extends RefCounted
# The two-phase tutorial script, as data.
#
# Phase 1: Skirmish with weak units (player experiences defeat)
# Phase 2: Design Lab to build a better unit
#
# One entry per step. TwoPhaseTutorialManager walks the appropriate phase's
# array; TwoPhaseTutorialOverlay renders whichever entry is current.

const SCENE_BATTLE := "res://scenes/Battle.tscn"
const SCENE_LAB := "res://scenes/MainLab.tscn"

# Phase 1: Skirmish steps (weak units vs strong enemies)
const PHASE_1_STEPS := [
	{
		"scene": SCENE_BATTLE,
		"title": "WELCOME TO KITBASH COMMAND",
		"body": "You are about to command a force in a skirmish battle. "
			+ "But first, a warning: your units are poorly designed. "
			+ "They have weak armor, weak weapons, and no staying power.\n\n"
			+ "This is intentional. You will lose this battle - and that is the lesson.\n\n"
			+ "Camera: hold right mouse to orbit, middle mouse to pan, wheel to zoom. "
			+ "Try it now, then continue.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "PLACE YOUR HQ",
		"body": "Every skirmish starts by placing your Headquarters. "
			+ "A green highlight marks your assigned base area. "
			+ "Click anywhere inside it to drop your HQ.\n\n"
			+ "The HQ is free - it doesn't cost credits. Everything else "
			+ "(refinery, factories, harvester) you'll build with your starting bank.",
		"target": "",
		"advance": "hq_placed",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "THE BATTLEFIELD",
		"body": "Your HQ is live. Your three units deploy automatically. "
			+ "The enemy base is on the far side with two units: a Striker "
			+ "with tracks and a cannon, and an Artillery unit with long-range fire.\n\n"
			+ "Resources (metal/crystal) are scattered between - harvesters collect them, "
			+ "refineries process them, factories build units.",
		"target": "",
		"advance": "battle_started",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "GIVE YOUR UNITS ORDERS",
		"body": "Select your units (left-click or drag a box). Right-click on the ground "
			+ "to move them. Right-click an enemy to attack-move.\n\n"
			+ "Your units will auto-engage when in range. Watch what happens when "
			+ "your Weak Scout meets the enemy Striker.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "ENGAGE THE ENEMY",
		"body": "Move your units toward the enemy base. The Artillery will fire from "
			+ "long range - your Weak Hauler and Weak Defender have no answer to it.\n\n"
			+ "The Striker will close and shred your Scout. Your units have "
			+ "thin armor (0.5-0.6 thickness) and light weapons. "
			+ "The enemy has 1.2 thickness armor and heavy guns.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "WATCH YOUR UNITS FALL",
		"body": "This is the point: poorly designed units die fast. "
			+ "Directional armor only protects the facet facing the attacker. "
			+ "Your Scout has a cannon only on the front - flanked, it's helpless.\n\n"
			+ "Your Hauler has NO weapons. Your Defender has no mobility.\n\n"
			+ "When your last unit is destroyed, the match ends.",
		"target": "",
		"advance": "player_defeated",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "DEFEAT - BUT THE WAR CONTINUES",
		"body": "Your force has been wiped out. The enemy base still stands.\n\n"
			+ "In a real Operation, this would cost you an engagement. "
			+ "But here, it teaches you WHY design matters:\n\n"
			+ "- Armor thickness and material determine survival\n"
			+ "- Weapon choice and placement determine kill power\n"
			+ "- Locomotion determines whether you can reach the fight\n"
			+ "- Every stat in the telemetry rail translates to battlefield reality\n\n"
			+ "Now you will build a unit that can win.",
		"target": "",
		"advance": "next_button",
	},
]

