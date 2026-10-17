import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("e2e", Path(__file__).parents[1] / "e2e.py")
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

# A package shaped like Mochi's: the app links the providers, the provider tests do not link the app.
PACKAGE = {"targets": [
    {"name": "Kernel", "type": "regular", "dependencies": []},
    {"name": "Providers", "type": "regular", "dependencies": [{"byName": ["Kernel", None]},
                                                              {"product": ["SaidGuard", "sayso", None, None]}]},
    {"name": "App", "type": "executable", "dependencies": [{"byName": ["Providers", None]}]},
    {"name": "Support", "type": "regular", "path": "Tests/Support", "dependencies": []},
    {"name": "ProvidersTests", "type": "test", "dependencies": [{"byName": ["Providers", None]},
                                                                {"byName": ["Support", None]}]},
]}
TREE = {
    "Package.swift": "p1", "Package.resolved": "r1", "Sources/Kernel/K.swift": "k1",
    "Sources/Providers/P.swift": "v1", "Sources/App/A.swift": "a1", "Tests/Support/S.swift": "s1",
    "Tests/ProvidersTests/T.swift": "t1", "README.md": "m1", "scripts/build-app.sh": "b1",
}
# A test reads a committed file by a path from the repository root: `repository.appendingPathComponent("Localization/
# Localizable.xcstrings")`, or the same through `#filePath`. The literal may sit on the next line or end in an
# interpolation.
REPOSITORY_READ = re.compile(
    r'(?:appendingPathComponent\(|appending\((?:path|component):|fileURLWithPath:|contentsOfFile:)\s*"([^"]*)"')


def repository_reads(text, top_level):
    """The repository-relative paths a Swift source reads: literals whose first component is committed at the top."""
    for literal in REPOSITORY_READ.findall(text):
        path = literal.split("\\(")[0]
        if path.split("/")[0] in top_level:
            yield path


HOST = {"host": "Mini", "macos": "27.0.1 26A434", "swift": "Swift 6.4", "codex": "codex-cli 0.163.0"}
APP = e2e.Check("ui", ("App",), ("scripts/build-app.sh",), ("--smoke-test",), evidence="smoke.txt")
LIVE = e2e.Check("live", ("ProvidersTests",), command="swift test", evidence="Suite", live=True)


def plan(tree=TREE, host=HOST, ledger=None, checks=(APP, LIVE)):
    return {d.check.name: d for d in e2e.decide(checks, ledger or {"passes": []}, tree, PACKAGE, host)}


def passed_all(tree=TREE, host=HOST):
    ledger = {"passes": []}
    for d in plan(tree, host).values():
        e2e.record(ledger, d, "c0ffee", "ok", "2026-10-17T00:00:00+08:00")
    return json.loads(json.dumps(ledger))  # as read back from disk


