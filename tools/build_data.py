"""Builds Sourcebook's data files.

	python tools/build_data.py [--build 1.60.1.70862] [--vmangos path/to/mangos.sqlite]

Writes two generated files (both are rebuilt from scratch; never edit them by hand):

	Sourcebook/Data/Recipes.lua      Recipes, reagents and recipe items, from the game's own tables
	                                 (wago.tools CSV exports of the Forever client build).
	Sourcebook_Loot/Loot.lua         Who drops, sells, skins or holds each item, with chances, from
	                                 the VMaNGOS world database (GPL-2.0), placed on the Forever maps.

Downloads are cached in tools/.cache/. Every string format in the output is described in the
header comment of the file it appears in.
"""

import argparse
import csv
import io
import json
import math
import os
import sqlite3
import statistics
import sys
import urllib.request
import zipfile
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from areas import Areas  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(REPO, "tools", ".cache")
DEFAULT_BUILD = "1.60.1.70862"
PATCH = 10  # VMaNGOS content patch: 10 = 1.12, the last vanilla patch
UA = "Sourcebook-build/1.0"

# Profession skill lines (vanilla IDs; Forever keeps them).
PROFESSIONS = [164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 129]

# Lock types that mean a gathering skill (Lock.csv Type=2 "lock type", Index = LockType).
LOCK_HERB, LOCK_MINE, LOCK_FISH = 2, 3, 19

# How many sources of each kind an item keeps; the rest are counted.
KEEP_PER_KIND = 12
VENDORS_KEEP = 80  # vendors can't be ranked offline; the addon sorts them by distance
NPC_DROPS_KEEP = 10


# ---------------------------------------------------------------- downloads

def fetch(url, path):
	if os.path.exists(path) and os.path.getsize(path) > 0:
		return path
	os.makedirs(os.path.dirname(path), exist_ok=True)
	print("download", url, file=sys.stderr)
	req = urllib.request.Request(url, headers={"User-Agent": UA})
	with urllib.request.urlopen(req, timeout=300) as r, open(path + ".part", "wb") as f:
		while True:
			chunk = r.read(1 << 20)
			if not chunk:
				break
			f.write(chunk)
	os.replace(path + ".part", path)
	return path


def db2(build, table):
	path = os.path.join(CACHE, "db2", build, table + ".csv")
	fetch(f"https://wago.tools/db2/{table}/csv?build={build}", path)
	with open(path, encoding="utf-8", newline="") as f:
		return list(csv.DictReader(f))


def vmangos_db():
	path = os.path.join(CACHE, "vmangos", "mangos.sqlite")
	if os.path.exists(path):
		return path
	req = urllib.request.Request("https://api.github.com/repos/vmangos/core/releases/tags/db_latest", headers={"User-Agent": UA})
	with urllib.request.urlopen(req, timeout=60) as r:
		assets = json.load(r)["assets"]
	asset = next(a for a in assets if a["name"].startswith("db-sqlite-"))
	zpath = fetch(asset["browser_download_url"], os.path.join(CACHE, "vmangos", asset["name"]))
	with zipfile.ZipFile(zpath) as z:
		name = next(n for n in z.namelist() if n.endswith("mangos.sqlite"))
		with z.open(name) as src, open(path, "wb") as dst:
			while True:
				chunk = src.read(1 << 20)
				if not chunk:
					break
				dst.write(chunk)
	return path


def i(v):
	try:
		return int(v)
	except (TypeError, ValueError):
		return int(float(v))


def lua_str(s):
	out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")
	return '"' + out + '"'


# ---------------------------------------------------------------- recipes