# Phase 2: Design Lab steps (build a better unit)
const PHASE_2_STEPS := [
	{
		"scene": SCENE_LAB,
		"title": "THE DESIGN BUREAU - PHASE 2",
		"body": "You are back in the Design Lab. The loop is simple: "
			+ "design here, test on the range, field in battle.\n\n"
			+ "You just saw what bad design looks like in combat. "
			+ "Now build something that survives.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_LAB,
		"title": "START WITH A STRONGER CHASSIS",
		"body": "Every design starts with a hull. Your previous units used "
			+ "light hulls (Scout, Transport, Bunker). For a combat unit, "
			+ "choose a Medium or Heavy hull.\n\n"
			+ "Drag the highlighted Medium Hull (Brenntal) onto the platform. "
			+ "It has more base structure, more mounting surface, and better "
			+ "weight capacity for armor and weapons.",
		"target": "part_card:brenntal_medium_a",
		"advance": "hull_replaced",
	},
	{
		"scene": SCENE_LAB,
		"title": "ADD REAL ARMOR",
		"body": "Your previous units had 0.5-0.6 armor thickness with Hardened Steel. "
			+ "That stops almost nothing. In the right rail, find the Armor Material "
			+ "dropdown and Armor Thickness slider:\n\n"
			+ "- Armor Material: Hardened Steel (or Reactive for kinetic)\n"
			+ "- Armor Thickness: 1.5 to 2.0\n\n"
			+ "Thicker armor adds weight - watch the drivetrain readout. "
			+ "You'll need stronger drives to carry it.",
		"target": "telemetry_dock",
		"advance": "next_button",
	},
	{
		"scene": SCENE_LAB,
		"title": "GIVE IT TRACKS FOR WEIGHT",
		"body": "Wheels are fast but have low weight capacity. Your heavy armor "
			+ "needs Tracked Treads - they carry more weight and handle rough "
			+ "terrain better.\n\n"
			+ "Drag Tracked Treads from the Drives toolbox onto the hull. "
			+ "They auto-place on the bottom facet. The telemetry rail will "
			+ "show your weight capacity vs actual weight.",
		"target": "part_card:tracked_treads",
		"advance": "locomotion_placed",
	},
	{
		"scene": SCENE_LAB,
		"title": "ARM IT WITH A TURRET CANNON",
		"body": "Your Scout had a fixed-front Basic Cannon. A turret rotates "
			+ "360 degrees - no flanking weakness.\n\n"
			+ "Drag the Basic Cannon onto the TOP facet of the hull. "
			+ "It will mount as a turret. In the floating tweak panel, "
			+ "increase Caliber to 1.3 and Barrel Length to 1.4 for "
			+ "real anti-armor performance.",
		"target": "part_card:basic_cannon",
		"advance": "weapon_placed",
	},
	{
		"scene": SCENE_LAB,
		"title": "ADD A CO-AXIAL AUTOCANNON",
		"body": "A turret cannon has traverse limits and reload time. "
			+ "Add an Autocannon as a pintle mount on the turret "
			+ "for close-in defense against light units and aircraft.\n\n"
			+ "Drag Autocannon onto the TOP facet near the cannon. "
			+ "It mounts as a pintle (side-mounted, limited arc but fast tracking).",
		"target": "part_card:autocannon",
		"advance": "weapon_placed",
	},
	{
		"scene": SCENE_LAB,
		"title": "READ THE TELEMETRY - THIS IS YOUR UNIT",
		"body": "The rail now shows a real combat unit:\n\n"
			+ "- Structure: HP from hull + armor + modules\n"
			+ "- Weight: Must stay under drivetrain capacity\n"
			+ "- Cost: Metal/Crystal to build in a match\n"
			+ "- DPS: Combined damage output of all weapons\n"
			+ "- Range: Effective engagement distance\n\n"
			+ "If Weight > Capacity, your unit will be slow. "
			+ "Adjust tread width or armor thickness until Load Ratio is < 1.0.",
		"target": "telemetry_dock",
		"advance": "next_button",
	},
	{
		"scene": SCENE_LAB,
		"title": "NAME AND SAVE YOUR DESIGN",
		"body": "Type a name (e.g. 'Tutorial Striker'). The roll button generates "
			+ "military-style names if you prefer.\n\n"
			+ "Press SAVE BLUEPRINT. This writes your design to the Blueprint "
			+ "Library where it can be drafted into Skirmish or Operations.\n\n"
			+ "Save refuses if parts clip - the Lab prevents broken designs "
			+ "from reaching the battlefield.",
		"target": "name_field",
		"advance": "design_named",
	},
	{
		"scene": SCENE_LAB,
		"title": "SAVE TO LIBRARY",
		"body": "Press SAVE BLUEPRINT to commit your design.\n\n"
			+ "It now appears in the Blueprint Library and can be selected "
			+ "in Match Setup for your next skirmish.",
		"target": "toolbar_save",
		"advance": "blueprint_saved",
	},
	{
		"scene": SCENE_LAB,
		"title": "TEST IT ON THE RANGE",
		"body": "Before taking it to war, prove it here. "
			+ "Press TEST IN ARENA - this drops your exact design onto "
			+ "the proving ground against target dummies.\n\n"
			+ "Your work is not lost by leaving - the Lab restores it when you return.",
		"target": "toolbar_test",
		"advance": "test_in_arena",
	},
	{
		"scene": SCENE_BATTLE,  # Test Range uses Battle.tscn
		"title": "THE PROVING GROUND",
		"body": "Your new design, live, against target dummies. Some shoot back.\n\n"
			+ "This is the same unit code that runs in a real battle - it acquires "
			+ "targets, manoeuvres to bring armour to bear, and fires on its own.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "DRIVE AND SHOOT",
		"body": "Right-click to move. Drive within range of a dummy - your turret "
			+ "will traverse and fire automatically. Your pintle MG covers "
			+ "close angles.\n\n"
			+ "Watch your health. With 1.5+ armor thickness, kinetic rounds "
			+ "should bounce or chip. Your tracks carry the weight without overload.",
		"target": "",
		"advance": "next_button",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "DESTROY THE DUMMIES",
		"body": "Eliminate all three target dummies. Your cannon's 1.3 caliber "
			+ "and 1.4 barrel length give it armor-piercing performance "
			+ "far beyond the 0.6/0.6 Scout cannon.\n\n"
			+ "When the last dummy falls, return to the Lab.",
		"target": "arena_dummy",
		"advance": "arena_dummy_destroyed",
	},
	{
		"scene": SCENE_BATTLE,
		"title": "RETURN TO THE LAB",
		"body": "That is the whole point of the range - find the weakness here, "
			+ "where it costs nothing, rather than in an Operation.\n\n"
			+ "Click the RETURN button to go back to the Design Lab. "
			+ "Your design comes with you.",
		"target": "arena_return",
		"advance": "return_to_lab",
	},
	{
		"scene": SCENE_LAB,
		"title": "THE LOOP IS COMPLETE",
		"body": "Build, test, refine, repeat. Your design is in the Blueprint Library "
			+ "and ready to be drafted.\n\n"
			+ "From the main menu:\n"
			+ "- SKIRMISH: Single battle, pick map and roster\n"
			+ "- OPERATIONS: 3-12 engagements, re-draft between each\n"
			+ "- Both field what you build here\n\n"
			+ "Your Tutorial Striker will crush the enemies that destroyed "
			+ "your first force. That is the power of the Design Lab.",
		"target": "",
		"advance": "finish_button",
	},
]


