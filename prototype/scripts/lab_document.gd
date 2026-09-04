class_name LabDocument
extends Control
const SliceShell = preload("res://scripts/ui_shell.gd")
const SliceTheme = preload("res://scripts/ui_theme.gd")
var lab_toolbar
var _document_expanded := true
var _document_page := "Performance"
var _document_body: ScrollContainer
var _document_tabs: HBoxContainer
var _document_toggle: Button
var _operation_label: Label
var _operation_icon: TextureRect
var _assembly_health_label: Label
var _document_clusters: Dictionary = {}
var tweak_callout_manager

var stats_dock: Control = null
var _callout_dirs = [
	Vector2(0.8, -1.2), Vector2(-0.8, -1.2), # Top corners
	Vector2(1.2, -0.2), Vector2(-1.2, -0.2), # High sides
	Vector2(1.2, 0.6), Vector2(-1.2, 0.6),   # Low sides
	Vector2(0.8, 1.2), Vector2(-0.8, 1.2)    # Bottom corners
]
var _current_callout_idx = 0


const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const BlueprintNamerScript = preload("res://scripts/blueprint_namer.gd")
const UIFlyoutScript = preload("res://scripts/ui_flyout.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const DesignVerdictScript = preload("res://scripts/design_verdict.gd")
const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")
const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const DesignStatsScript = preload("res://scripts/design_stats.gd")

# Folded in from the deleted telemetry_rail.gd - baseline/preview stat cache.
var _base_stats: Dictionary = {}
var _previewing: bool = false
var _cached_hull: Node3D = null

# --- Rail structure (VISUAL/UI plan item 7) ---------------------------------
# The rail used to be a bare anchored `Panel` in UI_StatBlock.tscn carrying an
# embedded StyleBoxFlat sub-resource (PanelStyle_Stats). Both are gone: the
# surface is a UIDock built in _ready(), which brings the STEEL frame, the
# POWDERCOAT body, the three collapse states and width persistence with it.
#
# EVERY @onready BELOW STAYS VALID ACROSS THAT MOVE. `$Path` resolves once, at
# _ready(), and stores an object reference - reparenting the subtree afterwards
# does not invalidate a reference, only a re-resolved path. The nine places that
# re-resolved `$ScrollContainer/VBoxContainer` on every call are the ones that
# had to change; they use `_rail_vbox` now, captured before the move.
var console_root: PanelContainer = null
var _slot_hull_label: Label = null
var _slot_parts_label: Label = null
var _slot_cost_label: Label = null
var _rail_vbox: VBoxContainer = null

# Alert Placard References (Overweight, Power Deficit & Vision/Spotter sliding warning bezels)
var overweight_alert_placard: PanelContainer = null
var overweight_text_label: Label = null
var overweight_detail_label: Label = null
var overweight_tween: Tween = null

var power_alert_placard: PanelContainer = null
var power_text_label: Label = null
var power_detail_label: Label = null
var power_tween: Tween = null

var vision_alert_placard: PanelContainer = null
var vision_text_label: Label = null
var vision_detail_label: Label = null
var vision_tween: Tween = null

# 4-Cluster UI References
var combat_hp_label: Label = null
var combat_dps_label: Label = null
var combat_speed_label: Label = null
var combat_range_label: Label = null
var combat_power_label: Label = null
var combat_weight_label: Label = null
var combat_role_label: Label = null
var combat_parts_label: Label = null
var combat_armor_label: Label = null
var combat_cargo_label: Label = null

var build_cost_label: Label = null
var build_materials_label: Label = null
var factory_glyph_label: Label = null
var factory_name_label: Label = null
var build_lab_tier_label: Label = null
var build_time_label: Label = null

var inspector_title_label: Label = null
var inspector_subtitle_label: Label = null
var inspector_stats_label: Label = null
var inspector_sliders_container: VBoxContainer = null

# The current design's headline stats, published by update_stats() for readers
# that want the numbers rather than the label text - fleet_comparison_panel.gd
# is the existing one. `drivetrain` is the whole Drivetrain.analyze() result
# (weight, capacity, load_ratio, top_speed, move_speed, is_overloaded, ...),
# so a new reader does not need a new field here for every figure it wants.
var total_hp: float = 0.0
var total_weight: float = 0.0
var total_dps: float = 0.0
var drivetrain: Dictionary = {}
var weapon_range: Dictionary = {}


@onready var hp_label = $ScrollContainer/VBoxContainer/HPLabel
@onready var weight_label = $ScrollContainer/VBoxContainer/WeightLabel
@onready var cost_label = $ScrollContainer/VBoxContainer/CostLabel
@onready var dps_label = $ScrollContainer/VBoxContainer/DPSLabel
@onready var mirror_checkbox = $ScrollContainer/VBoxContainer/MirrorCheckBox
@onready var delete_button = $ScrollContainer/VBoxContainer/DeleteButton
@onready var save_button = $ScrollContainer/VBoxContainer/SaveButton
@onready var test_button = $ScrollContainer/VBoxContainer/TestButton
@onready var blueprint_name_edit = $ScrollContainer/VBoxContainer/BlueprintNameEdit
@onready var library_button = $ScrollContainer/VBoxContainer/LibraryButton

@onready var locomotion_tweaks = $ScrollContainer/VBoxContainer/LocomotionTweaks
@onready var size_container = $ScrollContainer/VBoxContainer/LocomotionTweaks/SizeContainer
@onready var size_label = $ScrollContainer/VBoxContainer/LocomotionTweaks/SizeContainer/SizeLabel
@onready var size_slider = $ScrollContainer/VBoxContainer/LocomotionTweaks/SizeContainer/SizeSlider
@onready var count_container = $ScrollContainer/VBoxContainer/LocomotionTweaks/CountContainer
@onready var count_slider = $ScrollContainer/VBoxContainer/LocomotionTweaks/CountContainer/CountSlider
@onready var count_label = $ScrollContainer/VBoxContainer/LocomotionTweaks/CountContainer/CountLabel


const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
# Drivetrain and WeaponRange are no longer preloaded here: both are now called
# by design_stats.gd, which hands their results back in its return value, so this
# file has no direct use for either.
var current_selected_module: Node3D = null
var is_updating_sliders: bool = false
var _loco_slider_dragging: bool = false
var module_tweaks_container: VBoxContainer

# Which tweaks-dict key the shared "Size" slider writes, per locomotion
# type_id - used to route size_slider changes through
# update_locomotion_geometry_tweak() (no respawn) instead of the full
# update_locomotion() respawn _apply_tweaks() uses for count changes.
const LOCOMOTION_SIZE_KEY := {
	"wheels": "wheel_size",
	"tracked_treads": "tread_width",
	"helicopter_rotors": "blade_length",
	"legs": "leg_length",
	"hover_engine": "emv_level",
	"screw_drive": "drum_diameter",
	"ornithopter_wing": "wingspan",
	"half_track": "tread_width",
	"rocker_bogie": "wheel_size",
	"air_cushion_skirt": "skirt_diameter",
	"anti_grav_plate": "field_strength",
	# These two were missing and fell back to the "size" alias - a key nothing
	# reads for either type - so the Size dial was a dead knob and the declared
	# tweak (envelope_volume / tread_width) had no live control at all.
	"buoyant_envelope": "envelope_volume",
	"heavy_quad_tracks": "tread_width",
	"plasma_thruster": "nozzle_width",
}

const LOCOMOTION_SECONDARY_SIZE_KEY := {
	"helicopter_rotors": "blade_count",
	"buoyant_envelope": "blade_pitch",
	"screw_drive": "helix_depth",
	"ornithopter_wing": "wing_sweep",
	"half_track": "front_axle_size",
	"rocker_bogie": "arm_length",
	"air_cushion_skirt": "plenum_pressure",
}

# Floating Popup Window fields
var tweak_canvas: Control
var popup_name_label: Label
var popup_stats_label: Label
var popup_tweaks_container: VBoxContainer
var popup_rotate_btn: Button

const TWEAK_SPECS = {
	"basic_cannon": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_count", "label": "Barrel Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 1.0},
	],
	"rotary_cannon": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_count", "label": "Barrel Count", "min": 3.0, "max": 9.0, "step": 1.0, "default": 6.0},
		{"name": "motor_size", "label": "Electric Motor Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"gauss_railgun": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Electromagnetic Rail Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"artillery": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_count", "label": "Barrel Count", "min": 1.0, "max": 2.0, "step": 1.0, "default": 1.0},
	],
	"mortar_array": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Mortar Tube Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "tube_count", "label": "Mortar Tube Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 2.0},
	],
	"guided_missile": [
		{"name": "seeker_size", "label": "Missile Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Launch Tube Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_count", "label": "Launcher Tube Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 1.0},
	],
	"missile_pod": [
		{"name": "warhead_size", "label": "Rocket Warhead Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "motor_length", "label": "Rocket Motor Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "grid_size", "label": "Rocket Grid Size", "min": 2.0, "max": 6.0, "step": 1.0, "default": 4.0}
	],
	"cluster_dispenser": [
		{"name": "dispersion", "label": "Dispersion Spread Radius", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "payload_size", "label": "Canister Payload Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "tube_count", "label": "Projector Tube Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 2.0}
	],
	"flamethrower": [
		{"name": "nozzle_width", "label": "Emitter Nozzle Width", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Nozzle Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "pressure_valve", "label": "Pressure Fuel Valve", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"heavy_laser": [
		{"name": "lens_aperture", "label": "Laser Lens Aperture", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Optical Telescope Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"ciws": [
		{"name": "caliber", "label": "Rotary Gun Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Rotary Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "radar_dish", "label": "CIWS Tracking Radar Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"pd_laser": [
		{"name": "cooling_jacket", "label": "PD Laser Cooling Jacket", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Emitter Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# --- Roster expansion ---
	# Every tweak name below is reused from the existing vocabulary
	# (ModuleCatalog.LINEAR_SCALE_WEAPON_TWEAKS / module_data.gd's scaling
	# lists) rather than invented, so weight/cost/dps/range/traverse
	# scaling all work for these weapons with no new plumbing.
	"mk19_grenade_launcher": [
		{"name": "caliber", "label": "Grenade Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "drum_size", "label": "Belt Box Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"recoilless_rifle": [
		{"name": "caliber", "label": "Bore Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Tube Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"coil_gun": [
		{"name": "caliber", "label": "Slug Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"autocannon": [
		{"name": "caliber", "label": "Caliber", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "drum_size", "label": "Ammo Drum Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# Precision, not volume: no drum/ammo tweak at all, because "carry more
	# rounds" is not a question this weapon asks. optic_power is its
	# distinguishing slider (reach, at real crystal cost), and bipod_deploy
	# is the discrete capability trade - see auto_weapon's BIPOD_ constants.
	"anti_materiel_rifle": [
		{"name": "caliber", "label": "Calibre", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.6, "max": 2.2, "step": 0.1, "default": 1.0},
		{"name": "optic_power", "label": "Optic Power", "min": 0.7, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "bipod_deploy", "label": "Deploy Bipod", "min": 0.0, "max": 1.0, "step": 1.0, "default": 0.0},
	],
	"aa_autocannon": [
		{"name": "caliber", "label": "Calibre", "min": 0.6, "max": 1.6, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"sensor_beacon_launcher": [
		{"name": "payload_size", "label": "Beacon Size", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"spigot_mortar": [
		{"name": "rod_thickness", "label": "Spigot Rod", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Spigot Barrel Length", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "payload_size", "label": "Bomb Size", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"rocket_artillery": [
		{"name": "tube_count", "label": "Rail Count", "min": 2.0, "max": 8.0, "step": 1.0, "default": 4.0},
		{"name": "dispersion", "label": "Salvo Spread", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	"hypervelocity_missile": [
		{"name": "tube_count", "label": "Canister Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 2.0},
		{"name": "seeker_size", "label": "Designator Power", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"sam_launcher": [
		{"name": "tube_count", "label": "Rail Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 2.0},
		{"name": "radar_dish", "label": "Tracking Radar", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"bunker_buster": [
		{"name": "warhead_size", "label": "Penetrator Mass", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "ascent_thruster", "label": "Top-Attack Climb", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"cruise_missile": [
		{"name": "warhead_size", "label": "Warhead Size", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "motor_length", "label": "Fuel Load", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"mine_layer": [
		{"name": "tube_count", "label": "Mines Per Volley", "min": 1.0, "max": 4.0, "step": 1.0, "default": 1.0},
		{"name": "payload_size", "label": "Mine Charge Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# Tube count is the discharger's one real handle: more tubes means more
	# canisters per volley and so a wider screen, at the usual weight/cost.
	"smoke_discharger": [
		{"name": "tube_count", "label": "Discharger Tube Count", "min": 2.0, "max": 6.0, "step": 1.0, "default": 4.0},
	],
	"resource_harvester": [
		{"name": "cutter_head", "label": "Drill Head Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "mount_extension", "label": "Mount Extension", "min": 0.6, "max": 1.5, "step": 0.1, "default": 1.0}
	],
	# Three levers, and they are deliberately not three flavours of the same one.
	# bay_volume is the stat that matters (cargo carried, and the weight paid for
	# it); hopper_depth and hatch_width are pure geometry, changing how the bay
	# reads on the hull and how much deck it eats without touching capacity - the
	# bay is a big part and where it fits is a real constraint on a crowded
	# harvester. Sizing tweaks with no stat behind them would normally be dead
	# tweaks, but these two change the module's own footprint, which is what
	# decides whether a third bay fits at all.
	"resource_bay": [
		{"name": "bay_volume", "label": "Bay Volume", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "hopper_depth", "label": "Hopper Depth", "min": 0.6, "max": 1.6, "step": 0.1, "default": 1.0},
		{"name": "hatch_width", "label": "Hatch Width", "min": 0.6, "max": 1.6, "step": 0.1, "default": 1.0}
	],
	"repair_array": [
		{"name": "welder_count", "label": "Welder Arm Count", "min": 1.0, "max": 4.0, "step": 1.0, "default": 2.0},
		{"name": "arm_reach", "label": "Manipulator Arm Reach", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"sensor_suite": [
		{"name": "mast_height", "label": "Radar Mast Height", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "dish_aperture", "label": "Dish Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "whip_length", "label": "Whip Antenna Length", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0}
	],
	"heavy_sensor_suite": [
		{"name": "pylon_height", "label": "Array Pylon Height", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "radome_scale", "label": "Multispectrum Radome Scale", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "optics_aperture", "label": "EO/IR Sensor Aperture", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0}
	],
	"directional_radar": [
		{"name": "scan_arc", "label": "Sector Scan Arc (°)", "min": 40.0, "max": 120.0, "step": 5.0, "default": 60.0},
		{"name": "mast_height", "label": "Gimbal Mast Height", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "array_gain", "label": "Phased Array Gain", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0}
	],
	"energy_barrier_projector": [
		{"name": "projector_diameter", "label": "Array Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "coil_count", "label": "Capacitor Coil Count", "min": 2.0, "max": 6.0, "step": 1.0, "default": 4.0}
	],
	"heavy_barrier_projector": [
		{"name": "field_width", "label": "Field Width / Area", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrier_capacity", "label": "Absorption Capacity", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0},
		{"name": "projection_distance", "label": "Projection Range (m)", "min": 15.0, "max": 35.0, "step": 1.0, "default": 25.0}
	],
	"bubble_shield_projector": [
		{"name": "barrier_capacity", "label": "Shield Capacity", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0},
		{"name": "bubble_standoff", "label": "Balloon Separation / Standoff", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"capacitor_bank": [
		{"name": "bank_capacity", "label": "Capacitor Cell Count", "min": 2.0, "max": 6.0, "step": 1.0, "default": 4.0},
		{"name": "busbar_gauge", "label": "Busbar Gauge", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"flywheel_storage": [
		{"name": "rotor_mass", "label": "Flywheel Rotor Mass", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "containment_armor", "label": "Containment Armor", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"solid_state_battery": [
		{"name": "cell_layers", "label": "Cell Pack Layers", "min": 2.0, "max": 6.0, "step": 1.0, "default": 4.0},
		{"name": "dielectric_thickness", "label": "Dielectric Density", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"fusion_generator": [
		{"name": "reactor_length", "label": "Reactor Core Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "cooling_radiator", "label": "Cooling Radiator Fins", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"diesel_generator": [
		{"name": "engine_displacement", "label": "Turbine Displacement", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "radiator_fins", "label": "Exhaust & Cooling Louvers", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"thermo_generator": [
		{"name": "core_diameter", "label": "Thermal Core Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "heatsink_fins", "label": "Heat Pipe Runners", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	# Previously documented in Arsenal_Weapons_List.md but missing from this
	# dict entirely - drone_carrier rendered zero tweak sliders in the
	# Design Lab (ENERGY_AND_BALANCE_SPEC.md #3).
	# drone_type is handled by a dedicated RadialAmmoSelector in
	# tweak_callout_manager.gd (see the drone_carrier branch in
	# _generate_custom_tweaks) and must NOT be included here — the
	# parametric loop only handles numeric and bool specs.
	"drone_carrier": [
		{"name": "hangar_size", "label": "Hangar Size (Drone Count)", "min": 1.0, "max": 5.0, "step": 1.0, "default": 2.0},
		{"name": "launch_catapult", "label": "Launch Catapult", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	# Energy weapons (ENERGY_AND_BALANCE_SPEC.md #5)
	"arc_projector": [
		{"name": "containment", "label": "Arc Containment Field", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Emitter Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# dish_aperture is the classic width-vs-reach trade made physical: a
	# bigger dish spreads the cone wider and shortens it, which the player can
	# predict from the model before touching the slider.
	"microwave_emitter": [
		{"name": "dish_aperture", "label": "Dish Aperture", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Horn Length", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# charge_time buys per-shot damage with exposure: a longer wind-up is more
	# time an alert enemy has to kill you before the shot lands. focal_length
	# scales the accelerator spine alone.
	"particle_lance": [
		{"name": "charge_time", "label": "Capacitor Charge", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "focal_length", "label": "Accelerator Length", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
	],
	"ion_cannon": [
		{"name": "lens_aperture", "label": "Ion Focusing Lens", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "barrel_length", "label": "Barrel Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
	],
	# --- Rocket Booster (Support sprint ability) ---
	"booster_rack": [
		{"name": "booster_length", "label": "Booster Length (Duration)", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "booster_width", "label": "Booster Width (Thrust)", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "nozzle_count", "label": "Booster Tubes (Recharge)", "min": 1.0, "max": 4.0, "step": 1.0, "default": 3.0}
	]
}

# Wheels-only "dually" tweak (wheels_per_axle, 1-2): no scene node for this
# exists in UI_StatBlock.tscn (only the generic Size/Count sliders shared by
# every locomotion type), so it's built dynamically here rather than in the
# scene - added as a sibling of SizeContainer/CountContainer inside
# LocomotionTweaks so it reads as part of the same panel instead of a separate
# floating control.
var wheels_per_axle_container: HBoxContainer
var leg_type_container: VBoxContainer
var leg_type_button: OptionButton
var leg_type_desc: Label
var leg_width_container: HBoxContainer
var leg_width_label: Label
var leg_width_slider: HSlider
var wheels_per_axle_label: Label
var wheels_per_axle_slider: HSlider

# "Blade Count" tweak (blade_count, 2-8): same dynamic-widget pattern as
# wheels_per_axle above. Pure per-instance geometry (the ring in
# _build_helicopter_rotors()/_build_pylon_mounted_propeller()), no effect
# on collider or instance count, so it's always routed through
# update_locomotion_geometry_tweak(), never a respawn - same as
# tread_width. Originally helicopter_rotors-only; shared with naval_
# propeller/buoyant_envelope (Chris's ask, 2026-07-24) since all three now
# build a ring of blades the same way.
var blade_count_container: HBoxContainer
var blade_count_label: Label
var blade_count_slider: HSlider

# "Blade Pitch" tweak (blade_pitch, 0.5-1.5): buoyant_envelope originally
# (Chris's ask, 2026-07-24) - same dynamic-widget/geometry-tweak pattern as
# blade_count above. Now also reused (relabelled) by several other types'
# secondary slider - see the elif chain below.
var blade_pitch_container: HBoxContainer
var blade_pitch_label: Label
var blade_pitch_slider: HSlider

# "Helix Depth" tweak (helix_depth, 0.5-1.5): screw_drive only (Chris's
# ask, 2026-07-24) - same dynamic-widget pattern as blade_pitch above.
# Picks among 3 discrete authored drum variants in _build_screw_drive()
# rather than a continuous deformation, but the slider itself is a plain
# continuous 0.5-1.5 control like any other.
var helix_depth_container: HBoxContainer
var helix_depth_label: Label
var helix_depth_slider: HSlider

# helicopter_rotors-only "Ducted Shroud" tweak (duct, bool): same dynamic-
# widget pattern as above. Pure geometry (spawns/removes the duct ring in
# _build_helicopter_rotors()), routed through update_locomotion_geometry_
# tweak() like blade_count, not a respawn.
var duct_container: HBoxContainer
var duct_checkbox: CheckBox
# The checkbox is shared between helicopter_rotors' "Ducted Shroud" and
# pontoon_wheels' "Paddle Vanes" - which tweak key it writes and what its
# callout is titled are set per type in show_module_stats(), the same way the
# Blade Count slider is shared. Hardcoding the key is what silently no-opped
# that slider for two types before.
var bool_tweak_key := "duct"
var bool_tweak_title := "Ducted"

func _ready():
	add_to_group("stat_ui")

	# The Design Lab bed plus a workshop room tone. Deliberately the sparsest
	# track in the game (no kit, no hook, no melody) because the Lab is where a
	# player sits longest on one concentrated task - see tools/audio/tracks/lab.py.
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_music("lab")
		audio.play_ambience("ambience_lab")
	# Captured BEFORE _build_rail_dock() moves the subtree, because this one is
	# used as a parent for dynamically-added rows throughout the file.
	# Resolved here because the rest of _ready() adds rows to it. The dock itself
	# is built at the END of _ready() - see the call there for why the order
	# matters.
	_rail_vbox = $ScrollContainer/VBoxContainer
	lab_toolbar = preload("res://scripts/lab_toolbar.gd").new(self)
	tweak_callout_manager = preload("res://scripts/tweak_callout_manager.gd").new(self)
	
	var parts_menu = get_parent().get_node_or_null("UI_PartsMenu")
	if parts_menu:
		parts_menu.part_hovered.connect(_on_part_hovered)
		parts_menu.part_unhovered.connect(_on_part_unhovered)

	# Theme variations rather than four hand-picked fill colors.
	#
	# These used to be a saturated red, green, blue and purple slab stacked
	# in a column, which spent the loudest colors on screen on four buttons
	# that are not urgent, and left nothing to escalate to when something
	# actually goes wrong. It also meant the Design Lab's palette existed
	# nowhere else in the game.
	#
	# Now: Delete is the only destructive action here, so it is the only one
	# carrying alert red. Save is the commit action, so it takes the single
	# go-green. Test and Library are ordinary navigation and stay neutral -
	# they are reachable, not important.
	# The four blocks that used to sit here built a "plastic model kit sprue gate"
	# StyleBoxFlat per button - a green Save, an amber Test, a CYAN Library and a
	# red Delete, each with its own hover variant and font colour. They are gone,
	# and the paragraph above is now true instead of aspirational: the comment
	# already described theme variations as the intent while the code below it did
	# the exact opposite, so the design system could not reach the four loudest
	# controls in the Design Lab.
	#
	# Where the four states live now:
	#   Delete  -> DangerButton  (FIBERGLASS hazard placard) - set in the .tscn
	#   Save    -> PrimaryButton (CARBON, cast toward go-green) - set in the .tscn
	#   Test    -> plain Button  (MOULDED). Reclassified: it was marked
	#              DangerButton in UI_StatBlock.tscn, but running a test is not
	#              destructive, and spending alert red on it left nothing to
	#              escalate to. It is navigation.
	#   Library -> plain Button  (MOULDED). Its cyan appears nowhere in
	#              ui_tokens.gd; it was the last survivor of the old sci-fi accent.
	save_button.text = "SAVE BLUEPRINT"
	test_button.text = "PROVING GROUND"
	test_button.theme_type_variation = ""
	library_button.text = "BLUEPRINT LIBRARY"
	delete_button.text = "DISCARD PART"

	lab_toolbar._build_mirror_icon()
	mirror_checkbox.toggled.connect(_on_mirror_toggled)
	delete_button.pressed.connect(_on_delete_pressed)
	save_button.pressed.connect(_on_save_pressed)
	test_button.pressed.connect(_on_test_pressed)
	library_button.pressed.connect(_on_library_pressed)
	blueprint_name_edit.text_changed.connect(_on_blueprint_name_changed)
	lab_toolbar._setup_name_roller()
	
	size_slider.value_changed.connect(_on_size_value_changed)
	size_slider.custom_minimum_size = Vector2(180, 0)
	count_slider.value_changed.connect(_on_count_value_changed)
	count_slider.custom_minimum_size = Vector2(180, 0)
	# Size never changes how many module instances exist for ANY locomotion
	# type (only Count does) - it's a purely cosmetic per-instance geometry
	# tweak, so it's routed through update_locomotion_geometry_tweak() (an
	# in-place mesh rebuild on every existing instance, same idea as a
	# weapon's rebuild_visual - see that function in module_placer.gd) on
	# EVERY value_changed tick, live and smooth, no debounce needed. Count IS
	# structural (adds/removes instances), so it still goes through the full
	# update_locomotion() respawn - but debounced to drag-END: applying that
	# full respawn on every tick during a drag reselects an arbitrary
	# instance each time, which relocates the floating popup (it tracks the
	# selected module's 3D->2D screen position every frame) and made a real
	# mouse drag land on the wrong final slider position relative to where
	# the panel had jumped to mid-drag - confirmed via a real simulated-
	# mouse-drag test, not just a direct function call.
	size_slider.drag_started.connect(_push_undo)
	count_slider.drag_started.connect(_on_loco_drag_started)
	count_slider.drag_ended.connect(_on_loco_drag_ended)

	# Dynamically build the wheels-only "Wheels Per Axle" slider (dually
	# tweak) and insert it right after CountContainer inside LocomotionTweaks.
	wheels_per_axle_container = HBoxContainer.new()
	wheels_per_axle_container.custom_minimum_size = Vector2(0, 24)
	wheels_per_axle_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(wheels_per_axle_container)
	locomotion_tweaks.move_child(wheels_per_axle_container, count_container.get_index() + 1)

	wheels_per_axle_label = Label.new()
	wheels_per_axle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wheels_per_axle_label.text = "Wheels Per Axle:"
	wheels_per_axle_container.add_child(wheels_per_axle_label)

	wheels_per_axle_slider = HSlider.new()
	wheels_per_axle_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wheels_per_axle_slider.size_flags_stretch_ratio = 2.0
	wheels_per_axle_slider.min_value = 1.0
	wheels_per_axle_slider.max_value = 2.0
	wheels_per_axle_slider.step = 1.0
	wheels_per_axle_slider.value = 1.0
	wheels_per_axle_slider.custom_minimum_size = Vector2(180, 0)
	wheels_per_axle_container.add_child(wheels_per_axle_slider)
	wheels_per_axle_slider.value_changed.connect(_on_wheels_per_axle_changed)
	wheels_per_axle_slider.drag_started.connect(_push_undo)
	wheels_per_axle_container.visible = false

	# Dynamically build the helicopter_rotors-only "Blade Count" slider.
	blade_count_container = HBoxContainer.new()
	blade_count_container.custom_minimum_size = Vector2(0, 24)
	blade_count_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(blade_count_container)
	locomotion_tweaks.move_child(blade_count_container, wheels_per_axle_container.get_index() + 1)

	blade_count_label = Label.new()
	blade_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blade_count_label.text = "Blade Count:"
	blade_count_container.add_child(blade_count_label)

	blade_count_slider = HSlider.new()
	blade_count_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blade_count_slider.size_flags_stretch_ratio = 2.0
	blade_count_slider.min_value = 2.0
	blade_count_slider.max_value = 8.0
	blade_count_slider.step = 1.0
	blade_count_slider.value = 4.0
	blade_count_slider.custom_minimum_size = Vector2(180, 0)
	blade_count_container.add_child(blade_count_slider)
	blade_count_slider.value_changed.connect(_on_blade_count_changed)
	blade_count_slider.drag_started.connect(_push_undo)
	blade_count_container.visible = false

	# Dynamically build the buoyant_envelope-only "Blade Pitch" slider
	# (Chris's ask, 2026-07-24).
	blade_pitch_container = HBoxContainer.new()
	blade_pitch_container.custom_minimum_size = Vector2(0, 24)
	blade_pitch_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(blade_pitch_container)
	locomotion_tweaks.move_child(blade_pitch_container, blade_count_container.get_index() + 1)

	blade_pitch_label = Label.new()
	blade_pitch_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blade_pitch_label.text = "Blade Pitch:"
	blade_pitch_container.add_child(blade_pitch_label)

	blade_pitch_slider = HSlider.new()
	blade_pitch_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blade_pitch_slider.size_flags_stretch_ratio = 2.0
	blade_pitch_slider.min_value = 0.5
	blade_pitch_slider.max_value = 1.5
	blade_pitch_slider.step = 0.1
	blade_pitch_slider.value = 1.0
	blade_pitch_slider.custom_minimum_size = Vector2(180, 0)
	blade_pitch_container.add_child(blade_pitch_slider)
	blade_pitch_slider.value_changed.connect(_on_blade_pitch_changed)
	blade_pitch_slider.drag_started.connect(_push_undo)
	blade_pitch_container.visible = false

	# Dynamically build the screw_drive-only "Helix Depth" slider.
	helix_depth_container = HBoxContainer.new()
	helix_depth_container.custom_minimum_size = Vector2(0, 24)
	helix_depth_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(helix_depth_container)
	locomotion_tweaks.move_child(helix_depth_container, blade_pitch_container.get_index() + 1)

	helix_depth_label = Label.new()
	helix_depth_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	helix_depth_label.text = "Helix Depth:"
	helix_depth_container.add_child(helix_depth_label)

	helix_depth_slider = HSlider.new()
	helix_depth_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	helix_depth_slider.size_flags_stretch_ratio = 2.0
	helix_depth_slider.min_value = 0.5
	helix_depth_slider.max_value = 1.5
	helix_depth_slider.step = 0.1
	helix_depth_slider.value = 1.0
	helix_depth_slider.custom_minimum_size = Vector2(180, 0)
	helix_depth_container.add_child(helix_depth_slider)
	helix_depth_slider.value_changed.connect(_on_helix_depth_changed)
	helix_depth_slider.drag_started.connect(_push_undo)
	helix_depth_container.visible = false

	# Dynamically build the helicopter_rotors-only "Ducted Shroud" checkbox.
	duct_container = HBoxContainer.new()
	duct_container.custom_minimum_size = Vector2(0, 24)
	duct_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(duct_container)
	locomotion_tweaks.move_child(duct_container, helix_depth_container.get_index() + 1)

	duct_checkbox = CheckBox.new()
	duct_checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duct_container.add_child(duct_checkbox)
	duct_checkbox.toggled.connect(_on_duct_toggled)
	duct_container.visible = false

	# The legs-only "Leg Width" slider. Its partner, Leg Length, rides the shared
	# Size slider via LOCOMOTION_SIZE_KEY; width needs its own because a type can
	# only claim one entry there.
	leg_width_container = HBoxContainer.new()
	leg_width_container.custom_minimum_size = Vector2(0, 24)
	leg_width_container.add_theme_constant_override("separation", 4)
	locomotion_tweaks.add_child(leg_width_container)
	locomotion_tweaks.move_child(leg_width_container, duct_container.get_index() + 1)

	leg_width_label = Label.new()
	leg_width_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leg_width_label.text = "Leg Width:"
	leg_width_container.add_child(leg_width_label)

	leg_width_slider = HSlider.new()
	leg_width_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leg_width_slider.size_flags_stretch_ratio = 2.0
	leg_width_slider.min_value = 0.5
	leg_width_slider.max_value = 2.0
	leg_width_slider.step = 0.05
	leg_width_slider.value = 1.0
	leg_width_slider.custom_minimum_size = Vector2(180, 0)
	leg_width_container.add_child(leg_width_slider)
	leg_width_slider.value_changed.connect(_on_leg_width_changed)
	leg_width_slider.drag_started.connect(_push_undo)
	leg_width_container.visible = false

	# The legs-only "Leg Set" picker. A dropdown plus a description line, which
	# is the same two-control shape the weapon ammo selector uses (see
	# _generate_custom_tweaks) - and deliberately so, because it is the same
	# kind of choice: one named variant out of a short list, changing real
	# stats, rather than a number to drag.
	leg_type_container = VBoxContainer.new()
	leg_type_container.add_theme_constant_override("separation", 2)
	locomotion_tweaks.add_child(leg_type_container)
	locomotion_tweaks.move_child(leg_type_container, duct_container.get_index() + 1)

	var leg_type_caption = Label.new()
	leg_type_caption.text = "Leg Set:"
	leg_type_container.add_child(leg_type_caption)

	leg_type_button = OptionButton.new()
	leg_type_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for leg_id in ModuleCatalog.get_leg_options():
		leg_type_button.add_item(ModuleCatalog.get_leg_profile(leg_id).label)
	leg_type_container.add_child(leg_type_button)

	leg_type_desc = Label.new()
	leg_type_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	leg_type_desc.custom_minimum_size.x = 220
	leg_type_desc.add_theme_font_size_override("font_size", 11)
	leg_type_desc.modulate = Color(1, 1, 1, 0.65)
	leg_type_container.add_child(leg_type_desc)

	leg_type_button.item_selected.connect(_on_leg_type_selected)
	leg_type_container.visible = false

	# Create Module Tweaks container
	module_tweaks_container = VBoxContainer.new()
	module_tweaks_container.name = "ModuleTweaksContainer"
	module_tweaks_container.add_theme_constant_override("separation", 8)
	_rail_vbox.add_child(module_tweaks_container)
	
	# Remove popup_panel and use tweak_canvas instead for infographic UI
	tweak_canvas = Control.new()
	tweak_canvas.name = "TweakCanvas"
	tweak_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tweak_canvas)
	
	# We still need popup_tweaks_container as a stash for persistent locomotion containers
	# when they aren't assigned to a TweakCallout.
	popup_tweaks_container = VBoxContainer.new()
	popup_tweaks_container.visible = false
	add_child(popup_tweaks_container)
	
	popup_name_label = Label.new()
	popup_name_label.text = "Module Customization"
	popup_name_label.add_theme_font_size_override("font_size", 16)
	popup_name_label.add_theme_color_override("font_color", Color.GOLD)
	popup_tweaks_container.add_child(popup_name_label)
	
	popup_stats_label = Label.new()
	popup_stats_label.text = ""
	popup_stats_label.add_theme_font_size_override("font_size", 12)
	popup_tweaks_container.add_child(popup_stats_label)
	
	popup_rotate_btn = Button.new()
	popup_rotate_btn.text = "Rotate 90° [R]"
	popup_rotate_btn.add_theme_font_size_override("font_size", 12)
	popup_rotate_btn.pressed.connect(func():
		var root = get_node_or_null("/root/MainLab")
		# NOTE: module_placer.gd is the script on the MainLab ROOT node, not a
		# child called "ModulePlacer" - check scenes/MainLab.tscn, where it is
		# ext_resource "1_placer" on the root. Three call sites here looked up a
		# child by that name, got null, and silently did nothing; the Rotate
		# button in the Design Lab has never worked. _on_delete_pressed() had it
		# right all along, calling root.delete_selected_module() directly.
		if root and root.has_method("rotate_selected_module"):
			root.rotate_selected_module()
	)
	popup_tweaks_container.add_child(popup_rotate_btn)
	
	# Undo/Redo used to be a two-button row stacked in this rail. Design_Lab_UI_UX
	# .md always specified them as a TOP-BAR pair, and VISUAL/UI plan item 7 says
	# the same thing ("Undo/redo belong on a toolbar, not stacked in a stat
	# column"), so they are built in _build_toolbar() now. Their behaviour is
	# unchanged and still mirrors the Ctrl+Z / Ctrl+Y bindings in module_placer.gd.

	# Navigation back to the main menu - captured in a holder, reparented into
	# the top toolbar by _build_toolbar(). It belongs with the document actions
	# (the rest of which moved into the DOCUMENT toolbox body), and it does not
	# belong stacked under the stat readouts - that was the old "everything
	# in the rail" pattern the new layout explicitly replaced.
	var menu_btn = Button.new()
	menu_btn.name = "MainMenuButton"
	menu_btn.text = "Main Menu"
	menu_btn.pressed.connect(lab_toolbar._return_to_menu)
	_rail_vbox.add_child(menu_btn)

	# Locomotion tweaks (Size/Count/Wheels-Per-Axle) move into the same
	# floating popup weapon/armor tweaks use, instead of living in the
	# right-hand sidebar - Chris's ask, "mirroring the weapon module
	# behavior" so every module type's tweaks appear in one consistent
	# place near the selected module. These are reused/reparented (not
	# rebuilt) each selection since on_module_selected()'s popup-clearing
	# sweep below explicitly skips them - see that guard.
	#
	# This is the STASH, not the display path - _add_callout() pulls a widget out
	# of here and into a floating callout when its locomotion type is selected,
	# and _clear_callouts() puts it back. A widget missing from this list still
	# works, because _add_callout() reparents whatever it is given; what it loses
	# is a well-defined home between selections.
	size_container.reparent(popup_tweaks_container)
	count_container.reparent(popup_tweaks_container)
	wheels_per_axle_container.reparent(popup_tweaks_container)
	blade_count_container.reparent(popup_tweaks_container)
	duct_container.reparent(popup_tweaks_container)
	leg_type_container.reparent(popup_tweaks_container)
	leg_width_container.reparent(popup_tweaks_container)
	locomotion_tweaks.visible = false

	# LAST, deliberately. _build_toolbar() reparents controls into the bar, and
	# hull_spec_btn is created partway through this function rather than being an
	# @onready node - building the dock any earlier caught it as null and silently
	# left the flyout trigger stranded in the rail with no error.
	_build_stats_dock()

	# Initial sync of armor UI
	call_deferred("_initial_sync")

const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")

func sync_hull_ui(hull: Node3D):
	if not hull:
		if blueprint_name_edit:
			lab_toolbar._reroll_name_suggestion(true)
		return
	is_updating_sliders = true
	if blueprint_name_edit:
		var bp_name = str(hull.get_meta("blueprint_name", "")).strip_edges()
		if BlueprintManagerScript.is_named(bp_name):
			blueprint_name_edit.text = bp_name
			_update_abbr_label(bp_name)
		else:
			lab_toolbar._reroll_name_suggestion(true)
			hull.set_meta("blueprint_name", blueprint_name_edit.text)
			_update_abbr_label(blueprint_name_edit.text)
	# No faction sync: there is no faction control in the Lab any more. A
	# blueprint saved before this change still carries its "faction" key and
	# still deserializes, it simply has no effect until a match assigns one.
	is_updating_sliders = false
	update_stats(hull)

# One stylebox per load state, built on first use and reused - same idiom as
# skirmish.gd's _power_fill_style(). A ProgressBar fill is a STATE indicator,
# which is the documented exception to "no local styleboxes": there is no
# theme-side way to say "this bar is currently in its bad state", and the
# StyleBoxTexture material plates carry no colour channel to vary.
var _load_fill_styles: Dictionary = {}


var _alpha_rows: Array[Label] = []


# Opens the action ring on `module`.
#
# The ring carries the DISCRETE, mutually-exclusive verbs - rotate, mirror,
# discard - while the callouts carry the CONTINUOUS tweaks. That split is the
# whole reason there are two mechanisms rather than one: a pie slice cannot
# hold a slider, and a sidebar row is a bad place for a verb that applies to a
# thing you are looking at somewhere else.
func _create_beveled_box(bg_color: Color = Color(0.09, 0.11, 0.13, 0.95), border_color: Color = Color(0.38, 0.44, 0.48, 0.90), radius: int = 8, pad: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_color = border_color
	sb.set_border_width_all(2)
	sb.border_width_top = 3
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	return sb


func _build_stats_dock() -> void:
	var scroll: Node = get_node_or_null("ScrollContainer")
	if scroll == null:
		push_error("stat_calculator: no ScrollContainer to dock")
		return

	# Sliding Alert Placard 1: Overweight / Over Capacity Warning
	overweight_alert_placard = PanelContainer.new()
	overweight_alert_placard.name = "OverweightAlertPlacard"
	overweight_alert_placard.anchor_left = 0.5
	overweight_alert_placard.anchor_top = 1.0
	overweight_alert_placard.anchor_right = 0.5
	overweight_alert_placard.anchor_bottom = 1.0
	overweight_alert_placard.offset_left = -255.0
	overweight_alert_placard.offset_right = 45.0
	overweight_alert_placard.offset_top = -248.0
	overweight_alert_placard.offset_bottom = -164.0
	var over_style = _create_beveled_box(Color(0.14, 0.07, 0.07, 0.98), Color(0.92, 0.28, 0.22, 0.95), 4, 6)
	overweight_alert_placard.add_theme_stylebox_override("panel", over_style)
	add_child(overweight_alert_placard)

	var ov_vbox := VBoxContainer.new()
	ov_vbox.add_theme_constant_override("separation", 2)
	overweight_alert_placard.add_child(ov_vbox)

	var ov_tab := Label.new()
	ov_tab.text = "▲ ⚠️ DRIVE OVERLOAD"
	ov_tab.theme_type_variation = "StatLabel"
	ov_tab.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4, 1.0))
	ov_vbox.add_child(ov_tab)

	overweight_text_label = Label.new()
	overweight_text_label.theme_type_variation = "HeadingLabel"
	overweight_text_label.text = "OVERLOAD: 0 / 0 kg"
	overweight_text_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.9, 1.0))
	ov_vbox.add_child(overweight_text_label)

	overweight_detail_label = Label.new()
	overweight_detail_label.theme_type_variation = "HintLabel"
	overweight_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overweight_detail_label.text = "Speed cut by 0.0 m/s (Chassis Overloaded)"
	ov_vbox.add_child(overweight_detail_label)

	# Sliding Alert Placard 2: Power Deficit / Low Power Warning
	power_alert_placard = PanelContainer.new()
	power_alert_placard.name = "PowerAlertPlacard"
	power_alert_placard.anchor_left = 0.5
	power_alert_placard.anchor_top = 1.0
	power_alert_placard.anchor_right = 0.5
	power_alert_placard.anchor_bottom = 1.0
	power_alert_placard.offset_left = 55.0
	power_alert_placard.offset_right = 335.0
	power_alert_placard.offset_top = -248.0
	power_alert_placard.offset_bottom = -164.0
	var pwr_style = _create_beveled_box(Color(0.14, 0.11, 0.06, 0.98), Color(0.96, 0.68, 0.18, 0.95), 4, 6)
	power_alert_placard.add_theme_stylebox_override("panel", pwr_style)
	add_child(power_alert_placard)

	var pw_vbox := VBoxContainer.new()
	pw_vbox.add_theme_constant_override("separation", 2)
	power_alert_placard.add_child(pw_vbox)

	var pw_tab := Label.new()
	pw_tab.text = "▲ ⚡ POWER DEFICIT"
	pw_tab.theme_type_variation = "StatLabel"
	pw_tab.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2, 1.0))
	pw_vbox.add_child(pw_tab)

	power_text_label = Label.new()
	power_text_label.theme_type_variation = "HeadingLabel"
	power_text_label.text = "POWER: 0 / 0 kW"
	power_text_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8, 1.0))
	pw_vbox.add_child(power_text_label)

	power_detail_label = Label.new()
	power_detail_label.theme_type_variation = "HintLabel"
	power_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	power_detail_label.text = "Energy systems offline / brownout"
	pw_vbox.add_child(power_detail_label)

	# Sliding Alert Placard 3: Vision / Spotter Warning
	vision_alert_placard = PanelContainer.new()
	vision_alert_placard.name = "VisionAlertPlacard"
	vision_alert_placard.anchor_left = 0.5
	vision_alert_placard.anchor_top = 1.0
	vision_alert_placard.anchor_right = 0.5
	vision_alert_placard.anchor_bottom = 1.0
	vision_alert_placard.offset_left = 345.0
	vision_alert_placard.offset_right = 625.0
	vision_alert_placard.offset_top = -248.0
	vision_alert_placard.offset_bottom = -164.0
	var vis_style = _create_beveled_box(Color(0.09, 0.11, 0.14, 0.98), Color(0.38, 0.56, 0.72, 0.95), 4, 6)
	vision_alert_placard.add_theme_stylebox_override("panel", vis_style)
	add_child(vision_alert_placard)

	var vs_vbox := VBoxContainer.new()
	vs_vbox.add_theme_constant_override("separation", 2)
	vision_alert_placard.add_child(vs_vbox)

	var vs_tab := Label.new()
	vs_tab.text = "▲ 👁️ OUT-REACHES ITS OWN VISION"
	vs_tab.theme_type_variation = "StatLabel"
	vs_tab.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95, 1.0))
	vs_vbox.add_child(vs_tab)

	vision_text_label = Label.new()
	vision_text_label.theme_type_variation = "HeadingLabel"
	vision_text_label.text = "VISION: 0 m | REACH: 0 m"
	vision_text_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 1.0))
	vs_vbox.add_child(vision_text_label)

	vision_detail_label = Label.new()
	vision_detail_label.theme_type_variation = "HintLabel"
	vision_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vision_detail_label.text = "Every weapon's reach fits inside this design's own vision."
	vs_vbox.add_child(vision_detail_label)

	# Bottom-edge document: a latched handle and focused pages.
	console_root = PanelContainer.new()
	console_root.name = "DesignCockpitConsole"
	console_root.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	console_root.mouse_filter = Control.MOUSE_FILTER_STOP
	console_root.add_theme_stylebox_override("panel", SliceTheme.panel_style("surface"))
	add_child(console_root)
	var document_column := VBoxContainer.new()
	document_column.add_theme_constant_override("separation", Tokens.SPACE_XS)
	console_root.add_child(document_column)
	var handle_row := HBoxContainer.new()
	document_column.add_child(handle_row)
	_document_toggle = SliceShell.action(handle_row, "Design document  /  Hide", "secondary")
	_document_toggle.name = "DocumentToggle"
	_document_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_document_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_document_toggle.pressed.connect(func(): set_document_expanded(not _document_expanded))
	_document_tabs = SliceShell.navigation_spine(document_column, [
		{"id": "Design", "label": "Design"},
		{"id": "Performance", "label": "Performance"},
		{"id": "Build", "label": "Build"},
		{"id": "Selected", "label": "Selected part"},
	], "Performance", _select_document_page)
	# navigation_spine's initial destination is intentionally static for scene
	# navigation. Document pages change in place, so route each press from the
	# button's current destination instead of that initial value.
	for tab: Button in _document_tabs.get_children():
		tab.pressed.connect(_on_document_tab_pressed.bind(tab))
	_document_body = ScrollContainer.new()
	_document_body.name = "DocumentPages"
	_document_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_document_body.follow_focus = true
	_document_body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	document_column.add_child(_document_body)
	var hbox := HBoxContainer.new()
	hbox.name = "ConsoleHBox"
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_document_body.add_child(hbox)
	var cluster_style := SliceTheme.panel_style("inset")

	# =========================================================================
	# CLUSTER 1: NAME AND SAVE / LOAD GROUP (Width: 245px)
	# =========================================================================
	var c1 := PanelContainer.new()
	c1.name = "NameAndOperationsCluster"
	c1.custom_minimum_size = Vector2(245, 0)
	c1.add_theme_stylebox_override("panel", cluster_style.duplicate())
	hbox.add_child(c1)

	var c1_vbox := VBoxContainer.new()
	c1_vbox.add_theme_constant_override("separation", 3)
	c1.add_child(c1_vbox)

	var c1_title := Label.new()
	c1_title.text = "DESIGN & OPERATIONS"
	c1_title.theme_type_variation = "HeadingLabel"
	c1_title.add_theme_color_override("font_color", Color(0.92, 0.76, 0.45, 1.0))
	c1_vbox.add_child(c1_title)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	c1_vbox.add_child(name_row)

	if blueprint_name_edit:
		blueprint_name_edit.reparent(name_row)
		blueprint_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		blueprint_name_edit.custom_minimum_size = Vector2(150, 24)
		blueprint_name_edit.expand_to_text_length = false
		blueprint_name_edit.tooltip_text = blueprint_name_edit.text
		if not blueprint_name_edit.text_changed.is_connected(_on_blueprint_name_tooltip_update):
			blueprint_name_edit.text_changed.connect(_on_blueprint_name_tooltip_update)

	var roll_btn := Button.new()
	roll_btn.text = "🎲"
	roll_btn.tooltip_text = "Generate New Designation"
	roll_btn.custom_minimum_size = Vector2(28, 24)
	UIFeedbackScript.wire(roll_btn)
	roll_btn.pressed.connect(func(): lab_toolbar._reroll_name_suggestion())
	name_row.add_child(roll_btn)

	var abbr_label := Label.new()
	abbr_label.name = "BlueprintAbbrLabel"
	abbr_label.theme_type_variation = "HintLabel"
	abbr_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85, 0.85))
	c1_vbox.add_child(abbr_label)
	_update_abbr_label(blueprint_name_edit.text if blueprint_name_edit else "")

	var old_name_row := _rail_vbox.get_node_or_null("BlueprintNameRow")
	if old_name_row:
		old_name_row.visible = false

	# Save / Load Button Pair
	var save_load_row := HBoxContainer.new()
	save_load_row.add_theme_constant_override("separation", 4)
	c1_vbox.add_child(save_load_row)

	if save_button:
		save_button.reparent(save_load_row)
		save_button.text = "SAVE"
		save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		save_button.custom_minimum_size = Vector2(0, 24)
		save_button.theme_type_variation = "PrimaryButton"
		UIFeedbackScript.wire(save_button)

	if library_button:
		library_button.reparent(save_load_row)
		library_button.text = "LOAD"
		library_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		library_button.custom_minimum_size = Vector2(0, 24)
		UIFeedbackScript.wire(library_button)

	if test_button:
		test_button.reparent(c1_vbox)
		test_button.text = "PROVING GROUND"
		test_button.custom_minimum_size = Vector2(0, 22)
		UIFeedbackScript.wire(test_button)

	if mirror_checkbox:
		mirror_checkbox.reparent(c1_vbox)
		mirror_checkbox.text = "Mirror [M]"

	# =========================================================================
	# CLUSTER 2: COMBAT & POWER GROUP (Stamped Steel Gauge Cluster, Width: 290px)
	# =========================================================================
	var c2 := PanelContainer.new()
	c2.name = "CombatGaugeCluster"
	c2.custom_minimum_size = Vector2(290, 0)
	c2.add_theme_stylebox_override("panel", cluster_style.duplicate())
	hbox.add_child(c2)

	var c2_vbox := VBoxContainer.new()
	c2_vbox.add_theme_constant_override("separation", 2)
	c2.add_child(c2_vbox)

	var c2_title := Label.new()
	c2_title.text = "TACTICAL & COMBAT SPEC"
	c2_title.theme_type_variation = "HeadingLabel"
	c2_title.add_theme_color_override("font_color", Color(0.92, 0.76, 0.45, 1.0))
	c2_vbox.add_child(c2_title)

	# Main 2x2 Big Gauge Grid
	var main_grid := GridContainer.new()
	main_grid.columns = 2
	main_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_grid.add_theme_constant_override("h_separation", 12)
	main_grid.add_theme_constant_override("v_separation", 2)
	c2_vbox.add_child(main_grid)

	combat_hp_label = Label.new()
	combat_hp_label.theme_type_variation = "HeadingLabel"
	combat_hp_label.text = "HP: 0"
	main_grid.add_child(combat_hp_label)

	combat_dps_label = Label.new()
	combat_dps_label.theme_type_variation = "HeadingLabel"
	combat_dps_label.text = "DPS: 0.0"
	main_grid.add_child(combat_dps_label)

	combat_speed_label = Label.new()
	combat_speed_label.theme_type_variation = "HeadingLabel"
	combat_speed_label.text = "Speed: 0.0 km/h"
	main_grid.add_child(combat_speed_label)

	combat_range_label = Label.new()
	combat_range_label.theme_type_variation = "HeadingLabel"
	combat_range_label.text = "Range: 0 m"
	main_grid.add_child(combat_range_label)

	# Power stats readout (Generation, Storage, Draw)
	combat_power_label = Label.new()
	combat_power_label.theme_type_variation = "StatLabel"
	combat_power_label.text = "⚡ Gen: 0.0 kW | Stor: 0 kJ | Draw: 0.0 kW"
	combat_power_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55, 1.0))
	c2_vbox.add_child(combat_power_label)

	c2_vbox.add_child(HSeparator.new())

	# Detail Data Sub-labels
	combat_weight_label = Label.new()
	combat_weight_label.theme_type_variation = "StatLabel"
	combat_weight_label.text = "Mass: 0.0 / 0.0 kg"
	c2_vbox.add_child(combat_weight_label)

	var sub_row := HBoxContainer.new()
	sub_row.add_theme_constant_override("separation", 8)
	c2_vbox.add_child(sub_row)

	combat_role_label = Label.new()
	combat_role_label.theme_type_variation = "StatLabel"
	combat_role_label.text = "Role: Direct Fire"
	combat_role_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_row.add_child(combat_role_label)

	combat_parts_label = Label.new()
	combat_parts_label.theme_type_variation = "StatLabel"
	combat_parts_label.text = "Modules: 0 Mounted"
	sub_row.add_child(combat_parts_label)

	# Armor resistance readout (material + per-damage-type %, mirrors telemetry_rail.gd)
	combat_armor_label = Label.new()
	combat_armor_label.theme_type_variation = "StatLabel"
	combat_armor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	combat_armor_label.text = "Plating: Hardened Steel [K:0% T:0% X:0% E:0%]"
	c2_vbox.add_child(combat_armor_label)

	# Cargo capacity - only meaningful (and only shown) on a design that
	# actually mounts a resource_harvester; see update_stats_display()'s
	# is_harv branch for the show/hide toggle.
	combat_cargo_label = Label.new()
	combat_cargo_label.theme_type_variation = "StatLabel"
	combat_cargo_label.text = "Cargo Capacity: 0"
	combat_cargo_label.visible = false
	c2_vbox.add_child(combat_cargo_label)

	# =========================================================================
	# CLUSTER 3: BUILD GROUP (Width: 210px)
	# =========================================================================
	var c3 := PanelContainer.new()
	c3.name = "BuildCluster"
	c3.custom_minimum_size = Vector2(210, 0)
	c3.add_theme_stylebox_override("panel", cluster_style.duplicate())
	hbox.add_child(c3)

	var c3_vbox := VBoxContainer.new()
	c3_vbox.add_theme_constant_override("separation", 2)
	c3.add_child(c3_vbox)

	var c3_title := Label.new()
	c3_title.text = "MANUFACTURING SPEC"
	c3_title.theme_type_variation = "HeadingLabel"
	c3_title.add_theme_color_override("font_color", Color(0.92, 0.76, 0.45, 1.0))
	c3_vbox.add_child(c3_title)

	build_cost_label = Label.new()
	build_cost_label.theme_type_variation = "HeadingLabel"
	build_cost_label.text = "0 CREDITS"
	build_cost_label.add_theme_font_size_override("font_size", 16)
	c3_vbox.add_child(build_cost_label)

	build_materials_label = Label.new()
	build_materials_label.theme_type_variation = "StatLabel"
	build_materials_label.text = "0 Metal / 0 Crystal"
	c3_vbox.add_child(build_materials_label)

	# Factory Pane with Glyph
	var factory_pane := PanelContainer.new()
	var pane_style := StyleBoxFlat.new()
	pane_style.bg_color = Color(0.06, 0.07, 0.08, 0.95)
	pane_style.set_border_width_all(1)
	pane_style.border_color = Color(0.28, 0.32, 0.35, 0.8)
	pane_style.set_content_margin_all(3)
	pane_style.corner_radius_top_left = 4
	pane_style.corner_radius_top_right = 4
	pane_style.corner_radius_bottom_left = 4
	pane_style.corner_radius_bottom_right = 4
	factory_pane.add_theme_stylebox_override("panel", pane_style)
	c3_vbox.add_child(factory_pane)

	var f_hbox := HBoxContainer.new()
	f_hbox.add_theme_constant_override("separation", 6)
	factory_pane.add_child(f_hbox)

	factory_glyph_label = Label.new()
	factory_glyph_label.text = "⚙️"
	factory_glyph_label.add_theme_font_size_override("font_size", 18)
	f_hbox.add_child(factory_glyph_label)

	factory_name_label = Label.new()
	factory_name_label.text = "LIGHT VEHICLE FACTORY"
	factory_name_label.theme_type_variation = "StatLabel"
	factory_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f_hbox.add_child(factory_name_label)

	build_lab_tier_label = Label.new()
	build_lab_tier_label.theme_type_variation = "HintLabel"
	build_lab_tier_label.text = "Tech: Tier 1 Standard"
	c3_vbox.add_child(build_lab_tier_label)

	build_time_label = Label.new()
	build_time_label.theme_type_variation = "HintLabel"
	build_time_label.text = "Build Time: 0.0s"
	c3_vbox.add_child(build_time_label)

	# =========================================================================
	# CLUSTER 4: MODULE INSPECTOR (Width: 270px)
	# =========================================================================
	var c4 := PanelContainer.new()
	c4.name = "ModuleInspectorCluster"
	c4.custom_minimum_size = Vector2(270, 0)
	c4.add_theme_stylebox_override("panel", cluster_style.duplicate())
	hbox.add_child(c4)

	var c4_vbox := VBoxContainer.new()
	c4_vbox.add_theme_constant_override("separation", 2)
	c4.add_child(c4_vbox)

	var c4_title := Label.new()
	c4_title.text = "MODULE INSPECTOR"
	c4_title.theme_type_variation = "HeadingLabel"
	c4_title.add_theme_color_override("font_color", Color(0.92, 0.76, 0.45, 1.0))
	c4_vbox.add_child(c4_title)

	inspector_title_label = Label.new()
	inspector_title_label.theme_type_variation = "HeadingLabel"
	inspector_title_label.text = "NO MODULE SELECTED"
	c4_vbox.add_child(inspector_title_label)

	inspector_subtitle_label = Label.new()
	inspector_subtitle_label.theme_type_variation = "HintLabel"
	inspector_subtitle_label.text = "CHASSIS BASE // CLICK PART TO INSPECT"
	c4_vbox.add_child(inspector_subtitle_label)

	inspector_stats_label = Label.new()
	inspector_stats_label.theme_type_variation = "StatLabel"
	inspector_stats_label.text = "HP: - | Mass: - | DPS: -"
	c4_vbox.add_child(inspector_stats_label)

	var insp_scroll := ScrollContainer.new()
	insp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	insp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	c4_vbox.add_child(insp_scroll)

	inspector_sliders_container = VBoxContainer.new()
	inspector_sliders_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_sliders_container.add_theme_constant_override("separation", 2)
	insp_scroll.add_child(inspector_sliders_container)

	if locomotion_tweaks:
		locomotion_tweaks.reparent(inspector_sliders_container)

	if delete_button:
		delete_button.reparent(c4_vbox)
		delete_button.custom_minimum_size = Vector2(0, 24)
		delete_button.theme_type_variation = "DangerButton"
		delete_button.text = "DISCARD PART [DEL]"
		delete_button.visible = false
		UIFeedbackScript.wire(delete_button)

	# Residual scroll container stays hidden
	scroll.visible = false

	# Keep legacy @onready label references mapped to dummy/real nodes so nothing crashes
	if hp_label and hp_label.get_parent() == null: add_child(hp_label)
	if weight_label and weight_label.get_parent() == null: add_child(weight_label)
	if dps_label and dps_label.get_parent() == null: add_child(dps_label)
	if cost_label and cost_label.get_parent() == null: add_child(cost_label)

	_document_clusters = {"Design": c1, "Performance": c2, "Build": c3, "Selected": c4}
	for cluster: PanelContainer in _document_clusters.values():
		cluster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for button: Button in [save_button, library_button, test_button, delete_button]:
		SliceTheme.apply_action(button, "error" if button == delete_button else ("primary" if button == save_button else "secondary"))
	for readout: Label in [combat_hp_label, combat_dps_label, combat_speed_label, combat_range_label, build_cost_label]:
		readout.theme_type_variation = "HUDValueLabel"
	for label: Label in [inspector_title_label, inspector_subtitle_label, inspector_stats_label, factory_name_label, combat_power_label, combat_weight_label]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = 160
	# Warnings occupy the performance page rather than the model's canvas.
	for warning: PanelContainer in [overweight_alert_placard, power_alert_placard, vision_alert_placard]:
		warning.reparent(c2_vbox)
		warning.set_anchors_preset(Control.PRESET_TOP_LEFT)
		warning.custom_minimum_size = Vector2.ZERO
		warning.add_theme_stylebox_override("panel", SliceTheme.panel_style("inset"))
	lab_toolbar._build_toolbar()
	_build_operation_strip()
	resized.connect(_layout_document)
	_layout_document()
	UIFeedbackScript.wire_tree(self)



# Task 4 screen composition. Geometry remains local to the Lab.
func set_document_expanded(expanded: bool) -> void:
	_document_expanded = expanded
	_document_body.visible = expanded
	_document_tabs.visible = expanded
	_document_toggle.text = "Design document  /  Hide" if expanded else "Design document  /  Show"
	_layout_document()

func _select_document_page(page: String) -> void:
	_document_page = page
	for button: Button in _document_tabs.get_children():
		var selected := button.text == ("Selected part" if page == "Selected" else page)
		button.set_pressed_no_signal(selected)
		SliceTheme.apply_action(button, "active" if selected else "secondary")
	_layout_document()

func _on_document_tab_pressed(tab: Button) -> void:
	var page := str(tab.get_meta(&"destination_id", ""))
	if not page.is_empty() and page != _document_page:
		_select_document_page(page)

func _layout_document() -> void:
	if not is_instance_valid(console_root):
		return
	var viewport_size := get_viewport_rect().size
	console_root.offset_left = 330.0
	console_root.offset_right = -Tokens.SPACE_MD
	console_root.offset_bottom = -Tokens.SPACE_MD
	var height := minf(300.0, viewport_size.y * 0.38) if _document_expanded else 52.0
	console_root.offset_top = -Tokens.SPACE_MD - height
	var wide := viewport_size.x >= 1500.0
	for page: String in _document_clusters:
		_document_clusters[page].visible = page == _document_page or (wide and page == "Design")
	console_root.custom_minimum_size = Vector2.ZERO

func _build_operation_strip() -> void:
	var panel := PanelContainer.new()
	panel.name = "OperationStrip"
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_left = 330
	panel.offset_right = -Tokens.SPACE_MD
	panel.offset_top = Tokens.TOOLBAR_HEIGHT + Tokens.SPACE_SM
	panel.add_theme_stylebox_override("panel", SliceTheme.panel_style("inset"))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)
	var operation_row := HBoxContainer.new()
	operation_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	operation_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(operation_row)
	_operation_icon = TextureRect.new()
	_operation_icon.name = "OperationStateIcon"
	_operation_icon.texture = SliceTheme.industrial_icon("drop_target")
	_operation_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_operation_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_operation_icon.custom_minimum_size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
	_operation_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	operation_row.add_child(_operation_icon)
	_operation_label = Label.new()
	_operation_label.name = "OperationStatus"
	_operation_label.text = "ASSEMBLE  /  Drag a part from the parts bin onto a hull face"
	_operation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_operation_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_operation_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	operation_row.add_child(_operation_label)
	_assembly_health_label = Label.new()
	_assembly_health_label.name = "AssemblyHealthIndicator"
	_assembly_health_label.theme_type_variation = "HintLabel"
	_assembly_health_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_assembly_health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_assembly_health_label.add_theme_color_override("font_color", Tokens.SIGNAL_ALERT)
	_assembly_health_label.visible = false
	column.add_child(_assembly_health_label)
	var gestures := Label.new()
	gestures.text = "Right-drag: orbit   ·   Middle-drag: pan   ·   Wheel: zoom   ·   Click a part: tune"
	gestures.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gestures.theme_type_variation = "HintLabel"
	gestures.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(gestures)
	var placer := get_parent()
	placer.placement_feedback.connect(_show_placement_feedback)

func _show_placement_feedback(message: String, rejected: bool) -> void:
	_operation_label.text = ("CANNOT FIT  /  " if rejected else "FITTED  /  ") + message
	_operation_label.add_theme_color_override("font_color", Tokens.SIGNAL_ALERT if rejected else Tokens.TEXT_PRIMARY)
	_set_operation_icon("state_invalid" if rejected else "state_ready", Tokens.SIGNAL_ALERT if rejected else Tokens.TEXT_PRIMARY)


func _set_operation_icon(key: String, tint: Color) -> void:
	if _operation_icon == null:
		return
	var texture := SliceTheme.industrial_icon(key)
	if texture != null:
		_operation_icon.texture = texture
		_operation_icon.modulate = tint

func update_stats_display(stats: Dictionary, hull: Node3D) -> void:
	if stats.is_empty():
		return

	# --- 1. Combat Group ---
	var hp = float(stats.get("hull_hp", 0.0))
	var m_pool = float(stats.get("module_hp_pool", 0.0))
	if combat_hp_label:
		combat_hp_label.text = "HP: %.0f (+%.0f)" % [hp, m_pool]

	var dps = float(stats.get("dps", 0.0))
	if combat_dps_label:
		combat_dps_label.text = "DPS: %.1f" % dps

	var dt: Dictionary = stats.get("drivetrain", {})
	var spd = float(dt.get("top_speed", 0.0))
	if combat_speed_label:
		combat_speed_label.text = "Speed: %.1f km/h" % (spd * 3.6)

	var wr: Dictionary = stats.get("weapon_range", {})
	var has_wpn: bool = bool(stats.get("has_weapons", false)) or bool(wr.get("has_weapons", false)) or dps > 0.0
	var longest_rng: float = float(wr.get("longest", stats.get("longest_range", 0.0)))
	var shortest_rng: float = float(wr.get("shortest", stats.get("shortest_range", 0.0)))

	# Fallback if wr had not populated longest but weapons exist on hull
	if has_wpn and longest_rng <= 0.0 and hull:
		for child in hull.get_children():
			if child.has_meta("module_data"):
				var mdata = child.get_meta("module_data")
				if mdata and (mdata.category == "weapon" or mdata.get_dps() > 0.0):
					var b_rng = ModuleCatalog.get_base_range(mdata.type_id)
					longest_rng = maxf(longest_rng, b_rng)
					shortest_rng = b_rng if shortest_rng <= 0.0 else minf(shortest_rng, b_rng)

	if combat_range_label:
		if (has_wpn or dps > 0.0) and longest_rng > 0.0:
			if longest_rng == shortest_rng:
				combat_range_label.text = "Range: %.0f m" % longest_rng
			else:
				combat_range_label.text = "Range: %.0f-%.0f m" % [shortest_rng, longest_rng]
		else:
			combat_range_label.text = "Range: Unarmed"

	# Power stats readout (Generation, Storage, Draw)
	var power: Dictionary = stats.get("power", {})
	var gen: float = float(power.get("generation", 0.0))
	var stor: float = float(power.get("storage", 0.0))
	var idle_draw: float = float(power.get("draw", 0.0))
	var weapon_draw: float = float(power.get("weapon_draw", 0.0))
	var total_draw: float = float(power.get("total_draw", idle_draw + weapon_draw))
	var active_draw: float = total_draw if total_draw > 0.0 else idle_draw

	if combat_power_label:
		combat_power_label.text = "⚡ Gen: %.1f kW | Stor: %.0f kJ | Draw: %.1f kW" % [gen, stor, active_draw]
		if active_draw > 0.0 and gen <= 0.0:
			combat_power_label.add_theme_color_override("font_color", Tokens.SIGNAL_ALERT)
		elif gen > 0.0 and active_draw > gen:
			combat_power_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2, 1.0))
		else:
			combat_power_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55, 1.0))

	var wt = float(stats.get("weight", 0.0))
	var cap = float(dt.get("capacity", 0.0))
	var carried = float(dt.get("carried_weight", 0.0))
	var has_loco = bool(dt.get("has_locomotion", false))
	var is_over = bool(dt.get("is_overloaded", false))
	if not is_over and has_loco and cap > 0.0:
		if carried > cap or wt > cap or (carried / cap) >= 1.0:
			is_over = true

	if combat_weight_label:
		combat_weight_label.text = "Mass: %.1f / %.1f kg" % [wt, cap]
		combat_weight_label.add_theme_color_override("font_color", Tokens.SIGNAL_ALERT if is_over else Tokens.TEXT_PRIMARY)

	var is_harv: bool = bool(stats.get("is_harvester", false))
	if combat_cargo_label:
		combat_cargo_label.visible = is_harv
		if is_harv:
			combat_cargo_label.text = "Cargo Capacity: %d" % int(stats.get("cargo_capacity", 0))

	var role_str := "Direct Fire"
	if is_harv:
		role_str = "Resource Harvester"
	elif not has_wpn and dps <= 0.0:
		role_str = "Unarmed Support / Scout"
	else:
		var tier_label = wr.get("tier_label", "")
		if tier_label.is_empty() and longest_rng > 0.0:
			tier_label = ModuleCatalog.get_range_tier_label(longest_rng)
		if tier_label.is_empty():
			tier_label = "Direct Fire"
		role_str = tier_label

	if combat_role_label:
		combat_role_label.text = "Role: %s" % role_str

	# Armor resistance readout - mirrors telemetry_rail.gd's armor_plan read
	if combat_armor_label:
		var armor_material := "hardened_steel"
		var armor_thickness := 1.0
		if hull:
			var plan: Dictionary = hull.get_meta("armor_plan", {})
			if not plan.is_empty() and not bool(plan.get("empty", true)):
				var sides: Dictionary = plan.get("sides", {})
				var best_mat := ""
				var best_weight := 0.0
				var thick_weighted_sum := 0.0
				var thick_weight_total := 0.0
				for side_key in sides.keys():
					var side_data: Dictionary = sides[side_key]
					var mat = side_data.get("material", "")
					var thick = float(side_data.get("mean_thickness", 0.0))
					var coverage = float(side_data.get("coverage", 0.0))
					var area = float(side_data.get("area", 0.0))
					if coverage <= 0.001 or area <= 0.0 or mat == "":
						continue
					var w = coverage * area
					if w > best_weight:
						best_weight = w
						best_mat = mat
					thick_weighted_sum += w * thick
					thick_weight_total += w
				if best_mat != "":
					armor_material = best_mat
				if thick_weight_total > 0.0:
					armor_thickness = thick_weighted_sum / thick_weight_total
			if armor_material == "hardened_steel" and hull.has_meta("armor_material"):
				armor_material = hull.get_meta("armor_material")
			if armor_thickness == 1.0 and hull.has_meta("armor_thickness"):
				armor_thickness = hull.get_meta("armor_thickness")

		var k_pair = DamageResolverScript.get_material_threshold(armor_material, "kinetic", armor_thickness)
		var t_pair = DamageResolverScript.get_material_threshold(armor_material, "thermal", armor_thickness)
		var x_pair = DamageResolverScript.get_material_threshold(armor_material, "explosive", armor_thickness)
		var e_pair = DamageResolverScript.get_material_threshold(armor_material, "energy", armor_thickness)
		var k_resist = (1.0 - k_pair.y) * 100.0
		var t_resist = (1.0 - t_pair.y) * 100.0
		var x_resist = (1.0 - x_pair.y) * 100.0
		var e_resist = (1.0 - e_pair.y) * 100.0
		combat_armor_label.text = "Plating: %s [K:%.0f%% T:%.0f%% X:%.0f%% E:%.0f%%]" % [
			armor_material.replace("_", " ").capitalize(), k_resist, t_resist, x_resist, e_resist]

	# --- Drive Sliding Overweight Placard ---
	if overweight_alert_placard:
		var lost_spd = float(dt.get("speed_lost_to_overload", 0.0))
		if overweight_text_label:
			overweight_text_label.text = "OVERLOAD: %.0f / %.0f kg" % [carried if carried > 0 else wt, cap]
		if overweight_detail_label:
			overweight_detail_label.text = "-%.1f m/s Speed Penalty (Chassis Overloaded)" % lost_spd if lost_spd > 0 else "Chassis capacity exceeded"


		# Ghost opacity when condition is false
		overweight_alert_placard.visible = is_over
		if is_over:
			overweight_alert_placard.modulate = Color(1, 1, 1, 1)
		else:
			overweight_alert_placard.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)

	# --- Drive Sliding Power Deficit Placard ---
	var is_power_alert = (active_draw > 0.0 and gen <= 0.0) or (gen > 0.0 and active_draw > gen)

	if power_alert_placard:
		if power_text_label:
			if active_draw > 0.0 and gen <= 0.0:
				power_text_label.text = "UNPOWERED: Draw %.1f kW (0 Gen)" % active_draw
			else:
				power_text_label.text = "DEFICIT: Draw %.1f / Gen %.1f kW" % [active_draw, gen]
		if power_detail_label:
			var storage = float(power.get("storage", 0.0))
			var max_shot_cost = float(power.get("max_shot_cost", 0.0))
			var has_deficit = bool(power.get("has_deficit", false))
			var firing_deficit_only = bool(power.get("firing_deficit_only", false))
			var firing_net = float(power.get("firing_net", 0.0))
			var firing_endurance = float(power.get("firing_endurance", 0.0))
			var endurance = float(power.get("endurance", 0.0))

			if max_shot_cost > storage:
				power_detail_label.text = "A weapon needs %.1f energy to fire, but capacity is only %.1f. It will never fire." % [max_shot_cost, storage]
			elif has_deficit:
				power_detail_label.text = "A full buffer lasts %.0fs at rest." % endurance
				if firing_endurance != endurance and firing_endurance != INF:
					power_detail_label.text += " Sustained fire: %.0fs." % firing_endurance
				power_detail_label.text += " Shields drop first, then sensors dim, then energy weapons stop. Buildable and fieldable as-is - fit a generator, add storage to ride it out, or drop some electronics."
			elif firing_deficit_only:
				var burst_shots = int(storage / maxf(max_shot_cost, 1.0))
				power_detail_label.text = "~%d shots burst (floor(storage / max_shot_cost)), %.0fs sustained fire. Capacitors buy burst; a generator buys sustain." % [burst_shots, firing_endurance]
			else:
				power_detail_label.text = "Energy systems offline - fit generator" if (active_draw > 0.0 and gen <= 0.0) else "Shortfall by %.1f kW (Brownout risk)" % (active_draw - gen)


		# Ghost opacity when condition is false
		power_alert_placard.visible = is_power_alert
		if is_power_alert:
			power_alert_placard.modulate = Color(1, 1, 1, 1)
		else:
			power_alert_placard.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)

	# --- Vision / Spotter Sliding Placard ---
	# wr, has_wpn, longest_rng already declared above
	var vision = float(wr.get("vision", 0.0))
	var longest = float(wr.get("longest", 0.0))
	var required = wr.get("spotter_required", [])
	var assisted = wr.get("spotter_assisted", [])
	var has_weapons = has_wpn
	var is_vision_alert = has_weapons and (required.size() > 0 or assisted.size() > 0)

	if vision_alert_placard:
		if vision_text_label:
			vision_text_label.text = "VISION: %.0f m | REACH: %.0f m" % [vision, longest]
		if vision_detail_label:
			if not has_weapons:
				vision_detail_label.text = "Every weapon's reach fits inside this design's own vision."
			elif required.size() > 0:
				var names: Array = []
				for w in required:
					names.append("%s (%.0f)" % [w["name"], w["reach"]])
				var pct = (vision / longest) * 100.0
				vision_detail_label.text = "%s %s far past this design's own %.0f vision. Without another unit of yours watching the target, it can only shoot as far as it can see - roughly %.0f%% of its reach. Pair it with a scout or a radar mast and it works at full range." % [
					", ".join(names),
					"reaches" if names.size() == 1 else "reach",
					vision,
					pct
				]
			elif assisted.size() > 0:
				var names: Array = []
				for w in assisted:
					names.append("%s (%.0f)" % [w["name"], w["reach"]])
				var overhang = longest - vision
				vision_detail_label.text = "%s can shoot further than this design can see (%.0f). Usable as-is, but a spotting unit or a radar mast is what unlocks the last %.0f units of that reach." % [
					", ".join(names), vision, overhang
				]
			else:
				vision_detail_label.text = "Every weapon's reach fits inside this design's own vision."

		# Ghost opacity when condition is false
		vision_alert_placard.visible = is_vision_alert
		if is_vision_alert:
			vision_alert_placard.modulate = Color(1, 1, 1, 1)
		else:
			vision_alert_placard.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)

	_update_assembly_health(is_over, is_power_alert, is_vision_alert)

	var mod_count := 0
	if hull:
		for child in hull.get_children():
			if child.has_meta("type_id") or child.has_meta("module_data"):
				mod_count += 1
	if combat_parts_label:
		combat_parts_label.text = "Modules: %d Mounted" % mod_count

	# --- 2. Build Group ---
	var metal = int(stats.get("cost_metal", 0))
	var crystal = int(stats.get("cost_crystal", 0))
	var credits = ResourceCatalogScript.credits_from_materials(Vector2i(metal, crystal))
	if build_cost_label:
		build_cost_label.text = "%d CREDITS" % credits
	if build_materials_label:
		build_materials_label.text = "%d Metal / %d Crystal" % [metal, crystal]

	var hull_id: String = hull.get_meta("type_id", "brenntal_medium_a") if (hull and hull.has_meta("type_id")) else "brenntal_medium_a"
	var hdata: Dictionary = ModuleCatalog.get_module_data(hull_id)
	var traits: Array = hdata.get("traits", [])
	var size_tier: String = ModuleCatalog.get_hull_size_tier(hull_id)

	if factory_glyph_label and factory_name_label:
		if hdata.get("is_foundation", false):
			factory_glyph_label.text = "🏗️"
			factory_name_label.text = "FOUNDRY EMPLACEMENT"
		elif "airborne" in traits or "fixed_wing" in traits or "rotary_wing" in traits:
			factory_glyph_label.text = "✈️"
			factory_name_label.text = "AEROSPACE HANGAR"
		elif "naval" in traits or "buoyant" in traits:
			factory_glyph_label.text = "⚓"
			factory_name_label.text = "NAVAL SHIPYARD"
		elif size_tier == "heavy":
			factory_glyph_label.text = "🏭"
			factory_name_label.text = "HEAVY FACTORY COMPLEX"
		else:
			factory_glyph_label.text = "⚙️"
			factory_name_label.text = "LIGHT VEHICLE FACTORY"

	if build_lab_tier_label:
		build_lab_tier_label.text = "Tech: Tier 2 Advanced Lab" if size_tier == "heavy" or "airborne" in traits else "Tech: Tier 1 Standard Lab"

	var b_time = maxf(4.0, (metal * 0.04 + crystal * 0.08))
	if build_time_label:
		build_time_label.text = "Build Time: %.1fs" % b_time


func _update_assembly_health(is_over: bool, is_power_alert: bool, is_vision_alert: bool) -> void:
	if not is_instance_valid(_assembly_health_label):
		return
	var conditions: PackedStringArray = []
	if is_over:
		conditions.append("CHASSIS OVERLOAD")
	if is_power_alert:
		conditions.append("POWER DEFICIT")
	if is_vision_alert:
		conditions.append("VISION GAP")
	_assembly_health_label.visible = not conditions.is_empty()
	if not conditions.is_empty():
		_assembly_health_label.text = "ASSEMBLY WARNING  /  " + "  ·  ".join(conditions)

func update_inspector(module: Node3D, data = null) -> void:
	if not is_instance_valid(inspector_title_label):
		return
	if module == null or not is_instance_valid(module) or data == null:
		var root = get_node_or_null("/root/MainLab")
		var hull = root.get_node_or_null("Hull") if root else null
		var hull_id: String = hull.get_meta("type_id", "brenntal_medium_a") if (hull and hull.has_meta("type_id")) else "brenntal_medium_a"
		var hdata: Dictionary = ModuleCatalog.get_module_data(hull_id)
		inspector_title_label.text = str(hdata.get("name", "Brenntal Medium")).to_upper()
		inspector_subtitle_label.text = "CHASSIS BASE // NO PART SELECTED"
		var hp = hdata.get("base_hp", hdata.get("hp", 1200.0))
		var wt = hdata.get("weight", 496.0)
		inspector_stats_label.text = "Base HP: %.0f | Base Mass: %.0f kg" % [hp, wt]
		if delete_button:
			delete_button.visible = false
		return

	var mod_name: String = ""
	var category: String = "module"
	var role_name: String = ""
	var hp: float = 100.0
	var wt: float = 50.0
	var dps: float = 0.0
	var cost_val: int = 10

	if data is Resource:
		mod_name = str(data.get("module_name")) if data.get("module_name") != null else "Module"
		category = str(data.get("category")) if data.get("category") != null else "module"
		var type_id: String = str(data.get("type_id")) if data.get("type_id") != null else ""
		var cat_entry: Dictionary = ModuleCatalog.get_module_data(type_id)
		role_name = str(cat_entry.get("role", cat_entry.get("category", category)))
		hp = data.get_hp() if data.has_method("get_hp") else float(data.get("base_hp", 100.0))
		wt = data.get_weight() if data.has_method("get_weight") else float(data.get("base_weight", 50.0))
		dps = data.get_dps() if data.has_method("get_dps") else float(data.get("base_dps", 0.0))
		if data.has_method("get_cost"):
			cost_val = ResourceCatalogScript.credits_from_materials(data.get_cost())
		else:
			cost_val = ResourceCatalogScript.credits_from_materials(Vector2i(int(data.get("cost_metal", 10)), int(data.get("cost_crystal", 0))))
	elif data is Dictionary:
		mod_name = str(data.get("name", data.get("module_name", "Module")))
		category = str(data.get("category", "module"))
		role_name = str(data.get("role", category))
		hp = float(data.get("hp", data.get("base_hp", 100.0)))
		wt = float(data.get("weight", data.get("base_weight", 50.0)))
		dps = float(data.get("dps", data.get("base_dps", 0.0)))
		cost_val = ResourceCatalogScript.credits_from_materials(Vector2i(int(data.get("metal", 10)), int(data.get("crystal", 0))))

	inspector_title_label.text = mod_name.to_upper()
	inspector_subtitle_label.text = "CATEGORY: %s // ROLE: %s" % [category.to_upper(), role_name.to_upper()]
	inspector_stats_label.text = "HP: %.1f | WT: %.1f kg | DPS: %.1f | Cost: %d cr" % [hp, wt, dps, cost_val]
	if delete_button:
		delete_button.visible = true


# One transparent top-bar slot: a caption over a value, with a hairline rule on
# its trailing edge so the row reads as divided cells rather than as drifting text.
#
# Transparent deliberately - the slot is a REGION of the toolbar band, not a panel
# sitting on it. Giving each slot its own plate would stack two materials in a
# 64px strip and make the bar look like a row of buttons, which is the opposite of
# "static info". The only drawn ink is the divider.
func _info_slot(parent: Control, caption: String) -> Label:
	var slot := VBoxContainer.new()
	slot.add_theme_constant_override("separation", 0)
	slot.custom_minimum_size = Vector2(Tokens.SPACE_XL * 3, 0)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(slot)

	var cap := Label.new()
	cap.text = caption
	cap.theme_type_variation = "HintLabel"
	slot.add_child(cap)

	var value := Label.new()
	value.text = "-"
	# HUDValueLabel is the monospace readout variation, so a value changing width
	# does not shove the slots beside it sideways.
	value.theme_type_variation = "HUDValueLabel"
	slot.add_child(value)

	var rule := VSeparator.new()
	parent.add_child(rule)
	return value


# Refreshed from update_stats()' DesignStats result, so the bar and the rail can
# never show different numbers for the same design.
func _update_toolbar_info(hull: Node3D, stats: Dictionary) -> void:
	if _slot_hull_label:
		var hull_type := "-"
		if hull and hull.has_meta("type_id"):
			hull_type = _prettify_id(str(hull.get_meta("type_id")))
		_slot_hull_label.text = hull_type
	if _slot_parts_label:
		var n := 0
		if hull:
			for child in hull.get_children():
				if child.has_meta("module_data"):
					n += 1
		_slot_parts_label.text = str(n)
	if _slot_cost_label:
		# Read from the stats dict rather than recomputed, so the toolbar and the
		# telemetry rail's own Cost row are the same number by construction.
		_slot_cost_label.text = "%d cr" % int(stats.get("cost_credits", 0))


func _prettify_id(id: String) -> String:
	var out: Array = []
	for w in id.split("_"):
		if w.length() > 0:
			out.append(w[0].to_upper() + w.substr(1))
	return " ".join(PackedStringArray(out))


func _admin_action(parent: Control, label: String, handler: Callable, role: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	if role == "danger":
		btn.theme_type_variation = "DangerButton"
	elif role == "confirm":
		btn.theme_type_variation = "PrimaryButton"
	btn.pressed.connect(handler)
	parent.add_child(btn)
	UIFeedbackScript.wire(btn, role)
	return btn


# The thin top toolbar. STEEL band via HeaderPanel, which already carries the
# hazard underline that separates chrome from viewport.
func _initial_sync():
	var root = get_node_or_null("/root/MainLab")
	var hull = root.get_node_or_null("Hull") if root else null
	if hull:
		if not hull.has_meta("blueprint_name"):
			hull.set_meta("blueprint_name", "Untitled Design")
		sync_hull_ui(hull)

func _on_part_hovered(type_id: String) -> void:
	var root = get_node_or_null("/root/MainLab")
	var hull = root.get_node_or_null("Hull") if root else null
	if hull == null or not is_instance_valid(hull):
		return
		
	var cat = ModuleCatalog.get_module_data(type_id).get("category", "")
	if cat == "hull":
		return # Cannot preview whole hull replacement cleanly
		
	var VisualBuilder = preload("res://scripts/visual_builder.gd")
	var ghost = VisualBuilder.build_module(type_id)
	var mirror = null
	
	if mirror_checkbox and mirror_checkbox.button_pressed:
		var is_symmetric = ModuleCatalog.get_module_data(type_id).get("is_symmetric", true)
		if not is_symmetric:
			mirror = VisualBuilder.build_module(type_id)
			
	# For locomotion, we want to simulate replacing the existing locomotion.
	# We achieve this by temporarily hiding existing locomotion modules from the hull
	# so they are skipped by DesignStatsScript.analyze, which recursively scans visible/valid children.
	var hidden_locomotion = []
	if cat == "locomotion":
		for child in hull.get_children():
			if child is Node3D and child.has_meta("type_id"):
				var child_cat = ModuleCatalog.get_module_data(child.get_meta("type_id")).get("category", "")
				if child_cat == "locomotion" and child.visible:
					child.visible = false
					hidden_locomotion.append(child)
					
	update_preview_stats(ghost, mirror)
	
	# Restore hidden locomotion
	for child in hidden_locomotion:
		if is_instance_valid(child):
			child.visible = true
			
	# Free the temporary preview nodes since TelemetryRail removes them from tree after analysis
	ghost.queue_free()
	if mirror:
		mirror.queue_free()

func _on_part_unhovered() -> void:
	clear_preview()


# Routed through SceneRouter so leaving this screen fades out rather than cutting.
# The get_node_or_null guard keeps the direct call as a fallback, matching the
# pattern the other router call sites in this file already use - a scene
# instantiated outside the running game (a test fixture) has no autoloads.

func update_stats(hull: Node3D) -> void:
	# Folded in from the deleted telemetry_rail.gd.
	_cached_hull = hull
	if not hull:
		_base_stats = {}
		update_stats_display({}, null)
		return
	var stats: Dictionary = DesignStatsScript.analyze(hull)
	_base_stats = stats
	_previewing = false
	update_stats_display(stats, hull)
	_update_toolbar_info(hull, stats)

func update_preview_stats(ghost_mesh: Node3D, mirror_mesh: Node3D = null) -> void:
	if not _cached_hull or _base_stats.is_empty():
		return
	var old_parent_1 = ghost_mesh.get_parent()
	if old_parent_1:
		old_parent_1.remove_child(ghost_mesh)
	_cached_hull.add_child(ghost_mesh)
	var old_parent_2 = null
	if mirror_mesh:
		old_parent_2 = mirror_mesh.get_parent()
		if old_parent_2:
			old_parent_2.remove_child(mirror_mesh)
		_cached_hull.add_child(mirror_mesh)
	var preview_stats = DesignStatsScript.analyze(_cached_hull)
	_cached_hull.remove_child(ghost_mesh)
	if old_parent_1:
		old_parent_1.add_child(ghost_mesh)
	if mirror_mesh:
		_cached_hull.remove_child(mirror_mesh)
		if old_parent_2:
			old_parent_2.add_child(mirror_mesh)
	_previewing = true
	update_stats_display(preview_stats, _cached_hull)
	_update_toolbar_info(_cached_hull, preview_stats)

func compare_against_blueprint(bp_stats: Dictionary) -> void:
	if _base_stats.is_empty():
		return
	_previewing = true
	# bp_stats is accepted for API parity with the old telemetry_rail.gd call,
	# but has no live consumer: update_stats_display() only renders absolute
	# values, never a delta against a baseline. Wire it in if delta
	# highlighting is ever added to the live console.
	update_stats_display(_base_stats, _cached_hull)
	_update_toolbar_info(_cached_hull, _base_stats)

func clear_preview() -> void:
	if _previewing and _cached_hull:
		_previewing = false
		update_stats_display(_base_stats, _cached_hull)
		_update_toolbar_info(_cached_hull, _base_stats)

func clear_comparison() -> void:
	clear_preview()

func _push_undo(): lab_toolbar._push_undo()
func _on_delete_pressed(): lab_toolbar._on_delete_pressed()
func _on_save_pressed(): lab_toolbar._on_save_pressed()
func _on_test_pressed(): lab_toolbar._on_test_pressed()
func _on_mirror_toggled(button_pressed: bool): lab_toolbar._on_mirror_toggled(button_pressed)
func _on_library_pressed(): lab_toolbar._on_library_pressed()
func _on_blueprint_name_changed(new_text: String):
	lab_toolbar._on_blueprint_name_changed(new_text)
	_update_abbr_label(new_text)

func _update_abbr_label(name_text: String) -> void:
	var label = find_child("BlueprintAbbrLabel", true, false) as Label
	if not label:
		return
	var abbr: String = BlueprintNamerScript.suggest_abbreviation(name_text)
	if not abbr.is_empty():
		label.text = "Callsign: \"%s\"" % abbr
		label.visible = true
	else:
		label.text = ""
		label.visible = false
func _on_blueprint_name_tooltip_update(new_text: String) -> void:
	if blueprint_name_edit:
		blueprint_name_edit.tooltip_text = new_text
func _on_roll_name_pressed(): lab_toolbar._on_roll_name_pressed()

func on_module_selected(module: Node3D):
	tweak_callout_manager.on_module_selected(module)
	if not is_instance_valid(_operation_label):
		return
	_operation_label.remove_theme_color_override("font_color")
	if is_instance_valid(module) and module.has_meta("module_data"):
		var data = module.get_meta("module_data")
		_operation_label.text = "TUNE  /  %s  ·  Drag to move  ·  Arrows + Enter: ring actions  ·  Esc: close" % data.type_id.replace("_", " ").capitalize()
		_set_operation_icon("state_selected", Tokens.TEXT_PRIMARY)
		_select_document_page("Selected")
	else:
		_operation_label.text = "ASSEMBLE  /  Drag a part from the parts bin onto a hull face"
		_set_operation_icon("drop_target", Tokens.TEXT_PRIMARY)
func _on_size_value_changed(value: float): tweak_callout_manager._on_size_value_changed(value)
func _on_count_value_changed(value: float): tweak_callout_manager._on_count_value_changed(value)
func _on_wheels_per_axle_changed(value: float): tweak_callout_manager._on_wheels_per_axle_changed(value)
func _on_blade_count_changed(value: float): tweak_callout_manager._on_blade_count_changed(value)
func _on_blade_pitch_changed(value: float): tweak_callout_manager._on_blade_pitch_changed(value)
func _on_helix_depth_changed(value: float): tweak_callout_manager._on_helix_depth_changed(value)
func _on_leg_width_changed(value: float): tweak_callout_manager._on_leg_width_changed(value)
func _on_duct_toggled(pressed: bool): tweak_callout_manager._on_duct_toggled(pressed)
func _on_leg_type_selected(index: int): tweak_callout_manager._on_leg_type_selected(index)
func _on_loco_drag_started(): tweak_callout_manager._on_loco_drag_started()
func _on_loco_drag_ended(value_changed: bool): tweak_callout_manager._on_loco_drag_ended(value_changed)
