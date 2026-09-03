class_name TelemetryRail
extends RefCounted

const DesignStatsScript = preload("res://scripts/design_stats.gd")
const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")
const DesignCostingScript = preload("res://scripts/battle/economy/design_costing.gd")
const DrivetrainScript = preload("res://scripts/drivetrain.gd")
const WeaponAlphaScript = preload("res://scripts/weapon_alpha.gd")
const PhosphorPanelScript = preload("res://scripts/ui/phosphor_panel.gd")
const DesignVerdictScript = preload("res://scripts/design_verdict.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")

var lab: Node

func _init(p_lab: Node):
	lab = p_lab

# --- Owned by the LAB, read through on every access ------------------------
#
# These twelve used to be snapshotted in _init as `x = lab.x`. That is the
# pattern that stranded the Design Lab's HULL/PARTS/COST readout and its
# HULL SPECIFICATION button, so it is gone here too: a read-through cannot go
# stale however lab_document.gd's _ready() is ordered later. Getter-only,
# because this class never assigned any of them anywhere except that snapshot.
var hp_label:
	get: return lab.hp_label
var weight_label:
	get: return lab.weight_label
var cost_label:
	get: return lab.cost_label
var dps_label:
	get: return lab.dps_label
var _rail_vbox:
	get: return lab._rail_vbox

var _alpha_rows: Array[Label] = []
var _load_fill_styles: Dictionary = {}

# --- The Lab's PUBLISHED headline stats: read/write proxies -----------------
#
# update_stats() ends by writing these (`self.total_hp = ...`), and
# lab_document.gd's own comment says why they exist: "published by update_stats()
# for readers that want the numbers rather than the label text -
# fleet_comparison_panel.gd is the existing one". That reader does
# `root.get_node("UI_StatBlock").total_hp`, i.e. it reads them off the LAB.
#
# They were separate variables: this class snapshotted the Lab's 0.0 in _init and
# then wrote its own copy, so the Lab's stayed 0.0 forever and the fleet
# comparison panel compared every design against 0 HP / 0 weight / 0 DPS. Its
# `if "total_hp" in stat_calc else 0.0` guard passes - the field exists, it is
# just never populated - so nothing ever complained.
#
# Getter AND setter, unlike the read-only block above: the write is the whole
# point. A getter-only property would silently swallow it, which is exactly the
# failure this replaced.
var total_hp:
	get: return lab.total_hp
	set(v): lab.total_hp = v
var total_weight:
	get: return lab.total_weight
	set(v): lab.total_weight = v
var total_dps:
	get: return lab.total_dps
	set(v): lab.total_dps = v
var drivetrain:
	get: return lab.drivetrain
	set(v): lab.drivetrain = v
var weapon_range:
	get: return lab.weapon_range
	set(v): lab.weapon_range = v

# --- Built and owned by THIS class ------------------------------------------
# Every one of these is created by the rail's own build methods. They were also
# being seeded from `lab.*` in _init, which only ever captured null (the Lab
# declares them but never assigns them) and was overwritten moments later. Those
# seeds are gone, and so are the Lab's vestigial declarations.
var _power_gen_label
var _verdict_panel
var _verdict_headline
var _verdict_detail

var _profile_panel: PanelContainer
var _profile_role_label: Label
var _profile_stars_label: Label
var _profile_desc_label: Label

var _armor_summary_label: Label
var _diag_toggle_btn: Button
var _diag_container: VBoxContainer
var _diag_open: bool = true

var _lifetime_panel
var _lifetime_headline
var _lifetime_detail

var _range_label
var _vision_label
var _spotter_panel
var _spotter_title
var _spotter_detail
var _alpha_label
var _alpha_head

var _power_draw_label
var _power_net_label
var _power_panel
var _power_title
var _power_detail

var _load_bar
var _speed_label
var _load_label
var _overweight_panel
var _overweight_title
var _overweight_detail
var _boost_label

var armor_threshold_label
var tech_req_label
var _power_storage_label

var _base_stats: Dictionary = {}
var _previewing: bool = false
var _cached_hull: Node3D = null

func _build_combat_profile_header() -> void:
	if _profile_panel != null and is_instance_valid(_profile_panel):
		return
	if not _rail_vbox:
		return

	_profile_panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.13, 0.95)
	style.border_color = Tokens.BASE_500
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = Tokens.SPACE_SM
	style.content_margin_right = Tokens.SPACE_SM
	style.content_margin_top = Tokens.SPACE_XS
	style.content_margin_bottom = Tokens.SPACE_XS
	_profile_panel.add_theme_stylebox_override("panel", style)
	_rail_vbox.add_child(_profile_panel)
	_rail_vbox.move_child(_profile_panel, 0)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_profile_panel.add_child(vbox)

	var top_row = HBoxContainer.new()
	vbox.add_child(top_row)

	_profile_role_label = Label.new()
	_profile_role_label.theme_type_variation = "HeadingLabel"
	_profile_role_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.7, 1.0))
	_profile_role_label.text = "COMBAT VEHICLE"
	_profile_role_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_profile_role_label)

	_profile_stars_label = Label.new()
	_profile_stars_label.theme_type_variation = "StatLabel"
	_profile_stars_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2, 1.0))
	_profile_stars_label.text = "★★★☆☆"
	top_row.add_child(_profile_stars_label)

	_profile_desc_label = Label.new()
	_profile_desc_label.theme_type_variation = "StatLabel"
	_profile_desc_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_profile_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_profile_desc_label.text = "All-round combatant."
	vbox.add_child(_profile_desc_label)

func _update_combat_profile(stats: Dictionary) -> void:
	if _profile_panel == null:
		_build_combat_profile_header()
	if _profile_panel == null or not is_instance_valid(_profile_panel):
		return

	if stats.is_empty():
		_profile_panel.visible = false
		return
	_profile_panel.visible = true

	var arch: Dictionary = DesignVerdictScript.get_combat_archetype(stats)
	_profile_role_label.text = str(arch.get("role", "COMBAT VEHICLE"))
	var stars_count: int = int(arch.get("stars", 3))
	var star_str := ""
	for i in range(5):
		star_str += "★" if i < stars_count else "☆"
	_profile_stars_label.text = star_str
	_profile_desc_label.text = str(arch.get("desc", ""))

func _ensure_diagnostics_section() -> void:
	if _diag_container != null and is_instance_valid(_diag_container):
		return
	if not _rail_vbox:
		return

	_diag_toggle_btn = Button.new()
	_diag_toggle_btn.text = "▲ ADVANCED TELEMETRY"
	_diag_toggle_btn.theme_type_variation = "Button"
	_diag_toggle_btn.custom_minimum_size = Vector2(0, 26)
	_rail_vbox.add_child(_diag_toggle_btn)

	_diag_container = VBoxContainer.new()
	_diag_container.add_theme_constant_override("separation", 2)
	_diag_container.visible = true
	_rail_vbox.add_child(_diag_container)

	_diag_toggle_btn.pressed.connect(func():
		_diag_open = not _diag_container.visible
		_diag_container.visible = _diag_open
		_diag_toggle_btn.text = ("▲ HIDE TELEMETRY" if _diag_open else "▼ ADVANCED TELEMETRY"))

func update_stats(hull: Node3D):
	_cached_hull = hull
	if not hull:
		_base_stats = {}
		_apply_stats({})
		return
	var stats: Dictionary = DesignStatsScript.analyze(hull)
	_base_stats = stats
	_previewing = false
	_apply_stats(stats)

func update_preview_stats(ghost_mesh: Node3D, mirror_mesh: Node3D = null):
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
	_apply_stats(preview_stats, _base_stats)

