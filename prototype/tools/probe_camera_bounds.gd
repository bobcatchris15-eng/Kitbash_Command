extends SceneTree
# CAMERA STAYS INSIDE THE VOID WALL
# ---------------------------------------------------------------------------
# void_wall.gd puts its four panels at exactly +/-half_x, +/-half_z. The camera
# must never end up outside that box, at any zoom, any yaw, or after a
# middle-mouse drag that shoves the origin directly.
#
# The bug this guards: the hard clamp in rts_camera._clamp_to_void() allowed
# `half + VOID_CAMERA_MARGIN + VOID_CAMERA_EXTRA_VOID` = half + 8, so the eye
# was permitted eight metres past the wall. It only reproduced at close zoom,
# because the origin sits `height / tan(pitch)` behind the focal point - ~11 m
# zoomed in but ~140 m zoomed out, and only the close case can be pushed
# against the outer limit at all. A probe that tested one zoom would have
# missed it, so this one sweeps the whole range.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_camera_bounds.gd --quit

const RTSCameraScript = preload("res://scripts/rts_camera.gd")

const HALF := Vector2(400.0, 260.0)   # deliberately non-square
const YAWS := [0.0, 37.0, 90.0, 143.0, 180.0, 221.0, 270.0, 318.0]
# Push far enough past the edge that no clamp can be accused of merely not
# having been reached.
const SHOVE := 900.0


# The sweep runs on the first _process(), not in _init() or _initialize().
# In a SceneTree script both of those run before the root Window is live, so
# add_child() lands on nothing and every global_position write is silently
# swallowed by Node3D's !is_inside_tree() guard - which presents as a camera
# pinned at the origin and a clamp that looks like it is working.
var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_sweep()
	return true


func _sweep() -> void:
	var cam: Camera3D = RTSCameraScript.new()
	root.add_child(cam)
	cam.set_map_bounds(HALF)

	var worst_x := 0.0
	var worst_z := 0.0
	var worst_desc := ""
	var checks := 0

	var heights: Array = [cam.min_height, 12.0, 26.0, 50.0, 90.0, 140.0, cam.max_height]
	for h in heights:
		cam.height = float(h)
		cam._apply_pitch()
		for yaw in YAWS:
			cam.rotation_degrees.y = float(yaw)
			for sx in [-1.0, 0.0, 1.0]:
				for sz in [-1.0, 0.0, 1.0]:
					cam.global_position = Vector3(
						float(sx) * SHOVE, cam.height, float(sz) * SHOVE)
					cam._clamp_to_void()
					checks += 1
					var ox: float = absf(cam.global_position.x)
					var oz: float = absf(cam.global_position.z)
					if ox > worst_x:
						worst_x = ox
						worst_desc = "h=%.0f yaw=%.0f shove=(%.0f,%.0f)" % [h, yaw, sx, sz]
					if oz > worst_z:
						worst_z = oz

	print("  checks              : %d" % [checks])
	print("  wall at             : x=%.1f  z=%.1f" % [HALF.x, HALF.y])
	print("  worst camera origin : x=%.1f  z=%.1f" % [worst_x, worst_z])
	print("  worst case          : %s" % [worst_desc])

	var fail := false
	if worst_x > HALF.x:
		print("  [FAIL] camera reached x=%.1f, which is %.1f m outside the wall."
			% [worst_x, worst_x - HALF.x])
		fail = true
	if worst_z > HALF.y:
		print("  [FAIL] camera reached z=%.1f, which is %.1f m outside the wall."
			% [worst_z, worst_z - HALF.y])
		fail = true
	# The other half of the contract: the clamp must not be so aggressive that
	# it eats the map. If the camera cannot get near the edge at all, panning
	# to a corner base stops working.
	if worst_x < HALF.x * 0.9 or worst_z < HALF.y * 0.9:
		print("  [FAIL] clamp is too tight - the camera cannot approach the edge.")
		fail = true

	if fail:
		quit(1)
	else:
		print("  [PASS] camera stays inside the wall at every zoom and yaw.")
		quit(0)
