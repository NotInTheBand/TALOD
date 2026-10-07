"""TALOD census viewer: turns the census in TALOD's SavedVariables into
one HTML page of heat maps (where players travel, by faction, class, level and
time of day). Nothing is sent anywhere; the page is a local file.

    python tools/census_viewer.py                    # finds WTF/Account/*/SavedVariables/TALOD.lua
    python tools/census_viewer.py PATH [PATH ...]    # one or more SavedVariables files (merged)
    python tools/census_viewer.py -o out.html --open

Output defaults to census/census.html in the addon folder (git-ignored: it holds
other players' names). Map backgrounds are optional: save an image of a zone's
world map as census/maps/<mapID>.jpg (or .png / .webp) and re-run; the page lists
the map IDs it saw. Without one, the map shows subzone names where you were.

SavedVariables are written when you log out or /reload, not live.
"""
import argparse
import base64
import json
import os
import pathlib
import re
import sys
import time
import webbrowser

ADDON = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ADDON / "census"


def addon_name():
    """The addon's name from Brand.lua, the one place it is set (falls back to
    the folder name). The game names the SavedVariables file after the folder,
    and the folder is renamed with the addon."""
    try:
        m = re.search(r'^ns\.NAME\s*=\s*"([^"]+)"', (ADDON / "Brand.lua").read_text(encoding="utf-8"), re.M)
        if m:
            return m.group(1)
    except OSError:
        pass
    return ADDON.name


NAME = addon_name()
DB_NAME = NAME + "DB"
POINT_FIELDS = 18   # see Census.lua; newer points end in ",#<character number>" (names in the saved "chars")
CHAR_SUFFIX = re.compile(r",#(\d+)$")


# ---------------------------------------------------------------------------
# SavedVariables (Lua table literals) -> Python
# ---------------------------------------------------------------------------
TOKEN = re.compile(r"""
    (?P<ws>\s+|--[^\n]*)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<special>-?(?:inf|nan)(?:\(ind\))?|-?1\.\#(?:INF|IND|QNAN)\d*)
  | (?P<num>-?(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<sym>[{}\[\]=,;])
""", re.X)

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
           "\n": "\n"}


def unescape(body):
    out, i = [], 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt.isdigit():
            m = re.match(r"\d{1,3}", body[i + 1:])
            out.append(chr(int(m.group())))
            i += 1 + len(m.group())
        else:
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
    # The file is read as latin-1 (one char per byte), so raw text and \ddd
    # escapes are both bytes here: decode the UTF-8 that WoW wrote, once.
    try:
        return "".join(out).encode("latin-1").decode("utf-8", errors="replace")
    except UnicodeEncodeError:
        return "".join(out)


