import copy
import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location("validation", Path(__file__).with_name("validate-release.py"))
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class ReleaseValidationChecks(unittest.TestCase):
    def setUp(self):
        self.settings = {
            "MARKETING_VERSION": "0.34.1", "CURRENT_PROJECT_VERSION": "33",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.fayazahmed.Screendrop",
        }
        self.info = {
            "SUFeedURL": validation.FEED_URL,
            "SUPublicEDKey": "GPP/1zhI8AnoKZcO/7C5jIqjOLvxIgDNOvHEXU/+MLE=",
        }

    def test_valid_release(self):
        self.assertEqual(validation.validate_release("v0.34.1", self.settings, self.info), 33)

    def test_wrong_identity_tag_feed_or_key(self):
        invalid = [
            ("v0.34.0", {}, {}), ("../v0.34.1", {}, {}),
            ("v0.34.1", {"PRODUCT_BUNDLE_IDENTIFIER": "com.fayazahmed.Screendrop.dev"}, {}),
            ("v0.34.1", {"CURRENT_PROJECT_VERSION": "0"}, {}),
            ("v0.34.1", {}, {"SUFeedURL": "https://raw.githubusercontent.com/fayazara/screendrop/main/appcast.xml"}),
            ("v0.34.1", {}, {"SUPublicEDKey": "bad-key"}),
        ]
        for tag, settings_changes, info_changes in invalid:
            with self.subTest(tag=tag, settings=settings_changes, info=info_changes):
                settings, info = copy.copy(self.settings), copy.copy(self.info)
                settings.update(settings_changes)
                info.update(info_changes)
                with self.assertRaises(ValueError):
                    validation.validate_release(tag, settings, info)

    def test_build_must_exceed_published_versions(self):
        for previous in [32, 33, 34]:
            feed = ET.fromstring(f'<rss xmlns:sparkle="{validation.SPARKLE_NAMESPACE}"><channel><item><sparkle:version>{previous}</sparkle:version></item></channel></rss>')
            with self.subTest(previous=previous):
                if previous < 33:
                    self.assertEqual(validation.validate_release("v0.34.1", self.settings, self.info, feed), 33)
                else:
                    with self.assertRaises(ValueError):
                        validation.validate_release("v0.34.1", self.settings, self.info, feed)


if __name__ == "__main__":
    unittest.main()
