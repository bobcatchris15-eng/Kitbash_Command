extends Node
# Autoload singleton: carries the per-mode rule set the setup screen
# built (match_setup.gd / operations_draft.gd / test_range_launcher.gd)
# into the next match, plus selected_map_id for any caller that still
# wants it for display purposes.
#
# 2026-08-10: the seven legacy pre-match fields (player_livery /
# enemy_livery / selected_blueprint_paths / ai_difficulty /
# starting_credits, plus the redundant selected_map_id mirror) are
# retired. Phase 2 of the battle-system unification (June 2026) made
# match_director.gd read the rule set field-by-field, with each one
# falling back to the legacy field if the rule set was missing that key.
# Phase 5 retires the fallback: every caller now writes a
# MatchRuleSet, and every reader only consults the rule set. The
# duck-typed "match_config == null" guard in match_director.gd's
# _ready() still applies - a test path that boots Skirmish.tscn without
# the autoload gets the rule-set defaults (which is what a Test Range
# rule set would have given it), and the old hardcoded values are now
# the per-mode rule set's own defaults rather than per-field constants.
#
# Godot's change_scene_to_file() doesn't give the caller a handle to
# configure the new scene before it enters the tree, so a tiny autoload
# is the standard way to pass this kind of "next scene's setup" data -
# simpler than manually managing the scene tree swap just to inject one
# field.

# Battle-system unification (Phase 1): the per-mode rule set written by the
# setup screen, read by the match director. The single thing MatchConfig
# carries after Phase 5.
#
# Default `null` so a test path that instantiates a scene without the
# autoload registered keeps getting the rule-set defaults, which is the
# same posture as the `match_config == null` guard every other call
# site already uses.
var rule_set: MatchRuleSet = null

# Kept as a separate field for any UI that wants to display the chosen
# map's name (battle_hud minimap title, after-action report) before
# reading it from the rule set. Not used by the match director itself -
# the director reads the rule set.
var selected_map_id: String = ""

