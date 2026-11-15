#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the Swift-SQLite developer kit: files, manifests, links, recipes, pins.

Runs offline and changes nothing. Exits nonzero with one line per problem.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugins/swift-sqlite"
SKILL = PLUGIN / "skills/swift-sqlite"
KIT_VERSION = "0.3.0"
LIBRARY_VERSION = "1.1.0"
NAME = "swift-sqlite"
MAX_FILE_BYTES = 200_000
REQUIRED = [
    "LICENSE", "plugin.json", ".claude-plugin/plugin.json",
    "skills/swift-sqlite/SKILL.md", "skills/swift-sqlite/LICENSE",
    "skills/swift-sqlite/references/versions.md",
    "skills/swift-sqlite/references/semantics.md",
    "skills/swift-sqlite/references/recipes.md",
    "skills/swift-sqlite/references/troubleshooting.md",
    "skills/swift-sqlite/references/installation.md",
    "skills/swift-sqlite/references/compatibility.json",
    "skills/swift-sqlite/assets/consumer/Package.swift",
    "skills/swift-sqlite/assets/consumer/Sources/Consumer/Consumer.swift",
]
PRIVATE_PATTERNS = [re.compile(p) for p in (r"/Users/", r"/home/[a-z]", r"C:\\\\Users", r"\.claude/projects")]

problems = []


class KitError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise KitError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    require(not name.startswith("/") and ".." not in Path(name).parts, "unsafe archive path " + name)


def files(root):
    """Every distributable file under root, as {relative path: bytes}, skipping build output."""
    out = {}
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.is_dir() or any(part in (".build", ".swiftpm", "Package.resolved") for part in Path(rel).parts):
            continue
        require(not path.name.startswith(".") or rel.startswith(".claude-plugin/"), "unexpected hidden file " + rel)
        out[rel] = path.read_bytes()
    return out


def problem(message):
    problems.append(message)


def check_manifests():
    portable = json.loads((PLUGIN / "plugin.json").read_text())
    claude = json.loads((PLUGIN / ".claude-plugin/plugin.json").read_text())
    market = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
    entry = next((p for p in market.get("plugins", []) if p.get("name") == NAME), None)
    if entry is None:
        problem("marketplace.json has no swift-sqlite plugin")
        return
    if entry.get("source") != "./plugins/swift-sqlite":
        problem("marketplace source must be ./plugins/swift-sqlite")
    for label, manifest in (("plugin.json", portable), (".claude-plugin/plugin.json", claude), ("marketplace", entry)):
        if manifest.get("name") != NAME:
            problem(label + ": name must be " + NAME)
        if manifest.get("version") != KIT_VERSION:
            problem(label + ": version must be " + KIT_VERSION)
        if manifest.get("description") != portable.get("description"):
            problem(label + ": description differs from plugin.json")
        if LIBRARY_VERSION not in manifest.get("description", ""):
            problem(label + ": description must name library " + LIBRARY_VERSION)


def check_skill():
    text = (SKILL / "SKILL.md").read_text()
    match = re.match(r"^---\nname: (.+)\ndescription: \"(.+)\"\n---\n", text)
    if not match:
        problem("SKILL.md needs front matter with name and a quoted description")
        return
    if match.group(1) != NAME:
        problem("SKILL.md name must be " + NAME)
    if len(match.group(2)) > 1024:
        problem("SKILL.md description exceeds 1024 characters")
    for needle in ("kit " + KIT_VERSION, "library **" + LIBRARY_VERSION + "**"):
        if needle not in text:
            problem("SKILL.md must mention '" + needle + "'")
    if len(text.splitlines()) > 500:
        problem("SKILL.md is longer than 500 lines; move detail into references")


def check_links():
    for path in sorted(list(SKILL.rglob("*.md")) + [ROOT / "Documentation/AgentDeveloperKit.md"]):
        for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", path.read_text()):
            if re.match(r"^[a-z]+://", target):
                continue
            if not (path.parent / target).resolve().exists():
                problem(path.relative_to(ROOT).as_posix() + ": broken link " + target)


def check_recipes():
    source = (SKILL / "assets/consumer/Sources/Consumer/Consumer.swift").read_text()
    markers = re.findall(r"^// RECIPE ([a-z0-9-]+)$", source, re.MULTILINE)
    table = re.findall(r"^\| ([a-z0-9-]+) / ", (SKILL / "references/recipes.md").read_text(), re.MULTILINE)
    compat = json.loads((SKILL / "references/compatibility.json").read_text())
    if len(markers) != len(set(markers)):
        problem("duplicate RECIPE markers in Consumer.swift")
    if markers != table:
        problem("recipes.md table and Consumer.swift markers differ: %s vs %s" % (table, markers))
    if markers != compat.get("recipes"):
        problem("compatibility.json recipes differ from Consumer.swift markers")
    if compat.get("kit_version") != KIT_VERSION or compat.get("library", {}).get("tag") != LIBRARY_VERSION:
        problem("compatibility.json must pin kit %s to library %s" % (KIT_VERSION, LIBRARY_VERSION))
    package = (SKILL / "assets/consumer/Package.swift").read_text()
    if 'exact: "%s"' % LIBRARY_VERSION not in package:
        problem("consumer Package.swift must pin exact %s" % LIBRARY_VERSION)
    if "```swift" in "".join(p.read_text() for p in SKILL.rglob("*.md")):
        problem("Swift code belongs in the compiled consumer, not in Markdown fences")


def check_hygiene():
    for rel, data in files(PLUGIN).items():
        if len(data) > MAX_FILE_BYTES:
            problem(rel + ": larger than %d bytes" % MAX_FILE_BYTES)
        text = data.decode("utf-8", errors="replace")
        for pattern in PRIVATE_PATTERNS:
            if pattern.search(text):
                problem(rel + ": contains a private path (" + pattern.pattern + ")")
    if (PLUGIN / "LICENSE").read_bytes() != (ROOT / "LICENSE").read_bytes():
        problem("plugin LICENSE differs from the repository LICENSE")
    if (SKILL / "LICENSE").read_bytes() != (ROOT / "LICENSE").read_bytes():
        problem("skill LICENSE differs from the repository LICENSE")


def validate_plugin(root=PLUGIN):
    for rel in REQUIRED:
        require((root / rel).is_file(), "missing " + rel)
    try:
        files(root)
    except KitError as error:
        problem(str(error))
    check_manifests()
    check_skill()
    check_links()
    check_recipes()
    check_hygiene()
    if problems:
        raise KitError("\n".join(problems))


def main():
    try:
        validate_plugin()
    except KitError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    print("developer kit %s (library %s): valid" % (KIT_VERSION, LIBRARY_VERSION))


if __name__ == "__main__":
    main()
