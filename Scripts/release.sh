#!/usr/bin/env bash
# Invoked only by the protected, manually dispatched release workflow.
set -Eeuo pipefail
umask 077
: "${ASC_KEY_ID:?Missing App Store Connect key ID}"
: "${ASC_ISSUER_ID:?Missing App Store Connect issuer ID}"
: "${ASC_KEY_P8:?Missing App Store Connect private key}"
: "${ASC_TEAM_ID:?Missing signing team}"
: "${RELEASE_BUILD_NUMBER:?Missing unique build number}"
: "${GITHUB_SHA:?Missing source provenance}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || { echo 'Source SHA mismatch' >&2; exit 1; }
[[ "$RELEASE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'Build number must be numeric' >&2; exit 1; }
export DEVELOPER_DIR
DEVELOPER_DIR="$(python3 Scripts/select_xcode.py --toolchain toolchain.json)"
release_dir="$repo_root/build/release"
mkdir -p "$release_dir"
key_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/splitslip-signing.XXXXXX")"
trap 'rm -rf "$key_dir"' EXIT
export API_PRIVATE_KEYS_DIR="$key_dir"
key_file="$key_dir/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_KEY_P8" > "$key_file"
unset ASC_KEY_P8

xcodebuild -project SplitSlip.xcodeproj -scheme SplitSlip -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$release_dir/SplitSlip.xcarchive" \
  -allowProvisioningUpdates -authenticationKeyPath "$key_file" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" CURRENT_PROJECT_VERSION="$RELEASE_BUILD_NUMBER" archive

python3 - "$release_dir" <<'PY'
import json, os, pathlib, plistlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
app = root / 'SplitSlip.xcarchive/Products/Applications/SplitSlip.app'
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
if info.get('UIDeviceFamily') != [1]:
    raise SystemExit('Release refused: built app must be iPhone-only')
if info.get('CFBundleIdentifier') != 'com.infinityball.splitslip':
    raise SystemExit('Release refused: unexpected bundle ID')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
(root / 'provenance.json').write_text(json.dumps({
    'sha': os.environ['GITHUB_SHA'], 'build': info['CFBundleVersion'],
    'version': info['CFBundleShortVersionString'], 'deviceFamily': info['UIDeviceFamily'],
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
    'appleProcessing': 'Not verified. An upload response is not a processed TestFlight build.'
}, indent=2))
options = {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'automatic',
           'teamID': os.environ['ASC_TEAM_ID'], 'manageAppVersionAndBuildNumber': False}
with (root / 'ExportOptions.plist').open('wb') as f:
    plistlib.dump(options, f)
PY

xcodebuild -exportArchive -archivePath "$release_dir/SplitSlip.xcarchive" \
  -exportPath "$release_dir/export" -exportOptionsPlist "$release_dir/ExportOptions.plist" \
  -allowProvisioningUpdates -authenticationKeyPath "$key_file" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"

if [[ "${UPLOAD_TO_TESTFLIGHT:-false}" == true ]]; then
  ipa_files=("$release_dir"/export/*.ipa)
  [[ ${#ipa_files[@]} == 1 && -f "${ipa_files[0]}" ]] || { echo 'Expected one exported IPA' >&2; exit 1; }
  xcrun altool --upload-app -f "${ipa_files[0]}" --type ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    --output-format json > "$release_dir/upload-response.json"
  echo 'Upload request completed. Verify Apple processing and record the real build ID before claiming TestFlight availability.'
fi