func compare_against_blueprint(bp_stats: Dictionary):
	if _base_stats.is_empty():
		return
	_previewing = true
	# _apply_stats(current, baseline). We want baseline to be bp_stats.
	_apply_stats(_base_stats, bp_stats)

func clear_preview():
	if _previewing:
		_previewing = false
		_apply_stats(_base_stats)

func clear_comparison():
	clear_preview()

func _format_delta(current: float, base: float, invert_good: bool = false, is_int: bool = false) -> String:
	if absf(current - base) < 0.05:
		return ""
	var diff = current - base
	var sign_str = "+" if diff > 0 else "-"
	var val_str = ("%.0f" if is_int else "%.1f") % absf(diff)
	
	var good = diff > 0
	if invert_good:
		good = not good
		
	var color = Tokens.SIGNAL_GO if good else Tokens.SIGNAL_ALERT
	var color_hex = color.to_html(false)
	return " [color=#%s]%s%s[/color]" % [color_hex, sign_str, val_str]

func _apply_stats(stats: Dictionary, base_stats: Dictionary = {}):
	if stats.is_empty():
		return
	# The faction re-tint that used to happen here is gone with the `Panel` node
	# it painted (VISUAL/UI plan items 2 and 7). ui_material.gdshader's contract is
	# explicit that chrome stays neutral and the faction accent is "a low-strength
	# identity wash for the faction preview swatch only, never general chrome" -
	# and repainting the whole 320px rail in the faction's colour on every stat
	# recompute is about as far from that as the codebase got. The rail is
	# POWDERCOAT from the dock now, the same in every faction; faction identity is
	# carried by the units on the stage, which is where the player is looking.
	# The whole summation this function used to do inline now lives in
	# DesignStats.analyze(), so the roster cards and the fleet comparison panel
	# can read the same figures instead of only this sidebar being able to.
	# Nothing about WHAT is computed changed - see design_stats.gd's header. The
	# locals below are kept as locals so the label code further down reads
	# unchanged.
	var hull = _cached_hull
	_update_combat_profile(stats)
	_update_verdict(stats)
	if lab.has_method("update_stats_display"):
		lab.update_stats_display(stats, hull)
	if lab.has_method("_update_toolbar_info"):
		lab._update_toolbar_info(hull, stats)
	var total_cost_metal = stats["cost_metal"]
	var total_cost_crystal = stats["cost_crystal"]
	var total_dps = stats["dps"]
	var dt: Dictionary = stats["drivetrain"]

	# Read armor from armor_plan (aggregate per-side) instead of legacy meta
	var armor_material = "hardened_steel"
	var armor_thickness = 1.0
	var faction = "industrialists"

	if hull:
		var plan: Dictionary = hull.get_meta("armor_plan", {})
		if not plan.is_empty() and not bool(plan.get("empty", true)):
			var sides: Dictionary = plan.get("sides", {})
			var best_mat := ""
			var best_weight := 0.0
			var thick_weighted_sum := 0.0
			var thick_weight_total := 0.0
			for s in sides:
				var sd: Dictionary = sides[s]
				var cov := float(sd.get("coverage", 0.0))
				var area := float(sd.get("area", 0.0))
				var mat := str(sd.get("material", ""))
				var thick := float(sd.get("mean_thickness", 0.0))
				if cov > 0.001 and area > 0.0 and mat != "":
					var w := cov * area
					if w > best_weight:
						best_weight = w
						best_mat = mat
					thick_weighted_sum += w * thick
					thick_weight_total += w
			if best_mat != "":
				armor_material = best_mat
			if thick_weight_total > 0.0:
				armor_thickness = thick_weighted_sum / thick_weight_total
		# Fallback to legacy meta if no plan
		if armor_material == "hardened_steel" and hull.has_meta("armor_material"):
			armor_material = hull.get_meta("armor_material")
		if armor_thickness == 1.0 and hull.has_meta("armor_thickness"):
			armor_thickness = hull.get_meta("armor_thickness")
		if hull.has_meta("faction"):
			faction = hull.get_meta("faction")

	var module_hp_pool = stats["module_hp_pool"]
	var total_hp = stats["hull_hp"]
	var total_weight = stats["weight"]

	var k_thresh = DamageResolverScript.get_material_threshold(armor_material, "kinetic", armor_thickness).x
	var t_thresh = DamageResolverScript.get_material_threshold(armor_material, "thermal", armor_thickness).x
	var e_thresh = DamageResolverScript.get_material_threshold(armor_material, "energy", armor_thickness).x

	var hp_delta = _format_delta(total_hp, base_stats.get("hull_hp", total_hp))
	var mpool_delta = _format_delta(module_hp_pool, base_stats.get("module_hp_pool", module_hp_pool))
	hp_label.text = "Hull HP: %.0f%s (modules +%.0f%s)" % [total_hp, hp_delta, module_hp_pool, mpool_delta]
	hp_label.tooltip_text = "Hull HP is the unit's real health pool in combat.\nModule HP is each mounted part's own pool - parts get shot off (subsystem stripping) without draining hull HP."
	var cost_diff = _format_delta(total_cost_metal + total_cost_crystal, base_stats.get("cost_metal", total_cost_metal) + base_stats.get("cost_crystal", total_cost_crystal), true, true)
	cost_label.text = "Cost: %d credits%s" % [ResourceCatalogScript.credits_from_materials(Vector2i(total_cost_metal, total_cost_crystal)), cost_diff]
	var dps_delta = _format_delta(total_dps, base_stats.get("dps", total_dps))

	var wa: Dictionary = stats.get("alpha", {})
	var alpha_per_shot: float = float(wa.get("per_shot", 0.0))
	if alpha_per_shot > 0.0 and total_dps > 0.0:
		dps_label.text = "DPS: %.1f%s  (Alpha: %.0f / shot)" % [total_dps, dps_delta, alpha_per_shot]
	else:
		dps_label.text = "Total DPS: %.1f%s" % [total_dps, dps_delta]

	var weight_delta = _format_delta(total_weight, base_stats.get("weight", total_weight), true)
	weight_label.text = "Total Weight: %.1f kg%s" % [total_weight, weight_delta]

	self.total_hp = total_hp
	self.total_weight = total_weight
	self.total_dps = total_dps
	self.drivetrain = dt
	var wr: Dictionary = stats["weapon_range"]
	self.weapon_range = wr

	var tier = ModuleCatalog.get_hull_size_tier(hull.get_meta("type_id", "brenntal_medium_a")) if hull and hull.has_meta("type_id") else ""
	var tooltip_parts: Array = []
	if tier != "":
		tooltip_parts.append("Needs a %s Manufactory to build this design." % tier.capitalize())
	weight_label.tooltip_text = "\n".join(tooltip_parts)
	weight_label.modulate = Color(1, 1, 1)

	_ensure_diagnostics_section()

	_update_drivetrain_readout(dt)
	_update_range_readout(wr)
	_update_power_readout(stats.get("power", {}))

	var k_desc = "Heavy" if k_thresh >= 20.0 else ("Mod" if k_thresh >= 10.0 else "Light")
	var t_desc = "Heavy" if t_thresh >= 20.0 else ("Mod" if t_thresh >= 10.0 else "Light")
	var e_desc = "Heavy" if e_thresh >= 20.0 else ("Mod" if e_thresh >= 10.0 else "Light")

	if not _armor_summary_label:
		_armor_summary_label = Label.new()
		_armor_summary_label.theme_type_variation = "StatLabel"
		_armor_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rail_vbox.add_child(_armor_summary_label)
		if hp_label and hp_label.get_parent() == _rail_vbox:
			_rail_vbox.move_child(_armor_summary_label, hp_label.get_index() + 1)
	_armor_summary_label.text = "Plating: %s [K:%s T:%s E:%s]" % [armor_material.replace("_", " ").capitalize(), k_desc, t_desc, e_desc]
	_armor_summary_label.tooltip_text = "Armor Material: %s (Thickness: %.1fx)\nKinetic threshold: %.1f (%s)\nThermal threshold: %.1f (%s)\nEnergy threshold: %.1f (%s)" % [
		armor_material.capitalize(), armor_thickness, k_thresh, k_desc, t_thresh, t_desc, e_thresh, e_desc]

	if not armor_threshold_label:
		armor_threshold_label = Label.new()
		armor_threshold_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_diag_container.add_child(armor_threshold_label)
	armor_threshold_label.text = "Armor Thresholds: K: %.1f, T: %.1f, E: %.1f" % [k_thresh, t_thresh, e_thresh]

	if not tech_req_label:
		tech_req_label = Label.new()
		tech_req_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_diag_container.add_child(tech_req_label)

	var req_buildings: Array[String] = []
	if hull:
		var root = lab.get_node_or_null("/root/Main")
		var bm = root.get_node_or_null("BlueprintManager") if root else null
		if bm and bm.has_method("serialize_hull"):
			var bp_data: Dictionary = bm.serialize_hull(hull)
			req_buildings = DesignCostingScript.blueprint_required_buildings(bp_data)

	if req_buildings.is_empty():
		tech_req_label.visible = false
	else:
		tech_req_label.visible = true
		var names: Array = []
		for r in req_buildings:
			names.append(str(r).replace("_", " ").capitalize())
		tech_req_label.text = "Required Buildings: %s" % ", ".join(names)

	_update_alpha_readout(stats.get("alpha", {}))