def tokenize(text):
    pos = 0
    tokens = []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError(f"unexpected character at {pos}: {text[pos:pos + 20]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        tokens.append((kind, m.group()))
    return tokens


class Parser:
    def __init__(self, text):
        self.tokens = tokenize(text)
        self.i = 0

    def peek(self, ahead=0):
        i = self.i + ahead
        return self.tokens[i] if i < len(self.tokens) else (None, None)

    def take(self, value=None):
        tok = self.peek()
        if tok[0] is None:
            raise ValueError("the file ends in the middle of a table (truncated?)")
        if value is not None and tok[1] != value:
            raise ValueError(f"expected {value!r}, got {tok[1]!r}")
        self.i += 1
        return tok

    def value(self):
        kind, text = self.take()
        if kind == "str":
            return unescape(text[1:-1])
        if kind == "special":
            # Lua writes inf / nan as text: keep the file readable.
            low = text.lower()
            if "nan" in low or "ind" in low:
                return float("nan")
            return float("-inf") if text.startswith("-") else float("inf")
        if kind == "num":
            return int(text, 16) if text.lower().startswith(("0x", "-0x")) else (float(text) if re.search(r"[.eE]", text) else int(text))
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(text, text)
        if text == "{":
            return self.table()
        raise ValueError(f"unexpected {text!r}")

    def table(self):
        items, n = {}, 0
        while self.peek()[1] != "}":
            if self.peek()[1] == "[":
                self.take("[")
                key = self.value()
                self.take("]")
                self.take("=")
                items[key] = self.value()
            elif self.peek()[0] == "name" and self.peek(1)[1] == "=":
                key = self.take()[1]
                self.take("=")
                items[key] = self.value()
            else:
                n += 1
                items[n] = self.value()
            if self.peek()[1] in (",", ";"):
                self.take()
        self.take("}")
        if items and all(isinstance(k, int) for k in items) and sorted(items) == list(range(1, len(items) + 1)):
            return [items[k] for k in range(1, len(items) + 1)]
        return items

    def assignments(self):
        out = {}
        while self.peek()[0] is not None:
            name = self.take()[1]
            self.take("=")
            out[name] = self.value()
        return out


def read_saved_variables(path):
    """Parses a SavedVariables file. Read as latin-1: each string is decoded
    as UTF-8 on its own (see unescape)."""
    try:
        return Parser(path.read_bytes().decode("latin-1")).assignments()
    except ValueError as e:
        raise SystemExit(f"{path}: could not read it ({e}). Was the game closed while saving? Log in and out once.")


def load_census(path):
    sv = read_saved_variables(path)
    db = sv.get(DB_NAME) or {}
    census = db.get("census") if isinstance(db, dict) else None
    if not isinstance(census, dict):
        return {}
    chars = db.get("chars") if isinstance(db, dict) else None
    census["_chars"] = as_dict(chars.get("names")) if isinstance(chars, dict) else {}
    return census


def as_list(v):
    """A Lua array as a list. A table with holes comes back from the parser as
    a dict: keep its values in order instead of losing them."""
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(k for k in v if isinstance(k, int) and not isinstance(k, bool))]
    return []


def as_dict(v):
    if isinstance(v, dict):
        return v
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v)}
    return {}


