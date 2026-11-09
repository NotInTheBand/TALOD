"""WoW Forever's own client tables (DB2 exports on wago.tools, product "wowf"),
used to correct recipe data first read from Wowhead Classic.

Forever is not Classic Era: its client renames items, changes reagents and
difficulty colors, moves some recipes to another profession and gives some
recipes new spell IDs (Minor Healing Potion is 1244431 there, 2330 on Era).
Wowhead's Forever database refuses automated requests, so the generators keep
reading Wowhead Classic for what the client tables do not hold (where a recipe
is learned, trainer costs, patterns and their vendors, tools, icons) and take
the rest from here.

What the client tables cannot say:
  - which recipes the Forever servers actually teach: the tables also carry
    Season of Discovery recipes, so only recipes Wowhead Classic lists are
    kept (and their Forever replacements, found by the item they create);
  - the skill a recipe is learned at (orange): the trainer data is
    server-side. When Forever lowered a recipe's yellow below the Classic
    learn skill, the learn skill is lowered to the yellow and marked
    `learnGuess` (checked in game later).

    tables = load(refresh)               # cached in tools/cache/wago_wowf_*.csv
    report = apply_recipes(recipes, tables)
    apply_items(items, tables, vendor_ids)
"""
import collections
import csv
import io
import sys

from gen_enhancements import fetch

PRODUCT = "wowf"
WAGO = "https://wago.tools/db2/{}/csv?product=" + PRODUCT
TABLES = ("SkillLineAbility", "SpellReagents", "SpellEffect", "ItemSparse", "SpellName")
SKILL_LINES = {"Alchemy": 171, "Blacksmithing": 164, "Cooking": 185, "Enchanting": 333, "Engineering": 202,
               "First Aid": 129, "Leatherworking": 165, "Tailoring": 197, "Mining": 186}
PROF_OF = {v: k for k, v in SKILL_LINES.items()}
CREATE_ITEM = "24"          # SpellEffect.Effect: create item
REAGENT_SLOTS = 8


def _rows(name, refresh):
    csv.field_size_limit(min(sys.maxsize, 2 ** 31 - 1))
    text = fetch(WAGO.format(name), f"wago_{PRODUCT}_{name}.csv", refresh)
    return csv.DictReader(io.StringIO(text))


def load(refresh=False):
    t = {"ability": {}, "reagents": {}, "creates": {}, "items": {}, "names": {}}
    for r in _rows("SkillLineAbility", refresh):
        line = int(r["SkillLine"])
        if line in PROF_OF:
            t["ability"].setdefault(int(r["Spell"]), r)
    for r in _rows("SpellReagents", refresh):
        lst = [[int(r[f"Reagent_{i}"]), int(r[f"ReagentCount_{i}"])] for i in range(REAGENT_SLOTS)
               if int(r[f"Reagent_{i}"] or 0) > 0]
        t["reagents"][int(r["SpellID"])] = lst
    for r in _rows("SpellEffect", refresh):
        if r["Effect"] == CREATE_ITEM and int(r["EffectItemType"] or 0) > 0:
            t["creates"].setdefault(int(r["SpellID"]), (int(r["EffectItemType"]), float(r["EffectBasePointsF"] or 0)))
    for r in _rows("ItemSparse", refresh):
        t["items"][int(r["ID"])] = {"name": r["Display_lang"], "q": int(r["OverallQualityID"] or 1),
                                    "sell": int(r["SellPrice"] or 0), "buy": int(r["BuyPrice"] or 0)}
    for r in _rows("SpellName", refresh):
        t["names"][int(r["ID"])] = r["Name_lang"]
    # Created item -> Forever recipe spells, per skill line (finds re-numbered recipes).
    by_item = collections.defaultdict(list)
    for sid, (item, _) in t["creates"].items():
        a = t["ability"].get(sid)
        if a and sid in t["reagents"]:
            by_item[(int(a["SkillLine"]), item)].append(sid)
    t["by_item"] = by_item
    return t


