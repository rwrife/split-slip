import os
import tempfile
import unittest
from pathlib import Path

from Scripts.permissions_audit import audit_tree


def make_repo(root: Path, *, family="1", extra_files=None, entitlement=False):
    (root / "App").mkdir(parents=True)
    (root / "Packages" / "ReceiptDomain" / "Sources" / "ReceiptDomain").mkdir(parents=True)
    (root / "Packages" / "ReceiptDomain" / "Tests" / "ReceiptDomainTests").mkdir(parents=True)
    (root / "SplitSlip.xcodeproj").mkdir()
    (root / "SplitSlip.xcodeproj" / "project.pbxproj").write_text(
        f"""
        GENERATE_INFOPLIST_FILE = YES;
        TARGETED_DEVICE_FAMILY = {family};
        TARGETED_DEVICE_FAMILY = {family};
        """,
        encoding="utf-8",
    )
    (root / "App" / "SplitSlipApp.swift").write_text(
        "import SwiftUI\nstruct SplitSlipApp {}\n", encoding="utf-8"
    )
    (root / "Packages" / "ReceiptDomain" / "Sources" / "ReceiptDomain" / "Money.swift").write_text(
        "import Foundation\n", encoding="utf-8"
    )
    for name, content in (extra_files or {}).items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    if entitlement:
        (root / "SplitSlip.entitlements").write_text("<plist/>", encoding="utf-8")


class PermissionsAuditTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_clean_tree_passes(self):
        make_repo(self.root)
        self.assertEqual(audit_tree(self.root), [])

    def test_ipad_family_value_is_a_violation(self):
        make_repo(self.root, family="1,2")
        violations = audit_tree(self.root)
        self.assertTrue(any("TARGETED_DEVICE_FAMILY = 1,2" in v for v in violations))

    def test_missing_device_family_is_a_violation(self):
        make_repo(self.root)
        project = self.root / "SplitSlip.xcodeproj" / "project.pbxproj"
        text = project.read_text()
        project.write_text("\n".join(l for l in text.splitlines() if "TARGETED_DEVICE_FAMILY" not in l))
        self.assertTrue(any("no TARGETED_DEVICE_FAMILY" in v for v in audit_tree(self.root)))

    def test_entitlements_file_is_a_violation(self):
        make_repo(self.root, entitlement=True)
        self.assertTrue(any("entitlements file exists" in v for v in audit_tree(self.root)))

    def test_code_sign_entitlements_setting_is_a_violation(self):
        make_repo(self.root)
        project = self.root / "SplitSlip.xcodeproj" / "project.pbxproj"
        project.write_text(
            project.read_text() + "\nCODE_SIGN_ENTITLEMENTS = SplitSlip.entitlements;\n"
        )
        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS" in v for v in audit_tree(self.root)))

    def test_usage_description_key_is_a_violation(self):
        make_repo(self.root)
        project = self.root / "SplitSlip.xcodeproj" / "project.pbxproj"
        project.write_text(
            project.read_text() + '\n\t\t\t\tINFOPLIST_KEY_NSPhotoLibraryUsageDescription = "why";\n'
        )
        self.assertTrue(any("UsageDescription" in v for v in audit_tree(self.root)))

    def test_network_api_in_shipped_source_is_a_violation(self):
        make_repo(
            self.root,
            extra_files={
                "App/Network.swift": "import Foundation\nfunc go() { URLSession.shared }\n"
            },
        )
        self.assertTrue(any("URLSession" in v for v in audit_tree(self.root)))

    def test_permission_api_in_shipped_source_is_a_violation(self):
        make_repo(
            self.root,
            extra_files={
                "Packages/ReceiptDomain/Sources/ReceiptDomain/Loc.swift": "import Foundation\nlet x = CLLocationManager()\n"
            },
        )
        self.assertTrue(any("CLLocationManager" in v for v in audit_tree(self.root)))

    def test_raw_photos_import_is_a_violation_but_photosui_is_allowed(self):
        make_repo(
            self.root,
            extra_files={
                "App/Picker.swift": "import PhotosUI\nstruct P {}\n",
                "App/Legacy.swift": "import Photos\nstruct L {}\n",
            },
        )
        violations = audit_tree(self.root)
        self.assertTrue(any("Photos/Legacy" in v or "Legacy.swift" in v for v in violations))
        self.assertFalse(any("Picker.swift" in v for v in violations))

    def test_test_targets_are_exempt(self):
        # Tests simulate corrupt/hostile inputs; forbidden tokens there must
        # not fail the shipped-source audit.
        make_repo(
            self.root,
            extra_files={
                "Packages/ReceiptDomain/Tests/ReceiptDomainTests/Fake.swift": "let y = URLSession\n"
            },
        )
        self.assertEqual(audit_tree(self.root), [])

    def test_missing_project_is_a_violation(self):
        (self.root / "App").mkdir()
        self.assertTrue(any("project.pbxproj is missing" in v for v in audit_tree(self.root)))


if __name__ == "__main__":
    unittest.main()
