"""The addon's version: version.json is the record, the TOC carries it into the game.

version.json holds the current version, the date it was set and a history of
every bump (newest first). The game reads the version from the TOC's
`## Version` line (Core.lua: ns.VERSION), so a bump writes both, and stamps the
CHANGELOG's "## Unreleased" section with the new version and date. A bump
changes nothing while "## Unreleased" is empty.

changelogs/ holds one player-facing summary per version (<version>.md), ready
to copy into an upload page or an announcement. The next version's summary is
written in changelogs/Unreleased.md; a bump turns it into <version>.md (with
its heading and "Changes since <previous>.") and refuses while it is missing
or empty. The game shows them on the Changelog page: ChangelogData.lua is
built from the folder by every bump and by "notes". Each summary is checked
for words that never go to players (LEAK in build_release.py, PRIVATE here).

    python tools/version.py                      # show the version, check TOC / CHANGELOG agree
    python tools/version.py bump [patch|minor|major] [-m "what changed"]
    python tools/version.py set 1.0.0 [-m "..."]
    python tools/version.py check                # exit 1 when TOC, version.json and CHANGELOG disagree
    python tools/version.py notes                # rebuild ChangelogData.lua from changelogs/ (after an edit)

patch = fixes and small changes, minor = new features or settings, major = breaking
changes (saved data no longer readable by older versions, removed commands).
"""
import argparse
import datetime
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "version.json"
CHANGELOG = ROOT / "CHANGELOG.md"
NOTES_DIR = ROOT / "changelogs"
NEXT_NOTES = NOTES_DIR / "Unreleased.md"
NOTES_DATA = ROOT / "ChangelogData.lua"
NOTES_HEAD = re.compile(r"^# \S+ (\d+\.\d+\.\d+) — ([^\n]+?)[ \t]*\n(?:\nChanges since (\d+\.\d+\.\d+)\.[ \t]*\n)?")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
TOC_RE = re.compile(r"^## Version:[ \t]*(\S*)", re.M)


def read(path):
    # Bytes, not read_text: keeps the file's own line endings (CRLF or LF) when written back.
    return path.read_bytes().decode("utf-8")


def toc_path():
    return next(ROOT.glob("*.toc"))


def toc_version():
    m = TOC_RE.search(read(toc_path()))
    return m.group(1) if m else None


def load():
    if VERSION_FILE.exists():
        return json.loads(VERSION_FILE.read_text(encoding="utf-8"))
    # First run: adopt what the TOC says.
    return {"version": toc_version() or "0.1.0", "date": None, "history": []}


def save(data):
    VERSION_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_toc(version):
    path = toc_path()
    text = read(path)
    if TOC_RE.search(text):
        text = TOC_RE.sub("## Version: " + version, text, count=1)
    else:
        nl = "\r\n" if "\r\n" in text else "\n"
        text = text.replace(nl, nl + "## Version: " + version + nl, 1)
    path.write_bytes(text.encode("utf-8"))


def unreleased(text):
    return re.search(r"^## Unreleased[ \t]*\r?\n(.*?)(?=^## |\Z)", text, re.M | re.S)


def changelog_unready():
    if not CHANGELOG.exists():
        return "no CHANGELOG.md"
    m = unreleased(read(CHANGELOG))
    if not m:
        return "no '## Unreleased' section"
    if not m.group(1).strip():
        return "'## Unreleased' is empty: write what changed there first"
    return None


def stamp_changelog(version, date):
    """Turns "## Unreleased" into "## <version> — <date>" and opens a fresh, empty Unreleased."""
    text = read(CHANGELOG)
    m = unreleased(text)
    nl = "\r\n" if "\r\n" in text else "\n"
    heading = f"## Unreleased{nl}{nl}## {version} — {date}{nl}"
    text = text[:m.start()] + heading + text[m.start(1):]
    CHANGELOG.write_bytes(text.encode("utf-8"))