def num(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Census -> page data
# ---------------------------------------------------------------------------
def build_data(censuses):
    maps = {}

    def entry(map_id):
        return maps.setdefault(int(map_id), {"name": str(map_id), "points": [], "cells": {}, "labels": {}})

    for c in censuses:
        for map_id, name in as_dict(c.get("maps")).items():
            if isinstance(name, str):
                entry(map_id)["name"] = name
        chars = c.get("_chars") or {}
        for line in as_list(c.get("points")):
            if not isinstance(line, str):
                continue
            who = CHAR_SUFFIX.search(line)
            if who:
                line = line[:who.start()]
            p = line.split(",", POINT_FIELDS - 1)
            if len(p) != POINT_FIELDS or num(p[1]) is None:
                continue
            t, map_id, x, y, fac, rel, cls, lvl, race, lo, hi, src, mylvl, flags, ne, na, key, guild = p
            entry(map_id)["points"].append([
                num(t), num(x), num(y), fac, rel, cls, num(lvl), race, num(lo), num(hi), src, num(mylvl), flags,
                num(ne) or 0, num(na) or 0, key, guild, chars.get(int(who.group(1))) if who else None])
        for map_id, cells in as_dict(c.get("cells")).items():
            target = entry(map_id)["cells"]
            for key, n in as_dict(cells).items():
                if isinstance(n, (int, float)):
                    target[key] = target.get(key, 0) + n
        for map_id, labels in as_dict(c.get("labels")).items():
            target = entry(map_id)["labels"]
            for name, l in as_dict(labels).items():
                if isinstance(l, list) and len(l) == 3 and l[2]:
                    sx, sy, n = target.get(name, (0, 0, 0))
                    target[name] = (sx + l[0], sy + l[1], n + l[2])

    for m in maps.values():
        m["labels"] = [[name, sx / n, sy / n] for name, (sx, sy, n) in m["labels"].items()]
        m["points"].sort(key=lambda p: p[0] or 0)
    return maps


def map_images(maps, folder):
    images = {}
    for map_id in maps:
        for ext, mime in (("jpg", "jpeg"), ("jpeg", "jpeg"), ("png", "png"), ("webp", "webp")):
            f = folder / f"{map_id}.{ext}"
            if f.exists():
                images[map_id] = f"data:image/{mime};base64," + base64.b64encode(f.read_bytes()).decode("ascii")
                break
    return images


def render(maps, images, sources):
    data = {"generated": time.strftime("%Y-%m-%d %H:%M"), "sources": sources, "maps": maps, "images": images}
    # Inlined in a <script>: no "<" at all, so no text can close or comment it out.
    payload = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c")
    return PAGE.replace("__NAME__", NAME).replace("__DATA__", payload)


def saved_variables_roots():
    """Where to look: $WOW_DIR (a flavor folder such as _classic_era_, or the
    World of Warcraft folder), the game folder this addon is in, and every
    flavor folder next to it."""
    roots = []
    if os.environ.get("WOW_DIR"):
        roots.append(pathlib.Path(os.environ["WOW_DIR"]))
    flavor = ADDON.parent.parent.parent      # <flavor>/Interface/AddOns/TALOD
    return roots + [flavor, flavor.parent]


def find_saved_variables():
    found = set()
    for root in saved_variables_roots():
        found.update(root.glob(f"WTF/Account/*/SavedVariables/{NAME}.lua"))
        found.update(root.glob(f"_*_/WTF/Account/*/SavedVariables/{NAME}.lua"))
    return sorted(found)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", type=pathlib.Path, help="SavedVariables files (default: all accounts)")
    ap.add_argument("-o", "--out", type=pathlib.Path, default=OUT_DIR / "census.html")
    ap.add_argument("--maps", type=pathlib.Path, default=OUT_DIR / "maps", help="folder of <mapID>.jpg backgrounds")
    ap.add_argument("--open", action="store_true", help="open the page in your browser")
    args = ap.parse_args(argv)

    paths = args.paths or find_saved_variables()
    if not paths:
        print(f"No {NAME} SavedVariables found. Looked in: " + ", ".join(str(r) for r in saved_variables_roots()))
        print(f"Pass the file (WTF/Account/<account>/SavedVariables/{NAME}.lua) or set WOW_DIR to your game folder.")
        return 1
    censuses = []
    for p in paths:
        c = load_census(p)
        print(f"{p}: {len(c.get('points') or [])} points")
        censuses.append(c)
    maps = build_data(censuses)
    images = map_images(maps, args.maps)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(maps, images, [str(p) for p in paths]), encoding="utf-8")
    total = sum(len(m["points"]) for m in maps.values())
    print(f"{args.out}: {len(maps)} maps, {total} points, {len(images)} map images")
    if args.open:
        webbrowser.open(args.out.resolve().as_uri())
    return 0


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__NAME__ Census</title>
<style>
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10); --accent: #2a78d6;
  --heat-0: #cde2fb; --heat-1: #86b6ef; --heat-2: #3987e5; --heat-3: #1c5cab; --heat-4: #0d366b;
  --label-halo: rgba(252,252,251,0.85);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --accent: #3987e5;
    --heat-0: #184f95; --heat-1: #256abf; --heat-2: #3987e5; --heat-3: #86b6ef; --heat-4: #cde2fb;
    --label-halo: rgba(26,26,25,0.85);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
  --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --accent: #3987e5;
  --heat-0: #184f95; --heat-1: #256abf; --heat-2: #3987e5; --heat-3: #86b6ef; --heat-4: #cde2fb;
  --label-halo: rgba(26,26,25,0.85);
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1280px; margin: 0 auto; padding: 20px 16px 48px; }
h1 { font-size: 20px; margin: 0 0 2px; }
h2 { font-size: 14px; margin: 0 0 8px; }
.sub { color: var(--ink-2); font-size: 13px; margin: 0 0 16px; }
.filters { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: end; margin-bottom: 14px; }
.filters label { display: flex; flex-direction: column; gap: 3px; font-size: 12px; color: var(--ink-2); }
select, input { font: inherit; color: var(--ink); background: var(--surface); border: 1px solid var(--axis); border-radius: 6px; padding: 4px 6px; }
input[type=number] { width: 64px; }
.seg { display: inline-flex; border: 1px solid var(--axis); border-radius: 6px; overflow: hidden; }
.seg button { font: inherit; border: 0; background: var(--surface); color: var(--ink-2); padding: 4px 10px; cursor: pointer; }
.seg button[aria-pressed=true] { background: var(--accent); color: #fff; }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 16px; }
@media (max-width: 900px) { .layout { grid-template-columns: 1fr; } }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px; }
.mapwrap { position: relative; width: 100%; aspect-ratio: 3 / 2; border-radius: 6px; overflow: hidden; background: var(--surface); }
canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
.legend { display: flex; align-items: center; gap: 8px; margin-top: 10px; font-size: 12px; color: var(--ink-2); flex-wrap: wrap; }
.ramp { width: 160px; height: 10px; border-radius: 3px; background: linear-gradient(90deg, var(--heat-0), var(--heat-1), var(--heat-2), var(--heat-3), var(--heat-4)); }
.note { font-size: 12px; color: var(--muted); margin-top: 6px; }
.tip { position: absolute; pointer-events: none; background: var(--surface); color: var(--ink); border: 1px solid var(--border);
  border-radius: 8px; padding: 8px 10px; font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.18); max-width: 260px; display: none; z-index: 2; }
