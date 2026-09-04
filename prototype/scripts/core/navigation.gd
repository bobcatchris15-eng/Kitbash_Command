extends RefCounted
class_name Navigation
# The route table: where every screen is, what it is called, and what it links to.
#
# WHY THIS EXISTS. Navigation was hub-and-spoke with no cross-links: every screen
# returned to the main menu and nothing else. Getting from the Design Lab to the
# Blueprint Library - two halves of ONE activity - meant a round trip through
# home, and so did Library to Skirmish. The route each screen went back to was a
# `"res://scenes/MainMenu.tscn"` string literal repeated at five call sites, so
# "where does back go" was not a question anything could answer.
#
# THE TABLE IS THE ANSWER. A screen declares its id; this file owns its title,
# its parent (which is what BACK means) and its cross-links. Adding a link is a
# line here rather than a button wired in a screen script.
#
# NOT AN AUTOLOAD. It is pure data plus static helpers - there is no state to
# hold, and three autoloads were already added this phase. Screens preload it.

const FRONT_DESK := "front_desk"
const LAB := "lab"
const LIBRARY := "library"
const HULL_BUILDER := "hull_builder"
const MATCH_SETUP := "match_setup"
const OPERATIONS_SETUP := "operations_setup"
const OPERATIONS_DRAFT := "operations_draft"
const PROVING_GROUND := "proving_ground"
const BATTLE := "battle"

# `parent` is what BACK goes to, and it is deliberately NOT always the Front
# Desk. Backing out of the Operations draft should land on the Operations setup
# that created it, not at home - the player is mid-campaign.
#
# `links` are the cross-links offered in the title band's contextual slot. They
# are the answer to F9 in the audit: the hub was a bottleneck because the only
# edge out of any screen was the one back to it.
const ROUTES := {
	FRONT_DESK: {
		"scene": "res://scenes/MainMenu.tscn",
		"title": "FRONT DESK",
		"parent": "",
		"links": [],
	},
	LAB: {
		"scene": "res://scenes/MainLab.tscn",
		"title": "DESIGN LAB",
		"parent": FRONT_DESK,
		"links": [LIBRARY],
	},
	LIBRARY: {
		"scene": "res://scenes/BlueprintLibrary.tscn",
		"title": "BLUEPRINT LIBRARY",
		"parent": FRONT_DESK,
		"links": [LAB, MATCH_SETUP],
	},
	# Armoring is part of designing a vehicle, so BACK goes to the Lab rather
	# than the Front Desk - you are mid-design, the same reasoning that puts the
	# Operations draft under its setup. Deliberately IS in this table, unlike the
	# Livery workshop, which is reached from a hardwired main-menu button and so
	# armor belongs to one blueprint.
	# 2026-08-18: Armor Station is now an IN-SCENE sub-mode of the Lab
	# (see lab_toolbar.gd's _on_paint_station_pressed and
	# UI_ArmorStationPanel.gd). It is not a routable destination
	# anymore, so the ARMOR_BAY route is removed.
	HULL_BUILDER: {
		"scene": "res://scenes/ModularHullBuilder.tscn",
		"title": "HULL AUTHORING",
		"parent": FRONT_DESK,
		"links": [LAB],
	},
	MATCH_SETUP: {
		"scene": "res://scenes/MatchSetup.tscn",
		"title": "SKIRMISH",
		"parent": FRONT_DESK,
		"links": [LIBRARY],
	},
	OPERATIONS_SETUP: {
		"scene": "res://scenes/OperationsSetup.tscn",
		"title": "OPERATIONS",
		"parent": FRONT_DESK,
		"links": [LIBRARY],
	},
	OPERATIONS_DRAFT: {
		"scene": "res://scenes/OperationsDraft.tscn",
		"title": "RE-DRAFT",
		"parent": OPERATIONS_SETUP,
		"links": [LAB, LIBRARY],
	},
	PROVING_GROUND: {
		# 2026-08-10: Battlefield.tscn retired. The Test Range now boots on
		# Battle.tscn via main_menu's PROVING GROUND card (which uses
		# TestRangeLauncher to write a MatchRuleSet.test_range into
		# MatchConfig) and stat_calculator's "Test in Arena" button
		# (same launcher). This entry is the legacy navigation route
		# for any screen that still calls goto() on PROVING_GROUND
		# directly; it now lands on Battle.tscn with whatever the
		# current MatchConfig says, which is fine for a "go back to
		# the menu" flow because the Test Range launcher has already
		# populated it by the time this route is reachable.
		"scene": "res://scenes/Battle.tscn",
		"title": "PROVING GROUND",
		"parent": LAB,
		"links": [LAB],
	},
	# No parent and no links: you do not "back out" of a live match, you concede
	# or you finish. SystemLayer owns leaving it.
	BATTLE: {
		"scene": "res://scenes/Battle.tscn",
		"title": "ENGAGEMENT",
		"parent": "",
		"links": [],
	},
}

# The prefix every breadcrumb carries. The interface consistently presents itself
# as a piece of institutional equipment ("DESIGN BUREAU / CONSOLE 04"), and the
# breadcrumb is the clearest place to keep saying so.
const BREADCRUMB_ROOT := "BUREAU"


static func route(id: String) -> Dictionary:
	return ROUTES.get(id, {})


static func title_of(id: String) -> String:
	return str(route(id).get("title", id.to_upper()))


static func scene_of(id: String) -> String:
	return str(route(id).get("scene", ""))


static func parent_of(id: String) -> String:
	return str(route(id).get("parent", ""))


static func links_of(id: String) -> Array:
	return route(id).get("links", [])


# "BUREAU / OPERATIONS / RE-DRAFT" - the full chain, so a player two screens deep
# can see it. Walks parents rather than storing the string, so a re-parenting is
# one edit.
static func breadcrumb(id: String) -> String:
	var chain: Array = []
	var cursor := id
	# Bounded, because a table typo that made two routes each other's parent
	# would otherwise hang the screen on load rather than showing a wrong label.
	var guard := 0
	while cursor != "" and guard < 8:
		chain.push_front(title_of(cursor))
		cursor = parent_of(cursor)
		guard += 1
	chain.push_front(BREADCRUMB_ROOT)
	return " / ".join(chain)


# Routes through SceneRouter so the transition fades and the loading screen is
# chosen by the router rather than by each call site - which is the rule
# scene_router.gd's own header asks for.
static func go(tree: SceneTree, id: String) -> void:
	var path := scene_of(id)
	if path == "":
		push_error("Navigation: unknown route '%s'" % id)
		return
	var router = tree.root.get_node_or_null("SceneRouter")
	if router != null:
		router.goto(path)
	else:
		tree.change_scene_to_file(path)
