extends Node
# Test Range launcher. Used by:
#   * main_menu.gd's "PROVING GROUND" card
#   * stat_calculator.gd's "Test in Arena" button (the Design Lab's
#     destructive-test-permit exit)
#
# Both go through this single function so the rule set the Battle.tscn
# match director reads is identical in shape and provenance, and the
# two screens cannot drift in what "Test Range" actually means.
#
# WHAT IT DOES. Resolves the player blueprint path (Design Lab's
# scratch slot first, then the most-recent-saved blueprint, then a
# bundled default), picks three dummies from the bundled loadout, builds
# a `MatchRuleSet.test_range(...)` and writes it to MatchConfig alongside
# the display-only `selected_map_id`, then routes the scene change
# through SceneRouter the way every other entry point already does.
#
# WHY NOT INSIDE main_menu.gd. The Design Lab is the one with the
# freshest blueprint (it just built it), and the Lab's button cannot
# reach into the Main Menu's class without making the Main Menu
# autoload-global. Keeping the launcher as a small Node the screen
# instances and calls is what keeps both entry points independent of
# each other.
#
# The launcher is a Node, not RefCounted, because SceneRouter is
# reached through `get_node_or_null` and that is the path every
# other launcher in the project already uses.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const MatchConfigScript = preload("res://scripts/match_config.gd")

# The three dummies the original `Battlefield.tscn` map shipped with
# (battlefield.gd:168). Kept as a const so the two callers (Main Menu
# and Design Lab) cannot drift on which dummies show up.
const DUMMY_BLUEPRINT_PATHS := [
	"res://data/loadout/bulwark_mbt.json",
	"res://data/loadout/rattler_scout.json",
	"res://data/loadout/wasp_rocket_buggy.json",
]

# The bundled default when neither the scratch slot nor any saved
# blueprint is on disk. A fresh install boots into Test Range as the
# Bulwark MBT rather than as a blank screen with no design to test.
const FALLBACK_BLUEPRINT_PATH := "res://data/loadout/bulwark_mbt.json"

# The Test Range map. The plan's Phase 3 keeps the small artificial
# map the legacy Battlefield.tscn shipped with (battlefield.gd:19-38)
# for now; once MapCatalog learns about a "test_range" entry, the
# launcher will look it up by id rather than the legacy dict.
const TEST_RANGE_MAP_ID := "test_range"


# Resolves the player blueprint path: scratch first, most-recent-saved
# second, bundled default third. Returns the empty string only when
# every option failed, which means a corrupt library state - the
# caller treats that as an error and refuses to launch.
func _resolve_player_blueprint_path() -> String:
	var mgr = BlueprintManagerScript.new()
	add_child(mgr)
	# 1. Design Lab's scratch slot - the freshest design by definition.
	var scratch: Dictionary = mgr.load_blueprint("user://lab_scratch.json")
	if not scratch.is_empty():
		mgr.queue_free()
		return "user://lab_scratch.json"
	# 2. Most-recent-saved named blueprint. mgr.list_blueprints(true)
	# returns named-only (skips the "Untitled Design" placeholder per
	# BlueprintManager.is_named), and the natural list order is the
	# mtime sort the Library screen uses.
	var roster: Array = mgr.list_blueprints(true)
	if not roster.is_empty():
		var path := str(roster[0].get("path", ""))
		if path != "":
			mgr.queue_free()
			return path
	# 3. Bundled default. Will never be empty-string unless the
	# default-roster file itself went missing, which is a release
	# blocker; the caller surfaces the empty string as a user-facing
	# error rather than crashing.
	mgr.queue_free()
	return FALLBACK_BLUEPRINT_PATH


# Writes a Test Range rule set to MatchConfig, then routes the scene
# change to Battle.tscn through SceneRouter. After Phase 5, MatchConfig
# only carries `rule_set` and `selected_map_id` (display only), so the
# launcher writes the same two fields the other launchers write -
# faction / credits / difficulty / blueprint paths all live on the
# rule set, where MatchRuleSet.test_range() sets them with the right
# Test Range defaults (industrialists vs technocrats, no starting
# credits override, KILL_ALL_DUMMIES win).
#
# `from_screen` is a free-form label written to PROGRESS.md-worthy
# logging. It is the screen the user clicked from - "main_menu" or
# "design_lab" - so a future log reader can tell which entry point
# launched the Test Range without diffing the git history.
func launch(from_screen: String) -> bool:
	var player_path := _resolve_player_blueprint_path()
	if player_path == "":
		push_error("[TestRange] No player blueprint available - cannot launch")
		return false

	var mc: Node = _ensure_match_config()
	mc.selected_map_id = TEST_RANGE_MAP_ID
	mc.rule_set = MatchRuleSetScript.test_range(player_path, DUMMY_BLUEPRINT_PATHS)

	# SceneRouter if it is up; direct change_scene_to_file otherwise
	# (the same fallback every other launcher in the project uses,
	# for the test path that boots without autoloads).
	var router := get_node_or_null("/root/SceneRouter")
	if router != null:
		router.goto("res://scenes/Battle.tscn", "TEST RANGE")
	else:
		get_tree().change_scene_to_file("res://scenes/Battle.tscn")
	return true


# Returns the autoload MatchConfig if one is mounted, or makes a
# temporary one for the test path. Mirrors the same pattern in
# test_match_rule_set_integration.gd's _ensure_match_config.
func _ensure_match_config() -> Node:
	var existing := get_tree().root.get_node_or_null("MatchConfig")
	if existing != null:
		return existing
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(MatchConfigScript)
	get_tree().root.add_child(mc)
	return mc
