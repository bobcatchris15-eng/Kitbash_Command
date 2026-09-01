extends SceneTree
# Phase 4 acceptance: vision, HUD, minimap, win condition.
#
# The questions that need a real match:
#
#   * does the fog SCAN run and produce a per-team answer, not just a shroud
#   * does it actually HIDE things - a fog that reveals everything passes every
#     naive check and is indistinguishable from no fog at all
#   * does the minimap draw blips, verified by reading pixels back (which is the
#     whole reason it is an Image and not a SubViewport)
#   * does destroying an HQ end the match, once, with the right winner
#
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --path . \
#          --script tools/probe_battle_phase4.gd

const VisionServiceScript = preload("res://scripts/battle/vision/vision_service.gd")


func _init():
	var failures: Array = []

	var packed = load("res://scenes/Battle.tscn")
	if packed == null:
		print("[FAIL] Battle.tscn did not load")
		quit(1)
		return
	var battle = packed.instantiate()
	root.add_child(battle)
	var wait_frames := 0
	while not battle.world_is_ready and wait_frames < 60:
		await process_frame
		wait_frames += 1

	if battle.vision == null:
		_finish(battle, ["no vision service was built"])
		return
	if battle.battle_hud == null:
		_finish(battle, ["no battle HUD was built"])
		return

	# --- The shroud exists in the world -------------------------------------
	var shroud = battle.get_node_or_null("FogShroud")
	print("  shroud plane: %s" % ("present" if shroud != null else "MISSING"))
	if shroud == null:
		failures.append("no FogShroud was added to the scene")

	# --- Vision is a real number, not a placeholder -------------------------
	var blueprint: Dictionary = battle.bp_manager.load_blueprint("res://data/loadout/bulwark_mbt.json")
	var scout = battle.spawn_unit(blueprint, 0, Vector3(0, 0, 0))
	# Far enough that no plausible vision range reaches it.
	var hidden = battle.spawn_unit(blueprint, 1, Vector3(0, 0, -300.0))
	# Close enough that it certainly should be seen.
	var obvious = battle.spawn_unit(blueprint, 1, Vector3(0, 0, 10.0))
	for _i in range(4):
		await process_frame
	if scout == null or hidden == null or obvious == null:
		_finish(battle, ["could not spawn the vision test units"])
		return
	print("  scout vision_range: %.1f m" % scout.vision_range)
	if scout.vision_range <= 0.0:
		failures.append("a unit reports zero vision range - nothing can ever be spotted")

	# Run the scan directly rather than waiting on its timer: the timer fires
	# three times a second and this probe should not depend on wall clock.
	battle.vision.tick()

	var sees_near: bool = battle.vision.is_visible_to_team(obvious, 0)
	var sees_far: bool = battle.vision.is_visible_to_team(hidden, 0)
	print("  team0 sees the unit at 10 m: %s" % str(sees_near))
	print("  team0 sees the unit at 300 m: %s" % str(sees_far))
	if not sees_near:
		failures.append("a hostile 10 m away is not visible - vision is too tight or the scan is not running")
	if sees_far:
		failures.append("a hostile 300 m away is visible - fog reveals everything, which is the same as no fog")

	# fog_hidden must actually be written onto the construct, because that is what
	# rendering and auto_weapon.gd's targeting gate read.
	print("  far unit fog_hidden flag: %s" % str(hidden.fog_hidden))
	if not hidden.fog_hidden:
		failures.append("fog_hidden was not set on an unseen construct")

	# --- Reveal beacons ------------------------------------------------------
	battle.reveal_area(0, hidden.global_position, 40.0, 5.0)
	battle.vision.tick()
	print("  after a flare over it, team0 sees the far unit: %s"
		% str(battle.vision.is_visible_to_team(hidden, 0)))
	if not battle.vision.is_visible_to_team(hidden, 0):
		failures.append("an illumination beacon did not reveal what it was fired over")

	# --- Minimap draws -------------------------------------------------------
	battle.battle_hud.refresh()
	var image: Image = battle.battle_hud.minimap_image()
	if image == null:
		failures.append("the minimap has no image")
	else:
		print("  minimap: %dx%d" % [image.get_width(), image.get_height()])
		# The scout is at the origin and on the player's team, so its blip must be
		# there. Reading the pixel back is the point of an Image-based minimap.
		var cell: Vector2i = battle.battle_hud.world_to_cell(0.0, 0.0)
		var here: Color = image.get_pixel(cell.x, cell.y)
		var terrain: Color = image.get_pixel(0, 0)
		print("  minimap pixel at the scout: %s   (corner terrain: %s)"
			% [str(here), str(terrain)])
		if here.is_equal_approx(terrain):
			failures.append("no blip was drawn at a friendly unit's position")

	# --- Win condition -------------------------------------------------------
	var ended: Array = []
	battle.match_ended.connect(func(winner): ended.append(winner))

	var enemy_hq = null
	for s in battle.get_team_structures(1):
		if s.kind == "hq":
			enemy_hq = s
	if enemy_hq == null:
		print("  no enemy HQ in this scene - testing with the player's own")
		for s in battle.get_team_structures(0):
			if s.kind == "hq":
				enemy_hq = s
	if enemy_hq == null:
		failures.append("no HQ found at all - the win condition cannot be tested")
	else:
		var losing_team: int = enemy_hq.team
		enemy_hq.take_damage(999999.0, "explosive", null)
		await process_frame
		print("  match_ended fired: %s  winner: %s  game_over: %s"
			% [str(ended.size() == 1), str(ended), str(battle.game_over)])
		if ended.is_empty():
			failures.append("destroying an HQ did not end the match")
		elif ended.size() > 1:
			failures.append("match_ended fired %d times - it must be once" % ended.size())
		elif ended[0] == losing_team:
			failures.append("the team that LOST its HQ was declared the winner")

	_finish(battle, failures)


func _finish(battle: Node, failures: Array) -> void:
	battle.queue_free()
	await process_frame
	if failures.is_empty():
		print("[PASS] battle phase 4 - vision, HUD, win condition")
		quit(0)
	else:
		for f in failures:
			print("  [FAIL] %s" % f)
		print("[FAIL] battle phase 4: %d problem(s)" % failures.size())
		quit(1)