def build_recipes(build):
	skill_lines = {i(r["ID"]): r for r in db2(build, "SkillLine")}
	sla = [r for r in db2(build, "SkillLineAbility") if i(r["SkillLine"]) in PROFESSIONS]
	reagents = {}
	for r in db2(build, "SpellReagents"):
		pairs = []
		for k in range(8):
			item, count = i(r[f"Reagent_{k}"]), i(r[f"ReagentCount_{k}"])
			if item > 0 and count > 0:
				pairs.append((item, count))
		reagents[i(r["SpellID"])] = pairs
	creates = {}
	learns = {}
	for r in db2(build, "SpellEffect"):
		effect, spell = i(r["Effect"]), i(r["SpellID"])
		if effect == 24 and i(r["EffectItemType"]) > 0 and spell not in creates:
			amount = max(1, int(round(float(r["EffectBasePointsF"] or 1))))
			creates[spell] = (i(r["EffectItemType"]), amount)
		elif effect == 36 and i(r["EffectTriggerSpell"]) > 0:
			learns[spell] = i(r["EffectTriggerSpell"])
	item_effect_spell = {i(r["ID"]): i(r["SpellID"]) for r in db2(build, "ItemEffect")}

	recipes = {}
	for r in sla:
		spell = i(r["Spell"])
		pairs = reagents.get(spell)
		if not pairs:
			continue  # gathering abilities, skill ranks, etc.
		item, amount = creates.get(spell, (0, 1))
		recipes[spell] = {
			"skill": i(r["SkillLine"]),
			"item": item,
			"count": amount,
			"orange": i(r["MinSkillLineRank"]),
			"yellow": i(r["TrivialSkillLineRankLow"]),
			"gray": i(r["TrivialSkillLineRankHigh"]),
			"reagents": pairs,
			"auto": i(r["AcquireMethod"]) == 1,
		}

	teaches = {}
	for r in db2(build, "ItemXItemEffect"):
		spell = item_effect_spell.get(i(r["ItemEffectID"]))
		target = learns.get(spell, spell)
		if target in recipes:
			teaches[i(r["ItemID"])] = target
	for item, spell in teaches.items():
		recipes[spell].setdefault("taughtBy", []).append(item)

	names = {k: skill_lines[k]["DisplayName_lang"] for k in PROFESSIONS}
	return recipes, teaches, names


def write_recipes(build, recipes, teaches, names):
	path = os.path.join(REPO, "Sourcebook", "Data", "Recipes.lua")
	lines = [
		f"-- GENERATED by tools/build_data.py from the game's own tables (Forever build {build}). Do not edit.",
		"--",
		"-- ns.Professions[skillLineID] = English name (the game's localized name is used when it has one).",
		"-- ns.Recipes[spellID] = { skillLine, createdItemID (0 = none, e.g. an enchant), createdCount,",
		"--     orange, yellow, gray (skill ranks), learnedFrom (0 = trainer/automatic, else a recipe item ID),",
		"--     reagentID, count, reagentID, count, ... }",
		"-- ns.RecipeItems[itemID] = spellID the recipe item teaches.",
		"",
		"local _, ns = ...",
		"",
		"ns.Professions = {",
	]
	for k in sorted(names):
		lines.append(f"\t[{k}] = {lua_str(names[k])},")
	lines += ["}", "", "ns.Recipes = {"]
	for spell in sorted(recipes):
		r = recipes[spell]
		taught = min(r.get("taughtBy", [0]))
		flat = [r["skill"], r["item"], r["count"], r["orange"], r["yellow"], r["gray"], taught]
		for item, count in r["reagents"]:
			flat += [item, count]
		lines.append(f"\t[{spell}] = {{ {', '.join(str(v) for v in flat)} }},")
	lines += ["}", "", "ns.RecipeItems = {"]
	for item in sorted(teaches):
		lines.append(f"\t[{item}] = {teaches[item]},")
	lines += ["}", ""]
	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write("\n".join(lines))
	print(f"wrote {path}: {len(recipes)} recipes, {len(teaches)} recipe items, {os.path.getsize(path) / 1e3:.0f} KB")


# ---------------------------------------------------------------- maps

