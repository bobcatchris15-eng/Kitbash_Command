extends SceneTree
# Authors EVERY bundled default design - the player's starting Blueprint Library
# (res://assets/blueprints/default_roster/) and the battle roster
# (res://data/loadout/) - THROUGH THE REAL PLACEMENT PIPELINE.
#
# Supersedes tools/author_default_roster.gd, which covered only the nine Library
# designs and named three hulls (block_heavy_meridian_a, wedge_scout_meridian_a,
# landing_craft_hull) that the 81-hull rebuild retired.
#
# WHY EVERY BUNDLED DESIGN NEEDED REAUTHORING, not just the ones on dead hulls
#
#   1. DEAD HULLS. Four Library designs referenced hull slugs that no longer
#      exist. hull_loader.gd cannot resolve them, so they fell back to
#      brenntal_medium_a - the Library screen showed "Block Heavy Meridian A"
#      for a vehicle that was actually being built on something else.
#   2. THE RETIRED REFERENCE BOX. Every data/loadout/ design was hand-authored
#      against the old 4 x 1 x 6 hull box: every module sat at y = 0.5 (that
#      box's half-height) and every wheel and tread position was a literal.
#      Hull bodies are now SDF/marching-cubes meshes with real slope and dip,
#      and none of those hulls is 4 x 1 x 6 any more, so the modules floated or
#      sank and the running gear read as detached.
#   3. LOCOMOTION IS NOT RE-SOLVED ON LOAD. The Design Lab re-seats running gear
#      through LocomotionMount (chine seating + MountReach), but
#      blueprint_manager.reconstruct_vehicle() places locomotion modules at their
#      SERIALISED positions verbatim. A battle spawn therefore keeps whatever
#      coordinates the file was written with, forever. The only way a bundled
#      design gets correct running gear is for the file to have been written by
#      the pipeline in the first place - which is what this script is for.
#   4. A MODULE THAT DOES NOT EXIST. longarm_spg.json's main gun was
#      `heavy_howitzer`, which is in no catalog. reconstruct_vehicle() skips
#      unknown modules with a push_warning, so the shipped "SPG" fielded a CIWS
#      and nothing else. The catalogue's indirect-fire piece is `artillery`.
#
# HOW IT WORKS - the same three rules author_default_roster.gd established:
#   * Hulls are built with placer._place_hull_from_ui(), the Design Lab's own
#     call, which creates the PhysicsMesh and the precise surface collision body.
#   * Each mount specifies (x, z) ONLY. placer.surface_raycast() drops a ray onto
#     the real hull mesh and the hull decides y and the surface normal.
#   * Locomotion goes through placer.update_locomotion(), so stations come from
#     locomotion_layout.gd, get seated on the chine by hull_chine.gd and have
#     their mounting hardware length-solved by mount_reach.gd, per hull.
# Nothing here writes a coordinate, a stat or a cost that the placer or the
# catalog owns.
#
# CONVENTIONS
#   * Forward is local -Z. Main armament forward of centre, support and
#     launchers aft.
#   * The centreline belongs to the main gun. Support weapons go off-centre so
#     they do not clip into its barrel envelope (_place_weapon refuses a
#     clipping placement, which shows up as a [FAIL] line here).
#   * Library designs keep their existing faintly-absurd designations; battle
#     roster designs keep their plain [Name] [Role] names. Only the two that
#     were rebuilt around a different weapon are renamed.
#   * industrialists / hardened_steel unless the design has a reason to differ.
#
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --editor --import --quit --path .
#      Godot_v4.7.1-stable_win64_console.exe --headless --path . \
#          --script tools/author_default_designs.gd
# The reimport is NOT optional on a cold cache - without it the run dies on
# "Could not find type MatchRuleSet" and friends. See CLAUDE.md.

const LIBRARY_DIR := "res://assets/blueprints/default_roster/"
const LOADOUT_DIR := "res://data/loadout/"

const LOG_PATH := "res://scratch/author_default_designs.log"