def changelog_has(version):
    if not CHANGELOG.exists():
        return False
    return re.search(r"^## " + re.escape(version) + r"\b", read(CHANGELOG), re.M) is not None


# ---------------------------------------------------------------------------
# Version summaries (changelogs/)
# ---------------------------------------------------------------------------

# Never in a summary: files and tools players never get, and details that would
# help someone attack a release or the shared data. Assistant names: build_release.LEAK.
PRIVATE = re.compile("|".join([
    r"\.git\w*", r"\.pkgmeta", r"\bAGENT(S\b|_)",r"CHANGELOG\.md", r"SIGN_RELEASE", r"version\.json", r"version\.py",
    r"build_release", r"release_sign", r"build\.sh", r"\btests?/", r"run\.py", r"wowmock", r"\bdocs/",
    r"gen_\w+\.py", r"\bdist/", r"Release\.lua", r"Signature\.lua", r"\bRSA\b", r"Montgomery", r"\bmodulus\b",
    r"exponent", r"(private|public|signing|release) key", r"\bkeygen\b", r"sign-package", r"(?-i:\bsalt\b)", r"checksum",
    r"\bdigest\b", r"\bhash", r"\bexploit", r"\bbypass",
]), re.I)


def notes_leaks(name, text):
    sys.path.insert(0, str(ROOT / "tools"))
    import build_release
    found = []
    for n, line in enumerate(text.splitlines(), 1):
        for pattern in (build_release.LEAK, PRIVATE):
            m = pattern.search(line)
            if m:
                found.append(f"{name}:{n}: {m.group(0)!r}")
    return found


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def notes_files():
    """[(version, path)] newest first."""
    found = [(p.stem, p) for p in NOTES_DIR.glob("*.md") if VERSION_RE.match(p.stem)]
    return sorted(found, key=lambda e: version_key(e[0]), reverse=True)


def notes_text(path):
    return read(path).replace("\r\n", "\n")


def notes_unready():
    where = NEXT_NOTES.relative_to(ROOT).as_posix()
    if not NEXT_NOTES.exists() or not notes_text(NEXT_NOTES).strip():
        return f"{where} is missing or empty: write the summary of this update there first"
    leaks = notes_leaks(where, notes_text(NEXT_NOTES))
    if leaks:
        return f"{where} names things players never see:\n  " + "\n  ".join(leaks)
    return None


def write_notes(version, date, old):
    """changelogs/Unreleased.md -> changelogs/<version>.md under its heading."""
    head = f"# {toc_path().stem} {version} — {date}\n\n"
    if old:
        head += f"Changes since {old}.\n\n"
    body = notes_text(NEXT_NOTES).strip("\n")
    (NOTES_DIR / f"{version}.md").write_bytes((head + body + "\n").encode("utf-8"))
    NEXT_NOTES.unlink()


def slash_prefix():
    m = re.search(r'^Cmd\.PREFIX\s*=\s*"([^"]+)"', read(ROOT / "Commands.lua"), re.M)
    return m.group(1) if m else None


def lua_long_string(text):
    level = 0
    while "]" + "=" * level + "]" in text:
        level += 1
    eq = "=" * level
    return "[" + eq + "[\n" + text + "]" + eq + "]"


def notes_data():
    """ChangelogData.lua. The addon's name and slash prefix become {name} / {cmd}:
    Lua never spells them (Changelog.lua puts ns.NAME and the prefix back)."""
    name, prefix = toc_path().stem, slash_prefix()
    entries = []
    for version, path in notes_files():
        text = notes_text(path)
        m = NOTES_HEAD.match(text)
        date, old = (m.group(2), m.group(3)) if m else (None, None)
        body = (text[m.end():] if m else text).strip("\n")
        if prefix:
            body = body.replace(prefix, "{cmd}")
        body = body.replace(name, "{name}")
        fields = [f'v = "{version}"']
        if date:
            fields.append(f'd = "{date}"')
        if old:
            fields.append(f'from = "{old}"')
        entries.append("    { " + ", ".join(fields) + ", text = " + lua_long_string(body) + " },")
    return ("-- Generated by tools/version.py from changelogs/ (one summary per version). Do not edit:\n"
            "-- change the summary, then run tools/version.py notes.\n"
            "-- {name} and {cmd} stand for the addon's name and slash prefix (Changelog.lua fills them in).\n\n"
            "local ADDON_NAME, ns = ...\n\n"
            "-- Newest first.\n"
            "ns.CHANGELOGS = {\n" + "\n".join(entries) + "\n}\n")


