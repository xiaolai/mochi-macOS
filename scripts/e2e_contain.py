#!/usr/bin/env python3
"""Runs one e2e check on the test Mac so that nothing it started outlives it.

    python3 -I scripts/e2e_contain.py <timeout seconds> <staged folder> <command> [arguments …]

The command runs in its own session and process group. When it exits, times out (exit 124) or this runner is
interrupted or terminated (exit 128 + the signal), the whole group is ended: `swift test`'s xctest child and the
fixtures a script started go with it. An app that `open` launched belongs to launchd, not to the group, so every
process whose command line names the staged folder is ended too; the staged app and fixtures all live there.
"""
import os, re, signal, subprocess, sys, time

GRACE = 5  # seconds between SIGTERM and SIGKILL


class Interrupted(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def pids_naming(folder, own=frozenset()):
    """The processes whose command line names `folder`, except this runner's own."""
    pattern = re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", folder.rstrip("/") + "/")
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) not in own]


def signal_all(group, pids, signum):
    try:
        os.killpg(group, signum)
    except (ProcessLookupError, PermissionError):
        pass  # the group is already empty
    for pid in pids:
        try:
            os.kill(pid, signum)
        except (ProcessLookupError, PermissionError):
            pass


def end(group, folder):
    """Ends the command's process group and everything that names the staged folder: SIGTERM, then SIGKILL."""
    own = frozenset({os.getpid()})
    signal_all(group, pids_naming(folder, own), signal.SIGTERM)
    deadline = time.monotonic() + GRACE
    while time.monotonic() < deadline and (group_alive(group) or pids_naming(folder, own)):
        time.sleep(0.1)
    signal_all(group, pids_naming(folder, own), signal.SIGKILL)


def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def run(timeout, folder, command):
    def interrupted(signum, frame):
        raise Interrupted(signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    child = subprocess.Popen(command, start_new_session=True)
    try:
        code = child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"timed out after {timeout} s", file=sys.stderr, flush=True)
        code = 124
    except Interrupted as error:
        print(f"interrupted by signal {error.signum}", file=sys.stderr, flush=True)
        code = 128 + error.signum
    # Ignore further signals while ending, so a second interrupt cannot leave the group half ended.
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_IGN)
    end(child.pid, folder)
    child.poll()
    return code


if __name__ == "__main__":
    if len(sys.argv) < 4 or not sys.argv[1].isdigit() or not sys.argv[2].startswith("/"):
        sys.exit(__doc__)
    sys.exit(run(int(sys.argv[1]), sys.argv[2], sys.argv[3:]))
