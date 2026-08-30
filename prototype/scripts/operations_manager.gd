extends Node
# OperationsManager (Autoload / Singleton)
# Manages multi-round Operations campaign state, tracking stage progression,
# map rotation, player/AI roster state, and target blueprint pre-selection
# for inter-round Design Lab iteration.

const MapCatalogScript = preload("res://scripts/map_catalog.gd")

signal operation_started(operation_data: Dictionary)
signal stage_completed(stage_index: int, results: Dictionary)
signal operation_completed(overall_results: Dictionary)

# How many engagements an operation may be. The floor is 3 because two rounds
# is not a campaign - there is only one draft between them, so nothing is
# learned twice. The ceiling is 12 because that is where the itinerary editor
# stops fitting a screen and where re-drafting stops being a decision.
const MIN_ENGAGEMENTS := 3
const MAX_ENGAGEMENTS := 12

# Current active Operation session data
var is_active_operation: bool = false
var current_stage: int = 0
var difficulty: String = "normal" # "easy", "normal", "hard"
var target_iteration_blueprint: String = "" # Blueprint name queued to open in Design Lab

# Stages itinerary: map IDs and AI difficulty parameters. Replaced wholesale by
# start_new_operation() when the setup screen passes one in; this default is
# what a campaign started without a screen (a test, a direct boot) gets.
var stages_itinerary: Array = default_itinerary(3, "normal")


# Total stages is the itinerary's length, not a separate field. It used to be
# both, and the two could disagree the moment a custom itinerary was passed in -
# start_new_operation() replaced the array and left the count at 3.
var total_stages: int:
	get:
		return stages_itinerary.size()


# The default rotation, for `count` engagements at a chosen difficulty.
#
# Static so the setup screen can read it without instantiating a manager it then
# has to free - which is what it used to do, one line before constructing a
# SECOND manager into /root.
static func default_itinerary(count: int, base_difficulty: String = "normal") -> Array:
	var maps := MapCatalogScript.get_map_ids()
	var out: Array = []
	var n: int = clampi(count, MIN_ENGAGEMENTS, MAX_ENGAGEMENTS)
	for i in range(n):
		out.append({
			"map_id": str(maps[i % maps.size()]) if not maps.is_empty() else "delta_blues",
			"ai_difficulty": ramped_difficulty(i, n, base_difficulty),
			"title": "Engagement %d" % (i + 1),
		})
	return out


# An operation ramps: the chosen difficulty is where it ENDS, not a flat setting
# applied to every round. The first third opens one tier easier so the opening
# engagement is a place to find out what your roster does wrong, and the last
# third is the tier that was actually picked.
static func ramped_difficulty(index: int, count: int, base_difficulty: String) -> String:
	var tiers := ["easy", "normal", "hard"]
	var top: int = maxi(0, tiers.find(base_difficulty))
	if count <= 1 or top <= 0:
		return tiers[top]
	# Rounds map onto [top-1 .. top], spending the first third below.
	var progress: float = float(index) / float(count - 1)
	return tiers[top - 1] if progress < 0.34 else tiers[top]

# Round history tracking
var stage_results_history: Array = []

func start_new_operation(custom_itinerary: Array = [], selected_difficulty: String = "normal") -> void:
	is_active_operation = true
	current_stage = 0
	difficulty = selected_difficulty
	stage_results_history.clear()
	target_iteration_blueprint = ""
	player_roster_paths.clear()
	operation_id = _new_operation_id()

	if not custom_itinerary.is_empty():
		stages_itinerary = custom_itinerary.duplicate(true)

	operation_started.emit({
		"stages": stages_itinerary,
		"difficulty": difficulty
	})
	request_save()

func get_current_stage_info() -> Dictionary:
	if current_stage >= 0 and current_stage < stages_itinerary.size():
		return stages_itinerary[current_stage]
	return {}

# The combat log, one entry per finished engagement. `stage_stats` is
# MatchStats.to_report() plus who won, what each side fielded, and how long it
# took - which is everything counter-drafting needs to read later, recorded at
# the only moment it is all still in one place.
func record_stage_result(stage_stats: Dictionary) -> void:
	var entry: Dictionary = stage_stats.duplicate(true)
	entry["stage"] = current_stage
	entry["map_id"] = str(get_current_stage_info().get("map_id", ""))
	stage_results_history.append(entry)
	stage_completed.emit(current_stage, entry)
	# THE LAST ENGAGEMENT CLOSES THE OPERATION HERE, not in
	# advance_to_next_stage(). advance() is driven by the report's "Next
	# Engagement" button, and that button is not OFFERED after the final round -
	# has_next_stage() is false, so the only way out of the last report is Main
	# Menu. Leaving the close to advance() therefore meant the final engagement
	# never closed anything: the save stayed on disk pointing at a stage that
	# had already been fought and won, and resuming it re-fought the last
	# battle, forever. Recording the last result IS the end of the operation.
	if current_stage + 1 >= stages_itinerary.size():
		_finish_operation()
	else:
		request_save()


