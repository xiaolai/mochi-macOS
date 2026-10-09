#!/usr/bin/env python3
"""Small, testable release checks; credentials stay in notarytool's Keychain profile."""
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path


def validate_metadata(info, version, build):
    expected = {"CFBundleShortVersionString":version, "CFBundleVersion":build,
                "CFBundleIdentifier":"com.lixiaolai.mochi-macos", "LSMinimumSystemVersion":"14.0"}
    if not str(build).isdigit() or int(build) < 1:
        raise ValueError("Build number must be a positive integer")
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected {key}: {info.get(key)!r}; expected {value!r}")


def validate_binary_signature(architectures, signature):
    if architectures.strip() != "arm64":
        raise ValueError("Unexpected executable architecture")
    for pattern in (r"^Authority=Developer ID Application:", r"^Timestamp=.+", r"^TeamIdentifier=(?!not set).+", r"^CodeDirectory .*flags=.*runtime"):
        if not re.search(pattern, signature, re.MULTILINE):
            raise ValueError("Executable needs timestamped Developer ID signing with hardened runtime")


def check_binary(path, *, run=subprocess.run):
    run(["codesign", "--verify", "--strict", path], check=True, capture_output=True)
    architectures = run(["lipo", "-archs", path], check=True, capture_output=True, text=True).stdout
    signature = run(["codesign", "-d", "--verbose=4", path], check=True, capture_output=True, text=True).stderr
    validate_binary_signature(architectures, signature)


def validate_distribution_symbols(app_strings, helper_symbols, app_symbols=""):
    for probe in ("--tools-probe", "--smoke-test", "--tray-smoke-test", "--probe", "--import-environment", "AutomationSmokeClient", "SmokePlaybackPlayer"):
        if probe in app_strings:
            raise ValueError("Development probes cannot ship in the distribution app")
    for symbol in ("AutomationSmokeClient", "SmokePlaybackPlayer", "toolsProbe", "smokeTray"):
        if symbol in app_symbols:
            raise ValueError("Development probe symbols cannot ship in the distribution app")
    for retired in ("api.elevenlabs.io", "ElevenLabsVoices", "VoiceRenderer", "VoiceSetupModel", "ELEVENLABS_API_KEY", "OPENAI_API_KEY"):
        if retired in app_strings or retired in app_symbols:
            raise ValueError("Retired voice providers cannot ship in the Codex-only app")
    for symbol in ("Credentials", "RealtimeService", "VoiceRenderer", "codexToken"):
        if symbol in helper_symbols:
            raise ValueError("Provider and credential code cannot ship in the MCP helper")


def check_distribution(app, helper, *, run=subprocess.run):
    app_strings = run(["strings", app], check=True, capture_output=True, text=True).stdout
    app_symbols = run(["nm", app], check=True, capture_output=True, text=True).stdout
    helper_symbols = run(["nm", helper], check=True, capture_output=True, text=True).stdout
    validate_distribution_symbols(app_strings, helper_symbols, app_symbols)


def render_cask(template, digest):
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("A real lowercase SHA-256 is required")
    return template.replace("@SHA256@", digest)


def notarize(artifact, profile, *, run=subprocess.run, sleep=time.sleep, attempts=3):
    artifact = Path(artifact)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    record = artifact.with_suffix(artifact.suffix + ".notary.json")
    submission = None
    if record.exists():
        saved = json.loads(record.read_text())
        if saved.get("sha256") == digest:
            submission = saved.get("id")

    def command(operation, *args):
        result = run(["xcrun","notarytool",operation,*args,"--keychain-profile",profile],capture_output=True)
        try:
            payload = plistlib.loads(result.stdout)
        except (ValueError, plistlib.InvalidFileException):
            payload = {}
        return result, payload

    if not submission:
        for attempt in range(attempts):
            _, payload = command("submit",str(artifact),"--output-format","plist")
            submission = payload.get("id")
            if submission:
                record.write_text(json.dumps({"sha256":digest,"id":submission}) + "\n")
                break
            if attempt + 1 < attempts:
                sleep(5 * (attempt + 1))
        if not submission:
            raise RuntimeError("Notarization did not return a submission ID")
    print(f"Notary submission: {submission}",flush=True)
    status = "no verdict"
    for attempt in range(attempts):
        _, payload = command("wait",submission,"--timeout","60s","--output-format","plist")
        status = payload.get("status", "no verdict")
        if status == "Accepted":
            return submission
        if status in ("Invalid","Rejected"):
            result, _ = command("log",submission)
            artifact.with_suffix(artifact.suffix + ".rejection.log").write_bytes(result.stdout + result.stderr)
            raise RuntimeError(f"Notarization {status}; see artifact rejection log")
        if attempt + 1 < attempts:
            sleep(5 * (attempt + 1))
    raise RuntimeError(f"Notarization polling ended with {status}; rerun to resume {submission}")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "notarize":
            notarize(sys.argv[2],sys.argv[3])
        elif sys.argv[1] == "distribution":
            check_distribution(sys.argv[2],sys.argv[3])
        elif sys.argv[1] == "binary":
            check_binary(sys.argv[2])
        elif sys.argv[1] == "metadata":
            with open(sys.argv[2],"rb") as file:
                validate_metadata(plistlib.load(file),sys.argv[3],sys.argv[4])
        elif sys.argv[1] == "cask":
            Path(sys.argv[4]).write_text(render_cask(Path(sys.argv[2]).read_text(),sys.argv[3]))
        else:
            raise ValueError("Unknown operation")
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
