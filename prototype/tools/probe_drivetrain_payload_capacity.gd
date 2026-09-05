extends SceneTree

const Drivetrain = preload("res://scripts/drivetrain.gd")
const ModuleDataScript = preload("res://scripts/module_data.gd")

func _initialize() -> void:
	var hull := Node3D.new()
	root.add_child(hull)
	hull.set_meta("type_id", "brenntal_medium_a")
	hull.set_meta("locomotion_type", "heavy_quad_tracks")

	for _side in 2:
		var track := Node3D.new()
		var data := ModuleDataScript.new()
		data.type_id = "heavy_quad_tracks"
		data.category = "locomotion"
		data.base_weight = 180.0
		data.tweaks = {"track_count": 4.0, "tread_width": 1.0}
		track.set_meta("module_data", data)
		hull.add_child(track)

	var baseline := Drivetrain.analyze(hull, "heavy_quad_tracks",
		{"track_count": 4.0, "tread_width": 1.0})
	var structural_mass := float(baseline["weight"]) - float(baseline["loco_weight"])
	_assert_true(float(baseline["carried_weight"]) > 0.0,
		"declared hull armor must consume payload capacity")
	_assert_true(float(baseline["carried_weight"]) < structural_mass,
		"bare hull structure must not consume payload capacity")
	_assert_true(float(baseline["weight"]) > 0.0,
		"hull and locomotion must remain part of real total mass")
	_assert_true(not bool(baseline["is_overloaded"]),
		"a bare driven hull must never be overloaded")

	var wider := Drivetrain.analyze(hull, "heavy_quad_tracks",
		{"track_count": 4.0, "tread_width": 2.0})
	var more_pods := Drivetrain.analyze(hull, "heavy_quad_tracks",
		{"track_count": 6.0, "tread_width": 1.0})
	_assert_close(float(wider["capacity"]) / float(baseline["capacity"]), 2.0,
		"doubling heavy-track width must double payload capacity")
	_assert_close(float(more_pods["capacity"]) / float(baseline["capacity"]), 1.5,
		"six heavy track pods must carry 1.5x four pods")

	var payload := Node3D.new()
	var payload_data := ModuleDataScript.new()
	payload_data.type_id = "test_payload"
	payload_data.category = "weapon"
	payload_data.base_weight = 125.0
	payload.set_meta("module_data", payload_data)
	hull.add_child(payload)
	var loaded := Drivetrain.analyze(hull, "heavy_quad_tracks",
		{"track_count": 4.0, "tread_width": 1.0})
	_assert_close(float(loaded["carried_weight"]) - float(baseline["carried_weight"]), 125.0,
		"a non-locomotion module must add its exact mass to payload")

	var first_track_data = hull.get_child(0).get_meta("module_data")
	var original_track_mass: float = first_track_data.get_weight()
	first_track_data.base_weight += 75.0
	var added_track_mass: float = first_track_data.get_weight() - original_track_mass
	var heavier_drive := Drivetrain.analyze(hull, "heavy_quad_tracks",
		{"track_count": 4.0, "tread_width": 1.0})
	_assert_close(float(heavier_drive["carried_weight"]), float(loaded["carried_weight"]),
		"increasing locomotor mass must not increase payload")
	_assert_close(float(heavier_drive["weight"]) - float(loaded["weight"]), added_track_mass,
		"increasing locomotor mass must still increase total unit mass")

	print("[PASS] drivetrain payload excludes bare chassis/locomotion, includes armor; heavy quad track width and count raise capacity")
	hull.queue_free()
	quit(0)

func _assert_true(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		quit(1)

func _assert_close(actual: float, expected: float, message: String) -> void:
	_assert_true(is_equal_approx(actual, expected), "%s (got %.3f, expected %.3f)" % [message, actual, expected])