# --- Drivetrain readout (load bar + top speed + overweight warning) ---------
#
# WHY THIS IS VISIBLE CHROME AND NOT A TOOLTIP. The overweight state used to be
# communicated by tinting the weight label orange and putting a sentence in its
# tooltip. The comment justifying that said the sidebar "has zero
# vertical/horizontal layout slack left", and at the time it was right - it was
# a fixed 210px-wide strip, and the project's own overflow test had rejected
# three attempts at a persistent label.
#
# That constraint no longer exists. The TELEMETRY dock is a 320px UIDock whose
# body is a ScrollContainer (see _build_rail_dock()), so it can hold real rows
# and scroll them. A tooltip is also the wrong instrument for this specific
# job: the player is DRAGGING a tweak slider and needs to watch the number
# respond, and a tooltip is not on screen while the mouse is on the slider.
#
# Chris's ask was that exceeding capacity "light up a warning notification" and
# that the player "be aware of the flaw and what they are trading" - so the
# panel names the cost in the same units as the stat it is spending (speed),
# rather than saying "overweight" and leaving the player to infer the rest.
# Nothing here blocks saving or testing: an overloaded design is a legal,
# fieldable design, per that same ask.
func _load_fill_style(state: String) -> StyleBoxFlat:
	if not _load_fill_styles.has(state):
		var sb := StyleBoxFlat.new()
		match state:
			"go": sb.bg_color = Tokens.SIGNAL_GO
			"hazard": sb.bg_color = Tokens.SIGNAL_HAZARD
			_: sb.bg_color = Tokens.SIGNAL_ALERT
		sb.corner_radius_top_left = Tokens.RADIUS_CONTROL
		sb.corner_radius_top_right = Tokens.RADIUS_CONTROL
		sb.corner_radius_bottom_left = Tokens.RADIUS_CONTROL
		sb.corner_radius_bottom_right = Tokens.RADIUS_CONTROL
		_load_fill_styles[state] = sb
	return _load_fill_styles[state]

# --- Warning panel primitive -----------------------------------------------
#
# All three warning panels (overweight, power, spotter) share the same
# shape: a coloured panel with a left-border accent, holding a title row
# (the thing that changes - "OVERWEIGHT", "POWER SHORTFALL", "SPOTTER
# REQUIRED") and a detail row below it (the why). Extracted into one
# builder so the three call sites cannot drift on the visual language,
# and so a future change to the panel shape (e.g. adding an icon, or
# a different separator) lands in one place.
#
# THE SHAPE:
#
#   +-----------------------------------+
#   |  ! TITLE                         |   <- "HeadingLabel" in edge colour,
#   |  ----------------------------     |      with a "!" prefix as the
#   |  detail text wraps here, one     |      thematic icon the detail
#   |  short paragraph.                 |      used to visually crowd.
#   +-----------------------------------+
#
# The hairline rule between title and detail is what fixes the
# "detail overlaps the title" read the old layout had: with only
# 4px of VBox separation and no rule, the two lines blurred into
# one block. The rule also matches the UIFlyout.set_title() pattern
# (ui_flyout.gd:82-90), so the rail and the popover agree on what
# a "titled section" looks like.
#
# The detail uses TEXT_PRIMARY rather than the HintLabel's default
# TEXT_SECONDARY: against the dim-amber fill of a hazard panel, the
# secondary text reads as muddy. TEXT_PRIMARY is the warm off-white
# and has the contrast the warning actually needs to be readable.
#
# Returns [PanelContainer, Label(title), Label(detail)] so the caller
# stores them in its own _panel/_title/_detail fields and updates the
# text from update_stats() / update_*_readout() as before.
func _build_warning_panel(role: String) -> Array:
	var pair := Tokens.signal_pair(role)
	var panel := PanelContainer.new()
	var warn_style := StyleBoxFlat.new()
	warn_style.bg_color = pair["fill"]
	warn_style.border_color = pair["edge"]
	warn_style.border_width_left = Tokens.BORDER_EMPHASIS
	warn_style.content_margin_left = Tokens.SPACE_SM
	warn_style.content_margin_right = Tokens.SPACE_SM
	warn_style.content_margin_top = Tokens.SPACE_XS
	warn_style.content_margin_bottom = Tokens.SPACE_XS
	panel.add_theme_stylebox_override("panel", warn_style)
	# ALWAYS VISIBLE, GHOSTED WHEN UNLIT. The panel used to be `visible = false`
	# until its condition tripped, which meant three different amounts of the
	# rail's vertical space depending on how many warnings were currently true
	# - lighting one shoved everything below it down the rail mid-drag, which
	# is the opposite of what a warning arriving before the cliff should feel
	# like. The slot now always occupies its row; _apply_warning() below is the
	# single place that snaps it between the ghosted and lit look, so a fourth
	# warning added later only has to call that function, not invent a new
	# show/hide rule.
	panel.visible = true
	panel.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)

	var warn_box := VBoxContainer.new()
	warn_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	panel.add_child(warn_box)

	# Title row. HeadingLabel in the panel's edge colour, with a leading
	# "!" as the thematic icon. The "!" is plain ASCII, not a glyph or
	# emoji - it renders in the same Source Sans Pro Bold face the
	# rest of the title uses, so the title reads as one typographic
	# line rather than as "icon + text" stuck together.
	var title := Label.new()
	title.theme_type_variation = "HeadingLabel"
	title.add_theme_color_override("font_color", pair["edge"])
	warn_box.add_child(title)

	# Hairline rule - sits BETWEEN the title and the detail, so the
	# detail has a clear "underneath the title" position. Same role
	# the HSeparator plays in UIFlyout.set_title() (ui_flyout.gd:88-90).
	var rule := HSeparator.new()
	# The rule's own separation is a bit wider than the warn_box's
	# default SPACE_XS (4px) so the title and the detail feel like
	# distinct regions, not two lines of the same paragraph.
	rule.add_theme_constant_override("separation", Tokens.SPACE_SM)
	rule.add_theme_color_override("separator", pair["edge"])
	warn_box.add_child(rule)

	# Detail row. TEXT_PRIMARY (not the HintLabel default of
	# TEXT_SECONDARY) for contrast against the dim-amber fill -
	# a warning the player cannot read is not a useful warning.
	# autowrap is mandatory: these lines run past the rail's width
	# and a non-wrapping label would stretch the whole dock.
	var detail := Label.new()
	detail.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn_box.add_child(detail)

	return [panel, title, detail]


