"""Saved data across an update and back (tests/run.py runs it; also on its own):

    python tests/cross_version.py              # the checks below, against the commit in BASE
    python tests/cross_version.py --survey     # what each old scenario leaves in the saved table

An update may arrive by a plain /reload, even one that loads some files of the
old version and some of the new while they are being copied. So:
  (a) the old version plays a session on a rich saved file (built from the old
      version's own scenarios) and logs out;
  (b) the new version loads that file with its new texture files missing (a
      /reload does not see them): no error, every page, tab and view builds,
      and after its logout every key holds what the old version would have
      left itself (only the new settings with their defaults are added);
  (c) the old version loads what the new one saved: no error, its pages build,
      nothing is lost or changed (the new settings stay for the way back);
  (d) a second load of the new version on (c) ends where it would have without
      the trip back;
  (e) mixed loads: the new version with one old file, the old one with one new
      file, and quarter / half / three-quarter copied sets (in load order and
      by name): whatever breaks, the stores (every Store.DEFS key, the
      character table, the archive) are left as a whole version would leave
      them, and a full new load afterwards ends where it would have without
      the mixed one. With the TOC still old (it is copied last) nothing else
      changes either; with the new TOC beside an old file that fails to load,
      that module's settings go back to their defaults (set aside in
      store.quarantine), never a store.
(a) to (d) run on both clients (Era, Forever). The old version is read from
git (`git archive BASE`); without git or the commit (a release package) the
check says SKIP. Update BASE (and the two versions) at each release.
"""
import io
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

from lupa import lua51

TESTS = pathlib.Path(__file__).resolve().parent
REPO = TESTS.parent
# The version players run before this update (what a /reload replaces).
BASE = "2e86a93"
OLD_VERSION, NEW_VERSION = "0.30.1", "0.31.0"
FIXED_NOW = 1790000000
VERBOSE = "-v" in sys.argv

# Keys the new version adds, with their defaults (None: set at login, any
# value). Anything else it adds, drops or changes is a failure.
NEW_KEYS = {
    "classicLook": "false",
    "textSize": "12",
    "compactRows": "false",
    "navMovedSeen": None,   # set at the first login (an install without the old pages never sees the notice)
    "navLast": None,        # the page /talod reopens
}

# Checked on its own: it must stay empty.
SKIP_TOP = {"errorLog"}

# Each key of the rich file from the old scenarios that fill it (merged: maps
# key by key, of two lists the longer); every other key from the richest of
# these runs. Short enough to stay fast.
FIXTURE = {
    "players": ["alert_rules", "vanish_heuristic"],
    "journal": ["alert_rules", "vanish_heuristic"],
    "census": ["guild_recruit", "groups_raid_and_short"],
    "gear": ["gear_ledger", "gear_conditions", "enhance_view"],
    "skills": ["skills_forever_professions", "crafting_log", "skills_c_skillinfo"],
    "economy": ["econ_r5_sell_rate_effective", "economy_tracking", "auction_post_item_quantity"],
    "prices": ["large_data_background", "price_chart"],
    "ladders": ["large_data_background", "auction_desk_modern"],
    "ahOwned": ["auction_desk_ladder"],
    "ahBids": ["econ_stats_pages"],
    "ahScanLog": ["ah_helper_modern"],
    "ahFullScan": ["ah_helper"],
    "fishing": ["fishing_lure_id", "fishing_goals_checklist", "fishing_safety_targeting"],
    "craftTrack": ["crafttrack_reagent_bag"],
    "fishSwap": ["fishing_safety_weapon_row"],
    # Live and cold recruits with the text dictionary, the event log, replies.
    "guild": ["pack_recruits", "guild_recruiters", "lag_recruit_order", "guild_whisper_queue"],
    "guildActivity": ["store_seal"],
    "groups": ["groups_party_record", "groups_raid_and_short"],
    "guildShare": ["store_guild_member_sends_seals"],
    "audit": ["audit_share_officer", "audit_flags"],
    "chars": ["store_chars_and_tags"],
    # The legacy log, set-asides and a store parked by a newer version.
    "store": ["store_legacy"],
    "guildMessages": ["version_updated"],
    "guildMyNames": ["guild_forever_split_names"],
    "profPlanTargets": ["profession_plan"],
    "profPlanFrom": ["profession_plan"],
    "profPlanExcluded": ["craft_costs_unknown_price"],
    "navPos": ["navigation"],
    "<archive>": ["archive_prices_come_back", "archive_waits_then_moves", "archive_guild_events",
                  "archive_commands_and_page"],
}
# Settings away from their defaults (each must come back as it was).
SETTINGS = {
    "colorblind": "true", "panelScale": "1.25", "panelRows": "7", "alertSoundChoice": '"raid"',
    "minimapAngle": "33", "enhanceHidden": '{["Tailoring"]=true,}', "enhanceMineOnly": "true",
    "journalMax": "1500", "guildInactiveDays": "21", "fishMaxCasts": "12000", "cleanAuto": "false",
    "memoryCapMB": "200", "versionCheck": "false",
}