# The player's starting Blueprint Library. `dir` LIBRARY_DIR.
const LIBRARY := [
	{
		"id": "bp_default_boghammer_m60", "file": "bp_default_boghammer_m60",
		"name": "BogHammer M60", "role": "main battle tank",
		# was block_heavy_meridian_a (retired). Brenntal Schwerbau's Breakthrough
		# is the catalogue's plainest heavy tank body.
		"hull": "brenntal_heavy_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.6, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.4, "faction": "industrialists",
		"mounts": [
			# barrel_count 3 is inside basic_cannon's own tweak range, so the Lab
			# can reproduce this on its Barrel Count slider.
			{"type": "basic_cannon", "x": 0.0, "z": -1.0,
				"tweaks": {"barrel_count": 3.0, "caliber": 1.2, "barrel_length": 1.3}},
			# The two support mounts cover different quarters instead of stacking.
			{"type": "rotary_cannon", "x": 1.3, "z": 1.4},
			{"type": "ciws", "x": -1.3, "z": 1.4},
		],
	},
	{
		"id": "bp_default_skyswatter_no_9", "file": "bp_default_skyswatter_no_9",
		"name": "SkySwatter No. 9", "role": "anti-air",
		# was kestrel_scout_a - an aircraft fuselage under a pair of AA guns.
		# Calder's Assault Car is a wheeled gun platform, which is what this is.
		"hull": "calder_medium_b", "loco": "wheels",
		"loco_settings": {"wheel_size": 1.0, "num_axles": 4, "wheels_per_axle": 2},
		"armor": "hardened_steel", "thickness": 0.9, "faction": "industrialists",
		"mounts": [
			{"type": "aa_autocannon", "x": -0.8, "z": 0.4},
			{"type": "aa_autocannon", "x": 0.8, "z": 0.4},
			{"type": "sensor_suite", "x": 0.0, "z": -1.8},
		],
	},
	{
		"id": "bp_default_lobtoad_m77", "file": "bp_default_lobtoad_m77",
		"name": "LobToad M77", "role": "artillery",
		"hull": "rackham_medium_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.3, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.1, "faction": "industrialists",
		"mounts": [
			{"type": "mortar_array", "x": -0.9, "z": 1.2},
			{"type": "mortar_array", "x": 0.9, "z": 1.2},
			{"type": "sensor_suite", "x": 0.0, "z": -1.8},
		],
	},
	{
		"id": "bp_default_peepsnipe_m12", "file": "bp_default_peepsnipe_m12",
		"name": "PeepSnipe M12", "role": "recon",
		# was wedge_scout_meridian_a (retired). Calder's Pathrunner is the
		# lightest thing in the catalogue that still carries a gun.
		"hull": "calder_scout_b", "loco": "rocker_bogie", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 0.6, "faction": "industrialists",
		"mounts": [
			{"type": "sensor_suite", "x": 0.0, "z": 0.8},
			{"type": "coil_gun", "x": 0.0, "z": -0.9},
		],
	},
	{
		"id": "bp_default_scrubmarshal_no_33", "file": "bp_default_scrubmarshal_no_33",
		"name": "ScrubMarshal No. 33", "role": "light gun platform",
		# was wedge_scout_meridian_a (retired). Orrin's Skulker keeps the
		# scrapper-built character the twin coil guns imply.
		"hull": "orrin_scout_a", "loco": "rocker_bogie", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 0.7, "faction": "industrialists",
		"mounts": [
			{"type": "coil_gun", "x": -0.7, "z": -0.3},
			{"type": "coil_gun", "x": 0.7, "z": -0.3},
		],
	},
	{
		"id": "bp_default_spaderammer_mk_xii", "file": "bp_default_spaderammer_mk_xii",
		"name": "SpadeRammer Mk XII", "role": "assault engineering",
		# was landing_craft_hull (retired). Halvorsen Yard's Landing Barge is the
		# direct descendant of that body in the new catalogue, and this design
		# carries the most parts of any bundled one - it needs the deck.
		"hull": "halvorsen_transport_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 2.0, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.2, "faction": "industrialists",
		"mounts": [
			{"type": "autocannon", "x": -1.1, "z": -1.4},
			{"type": "autocannon", "x": 1.1, "z": -1.4},
			{"type": "mortar_array", "x": -1.1, "z": 0.4},
			{"type": "mortar_array", "x": 1.1, "z": 0.4},
			{"type": "mine_layer", "x": -1.1, "z": 2.0},
			{"type": "mine_layer", "x": 1.1, "z": 2.0},
			{"type": "smoke_discharger", "x": -1.1, "z": 3.2},
			{"type": "smoke_discharger", "x": 1.1, "z": 3.2},
		],
	},
]