.tip b { font-variant-numeric: tabular-nums; }
.stat { display: flex; gap: 18px; margin-bottom: 12px; }
.stat div { display: flex; flex-direction: column; }
.stat strong { font-size: 22px; font-variant-numeric: tabular-nums; }
.stat span { font-size: 12px; color: var(--ink-2); }
.bars { display: grid; grid-template-columns: 74px 1fr 44px; gap: 4px 8px; align-items: center; font-size: 12px; margin-bottom: 14px; }
.bars .name { color: var(--ink-2); }
.bars .track { height: 10px; }
.bars .fill { height: 100%; background: var(--heat-2); border-radius: 0 4px 4px 0; min-width: 1px; }
.bars .val { text-align: right; font-variant-numeric: tabular-nums; color: var(--ink); }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid var(--grid); }
th { color: var(--ink-2); font-weight: 600; }
td.n { text-align: right; font-variant-numeric: tabular-nums; }
.tables { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 16px; }
@media (max-width: 900px) { .tables { grid-template-columns: 1fr; } }
.empty { color: var(--muted); padding: 30px 0; text-align: center; }
code { font-size: 12px; }
</style>
</head>
<body>
<main>
  <h1>__NAME__ Census</h1>
  <p class="sub" id="sub"></p>
  <div class="filters">
    <label>Map <select id="f-map"></select></label>
    <label>Data <span class="seg" id="f-mode">
      <button data-v="points" aria-pressed="true" title="Every logged point: exact time, all filters, the last N points only">Recent detail</button>
      <button data-v="cells" aria-pressed="false" title="Kept forever: one count per player per map square per visit">All time</button>
    </span></label>
    <label>Players <select id="f-rel">
      <option value="E">Enemies (incl. hidden)</option><option value="F">Allies</option><option value="all">Everyone</option>
    </select></label>
    <label>Faction <select id="f-fac"><option value="all">Both</option><option value="A">Alliance</option><option value="H">Horde</option></select></label>
    <label>Class <select id="f-class"><option value="all">All classes</option></select></label>
    <label>Level <span><input id="f-lmin" type="number" min="1" max="60" value="1"> – <input id="f-lmax" type="number" min="1" max="60" value="60"></span></label>
    <label>Time of day <select id="f-hour"><option value="all">Any time</option></select></label>
    <label>Date <select id="f-date">
      <option value="all">All dates</option><option value="1">Last 24 h</option><option value="7">Last 7 days</option><option value="30">Last 30 days</option>
    </select></label>
  </div>
  <div class="layout">
    <div class="card">
      <div class="mapwrap" id="mapwrap"><canvas id="map"></canvas><div class="tip" id="tip"></div></div>
      <div class="legend"><span>Fewer</span><span class="ramp"></span><span>More</span><span id="legend-max"></span></div>
      <div class="note" id="map-note"></div>
    </div>
    <div class="card" id="side"></div>
  </div>
  <div class="tables">
    <div class="card"><h2>Busiest spots</h2><div id="t-spots"></div></div>
    <div class="card"><h2>Players seen most</h2><div id="t-players"></div></div>
  </div>
