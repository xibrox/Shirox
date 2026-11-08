#!/usr/bin/env python3
"""The SF Symbols Shirox uses, as the list icon packs are made against.

    python3 -I scripts/icons/icons.py update   # rewrites iconpacks/icons.json (macOS: needs the
                                               # system's SF Symbols list); bumps its version when
                                               # the set of icons changes
    python3 -I scripts/icons/icons.py check    # fails if the code uses a symbol icons.json lacks

An icon is any string literal in the Swift sources that names a real SF Symbol, wherever it sits:
`Image(systemName:)`, `Label(…, systemImage:)`, an enum's `icon` property, either side of a
ternary. Names put together at runtime ("\\(name).fill") can't be found this way; write the
full names out as literals instead.

The packs themselves live in the website repo (github.com/shiroxapp/shiroxapp.github.io, under
static/iconpacks/), published at https://shiroxapp.github.io/iconpacks/<pack>/pack.json. Its
`bun run iconpacks check` and `bun run iconpacks build <pack>` read this icons.json from GitHub,
so a version bump here shows up there as packs that need updating. The pack format:

    { "name": "Font Awesome", "author": "Fonticons, Inc.", "license": "CC BY 4.0",
      "website": "https://fontawesome.com",
      "url": "https://shiroxapp.github.io/iconpacks/fontawesome/pack.json",
      "iconsVersion": 3, "packVersion": 2,
      "icons": { "house.fill": "icons/house.fill.pdf", … } }

`url` is where the pack's own pack.json is published, and the icon paths are relative to it: the
app downloads a pack from that address and checks it there for updates (a higher packVersion).
`iconsVersion` is the icons.json version the pack was made for. The app loads a pack only when
it matches the version it ships with, so a pack missing new icons is never half applied; bump
`packVersion` with every change to a pack so installed copies update. Icons are tinted like
symbols; a pack drawn in colour sets `"multicolor": true` to keep its own colours (builds from
before that flag show such a pack as tinted shapes).
"""
import glob
import json
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SOURCES = os.path.join(ROOT, "Shirox")
MANIFEST = os.path.join(ROOT, "iconpacks", "icons.json")
SF_SYMBOLS = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"

LITERAL = re.compile(r'"([a-z0-9]+(?:\.[a-z0-9]+)*)"')
# Where a literal is an icon whatever it names: for `check`, which also runs without the
# system's symbol list (CI on Linux).
ICON_CONTEXT = re.compile(r'(?:systemName|systemImage|icon|symbol)\s*:\s*"([^"]+)"')


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def swift_lines():
    for path in sorted(glob.glob(os.path.join(SOURCES, "**", "*.swift"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if not line.strip().startswith("//"):
                    yield os.path.relpath(path, ROOT), number, line


def system_symbols():
    if not os.path.exists(SF_SYMBOLS):
        sys.exit("update needs macOS: the SF Symbols list comes from CoreGlyphs.bundle")
    with open(SF_SYMBOLS, "rb") as f:
        return set(plistlib.load(f)["symbols"])


# Declarations whose body names icons: `var icon: String`, `func symbol(for:)`, `systemImage`.
ICON_DECLARATION = re.compile(r'\b(?:var|func|let)\s+\w*(?:icon|Icon|symbol|Symbol|systemImage|systemName)\w*')
DECLARATION = re.compile(r'^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|override)\s+)*(?:var|func|let|init|struct|enum|class)\b')


def used_icons(known):
    """Names with a dot are icons wherever they are ("house.fill" is nothing else). A bare word
    ("house", but also "left" or "case") counts only where icons are named: an icon parameter,
    or inside a property or function whose name says it returns one."""
    found = set()
    in_icon_body = False
    current = None
    for rel, _, line in swift_lines():
        if rel != current:
            current, in_icon_body = rel, False
        if DECLARATION.match(line):
            in_icon_body = bool(ICON_DECLARATION.search(line))
        context = in_icon_body or ICON_CONTEXT.search(line) or "systemName" in line or "systemImage" in line
        for match in LITERAL.finditer(line):
            name = match.group(1)
            if name in known and ("." in name or context):
                found.add(name)
    return sorted(found)


def cmd_update(_):
    icons = used_icons(system_symbols())
    manifest = load_json(MANIFEST, {"version": 0, "icons": []})
    if icons != manifest.get("icons"):
        added = sorted(set(icons) - set(manifest.get("icons", [])))
        removed = sorted(set(manifest.get("icons", [])) - set(icons))
        manifest = {"version": manifest.get("version", 0) + 1, "icons": icons}
        write_json(MANIFEST, manifest)
        write_swift_manifest(manifest)
        print(f"icons.json is version {manifest['version']}: {len(icons)} icons "
              f"(+{len(added)} -{len(removed)})")
        for name in added:
            print(f"  + {name}")
        for name in removed:
            print(f"  - {name}")
        print("Packs made for the previous version won't load until they're updated.")
    else:
        write_swift_manifest(manifest)
        print(f"icons.json is up to date: version {manifest['version']}, {len(icons)} icons")


def cmd_check(_):
    manifest = load_json(MANIFEST, None)
    if manifest is None:
        sys.exit("iconpacks/icons.json is missing: run `icons.py update`")
    listed = set(manifest["icons"])
    problems = []
    if os.path.exists(SF_SYMBOLS):
        missing = sorted(set(used_icons(system_symbols())) - listed)
        problems += [f"icon \"{name}\" isn't in iconpacks/icons.json" for name in missing]
    for rel, number, line in swift_lines():
        for match in ICON_CONTEXT.finditer(line):
            name = match.group(1)
            if "\\(" in name:
                problems.append(f"{rel}:{number}: icon name built at runtime: write each one out")
            elif LITERAL.fullmatch(f'"{name}"') and name not in listed and "." in name:
                problems.append(f"{rel}:{number}: icon \"{name}\" isn't in iconpacks/icons.json")
    for problem in sorted(set(problems)):
        print(problem)
    if problems:
        print("\nRun `python3 -I scripts/icons/icons.py update` and bump the packs.")
        sys.exit(1)
    print(f"icons: all {len(listed)} icons are listed (version {manifest['version']})")


def write_swift_manifest(manifest):
    """The version the app checks packs against, compiled in."""
    path = os.path.join(SOURCES, "Services", "IconManifest.swift")
    with open(path, "w", encoding="utf-8") as f:
        f.write("// Generated by scripts/icons/icons.py update; don't edit.\n\n")
        f.write("/// The icons.json version this build was made with: icon packs for any other\n")
        f.write("/// version aren't loaded.\n")
        f.write("enum IconManifest {\n")
        f.write(f"    static let version = {manifest['version']}\n")
        f.write(f"    static let count = {len(manifest['icons'])}\n")
        f.write("}\n")


COMMANDS = {"update": cmd_update, "check": cmd_check}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