# The ONE lit/unlit rule every warning panel goes through - see the ghosting
# comment in _build_warning_panel(). idle_title/idle_detail are what the slot
# reads as an inactive indicator ("no problem right now"); lit_title/
# lit_detail are the specific, actionable message. Adding a fourth warning
# later is a call to this function with its own four strings, not a new
# widget or a new show/hide branch.
func _apply_warning(panel: PanelContainer, title_lbl: Label, detail_lbl: Label, lit: bool,
		idle_title: String, idle_detail: String, lit_title: String = "", lit_detail: String = "") -> void:
	print("[TELEMETRY] _apply_warning: panel=%s, lit=%s, idle_title=%s" % [panel.name if panel else "null", lit, idle_title])
	if lit:
		panel.modulate = Color(1, 1, 1, 1)
		title_lbl.modulate = Color(1, 1, 1, 1)
		detail_lbl.modulate = Color(1, 1, 1, 1)
		title_lbl.text = lit_title
		detail_lbl.text = lit_detail
	else:
		panel.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)
		title_lbl.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)
		detail_lbl.modulate = Color(1, 1, 1, Tokens.WARNING_GHOST_OPACITY)
		title_lbl.text = idle_title
		detail_lbl.text = idle_detail


func _build_drivetrain_readout() -> void:
	# Built once, lazily, then reused - matches how armor_threshold_label is
	# handled in update_stats(). Ordered directly
	# after the weight row it explains, via move_child: lazily-added children
	# otherwise land at the end of the rail, which would put the load bar
	# below the save/test buttons.
	_speed_label = Label.new()
	_speed_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_speed_label)

	_load_label = Label.new()
	_load_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_load_label)

	_load_bar = ProgressBar.new()
	_load_bar.show_percentage = false
	_load_bar.min_value = 0.0
	# Deliberately 0-125 rather than 0-100: a bar that pins at full the moment
	# a design crosses capacity cannot show HOW far over it is, and "how far
	# over" is the whole quantity the player is trading against. Past 125% it
	# does pin, and the warning panel carries the exact figure.
	_load_bar.max_value = 125.0
	_load_bar.custom_minimum_size = Vector2(0, 6)
	_rail_vbox.add_child(_load_bar)

	# The warning notification. HAZARD, not ALERT: an overweight design is a
	# flaw the player is choosing to accept, not a failure or a destructive
	# action - see ui_tokens.gd's role comments on the signal colours.
	var w_overweight := _build_warning_panel("hazard")
	_overweight_panel = w_overweight[0]
	_overweight_title = w_overweight[1]
	_overweight_detail = w_overweight[2]
	_rail_vbox.add_child(_overweight_panel)

	if weight_label and weight_label.get_parent() == _rail_vbox:
		var at = weight_label.get_index()
		_rail_vbox.move_child(_speed_label, at + 1)
		_rail_vbox.move_child(_load_label, at + 2)
		_rail_vbox.move_child(_load_bar, at + 3)
		_rail_vbox.move_child(_overweight_panel, at + 4)

# --- Power readout ---------------------------------------------------------
#
# Four rows and a warning, built to the same pattern as the drivetrain block
# above and placed directly under it, because they are the same kind of
# statement: here is a budget, here is what you are spending against it, and
# here is what exceeding it costs. A player who has learned to read the load bar
# already knows how to read this.
#
# Why four rows rather than one "power: OK/short" summary. The three inputs fail
# differently and have different fixes, and collapsing them hides which one the
# player is short of:
#
#   Generation  too low  -> fit a fusion generator
#   Storage     too low  -> fit a capacitor bank
#   Draw        too high -> take some electronics off
#
# A single net figure cannot distinguish "needs a generator" from "needs a
# capacitor", and those are genuinely different answers to genuinely different
# problems - a design that is permanently slightly short needs generation, while
# one that is fine except during a firefight needs buffer.
func _build_power_readout() -> void:
	_power_gen_label = Label.new()
	_power_gen_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_power_gen_label)

	_power_storage_label = Label.new()
	_power_storage_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_power_storage_label)

	_power_draw_label = Label.new()
	_power_draw_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_power_draw_label)

	_power_net_label = Label.new()
	_power_net_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_power_net_label)

	# HAZARD, matching the overweight panel exactly. A power deficit is the same
	# class of thing: a flaw the player may be choosing deliberately, not a
	# failure and not a destructive action. It does not block saving or fielding,
	# for the same reason the overweight panel does not - a burst-heavy design
	# that runs down its buffer in a short engagement and recharges between them
	# is a legitimate build, and the Lab has no business deciding it is wrong.
	var w_power := _build_warning_panel("hazard")
	_power_panel = w_power[0]
	_power_title = w_power[1]
	_power_detail = w_power[2]
	_rail_vbox.add_child(_power_panel)

	# Sits under the drivetrain block rather than at the end of the rail, where
	# lazily-added children otherwise land - which would put it below the
	# save/test buttons. Same move_child ordering the drivetrain readout uses.
	if _overweight_panel and _overweight_panel.get_parent() == _rail_vbox:
		var at = _overweight_panel.get_index()
		_rail_vbox.move_child(_power_gen_label, at + 1)
		_rail_vbox.move_child(_power_storage_label, at + 2)
		_rail_vbox.move_child(_power_draw_label, at + 3)
		_rail_vbox.move_child(_power_net_label, at + 4)
		_rail_vbox.move_child(_power_panel, at + 5)