func advance_to_next_stage() -> bool:
	current_stage += 1
	if current_stage >= stages_itinerary.size():
		# Normally already closed by record_stage_result() above; this covers a
		# caller that advances without recording (the abandon-and-skip path a
		# future screen might want) and is a no-op otherwise - _finish_operation()
		# guards on is_active_operation so operation_completed cannot double-fire.
		_finish_operation()
		return false
	request_save()
	return true


# One place where an operation ends, whichever way it got there. Guarded on
# is_active_operation so the two callers above cannot both fire
# operation_completed for the same campaign.
#
# THE SAVE IS DELETED, NOT MARKED DONE. list_saved() is the resume list, and a
# finished campaign has nothing to resume into - current_stage is past the end
# of its own itinerary, which from_dict() now refuses outright. Marking it
# complete and filtering it out of the list instead would leave a file in
# user://operations/ that no screen can ever show and therefore no player can
# ever delete, one per campaign, forever. What is worth keeping after the last
# engagement is the debrief, and that is on screen at the moment it matters.
func _finish_operation() -> void:
	if not is_active_operation:
		return
	is_active_operation = false
	operation_completed.emit({"history": stage_results_history})
	delete_save()


# Whether there is another engagement after the one just finished. Asked by the
# after-action report to decide between "Next Engagement" and "Operation
# Complete", and it must NOT be answered by advancing - the report is shown
# before the player has chosen to go on.
func has_next_stage() -> bool:
	return is_active_operation and current_stage + 1 < stages_itinerary.size()


# What the player fielded going into the next engagement. Set by the draft
# screen, read by MatchConfig on the way into the match.
func set_player_roster(paths: Array) -> void:
	player_roster_paths = paths.duplicate()
	request_save()


# What each side fielded, per round, newest last. The seam counter-drafting
# reads: Commander.design_fills_role() can classify a design it has never seen,
# so this is enough to bias a roster without new AI.
func fielded_history() -> Array:
	var out: Array = []
	for entry in stage_results_history:
		out.append({
			"stage": entry.get("stage", 0),
			"map_id": entry.get("map_id", ""),
			"victory": entry.get("victory", false),
			"player_designs": entry.get("player_designs", []),
			# The threat tags are what CounterDraft actually reads. Leaving them
			# out of this projection - which is what happened first - makes the
			# counter-draft silently see an empty history and field a balanced
			# force forever, with no error anywhere to say so.
			"player_threats": entry.get("player_threats", []),
			"enemy_designs": entry.get("enemy_designs", []),
		})
	return out


# --- Persistence --------------------------------------------------------------
#
# JSON to user://operations/, NOT .tres Resources. The research pass proposed
# nested Resource + ResourceSaver with FLAG_BUNDLE_RESOURCES; that solves a
# problem this codebase does not have. Blueprints are already JSON at schema
# v2.0 with a deliberate scratch-vs-saved split, and data/loadout/ and
# data/enemy/ are load-bearing JSON. One serialisation format.
#
# VERSIONED FROM DAY ONE. The blueprint schema earned its version the hard way -
# a silently mis-loaded old save is worse than a refused one.
#
# WHERE THE WRITE IS TRIGGERED, and why it is here rather than at the call sites.
# Every state change an operation has - started, roster drafted, engagement
# recorded, stage advanced - already funnels through exactly one method on this
# object. Hooking the save onto those methods means the campaign is persisted by
# the act of changing, and a new screen cannot forget to call save() the way
# operations_setup.gd, operations_draft.gd and match_director.gd each would have
# had to remember. The alternative - saving on the stage_completed /
# operation_completed signals - was rejected because two of the four save-worthy
# moments (start, and the between-rounds re-draft) emit no signal at all, so half
# the wiring would still have had to live at a call site.
#
# THE WRITE ITSELF IS DEFERRED AND COALESCED (request_save below). Three of the
# four moments happen inside a button handler that then changes scene:
# operations_setup's BEGIN OPERATION mutates twice and routes, operations_draft's
# DEPLOY mutates once and routes, the after-action report records a result and
# then routes. Writing synchronously on each mutation put two full serialise +
# file-open + fsync round trips on the exact frame a scene transition starts.
# Marking dirty and flushing at idle collapses those to one write, off the
# transition's critical path, and still lands before the tree actually swaps
# scenes (SceneRouter's fade, and change_scene_to_file itself, are both deferred
# past the message queue).
const SAVE_VERSION := 1
const SAVE_DIR := "user://operations"

