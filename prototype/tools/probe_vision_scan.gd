extends SceneTree
# Behavioral probe for VisionService.tick()'s spotted scan after the 2026-08-25
# profile-hoisting rewrite (_viewer_profiles + amortized disc queue). The two
# battle-booting probes (probe_battle_phase4 / probe_battle_ai) went stale when
# the deploy-gate moved boot artifacts past their frame budget, so this pins the
# scan contract directly against a mock controller instead:
#
#   1. Omni vision: near hostile seen, far hostile not.
#   2. Hysteresis: something already visible stays visible out to
#      HIDE_RANGE_MULT x vision before dropping.
#   3. Seismic: a MOVING ground contact inside seismic_range is detected with
#      zero vision range; the same stationary contact is not.
#   4. Directional sensors: sector ahead detects, sector behind does not.
#   5. Flare beacons reveal, then stop on expiry.
#   6. Same-team constructs are always visible to themselves.
#
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --path . \
#          --script res://tools/probe_vision_scan.gd

const VisionService = preload("res://scripts/battle/vision/vision_service.gd")

var _failures: int = 0

# _all_constructs() skips anything without an is_dead property - a plain
# Node3D would vanish from the scan entirely.
class MockConstruct extends Node3D:
	var is_dead: bool = false


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  [PASS] %s" % label)
	else:
		print("  [FAIL] %s" % label)
		_failures += 1


func _make_construct(parent: Node, team: int, pos: Vector3, props: Dictionary) -> Node3D:
	var n := MockConstruct.new()
	parent.add_child(n)
	n.position = pos
	# _all_constructs() walks this group, exactly as it does for real units
	# and structures.
	n.add_to_group("damageable")
	n.set_meta("team", team)
	for k in props:
		n.set_meta(k, props[k])
	return n


func _init() -> void:
	print("=== PROBING VISION SPOTTED SCAN ===")
	var controller := Node3D.new()
	get_root().add_child(controller)
	# Nodes added while the SceneTree is inside its OWN _init do not enter the
	# tree (and so have no valid global transform / physics world) until a frame
	# passes - see debug_settings.gd's note on the same timing quirk.
	await process_frame

	var vs = VisionService.new()
	vs.setup(controller, 0, 500.0, 1.0)

	var viewer := _make_construct(controller, 0, Vector3.ZERO, {
		"vision_range": 100.0,
	})
	var seer := _make_construct(controller, 0, Vector3(400.0, 0.0, 400.0), {
		"vision_range": 100.0,
	})

	# --- 1. Omni vision -------------------------------------------------------
	print("Test 1: omni vision near/far")
	var near_t := _make_construct(controller, 1, Vector3(50, 0, 0), {})
	var far_t := _make_construct(controller, 1, Vector3(300, 0, 0), {})
	vs.tick()
	_check(vs.is_visible_to_team(near_t, 0), "hostile at 50 m seen")
	_check(not vs.is_visible_to_team(far_t, 0), "hostile at 300 m not seen")

	# --- 2. Hysteresis --------------------------------------------------------
	print("Test 2: hysteresis holds a visible contact past plain range")
	near_t.position = Vector3(112, 0, 0) # >100, < 100 * 1.15
	vs.tick()
	_check(vs.is_visible_to_team(near_t, 0),
		"contact at 112 m stays seen while already tracked")
	near_t.position = Vector3(220, 0, 0) # past the hysteresis band too
	vs.tick()
	_check(not vs.is_visible_to_team(near_t, 0), "contact at 220 m drops")

	# --- 3. Seismic -----------------------------------------------------------
	print("Test 3: seismic senses movement without vision")
	var seis := _make_construct(controller, 0, Vector3(-200, 0, 0), {
		"vision_range": 0.0,
		"seismic_range": 80.0,
	})
	var walker := _make_construct(controller, 1, Vector3(-150, 0, 0), {
		"velocity": Vector3(1, 0, 0),
	})
	vs.tick()
	_check(vs.is_visible_to_team(walker, 0), "moving hostile at 50 m caught by seismic")
	walker.set_meta("velocity", Vector3.ZERO)
	vs.tick()
	_check(not vs.is_visible_to_team(walker, 0), "same hostile stopped is invisible again")

	# --- 4. Directional sensors ----------------------------------------------
	print("Test 4: directional radar is a forward sector")
	var radar := _make_construct(controller, 0, Vector3(200, 0, 0), {
		"vision_range": 0.0,
		"directional_sensors": [{"range": 120.0, "arc_rad": PI / 3.0}],
	})
	radar.rotation_degrees.y = 180.0 # forward (-Z) now points toward +Z
	var front := _make_construct(controller, 1, Vector3(200, 0, 80), {"is_flying": true})
	var behind := _make_construct(controller, 1, Vector3(200, 0, -80), {"is_flying": true})
	vs.tick()
	_check(vs.is_visible_to_team(front, 0), "contact inside the sector seen")
	_check(not vs.is_visible_to_team(behind, 0), "contact behind the sector unseen")

	# --- 5. Beacons ------------------------------------------------------------
	print("Test 5: flare reveals then burns out")
	var dark := _make_construct(controller, 1, Vector3(-350, 0, -350), {})
	vs.tick()
	_check(not vs.is_visible_to_team(dark, 0), "target outside all reach unseen")
	vs.reveal_area(0, dark.position, 40.0, 5.0)
	vs.tick()
	_check(vs.is_visible_to_team(dark, 0), "flare reveals what it is fired over")
	for b in vs._beacons:
		b.expires_at = Time.get_ticks_msec() - 1
	vs.tick()
	_check(not vs.is_visible_to_team(dark, 0), "burnt-out flare stops revealing")

	# --- 6. Same-team always visible ------------------------------------------
	print("Test 6: own team never fogged")
	_check(vs.is_visible_to_team(viewer, 0), "team 0 sees itself")
	_check(not vs.is_visible_to_team(seer, 1), "sanity: enemy read of our unit is not granted here")

	if _failures == 0:
		print(">>> ALL VISION SCAN TESTS PASSED <<<")
	else:
		print(">>> %d TEST(S) FAILED <<<" % _failures)
	quit(0 if _failures == 0 else 1)