func _update_power_readout(pw: Dictionary) -> void:
	if _power_net_label == null:
		_build_power_readout()

	print("[TELEMETRY] _update_power_readout: pw=%s" % [pw])

	# clear_hull() calls update_stats(null), and there is nothing to say about
	# the power budget of a design that does not exist. Branches on has_hull
	# exactly as the drivetrain readout branches on has_locomotion - the dict is
	# always fully populated, so emptiness is a flag rather than a missing key.
	if pw.is_empty() or not bool(pw.get("has_hull", false)):
		for l in [_power_gen_label, _power_storage_label, _power_draw_label, _power_net_label]:
			if l: l.visible = false
		if _power_panel: _power_panel.visible = false
		return
	for l in [_power_gen_label, _power_storage_label, _power_draw_label, _power_net_label]:
		if l: l.visible = true

	var generation: float = float(pw.get("generation", 0.0))
	var storage: float = float(pw.get("storage", 0.0))
	var draw: float = float(pw.get("draw", 0.0))
	var weapon_draw: float = float(pw.get("weapon_draw", 0.0))
	var net: float = float(pw.get("net", 0.0))

	_power_gen_label.text = "Generation: %.1f /s" % generation
	_power_gen_label.tooltip_text = "Hull base output plus any Fusion Generators. This is the rate the buffer refills at."
	_power_storage_label.text = "Storage: %.0f" % storage
	_power_storage_label.tooltip_text = "Hull base capacity plus any Capacitor Banks.\nStorage does not make power - it decides how long a shortfall is survivable."

	# The weapon share is called out separately because it is conditional in a
	# way the rest is not: a unit that is not shooting is not paying it, so a
	# design can be in deficit only while it fires. Merging the two would make
	# an intermittent cost look permanent.
	if weapon_draw > 0.0:
		_power_draw_label.text = "Draw: %.1f /s  (%.1f firing)" % [draw, weapon_draw]
		_power_draw_label.tooltip_text = "Continuous draw from electronics and shield upkeep, plus what sustained energy-weapon fire adds on top.\nThe second figure only applies while actually shooting."
	else:
		_power_draw_label.text = "Draw: %.1f /s" % draw
		_power_draw_label.tooltip_text = "Continuous draw from electronics and shield upkeep."

	_power_net_label.text = "Net: %+.1f /s" % net
	if net < 0.0:
		_power_net_label.add_theme_color_override("font_color", Tokens.signal_pair("hazard")["edge"])
	else:
		_power_net_label.remove_theme_color_override("font_color")
	_power_net_label.tooltip_text = "Generation minus the always-on draw, so this is the design at rest.\nNegative means the buffer runs down even when it is not shooting."

	# Two different warnings, because they are two different problems with two
	# different fixes. PowerBudget makes them mutually exclusive
	# (firing_deficit_only is false whenever has_deficit is true), so the order
	# of these branches does not matter and neither can mask the other.
	var excessive_peak: bool = float(pw.get("max_shot_cost", 0.0)) > float(pw.get("storage", 0.0))
	var has_deficit: bool = bool(pw.get("has_deficit", false))
	var firing_only: bool = bool(pw.get("firing_deficit_only", false))
	
	if excessive_peak:
		var max_shot := float(pw.get("max_shot_cost", 0.0))
		_apply_warning(_power_panel, _power_title, _power_detail, true, "", "",
			"!  PEAK DRAW EXCESSIVE",
			"A weapon needs %.1f energy to fire, but capacity is only %.1f. It will never fire. Add a Capacitor Bank." % [max_shot, storage])
	elif has_deficit:
		var rest_endurance := float(pw.get("endurance", 0.0))
		var firing_endurance := float(pw.get("firing_endurance", 0.0))
		var detail := "A full buffer lasts %.0fs at rest." % rest_endurance
		if firing_endurance != rest_endurance and firing_endurance != INF:
			detail += " Sustained fire: %.0fs." % firing_endurance
		detail += " Shields drop first, then sensors dim, then energy weapons stop. Buildable and fieldable as-is - fit a generator, add storage to ride it out, or drop some electronics."
		_apply_warning(_power_panel, _power_title, _power_detail, true, "", "",
			"!  POWER DEFICIT - %.1f /s SHORT" % absf(net),
			detail)
	elif firing_only:
		var firing_net := absf(float(pw.get("firing_net", 0.0)))
		var firing_endurance := float(pw.get("firing_endurance", 0.0))
		var max_shot := float(pw.get("max_shot_cost", 0.0))
		var burst_shots := int(storage / maxf(max_shot, 1.0))
		var detail := "Fine at rest, but %.1f /s short while firing - about %.0fs of continuous fire from a full buffer before energy weapons cut out." % [firing_net, firing_endurance]
		if burst_shots > 0:
			detail += " ~%d shots burst." % burst_shots
		detail += " Capacitors buy a longer burst; a generator buys sustain."
		_apply_warning(_power_panel, _power_title, _power_detail, true, "", "",
			"!  SUSTAINED FIRE OUTRUNS POWER",
			detail)
	else:
		_apply_warning(_power_panel, _power_title, _power_detail, false,
			"!  POWER DEFICIT", "Generation and storage cover this design's draw.")


func _update_drivetrain_readout(dt: Dictionary) -> void:
	if _load_bar == null:
		_build_drivetrain_readout()

	print("[TELEMETRY] _update_drivetrain_readout: has_locomotion=%s, is_overloaded=%s, load_pct=%.1f" % [dt["has_locomotion"], dt["is_overloaded"], dt["load_ratio"] * 100.0])

	# A design with no running gear yet has no speed and no capacity to be
	# over. Showing "Top Speed 0.0" and a full-red load bar on a hull the
	# player has only just spawned would read as a fault in the design rather
	# than as an unfinished one.
	if not dt["has_locomotion"]:
		_speed_label.text = "Top Speed: - (no locomotion)"
		_load_label.visible = false
		_load_bar.visible = false
		_overweight_panel.visible = false
		return
	_load_label.visible = true
	_load_bar.visible = true

	var top_speed: float = dt["top_speed"]
	var move_speed: float = dt["move_speed"]
	var load_pct: float = dt["load_ratio"] * 100.0

	# Two different figures when overloaded, and the gap between them IS the
	# trade. When not overloaded there is only one, so only one is shown -
	# printing "9.7 (of 9.7)" would imply a penalty that isn't there.
	#
	# The gap is also suppressed when it rounds away. A design a fraction of a
	# percent over capacity has a real but sub-0.05 penalty, and rendering that
	# as "Top Speed: 5.0 (was 5.0)" reads as a broken label rather than as a
	# negligible cost - caught in the 100%-load capture, not by the suite,
	# which asserts the text only at 130% where the gap is wide.
	#
	# Running light is the same story told the other way, and it gets the same
	# treatment: the bonus is only printed when it survives rounding, and it is
	# stated as a gain rather than as a bare parenthetical so it cannot be
	# misread as the penalty case at a glance.
	if dt["is_overloaded"] and absf(top_speed - move_speed) >= 0.05:
		_speed_label.text = "Top Speed: %.1f  (was %.1f)" % [move_speed, top_speed]
	elif dt.get("is_underloaded", false) and absf(move_speed - top_speed) >= 0.05:
		_speed_label.text = "Top Speed: %.1f  (+%.0f%% running light)" % [
			move_speed, (dt["underload_multiplier"] - 1.0) * 100.0]
	else:
		_speed_label.text = "Top Speed: %.1f" % move_speed
	# Says WHICH limit is binding, because the two have opposite fixes: a
	# chassis-limited design needs different locomotion, a power-limited one
	# needs more thrust or less mass. Without this the player has no way to
	# tell why adding engines stopped helping.
	#
	# chassis_top_speed already HAS a propulsion part's top_speed_mult folded
	# in (Drivetrain.analyze() applies it before returning the figure), so an
	# Overdrive Gearbox is already visible in the number itself - this just
	# names why it moved, the same way the overload/underload rows above name
	# their own multipliers rather than leaving the player to infer them.
	var mult_note := ""
	if dt.get("chassis_speed_mult", 1.0) > 1.001:
		mult_note = " (+%.0f%% from fitted propulsion)" % [(dt["chassis_speed_mult"] - 1.0) * 100.0]
	if dt["capacity_limited"] and not dt["is_overloaded"]:
		_speed_label.tooltip_text = "This chassis is rated for %.1f%s and is already there - more thrust will not make it faster. A different locomotion type (or a part that raises the ceiling itself) will." % [dt["chassis_top_speed"], mult_note]
	else:
		_speed_label.tooltip_text = "Chassis rated %.1f%s; this design's power/weight allows %.1f." % [dt["chassis_top_speed"], mult_note, dt["power_top_speed"]]

	# `carried_weight` here, not `weight` - the bar is `load_ratio` (= carried /
	# capacity), so the numerator in the label has to be the carried mass for
	# the two figures to agree. The total design mass is shown on the
	# `weight_label` row above; the chassis/loco split it omits is the point
	# of the "tuned for the unit" pass (Chris, 2026-08-16).
	var carried: float = float(dt.get("carried_weight", dt.get("weight", 0.0)))
	_load_label.text = "Load: %.0f / %.0f kg  (%.0f%%)" % [carried, dt["capacity"], load_pct]
	_load_bar.value = minf(load_pct, _load_bar.max_value)
	# HAZARD from 90% - the point of a warning is to arrive BEFORE the cliff,
	# and a design at 95% is one armor plate away from the penalty.
	var state := "go"
	if dt["is_overloaded"]:
		state = "alert"
	elif load_pct >= 90.0:
		state = "hazard"
	_load_bar.add_theme_stylebox_override("fill", _load_fill_style(state))

	if dt["is_overloaded"]:
		# Same rounding guard as the speed row above: at a fraction of a
		# percent over, "Top speed 5.0 instead of 5.0" reads as a broken
		# label, so the cost is stated as a percentage alone until the two
		# figures actually differ on screen.
		var cost_pct: float = (1.0 - dt["overload_multiplier"]) * 100.0
		var cost: String
		if absf(top_speed - move_speed) >= 0.05:
			cost = "Top speed %.1f instead of %.1f (-%.0f%%)." % [move_speed, top_speed, cost_pct]
		else:
			cost = "Top speed down %.1f%% so far, and falling steeply from here." % cost_pct
		# Overage against capacity, not total: the locomotor is calibrated
		# for the unit, so what it cannot carry is what matters. See the
		# `_load_label` note above for the same reasoning.
		var overweight_detail := "%.0f kg over what this locomotion is rated to carry. %s Buildable and fieldable as-is - add locomotion, shed carried mass, or accept the loss." % [
			carried - dt["capacity"], cost]
		_apply_warning(_overweight_panel, _overweight_title, _overweight_detail, true,
			"", "", "!  OVERWEIGHT - %.0f%% OF CAPACITY" % load_pct, overweight_detail)
	else:
		_apply_warning(_overweight_panel, _overweight_title, _overweight_detail, false,
			"!  OVERWEIGHT", "Load is within what this locomotion is rated to carry.")
	_load_label.tooltip_text = "What this design's locomotion is rated to carry, tweaks included. The chassis and locomotion themselves are not counted against this limit - the locomotor is tuned for the unit.\nOver capacity, top speed falls steeply - see the warning below.\nUnder %.0f%%, the design runs light and gains top speed, up to +%.0f%% empty." % [
		DrivetrainScript.UNDERLOAD_THRESHOLD * 100.0,
		(DrivetrainScript.UNDERLOAD_CEILING - 1.0) * 100.0]

	# Boost row - shows burst speed parts if fitted
	_update_boost_readout(dt)


