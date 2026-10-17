#!/usr/bin/env python3
"""Native E2E checks with a ledger: a check that passed is not run again until something it depends on changes.

A check's fingerprint covers its definition, every committed file it depends on and the test Mac's environment. Its
files are the source folders of the Swift targets it exercises, found from the package graph, plus the files named in
its definition: a change to a test, a doc or another check's script leaves it covered. The environment is the host,
its macOS and Swift build, and for live checks the Codex version. Only passes are recorded; a failure always runs
again. `--force` reruns a covered check and needs a reason, which the ledger keeps.

    scripts/e2e.py plan              what would run on HEAD, and why
    scripts/e2e.py run               runs what is not covered, on the test Mac, and records the passes
    scripts/e2e.py run --only smoke  runs only the named checks that are not covered

The ledger is scripts/e2e-ledger.json; commit it with the change it verified.
"""
import argparse, datetime, hashlib, json, os, subprocess, sys, tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "scripts/e2e-ledger.json"
# The test Mac is named outside this public repository: --host, or MOCHI_E2E_HOST (see AGENTS.md).
DEFAULT_HOST = os.environ.get("MOCHI_E2E_HOST", "")
KEPT_PER_CHECK = 10
# The package graph and the build; every check depends on them.
COMMON_INPUTS = ("Package.swift", "Package.resolved")
# What launching the app needs besides its targets: the bundle script and the catalogs it compiles in.
APP_INPUTS = ("scripts/build-app.sh", "scripts/localization.py", "scripts/release_support.py", "Localization/")
APP_ROOTS = ("MochiApp", "MochiMCP")
# The learner a hands-free check plays: synthesized on the test Mac, so its recipe is part of the definition.
LEARNER = "I would like to order a coffee, please. Could you also tell me how long it will take?"
BUSY = "CheckmateAcceptance|run-gates.py|xctest|swift-test|swift-build"


@dataclass(frozen=True)
class Check:
    name: str
    roots: tuple  # the Swift targets it exercises
    extra: tuple = ()  # further committed files or folders (a trailing / means a folder) it depends on
    app_args: tuple = ()  # launches the development app with these arguments
    command: str = ""  # or runs this command in the staged copy
    evidence: str = ""  # the file its verdict is read from, in its evidence folder
    live: bool = False  # reaches the real Codex sign-in and OpenAI
    timeout: int = 900

    def spec(self):
        """The definition that decides the result, in the form the ledger stores it (lists, not tuples); changing it
        makes the check run again."""
        return json.loads(json.dumps(asdict(self)))


AUDITION = "MOCHI_LIVE_AUDITION=1 RUST_LOG=codex_app_server=debug,codex_core=info swift test --filter {}"
CHECKS = (
    Check("smoke", APP_ROOTS, APP_INPUTS, ("--smoke-test",), evidence="smoke.txt"),
    Check("tray", APP_ROOTS, APP_INPUTS, ("--tray-smoke-test",), evidence="tray-smoke.txt", timeout=600),
    Check("probe", APP_ROOTS, APP_INPUTS, ("--probe",), evidence="live-probe.txt", live=True, timeout=600),
    Check("tools-probe", APP_ROOTS, APP_INPUTS, ("--tools-probe",), evidence="live-tools-probe.txt", live=True),
    Check(
        "hands-free", APP_ROOTS, APP_INPUTS, ("--hands-free-smoke-test", "{learner}"),
        evidence="hands-free-smoke.json", live=True, timeout=600),
    Check(
        "barge-in", APP_ROOTS, APP_INPUTS, ("--hands-free-smoke-test", "{learner}", "--barge-in"),
        evidence="barge-in-smoke.json", live=True, timeout=600),
    Check(
        "single-instance", APP_ROOTS, APP_INPUTS + ("VERSION", "scripts/tests/single_instance_e2e.py",
                                                    "scripts/tests/fixtures/"),
        command="python3 scripts/tests/single_instance_e2e.py --allow-native",
        evidence="build/evidence/single-instance-e2e/report.json"),
    *(Check(f"audition-{suite}", ("MochiProvidersTests",), command=AUDITION.format(suite), evidence=suite,
            live=True, timeout=1800)
      for suite in ("CoachingAuditionTests", "StartAgainAuditionTests", "HelpSuggestionLiveTests",
                    "TemplateAuditionTests")),
)


# MARK: Fingerprints