def write_notes_data():
    NOTES_DATA.write_bytes(notes_data().encode("utf-8"))


def notes_problems(version=None):
    if not NOTES_DIR.exists():
        return ["no changelogs/ folder"]
    found = []
    if version and not (NOTES_DIR / f"{version}.md").exists():
        found.append(f"changelogs/{version}.md is missing (the summary of the current version)")
    paths = [p for _, p in notes_files()] + ([NEXT_NOTES] if NEXT_NOTES.exists() else [])
    for path in paths:
        found += notes_leaks("changelogs/" + path.name, notes_text(path))
    if not NOTES_DATA.exists() or notes_text(NOTES_DATA) != notes_data():
        found.append("ChangelogData.lua does not match changelogs/: run python tools/version.py notes")
    return found


def problems():
    found = []
    if not VERSION_FILE.exists():
        return ["version.json is missing: run python tools/version.py bump"]
    data = load()
    version = data.get("version")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        found.append(f"version.json version {version!r} is not MAJOR.MINOR.PATCH")
    if toc_version() != version:
        found.append(f"TOC says {toc_version()!r}, version.json says {version!r}: run python tools/version.py set {version}")
    if not changelog_has(version):
        found.append(f"CHANGELOG.md has no '## {version}' section")
    return found + notes_problems(version)


def apply(new, note):
    data = load()
    old = data.get("version")
    # Nothing changes unless the changelog can say what this version is.
    unready = changelog_unready()
    if unready:
        sys.exit(f"CHANGELOG: {unready}. Version left at {old}.")
    unready = notes_unready()
    if unready:
        sys.exit(f"Summary: {unready}\nVersion left at {old}.")
    today = datetime.date.today().isoformat()
    entry = {"version": new, "date": today, "from": old}
    if note:
        entry["note"] = note
    data["version"], data["date"] = new, today
    data["history"] = [entry] + list(data.get("history") or [])
    save(data)
    write_toc(new)
    stamp_changelog(new, today)
    write_notes(new, today, old)
    write_notes_data()
    print(f"{old} -> {new} ({today}), summary in changelogs/{new}.md")


def bumped(version, part):
    major, minor, patch = (int(x) for x in version.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd")
    b = sub.add_parser("bump")
    b.add_argument("part", nargs="?", default="patch", choices=["patch", "minor", "major"])
    b.add_argument("-m", "--note", default=None)
    s = sub.add_parser("set")
    s.add_argument("version")
    s.add_argument("-m", "--note", default=None)
    sub.add_parser("check")
    sub.add_parser("notes")
    args = parser.parse_args()

    if args.cmd == "notes":
        write_notes_data()
        found = notes_problems()
        print(f"ChangelogData.lua: {len(notes_files())} versions")
        for p in found:
            print("FAIL", p)
        sys.exit(1 if found else 0)
    elif args.cmd == "bump":
        apply(bumped(load()["version"], args.part), args.note)
    elif args.cmd == "set":
        if not VERSION_RE.match(args.version):
            sys.exit("version must be MAJOR.MINOR.PATCH")
        if args.version == load().get("version") and VERSION_FILE.exists():
            write_toc(args.version)  # resync only
            print("TOC set to", args.version)
        else:
            apply(args.version, args.note)
    else:
        found = problems()
        if args.cmd is None:
            data = load()
            print(f"{data.get('version')} (set {data.get('date') or '?'})")
        for p in found:
            print("FAIL", p)
        sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