var operation_id: String = ""
var player_roster_paths: Array = []

# Set by request_save(), cleared by any write or delete. Exists so a handler that
# mutates three times before routing produces one file write rather than three.
var _save_pending: bool = false


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"operation_id": operation_id,
		"is_active_operation": is_active_operation,
		"current_stage": current_stage,
		"difficulty": difficulty,
		"stages_itinerary": stages_itinerary.duplicate(true),
		"stage_results_history": stage_results_history.duplicate(true),
		"player_roster_paths": player_roster_paths.duplicate(),
		# The design the player asked to iterate on, which is set on the way OUT
		# of a match and consumed on the way INTO the Lab - so it is live across
		# exactly the scene change a quit is most likely to interrupt. Added
		# without a SAVE_VERSION bump on purpose: an older reader ignores an
		# unknown key and a newer reader defaults it to "", so neither direction
		# mis-loads, which is the only thing the version guard exists to prevent.
		"target_iteration_blueprint": target_iteration_blueprint,
	}


# Returns false rather than half-applying. A campaign restored from a file whose
# shape has moved on is worse than one that admits it cannot be restored.
func from_dict(data: Dictionary) -> bool:
	if int(data.get("version", -1)) != SAVE_VERSION:
		push_warning("OperationsManager: refusing to load save version %s (expected %d)"
			% [str(data.get("version", "?")), SAVE_VERSION])
		return false
	var itinerary: Array = data.get("stages_itinerary", [])
	if itinerary.is_empty():
		push_warning("OperationsManager: refusing to load a save with no itinerary")
		return false
	# A POINTER PAST THE END OF THE ITINERARY IS NOT A RESUMABLE CAMPAIGN, and it
	# used to be accepted. get_current_stage_info() then returns {}, which the
	# draft screen renders as a blank map name and which write_match_config()
	# silently resolves to MapCatalog.DEFAULT_MAP_ID - so a finished or corrupt
	# save came back as a playable engagement on the wrong map with no error
	# anywhere. Refused for the same reason a bad version is.
	var stage: int = int(data.get("current_stage", 0))
	if stage < 0 or stage >= itinerary.size():
		push_warning("OperationsManager: refusing a save whose stage pointer (%d) is outside its %d-stage itinerary"
			% [stage, itinerary.size()])
		return false
	operation_id = str(data.get("operation_id", ""))
	is_active_operation = bool(data.get("is_active_operation", false))
	current_stage = stage
	difficulty = str(data.get("difficulty", "normal"))
	stages_itinerary = itinerary.duplicate(true)
	stage_results_history = (data.get("stage_results_history", []) as Array).duplicate(true)
	player_roster_paths = (data.get("player_roster_paths", []) as Array).duplicate()
	# Assigned unconditionally, not only when the key is present: this manager is
	# an autoload, so a load lands on top of whatever the previous campaign left
	# behind, and a stale queued design would otherwise open the Lab on a vehicle
	# from a campaign the player just walked away from.
	target_iteration_blueprint = str(data.get("target_iteration_blueprint", ""))
	# A restore is not itself a change worth writing back, and writing here would
	# rewrite the file the player is in the middle of choosing from.
	_save_pending = false
	return true


func save_path() -> String:
	return "%s/%s.json" % [SAVE_DIR, operation_id if operation_id != "" else "current"]


# Marks the campaign dirty and schedules one flush. See the persistence header
# for why the write is deferred rather than immediate.
#
# Only an ACTIVE operation with an id is persisted. That single guard is what
# keeps a stray mutation after reset_operation() or after the final engagement
# from re-creating a file that delete_save() just removed - the resume list would
# otherwise sprout a campaign the player had already finished or abandoned.
func request_save() -> void:
	if not is_active_operation or operation_id == "":
		return
	if _save_pending:
		return
	_save_pending = true
	_flush_save.call_deferred()


func _flush_save() -> void:
	if not _save_pending:
		return
	save()


# The immediate, synchronous write. Kept public and separate from request_save()
# so a caller that genuinely needs the bytes on disk before it continues (the
# tests, tools/probe_operations_loop.gd) can say so.
func save() -> bool:
	_save_pending = false
	if operation_id == "":
		# No operation to save. Writing "current.json" here would put a nameless
		# half-campaign into the resume list.
		return false
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var file := FileAccess.open(save_path(), FileAccess.WRITE)
	if file == null:
		push_warning("OperationsManager: could not write %s" % save_path())
		return false
	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()
	return true