class Placer:
	"""Turns server world positions into Forever UI map coordinates, like the client does.

	The zone comes from the terrain's area ID (tools/areas.py), walked up to its top-level zone;
	the zone's map rectangle then gives the percent coordinates.
	"""

	def __init__(self, build, wow_root):
		ui_maps = {i(r["ID"]): r for r in db2(build, "UiMap")}
		self.zone_rect = {}
		for r in db2(build, "UiMapAssignment"):
			ui = i(r["UiMapID"])
			m = ui_maps.get(ui)
			if not m or i(m["Type"]) not in (3, 6) or i(r["AreaID"]) == 0:
				continue  # continents and the world map are too coarse
			rect = (float(r["Region_0"]), float(r["Region_1"]), float(r["Region_3"]), float(r["Region_4"]), ui)
			self.zone_rect[(i(r["MapID"]), i(r["AreaID"]))] = rect
		self.parent = {i(r["ID"]): i(r["ParentAreaID"]) for r in db2(build, "AreaTable")}
		self.maps = {i(r["ID"]): r for r in db2(build, "Map")}
		wdts = {m: i(r["WdtFileDataID"]) for m, r in self.maps.items() if i(r["WdtFileDataID"]) > 0}
		self.areas = Areas(wow_root, wdts)
		self.misses = 0

	def instance(self, map_id):
		m = self.maps.get(map_id)
		return m is not None and i(m["InstanceType"]) in (1, 2)

	def zone_of(self, area):
		seen = 0
		while area and self.parent.get(area) and seen < 8:
			area = self.parent[area]
			seen += 1
		return area

	def place(self, map_id, x, y):
		"""Returns (uiMapID, xPercent, yPercent) or None."""
		area = self.areas.area(map_id, x, y)
		rect = self.zone_rect.get((map_id, area)) or self.zone_rect.get((map_id, self.zone_of(area)))
		if not rect:
			self.misses += 1
			return None
		min_x, min_y, max_x, max_y, ui = rect
		ux = (max_y - y) / (max_y - min_y) * 100
		uy = (max_x - x) / (max_x - min_x) * 100
		return ui, round(min(100, max(0, ux)), 1), round(min(100, max(0, uy)), 1)


def summarize_spawns(placer, spawns, keep_points):
	"""spawns: [(map, x, y)]. Returns the location string (see Loot.lua header)."""
	by_zone = defaultdict(list)
	instances = defaultdict(int)
	for map_id, x, y in spawns:
		if placer.instance(map_id):
			instances[map_id] += 1
			continue
		p = placer.place(map_id, x, y)
		if p:
			by_zone[p[0]].append((p[1], p[2]))
	# Open-world zones first (you can walk there and get a waypoint), then instances.
	parts = []
	for ui, pts in sorted(by_zone.items(), key=lambda kv: -len(kv[1])):
		chosen = thin(pts, keep_points)
		coords = ":".join(f"{x:g}:{y:g}" for x, y in chosen)
		parts.append(f"{ui}:{len(pts)}:{coords}")
	for map_id, n in sorted(instances.items(), key=lambda kv: -kv[1]):
		parts.append(f"i{map_id}:{n}")
	return ",".join(parts)


JUNK_WORDS = ("test", "[dnt]", "[ph]", "zzold", "unused", "deprecated", "(old)", "qa ")


def is_junk(name):
	n = (name or "").lower()
	return not n or any(w in n for w in JUNK_WORDS)


def thin(points, keep):
	"""Picks up to `keep` points spread across the set (farthest-point sampling from the median)."""
	if len(points) <= keep:
		return points
	mx = statistics.median(p[0] for p in points)
	my = statistics.median(p[1] for p in points)
	first = min(points, key=lambda p: (p[0] - mx) ** 2 + (p[1] - my) ** 2)
	chosen = [first]
	dist = [(p[0] - first[0]) ** 2 + (p[1] - first[1]) ** 2 for p in points]
	while len(chosen) < keep:
		k = max(range(len(points)), key=dist.__getitem__)
		if dist[k] == 0:
			break
		chosen.append(points[k])
		for j, p in enumerate(points):
			d = (p[0] - points[k][0]) ** 2 + (p[1] - points[k][1]) ** 2
			if d < dist[j]:
				dist[j] = d
	return chosen


# ---------------------------------------------------------------- loot

def patch_ok(row):
	return row["patch_min"] <= PATCH <= row["patch_max"]


def load_templates(c, table):
	out = defaultdict(list)
	for row in c.execute(f"select * from {table}"):
		if patch_ok(row):
			out[row["entry"]].append(row)
	return out