# The bundled battle roster. `dir` LOADOUT_DIR.
const LOADOUT := [
	{
		"id": "default_bulwark_mbt", "file": "bulwark_mbt",
		"name": "Bulwark MBT", "role": "main battle tank",
		"hull": "brenntal_heavy_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.6, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.4, "faction": "industrialists",
		"mounts": [
			{"type": "basic_cannon", "x": 0.0, "z": -0.8,
				"tweaks": {"caliber": 1.3, "barrel_length": 1.4}},
			{"type": "heavy_machine_gun", "x": 1.2, "z": 1.2},
		],
	},
	{
		"id": "default_breaker_td", "file": "breaker_td",
		"name": "Breaker TD", "role": "tank destroyer",
		# Brenntal's Assault Gun is a casemate - a fixed heavy gun in a low
		# body, which is what a tank destroyer is.
		"hull": "brenntal_heavy_c", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.4, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.2, "faction": "industrialists",
		"mounts": [
			{"type": "recoilless_rifle", "x": 0.0, "z": -0.4,
				"tweaks": {"caliber": 1.2, "barrel_length": 1.3}},
			{"type": "heavy_machine_gun", "x": 1.2, "z": 1.2},
		],
	},
	{
		"id": "default_warden_aa", "file": "warden_aa",
		"name": "Warden AA", "role": "anti-air",
		"hull": "pillar_medium_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.3, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.0, "faction": "industrialists",
		"mounts": [
			# EVERY weapon on this design is an anti-air weapon, deliberately.
			# counter_draft.role_strength() is matching-weapons/total-weapons, and
			# tests/battle/test_counter_draft.gd asserts that this platform (2/2 =
			# 1.0) outranks the Culverin SPG, which merely carries a CIWS (1/2).
			# Adding any non-AA weapon here would dilute that below 1.0.
			{"type": "flak_cannon", "x": 0.0, "z": -0.6},
			{"type": "ciws", "x": 0.0, "z": 1.8},
		],
	},
	{
		"id": "default_rattler_scout", "file": "rattler_scout",
		"name": "Rattler Scout Car", "role": "recon",
		"hull": "calder_scout_a", "loco": "wheels",
		"loco_settings": {"wheel_size": 0.9, "num_axles": 4, "wheels_per_axle": 1},
		"armor": "hardened_steel", "thickness": 0.6, "faction": "industrialists",
		"mounts": [
			{"type": "heavy_machine_gun", "x": 0.0, "z": -1.0},
			{"type": "sensor_suite", "x": 0.0, "z": 0.9},
		],
	},
	{
		"id": "default_dart_skirmisher", "file": "dart_skirmisher",
		"name": "Dart Hover Skirmisher", "role": "hover skirmisher",
		"hull": "calder_light_c", "loco": "hover_engine", "loco_settings": {},
		"armor": "energy_shielding", "thickness": 0.7, "faction": "technocrats",
		"mounts": [
			{"type": "heavy_laser", "x": 0.0, "z": -0.8},
			{"type": "sensor_suite", "x": 0.0, "z": 1.6},
		],
	},
	{
		"id": "default_raptor_striker", "file": "raptor_striker",
		"name": "Raptor Strike Fighter", "role": "strike aircraft",
		"hull": "kestrel_light_a", "loco": "fixed_wing_engine", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 0.5, "faction": "technocrats",
		"mounts": [
			{"type": "rotary_cannon", "x": 0.0, "z": 0.2},
			{"type": "missile_pod", "x": 0.0, "z": 1.7},
		],
	},
	{
		"id": "default_vulture_harvester", "file": "vulture_harvester",
		"name": "Vulture Harvester", "role": "resource gathering",
		"hull": "kestrel_transport_a", "loco": "hover_engine", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 0.7, "faction": "technocrats",
		"mounts": [
			{"type": "resource_harvester", "x": 0.0, "z": 0.8},
			{"type": "resource_bay", "x": -0.9, "z": 2.8},
			{"type": "resource_bay", "x": 0.9, "z": 2.8},
			{"type": "sensor_suite", "x": 0.0, "z": -2.4},
		],
	},
	{
		# Replaces ore_trucker.json / "Scrapper Ore Trucker". The Orrin
		# Collective is the scrapper manufacturer, so the flavour the old
		# designation carried now comes from the hull itself.
		"id": "default_magpie_ore_hauler", "file": "magpie_ore_hauler",
		"name": "Magpie Ore Hauler", "role": "resource gathering",
		"hull": "orrin_transport_a", "loco": "wheels",
		"loco_settings": {"wheel_size": 1.1, "num_axles": 8, "wheels_per_axle": 2},
		"armor": "hardened_steel", "thickness": 0.8, "faction": "industrialists",
		"mounts": [
			{"type": "resource_harvester", "x": 0.0, "z": 1.0},
			{"type": "resource_bay", "x": -1.0, "z": 2.8},
			{"type": "resource_bay", "x": 1.0, "z": 2.8},
			{"type": "sensor_suite", "x": 0.0, "z": -1.4},
			{"type": "heavy_machine_gun", "x": 0.0, "z": -2.9},
		],
	},
	{
		# Replaces longarm_spg.json / "Longarm SPG", whose main gun was the
		# nonexistent `heavy_howitzer`. See the header.
		"id": "default_culverin_spg", "file": "culverin_spg",
		"name": "Culverin SPG", "role": "self-propelled artillery",
		"hull": "rackham_heavy_b", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.5, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.0, "faction": "industrialists",
		"mounts": [
			# Every tweak is inside artillery's own range in lab_document.gd's
			# TWEAK_SPECS, so the design is reproducible on the Lab's sliders.
			{"type": "artillery", "x": 0.0, "z": 0.6,
				"tweaks": {"caliber": 1.2, "barrel_length": 1.4}},
			# Off the centreline: artillery's envelope is 6.4 deep and owns it.
			{"type": "ciws", "x": 1.2, "z": 1.0},
		],
	},
	{
		"id": "default_lance_rail_platform", "file": "lance_rail_platform",
		"name": "Lance Rail Platform", "role": "railgun platform",
		"hull": "pillar_heavy_a", "loco": "tracked_treads",
		"loco_settings": {"tread_width": 1.5, "drive_sprocket": true},
		"armor": "hardened_steel", "thickness": 1.1, "faction": "technocrats",
		"mounts": [
			{"type": "gauss_railgun", "x": 0.0, "z": -0.4,
				"tweaks": {"barrel_length": 1.3}},
			{"type": "pd_laser", "x": 1.4, "z": 2.4},
		],
	},
	# --- STATIC DEFENCES. Foundation hulls: no locomotion, `loco` empty. ---
	{
		"id": "default_bastion_gun_turret", "file": "bastion_gun_turret",
		"name": "Bastion Gun Turret", "role": "static gun emplacement",
		"hull": "bunker_main_meridian", "loco": "", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 1.5, "faction": "industrialists",
		"mounts": [
			{"type": "coil_gun", "x": 0.0, "z": 0.0},
		],
	},
	{
		"id": "default_gatling_pillbox", "file": "gatling_pillbox",
		"name": "Gatling Pillbox", "role": "static point defence",
		"hull": "bunker_main_meridian", "loco": "", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 1.3, "faction": "industrialists",
		"mounts": [
			{"type": "rotary_cannon", "x": -0.7, "z": 0.0},
			{"type": "rotary_cannon", "x": 0.7, "z": 0.0},
		],
	},
	{
		"id": "default_rampart_bunker", "file": "rampart_bunker",
		"name": "Rampart Bunker", "role": "static bunker",
		"hull": "rampart_main_meridian", "loco": "", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 1.8, "faction": "industrialists",
		"mounts": [
			{"type": "heavy_machine_gun", "x": 0.0, "z": 0.0},
		],
	},
	{
		"id": "default_sentinel_sam_turret", "file": "sentinel_sam_turret",
		"name": "Sentinel SAM Turret", "role": "static anti-air",
		"hull": "tower_main_meridian", "loco": "", "loco_settings": {},
		"armor": "hardened_steel", "thickness": 1.2, "faction": "industrialists",
		"mounts": [
			{"type": "sam_launcher", "x": 0.0, "z": 0.0},
			{"type": "ciws", "x": 0.9, "z": 0.0},
		],
	},
]

