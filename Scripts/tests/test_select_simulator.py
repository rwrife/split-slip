import unittest

from Scripts.select_simulator import DestinationError, select_destination


class DestinationTests(unittest.TestCase):
    def test_selects_available_iphone_on_exact_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {
                        "name": "iPhone 17 Pro",
                        "udid": "PHONE-26",
                        "isAvailable": True,
                    },
                    {
                        "name": "iPad Pro",
                        "udid": "PAD-26",
                        "isAvailable": True,
                    },
                ]
            }
        }
        self.assertEqual(select_destination(devices, "26.0"), "PHONE-26")

    def test_rejects_unavailable_iphone(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "NOPE", "isAvailable": False}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "available iPhone"):
            select_destination(devices, "26.0")

    def test_rejects_unsupported_sdk_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-25-5": [
                    {"name": "iPhone 16", "udid": "OLD", "isAvailable": True}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "iOS 26.0"):
            select_destination(devices, "26.0")


if __name__ == "__main__":
    unittest.main()
