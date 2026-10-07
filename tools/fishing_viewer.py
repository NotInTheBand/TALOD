"""TALOD fishing viewer: turns the fishing log in TALOD's SavedVariables
into one HTML page: a heat map per map (casts, catches, one fish, attacks,
enemy players seen), every spot with its catch rate, value per hour and danger,
and the encounters while fishing. Nothing is sent anywhere; the page is a local file.

    python tools/fishing_viewer.py                    # finds WTF/Account/*/SavedVariables/TALOD.lua
    python tools/fishing_viewer.py PATH [PATH ...]    # one or more SavedVariables files (merged)
    python tools/fishing_viewer.py -o out.html --open

Output defaults to fishing/fishing.html in the addon folder (git-ignored: it
names players who attacked you). Map backgrounds are shared with the census
viewer: census/maps/<mapID>.jpg (or .png / .webp).

Values use the lowest Auction House price you saw (after the 5% cut), where
there is one; in game the fishing window also counts vendor prices.
Catch rate is catches / (catches + fish that got away); missed clicks (nothing
hooked, early stops), timeouts and interrupted casts are left out. Data logged
before misses were told apart counts early stops as "got away".
SavedVariables are written when you log out or /reload, not live.
"""
import argparse
import importlib.util
import json
import pathlib
import sys
import time
import webbrowser

ADDON = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ADDON / "fishing"
GRID = 50
AH_CUT = 0.05

_spec = importlib.util.spec_from_file_location("census_viewer", pathlib.Path(__file__).resolve().parent / "census_viewer.py")
census_viewer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(census_viewer)
Parser, as_dict, num = census_viewer.Parser, census_viewer.as_dict, census_viewer.num


def load_db(path):
    sv = census_viewer.read_saved_variables(path)
    db = sv.get(census_viewer.DB_NAME) or {}
    return db if isinstance(db, dict) else {}


def tally(t):
    t = as_dict(t)
    out = {k: (t.get(k) if isinstance(t.get(k), (int, float)) else 0) for k in ("n", "c", "a", "m", "t", "i", "s", "x", "p", "u", "e", "d")}
    out["it"] = {str(k): v for k, v in as_dict(t.get("it")).items() if isinstance(v, (int, float))}
    return out


def add(dst, src):
    for k, v in src.items():
        if k == "it":
            for item, n in v.items():
                dst["it"][item] = dst["it"].get(item, 0) + n
        else:
            dst[k] = dst.get(k, 0) + v


def empty():
    return tally({})


def parse_cast(record):
    """One cast log record ("time,mapID,x,y,result,skill,mod,lure,level,items,spot[,lureID,serverMin,channel,tags[,char]]").
    char is the number of the character that cast (names in the saved "chars").
    Records from before the later fields stop at the spot; anything unreadable is None."""
    if not isinstance(record, str):
        return None
    v = record.split(",")
    v += [""] * (16 - len(v))

    def n(x):
        try:
            return float(x) if "." in x else int(x)
        except ValueError:
            return None
    items = {}
    for part in v[9].split(";"):
        a, _, b = part.partition(":")
        if n(a) is not None and n(b) is not None:
            items[str(n(a))] = n(b)
    tags = {}
    for part in v[14].split(";"):
        if part:
            k, eq, val = part.partition("=")
            tags[k] = (n(val) if n(val) is not None else val) if eq else True
    if not isinstance(n(v[0]), int):
        return None
    server = n(v[12])
    return {"t": n(v[0]), "m": n(v[1]), "result": v[4] or None, "skill": n(v[5]), "mod": n(v[6]), "lure": v[7] == "1",
            "level": n(v[8]), "items": items, "sub": v[10], "lureID": n(v[11]), "serverMin": server,
            "serverHour": server // 60 if isinstance(server, int) else None, "channel": n(v[13]), "tags": tags,
            "char": n(v[15])}