# --- Boost readout ---------------------------------------------------------
# The Design Lab shows the burst boost as its own row, separate from the
# steady-state top speed. This is deliberate: a burst that inflated the
# quoted top speed would make the Lab's number a lie (Drivetrain.analyze()
# is design-time; boost is combat-time only).
func _build_boost_readout() -> void:
	_boost_label = Label.new()
	_boost_label.theme_type_variation = "StatLabel"
	_boost_label.visible = false
	_rail_vbox.add_child(_boost_label)
	# Place after the load bar row - find the overweight_panel and insert before it
	if _overweight_panel and _overweight_panel.get_parent() == _rail_vbox:
		var at = _overweight_panel.get_index()
		_rail_vbox.move_child(_boost_label, at)

func _update_boost_readout(dt: Dictionary) -> void:
	if _boost_label == null:
		_build_boost_readout()

	var boost: Dictionary = dt.get("boost", {})
	if boost.is_empty():
		_boost_label.visible = false
		return

	var speed_mult: float = float(boost.get("speed_mult", 1.0))
	var duration: float = float(boost.get("duration", 0.0))
	var cooldown: float = float(boost.get("cooldown", 0.0))
	var charges: int = int(boost.get("charges", 0))

	_boost_label.visible = true
	if charges == 0:
		_boost_label.text = "Boost: x%.2f for %.1fs (%.1fs cooldown)" % [speed_mult, duration, cooldown]
	else:
		_boost_label.text = "Boost: x%.2f for %.1fs (%d charges)" % [speed_mult, duration, charges]
	_boost_label.tooltip_text = "Burst speed from a fitted propulsion part. Engages automatically on long straight runs when no enemy is in range.\nDoes not inflate the quoted top speed above - that is steady-state only."

# --- Range readout ---------------------------------------------------------
# The sidebar showed no range at all before this, which made a whole axis of
# the design invisible: the player could drag barrel_length - the single
# biggest lever on reach - and see the weight and cost move while the stat it
# was actually buying stayed off-screen entirely.
#
# It reports three things, because the range retune (ModuleCatalog.RANGE_TIERS)
# made them separable for the first time:
#   - the reach span across the design's real weapons, and which tier the
#     longest one lands in;
#   - the design's own vision, since that is the line between "this weapon can
#     find its own targets" and "this weapon needs somebody else to look";
#   - a warning naming any weapon that reaches past that line, and what it
#     costs. Exactly like the overweight panel, it does not block anything: a
#     spotter-dependent design is a legitimate and often very strong design,
#     it just isn't one you want to field by accident with no scout.
func _build_range_readout() -> void:
	_range_label = Label.new()
	_range_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_range_label)

	_vision_label = Label.new()
	_vision_label.theme_type_variation = "StatLabel"
	_rail_vbox.add_child(_vision_label)

	# HAZARD, matching the overweight panel: a trade the player is choosing,
	# not a failure. See ui_tokens.gd's role comments on the signal colours.
	var w_spotter := _build_warning_panel("hazard")
	_spotter_panel = w_spotter[0]
	_spotter_title = w_spotter[1]
	_spotter_detail = w_spotter[2]
	_rail_vbox.add_child(_spotter_panel)

	# Sits directly after the DPS row it belongs with, rather than at the end
	# of the rail where lazily-added children otherwise land (which would put
	# it below the save/test buttons). Same move_child idiom as the drivetrain
	# rows above.
	# Fallback: if dps_label isn't in _rail_vbox, place after the last child
	# before the diagnostics toggle (which is always near the bottom).
	var insert_at: int = _rail_vbox.get_child_count() - 1
	if dps_label and dps_label.get_parent() == _rail_vbox:
		insert_at = dps_label.get_index()
	_rail_vbox.move_child(_range_label, insert_at + 1)
	_rail_vbox.move_child(_vision_label, insert_at + 2)
	_rail_vbox.move_child(_spotter_panel, insert_at + 3)