def git(*args):
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, check=True).stdout


def old_tree(dest):
    """The old version's files under dest/<addon folder>; None when git or the commit is missing."""
    try:
        git("cat-file", "-e", BASE + "^{commit}")
        data = git("archive", "--format=tar", BASE)
    except (OSError, subprocess.CalledProcessError):
        return None
    # The addon's folder name comes from its TOC, not from where the checkout sits.
    root = pathlib.Path(dest) / next(REPO.glob("*.toc")).stem
    root.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(root, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    return root


def toc_files(root):
    toc = next(root.glob("*.toc"))
    out = []
    for line in toc.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line.replace("\\", "/"))
    return out


def file_set(root):
    return [(f, (root / f).as_posix()) for f in toc_files(root)]


def fixed_clock(lua):
    lua.execute(f"local real = os.time; os.time = function(t) if t then return real(t) end return {FIXED_NOW} end")


def runtime(addon_dir):
    """A fresh game: the mock (this repository's, the newest), the driver, a fixed clock."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    fixed_clock(lua)
    g = lua.globals()
    g.ADDON_DIR = addon_dir
    g.ADDON_NAME = pathlib.Path(addon_dir).name
    lua.execute((TESTS / "wowmock.lua").read_text(encoding="utf-8"))
    lua.execute((TESTS / "cross_version.lua").read_text(encoding="utf-8"))
    return lua


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def db_text(db):
    if db is None:
        return "nil"
    return "{" + "".join("[%s]=%s," % (lua_str(k), v) for k, v in sorted(db.items())) + "}"


class Run:
    """One session's result: db {key: text}, archive text, errors, windows opened."""

    def __init__(self, r):
        self.db = dict(r.db.items())
        self.archive = r.archive
        self.errors = list(r.errors.values())
        self.windows = list(r.windows.values())
        self.stores = list(r.stores.values())

    def problems(self, label):
        return [f"{label}: {e}" for e in self.errors[:6]] + \
            [f"{label}: window {w}" for w in self.windows if w.endswith("FAILED")]


VIEW_KEY = re.compile(r'\{ key = "(\w+)", label = "[^"]*", build =')


def module_views(files):
    """{ module: [view keys] } from each UI file's VIEWS table (the old version opens views by key)."""
    out = {}
    for name, path in files:
        if name.endswith("UI.lua"):
            keys = VIEW_KEY.findall(pathlib.Path(path).read_text(encoding="utf-8"))
            if keys:
                out[name[:-4]] = keys
    return out