def build_data(dbs):
    """Merges the fishing data of several SavedVariables into page data."""
    maps, names, prices, threats, sessions, lures = {}, {}, {}, [], [], {}
    hours = {h: {"n": 0, "c": 0, "a": 0, "it": {}} for h in range(24)}
    casts = 0

    def entry(map_id):
        return maps.setdefault(int(map_id), {"name": str(map_id), "cells": {}, "spots": {}})

    for db in dbs:
        f = as_dict(db.get("fishing"))
        for realm in as_dict(db.get("prices")).values():
            for item, e in as_dict(realm).items():
                p = as_dict(e).get("p")
                if isinstance(p, (int, float)) and p > 0:
                    key = str(item)
                    prices[key] = min(prices.get(key, p), p)
        for item, name in as_dict(f.get("names")).items():
            if isinstance(name, str):
                names[str(item)] = name
        for map_id, name in as_dict(f.get("maps")).items():
            if isinstance(name, str):
                entry(map_id)["name"] = name
        for map_id, cells in as_dict(f.get("cells")).items():
            target = entry(map_id)["cells"]
            for key, t in as_dict(cells).items():
                if isinstance(key, str) and ":" in key:
                    add(target.setdefault(key, empty()), tally(t))
        for map_id, spots in as_dict(f.get("spots")).items():
            target = entry(map_id)["spots"]
            for name, s in as_dict(spots).items():
                s = as_dict(s)
                spot = target.setdefault(str(name), {"all": empty(), "bands": {}, "px": 0, "py": 0, "pn": 0})
                for band, t in as_dict(s.get("b")).items():
                    t = tally(t)
                    add(spot["all"], {k: v for k, v in t.items() if k in ("n", "c", "a", "m", "t", "i", "it")})
                    add(spot["bands"].setdefault(str(band), empty()), t)
                for k in ("s", "x", "p", "u", "e", "d"):
                    spot["all"][k] += s.get(k) or 0
                for k in ("px", "py", "pn"):
                    spot[k] += s.get(k) or 0
        for key, t in as_dict(f.get("lures")).items():
            t, raw = tally(t), as_dict(t)
            t["ms"] = raw.get("ms") if isinstance(raw.get("ms"), (int, float)) else 0
            t["mn"] = raw.get("mn") if isinstance(raw.get("mn"), (int, float)) else 0
            add(lures.setdefault(str(key), dict(empty(), ms=0, mn=0)), t)
        for record in census_viewer.as_list(f.get("casts")):
            c = parse_cast(record)
            if not c:
                continue
            casts += 1
            h = hours.get(c["serverHour"])
            if h is not None and c["result"] in ("c", "a"):
                h["n"] += 1
                h[c["result"]] += 1
                if c["result"] == "c":
                    for item, k in c["items"].items():
                        h["it"][item] = h["it"].get(item, 0) + k
        for r in census_viewer.as_list(f.get("threats")):
            r = as_dict(r)
            if num(r.get("t")) is not None:
                threats.append({k: r.get(k) for k in ("t", "m", "k", "who", "lvl", "cls", "sub", "died")})
        for s in census_viewer.as_list(f.get("sessions")) + ([f["session"]] if isinstance(f.get("session"), dict) else []):
            s = as_dict(s)
            if num(s.get("start")) is not None:
                t = tally(s)
                t.update({"start": s.get("start"), "zone": s.get("zone"), "char": s.get("char"),
                          "skill0": s.get("skill0"), "skill1": s.get("skill1")})
                sessions.append(t)
    threats.sort(key=lambda r: r["t"] or 0, reverse=True)
    sessions.sort(key=lambda s: s["start"] or 0, reverse=True)
    for m in maps.values():
        m["labels"] = [[name, s["px"] / s["pn"], s["py"] / s["pn"]] for name, s in m["spots"].items() if s["pn"]]
    return {"maps": maps, "names": names, "prices": {k: round(v * (1 - AH_CUT)) for k, v in prices.items()},
            "threats": threats[:500], "sessions": sessions[:300], "lures": lures,
            "hours": {str(h): t for h, t in hours.items() if t["n"]}, "casts": casts}