</main>
<script>
const DATA = __DATA__;
const CLASSES = { WARRIOR: "Warrior", PALADIN: "Paladin", HUNTER: "Hunter", ROGUE: "Rogue", PRIEST: "Priest",
  SHAMAN: "Shaman", MAGE: "Mage", WARLOCK: "Warlock", DRUID: "Druid" };
const HOURS = [0, 1, 2, 3, 4, 5].map(i => ({ v: i, label: `${String(i * 4).padStart(2, "0")}:00–${String(i * 4 + 4).padStart(2, "0")}:00` }));
const GRID = 50;
const $ = id => document.getElementById(id);
const state = { map: null, mode: "points", rel: "E", fac: "all", cls: "all", lmin: 1, lmax: 60, hour: "all", date: "all" };
let grid = null, cellInfo = null;

const mapIds = Object.keys(DATA.maps).sort((a, b) => weight(DATA.maps[b]) - weight(DATA.maps[a]));
function weight(m) { return m.points.length + Object.values(m.cells).reduce((s, n) => s + n, 0); }

function init() {
  const total = mapIds.reduce((s, id) => s + DATA.maps[id].points.length, 0);
  $("sub").textContent = `${total.toLocaleString()} recent points on ${mapIds.length} maps · generated ${DATA.generated}. ` +
    "A point is where you stood when you saw the player (within nameplate range, ~41 yd); party members are at their own position.";
  for (const id of mapIds) $("f-map").add(new Option(`${DATA.maps[id].name} (${id})`, id));
  for (const [k, v] of Object.entries(CLASSES)) $("f-class").add(new Option(v, k));
  for (const h of HOURS) $("f-hour").add(new Option(h.label, h.v));
  state.map = mapIds[0] || null;
  const bind = (id, key, conv = v => v) => $(id).addEventListener("change", e => { state[key] = conv(e.target.value); draw(); });
  bind("f-map", "map"); bind("f-rel", "rel"); bind("f-fac", "fac"); bind("f-class", "cls"); bind("f-hour", "hour"); bind("f-date", "date");
  bind("f-lmin", "lmin", Number); bind("f-lmax", "lmax", Number);
  $("f-mode").addEventListener("click", e => {
    const b = e.target.closest("button"); if (!b) return;
    state.mode = b.dataset.v;
    for (const x of $("f-mode").children) x.setAttribute("aria-pressed", x === b);
    draw();
  });
  const canvas = $("map");
  canvas.addEventListener("mousemove", hover);
  canvas.addEventListener("mouseleave", () => { $("tip").style.display = "none"; });
  new ResizeObserver(draw).observe($("mapwrap"));
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", draw);
  if (!state.map) { $("side").innerHTML = '<p class="empty">No census data yet. Play with the census on, then /reload or log out and run the viewer again.</p>'; }
  draw();
}

function relOk(rel) { return state.rel === "all" || (state.rel === "F" ? rel === "F" : rel !== "F"); }
function levelOk(level) {
  const full = state.lmin <= 1 && state.lmax >= 60;
  if (level == null) return full;
  if (level === -1) return state.lmax >= 60;
  return level >= state.lmin && level <= state.lmax;
}
function bandOk(band) {
  if (band === "?") return state.lmin <= 1 && state.lmax >= 60;
  if (band === "s") return state.lmax >= 60;
  const lo = Number(band); return lo + 9 >= state.lmin && lo <= state.lmax;
}