def _colors(a, old, skill):
    """Forever yellow / grey from the client; green halfway (the Classic rule
    the Wowhead data follows); orange never above yellow. Wowhead leaves orange
    0 on some recipes (Smelt Tin): the planner would read that as "orange from
    0", so it becomes the learn skill."""
    lo, hi = int(a["TrivialSkillLineRankLow"]), int(a["TrivialSkillLineRankHigh"])
    if not hi:
        return None
    orange = old[0] if old and old[0] else skill
    return [max(1, min(orange, lo)), lo, (lo + hi) // 2, hi]


def apply_recipes(recipes, t):
    """Correct `recipes` (spell ID -> recipe, as gen_professions builds them) in
    place from the Forever tables. Returns a Counter of what changed."""
    n = collections.Counter()
    for sid in sorted(recipes):
        r = recipes[sid]
        fid = sid
        a = t["ability"].get(sid)
        if a is None or sid not in t["reagents"]:
            # Re-numbered on Forever: the same profession's recipe that makes the same item.
            cands = t["by_item"].get((SKILL_LINES[r["prof"]], r.get("creates")), []) if r.get("creates") else []
            for prof, line in SKILL_LINES.items():
                if not cands and r.get("creates"):
                    cands = t["by_item"].get((line, r["creates"]), [])
            if len(cands) == 1 and cands[0] not in recipes:
                fid = cands[0]
                a = t["ability"][fid]
                n["renumbered"] += 1
            elif a is None:
                n["not_in_client"] += 1
                continue
        prof = PROF_OF[int(a["SkillLine"])]
        if prof != r["prof"]:
            r["prof"] = prof
            n["profession"] += 1
        colors = _colors(a, r["colors"], r["skill"])
        if colors and colors != r["colors"]:
            r["colors"] = colors
            n["colors"] += 1
            if r["skill"] > colors[1]:
                r["skill"] = max(1, colors[1])
                r["learnGuess"] = True
                n["learn_lowered"] += 1
        ups = int(a["NumSkillUps"] or 1)
        if ups > 1 and r.get("up") != ups:
            r["up"] = ups
            n["skillups"] += 1
        reag = t["reagents"].get(fid)
        if reag and sorted(reag) != sorted(r["reagents"]):
            r["reagents"] = reag
            n["reagents"] += 1
        c = t["creates"].get(fid)
        if c:
            item, points = c
            if r.get("creates") != item:
                r["creates"] = item
                n["creates"] += 1
            # 0 on oils and transmutes: they make one, as on Classic.
            makes = int(points) if points == int(points) else round(points, 1)
            if makes >= 1 and r.get("makes") != makes:
                r["makes"] = makes
                n["makes"] += 1
        name = t["names"].get(fid)
        if name and name != r["name"]:
            r["name"] = name
            n["names"] += 1
        if fid != sid:
            r["classic"] = sid
            r["forever"] = True
            recipes[fid] = recipes.pop(sid)
    return n


def apply_items(items, t, vendor_ids):
    """Correct item entries (item ID -> {name, q, sell, vendor, ...}) in place."""
    n = collections.Counter()
    for iid, it in items.items():
        f = t["items"].get(iid)
        if not f:
            n["not_in_client"] += 1
            continue
        if f["name"] and f["name"] != it.get("name"):
            it["name"] = f["name"]
            n["names"] += 1
        if f["q"] != it.get("q"):
            it["q"] = f["q"]
            n["quality"] += 1
        if f["sell"] != (it.get("sell") or 0):
            if f["sell"]:
                it["sell"] = f["sell"]
            else:
                it.pop("sell", None)
            n["sell"] += 1
        # The client's buy price is the item's price field, not proof a vendor
        # sells it: only for the hand list of vendor goods.
        if iid in vendor_ids and f["buy"] and f["buy"] != it.get("vendor"):
            it["vendor"] = f["buy"]
            n["vendor"] += 1
    return n


def item_entry(iid, t):
    """A new item entry for an item only the Forever tables know (e.g. Mote of Magic)."""
    f = t["items"].get(iid)
    if not f:
        return {"name": f"Item {iid}", "q": 1}
    e = {"name": f["name"], "q": f["q"]}
    if f["sell"]:
        e["sell"] = f["sell"]
    return e


def apply_same_ids(recipes, t):
    """For EnhanceData: correct recipes in place under their own spell IDs
    (enhancements point at them): profession, grey, reagents, yield, name.
    A recipe Forever re-numbered keeps its Classic numbers here."""
    n = collections.Counter()
    for sid, r in recipes.items():
        a = t["ability"].get(sid)
        if a is None or sid not in t["reagents"]:
            n["not_in_client"] += 1
            continue
        prof = PROF_OF[int(a["SkillLine"])]
        if prof != r["prof"]:
            r["prof"] = prof
            n["profession"] += 1
        lo, hi = int(a["TrivialSkillLineRankLow"]), int(a["TrivialSkillLineRankHigh"])
        if hi and r.get("grey") != hi:
            r["grey"] = hi
            n["grey"] += 1
        if lo and r.get("skill") and r["skill"] > lo:
            r["skill"] = max(1, lo)
            r["learnGuess"] = True
            n["learn_lowered"] += 1
        reag = t["reagents"][sid]
        if reag and sorted(reag) != sorted(r["reagents"]):
            r["reagents"] = reag
            n["reagents"] += 1
        c = t["creates"].get(sid)
        if c and c[1] >= 1 and c[1] == int(c[1]) and r.get("makes") != int(c[1]):
            r["makes"] = int(c[1])
            n["makes"] += 1
        name = t["names"].get(sid)
        if name and name != r["name"]:
            r["name"] = name
            n["names"] += 1
    return n