def session(files, db, archive, version, windows=True, media=True, iface=11509):
    """files: [(name, path)] in load order; iface: the client (11509 Era, 16001 Forever)."""
    lua = runtime(pathlib.Path(files[0][1]).parent.as_posix())
    lt = lua.table_from([lua.table_from({"name": n, "path": p}) for n, p in files])
    views = lua.table_from({m: lua.table_from(k) for m, k in module_views(files).items()})
    o = lua.table_from({"files": lt, "db": db_text(db), "archive": archive or "nil", "views": views,
                        "version": version, "windows": windows, "noMedia": not media,
                        "iface": iface})
    return Run(lua.globals().XV.Session(o))


def run_old_scenario(old_root, name):
    """One of the old version's own scenarios; its saved tables as text."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    fixed_clock(lua)
    g = lua.globals()
    g.ADDON_DIR = old_root.as_posix()
    g.ADDON_FILES = lua.table_from(toc_files(old_root))
    g.SCENARIO = name
    g.EXTRA_SCENARIO_FILES = lua.table_from([f.as_posix() for f in sorted((old_root / "tests").glob("scenarios_*.lua"))])
    g.ADDON_NAME = old_root.name
    lua.execute((old_root / "tests" / "wowmock.lua").read_text(encoding="utf-8"))
    lua.execute((TESTS / "cross_version.lua").read_text(encoding="utf-8"))
    lua.execute((old_root / "tests" / "scenarios.lua").read_text(encoding="utf-8"))
    xv = g.XV
    return dict(xv.SerializeTop(g.TALODDB).items()), xv.Serialize(g[old_root.name + "ArchiveDB"])


def survey(old_root):
    """Every old scenario: which leaves the most of each key."""
    names = []
    for f in sorted((old_root / "tests").glob("scenarios*.lua")):
        names += re.findall(r"^scenarios\.(\w+)\s*=\s*function", f.read_text(encoding="utf-8"), re.M)
    best = {}
    for name in names:
        try:
            db, arch = run_old_scenario(old_root, name)
        except Exception:  # noqa: BLE001 - a failing old scenario leaves nothing to use
            continue
        db["<archive>"] = arch
        for k, v in db.items():
            if len(v) > best.get(k, (0, ""))[0]:
                best[k] = (len(v), name)
    for k, (n, name) in sorted(best.items()):
        print(f"{k:28} {n:9} {name}")


def build_fixture(old_root):
    """The rich saved file and archive, and a Lua state to compare with."""
    names = sorted({n for ns in FIXTURE.values() for n in ns} | {"era_boot"})
    runs = {}
    for name in names:
        db, arch = run_old_scenario(old_root, name)
        db["<archive>"] = arch
        runs[name] = db
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute((TESTS / "cross_version.lua").read_text(encoding="utf-8"))
    xv = lua.globals().XV
    fix = {}
    for db in runs.values():
        for k, v in db.items():
            if k not in FIXTURE and k not in ("errorLog", "lastProbe") and len(v) > len(fix.get(k, "")):
                fix[k] = v
    for k, sources in FIXTURE.items():
        fix[k] = xv.MergeTexts(lua.table_from([runs[n][k] for n in sources if k in runs[n]]))
    fix.update(SETTINGS)
    # Saved by the old version: no key of it is legacy at its own load.
    fix["store"] = re.sub(r'\["addon"\]="[^"]*"', '["addon"]="%s"' % OLD_VERSION, fix["store"])
    archive = fix.pop("<archive>")
    return fix, archive, xv


def addon_free(db):
    """The saved table without the version that saved it (store.addon: newer after the new version ran)."""
    if "store" not in db:
        return db
    out = dict(db)
    out["store"] = re.sub(r'\["addon"\]="[^"]*",', "", db["store"], count=1)
    return out


def diff(xv, a, b, skip=(), limit=6):
    """Differences between two saved tables, key by key: [text]."""
    a, b = addon_free(a), addon_free(b)
    out = []
    for k in sorted(set(a) | set(b)):
        if k in skip or a.get(k) == b.get(k):
            continue
        if k not in a or k not in b:
            out.append(f"{k}: {'added' if k not in a else 'gone'}")
            continue
        out.append(f"{k}: " + "; ".join(xv.Diff(a[k], b[k], limit).values()))
    return out


def archive_diff(xv, a, b):
    return [] if a == b else ["archive: " + "; ".join(xv.Diff(a, b, 6).values())]


def empty(text):
    return text is None or text in ("{}", '""', "nil")


def check(new_root=None):
    """[(name, ok, message)], or a string saying why it was skipped."""
    with tempfile.TemporaryDirectory() as tmp:
        old_root = old_tree(tmp)
        if not old_root:
            return "git or commit " + BASE + " not available (a release package?)"
        return run_checks(old_root, pathlib.Path(new_root or REPO))


def run_checks(old_root, new_root):
    results = []

    def result(name, problems):
        results.append((name, not problems, "\n     ".join(problems[:14])))

    fix, archive, xv = build_fixture(old_root)
    old_files, new_files = file_set(old_root), file_set(new_root)
    A = both_ways(xv, fix, archive, old_files, new_files, 11509, "era", result)
    both_ways(xv, fix, archive, old_files, new_files, 16001, "forever", result)
    result("cross_version_e_mixed_loads", mixed(xv, A, old_files, new_files))
    return results


def both_ways(xv, fix, archive, old_files, new_files, iface, client, result):
    """(a) to (d) on one client; returns (a)'s session."""

    # Every session opens every page: what a page writes when it opens is
    # part of what is compared.
    def old(r):
        return session(old_files, r.db, r.archive, OLD_VERSION, iface=iface)

    def new(r, media=True):
        return session(new_files, r.db, r.archive, NEW_VERSION, media=media, iface=iface)

    def new_keys(r, label):
        p = []
        for k, want in NEW_KEYS.items():
            if k not in r.db:
                p.append(f"{k}: not saved {label}")
            elif want is not None and r.db[k] != want:
                p.append(f"{k}: {r.db[k]} {label}, not its default {want}")
        return p

    # (a) The old version on the rich file.
    A = session(old_files, fix, archive, OLD_VERSION, iface=iface)
    p = A.problems("old") + [f"fixture: {k} is empty" for k in FIXTURE if k != "<archive>" and empty(A.db.get(k))]
    if len(A.archive) < 200:
        p.append("fixture: the archive is empty")
    result("cross_version_a_old_session_" + client, p)

    # (b) The new version on it (the new media files missing, as after a
    # /reload), against the old version on it.
    Bo, Bn = old(A), new(A, media=False)
    p = Bn.problems("new") + Bo.problems("old")
    p += diff(xv, Bo.db, Bn.db, skip=set(NEW_KEYS) | SKIP_TOP)
    p += new_keys(Bn, "by the new version")
    p += archive_diff(xv, Bo.archive, Bn.archive)
    result("cross_version_b_new_reads_old_" + client, p)

    # (c) The old version on what the new one saved, against old after old:
    # the same, and the new keys still there for the way back.
    C, D = old(Bn), old(Bo)
    p = C.problems("old after new")
    p += diff(xv, D.db, C.db, skip=set(NEW_KEYS) | SKIP_TOP)
    p += [f"{k}: not kept by the old version" for k in NEW_KEYS if C.db.get(k) != Bn.db.get(k)]
    p += archive_diff(xv, D.archive, C.archive)
    result("cross_version_c_old_reads_new_" + client, p)

    # (d) Forward again: the same as without the trip back (the new keys as
    # the first new session left them).
    E, F = new(C), new(D)
    p = E.problems("new again") + diff(xv, F.db, E.db, skip=set(NEW_KEYS) | SKIP_TOP)
    p += archive_diff(xv, F.archive, E.archive) + new_keys(E, "after the trip back")
    result("cross_version_d_forward_again_" + client, p)
    return A