// Rows of { gx, gy, n, cls, level, key, t } for the current filters.
function rows() {
  const m = DATA.maps[state.map]; if (!m) return { rows: [], unplaced: 0 };
  const out = []; let unplaced = 0;
  if (state.mode === "points") {
    const since = state.date === "all" ? 0 : Date.now() / 1000 - Number(state.date) * 86400;
    for (const p of m.points) {
      const [t, x, y, fac, rel, cls, level, race, lo, hi, src, mylvl, flags, ne, na, key, guild] = p;
      if (t < since || !relOk(rel) || (state.fac !== "all" && fac !== state.fac) || (state.cls !== "all" && cls !== state.cls) || !levelOk(level)) continue;
      if (state.hour !== "all" && Math.floor(new Date(t * 1000).getHours() / 4) !== Number(state.hour)) continue;
      if (x == null || y == null) { unplaced++; continue; }
      out.push({ gx: Math.min(GRID - 1, Math.floor(x / 1000 * GRID)), gy: Math.min(GRID - 1, Math.floor(y / 1000 * GRID)), n: 1, cls, level, key, guild, t, x, y });
    }
  } else {
    for (const [k, n] of Object.entries(m.cells)) {
      const parts = k.split(":");
      const placed = parts[0] !== "-";
      const [fac, rel, cls, band, h4] = placed ? parts.slice(2) : parts.slice(1);
      if (!relOk(rel) || (state.fac !== "all" && fac !== state.fac) || (state.cls !== "all" && cls !== state.cls) || !bandOk(band)) continue;
      if (state.hour !== "all" && Number(h4) !== Number(state.hour)) continue;
      if (!placed) { unplaced += n; continue; }
      out.push({ gx: Number(parts[0]), gy: Number(parts[1]), n, cls, band });
    }
  }
  return { rows: out, unplaced };
}

function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
function heatColor(f) {
  const stops = [0, 1, 2, 3, 4].map(i => css(`--heat-${i}`));
  return stops[Math.min(4, Math.floor(f * 5))];
}

const imageCache = {};
function mapImage(id) {
  if (!DATA.images[id]) return null;
  if (!imageCache[id]) { const img = new Image(); img.onload = draw; img.src = DATA.images[id]; imageCache[id] = img; }
  return imageCache[id].complete ? imageCache[id] : null;
}

function draw() {
  const canvas = $("map"), wrap = $("mapwrap");
  const dpr = window.devicePixelRatio || 1, W = wrap.clientWidth, H = wrap.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  const g = canvas.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.fillStyle = css("--surface"); g.fillRect(0, 0, W, H);
  const m = DATA.maps[state.map];
  const { rows: rs, unplaced } = rows();

  grid = new Float64Array(GRID * GRID); cellInfo = new Map();
  for (const r of rs) {
    const i = r.gy * GRID + r.gx; grid[i] += r.n;
    let c = cellInfo.get(i); if (!c) { c = { n: 0, cls: {}, lmin: 99, lmax: 0, players: new Set() }; cellInfo.set(i, c); }
    c.n += r.n; c.cls[r.cls || "?"] = (c.cls[r.cls || "?"] || 0) + r.n;
    if (r.level > 0) { c.lmin = Math.min(c.lmin, r.level); c.lmax = Math.max(c.lmax, r.level); }
    if (r.key) c.players.add(r.key);
  }
  const img = m && mapImage(state.map);
  if (img) { g.globalAlpha = 0.9; g.drawImage(img, 0, 0, W, H); g.globalAlpha = 1; }
  else {
    g.strokeStyle = css("--grid"); g.lineWidth = 1;
    for (let i = 1; i < 10; i++) { const x = Math.round(W * i / 10) + 0.5, y = Math.round(H * i / 10) + 0.5;
      g.beginPath(); g.moveTo(x, 0); g.lineTo(x, H); g.stroke(); g.beginPath(); g.moveTo(0, y); g.lineTo(W, y); g.stroke(); }
  }
  let max = 0; for (const v of grid) max = Math.max(max, v);
  const cw = W / GRID, ch = H / GRID;
  for (let i = 0; i < grid.length; i++) {
    if (!grid[i]) continue;
    const f = Math.sqrt(grid[i] / max);
    g.globalAlpha = img ? 0.55 + 0.4 * f : 0.85;
    g.fillStyle = heatColor(f);
    g.beginPath(); g.roundRect((i % GRID) * cw + 1, Math.floor(i / GRID) * ch + 1, cw - 2, ch - 2, 2); g.fill();
  }
  g.globalAlpha = 1;
  if (m && !img) {
    g.font = "12px system-ui, sans-serif"; g.textAlign = "center"; g.textBaseline = "middle";
    for (const [name, x, y] of m.labels) {
      g.lineWidth = 3; g.strokeStyle = css("--label-halo"); g.strokeText(name, x * W, y * H);
      g.fillStyle = css("--ink-2"); g.fillText(name, x * W, y * H);
    }
  }
  $("legend-max").textContent = max ? `· darkest square: ${max.toLocaleString()} ${state.mode === "points" ? "points" : "visits"} (scale is square-root)` : "";
  const notes = [];
  if (unplaced) notes.push(`${unplaced.toLocaleString()} ${state.mode === "points" ? "points" : "visits"} without a position (instances, capitals for allies, or hidden).`);
  if (m && !img) notes.push(`No background for this map: save a world-map image as census/maps/${state.map}.jpg and re-run the viewer.`);
  if (state.mode === "cells" && state.date !== "all") notes.push("All-time data has no dates: the date filter applies to recent detail only.");
  $("map-note").textContent = notes.join(" ");
  side(rs);
  tables(rs, m);
}

