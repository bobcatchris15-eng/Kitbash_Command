extends SceneTree
const UITheme = preload("res://scripts/ui_theme.gd")

# Task 5 screen-contract probe. Run with Godot headless; it exercises the
# scene's presentation state without committing a match or loading Battle.
var checks := 0
var failures := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] ", message)


func _settle() -> void:
	for _frame in range(8):
		await process_frame


func _run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 800)
	DisplayServer.window_set_size(Vector2i(1280, 800))
	await _settle()

	var setup: Node = load("res://scenes/MatchSetup.tscn").instantiate()
	root.add_child(setup)
	await _settle()

	_check(setup.find_child("MatchSetupReadiness", true, false) != null,
		"readiness state is named for launch and assistive inspection")
	var readiness_icon := setup.find_child("MatchSetupReadinessIcon", true, false) as TextureRect
	_check(readiness_icon != null and readiness_icon.texture == UITheme.industrial_icon("state_selected"),
		"active setup progression uses the authored selected state icon")
	_check(setup.find_child("StageTheatre", true, false) != null,
		"theatre stage has a stable semantic name")
	_check(setup.find_child("StageRoster", true, false) != null,
		"roster stage has a stable semantic name")
	_check(setup.find_child("StageLaunch", true, false) != null,
		"launch stage has a stable semantic name")

	var roster_chip := setup._spine_chips[1] as Button
	var launch_chip := setup._spine_chips[2] as Button
	_check(roster_chip.focus_mode != Control.FOCUS_NONE and launch_chip.focus_mode != Control.FOCUS_NONE,
		"stage navigation is keyboard and gamepad focusable")
	_check(launch_chip.disabled, "launch stage is blocked before theatre and roster progression")
	setup._on_next_pressed()
	setup._on_next_pressed()
	await _settle()
	_check(setup._stage == 2 and not launch_chip.disabled,
		"stage progression unlocks a reachable launch review")
	var readiness := setup.find_child("MatchSetupReadiness", true, false) as Label
	_check(readiness != null and readiness.text != "",
		"launch review exposes a non-empty readiness explanation")
	_check(readiness_icon != null and (readiness_icon.texture == UITheme.industrial_icon("state_invalid") or
		readiness_icon.texture == UITheme.industrial_icon("state_ready")),
		"launch readiness keeps an authored state icon")
	var spawn_marker := setup.find_child("IndustrialSpawnMarker", true, false) as TextureRect
	_check(spawn_marker != null and spawn_marker.texture == UITheme.industrial_icon("map_spawn_marker"),
		"theatre legend uses the authored deployment marker")

	root.size = Vector2i(960, 720)
	DisplayServer.window_set_size(Vector2i(960, 720))
	await _settle()
	_check(setup.is_narrow_viewport(), "narrow viewport state is detected at 960px")
	_check(not setup._ops_mode_btn.visible,
		"dense war-room mode is withheld when the staged flow is the readable option")

	setup.queue_free()
	await _settle()
	print("[match-setup] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
