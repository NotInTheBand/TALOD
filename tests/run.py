"""Offline smoke tests for TALOD: runs tests/scenarios.lua against tests/wowmock.lua
in a fresh Lua 5.1 state per scenario. Requires `pip install lupa`.

    python tests/run.py            # all scenarios
    python tests/run.py -v         # also print addon chat output
"""
import pathlib
import re
import sys

from lupa import lua51

TESTS = pathlib.Path(__file__).resolve().parent
# --root <folder> runs the suite against another copy of the addon (e.g. the
# built release in dist/TALOD); default is this working folder.
ROOT = TESTS.parent
if "--root" in sys.argv:
    ROOT = pathlib.Path(sys.argv[sys.argv.index("--root") + 1]).resolve()
TOC = next(ROOT.glob("*.toc"))

SCENARIOS = [
    "era_boot",
    "spotted_alert_and_panel",
    "alert_rules",
    "target_readout_and_flag_safety",
    "journal_and_lists",
    "vanish_heuristic",
    "combat_lockdown",
    "forever_secrets",
    "slash_and_options",
    "missing_templates",
    "savedvariables_upgrade",
    "panel_details",
    "panel_details_secrets",
    "allies_filtered",
    "census_logging",
    "gear_ledger",
    "skills_tracking",
    "gear_conditions",
    "gear_combat",
    "enhance_view",
    "economy_tracking",
    "profession_plan",
    "skills_forever_professions",
    "skills_c_skillinfo",
    "crafting_log",
    "minimap_button",
    "auction_prices",
    "market",
    "ah_helper",
    "ah_helper_modern",
    "fishing",
    "fishing_forever",
    "fishing_crash_recovery",
    "fishing_no_false_alarm",
    "fishing_sound_restore",
    "list_filters",
    "flag_safety_npcs",
    "review_fixes",
    "data_integrity",
    "panel_mute_alerts",
]


# Scenario files besides scenarios.lua: tests/scenarios_<area>.lua, their
# scenario names read from "scenarios.<name> = function".
EXTRA_FILES = sorted(TESTS.glob("scenarios_*.lua"))
for _extra in EXTRA_FILES:
    for _name in re.findall(r"^scenarios\.(\w+)\s*=\s*function", _extra.read_text(encoding="utf-8"), re.M):
        if _name not in SCENARIOS:
            SCENARIOS.append(_name)


def toc_files():
    files = []
    for line in TOC.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return files


def toc_check():
    folder = ROOT.name
    problems = []
    if TOC.stem != folder:
        problems.append(f"TOC name {TOC.name} does not match folder {folder}")
    for f in toc_files():
        if not (ROOT / f).exists():
            problems.append(f"TOC lists missing file {f}")
    if not re.search(r"^## Interface:.*\b16001\b", TOC.read_text(encoding="utf-8"), re.M):
        problems.append("TOC does not list Interface 16001")
    return problems


# Whispers and invites leave the addon only through Outbox.lua (one pace, one
# throttle hold for all of them).
OUTBOX_ONLY = re.compile(r"(?<![\w.:])(SendChatMessage|GuildInvite|InviteUnit|InviteToGroup|BNSendWhisper)\b"
                         r"|C_GuildInfo\s*[.:]\s*Invite\b|C_GuildInfo\s*,\s*\"Invite\"")


def outbox_check():
    problems = []
    for f in toc_files():
        if not f.endswith(".lua") or f == "Outbox.lua":
            continue
        for n, line in enumerate((ROOT / f).read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]
            if OUTBOX_ONLY.search(code):
                problems.append(f"{f}:{n} sends outside Outbox.lua: {line.strip()}")
    return problems



# Tooltips are written only by Tooltip.lua (one look for every tooltip). Reading
# the game's tooltip (FishingGear's pool name) is fine.
TOOLTIP_ONLY = re.compile(r"\b(GameTooltip|ItemRefTooltip|tooltip|tip)\s*[:.]\s*"
                          r"(SetOwner|SetText|AddLine|AddDoubleLine|SetHyperlink|SetUnit|SetSpellByID|Hide)\b"
                          r"|AddTooltipPostCall\s*,?\s*\(?\s*Enum\.TooltipDataType\.Item\b|OnTooltipSetItem")


def tooltip_check():
    problems = []
    for f in toc_files():
        if not f.endswith(".lua") or f == "Tooltip.lua":
            continue
        for n, line in enumerate((ROOT / f).read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]
            if TOOLTIP_ONLY.search(code):
                problems.append(f"{f}:{n} writes a tooltip outside Tooltip.lua (use ns.Tooltip): {line.strip()}")
    return problems