function bars(entries, total) {
  if (!entries.length) return '<p class="empty">Nothing for these filters.</p>';
  const top = Math.max(...entries.map(e => e[1]));
  return '<div class="bars">' + entries.map(([name, n]) =>
    `<span class="name">${esc(name)}</span><span class="track"><span class="fill" style="display:block;width:${(n / top * 100).toFixed(1)}%"></span></span><span class="val">${n.toLocaleString()}</span>`
  ).join("") + "</div>";
}

function side(rs) {
  if (!state.map) return;
  const total = rs.reduce((s, r) => s + r.n, 0);
  const players = new Set(rs.filter(r => r.key).map(r => r.key));
  const byClass = {}; for (const r of rs) byClass[r.cls || "?"] = (byClass[r.cls || "?"] || 0) + r.n;
  const byLevel = {};
  for (const r of rs) {
    const band = state.mode === "points" ? (r.level === -1 ? "??" : r.level ? `${Math.floor((r.level - 1) / 10) * 10 + 1}–${Math.floor((r.level - 1) / 10) * 10 + 10}` : "?")
      : (r.band === "s" ? "??" : r.band === "?" ? "?" : `${r.band}–${Number(r.band) + 9}`);
    byLevel[band] = (byLevel[band] || 0) + r.n;
  }
  const levelOrder = k => k === "??" ? 100 : k === "?" ? 101 : parseInt(k, 10);
  $("side").innerHTML =
    `<div class="stat"><div><strong>${total.toLocaleString()}</strong><span>${state.mode === "points" ? "points" : "visits"}</span></div>` +
    (state.mode === "points" ? `<div><strong>${players.size.toLocaleString()}</strong><span>players</span></div>` : "") + `</div>` +
    `<h2>By level</h2>` + bars(Object.entries(byLevel).sort((a, b) => levelOrder(a[0]) - levelOrder(b[0])), total) +
    `<h2>By class</h2>` + bars(Object.entries(byClass).sort((a, b) => b[1] - a[1]).map(([k, n]) => [CLASSES[k] || "Unknown", n]), total);
}

function nearestLabel(m, x, y) {
  let best = null, bd = 0.02;
  for (const [name, lx, ly] of (m ? m.labels : [])) { const d = (lx - x) ** 2 + (ly - y) ** 2; if (d < bd) { bd = d; best = name; } }
  return best;
}

