"""Checks that every interface string the compiler extracted has a finished translation in every shipped language.

Build with `-Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <folder>` and the
compiler writes one .stringsdata file per source file into <folder>. A string that is in the source but missing from
the catalog would silently show in English, so it fails here instead; a catalog entry no source uses is stale.
The catalogs live outside the package: build-app.sh compiles them with xcstringstool, so translations never depend
on whether a toolchain's package build understands string catalogs.
"""
import json
import re
import sys
from pathlib import Path

LANGUAGES = ("zh-Hans", "zh-Hant", "ja", "ko")
ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Localization/Localizable.xcstrings"
INFO_PLIST_CATALOG = ROOT / "Localization/InfoPlist.xcstrings"
INFO_PLIST_KEYS = {"NSMicrophoneUsageDescription"}
BUILD_SCRIPT = ROOT / "scripts/build-app.sh"
SOURCES = ROOT / "Sources"
# The MCP helper ships no translations; tests and generated files are outside Sources and never ship.
UNTRANSLATED_MODULES = {"MochiMCP"}
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(@|lld|lf)")
# AppKit takes plain strings, so the compiler extracts no literal handed to it and the text would show in English.
APPKIT_TEXT = re.compile(
    r"(?:\.(?:placeholderString|toolTip|title|messageText|informativeText|prompt|message|nameFieldLabel|label"
    r"|paletteLabel)\s*=|setAccessibility(?:Label|Title|Help|Value|RoleDescription)\(|(?:addButton|addItem|insertItem)"
    r"\(withTitle:|NSMenu(?:Item)?\(title:)\s*\"((?:[^\"\\]|\\.)*)\"")
# Interface text the model holds as a plain String, which the compiler extracts nothing from: the notice, error and
# warning lines, the manager's feedback, a reported failure, and a LabeledContent value. A ternary's first branch counts.
MODEL_TEXT = re.compile(
    r"(?:\b(?:notice|error|recordingWarning|feedback|serviceStatus|startupProgress|transfer|progress)\s*=\s*"
    r"(?:[^\"\n=]*\?\s*)?|\breport\(\s*|\bLabeledContent\([^\n]*?\bvalue:\s*)\"((?:[^\"\\]|\\.)*)\"")
# The product name reads the same in every language.
UNTRANSLATED_TEXT = {"Mochi"}


def specifiers(text):
    """The argument types in the order they are consumed; positional forms are put back in argument order."""
    found = [(match.group(1), match.group(2)) for match in SPECIFIER.finditer(text)]
    positional = [(int(index), kind) for index, kind in found if index]
    if positional and len(positional) != len(found):
        raise ValueError(f"mixes positional and sequential specifiers: {text!r}")
    return [kind for _, kind in sorted(positional)] if positional else [kind for _, kind in found]


def shipped(source, sources=SOURCES):
    """Whether the app ships this source file's strings, judged by where the file lives."""
    path = Path(source).resolve()
    # A file deleted since an earlier build leaves its strings data behind; it no longer ships.
    return (
        path.is_relative_to(sources) and path.relative_to(sources).parts[0] not in UNTRANSLATED_MODULES
        and path.is_file()
    )


def name_clashes(sources=SOURCES):
    """The compiler names each strings file after its source file, so two sources with one name overwrite each
    other's strings in the shared folder and one file's strings silently go unchecked."""
    seen = {}
    for path in sorted(sources.rglob("*.swift")):
        if path.relative_to(sources).parts[0] not in UNTRANSLATED_MODULES:
            seen.setdefault(path.name, []).append(str(path.relative_to(sources)))
    return [f"rename one of {', '.join(paths)}: strings files would collide" for paths in seen.values() if len(paths) > 1]


def source_keys(folder, sources=SOURCES):
    """Every key the compiler extracted from the app's own sources."""
    keys = set()
    files = 0
    for path in Path(folder).rglob("*.stringsdata"):
        data = json.loads(path.read_text())
        if not shipped(data.get("source", ""), sources):
            continue
        files += 1
        tables = data.get("tables", {})
        unexpected = set(tables) - {"Localizable"}
        if unexpected:
            raise ValueError(f"{path.name} uses tables {sorted(unexpected)}; Mochi ships only Localizable")
        keys.update(entry["key"] for entry in tables.get("Localizable", []))
    if not files:
        raise ValueError(f"no strings data from {sources} under {folder}; build with -emit-localized-strings first")
    return keys