# The addon's name lives in Brand.lua and the slash prefix in Commands.lua only, so a rename is one edit there.
def brand_literal():
    brand = (ROOT / "Brand.lua").read_text(encoding="utf-8")
    name = re.search(r'^ns\.NAME\s*=\s*"([^"]+)"', brand, re.M).group(1)
    commands = (ROOT / "Commands.lua").read_text(encoding="utf-8")
    short = re.search(r'^Cmd\.PREFIX\s*=\s*"([^"]+)"', commands, re.M).group(1)
    # As a word or a prefix of a CamelCase name ("TALODPanel", "TALOD_RESET"), never
    # inside another word ("footer", "FOOTER" for a name like "Foo").
    n, up, slash = re.escape(name), re.escape(name.upper()), re.escape("/" + name.lower())
    return re.compile(rf"(?<![A-Za-z]){n}(?![a-z])|(?<![A-Za-z]){up}(?![A-Za-z])|{slash}(?![a-z])|{re.escape(short)}\b")


def brand_check():
    problems = []
    BRAND_LITERAL = brand_literal()
    for f in toc_files():
        if not f.endswith(".lua") or f in ("Brand.lua", "Commands.lua"):
            continue
        for n, line in enumerate((ROOT / f).read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]
            if BRAND_LITERAL.search(code):
                problems.append(f"{f}:{n} names the addon outside Brand.lua (use ns.NAME / ns.FRAME / ns.DB() ...): {line.strip()}")
    return problems

def run(name, verbose):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.ADDON_DIR = ROOT.as_posix()
    g.ADDON_FILES = lua.table_from(toc_files())
    g.SCENARIO = name
    g.EXTRA_SCENARIO_FILES = lua.table_from([f.as_posix() for f in EXTRA_FILES])
    g.ADDON_NAME = ROOT.name
    lua.execute((TESTS / "wowmock.lua").read_text(encoding="utf-8"))
    try:
        lua.execute((TESTS / "scenarios.lua").read_text(encoding="utf-8"))
        ok, err = True, None
        # A protected call outside a click: the game blocks it (ADDON_ACTION_BLOCKED).
        blocked = list(g.MOCK.blocked.values())
        if blocked:
            ok, err = False, "blocked outside a click (ADDON_ACTION_BLOCKED): " + ", ".join(blocked)
    except Exception as e:  # lupa raises LuaError
        ok, err = False, str(e)
    if verbose or not ok:
        for line in g.MOCK.prints.values():
            print("   chat:", line)
    return ok, err


def viewer_check():
    """tools/census_viewer.py: parses SavedVariables and builds the page data."""
    import importlib.util
    viewer_path = ROOT / "tools" / "census_viewer.py"
    if not viewer_path.exists():   # not shipped in the release package
        return []
    spec = importlib.util.spec_from_file_location("census_viewer", viewer_path)
    viewer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(viewer)
    sv = r'''
TALODDB = {
	["enabled"] = true,
	["census"] = {
		["points"] = {
			"1700000000,1429,420,650,H,E,ROGUE,24,Orc,8,20,n,20,c,1,0,Shadowfang,The \"Reds\", Inc", -- [1]
			"1700000005,1429,,,A,F,PRIEST,,Human,,,g,20,,0,1,Buddy,", -- [2]
			"broken", -- [3]
			"1700000009,1429,,,H,E,MAGE,30,Troll,,,n,20,,1,0,Zap,Inc,#1", -- [4]
		},
		["cells"] = { [1429] = { ["21:32:H:E:ROGUE:21:3"] = 2, }, },
		["maps"] = { [1429] = "Elwynn Forest", },
		["labels"] = { [1429] = { ["Goldshire"] = { 0.84, 1.3, 2, }, }, },
	},
}
'''
    problems = []
    try:
        census = viewer.Parser(sv).assignments()["TALODDB"]["census"]
        census["_chars"] = {1: "Tester-Mockrealm"}
        maps = viewer.build_data([census])
        m = maps[1429]
        zap = [p for p in m["points"] if p[15] == "Zap"]
        if not zap or zap[0][16] != "Inc" or zap[0][17] != "Tester-Mockrealm" or m["points"][0][17] is not None:
            problems.append(f"viewer point character: {zap}")
        m["points"] = [p for p in m["points"] if p[15] != "Zap"]
        if m["name"] != "Elwynn Forest" or len(m["points"]) != 2:
            problems.append(f"viewer map data: {m['name']} {len(m['points'])} points")
        elif m["points"][0][16] != 'The "Reds", Inc' or m["points"][1][1] is not None:
            problems.append(f"viewer point fields: {m['points']}")
        if m["labels"] != [["Goldshire", 0.42, 0.65]] or m["cells"] != {"21:32:H:E:ROGUE:21:3": 2}:
            problems.append(f"viewer labels/cells: {m['labels']} {m['cells']}")
        if "__DATA__" in viewer.render(maps, {}, []):
            problems.append("viewer page not filled")
    except Exception as e:
        problems.append(f"viewer error: {e!r}")
    return problems