class DependencyTests(unittest.TestCase):
    def test_a_check_depends_on_its_targets_and_what_they_link(self):
        self.assertEqual(
            e2e.target_dirs(PACKAGE, ("App",)), ["Sources/App/", "Sources/Kernel/", "Sources/Providers/"])
        self.assertEqual(
            e2e.target_dirs(PACKAGE, ("ProvidersTests",)),
            ["Sources/Kernel/", "Sources/Providers/", "Tests/ProvidersTests/", "Tests/Support/"])

    def test_an_unknown_target_is_an_error(self):
        with self.assertRaises(ValueError):
            e2e.target_dirs(PACKAGE, ("Missing",))

    def test_an_input_that_matches_no_file_is_an_error(self):
        with self.assertRaises(ValueError):
            e2e.inputs_digest(TREE, ("scripts/build-ap.sh",))

    def test_every_real_check_names_files_that_exist(self):
        tree = e2e.committed_tree()
        package = e2e.package_graph()
        for check in e2e.CHECKS:
            e2e.inputs_digest(tree, e2e.inputs(check, package))

    def test_the_committed_tree_keeps_unusual_paths_as_they_are(self):
        # Without -z, git quotes a path with a space or non-ASCII letters, and the quoted form matches no input.
        names = ("Localization/a b.txt", "Localization/语言 é.txt", "VERSION")
        with tempfile.TemporaryDirectory() as folder:
            run = lambda *args: subprocess.run(["git", "-C", folder, *args], check=True, capture_output=True)
            run("init", "-q")
            for name in names:
                (Path(folder) / name).parent.mkdir(exist_ok=True)
                (Path(folder) / name).write_text(name)
            run("add", ".")
            run("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "t")
            first = run("rev-parse", "HEAD").stdout.decode().strip()
            for name in names[:2]:
                (Path(folder) / name).write_text("changed")
            run("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-am", "t")
            with mock.patch.object(e2e, "ROOT", Path(folder)):
                tree = e2e.committed_tree()
                changed = e2e.changed_paths(first, ("Localization/",))
        self.assertEqual(sorted(tree), sorted(names))
        self.assertEqual(sorted(changed), sorted(names[:2]))
        self.assertTrue(all(len(blob) == 40 for blob in tree.values()))
        e2e.inputs_digest(tree, ("Localization/",))

    def test_the_scanner_finds_repository_reads_in_every_form(self):
        text = (
            'let a = repository.appendingPathComponent("Localization/Localizable.xcstrings")\n'
            'let b = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(\n'
            '    "scripts/tests/fixtures/InstanceLock.c")\n'
            'let c = root.appendingPathComponent("build/evidence/\\(name)")\n'
            'let d = root.appending(path: "VERSION")\n'
            'let e = folder.appendingPathComponent("replies.jsonl")\n')
        top = {"Localization", "scripts", "VERSION", "Sources"}
        self.assertEqual(list(repository_reads(text, top)),
                         ["Localization/Localizable.xcstrings", "scripts/tests/fixtures/InstanceLock.c", "VERSION"])

    def test_every_file_a_checks_tests_read_is_one_of_its_inputs(self):
        # A test that reads a committed file at run time depends on it as much as on its own source: an edit to
        # the file has to make the check run again.
        tree = e2e.committed_tree()
        package = e2e.package_graph()
        top = {path.split("/")[0] for path in tree}
        for check in e2e.CHECKS:
            prefixes = e2e.inputs(check, package)
            sources = [p for p in tree if p.endswith(".swift") and p.startswith("Tests/") and e2e.covered_by(p, prefixes)]
            for source in sources:
                for path in repository_reads((e2e.ROOT / source).read_text(encoding="utf-8"), top):
                    with self.subTest(check=check.name, source=source, path=path):
                        self.assertTrue(e2e.covered_by(path, prefixes) or path.rstrip("/") + "/" in prefixes,
                                        f"{source} reads {path}, which is not an input of {check.name}")


class LedgerTests(unittest.TestCase):
    def test_nothing_runs_twice_when_nothing_changed(self):
        decisions = plan(ledger=passed_all())
        self.assertFalse(any(d.needed for d in decisions.values()))

    def test_a_file_outside_every_input_changes_nothing(self):
        decisions = plan(dict(TREE, **{"README.md": "m2"}), ledger=passed_all())
        self.assertFalse(any(d.needed for d in decisions.values()))

    def test_an_app_change_reruns_only_what_links_the_app(self):
        decisions = plan(dict(TREE, **{"Sources/App/A.swift": "a2"}), ledger=passed_all())
        self.assertTrue(decisions["ui"].needed)
        self.assertFalse(decisions["live"].needed)
        self.assertIn("inputs changed", decisions["ui"].reasons[0])

    def test_a_shared_change_reruns_everything_that_links_it(self):
        decisions = plan(dict(TREE, **{"Sources/Kernel/K.swift": "k2"}), ledger=passed_all())
        self.assertTrue(decisions["ui"].needed and decisions["live"].needed)

    def test_a_new_file_and_a_pinned_package_change_count(self):
        self.assertTrue(plan(dict(TREE, **{"Sources/Kernel/New.swift": "n1"}), ledger=passed_all())["ui"].needed)
        self.assertTrue(plan(dict(TREE, **{"Package.resolved": "r2"}), ledger=passed_all())["live"].needed)

    def test_another_mac_or_system_reruns_it(self):
        decisions = plan(host=dict(HOST, host="Other"), ledger=passed_all())
        self.assertTrue(decisions["ui"].needed)
        self.assertIn("host Mini → Other", decisions["ui"].reasons)
        self.assertTrue(plan(host=dict(HOST, macos="27.1 26B1"), ledger=passed_all())["ui"].needed)

    def test_codex_counts_only_for_live_checks(self):
        decisions = plan(host=dict(HOST, codex="codex-cli 0.170.0"), ledger=passed_all())
        self.assertFalse(decisions["ui"].needed)
        self.assertTrue(decisions["live"].needed)

    def test_changing_a_checks_definition_reruns_it(self):
        changed = e2e.Check("ui", ("App",), ("scripts/build-app.sh",), ("--smoke-test",), evidence="smoke.txt",
                            timeout=60)
        decision = plan(ledger=passed_all(), checks=(changed,))["ui"]
        self.assertTrue(decision.needed)
        self.assertIn("its definition changed", decision.reasons)

    def test_a_check_never_passed_runs(self):
        self.assertEqual(plan()["ui"].reasons, ["never passed"])

    def test_an_older_pass_covers_a_return_to_its_inputs(self):
        ledger = passed_all()
        later = plan(dict(TREE, **{"Sources/App/A.swift": "a2"}))
        e2e.record(ledger, later["ui"], "beef", "ok", "2026-10-18T00:00:00+08:00")
        self.assertFalse(plan(ledger=ledger)["ui"].needed)

    def test_the_ledger_keeps_the_latest_passes_per_check(self):
        ledger = {"passes": []}
        decision = plan()["ui"]
        for i in range(e2e.KEPT_PER_CHECK + 3):
            e2e.record(ledger, decision, f"c{i}", "ok", "t")
        commits = [p["commit"] for p in ledger["passes"]]
        self.assertEqual(len(commits), e2e.KEPT_PER_CHECK)
        self.assertEqual(commits[-1], f"c{e2e.KEPT_PER_CHECK + 2}")


class VerdictTests(unittest.TestCase):
    def check(self, name):
        return next(c for c in e2e.CHECKS if c.name == name)

    def test_a_failed_exit_or_missing_evidence_never_passes(self):
        self.assertFalse(e2e.verdict(self.check("smoke"), "Native smoke: PASS.", 1)[0])
        self.assertFalse(e2e.verdict(self.check("smoke"), "", 0)[0])

    def test_app_evidence(self):
        self.assertTrue(e2e.verdict(self.check("smoke"), "Native smoke: PASS. 82 snapshots\n", 0)[0])
        self.assertFalse(e2e.verdict(self.check("smoke"), "Native smoke: FAIL. 2 capture failures\n", 0)[0])
        self.assertTrue(e2e.verdict(self.check("tray"), "PASS: a\nPASS: b\n", 0)[0])
        self.assertFalse(e2e.verdict(self.check("tray"), "PASS: a\nFAIL: b\n", 0)[0])
        self.assertFalse(e2e.verdict(self.check("probe"), "Realtime text: PASS\nHelp translation: FAIL\n", 0)[0])
        report = {"checks": [{"passed": True}, {"passed": False}]}
        self.assertFalse(e2e.verdict(self.check("hands-free"), json.dumps(report), 0)[0])
        self.assertFalse(e2e.verdict(self.check("barge-in"), json.dumps({"checks": []}), 0)[0])
        self.assertTrue(e2e.verdict(self.check("single-instance"),
                                    json.dumps({"result": "PASS", "checks": [{}]}), 0)[0])

    def test_an_audition_that_ran_nothing_does_not_pass(self):
        coaching = self.check("audition-CoachingAuditionTests")
        self.assertFalse(e2e.verdict(coaching, "Executed 0 tests, with 0 failures\n", 0)[0])
        self.assertTrue(e2e.verdict(coaching, "Test Suite 'CoachingAuditionTests' passed at …\n", 0)[0])


if __name__ == "__main__":
    unittest.main()