def target_dirs(package, roots):
    """The source folders of `roots` and every target they depend on, from `swift package dump-package`."""
    targets = {t["name"]: t for t in package["targets"]}
    seen, pending = set(), list(roots)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        if name not in targets:
            raise ValueError(f"No target named {name} in the package")
        seen.add(name)
        for dependency in targets[name]["dependencies"]:
            kind, value = next(iter(dependency.items()))
            if kind in ("byName", "target") and value[0] in targets:
                pending.append(value[0])  # a product of another package is pinned by Package.resolved
    dirs = []
    for name in sorted(seen):
        t = targets[name]
        base = "Tests" if t["type"] == "test" else "Sources"
        dirs.append((t.get("path") or f"{base}/{name}").rstrip("/") + "/")
    return dirs


def inputs(check, package):
    """Every committed path prefix the check depends on."""
    return tuple(sorted(set(COMMON_INPUTS) | set(check.extra) | set(target_dirs(package, check.roots))))


def covered_by(path, prefixes):
    return any(path == p or (p.endswith("/") and path.startswith(p)) for p in prefixes)


def inputs_digest(tree, prefixes):
    """The digest of the committed files under `prefixes`: each path with its blob, so content and renames count.
    A prefix that matches nothing is an error: a misspelt input would otherwise never invalidate anything."""
    lines, matched = [], set()
    for path, blob in sorted(tree.items()):
        hits = [p for p in prefixes if covered_by(path, (p,))]
        if hits:
            matched.update(hits)
            lines.append(f"{path}\0{blob}\n")
    missing = [p for p in prefixes if p not in matched]
    if missing:
        raise ValueError(f"Inputs match no committed file: {', '.join(missing)}")
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def environment(check, host_env):
    keys = ("host", "macos", "swift") + (("codex",) if check.live else ())
    return {k: host_env.get(k, "") for k in keys}


