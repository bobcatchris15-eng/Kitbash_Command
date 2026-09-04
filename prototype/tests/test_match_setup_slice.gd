extends SceneTree

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
