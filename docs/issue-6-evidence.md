# Issue #6 evidence: integrated journeys, arithmetic regressions, and gates

Scope discipline: this file separates **unit**, **static**, **simulator**,
**physical iPhone**, and **store-processing** evidence. Green rows below cite
commands that were actually executed; unchecked acceptance boxes stay open
when the required evidence tier does not exist on a headless Linux executor.

## Added in this slice (Refs #6)

### 1. Documented-limit arithmetic stress (unit tier, real pipeline)

`Packages/ReceiptDomain/Tests/ReceiptDomainTests/LimitStressTests.swift`
pushes the domain through the *real* finalization/backup-validation pipeline
at every documented bound from PLAN.md (not just the engine):

- Structurally maximal receipt: 200 lines x 500,000¢ = exactly the
  100,000,000¢ bound, 50 adjustments (25 fee/discount pairs netting zero),
  30 participants, maximum weight 1000 on every line. Finalizes with exact
  conservation per person, per row, per signed adjustment row; the export
  renders `1000000.00 USD` exactly.
- Byte-for-byte determinism of that finalization across runs.
- Maximum-magnitude negative discount (−999,999.99 against a 1,000,000.00
  line, 30-way): rounding must leave exactly one cent, deterministically at
  stored-order position 9 — a stable rounding-priority proof at the bound.
- Extreme weight skew (1,000 vs 29 x 1) at the full bound: every share
  within one cent of its exact proportional value, exact conservation.
- Participant removal on the maximal receipt: all 250 rows cleared *and*
  flagged for review, finalization refuses (never silent reallocation).
- The maximal snapshot survives `ReceiptLibrary.validate()` — the same
  recomputation a restore performs — unchanged.

Executed locally on this executor (Linux, Swift 6.2 toolchain, `swift test
--package-path Packages/ReceiptDomain`): **97 tests passed** (91 pre-existing
+ 6 new). This is supplementary unit evidence; the pinned macOS lane re-runs
the same suite at the exact PR head under the pinned toolchain.

### 2. Permissions/entitlements/offline audit (static tier, CI-gated)

`Scripts/permissions_audit.py` is a deterministic auditor now wired into
`Scripts/ci.sh` as a failing-phase step (its log uploads as
`permissions-audit.txt` in the CI artifact):

- no `.entitlements` file and no `CODE_SIGN_ENTITLEMENTS` anywhere;
- every `TARGETED_DEVICE_FAMILY` assignment is exactly `1` (a `1,2` fails);
- no `NS*UsageDescription` permission keys in Info.plist build settings;
- shipped sources contain no location/contacts/camera/microphone/calendar/
  photo-library-authorization/notification/tracking APIs;
- no URLSession/Network.framework/CloudKit/MultipeerConnectivity/CFNetwork/
  WCSession/MKMapView usage (offline independence);
- photo access stays `PhotosUI`/`PhotosPicker` — a raw `import Photos` fails.

Current result on the real tree: **PASS** (command above, output retained in
the CI artifact each run). 11 unit tests in
`Scripts/tests/test_permissions_audit.py` cover each rule and its
clean-tree/mutation behavior; full helper suite now 32 tests.

This audit proves *source and build-configuration posture only*. It cannot
prove a signed archive, a runtime permission sheet, or OS-level behavior —
those remain separate gates below.

## Evidence-tier status for issue #6 acceptance

| Criterion | Status | Evidence tier |
|---|---|---|
| Integrated journey CI at exact head (entry→…→restore, restart, cancel) | Already automated (9 journeys incl. backup→delete→restore→relaunch and canceled exports); this PR re-proves at its head | simulator |
| Limit stress incl. removal, negative discounts, corrupted-store recovery without hidden errors | **Completed this slice** (item 1; corrupted-store + failure-injection coverage pre-existed in store/backup suites) | unit |
| Layout/accessibility/dark/light/no-color/orientation/offline journeys | Automated journeys exist (AXXXX-L + dark + canceled Files + rotation); permissions/entitlements + export privacy audit **automated this slice** (item 2) | simulator + static |
| Real iPhone VoiceOver/PhotosPicker/share sheet/Files/termination with recorded device/OS provenance | **BLOCKED — no physical iPhone reachable from headless CI.** No checklist item is marked passed | physical (missing) |
| Family-1 enforcement incl. built `UIDeviceFamily == [1]` | Pinned CI guard (pre-existing) + this PR's CI run | simulator |
| Real iPhone share/Files flows, store processing | Remain explicit open gates; not claimed | device/store (missing) |

## Reproduce

```bash
python3 -m unittest discover -s Scripts/tests        # 32 helper/audit tests
python3 Scripts/permissions_audit.py --root .        # static posture audit
# Full native lane (macOS, pinned toolchain):
Scripts/ci.sh "$(git rev-parse HEAD)"
```

## Next dependency

Issue #6 cannot close on headless CI: the real-iPhone evidence row above is
the remaining gate (plus #5's native share/Files device evidence, which #6's
checklist inherits). Nothing here claims otherwise.
