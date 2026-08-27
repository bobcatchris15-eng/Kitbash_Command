extends SceneTree
# Headless check of the match-setup roster picker: three libraries, twelve unit
# slots with one reserved for a harvester, four defence slots, and the capability
# badges.
#
#   Godot..._console.exe --headless --path <prototype>
#     --script res://tools/probe_roster_picker.gd --quit

const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const HullLoaderScript = preload("res://scripts/hull_loader.gd")
const MatchDirectorScript = preload("res://scripts/battle/match_director.gd")

var _pass := 0
var _fail := 0

func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s%s" % [label, ("  " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  [FAIL] %s%s" % [label, ("  " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("=== roster picker probe ===")
	var bm := BlueprintManagerScript.new()
	root.add_child(bm)
	var entries: Array = bm.list_blueprints(true)
	print("  library: %d saved designs" % entries.size())

	# --- classification -----------------------------------------------------
	var units := 0
	var harvesters := 0
	var buildings := 0
	var repairers := 0
	for e in entries:
		if e.get("is_defensive", false):
			buildings += 1
		elif e.get("is_harvester", false):
			harvesters += 1
		else:
			units += 1
		if e.get("has_repair", false):
			repairers += 1
	print("  categories: %d unit / %d harvester / %d defensive (%d with repair arms)"
		% [units, harvesters, buildings, repairers])
	_check(units + harvesters + buildings == entries.size(),
		"every design lands in exactly one library")
	_check(entries.all(func(e): return e.has("is_defensive")),
		"every entry carries is_defensive")

	# The setup screen and the match runtime must agree on what a defence is,
	# or a design sorted into the defence library gets produced as a vehicle.
	var disagree := []
	for e in entries:
		var data: Dictionary = bm.load_blueprint(str(e.get("path", "")))
		if data.is_empty():
			continue
		var runtime_says: bool = ModuleCatalogScript.is_foundation(str(data.get("hull_type", "")))
		if runtime_says != bool(e.get("is_defensive", false)):
			disagree.append("%s (setup=%s runtime=%s)"
				% [e.get("name", "?"), e.get("is_defensive", false), runtime_says])
	_check(disagree.is_empty(),
		"setup classification agrees with match_director.is_defence_design",
		"" if disagree.is_empty() else str(disagree))

	# --- picker construction ------------------------------------------------
	var picker := RosterPickerScript.new()
	root.add_child(picker)
	picker.setup(entries, 12)

	var unit_slots: Array = picker._slots
	var bld_slots: Array = picker._building_slots
	_check(unit_slots.size() == 12, "twelve unit slots", "got %d" % unit_slots.size())
	_check(bld_slots.size() == RosterPickerScript.BUILDING_CAPACITY,
		"four defence slots", "got %d" % bld_slots.size())

	var reserved := 0
	for s in unit_slots:
		if s.kind == RosterPickerScript.SlotKind.HARVESTER:
			reserved += 1
	_check(reserved == 1, "exactly one reserved harvester slot", "got %d" % reserved)
	_check(unit_slots[RosterPickerScript.HARVESTER_SLOT_INDEX].kind
			== RosterPickerScript.SlotKind.HARVESTER,
		"the reserved slot is the last one (slot 12)")
	for s in bld_slots:
		if s.kind != RosterPickerScript.SlotKind.BUILDING:
			_check(false, "every defence slot is kind BUILDING")
			break

	# --- slot acceptance rules ---------------------------------------------
	var a_unit := _first_path(entries, "unit")
	var a_harv := _first_path(entries, "harvester")
	var a_bld := _first_path(entries, "building")
	if a_unit != "":
		_check(picker.path_fits_kind(a_unit, RosterPickerScript.SlotKind.UNIT),
			"a unit fits a unit slot")
		_check(not picker.path_fits_kind(a_unit, RosterPickerScript.SlotKind.HARVESTER),
			"a unit is refused by the reserved harvester slot")
		_check(not picker.path_fits_kind(a_unit, RosterPickerScript.SlotKind.BUILDING),
			"a unit is refused by a defence slot")
	if a_harv != "":
		_check(picker.path_fits_kind(a_harv, RosterPickerScript.SlotKind.HARVESTER),
			"a harvester fits the reserved slot")
		_check(picker.path_fits_kind(a_harv, RosterPickerScript.SlotKind.UNIT),
			"a harvester also fits a general unit slot")
	if a_bld != "":
		_check(picker.path_fits_kind(a_bld, RosterPickerScript.SlotKind.BUILDING),
			"a defence fits a defence slot")
		_check(not picker.path_fits_kind(a_bld, RosterPickerScript.SlotKind.UNIT),
			"a defence is refused by a unit slot")
	else:
		print("  NOTE: no defensive designs in the library - defence slot rules unexercised.")

	# --- round trip ---------------------------------------------------------
	var want := []
	for e in entries:
		want.append(str(e.get("path", "")))
	var filled: int = picker.fill_from(want)
	var out: Array = picker.ordered_paths()
	print("  fill_from(%d paths) -> %d placed, ordered_paths -> %d"
		% [want.size(), filled, out.size()])
	_check(out.size() == filled, "ordered_paths returns exactly what was placed")
	_check(out.size() == out.duplicate().size(), "no duplicate slotting")
	var seen := {}
	var dupes := 0
	for p in out:
		if seen.has(p):
			dupes += 1
		seen[p] = true
	_check(dupes == 0, "a design occupies at most one slot", "%d duplicates" % dupes)

	# Defences must come out AFTER units and must all be defences.
	var tail_ok := true
	var in_tail := false
	for p in out:
		if picker.is_building_path(p):
			in_tail = true
		elif in_tail:
			tail_ok = false
			break
	_check(tail_ok, "ordered_paths lists units first, then defences")

	# Nothing should have been routed into the wrong grid.
	var misrouted := 0
	for s in unit_slots:
		if s.entry_path != "" and picker.is_building_path(s.entry_path):
			misrouted += 1
	for s in bld_slots:
		if s.entry_path != "" and not picker.is_building_path(s.entry_path):
			misrouted += 1
	_check(misrouted == 0, "fill_from routes each design to the right grid",
		"%d misrouted" % misrouted)

	# --- icons --------------------------------------------------------------
	for n in [RosterPickerScript.ICON_HARVESTER, RosterPickerScript.ICON_REPAIR,
			RosterPickerScript.ICON_BUILDING]:
		_check(UIIcons.has_icon(n), "icon '%s' resolves" % n)

	# --- synthetic defence coverage ----------------------------------------
	# The shipped library has no foundation-hull designs, so every defence rule
	# above was skipped. Build the categories by hand and run the picker again:
	# a feature nobody has saved a design for is exactly the one that will be
	# broken when they finally do.
	print("  -- synthetic defence coverage --")
	var foundation_hull := ""
	for hid in HullLoaderScript.get_hulls().keys():
		if ModuleCatalogScript.is_foundation(str(hid)):
			foundation_hull = str(hid)
			break
	_check(foundation_hull != "", "a foundation hull exists in the catalog", foundation_hull)

	if foundation_hull != "":
		var static_bp := {"hull_type": foundation_hull, "modules": [{"type_id": "autocannon"}]}
		_check(ModuleCatalogScript.blueprint_is_static(static_bp),
			"foundation hull classifies as static")
		_check(not ModuleCatalogScript.blueprint_has_locomotion(static_bp),
			"foundation design reports no locomotion")

		var synth: Array = [
			{"path": "synth://turret", "name": "Synth Turret", "is_defensive": true,
				"is_harvester": false, "has_repair": false},
			{"path": "synth://tank", "name": "Synth Tank", "is_defensive": false,
				"is_harvester": false, "has_repair": false},
			{"path": "synth://miner", "name": "Synth Miner", "is_defensive": false,
				"is_harvester": true, "has_repair": false},
			{"path": "synth://medic", "name": "Synth Medic", "is_defensive": false,
				"is_harvester": false, "has_repair": true},
		]
		var p2 := RosterPickerScript.new()
		root.add_child(p2)
		p2.setup(synth, 12)
		_check(p2.is_building_path("synth://turret"), "synthetic defence is registered")
		_check(p2.path_fits_kind("synth://turret", RosterPickerScript.SlotKind.BUILDING),
			"defence accepted by a defence slot")
		_check(not p2.path_fits_kind("synth://turret", RosterPickerScript.SlotKind.UNIT),
			"defence refused by a unit slot")
		_check(not p2.path_fits_kind("synth://tank", RosterPickerScript.SlotKind.BUILDING),
			"unit refused by a defence slot")
		_check(p2.is_repair_path("synth://medic"), "repair design flagged for the support badge")

		# fill_from must route the turret to the defence grid even though it is
		# first in the list, and must not spend a unit slot on it.
		var n2: int = p2.fill_from(["synth://turret", "synth://tank", "synth://miner", "synth://medic"])
		_check(n2 == 4, "all four synthetic designs placed", "got %d" % n2)
		_check(p2._building_slots[0].entry_path == "synth://turret",
			"the defence landed in the defence grid",
			"got '%s'" % p2._building_slots[0].entry_path)
		var unit_paths := []
		for s in p2._slots:
			if s.entry_path != "":
				unit_paths.append(s.entry_path)
		_check(not unit_paths.has("synth://turret"),
			"the defence did NOT consume a unit slot")
		_check(p2._slots[RosterPickerScript.HARVESTER_SLOT_INDEX].entry_path == "",
			"the reserved harvester slot is left open when general slots are free",
			"got '%s'" % p2._slots[RosterPickerScript.HARVESTER_SLOT_INDEX].entry_path)
		var out2: Array = p2.ordered_paths()
		_check(out2.size() == 4 and out2[out2.size() - 1] == "synth://turret",
			"ordered_paths puts the defence last", str(out2))

	# --- the runtime cap must not eat the defences -------------------------
	# roster_picker puts defences at the TAIL of its flat output, so a plain
	# slice(0, 12) drops all of them the moment a full slate of units is
	# fielded. This is the regression test for that.
	if foundation_hull != "":
		print("  -- runtime roster cap --")
		var big: Array = []
		for i in range(20):
			big.append({"id": "unit_%d" % i, "hull_type": "brenntal_medium_a",
				"modules": [{"type_id": "autocannon"}]})
		for i in range(6):
			big.append({"id": "turret_%d" % i, "hull_type": foundation_hull,
				"modules": [{"type_id": "autocannon"}]})
		var trimmed: Array = MatchDirectorScript._trim_roster(big)
		var t_units := 0
		var t_def := 0
		for d in trimmed:
			if MatchDirectorScript.is_defence_design(d):
				t_def += 1
			else:
				t_units += 1
		print("  trim(20 units + 6 defences) -> %d units, %d defences" % [t_units, t_def])
		_check(t_units == MatchDirectorScript.ROSTER_LIMIT,
			"units capped at ROSTER_LIMIT", "got %d" % t_units)
		_check(t_def == MatchDirectorScript.DEFENCE_LIMIT,
			"defences capped at DEFENCE_LIMIT, not discarded", "got %d" % t_def)

		# The realistic case: exactly what a full setup screen produces.
		var full: Array = []
		for i in range(12):
			full.append({"id": "u%d" % i, "hull_type": "brenntal_medium_a", "modules": []})
		for i in range(4):
			full.append({"id": "d%d" % i, "hull_type": foundation_hull, "modules": []})
		var kept: Array = MatchDirectorScript._trim_roster(full)
		_check(kept.size() == 16, "a full 12+4 roster survives the cap intact",
			"got %d" % kept.size())

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _first_path(entries: Array, category: String) -> String:
	for e in entries:
		var cat := "unit"
		if e.get("is_defensive", false):
			cat = "building"
		elif e.get("is_harvester", false):
			cat = "harvester"
		if cat == category:
			return str(e.get("path", ""))
	return ""