def mixed_sets(old_files, new_files):
    """(label, files, version): a /reload during the copy. The TOC (and so the
    version) is copied after the Lua files; the half-copied sets are also tried
    with the new TOC."""
    old_path = dict(old_files)
    changed = [n for n, p in new_files if pathlib.Path(p).read_bytes() != pathlib.Path(old_path[n]).read_bytes()]

    def with_new(names):
        return [(n, p if n in names else old_path[n]) for n, p in new_files]

    out = []
    for n in changed:
        out.append(("new files, old " + n, with_new(set(changed) - {n}), OLD_VERSION))
        out.append(("old files, new " + n, with_new({n}), OLD_VERSION))
    for order, names in (("load order", changed), ("by name", sorted(changed, key=str.lower))):
        for part in (1, 2, 3):
            first = set(names[:len(names) * part // 4])
            for version in (OLD_VERSION, NEW_VERSION):
                out.append((f"{part}/4 copied ({order}), version {version}", with_new(first), version))
    return out


def mixed(xv, A, old_files, new_files):
    """(e): each mixed set on (a)'s file, then a full new load on what it saved."""
    def run(files, r, version):
        return session(files, r.db, r.archive, version, windows=False)

    # Without pages opened (what a page writes on opening is compared above).
    Bo, Bn = run(old_files, A, OLD_VERSION), run(new_files, A, NEW_VERSION)
    G = run(new_files, Bo, NEW_VERSION)
    stores = sorted(set(Bn.stores) | {"chars"})
    problems, broken, reset = [], 0, set()
    for label, files, version in mixed_sets(old_files, new_files):
        M = run(files, A, version)
        broken += 1 if M.errors else 0
        for k in stores:
            if M.db.get(k) not in (A.db.get(k), Bo.db.get(k), Bn.db.get(k)):
                problems.append(f"{label}: {k} changed: " + "; ".join(xv.Diff(Bo.db[k], M.db[k], 4).values()))
        if M.archive not in (A.archive, Bo.archive, Bn.archive):
            problems.append(f"{label}: archive changed")
        # The next /reload loads every new file: where a whole new load ends.
        N = run(new_files, M, NEW_VERSION)
        p = N.problems("then new")
        for k in sorted(set(N.db) | set(G.db)):
            if k in NEW_KEYS or k in SKIP_TOP:
                continue
            a, b = addon_free(N.db).get(k), addon_free(G.db).get(k)
            if a == b or a == Bn.db.get(k):
                continue
            paths = list(xv.Diff(b, a, 4).values()) if a and b else ["gone" if a is None else "added"]
            # Only with the new TOC beside an old file that fails to load (the
            # copy puts the TOC last): that module's settings are unknown to
            # the load, so the legacy sweep sets them aside (kept in
            # store.quarantine, listed by /talod data) and they are back at
            # their defaults. Stores are never touched (checked above).
            if version == NEW_VERSION and k not in stores:
                if k == "store" and all(x.startswith((".legacy", ".quarantine")) for x in paths):
                    continue
                if f'["key"]="{k}",["path"]="{k}",["reason"]="not used by this version"' in M.db.get("store", ""):
                    reset.add(k)
                    continue
            p.append(f"{k}: " + "; ".join(paths))
        problems += [f"{label}, then new: {x}" for x in p]
        if VERBOSE and M.errors:
            print(f"   mixed {label}: {len(M.errors)} errors, first: {M.errors[0][:160]}")
    if VERBOSE:
        print(f"   mixed sets with errors: {broken}; settings set aside with the new TOC: {sorted(reset)}")
    return problems


def main():
    if "--survey" in sys.argv:
        with tempfile.TemporaryDirectory() as tmp:
            survey(old_tree(tmp))
        return 0
    out = check()
    if isinstance(out, str):
        print("SKIP cross_version: " + out)
        return 0
    bad = 0
    for name, ok, msg in out:
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else "\n     " + msg))
        bad += 0 if ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