function tables(rs, m) {
  const spots = [...cellInfo.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, 10);
  $("t-spots").innerHTML = spots.length ? "<table><tr><th>Where (x, y)</th><th>Near</th><th>Classes</th><th class=n>Count</th></tr>" +
    spots.map(([i, c]) => {
      const x = (i % GRID + 0.5) / GRID, y = (Math.floor(i / GRID) + 0.5) / GRID;
      const cls = Object.entries(c.cls).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([k]) => CLASSES[k] || "?").join(", ");
      return `<tr><td>${(x * 100).toFixed(0)}, ${(y * 100).toFixed(0)}</td><td>${esc(nearestLabel(m, x, y) || "")}</td><td>${esc(cls)}</td><td class=n>${c.n.toLocaleString()}</td></tr>`;
    }).join("") + "</table>" : '<p class="empty">Nothing for these filters.</p>';
  if (state.mode !== "points") { $("t-players").innerHTML = '<p class="empty">Names are in recent detail only.</p>'; return; }
  const by = new Map();
  for (const r of rs) {
    if (!r.key) continue;
    let p = by.get(r.key); if (!p) { p = { n: 0, cls: r.cls, level: r.level, guild: r.guild, last: 0 }; by.set(r.key, p); }
    p.n++; p.last = Math.max(p.last, r.t); if (r.level) p.level = r.level; if (r.guild) p.guild = r.guild;
  }
  const top = [...by.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, 15);
  $("t-players").innerHTML = top.length ? "<table><tr><th>Player</th><th>Class</th><th class=n>Level</th><th>Guild</th><th>Last seen</th><th class=n>Points</th></tr>" +
    top.map(([k, p]) => `<tr><td>${esc(k)}</td><td>${CLASSES[p.cls] || "?"}</td><td class=n>${p.level === -1 ? "??" : p.level || "?"}</td><td>${esc(p.guild || "")}</td><td>${new Date(p.last * 1000).toLocaleString()}</td><td class=n>${p.n}</td></tr>`).join("") + "</table>"
    : '<p class="empty">Nothing for these filters.</p>';
}

function hover(e) {
  const rect = e.target.getBoundingClientRect();
  const gx = Math.floor((e.clientX - rect.left) / rect.width * GRID), gy = Math.floor((e.clientY - rect.top) / rect.height * GRID);
  const tip = $("tip");
  // Hit target a bit larger than one square: the square under the cursor,
  // else the busiest of its neighbours.
  const at = (x, y) => (x >= 0 && y >= 0 && x < GRID && y < GRID && cellInfo) ? cellInfo.get(y * GRID + x) : null;
  let best = at(gx, gy);
  if (!best) for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
    const c = at(gx + dx, gy + dy);
    if (c && (!best || c.n > best.n)) best = c;
  }
  if (!best) { tip.style.display = "none"; return; }
  const m = DATA.maps[state.map];
  const near = nearestLabel(m, (gx + 0.5) / GRID, (gy + 0.5) / GRID);
  const cls = Object.entries(best.cls).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${CLASSES[k] || "Unknown"} ${n}`).join(" · ");
  tip.innerHTML = `<b>${best.n.toLocaleString()}</b> ${state.mode === "points" ? "points" : "visits"}${near ? " near " + esc(near) : ""}<br>${esc(cls)}` +
    (best.lmax ? `<br>Levels ${best.lmin}–${best.lmax}` : "") + (best.players.size ? `<br>${best.players.size} players` : "");
  tip.style.display = "block";
  const wrap = $("mapwrap").getBoundingClientRect();
  let left = e.clientX - wrap.left + 14, top = e.clientY - wrap.top + 14;
  if (left + tip.offsetWidth > wrap.width) left = e.clientX - wrap.left - tip.offsetWidth - 14;
  if (top + tip.offsetHeight > wrap.height) top = e.clientY - wrap.top - tip.offsetHeight - 14;
  tip.style.left = left + "px"; tip.style.top = top + "px";
}

function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]); }
init();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    sys.exit(main())