func _update_range_readout(wr: Dictionary) -> void:
	if _range_label == null:
		print("[TELEMETRY] _build_range_readout() called")
		_build_range_readout()

	# A hull with no armed modules yet has no range to report. Showing
	# "Range: 0.0" on a design the player has only started reads as a fault
	# rather than as an unfinished build - same reasoning as the drivetrain
	# readout's no-locomotion case.
	print("[TELEMETRY] _update_range_readout: has_weapons=%s, wr=%s" % [wr.get("has_weapons", false), wr])
	if not wr.get("has_weapons", false):
		_range_label.text = "Range: - (no weapons)"
		_vision_label.visible = false
		# Ghost the spotter panel instead of hiding it - the slot must always
		# occupy its row so the rail doesn't reflow when weapons are added.
		_apply_warning(_spotter_panel, _spotter_title, _spotter_detail, false,
			"!  OUT-REACHES ITS OWN VISION", "Every weapon's reach fits inside this design's own vision.")
		return
	_vision_label.visible = true

	var shortest: float = wr["shortest"]
	var longest: float = wr["longest"]
	var vision: float = wr["vision"]

	# One figure when every weapon reaches the same distance, a span otherwise -
	# printing "Range: 38 - 38" implies a spread that isn't there.
	if absf(longest - shortest) >= 0.5:
		_range_label.text = "Range: %.0f - %.0f  (%s)" % [shortest, longest, wr["tier_label"]]
	else:
		_range_label.text = "Range: %.0f  (%s)" % [longest, wr["tier_label"]]
	_range_label.tooltip_text = "Reach of this design's armed modules, tweaks included.\nBarrel length is the biggest lever: a longer barrel reaches further and throws faster, but traverses slower."

	_vision_label.text = "Vision: %.0f" % vision
	_vision_label.tooltip_text = "How far this design can see for itself.\nWeapons reaching past this can only fire that far at targets another unit on your team is looking at."

	var required: Array = wr["spotter_required"]
	var assisted: Array = wr["spotter_assisted"]
	var spotter_lit: bool = not required.is_empty() or not assisted.is_empty()
	if not spotter_lit:
		_apply_warning(_spotter_panel, _spotter_title, _spotter_detail, false,
			"!  OUT-REACHES ITS OWN VISION", "Every weapon's reach fits inside this design's own vision.")
		return

	# The stronger claim first. A weapon past 2x vision cannot meaningfully
	# self-acquire at range at all, which is a different and much more
	# consequential fact than "reaches a bit past its own eyes".
	if not required.is_empty():
		var names: Array = []
		for w in required:
			names.append("%s (%.0f)" % [w["name"], w["reach"]])
		var detail := "%s %s far past this design's own %.0f vision. Without another unit of yours watching the target, it can only shoot as far as it can see - roughly %.0f%% of its reach. Pair it with a scout or a radar mast and it works at full range." % [
			", ".join(names),
			"reaches" if names.size() == 1 else "reach",
			vision,
			(vision / longest) * 100.0]
		_apply_warning(_spotter_panel, _spotter_title, _spotter_detail, true, "", "",
			"!  NEEDS A SPOTTER", detail)
	else:
		var names: Array = []
		for w in assisted:
			names.append("%s (%.0f)" % [w["name"], w["reach"]])
		var detail := "%s can shoot further than this design can see (%.0f). Usable as-is, but a spotting unit or a radar mast is what unlocks the last %.0f units of that reach." % [
			", ".join(names), vision, longest - vision]
		_apply_warning(_spotter_panel, _spotter_title, _spotter_detail, true, "", "",
			"!  OUT-REACHES ITS OWN VISION", detail)

# --- Alpha readout (per-shot damage and what it is worth vs armour) ---------
#
# WHAT THIS FIXES. "Total DPS" one row up is, by construction, the one figure
# the caliber and barrel_length sliders cannot say anything interesting with.
# Both tweaks sit in the linear multiplier lists of ModuleData.get_dps(),
# get_weight() AND get_cost(), so dragging either moved all three rows by the
# same factor: DPS-per-kg and DPS-per-credit were perfectly FLAT across the
# whole slider range. A player who dragged the bar, watched three numbers rise
# together and concluded it did not matter was reading this rail correctly.
#
# The trade is real and lives one layer down. caliber also multiplies the shot
# INTERVAL (auto_weapon.gd's cadence chain, mirrored in WeaponAlpha.
# shot_interval()), so a bigger bore is FEWER, HARDER hits at roughly the same
# nominal DPS. That matters because damage_resolver.gd gates on the SHOT, never
# on the DPS: under the material's threshold a hit delivers CHIP_THROUGH_FACTOR
# of its already-reduced damage, and from BRUTE_FORCE_RATIO x threshold upward
# the reduction blends back toward 1.0. Same weapon, same DPS, roughly a 6.7x
# swing in what actually lands - decided entirely by alpha.
#
# So the block prints the two things the rail was missing:
#   - the per-shot alpha, and the cadence it is bought at;
#   - one row per armour material: the effective DPS this design lands on that
#     plate, and which regime the hardest shot is in against it.
#
# DESIGN_VISION.md's test ("two players building the same concept must diverge
# through continuous tweaks") is decided almost entirely here, which is why
# this is visible chrome and not a tooltip - the player is DRAGGING the slider
# and needs to watch the regime word flip while the mouse is on the handle.
#
# NO WARNING PANEL, unlike the drivetrain/power/spotter blocks. The chip-regime
# failure already leads the rail in the verdict block at the top ("CHIPS ONLY",
# see design_verdict.gd), and a fourth hazard placard restating it eight rows
# further down would be the same sentence twice on one screen. The colour on
# the material rows is the in-place signal; the verdict is the headline.
func _alpha_regime_word(regime: String) -> String:
	if regime == WeaponAlphaScript.REGIME_CHIP:
		return "CHIP"
	if regime == WeaponAlphaScript.REGIME_BRUTE:
		return "BRUTE"
	return "through"


# Returns null for the ordinary regime rather than a colour, so the caller can
# clear the override and fall back to StatLabel's own TEXT_SECONDARY instead of
# this file hardcoding what "normal text" is a second time.
func _alpha_regime_color(regime: String) -> Variant:
	if regime == WeaponAlphaScript.REGIME_CHIP:
		return Tokens.SIGNAL_ALERT
	if regime == WeaponAlphaScript.REGIME_BRUTE:
		return Tokens.SIGNAL_GO
	return null


func _build_alpha_readout() -> void:
	var target_parent = _rail_vbox

	_alpha_label = Label.new()
	_alpha_label.theme_type_variation = "StatLabel"
	_alpha_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	target_parent.add_child(_alpha_label)

	_alpha_head = Label.new()
	_alpha_head.theme_type_variation = "StatLabel"
	_alpha_head.add_theme_font_size_override("font_size", Tokens.FONT_MICRO)
	target_parent.add_child(_alpha_head)

	_alpha_rows.clear()
	for _i in range(DamageResolverScript.ARMOR_TABLE.size()):
		var row := Label.new()
		row.theme_type_variation = "StatLabel"
		row.add_theme_font_size_override("font_size", Tokens.FONT_MICRO)
		target_parent.add_child(row)
		_alpha_rows.append(row)


