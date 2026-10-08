"""TALOD data report: what fills TALOD's SavedVariables and its archive.

    python tools/data_report.py                  # every account found (WTF/Account/*/SavedVariables)
    python tools/data_report.py PATH [PATH ...]  # SavedVariables/TALOD.lua files (TALOD_Archive.lua next to each is read too)
    python tools/data_report.py --export DIR     # also write the archive's entries as JSON, one file per kind

SavedVariables are written when you log out or /reload, not live. This tool only
reads them: nothing in the game's files is changed.
"""
import argparse
import importlib.util
import json
import pathlib
import re
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("census_viewer", HERE / "census_viewer.py")
cv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cv)

NAME = cv.NAME
DB_NAME = cv.DB_NAME
ARCHIVE_ADDON = NAME + "_Archive"
ARCHIVE_DB = NAME + "ArchiveDB"

# What each archive kind holds (the cleanup rule that moved it there).
KINDS = {
    "recruitText": "recruit messages (whisper; echo; unsent; chat; echo time)",
    "priceHistory": "earlier Auction House looks of an item",
    "priceUnseen": "price entries of items not seen for months",
    "guildEvents": "guild event log entries",
}


# ---------------------------------------------------------------------------
# Packed values (Store.lua): "" nil, T / F booleans, n<number>, s<text> with
# separators escaped as %XX.
def unescape(s):
    return re.sub(r"%([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), s)


def unpack_value(s):
    if not s:
        return None
    tag, rest = s[0], s[1:]
    if tag == "s":
        return unescape(rest)
    if tag == "n":
        try:
            n = float(rest)
            return int(n) if n.is_integer() else n
        except ValueError:
            return None
    if tag == "T":
        return True
    if tag == "F":
        return False
    return None


def split_list(s, sep):
    return s.split(sep)


def looks(text):
    """A price history string "t:p:n:a:c:b,..." as a list of dicts."""
    out = []
    for part in (text or "").split(","):
        f = part.split(":")
        if len(f) != 6:
            continue
        num = lambda x: (int(float(x)) if float(x).is_integer() else float(x)) if x else None
        try:
            t, p, n, a, c, b = (num(x) for x in f)
        except ValueError:
            continue
        out.append({"t": t, "p": p, "n": n, "a": a, "c": c, "b": b})
    return out


def chat_lines(text, whisper):
    """A packed recruit chat ("#line~line", each "t;me;text;c", W = the opener)."""
    if not text:
        return None
    lines = []
    for raw in text[1:].split("~") if len(text) > 1 else []:
        f = raw.split(";")
        f += [""] * (4 - len(f))
        lines.append({"t": unpack_value(f[0]), "me": unpack_value(f[1]),
                      "text": whisper if f[2] == "W" else unpack_value(f[2]), "c": unpack_value(f[3])})
    return lines


def event(text):
    f = (text or "").split("|") + [""] * 5
    return {"t": unpack_value(f[0]), "k": unpack_value(f[1]), "a": unpack_value(f[2]),
            "b": unpack_value(f[3]), "rank": unpack_value(f[4])}


def decode_value(kind, value):
    """An archived value in readable form."""
    if not isinstance(value, str):
        return value
    if kind == "recruitText":
        f = value.split(";") + [""] * 5
        whisper = unpack_value(f[0])
        echo = unpack_value(f[1])
        return {"whisper": whisper, "echo": echo, "unsent": unpack_value(f[2]),
                "chat": chat_lines(unpack_value(f[3]), whisper), "echoT": unpack_value(f[4])}
    if kind == "priceHistory":
        return looks(value)
    if kind == "priceUnseen":
        f = value.split(";") + [""] * 8
        return {"p": unpack_value(f[0]), "t": unpack_value(f[1]), "n": unpack_value(f[2]), "a": unpack_value(f[3]),
                "name": unpack_value(f[4]), "c": unpack_value(f[5]), "history": looks(unpack_value(f[6])),
                "days": unpack_value(f[7])}
    if kind == "guildEvents":
        return event(value)
    return value


def archive_entries(archive, kind):
    """[{t, c, key, value}] of one kind, oldest first."""
    out = []
    for raw in cv.as_list((archive.get("stores") or {}).get(kind)):
        if not isinstance(raw, str):
            continue
        f = raw.split("|") + [""] * 4
        out.append({"t": unpack_value(f[0]), "c": unpack_value(f[1]), "key": unpack_value(f[2]),
                    "value": decode_value(kind, unpack_value(f[3]))})
    return out


# ---------------------------------------------------------------------------
# Sizes
def weigh(value, seen=None):
    """(estimated bytes in game memory, tables). Lua 5.1 on a 64-bit client: a table header, 40 bytes per
    hash slot (slots rounded up to a power of two), 16 per array slot, a string's header plus its text
    (once: the game keeps one copy of equal strings). `seen` is shared between stores."""
    size, tables = 0, 0
    seen = set() if seen is None else seen
    stack = [value]
    while stack:
        v = stack.pop()
        if isinstance(v, dict):
            tables += 1
            slots = 1
            while slots < len(v):
                slots *= 2
            size += 56 + 40 * slots if v else 56
            for k, x in v.items():
                if isinstance(k, str) and k not in seen:
                    seen.add(k)
                    size += 25 + len(k)
                stack.append(x)
        elif isinstance(v, list):
            tables += 1
            size += 56 + 16 * len(v)
            stack.extend(v)
        elif isinstance(v, str) and v not in seen:
            seen.add(v)
            size += 25 + len(v)
    return size, tables


def estimate_mb(size):
    return size / (1024 * 1024)


def report(db, archive, path):
    lines = [f"{path}", ""]
    rows, seen = [], set()
    for key, value in db.items():
        if isinstance(value, (dict, list)):
            size, tables = weigh(value, seen)
            rows.append((estimate_mb(size), key, tables))
    rows.sort(reverse=True)
    total = sum(r[0] for r in rows) or 1
    lines.append(f"Saved data, largest first (about {sum(r[0] for r in rows):.1f} MB of game memory):")
    for mb, key, tables in rows[:15]:
        lines.append(f"  {mb:7.2f} MB  {100 * mb / total:4.0f}%  {key}  ({tables} tables)")
    packed = plain = 0
    for g in ((db.get("guild") or {}).get("guilds") or {}).values():
        for r in (g.get("recruits") or {}).values():
            if isinstance(r, dict):
                packed, plain = (packed + 1, plain) if "x" in r else (packed, plain + 1)
    if packed or plain:
        lines.append(f"  recruit records: {packed} packed, {plain} plain")
    lines.append("")
    if archive is None:
        lines.append(f"Archive: no {ARCHIVE_ADDON}.lua next to it (not installed, or never loaded).")
    else:
        lines.append("Archive:")
        for kind in sorted((archive.get("stores") or {})):
            entries = archive_entries(archive, kind)
            times = [e["t"] for e in entries if isinstance(e["t"], (int, float))]
            span = (f", moved {time.strftime('%Y-%m-%d', time.localtime(min(times)))}"
                    f" to {time.strftime('%Y-%m-%d', time.localtime(max(times)))}") if times else ""
            lines.append(f"  {kind}: {len(entries)} entries{span}  ({KINDS.get(kind, 'unknown kind')})")
    return "\n".join(lines)


def read_pair(path):
    sv = cv.read_saved_variables(path)
    db = sv.get(DB_NAME) or {}
    archive_path = path.with_name(ARCHIVE_ADDON + ".lua")
    archive = cv.read_saved_variables(archive_path).get(ARCHIVE_DB) if archive_path.exists() else None
    return db, archive


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", type=pathlib.Path, help=f"{NAME}.lua SavedVariables files (default: all accounts)")
    ap.add_argument("--export", type=pathlib.Path, help="folder to write the archive's entries to, as JSON")
    args = ap.parse_args(argv)
    paths = args.paths or cv.find_saved_variables()
    if not paths:
        print(f"No {NAME} SavedVariables found. Pass the file (WTF/Account/<account>/SavedVariables/{NAME}.lua) "
              "or set WOW_DIR to your game folder.")
        return 1
    for path in paths:
        db, archive = read_pair(path)
        print(report(db, archive, path))
        print()
        if args.export and archive is not None:
            account = path.parent.parent.name
            out = args.export / account
            out.mkdir(parents=True, exist_ok=True)
            for kind in (archive.get("stores") or {}):
                target = out / f"{kind}.json"
                target.write_text(json.dumps(archive_entries(archive, kind), indent=1, ensure_ascii=False), encoding="utf-8")
                print(f"  wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