def render(data, images, sources):
    data = dict(data, generated=time.strftime("%Y-%m-%d %H:%M"), sources=sources, images=images, grid=GRID)
    payload = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c")
    return PAGE.replace("__NAME__", census_viewer.NAME).replace("__DATA__", payload)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", type=pathlib.Path, help="SavedVariables files (default: all accounts)")
    ap.add_argument("-o", "--out", type=pathlib.Path, default=OUT_DIR / "fishing.html")
    ap.add_argument("--maps", type=pathlib.Path, default=ADDON / "census" / "maps", help="folder of <mapID>.jpg backgrounds")
    ap.add_argument("--open", action="store_true", help="open the page in your browser")
    args = ap.parse_args(argv)

    paths = args.paths or census_viewer.find_saved_variables()
    if not paths:
        print(f"No {census_viewer.NAME} SavedVariables found. Pass the path to WTF/Account/<account>/SavedVariables/{census_viewer.NAME}.lua.")
        return 1
    dbs = []
    for p in paths:
        db = load_db(p)
        print(f"{p}: {len(as_dict(db.get('fishing')).get('casts') or [])} recent casts")
        dbs.append(db)
    data = build_data(dbs)
    images = census_viewer.map_images(data["maps"], args.maps)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(data, images, [str(p) for p in paths]), encoding="utf-8")
    spots = sum(len(m["spots"]) for m in data["maps"].values())
    print(f"{args.out}: {len(data['maps'])} maps, {spots} spots, {len(data['sessions'])} sessions, {len(images)} map images")
    if args.open:
        webbrowser.open(args.out.resolve().as_uri())
    return 0


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__NAME__ Fishing</title>
<style>
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10); --accent: #2a78d6; --bad: #c2410c;
  --heat-0: #cde2fb; --heat-1: #86b6ef; --heat-2: #3987e5; --heat-3: #1c5cab; --heat-4: #0d366b;
  --label-halo: rgba(252,252,251,0.85);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --accent: #3987e5; --bad: #fb923c;
    --heat-0: #184f95; --heat-1: #256abf; --heat-2: #3987e5; --heat-3: #86b6ef; --heat-4: #cde2fb;
    --label-halo: rgba(26,26,25,0.85);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
  --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --accent: #3987e5; --bad: #fb923c;
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
select { font: inherit; color: var(--ink); background: var(--surface); border: 1px solid var(--axis); border-radius: 6px; padding: 4px 6px; max-width: 100%; }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 16px; }
@media (max-width: 900px) { .layout { grid-template-columns: 1fr; } }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px; min-width: 0; }
.mapwrap { position: relative; width: 100%; aspect-ratio: 3 / 2; border-radius: 6px; overflow: hidden; background: var(--page); }
canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
.legend { display: flex; align-items: center; gap: 8px; margin-top: 10px; font-size: 12px; color: var(--ink-2); flex-wrap: wrap; }
.ramp { width: 160px; height: 10px; border-radius: 3px; background: linear-gradient(90deg, var(--heat-0), var(--heat-1), var(--heat-2), var(--heat-3), var(--heat-4)); }
.note { font-size: 12px; color: var(--muted); margin-top: 6px; }
.tip { position: absolute; pointer-events: none; background: var(--surface); color: var(--ink); border: 1px solid var(--border);
  border-radius: 8px; padding: 8px 10px; font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.18); max-width: 260px; display: none; z-index: 2; }
