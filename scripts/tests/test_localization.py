import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("localization", Path(__file__).parents[1] / "localization.py")
localization = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localization)


def entry(**values):
    return {"localizations": {
        language: {"stringUnit": {"state": "translated", "value": value}} for language, value in values.items()}}


def complete(value):
    return entry(**{language: value for language in localization.LANGUAGES})


class LocalizationTests(unittest.TestCase):
    def test_specifiers_follow_argument_order(self):
        self.assertEqual(localization.specifiers("Delete %lld items from %@?"), ["lld", "@"])
        self.assertEqual(localization.specifiers("%2$@ から %1$lld 件"), ["lld", "@"])
        with self.assertRaises(ValueError):
            localization.specifiers("%1$@ and %@")

    def test_complete_catalog_passes(self):
        catalog = {"sourceLanguage": "en", "strings": {"Hello %@": complete("你好 %@"), "": {"shouldTranslate": False}}}
        self.assertEqual(localization.catalog_problems({"Hello %@", ""}, catalog), [])

    def test_missing_stale_untranslated_and_wrong_placeholders_all_fail(self):
        partial = complete("x")
        partial["localizations"]["ko"]["stringUnit"]["state"] = "new"
        catalog = {"sourceLanguage": "en", "strings": {
            "Old": complete("旧"), "Partial": partial, "%lld left": complete("还剩 %@")}}
        problems = "\n".join(localization.catalog_problems({"New", "Partial", "%lld left"}, catalog))
        self.assertIn("missing from the catalog: 'New'", problems)
        self.assertIn("stale (no source uses it): 'Old'", problems)
        self.assertIn("ko: no translation for 'Partial'", problems)
        self.assertIn("placeholders differ for '%lld left'", problems)

    def test_info_plist_english_must_match_the_bundle_template(self):
        key = "NSMicrophoneUsageDescription"
        catalog = {"sourceLanguage": "en", "strings": {key: complete("x")}}
        catalog["strings"][key]["localizations"]["en"] = {"stringUnit": {"state": "translated", "value": "Old text"}}
        script = f"<key>{key}</key><string>New text</string>"
        self.assertTrue(any("differs" in p for p in localization.info_plist_problems(catalog, script)))
        self.assertEqual(localization.info_plist_problems(catalog, script.replace("New", "Old")), [])

    def test_same_named_sources_in_two_modules_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            sources = Path(d)
            for path in ("MochiApp/Automation.swift", "MochiAutomation/Automation.swift", "MochiMCP/main.swift",
                         "MochiCore/main.swift"):
                (sources / path).parent.mkdir(parents=True, exist_ok=True)
                (sources / path).touch()
            clashes = localization.name_clashes(sources)
            self.assertEqual(len(clashes), 1)
            self.assertIn("Automation.swift", clashes[0])

    def test_source_keys_read_only_shipped_sources_and_refuse_an_empty_build(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            sources, extracted = root / "Sources", root / "strings"
            extracted.mkdir()
            with self.assertRaises(ValueError):
                localization.source_keys(extracted, sources)
            for name, source, key in (
                ("Views", sources / "MochiApp/Views.swift", "Shipped"),
                ("Domain", sources / "MochiCore/Domain.swift", "Core"),
                ("main", sources / "MochiMCP/main.swift", "Helper only"),
                ("Tests", root / "Tests/MochiAppTests/Tests.swift", "Test only"),
                ("Accessor", root / ".build/resource_bundle_accessor.swift", "Generated"),
                ("Deleted", sources / "MochiApp/Removed.swift", "Left behind"),
            ):
                if name != "Deleted":
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.touch()
                (extracted / f"{name}.stringsdata").write_text(json.dumps(
                    {"source": str(source), "tables": {"Localizable": [{"key": key}]}}))
            self.assertEqual(localization.source_keys(extracted, sources), {"Shipped", "Core"})

    def test_appkit_text_from_a_literal_is_refused_where_it_ships(self):
        with tempfile.TemporaryDirectory() as d:
            sources = Path(d)
            for path, text in (
                ("MochiApp/Search.swift", "\n".join((
                    'field.placeholderString = "Search this conversation"',
                    'field.setAccessibilityLabel(String(localized: "Search this conversation"))',
                    "alert.messageText =",
                    '    "Could not save"',
                    'item.button?.toolTip = "Mochi"',
                    'if item.title == "Stop" { field.stringValue = "" }',
                    "#if MOCHI_DEVELOPMENT",
                    '    window.title = "Smoke only"',
                    "    #if DEBUG",
                    '        window.title = "Nested smoke only"',
                    "    #endif",
                    "#else",
                    '    menu.addItem(withTitle: "Shipped", action: nil, keyEquivalent: "")',
                    "#endif",
                    'panel.title = "After the block"',
                ))),
                ("MochiMCP/main.swift", 'panel.title = "Helper only"'),
            ):
                (sources / path).parent.mkdir(parents=True, exist_ok=True)
                (sources / path).write_text(text)
            problems = localization.literal_problems(sources)
            self.assertEqual([problem.split(": ")[0] for problem in problems], [
                "MochiApp/Search.swift:1", "MochiApp/Search.swift:3", "MochiApp/Search.swift:13",
                "MochiApp/Search.swift:15"])
            self.assertIn("'Search this conversation'", problems[0])

    def test_interface_text_held_as_a_plain_string_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            sources = Path(d)
            (sources / "MochiApp").mkdir()
            (sources / "MochiApp/Views.swift").write_text("\n".join((
                'if app.saveExpression() { app.notice = "Saved to My Expressions." }',
                'app.notice = String(localized: "Saved to My Expressions.")',
                'self.error = AppFailure.message(for: error, fallback: "Could not save.")',
                'model.recordingWarning = quiet ? "Mochi hears nothing." : nil',
                'history.feedback = "Archived"',
                'report("The folder could not be opened.", in: .privacy)',
                'LabeledContent("Conversations and recordings", value: "On this Mac")',
                'LabeledContent("Conversations and recordings") { Text("On this Mac") }',
                'notice = ""',
                'error = nil',
            )))
            problems = localization.literal_problems(sources)
            self.assertEqual([problem.split(": ")[0] for problem in problems], [
                "MochiApp/Views.swift:1", "MochiApp/Views.swift:4", "MochiApp/Views.swift:5",
                "MochiApp/Views.swift:6", "MochiApp/Views.swift:7"])
            self.assertIn("'Saved to My Expressions.'", problems[0])
            self.assertIn("'On this Mac'", problems[4])

if __name__ == "__main__":
    unittest.main()
