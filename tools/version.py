"""The addon's version: version.json is the record, the TOC carries it into the game.

version.json holds the current version, the date it was set and a history of
every bump (newest first). The game reads the version from the TOC's
`## Version` line (Core.lua: ns.VERSION), so a bump writes both, and stamps the
CHANGELOG's "## Unreleased" section with the new version and date. A bump
changes nothing while "## Unreleased" is empty.

    python tools/version.py                      # show the version, check TOC / CHANGELOG agree
    python tools/version.py bump [patch|minor|major] [-m "what changed"]
    python tools/version.py set 1.0.0 [-m "..."]
    python tools/version.py check                # exit 1 when TOC, version.json and CHANGELOG disagree

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
    return found


def apply(new, note):
    data = load()
    old = data.get("version")
    # Nothing changes unless the changelog can say what this version is.
    unready = changelog_unready()
    if unready:
        sys.exit(f"CHANGELOG: {unready}. Version left at {old}.")
    today = datetime.date.today().isoformat()
    entry = {"version": new, "date": today, "from": old}
    if note:
        entry["note"] = note
    data["version"], data["date"] = new, today
    data["history"] = [entry] + list(data.get("history") or [])
    save(data)
    write_toc(new)
    stamp_changelog(new, today)
    print(f"{old} -> {new} ({today})")


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
    args = parser.parse_args()

    if args.cmd == "bump":
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