.stat { display: flex; gap: 18px; margin-bottom: 12px; flex-wrap: wrap; }
.stat div { display: flex; flex-direction: column; }
.stat strong { font-size: 22px; font-variant-numeric: tabular-nums; }
.stat span { font-size: 12px; color: var(--ink-2); }
.scroll { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid var(--grid); white-space: nowrap; }
th { color: var(--ink-2); font-weight: 600; }
td.n { text-align: right; font-variant-numeric: tabular-nums; }
td.bad { color: var(--bad); }
.section { margin-top: 16px; }
.empty { color: var(--muted); padding: 30px 0; text-align: center; }
</style>
</head>
<body>
<main>
  <h1>__NAME__ Fishing</h1>
  <p class="sub" id="sub"></p>
  <div class="filters">
    <label>Map <select id="map"></select></label>
    <label>Show <select id="metric"></select></label>
  </div>
  <div class="layout">
    <div class="card">
      <div class="mapwrap" id="mapwrap"><canvas id="cv" width="1200" height="800"></canvas><div class="tip" id="tip"></div></div>
      <div class="legend"><span>less</span><span class="ramp"></span><span>more</span><span id="legend-max"></span></div>
      <p class="note" id="map-note"></p>
    </div>
    <div class="card" id="side"></div>
  </div>
  <div class="card section"><h2>Spots on this map</h2><div class="scroll" id="spots"></div></div>
  <div class="card section"><h2>By lure <span class="note">(every spot and skill)</span></h2><div class="scroll" id="lures"></div></div>
  <div class="card section"><h2>By server hour <span class="note">(the game's clock, from the recent cast log: day and night fish)</span></h2><div class="scroll" id="hours"></div></div>
  <div class="card section"><h2>Encounters while fishing</h2><div class="scroll" id="threats"></div></div>
  <div class="card section"><h2>Sessions</h2><div class="scroll" id="sessions"></div></div>
</main>
<script>
const DATA = __DATA__;
const GRID = DATA.grid;
const $ = id => document.getElementById(id);
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const state = { map: null, metric: "n" };
const KIND = { N: "NPC attack", P: "Player attack", "?": "Attack (who: ?)", E: "Enemy player seen", e: "Player seen (hostility hidden)", D: "You died" };
const CLASSES = { WARRIOR: "Warrior", PALADIN: "Paladin", HUNTER: "Hunter", ROGUE: "Rogue", PRIEST: "Priest", SHAMAN: "Shaman", MAGE: "Mage", WARLOCK: "Warlock", DRUID: "Druid" };
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const itemName = id => DATA.names[id] || `item ${id}`;
const value = it => { let v = 0, missing = 0; for (const [id, n] of Object.entries(it || {})) { const p = DATA.prices[id]; if (p) v += p * n; else missing++; } return [v, missing]; };
const money = c => { c = Math.round(c || 0); if (c <= 0) return "0c"; const g = Math.floor(c / 10000), s = Math.floor(c / 100) % 100, k = c % 100; return [g ? g + "g" : "", s ? s + "s" : "", (!g && k) ? k + "c" : ""].filter(Boolean).join(" "); };
const minutes = s => { const m = (s || 0) / 60; return m >= 90 ? (m / 60).toFixed(1) + " h" : Math.round(m) + " min"; };
const pct = (a, b) => b ? Math.round(a / b * 100) + "%" : "?";
const dateText = t => t ? new Date(t * 1000).toLocaleString() : "?";

function metricValue(t, m) {
  if (m === "n") return t.n; if (m === "c") return t.c; if (m === "v") return value(t.it)[0];
  if (m === "attacks") return t.x + t.p + t.u; if (m === "e") return t.e;
  return (t.it || {})[m.slice(5)] || 0;
}

function init() {
  const ids = Object.keys(DATA.maps).sort((a, b) => Object.values(DATA.maps[b].cells).reduce((s, t) => s + t.n, 0) - Object.values(DATA.maps[a].cells).reduce((s, t) => s + t.n, 0));
  $("sub").textContent = `Generated ${DATA.generated} from ${DATA.sources.length} SavedVariables file(s). Values: your lowest Auction House look after the 5% cut (items never seen there count 0).`;
  $("map").innerHTML = ids.map(id => `<option value="${id}">${esc(DATA.maps[id].name)}</option>`).join("");
  state.map = ids[0] || null;
  $("map").onchange = e => { state.map = e.target.value; state.metric = "n"; metrics(); draw(); };
  $("metric").onchange = e => { state.metric = e.target.value; draw(); };
  $("cv").addEventListener("mousemove", hover);
  $("cv").addEventListener("mouseleave", () => $("tip").style.display = "none");
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", draw);
  metrics(); draw(); lures(); hours(); threats(); sessions();
}

function metrics() {
  const m = DATA.maps[state.map];
  const items = {};
  for (const t of Object.values(m ? m.cells : {})) for (const [id, n] of Object.entries(t.it)) items[id] = (items[id] || 0) + n;
  const opts = [["n", "Casts"], ["c", "Catches"], ["v", "Value caught"], ["attacks", "Attacks"], ["e", "Enemy players seen"]]
    .concat(Object.entries(items).sort((a, b) => b[1] - a[1]).map(([id]) => ["item:" + id, "Fish: " + itemName(id)]));
  $("metric").innerHTML = opts.map(([k, l]) => `<option value="${k}"${k === state.metric ? " selected" : ""}>${esc(l)}</option>`).join("");
}

let images = {};
function draw() {
  const cv = $("cv"), g = cv.getContext("2d"), W = cv.width, H = cv.height;
  g.clearRect(0, 0, W, H);
  const m = DATA.maps[state.map];
  if (!m) { $("side").innerHTML = '<p class="empty">No fishing logged yet.</p>'; return; }
  const src = DATA.images[state.map];
  if (src && !images[state.map]) { const im = new Image(); im.onload = draw; im.src = src; images[state.map] = im; }
  const img = images[state.map] && images[state.map].complete ? images[state.map] : null;
  if (img) g.drawImage(img, 0, 0, W, H);
  const cw = W / GRID, ch = H / GRID;
  let max = 0;
  const cells = Object.entries(m.cells).map(([k, t]) => { const [x, y] = k.split(":").map(Number); const v = metricValue(t, state.metric); if (v > max) max = v; return { x, y, t, v }; }).filter(c => c.v > 0);
  const ramp = [css("--heat-0"), css("--heat-1"), css("--heat-2"), css("--heat-3"), css("--heat-4")];
  for (const c of cells) {
    const f = Math.sqrt(c.v / max);
    g.globalAlpha = img ? 0.55 + 0.4 * f : 0.9;
    g.fillStyle = ramp[Math.min(4, Math.floor(f * 4.999))];
    g.beginPath(); g.roundRect(c.x * cw + 1, c.y * ch + 1, cw - 2, ch - 2, 2); g.fill();
  }
  g.globalAlpha = 1;
  if (!img) {
    g.font = "22px system-ui, sans-serif"; g.textAlign = "center"; g.textBaseline = "middle";
    for (const [name, x, y] of m.labels) {
      g.lineWidth = 4; g.strokeStyle = css("--label-halo"); g.strokeText(name, x * W, y * H - 18);
      g.fillStyle = css("--ink-2"); g.fillText(name, x * W, y * H - 18);
    }
  }
  $("legend-max").textContent = max ? `· darkest square: ${state.metric === "v" ? money(max) : max.toLocaleString()} (square-root scale)` : "";
  $("map-note").textContent = img ? "" : `No background: save a world-map image as census/maps/${state.map}.jpg and re-run. Labels mark where you fished.`;
  side(m); spots(m);
}

function totals(m) {
  const t = { n: 0, c: 0, a: 0, m: 0, s: 0, x: 0, p: 0, u: 0, e: 0, d: 0, it: {} };
  for (const s of Object.values(m.spots)) { for (const k of ["n", "c", "a", "m", "s", "x", "p", "u", "e", "d"]) t[k] += s.all[k]; for (const [id, n] of Object.entries(s.all.it)) t.it[id] = (t.it[id] || 0) + n; }
  return t;
}

function side(m) {
  const t = totals(m), [v] = value(t.it);
  const fish = Object.entries(t.it).sort((a, b) => b[1] - a[1]).slice(0, 12);
  $("side").innerHTML = `<h2>${esc(m.name)}</h2><div class="stat"><div><strong>${t.c.toLocaleString()}</strong><span>catches</span></div>` +
    `<div><strong>${pct(t.c, t.c + t.a)}</strong><span>caught</span></div><div><strong>${minutes(t.s)}</strong><span>fished</span></div>` +
    `<div><strong>${t.s >= 300 ? money(v / (t.s / 3600)) : "?"}</strong><span>per hour</span></div></div>` +
    `<h2>Catches</h2>` + (fish.length ? "<table>" + fish.map(([id, n]) => `<tr><td>${esc(itemName(id))}</td><td class=n>${n}</td><td class=n>${pct(n, t.c)}</td></tr>`).join("") + "</table>" : '<p class="empty">Nothing caught.</p>') +
    `<h2 style="margin-top:12px">Danger</h2><p>${t.x} NPC attacks · ${t.p} player attacks · ${t.u} unclear · ${t.e} enemies seen${t.d ? ` · <b>${t.d} deaths</b>` : ""}</p>` +
    `<p class="note">${t.s >= 900 ? `Chance of 30 min without an attack: ~${Math.round(Math.exp(-30 * (t.x + t.p + t.u) / (t.s / 60)) * 100)}%` : "Too little fishing here to estimate the danger."}</p>`;
}

function every(n, s) { return s < 300 ? "?" : n ? `1 / ${minutes(s / n)}` : `0 in ${minutes(s)}`; }

function spots(m) {
  const rows = Object.entries(m.spots).map(([name, s]) => { const [v, missing] = value(s.all.it); return { name, s, v, missing }; })
    .sort((a, b) => (b.s.all.s ? b.v / b.s.all.s : 0) - (a.s.all.s ? a.v / a.s.all.s : 0));
  $("spots").innerHTML = rows.length ? "<table><tr><th>Spot</th><th class=n>Casts</th><th class=n>Caught</th><th class=n>Got away</th><th class=n>Missed</th><th class=n>Fished</th><th class=n>Per hour</th><th>By skill (caught)</th><th class=n>NPC attacks</th><th class=n>Player attacks</th><th class=n>Enemies seen</th><th>Top fish</th></tr>" +
    rows.map(r => {
      const a = r.s.all;
      const bands = Object.entries(r.s.bands).filter(([b]) => b !== "unknown").sort((x, y) => x[0] - y[0]).map(([b, t]) => `${b}+: ${pct(t.c, t.c + t.a)}`).join(", ");
      const top = Object.entries(a.it).sort((x, y) => y[1] - x[1]).slice(0, 3).map(([id]) => itemName(id)).join(", ");
      return `<tr><td>${esc(r.name)}</td><td class=n>${a.n}</td><td class=n>${pct(a.c, a.c + a.a)}</td><td class=n>${a.a}</td><td class=n>${a.m}</td><td class=n>${minutes(a.s)}</td>` +
        `<td class=n>${a.s >= 300 ? money(r.v / (a.s / 3600)) : "?"}</td><td>${esc(bands)}</td><td class="n${a.x ? " bad" : ""}">${every(a.x, a.s)}</td>` +
        `<td class="n${a.p ? " bad" : ""}">${every(a.p, a.s)}</td><td class=n>${every(a.e, a.s)}</td><td>${esc(top)}</td></tr>`;
    }).join("") + "</table>" : '<p class="empty">No spots on this map.</p>';
}

const LURE_BONUS = { 263: 25, 264: 50, 265: 75, 266: 100, 2603: 75 };
const lureName = k => k === "none" ? "No lure" : k === "on" ? "Lure (which: ?)" : k === "?" ? "Lure: ?" : LURE_BONUS[k] ? `+${LURE_BONUS[k]} lure` : `Lure #${k}`;

function lures() {
  const rows = Object.entries(DATA.lures || {}).filter(([, t]) => t.n).sort((a, b) => b[1].n - a[1].n);
  $("lures").innerHTML = rows.length ? "<table><tr><th>Lure</th><th class=n>Casts</th><th class=n>Caught</th><th class=n>Got away</th><th class=n>Missed</th><th class=n>Fished</th><th class=n>Per hour</th><th class=n>Avg skill +</th></tr>" + rows.map(([k, t]) => {
    const [v] = value(t.it);
    return `<tr><td>${esc(lureName(k))}</td><td class=n>${t.n}</td><td class=n>${pct(t.c, t.c + t.a)}</td><td class=n>${t.a}</td><td class=n>${t.m}</td><td class=n>${minutes(t.s)}</td>` +
      `<td class=n>${t.s >= 300 ? money(v / (t.s / 3600)) : "?"}</td><td class=n>${t.mn ? Math.round(t.ms / t.mn) : "?"}</td></tr>`;
  }).join("") + "</table>" : '<p class="empty">No casts by lure yet (logged since this version).</p>';
}

function hours() {
  const rows = Object.entries(DATA.hours || {}).sort((a, b) => a[0] - b[0]);
  $("hours").innerHTML = rows.length ? "<table><tr><th>Server hour</th><th class=n>Bites</th><th class=n>Caught</th><th>Top fish</th></tr>" + rows.map(([h, t]) => {
    const top = Object.entries(t.it).sort((x, y) => y[1] - x[1]).slice(0, 4).map(([id, n]) => `${n}× ${itemName(id)}`).join(", ");
    return `<tr><td>${String(h).padStart(2, "0")}:00</td><td class=n>${t.n}</td><td class=n>${pct(t.c, t.n)}</td><td>${esc(top)}</td></tr>`;
  }).join("") + "</table>" : '<p class="empty">No casts with the server time yet (logged since this version).</p>';
}

function threats() {
  const rows = DATA.threats;
  $("threats").innerHTML = rows.length ? "<table><tr><th>When</th><th>What</th><th>Who</th><th>Where</th></tr>" + rows.slice(0, 200).map(r =>
    `<tr><td>${dateText(r.t)}</td><td class="${"NP?D".includes(r.k) ? "bad" : ""}">${KIND[r.k] || esc(r.k)}${r.died ? " · you died" : ""}</td>` +
    `<td>${esc(r.who || "")} ${r.lvl === -1 ? "??" : esc(r.lvl ?? "")} ${CLASSES[r.cls] || ""}</td><td>${esc(r.sub || "")}${DATA.maps[r.m] ? ", " + esc(DATA.maps[r.m].name) : ""}</td></tr>`).join("") + "</table>"
    : '<p class="empty">No attacks or enemy players while fishing.</p>';
}

function sessions() {
  const rows = DATA.sessions;
  $("sessions").innerHTML = rows.length ? "<table><tr><th>Started</th><th>Character</th><th>Zone</th><th class=n>Fished</th><th class=n>Caught</th><th class=n>Value</th><th class=n>Per hour</th><th class=n>Skill</th><th class=n>Attacks</th></tr>" + rows.map(s => {
    const [v] = value(s.it);
    return `<tr><td>${dateText(s.start)}</td><td>${esc(s.char)}</td><td>${esc(s.zone)}</td><td class=n>${minutes(s.s)}</td><td class=n>${s.c}/${s.n}</td>` +
      `<td class=n>${money(v)}</td><td class=n>${s.s >= 300 ? money(v / (s.s / 3600)) : "?"}</td><td class=n>${s.skill1 && s.skill0 && s.skill1 > s.skill0 ? "+" + (s.skill1 - s.skill0) : "-"}</td><td class=n>${s.x + s.p + s.u}</td></tr>`;
  }).join("") + "</table>" : '<p class="empty">No sessions.</p>';
}

function hover(e) {
  const m = DATA.maps[state.map]; if (!m) return;
  const rect = e.target.getBoundingClientRect();
  const gx = Math.floor((e.clientX - rect.left) / rect.width * GRID), gy = Math.floor((e.clientY - rect.top) / rect.height * GRID);
  let t = m.cells[`${gx}:${gy}`];
  if (!t) for (let dy = -1; dy <= 1 && !t; dy++) for (let dx = -1; dx <= 1 && !t; dx++) t = m.cells[`${gx + dx}:${gy + dy}`];
  const tip = $("tip");
  if (!t) { tip.style.display = "none"; return; }
  const fish = Object.entries(t.it).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([id, n]) => `${n}× ${esc(itemName(id))}`).join("<br>");
  tip.innerHTML = `<b>${t.n}</b> casts, <b>${t.c}</b> caught (${pct(t.c, t.c + t.a)}), ${minutes(t.s)}<br>Value ${money(value(t.it)[0])}` +
    (t.x + t.p + t.u + t.e ? `<br>Attacks: ${t.x} NPC, ${t.p} player, ${t.u} ? · enemies seen ${t.e}` : "") + (fish ? "<br>" + fish : "");
  tip.style.display = "block";
  const wrap = $("mapwrap").getBoundingClientRect();
  let left = e.clientX - wrap.left + 14, top = e.clientY - wrap.top + 14;
  if (left + tip.offsetWidth > wrap.width) left = e.clientX - wrap.left - tip.offsetWidth - 14;
  if (top + tip.offsetHeight > wrap.height) top = e.clientY - wrap.top - tip.offsetHeight - 14;
  tip.style.left = left + "px"; tip.style.top = top + "px";
}

init();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    sys.exit(main())