class Resolver:
	"""Expands a loot template into {itemID: (chancePercent, minCount, maxCount, quest)}.

	MaNGOS rules: ungrouped entries roll on their own chance. Within a group, entries with an
	explicit chance take it; entries with chance 0 split what is left of 100% equally. A negative
	chance is a quest drop (only seen while on the quest). A negative mincount is a reference to
	reference_loot_template, rolled maxcount times with the entry's chance.
	"""

	def __init__(self, refs):
		self.refs = refs
		self.cache = {}

	def expand(self, rows, depth=0):
		out = {}
		groups = defaultdict(list)
		for r in rows:
			if r["groupid"]:
				groups[r["groupid"]].append(r)
			else:
				self._add(out, r, r["ChanceOrQuestChance"], depth)
		for members in groups.values():
			explicit = sum(abs(r["ChanceOrQuestChance"]) for r in members if r["ChanceOrQuestChance"] != 0)
			equal = [r for r in members if r["ChanceOrQuestChance"] == 0]
			share = max(0.0, 100.0 - explicit) / len(equal) if equal else 0.0
			for r in members:
				chance = r["ChanceOrQuestChance"] if r["ChanceOrQuestChance"] != 0 else share
				self._add(out, r, chance, depth)
		return out

	def _add(self, out, r, chance, depth):
		quest = chance < 0
		chance = abs(chance)
		if chance <= 0:
			return
		if r["mincountOrRef"] < 0:
			if depth > 4:
				return
			ref = -r["mincountOrRef"]
			if ref not in self.cache:
				self.cache[ref] = self.expand(self.refs.get(ref, []), depth + 1)
			rolls = max(1, r["maxcount"])
			for item, (c2, lo, hi, q2) in self.cache[ref].items():
				p = 1 - (1 - chance / 100 * c2 / 100) ** rolls
				merge(out, item, p * 100, lo, hi, quest or q2)
			return
		merge(out, r["item"], chance, max(1, r["mincountOrRef"]), max(1, r["maxcount"]), quest)


def merge(out, item, chance, lo, hi, quest):
	old = out.get(item)
	if old:
		p = 1 - (1 - old[0] / 100) * (1 - chance / 100)
		out[item] = (p * 100, min(old[1], lo), max(old[2], hi), old[3] and quest)
	else:
		out[item] = (min(chance, 100.0), lo, hi, quest)


def latest_rows(c, table, key="entry"):
	"""Template tables have one row per patch; keep the newest one at or before PATCH."""
	best = {}
	for row in c.execute(f"select * from {table} where patch <= ? order by patch", (PATCH,)):
		best[row[key]] = row
	return best