# Removes this campaign's file and cancels any flush still queued for it -
# without that second half, the deferred write from the mutation that ENDED the
# operation would land a moment later and put the file straight back.
func delete_save() -> bool:
	_save_pending = false
	if operation_id == "":
		return false
	return delete_save_at(save_path())


# Deleting by path, for the resume list's DISCARD. Static because the screen has
# the path from list_saved() and should not have to know SAVE_DIR to act on it.
static func delete_save_at(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("OperationsManager: %s is not a JSON object" % path)
		return false
	return from_dict(parsed)


# Every saved operation, newest first, as
# {id, path, stage, total, difficulty, active, saved_unix}.
#
# STATIC, for the same reason default_itinerary() is: the resume list is drawn by
# a setup screen that has no business instantiating a manager it then has to
# free, and nothing here reads instance state. Calling it through the autoload
# still works, so no existing call site has to change.
static func list_saved() -> Array:
	var out: Array = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var path: String = "%s/%s" % [SAVE_DIR, name]
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		out.append({
			"id": str(parsed.get("operation_id", name.get_basename())),
			"path": path,
			"stage": int(parsed.get("current_stage", 0)),
			"total": (parsed.get("stages_itinerary", []) as Array).size(),
			"difficulty": str(parsed.get("difficulty", "normal")),
			"active": bool(parsed.get("is_active_operation", false)),
			# WHEN IT WAS LAST PLAYED, from the file's own mtime rather than a
			# stored timestamp - it needs no schema change, and "last played" is
			# the thing that tells two in-flight campaigns apart, which "started"
			# would not. This also replaces the previous out.reverse(), which
			# leaned on DirAccess.get_files() coming back alphabetically sorted
			# AND on the id being a unix stamp; sorting on the number directly is
			# the same intent without the two assumptions.
			"saved_unix": FileAccess.get_modified_time(path),
		})
	out.sort_custom(func(a, b): return int(a["saved_unix"]) > int(b["saved_unix"]))
	return out


# Whether a list_saved() entry describes a campaign that can actually be picked
# back up. `active` alone is not enough: the pointer also has to name a stage
# inside the itinerary, because that is exactly what from_dict() refuses. If this
# and the loader ever disagree, the resume button lands on a push_warning and
# nothing else - which is the worst possible failure for this feature.
static func entry_is_resumable(entry: Dictionary) -> bool:
	if not bool(entry.get("active", false)):
		return false
	var stage: int = int(entry.get("stage", 0))
	return stage >= 0 and stage < int(entry.get("total", 0))


# Deletes every save entry_is_resumable() rejects; returns how many went.
#
# Separate from list_saved() on purpose - a function that lists must not delete,
# or a screen that only wanted to count campaigns quietly destroys them. Called
# by the one screen that draws the resume list, because that screen is the only
# thing in the game that ever looks at this directory and so the only place a
# dead file can be noticed at all.
static func prune_unresumable() -> int:
	var removed := 0
	for entry in list_saved():
		if entry_is_resumable(entry):
			continue
		if delete_save_at(str(entry.get("path", ""))):
			removed += 1
	return removed


# A queued write must not be lost to a quit. WM_CLOSE_REQUEST is the window's
# close box; EXIT_TREE covers get_tree().quit() and the autoload teardown that
# follows it. Both fire after the message queue's last ordinary flush, so without
# this the one case the save exists for - the player closing the game mid-
# campaign - is the one case it could miss.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_flush_save()


# Time-based, so two operations started in the same session do not collide and
# so list_saved()'s reverse-alphabetical order is newest-first.
func _new_operation_id() -> String:
	return "op_%d" % Time.get_unix_time_from_system()

func queue_blueprint_iteration(blueprint_name: String) -> void:
	target_iteration_blueprint = blueprint_name

func pop_queued_iteration_blueprint() -> String:
	var bp_name = target_iteration_blueprint
	target_iteration_blueprint = ""
	return bp_name

# Abandoning. Reached from the draft screen's ABANDON OPERATION, and used by the
# test suites to hand the autoload back in a clean state.
#
# THE FILE GOES TOO. "Abandon" that leaves the campaign in the resume list is not
# abandoning it, it is hiding it - the player would come back to the Operations
# screen and be offered the run they just quit. Deleted before the id is cleared,
# because save_path() is derived from it.
func reset_operation() -> void:
	delete_save()
	is_active_operation = false
	operation_id = ""
	current_stage = 0
	stage_results_history.clear()
	target_iteration_blueprint = ""