def fishing_viewer_check():
    """tools/fishing_viewer.py: merges the fishing data and builds the page."""
    import importlib.util
    viewer_path = ROOT / "tools" / "fishing_viewer.py"
    if not viewer_path.exists():   # not shipped in the release package
        return []
    spec = importlib.util.spec_from_file_location("fishing_viewer", viewer_path)
    viewer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(viewer)
    sv = r'''
TALODDB = {
	["prices"] = { ["Mockrealm-Alliance"] = { [6291] = { ["p"] = 100, ["t"] = 1700000000, }, }, },
	["fishing"] = {
		["names"] = { [6291] = "Raw Brilliant Smallfish", },
		["maps"] = { [1429] = "Elwynn Forest", },
		["cells"] = { [1429] = { ["21:32"] = { ["n"] = 4, ["c"] = 3, ["a"] = 1, ["s"] = 400, ["x"] = 1, ["it"] = { [6291] = 3, }, }, }, },
		["spots"] = { [1429] = { ["Crystal Lake"] = { ["b"] = { [100] = { ["n"] = 4, ["c"] = 3, ["a"] = 1, ["s"] = 400, ["it"] = { [6291] = 3, }, }, },
			["s"] = 400, ["x"] = 1, ["p"] = 0, ["e"] = 2, ["px"] = 0.84, ["py"] = 1.3, ["pn"] = 2, }, }, },
		["threats"] = { { ["t"] = 1700000100, ["m"] = 1429, ["k"] = "N", ["who"] = "Murloc", ["sub"] = "Crystal Lake", }, },
		["sessions"] = { { ["start"] = 1700000000, ["n"] = 4, ["c"] = 3, ["s"] = 400, ["zone"] = "Elwynn Forest", ["it"] = { [6291] = 3, }, }, },
	},
}
'''
    problems = []
    try:
        db = viewer.Parser(sv).assignments()["TALODDB"]
        data = viewer.build_data([db, db])
        m = data["maps"][1429]
        spot = m["spots"]["Crystal Lake"]
        if m["cells"]["21:32"]["n"] != 8 or m["cells"]["21:32"]["it"]["6291"] != 6:
            problems.append(f"fishing viewer cells: {m['cells']}")
        if spot["all"]["c"] != 6 or spot["all"]["s"] != 800 or spot["all"]["e"] != 4 or m["labels"] != [["Crystal Lake", 0.42, 0.65]]:
            problems.append(f"fishing viewer spot: {spot['all']} {m['labels']}")
        if data["prices"] != {"6291": 95} or len(data["threats"]) != 2 or len(data["sessions"]) != 2:
            problems.append(f"fishing viewer prices/threats/sessions: {data['prices']} {len(data['threats'])} {len(data['sessions'])}")
        if "__DATA__" in viewer.render(data, {}, []):
            problems.append("fishing viewer page not filled")
        old = viewer.parse_cast("1700000000,1429,420,650,c,100,0,0,20,6291:1,Crystal Lake")
        new = viewer.parse_cast("1700000000,1429,420,650,a,100,25,1,20,,Crystal Lake,263,1230,30,pool;x=3")
        if not old or old["sub"] != "Crystal Lake" or old["items"] != {"6291": 1} or old["lureID"] is not None:
            problems.append(f"fishing viewer old cast record: {old}")
        tagged = viewer.parse_cast("1700000000,1429,420,650,a,100,25,1,20,,Crystal Lake,263,1230,30,pool;x=3,2")
        if not tagged or tagged["char"] != 2 or tagged["tags"] != {"pool": True, "x": 3} or old["char"] is not None:
            problems.append(f"fishing viewer cast character: {tagged}")
        if not new or new["lureID"] != 263 or new["serverHour"] != 20 or new["tags"] != {"pool": True, "x": 3}:
            problems.append(f"fishing viewer new cast record: {new}")
        if viewer.parse_cast("garbage") is not None or viewer.parse_cast(None) is not None:
            problems.append("fishing viewer: unreadable cast record not None")
    except Exception as e:
        problems.append(f"fishing viewer error: {e!r}")
    return problems


def version_check():
    """version.json, the TOC's ## Version and the CHANGELOG agree (tools/version.py).
    Only in the working folder: the release package carries no version.json."""
    if ROOT != TESTS.parent:
        return []
    sys.path.insert(0, str(ROOT / "tools"))
    import version
    return version.problems()


def main():
    verbose = "-v" in sys.argv
    failures = 0
    for problem in toc_check():
        print("TOC  FAIL", problem)
        failures += 1
    for problem in outbox_check():
        print("OUTBOX FAIL", problem)
        failures += 1
    for problem in brand_check():
        print("BRAND FAIL", problem)
        failures += 1
    for problem in tooltip_check():
        print("TOOLTIP FAIL", problem)
        failures += 1
    for problem in viewer_check() + fishing_viewer_check():
        print("VIEWER FAIL", problem)
        failures += 1
    for problem in version_check():
        print("VERSION FAIL", problem)
        failures += 1
    for name in SCENARIOS:
        ok, err = run(name, verbose)
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else "\n     " + err))
        failures += 0 if ok else 1
    print(f"\n{len(SCENARIOS) - failures if failures <= len(SCENARIOS) else 0} passed, {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