def released(text):
    """The source as a release build compiles it: lines under `#if MOCHI_DEVELOPMENT` are blanked, so line numbers
    still match the file."""
    lines, development = [], []
    for line in text.split("\n"):
        directive = line.split("//")[0].strip()
        if directive.startswith("#if"):
            development.append(directive == "#if MOCHI_DEVELOPMENT")
        elif directive.startswith("#else") and development:
            development[-1] = False
        elif directive == "#endif" and development:
            development.pop()
        lines.append("" if any(development) else line)
    return "\n".join(lines)


def literal_problems(sources=SOURCES):
    """AppKit text, or interface text the model holds as a String, set from a string literal no translation reaches."""
    problems = []
    for path in sorted(sources.rglob("*.swift")):
        relative = path.relative_to(sources)
        if relative.parts[0] in UNTRANSLATED_MODULES:
            continue
        text = released(path.read_text())
        for match in APPKIT_TEXT.finditer(text):
            if re.search(r"[A-Za-z]", match.group(1)) and match.group(1) not in UNTRANSLATED_TEXT:
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{relative}:{line}: AppKit shows {match.group(1)!r} untranslated; use String(localized:)")
        for match in MODEL_TEXT.finditer(text):
            if re.search(r"[A-Za-z]", match.group(1)) and match.group(1) not in UNTRANSLATED_TEXT:
                line = text.count("\n", 0, match.start()) + 1
                problems.append(
                    f"{relative}:{line}: the interface shows {match.group(1)!r} untranslated; use String(localized:)")
    return sorted(problems, key=lambda problem: (problem.split(":")[0], int(problem.split(":")[1])))


def translation_problems(key, entry):
    if entry.get("shouldTranslate") is False:
        return []
    problems = []
    expected = specifiers(key)
    for language in LANGUAGES:
        unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
        value = unit.get("value", "")
        if unit.get("state") != "translated" or not value.strip():
            problems.append(f"{language}: no translation for {key!r}")
            continue
        try:
            if specifiers(value) != expected:
                problems.append(f"{language}: placeholders differ for {key!r}: {value!r}")
        except ValueError as error:
            problems.append(f"{language}: {error}")
    return problems


def catalog_problems(keys, catalog):
    strings = catalog.get("strings", {})
    if catalog.get("sourceLanguage") != "en":
        return ["the catalog's source language must be en"]
    problems = [f"missing from the catalog: {key!r}" for key in sorted(keys - set(strings))]
    problems += [f"stale (no source uses it): {key!r}" for key in sorted(set(strings) - keys)]
    for key in sorted(keys & set(strings)):
        problems += translation_problems(key, strings[key])
    return problems


def info_plist_problems(catalog, build_script):
    """The English entry is compiled into en.lproj, so it must say what Info.plist says."""
    problems = [f"InfoPlist: {problem}" for problem in catalog_problems(INFO_PLIST_KEYS, catalog)]
    for key in sorted(INFO_PLIST_KEYS):
        match = re.search(rf"<key>{key}</key><string>(.*?)</string>", build_script)
        english = catalog["strings"].get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {})
        if not match or english.get("value") != match.group(1):
            problems.append(f"InfoPlist: the English {key} differs from Info.plist in build-app.sh")
    return problems


def check(folder, catalog_path=CATALOG, info_plist_path=INFO_PLIST_CATALOG, build_script=BUILD_SCRIPT):
    clashes = name_clashes()
    if clashes:
        raise ValueError("\n".join(clashes))
    keys = source_keys(folder)
    problems = catalog_problems(keys, json.loads(Path(catalog_path).read_text()))
    problems += literal_problems()
    problems += info_plist_problems(json.loads(Path(info_plist_path).read_text()), Path(build_script).read_text())
    if any(problem.startswith("stale") for problem in problems):
        problems.append(
            "An incremental build writes strings only for the files it recompiles: keep the strings folder with its "
            "build folder, or build clean, before trusting a stale entry.")
    if problems:
        raise ValueError("\n".join(problems))
    return len(keys)


if __name__ == "__main__":
    if sys.argv[1:] == ["languages"]:
        print(*LANGUAGES)
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        try:
            count = check(sys.argv[2])
        except (OSError, ValueError) as error:
            sys.exit(str(error))
        print(f"{count} strings translated into {', '.join(LANGUAGES)}")
    else:
        sys.exit("usage: localization.py languages | check <folder of .stringsdata from -emit-localized-strings>")