# Every `advance` value the table is allowed to use.
const ADVANCE_IDS := [
	"next_button",
	"finish_button",
	"scene_is_battle",
	"battle_started",
	"hq_placed",
	"player_unit_lost",
	"player_defeated",
	"scene_is_lab",
	"hull_replaced",
	"locomotion_placed",
	"weapon_placed",
	"module_selected",
	"design_named",
	"blueprint_saved",
	"test_in_arena",
	"arena_dummy_destroyed",
	"return_to_lab",
]

# Every `target` value, minus the "part_card:<type_id>" family.
const TARGET_IDS := [
	"",
	"parts_dock",
	"telemetry_dock",
	"name_field",
	"toolbar_save",
	"toolbar_test",
	"hull",
	"arena_dummy",
	"arena_return",
]

const PART_CARD_PREFIX := "part_card:"


static func get_steps_for_phase(phase: int) -> Array:
	if phase == 1:
		return PHASE_1_STEPS
	elif phase == 2:
		return PHASE_2_STEPS
	return []


static func get_step(phase: int, index: int) -> Dictionary:
	var steps = get_steps_for_phase(phase)
	if index < 0 or index >= steps.size():
		return {}
	return steps[index]


static func count_for_phase(phase: int) -> int:
	return get_steps_for_phase(phase).size()


static func is_button_step(advance: String) -> bool:
	return advance == "next_button" or advance == "finish_button"