def fingerprint(check, digest, env):
    body = json.dumps({"spec": check.spec(), "inputs": digest, "env": env}, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()


# MARK: Plan


@dataclass
class Decision:
    check: Check
    fingerprint: str
    digest: str
    env: dict
    covering: dict = None  # the pass that covers it
    reasons: list = field(default_factory=list)

    @property
    def needed(self):
        return self.covering is None


def decide(checks, ledger, tree, package, host_env, changed=lambda commit, prefixes: None):
    """What each check needs. `changed(commit, prefixes)` lists the input paths changed since a commit, or None."""
    decisions = []
    for check in checks:
        prefixes = inputs(check, package)
        digest = inputs_digest(tree, prefixes)
        env = environment(check, host_env)
        d = Decision(check, fingerprint(check, digest, env), digest, env)
        passes = [p for p in ledger.get("passes", []) if p["check"] == check.name]
        d.covering = next((p for p in reversed(passes) if p["fingerprint"] == d.fingerprint), None)
        if d.needed:
            last = passes[-1] if passes else None
            if last is None:
                d.reasons.append("never passed")
            else:
                if last.get("spec") != check.spec():
                    d.reasons.append("its definition changed")
                if last.get("inputs") != digest:
                    paths = changed(last["commit"], prefixes) or []
                    shown = ", ".join(paths[:4]) + (f" and {len(paths) - 4} more" if len(paths) > 4 else "")
                    d.reasons.append(f"inputs changed since {last['commit'][:7]}" + (f": {shown}" if paths else ""))
                for key, value in env.items():
                    if last.get("env", {}).get(key) != value:
                        d.reasons.append(f"{key} {last.get('env', {}).get(key) or '(none)'} → {value or '(none)'}")
        decisions.append(d)
    return decisions


def record(ledger, decision, commit, evidence, ran_at, forced=""):
    entry = {
        "check": decision.check.name, "fingerprint": decision.fingerprint, "commit": commit, "ran_at": ran_at,
        "inputs": decision.digest, "env": decision.env, "spec": decision.check.spec(), "evidence": evidence,
    }
    if forced:
        entry["forced"] = forced
    passes = ledger.setdefault("passes", [])
    passes.append(entry)
    mine = [p for p in passes if p["check"] == decision.check.name]
    for stale in mine[:-KEPT_PER_CHECK]:
        passes.remove(stale)
    return entry


# MARK: Verdicts, read from the evidence a check left


def verdict(check, text, exit_code):
    """(passed, one-line summary) for a check's evidence file, or its output for a command."""
    if exit_code != 0:
        return False, f"exit {exit_code}"
    if not text.strip():
        return False, f"{check.evidence} is missing or empty"
    if check.name == "smoke":
        line = text.strip().splitlines()[0]
        return line.startswith("Native smoke: PASS"), line
    if check.name == "tray":
        lines = [l for l in text.splitlines() if l.strip()]
        failed = [l for l in lines if not l.startswith("PASS")]
        return not failed and bool(lines), failed[0] if failed else f"{len(lines)} of {len(lines)} PASS"
    if check.name == "probe":
        lines = [l for l in text.splitlines() if l.strip()]
        failed = [l for l in lines if ": PASS" not in l]
        return not failed and bool(lines), failed[0] if failed else f"{len(lines)} of {len(lines)} PASS"
    if check.name == "tools-probe":
        line = text.strip().splitlines()[0]
        return line.startswith("Live Realtime instructions and tools: PASS"), line[:120]
    if check.name in ("hands-free", "barge-in"):
        results = [c["passed"] for c in json.loads(text).get("checks", [])]
        return bool(results) and all(results), f"{sum(results)} of {len(results)} checks passed"
    if check.name == "single-instance":
        report = json.loads(text)
        checks = report.get("checks", [])
        return report.get("result") == "PASS" and bool(checks), f"{report.get('result')}, {len(checks)} checks"
    if check.name.startswith("audition-"):
        # A filter that matches nothing also exits 0; the suite itself has to have passed.
        passed = f"Test Suite '{check.evidence}' passed" in text
        return passed, f"{check.evidence} passed" if passed else f"{check.evidence} did not pass"
    raise ValueError(f"No verdict for {check.name}")


# MARK: The test Mac


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def committed_tree(commit="HEAD"):
    tree = {}
    for line in git("ls-tree", "-r", commit).splitlines():
        meta, path = line.split("\t", 1)
        tree[path] = meta.split()[2]
    return tree


def changed_paths(commit, prefixes):
    try:
        paths = git("diff", "--name-only", commit, "HEAD").split()
    except subprocess.CalledProcessError:
        return None  # the commit is not in this clone
    return [p for p in paths if covered_by(p, prefixes)]


def package_graph():
    out = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT, check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def remote(host, script, timeout=120):
    """Runs `script` with bash on the test Mac; returns (exit code, combined output)."""
    try:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", host, "bash", "-s"], input=script, capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout} s"
    return r.returncode, r.stdout + r.stderr


PRELUDE = "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\nset -u\n"


def host_environment(host):
    code, out = remote(host, PRELUDE + """
echo "host=$(scutil --get LocalHostName)"
echo "macos=$(sw_vers -productVersion) $(sw_vers -buildVersion)"
echo "swift=$(xcrun swift --version 2>&1 | head -1)"
echo "codex=$(codex --version 2>/dev/null)"
""")
    if code != 0:
        raise SystemExit(f"Cannot read the test Mac {host}: {out.strip()}")
    env = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    # The ledger is public: it keeps a digest of the Mac's name, which still tells one Mac from another.
    env["name"] = env.pop("host")
    env["host"] = hashlib.sha256(env["name"].encode()).hexdigest()[:12]
    return env


def busy(host):
    code, out = remote(host, PRELUDE + f"{{ pgrep -lx Mochi; pgrep -fl '{BUSY}'; }} | cut -c1-120 | head -8; true")
    return out.strip()


def stage(host, commit, folder):
    archive = subprocess.Popen(["git", "archive", "--format=tar", commit], cwd=ROOT, stdout=subprocess.PIPE)
    extract = subprocess.run(["ssh", "-o", "BatchMode=yes", host, f"mkdir -p {folder} && tar -x -C {folder}"],
                             stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0 or extract.returncode != 0:
        raise SystemExit("Could not stage the commit on the test Mac")


def run_check(host, folder, check):
    """Runs one check in the staged copy; returns (passed, summary)."""
    evidence = f"{folder}/evidence/{check.name}"
    if check.app_args:
        args = " ".join(f'"{a}"' for a in check.app_args).replace("{learner}", f"{folder}/evidence/learner.pcm")
        body = (f"rm -rf {evidence}; mkdir -p {evidence}; cd {folder}\n"
                f"perl -e 'alarm shift; exec @ARGV' {check.timeout} open -n -W -F "
                f"--env MOCHI_EVIDENCE_DIR={evidence} build/Mochi.app --args {args}\n"
                f"code=$?; cat {evidence}/{check.evidence} 2>/dev/null; exit $code")
    else:
        source = f"{folder}/{check.evidence}" if "/" in check.evidence else ""
        body = (f"mkdir -p {evidence}; cd {folder}\n"
                f"perl -e 'alarm shift; exec @ARGV' {check.timeout} bash -c \"{check.command}\" "
                f"> {evidence}/output.txt 2>&1; code=$?\n"
                + (f"cat {source} 2>/dev/null\n" if source else f"cat {evidence}/output.txt\n")
                + "exit $code")
    code, out = remote(host, PRELUDE + body, timeout=check.timeout + 120)
    return verdict(check, out, code)


SETUP = """
cd {folder}
if [ {app} = 1 ]; then ./scripts/build-app.sh > evidence/build-app.txt 2>&1 || {{ tail -20 evidence/build-app.txt; exit 1; }}; fi
say -o evidence/learner.aiff "{learner}"
afconvert evidence/learner.aiff evidence/learner.wav -f WAVE -d LEI16@24000 -c 1
python3 -I -c 'import sys, wave; w = wave.open(sys.argv[1]); open(sys.argv[2], "wb").write(w.readframes(w.getnframes()))' evidence/learner.wav evidence/learner.pcm
"""


# MARK: Commands


def load_ledger():
    return json.loads(LEDGER.read_text()) if LEDGER.exists() else {"schema": 1, "passes": []}


def save_ledger(ledger):
    LEDGER.write_text(json.dumps(ledger, indent=1, sort_keys=True, ensure_ascii=False) + "\n")


def selected(names):
    known = {c.name: c for c in CHECKS}
    unknown = [n for n in names if n not in known]
    if unknown:
        raise SystemExit(f"Unknown checks: {', '.join(unknown)}. Known: {', '.join(known)}")
    return [known[n] for n in names]


def plan_for(host, only):
    host_env = host_environment(host)
    checks = selected(only) if only else list(CHECKS)
    return decide(checks, load_ledger(), committed_tree(), package_graph(), host_env, changed_paths), host_env


def show(decisions):
    for d in decisions:
        if d.needed:
            print(f"  RUN    {d.check.name:34} {'; '.join(d.reasons)}")
        else:
            c = d.covering
            print(f"  SKIP   {d.check.name:34} passed at {c['commit'][:7]} on {c['ran_at'][:10]}: {c['evidence']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("plan", "run"))
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--only", default="", help="comma-separated check names")
    parser.add_argument("--force", default="", help="comma-separated covered checks to run again")
    parser.add_argument("--reason", default="", help="why --force is necessary; kept in the ledger")
    parser.add_argument("--keep", action="store_true", help="leave the staged copy on the test Mac")
    a = parser.parse_args()
    if not a.host:
        raise SystemExit("Name the test Mac with --host or MOCHI_E2E_HOST")
    only = [n for n in a.only.split(",") if n]
    forced = {c.name for c in selected([n for n in a.force.split(",") if n])}
    if forced and not a.reason.strip():
        raise SystemExit("--force needs --reason: a covered check runs again only when it is necessary")
    decisions, host_env = plan_for(a.host, only)
    for d in decisions:
        if d.check.name in forced and not d.needed:
            d.covering, d.reasons = None, [f"forced: {a.reason}"]
    commit = git("rev-parse", "HEAD").strip()
    print(f"E2E plan for {commit[:7]} on {a.host} ({host_env.get('name')}, macOS {host_env.get('macos')}):")
    show(decisions)
    needed = [d for d in decisions if d.needed]
    if a.command == "plan" or not needed:
        if not needed:
            print("Nothing to run: every check is covered.")
        return
    if git("status", "--porcelain", "--untracked-files=no").strip():
        raise SystemExit("Commit first: the ledger records what HEAD contains, and only HEAD is staged")
    if other := busy(a.host):
        raise SystemExit(f"The test Mac is busy; run when it is free:\n{other}")
    code, free = remote(a.host, "df -g ~ | tail -1 | awk '{print $4}'")
    if code != 0 or int(free.strip() or 0) < 8:
        raise SystemExit(f"The test Mac has {free.strip()} GB free; a staged copy and its builds need about 8")
    folder = f"mochi-e2e/{commit[:12]}-{datetime.datetime.now():%H%M%S}"
    ledger, failures = load_ledger(), []
    stage(a.host, commit, folder)
    try:
        app = int(any(d.check.app_args or d.check.name == "single-instance" for d in needed))
        code, out = remote(a.host, PRELUDE + f"cd ~ && mkdir -p {folder}/evidence\n"
                           + SETUP.format(folder=folder, app=app, learner=LEARNER), timeout=1800)
        if code != 0:
            raise SystemExit(f"Setup failed on the test Mac:\n{out}")
        for d in needed:
            print(f"  running {d.check.name} …", flush=True)
            passed, summary = run_check(a.host, f"$HOME/{folder}", d.check)
            print(f"    {'PASS' if passed else 'FAIL'}: {summary}", flush=True)
            if passed:
                ran_at = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
                record(ledger, d, commit, summary, ran_at, forced=a.reason if d.check.name in forced else "")
                save_ledger(ledger)  # after each pass, so an interrupted run keeps what it proved
            else:
                failures.append(d.check.name)
    finally:
        if a.keep:
            print(f"Kept {a.host}:~/{folder}")
        else:
            remote(a.host, f"rm -rf ~/{folder}")
    print(f"Ledger: {LEDGER.relative_to(ROOT)}; commit it with the change it verified.")
    if failures:
        raise SystemExit(f"Failed: {', '.join(failures)}")


if __name__ == "__main__":
    main()