def build_loot(build, db_path, wow_root, recipes, teaches):
	c = sqlite3.connect(db_path)
	c.row_factory = sqlite3.Row
	placer = Placer(build, wow_root)
	items_db2 = {i(r["ID"]): r for r in db2(build, "Item")}
	sparse = {i(r["ID"]): r for r in db2(build, "ItemSparse")}
	locks = {i(r["ID"]): r for r in db2(build, "Lock")}
	# wago's ItemSparse export is missing about 40% of rows, so VMaNGOS fills the gaps.
	vm_quality = {row["entry"]: row["quality"] for row in latest_rows(c, "item_template").values()}

	def quality(item):
		s = sparse.get(item)
		return i(s["OverallQualityID"]) if s else vm_quality.get(item, 0)

	reagent_ids = {item for r in recipes.values() for item, _ in r["reagents"]}
	crafted_ids = {r["item"] for r in recipes.values() if r["item"]}

	def wanted(item):
		"""Items worth a source list: reagents, recipes, gear and bags of note, consumables."""
		if item in reagent_ids or item in teaches or item in crafted_ids:
			return True
		it = items_db2.get(item)
		if not it:
			return False
		cls = i(it["ClassID"])
		q = quality(item)
		if cls in (5, 7, 9):  # reagent, trade goods, recipe
			return True
		if cls in (2, 4, 1):  # weapon, armor, container
			return q >= 2
		if cls == 0:  # consumables
			return True
		if cls == 15:  # miscellaneous (pets, mounts, keys, junk boxes)
			return q >= 2
		return False

	refs = load_templates(c, "reference_loot_template")
	res = Resolver(refs)

	def resolve_all(table):
		out = {}
		for entry, rows in load_templates(c, table).items():
			out[entry] = res.expand(rows)
		return out

	creature_loot = resolve_all("creature_loot_template")
	skin_loot = resolve_all("skinning_loot_template")
	pick_loot = resolve_all("pickpocketing_loot_template")
	go_loot = resolve_all("gameobject_loot_template")
	item_loot = resolve_all("item_loot_template")
	fish_loot = resolve_all("fishing_loot_template")

	creatures = latest_rows(c, "creature_template")
	gobjects = latest_rows(c, "gameobject_template")

	# Spawns.
	npc_spawns = defaultdict(list)
	for row in c.execute("select id, map, position_x, position_y, patch_min, patch_max from creature"):
		if patch_ok(row):
			npc_spawns[row["id"]].append((row["map"], row["position_x"], row["position_y"]))
	obj_spawns = defaultdict(list)
	for row in c.execute("select id, map, position_x, position_y, patch_min, patch_max from gameobject"):
		if patch_ok(row):
			obj_spawns[row["id"]].append((row["map"], row["position_x"], row["position_y"]))

	# item -> kind -> [(sourceID, chance, lo, hi, quest)]
	sources = defaultdict(lambda: defaultdict(list))

	creatures = {k: v for k, v in creatures.items() if not is_junk(v["name"])}
	gobjects = {k: v for k, v in gobjects.items() if not is_junk(v["name"])}

	def add_npc_loot(loot_by_id, kind, field):
		for entry, ct in creatures.items():
			loot_id = ct[field]
			if not loot_id or loot_id not in loot_by_id:
				continue
			for item, (chance, lo, hi, quest) in loot_by_id[loot_id].items():
				sources[item][kind].append((entry, chance, lo, hi, quest))

	obj_kind = {}
	for entry, gt in gobjects.items():
		kind = "O"
		if gt["type"] == 25:
			kind = "F"
		elif gt["type"] == 3:
			lock = locks.get(gt["data0"])
			if lock:
				for k in range(8):
					if i(lock[f"Type_{k}"]) == 2:
						idx = i(lock[f"_Index_{k}"])
						kind = {LOCK_HERB: "H", LOCK_MINE: "M", LOCK_FISH: "F"}.get(idx, kind)
			if kind == "O":
				kind = "C"
		obj_kind[entry] = kind
		loot_id = gt["data1"] if gt["type"] in (3, 25) else 0
		if loot_id and loot_id in go_loot:
			for item, (chance, lo, hi, quest) in go_loot[loot_id].items():
				sources[item]["o"].append((entry, chance, lo, hi, quest))

	# VMaNGOS files some vein and herb loot under the creature that shares the node's ID (creature
	# 1731 "Goblin Craftsman" "drops" Copper Ore at 99%, like Copper Vein 1731). Drop those rows.
	node_items = {}
	for entry, gt in gobjects.items():
		if obj_kind.get(entry) in ("H", "M") and gt["data1"] in go_loot:
			node_items[entry] = set(go_loot[gt["data1"]])
	leaked = 0
	for loot_id in list(creature_loot):
		bad = node_items.get(loot_id)
		if bad:
			before = len(creature_loot[loot_id])
			creature_loot[loot_id] = {k: v for k, v in creature_loot[loot_id].items() if k not in bad}
			leaked += before - len(creature_loot[loot_id])
	print(f"removed {leaked} gathering-node rows filed under creatures", file=sys.stderr)

	add_npc_loot(creature_loot, "d", "loot_id")
	add_npc_loot(skin_loot, "k", "skinning_loot_id")
	add_npc_loot(pick_loot, "p", "pickpocket_loot_id")

	for container, loot in item_loot.items():
		for item, (chance, lo, hi, quest) in loot.items():
			sources[item]["c"].append((container, chance, lo, hi, quest))
	for area, loot in fish_loot.items():
		for item, (chance, lo, hi, quest) in loot.items():
			sources[item]["f"].append((area, chance, lo, hi, quest))

	vendor_rows = list(c.execute("select entry, item, maxcount from npc_vendor"))
	vendor_templates = {}
	try:
		for row in c.execute("select entry, item, maxcount from npc_vendor_template"):
			vendor_templates.setdefault(row["entry"], []).append(row)
	except sqlite3.OperationalError:
		pass
	for row in vendor_rows:
		sources[row["item"]]["v"].append((row["entry"], 100.0, 1, 1, row["maxcount"] > 0))
	for entry, ct in creatures.items():
		vid = ct["vendor_id"]
		for row in vendor_templates.get(vid, []) if vid else []:
			sources[row["item"]]["v"].append((entry, 100.0, 1, 1, row["maxcount"] > 0))

	# Write.
	used_npcs, used_objs = set(), set()
	item_lines = []
	npc_drops = defaultdict(list)
	for item in sorted(sources):
		if not wanted(item):
			continue
		parts = []
		for kind in "dkpocfv":
			lst = sources[item].get(kind)
			if not lst:
				continue
			best = {}
			if kind in "dkpv":
				lst = [s for s in lst if s[0] in creatures]
			elif kind == "o":
				lst = [s for s in lst if s[0] in gobjects]
			if not lst:
				continue
			for sid, chance, lo, hi, quest in lst:
				if sid not in best or chance > best[sid][0]:
					best[sid] = (chance, lo, hi, quest)
			if kind in "dkp":
				# A good farm is a high chance on a creature there are plenty of.
				def score(kv):
					return kv[1][0] * math.sqrt(min(len(npc_spawns.get(kv[0], ())), 30)) * (0.5 if kv[1][3] else 1)
				ranked = sorted(best.items(), key=lambda kv: (-score(kv), kv[0]))
				spawned = [kv for kv in ranked if kv[0] in creatures and npc_spawns.get(kv[0])]
				ranked = spawned or ranked
			else:
				ranked = sorted(best.items(), key=lambda kv: (-kv[1][0], kv[0]))
			keep = VENDORS_KEEP if kind == "v" else KEEP_PER_KIND
			for sid, (chance, lo, hi, quest) in ranked[:keep]:
				bp = max(1, int(round(chance * 100)))
				s = f"{kind}{sid}:{bp}"
				if hi > 1:
					s += f":{lo}:{hi}"
				if quest:
					s += ":q" if kind != "v" else ":l"
				parts.append(s)
				if kind in "dkpv":
					used_npcs.add(sid)
				elif kind == "o":
					used_objs.add(sid)
			if len(ranked) > keep:
				parts.append(f"#{kind}{len(ranked)}")
			if kind == "d":
				for sid, (chance, _, _, quest) in ranked:
					if not quest and (item in teaches or item in reagent_ids or quality(item) >= 3):
						npc_drops[sid].append((chance, item))
		if parts:
			item_lines.append(f"\t[{item}] = {lua_str(';'.join(parts))},")

	npc_lines = []
	for npc in sorted(used_npcs):
		ct = creatures.get(npc)
		if not ct:
			continue
		loc = summarize_spawns(placer, npc_spawns.get(npc, []), 4)
		name = ct["name"].replace("|", "/")
		lvl = f"{ct['level_min']}" if ct["level_min"] == ct["level_max"] else f"{ct['level_min']}-{ct['level_max']}"
		npc_lines.append(f"\t[{npc}] = {lua_str(f'{name}|{lvl}|{ct['rank']}|{loc}')},")
	obj_lines = []
	for obj in sorted(used_objs):
		gt = gobjects.get(obj)
		if not gt:
			continue
		loc = summarize_spawns(placer, obj_spawns.get(obj, []), 6)
		name = gt["name"].replace("|", "/")
		obj_lines.append(f"\t[{obj}] = {lua_str(f'{name}|{obj_kind.get(obj, 'O')}|{loc}')},")
	drop_lines = []
	for npc in sorted(npc_drops):
		if npc not in creatures:
			continue
		top = sorted(npc_drops[npc], key=lambda t: -t[0])[:NPC_DROPS_KEEP]
		drop_lines.append(f"\t[{npc}] = {lua_str(';'.join(f'{item}:{max(1, int(round(ch * 100)))}' for ch, item in top))},")

	# English names for search: everything with sources, plus everything crafted or used in a craft.
	vm_names = {row["entry"]: row["name"] for row in latest_rows(c, "item_template").values()}
	named = set(int(line.split("]")[0].strip()[1:]) for line in item_lines) | reagent_ids | crafted_ids | set(teaches)
	vm_items = latest_rows(c, "item_template")
	name_lines = []
	meta_lines = []
	for item in sorted(named):
		s = sparse.get(item)
		name = (s["Display_lang"] if s and s["Display_lang"] else None) or vm_names.get(item)
		if not name or is_junk(name):
			continue
		name_lines.append(f"\t[{item}] = {lua_str(name)},")
		vm = vm_items.get(item)
		it = items_db2.get(item)
		cls = i(it["ClassID"]) if it else (vm["class"] if vm else 15)
		sub = i(it["SubclassID"]) if it else (vm["subclass"] if vm else 0)
		ilvl = i(s["ItemLevel"]) if s else (vm["item_level"] if vm else 0)
		req = i(s["RequiredLevel"]) if s else (vm["required_level"] if vm else 0)
		meta_lines.append(f"\t[{item}] = \"{cls}:{sub}:{quality(item)}:{ilvl}:{req}\",")

	path = os.path.join(REPO, "Sourcebook_Loot", "Loot.lua")
	header = f"""-- GENERATED by tools/build_data.py. Do not edit.
-- Loot, vendor and spawn data from the VMaNGOS world database (https://github.com/vmangos/core,
-- GPL-2.0), patch 1.12 content, placed on the World of Warcraft: Forever {build} maps.
--
-- SourcebookLoot.item[itemID] = "source;source;..."  Each source is
--     <kind><id>:<chance>[:<min>:<max>][:q|:l]
--   kind: d = dropped by NPC, k = skinned from NPC, p = pickpocketed from NPC, o = gathered from or
--         found in an object, c = found in a container item, f = fished in an area (AreaTable ID),
--         v = sold by NPC.
--   chance: basis points (10000 = 100%). Vendors are always 10000.
--   :min:max  the stack size when it can be more than one.
--   :q  only drops while on a quest.  :l  limited vendor supply.
--   "#<kind><n>" means there are n sources of that kind in all; only the best {KEEP_PER_KIND} are listed.
-- SourcebookLoot.npc[npcID] = "name|level or min-max|rank|locations"
--   rank: 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare.
-- SourcebookLoot.obj[objectID] = "name|kind|locations"
--   kind: H herb, M ore vein, F fishing pool, C chest, O other.
-- locations: comma-separated, most spawns first. "i<instanceMapID>:<n>" is n spawns inside an
--   instance; "<uiMapID>:<n>:<x>:<y>[:<x>:<y>...]" is n spawns in that zone with up to a few
--   spread-out sample points in map percent.
-- SourcebookLoot.npcDrops[npcID] = "itemID:chance;..." the notable things an NPC drops (recipes,
--   reagents, rare or better gear), best first.
-- SourcebookLoot.names[itemID] = English item name, for search (the game's own name is shown).
-- SourcebookLoot.meta[itemID] = "classID:subclassID:quality:itemLevel:requiredLevel", for the
--   book's filters and sorting.

SourcebookLoot = {{
	build = {lua_str(build)},
}}

SourcebookLoot.item = {{
"""
	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write(header)
		f.write("\n".join(item_lines))
		f.write("\n}\n\nSourcebookLoot.npc = {\n")
		f.write("\n".join(npc_lines))
		f.write("\n}\n\nSourcebookLoot.obj = {\n")
		f.write("\n".join(obj_lines))
		f.write("\n}\n\nSourcebookLoot.npcDrops = {\n")
		f.write("\n".join(drop_lines))
		f.write("\n}\n\nSourcebookLoot.names = {\n")
		f.write("\n".join(name_lines))
		f.write("\n}\n\nSourcebookLoot.meta = {\n")
		f.write("\n".join(meta_lines))
		f.write("\n}\n")
	print(f"wrote {path}: {len(item_lines)} items, {len(npc_lines)} NPCs, {len(obj_lines)} objects, "
		f"{len(drop_lines)} NPC drop lists, {os.path.getsize(path) / 1e6:.1f} MB; "
		f"{placer.misses} open-world spawns had no zone map")


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--build", default=DEFAULT_BUILD)
	ap.add_argument("--vmangos", default=None)
	ap.add_argument("--wow", default=r"D:\World of Warcraft", help="game install, for the terrain's zone map")
	ap.add_argument("--recipes-only", action="store_true")
	args = ap.parse_args()
	recipes, teaches, names = build_recipes(args.build)
	write_recipes(args.build, recipes, teaches, names)
	if not args.recipes_only:
		build_loot(args.build, args.vmangos or vmangos_db(), args.wow, recipes, teaches)


if __name__ == "__main__":
	main()