func _update_alpha_readout(wa: Dictionary) -> void:
	if _alpha_label == null:
		_build_alpha_readout()

	# Same shape as the range readout's no-weapons case, and for the same
	# reason: a hull the player has only just started has no shot to report, and
	# printing "Alpha: 0.0" against a full table of zeroes reads as a broken
	# design rather than an unfinished one.
	if not wa.get("has_weapons", false):
		_alpha_label.text = "Alpha: - (no weapons)"
		_alpha_label.tooltip_text = "Per-shot damage, once this design has an armed module fitted."
		_alpha_head.visible = false
		for row in _alpha_rows:
			row.visible = false
		return
	_alpha_head.visible = true

	var per_shot: float = float(wa.get("per_shot", 0.0))
	var interval: float = float(wa.get("interval", 0.0))
	var weapons: Array = wa.get("weapons", [])

	_alpha_label.text = "Alpha: %.1f / shot  (%.2fs)" % [per_shot, interval]
	# The tooltip is where the MECHANISM goes. The row itself has to stay a row,
	# but a player who has just noticed that dragging caliber barely moves Total
	# DPS while moving this number a lot deserves the sentence that explains why.
	_alpha_label.tooltip_text = ("What one hit is worth before armour, and the seconds between hits.\n"
		+ "Armour gates on THIS (dps*interval), never on total DPS - under threshold = 8% chip, far over (5x) = brute pierce up to 60% toward full damage.\n"
		+ "Caliber multiplies damage and interval together: total DPS barely moves, but fewer harder hits cross thresholds.\n"
		+ "Hardest of %d armed module(s): %s (%s damage).") % [
			weapons.size(), str(wa.get("hardest", "")), str(wa.get("hardest_class", ""))]

	_alpha_head.text = "Lands vs %.1f plate (defender's own plating)" % float(wa.get("reference_thickness", 1.0))
	_alpha_head.tooltip_text = ("What this design lands per second on each armour, summed across weapons. Quoted at reference thickness.\n"
		+ "Titanium (K30) stops kinetic, Ceramic (T28) stops thermal, Reactive (X30) stops explosive, Shielding (E42) stops energy.\n"
		+ "Row colour: red=CHIP (8% chip), green=BRUTE (pierce), white=through. Hover a row for per-weapon breakdown.")

	var effective: Dictionary = wa.get("effective_dps", {})
	var regimes: Dictionary = wa.get("regime", {})
	var idx := 0
	for material in effective:
		if idx >= _alpha_rows.size():
			break
		var row: Label = _alpha_rows[idx]
		idx += 1
		row.visible = true
		var regime: String = str(regimes.get(material, WeaponAlphaScript.REGIME_THROUGH))
		row.text = "%-9s %7.1f  %s" % [
			WeaponAlphaScript.short_label(material),
			float(effective[material]),
			_alpha_regime_word(regime)]
		var tint = _alpha_regime_color(regime)
		if tint == null:
			row.remove_theme_color_override("font_color")
		else:
			row.add_theme_color_override("font_color", tint)
		# The per-weapon breakdown, which is the part that cannot fit on a row.
		# Every armed module's own alpha, its own threshold against THIS material
		# (thresholds are per damage class, so a thermal round and an AP round out
		# of the same hull are answered by different numbers) and its own regime.
		var lines: Array = ["%s plate:" % WeaponAlphaScript.short_label(material)]
		for w in weapons:
			var vs: Dictionary = w.get("vs", {}).get(material, {})
			lines.append("  %s - %.1f per shot vs %.1f threshold: %s (%.1f dps, %s)" % [
				str(w.get("name", "")),
				float(w.get("per_shot", 0.0)),
				float(vs.get("threshold", 0.0)),
				_alpha_regime_word(str(vs.get("regime", ""))),
				float(vs.get("dps", 0.0)),
				str(w.get("damage_class", ""))])
		row.tooltip_text = "\n".join(lines)

	while idx < _alpha_rows.size():
		_alpha_rows[idx].visible = false
		idx += 1

# Radial positions for infographic lines (prioritize a ring around the module).
#
# These are ORDERED BY PREFERENCE, not by angle: top corners first, then high
# sides, then low sides, then bottom corners. A module usually has fewer tweaks
# than there are slots, so the early entries are the ones that get used, and
# they are the positions that read best - above and outboard of the part, where
# a leader line has clear air and nothing is hidden behind the callout.
# tweak_callout.gd may flip a direction horizontally to keep its line on the
# same side as the geometry it points at; the vertical spread here is what stops
# same-side callouts from piling up.
func _build_lifetime_stats_block() -> void:
	if _lifetime_panel != null and is_instance_valid(_lifetime_panel):
		return
	var parent = hp_label.get_parent()
	if parent == null:
		return

	_lifetime_panel = PhosphorPanelScript.new()
	_lifetime_panel.tube = PhosphorPanelScript.Tube.GREEN
	parent.add_child(_lifetime_panel)
	
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_lifetime_panel.add_child(stack)

	_lifetime_headline = Label.new()
	_lifetime_headline.theme_type_variation = "HeadingLabel"
	_lifetime_headline.add_theme_color_override("font_color", Color.WHITE)
	_lifetime_headline.text = "LIFETIME COMBAT RECORD"
	stack.add_child(_lifetime_headline)

	var rule := HSeparator.new()
	rule.add_theme_constant_override("separation", Tokens.SPACE_XS)
	stack.add_child(rule)

	_lifetime_detail = Label.new()
	_lifetime_detail.theme_type_variation = "StatLabel"
	_lifetime_detail.add_theme_color_override("font_color", Color.WHITE)
	_lifetime_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_lifetime_detail)

func _update_lifetime_stats(hull: Node3D) -> void:
	_build_lifetime_stats_block()
	if _lifetime_panel == null or not is_instance_valid(_lifetime_panel):
		return
		
	var dr = lab.get_tree().root.get_node_or_null("DesignRecord")
	if not dr:
		_lifetime_panel.visible = false
		return
		
	var bp_name = hull.get_meta("blueprint_name", "") if hull else ""
	var record = dr.get_record(bp_name)
	
	if record.is_empty() or record.get("built", 0) == 0:
		_lifetime_panel.visible = false
		return
		
	_lifetime_panel.visible = true
	
	var text = "Units Fielded: %d\n" % record.get("built", 0)
	text += "Total Kills: %d\n" % record.get("kills", 0)
	text += "Total Damage: %d\n" % record.get("damage_dealt", 0)
	text += "Credits Spent: %d" % record.get("credits_spent", 0)
	
	_lifetime_detail.text = text

func _build_verdict_block() -> void:
	if _verdict_panel != null and is_instance_valid(_verdict_panel):
		return
	var parent: Node = lab.get_node_or_null("StatsDock/ConsoleHBox/TelemetryCard/TelemetryVBox/TopMetaRow/VerdictBadge")
	if parent == null:
		parent = hp_label.get_parent() if hp_label else null
	if parent == null:
		return

	_verdict_panel = PhosphorPanelScript.new()
	_verdict_panel.tube = PhosphorPanelScript.Tube.AMBER
	_verdict_panel.custom_minimum_size = Vector2(240, 26)
	_verdict_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(_verdict_panel)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_verdict_panel.add_child(hbox)

	_verdict_headline = Label.new()
	_verdict_headline.theme_type_variation = "HeadingLabel"
	_verdict_headline.add_theme_color_override("font_color", Color.WHITE)
	hbox.add_child(_verdict_headline)

	_verdict_detail = Label.new()
	_verdict_detail.theme_type_variation = "StatLabel"
	_verdict_detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
	_verdict_detail.clip_text = true
	_verdict_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_verdict_detail)


# NOTHING HERE RE-DERIVES. `stats` is the exact analyze() result the rest of
# update_stats() already reads - DesignVerdict.evaluate() only compares and
# phrases fields already present in it. See design_verdict.gd's own header
# for why that rule is non-negotiable in this file specifically.
func _update_verdict(stats: Dictionary) -> void:
	_build_verdict_block()
	if _verdict_panel == null or not is_instance_valid(_verdict_panel):
		return
	var top: Dictionary = DesignVerdictScript.headline(stats)
	if top.is_empty():
		_verdict_panel.visible = false
		return
	_verdict_panel.visible = true
	# "!" prefix is the icon - the design_verdict.gd headline text is the
	# unprefixed label ("UNARMED", "OVER CAPACITY", ...) because the test
	# suite asserts on it verbatim, and the test's contract is the raw
	# string, not the display rendering. The prefix is added HERE so
	# the icon is a presentation concern of the rail, not a data concern
	# of the verdict evaluator. The two-space gap after the "!" keeps
	# it from merging with the first letter under the phosphor's tight
	# letter-spacing.
	_verdict_headline.text = "!  %s" % top.get("headline", "")
	_verdict_headline.add_theme_color_override(
		"font_color", DesignVerdictScript.color_for(top.get("severity", DesignVerdictScript.Severity.NOTE)))
	_verdict_detail.text = top.get("detail", "")