var _log: FileAccess = null


func _say(msg: String) -> void:
	print(msg)
	if _log != null:
		_log.store_line(msg)
		_log.flush()


func _init():
	DirAccess.make_dir_recursive_absolute("res://scratch")
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)

	var ModulePlacerScript = load("res://scripts/module_placer.gd")
	var BlueprintManagerScript = load("res://scripts/blueprint_manager.gd")

	var world := Node3D.new()
	root.add_child(world)
	var placer = ModulePlacerScript.new()
	world.add_child(placer)
	var bm = BlueprintManagerScript.new()
	world.add_child(bm)

	var written := 0
	var failed := 0

	for batch in [{"dir": LIBRARY_DIR, "specs": LIBRARY},
			{"dir": LOADOUT_DIR, "specs": LOADOUT}]:
		for spec in batch["specs"]:
			var design_name := str(spec["name"])
			_say("\nauthoring %s (%s) on %s" % [design_name, spec["role"], spec["hull"]])

			placer.clear_hull()
			placer._place_hull_from_ui(str(spec["hull"]))
			if placer.hull == null:
				_say("  [FAIL] hull %s did not place" % spec["hull"])
				failed += 1
				continue

			placer.hull.set_meta("armor_material", str(spec["armor"]))
			placer.hull.set_meta("armor_thickness", float(spec["thickness"]))
			placer.hull.set_meta("faction", str(spec["faction"]))
			placer.hull.set_meta("blueprint_id", str(spec["id"]))
			placer.hull.set_meta("blueprint_name", design_name)
			placer.update_hull_appearance()

			# Two physics frames before any raycast: the surface collision body
			# was only just added, and PhysicsServer does not know about it until
			# it has stepped. Raycasting immediately silently falls back to the
			# bounding box - the exact failure this script exists to avoid, and it
			# would fail invisibly.
			await physics_frame
			await physics_frame

			var loco := str(spec["loco"])
			if loco != "":
				placer.update_locomotion(loco, spec["loco_settings"])
				await physics_frame

			var hull_size: Vector3 = placer.hull.get_meta("base_hull_size", Vector3.ONE)
			var placed := 0
			for mount in spec["mounts"]:
				var mx := float(mount.get("x", 0.0))
				var mz := float(mount.get("z", 0.0))
				var hit: Dictionary
				if str(mount["type"]) == "resource_harvester":
					var origin: Vector3 = placer.hull.global_position \
						+ Vector3(0.0, 0.0, -hull_size.z - 4.0)
					hit = placer.surface_raycast(origin, Vector3(0, 0, 1), 1000.0)
				else:
					var origin: Vector3 = placer.hull.global_position \
						+ Vector3(mx, hull_size.y * 2.0 + 4.0, mz)
					hit = placer.surface_raycast(origin, Vector3.DOWN, 1000.0)
				if hit.is_empty():
					_say("  [FAIL] %s: no surface found"
						% [mount["type"]])
					failed += 1
					continue
				var node = placer._place_weapon(str(mount["type"]),
					hit["position"], hit["normal"], false, mount.get("tweaks", {}))
				if node == null:
					_say("  [FAIL] %s: placement refused at (%.2f, %.2f) - clipping?"
						% [mount["type"], mx, mz])
					failed += 1
					continue
				placed += 1
				_say("    %-20s -> y=%.3f facet=%s" % [
					mount["type"], node.position.y, str(node.get_meta("facet", "?"))])
				await physics_frame

			var data: Dictionary = bm.serialize_hull(placer.hull)
			data["id"] = str(spec["id"])
			data["name"] = design_name

			var out_path: String = str(batch["dir"]) + str(spec["file"]) + ".json"
			var f = FileAccess.open(out_path, FileAccess.WRITE)
			if f == null:
				_say("  [FAIL] could not write %s" % out_path)
				failed += 1
				continue
			f.store_string(JSON.stringify(data, "\t"))
			f.close()
			written += 1
			_say("  wrote %s (%d mounts placed, %d modules total)"
				% [out_path, placed, data.get("modules", []).size()])

	_say("\n%d written, %d failure(s)." % [written, failed])
	_log.close()
	quit(0 if failed == 0 else 1)
