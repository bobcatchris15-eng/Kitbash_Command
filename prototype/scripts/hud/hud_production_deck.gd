class_name HUDProductionDeck
extends Panel
# The five production queues, in one panel, behind five tabs.
#
# WHAT THIS REPLACES AND WHY. Two separate production interfaces used to be on
# screen simultaneously: production_hud.gd built five accordion toolboxes along
# the bottom edge, and command_console.gd built a ProductionTabBar plus a
# ProductionDrawer that did the same job again. Both read and wrote the same
# ProductionService, so they were never out of sync with the simulation - but
# they were out of sync with each other, and the player had two places to look
# for one answer.
#
# TABS, NOT FIVE ACCORDIONS. Five independently-collapsible toolboxes means five
# open/closed states and no single home for "what am I building". Opening one
# told you nothing about the other four, so reading the whole economy meant five
# clicks. One panel with five tabs has ONE state, and - the part that actually
# matters - each tab header carries its own depth badge and a progress bar of its
# head job, so all five queues are readable at a glance without opening any of
# them. The tab you have open is for acting; the tab strip is for knowing.
#
# QUEUE PER FACTORY TYPE, NOT PER FACTORY. This mirrors BuildingCatalog.QUEUES
# exactly: one global line per type, per team, and every live contributing
# structure speeds that one line up. That is a simulation decision, not a UI one
# (see building_catalog.gd), so the deck shows the contributor count and the
# resulting speed multiplier rather than pretending each building has its own
# queue.
#
# THE STATE LIVES IN ProductionService. Nothing here caches what is queued. The
# old build bar kept a parallel idea of the queue and the two drifted whenever a
# factory died mid-build.

const Style = preload("res://scripts/hud/hud_style.gd")
const Icons = preload("res://scripts/hud/hud_icons.gd")
const BuildingCatalog = preload("res://scripts/battle/economy/building_catalog.gd")
const DesignCosting = preload("res://scripts/battle/economy/design_costing.gd")
const ProductionService = preload("res://scripts/battle/economy/production_service.gd")
const ResourceCatalog = preload("res://scripts/battle/economy/resource_catalog.gd")

const QUEUE_LABELS := {
	"light": "LIGHT",
	"medium": "MEDIUM",
	"heavy": "HEAVY",
	"building": "STRUCTURES",
	"defense": "DEFENCE",
}

const QUEUE_ICONS := {
	"light": "tier_light",
	"medium": "tier_medium",
	"heavy": "tier_heavy",
	"building": "structures",
	"defense": "defence",
}

# Sized so the palette gets TWO rows of cards inside the band rather than one.
# The band is 224 px; the fixed furniture above the palette (tabs, context line,
# queue strip, two dividers, separations, margins) comes to ~126, which leaves
# ~98 - two 46 px card rows. Growing any of these numbers costs a card row.
const TAB_HEIGHT := 32
const CHIP_WIDTH := 74.0
const CHIP_HEIGHT := 36.0
# How many queued jobs get a chip. Past this the strip stops growing and the
# depth badge on the tab carries the rest - a 40-deep queue must not be allowed
# to lay out 40 controls every time it changes.
const MAX_CHIPS := 10

# Tab width is FIXED, not a share of the deck. At 2669 px wide the deck is
# ~2093 px, and five expanding tabs came out 418 px each - a 20 px icon at the
# far left with a centred label a long way from it, which reads as five empty
# bars rather than five buttons. Fixed width keeps a tab looking like a tab at
# any resolution, and the space it gives back goes to the palette.
const TAB_WIDTH := 148.0

# 148, not 124: MEDIUM MANUFACTORY clipped to "MEDIUM MANUFACTOI" at 124, and a
# silently truncated build option is worse than a smaller grid.
const CARD_WIDTH := 148.0
const CARD_HEIGHT := 46.0

var _director: Node = null
var _local_team: int = 0
var _active: String = "light"

var _tab_row: HBoxContainer = null
var _tabs: Dictionary = {}          # queue -> {button, badge, bar}
var _contrib_label: Label = null
var _speed_label: Label = null
var _strip: HBoxContainer = null
var _palette: HFlowContainer = null
var _palette_scroll: ScrollContainer = null
var _empty_hint: Label = null

# Every palette card with the item it was built from, so a tech gate that opens
# or closes mid-match can be re-evaluated without rebuilding the whole palette.
var _cards: Array = []


func _init() -> void:
	name = "ProductionDeck"
	mouse_filter = Control.MOUSE_FILTER_STOP
	Style.apply_panel(self, false, Style.EDGE_BRIGHT)
	_build()


func _build() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = Style.SP_SM
	col.offset_right = -Style.SP_SM
	col.offset_top = Style.SP_SM
	col.offset_bottom = -Style.SP_SM
	col.add_theme_constant_override("separation", Style.SP_SM)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	# --- Tab strip ---
	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", Style.SP_XS)
	_tab_row.custom_minimum_size = Vector2(0, TAB_HEIGHT)
	_tab_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_tab_row)
	for q in BuildingCatalog.QUEUES:
		_tab_row.add_child(_make_tab(q))

	col.add_child(Style.divider())

	# --- Context line: what feeds this queue and how fast ---
	var ctx := HBoxContainer.new()
	ctx.add_theme_constant_override("separation", Style.SP_SM)
	ctx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(ctx)
	_contrib_label = Style.label("", Style.SZ_MICRO, Style.TEXT_DIM)
	ctx.add_child(_contrib_label)
	_speed_label = Style.label("", Style.SZ_MICRO, Style.OK, true)
	ctx.add_child(_speed_label)

	# --- Live queue strip ---
	_strip = HBoxContainer.new()
	_strip.add_theme_constant_override("separation", Style.SP_XS)
	_strip.custom_minimum_size = Vector2(0, CHIP_HEIGHT)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_strip)

	col.add_child(Style.divider())

	# --- Build palette ---
	_palette_scroll = ScrollContainer.new()
	_palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(_palette_scroll)

	_palette = HFlowContainer.new()
	_palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette.add_theme_constant_override("h_separation", Style.SP_XS)
	_palette.add_theme_constant_override("v_separation", Style.SP_XS)
	_palette_scroll.add_child(_palette)

	_empty_hint = Style.label("", Style.SZ_SMALL, Style.TEXT_FAINT)
	_empty_hint.visible = false
	col.add_child(_empty_hint)


# --- Tabs -------------------------------------------------------------------

func _make_tab(queue_name: String) -> Control:
	# A Button with three IGNORE-filter children on top of it. The alternative -
	# a Control that draws its own states - would have to reimplement hover and
	# press, and the whole point of hud_style is that there is one button look.
	var b := Button.new()
	b.name = "Tab_%s" % queue_name
	b.text = QUEUE_LABELS[queue_name]
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.custom_minimum_size = Vector2(TAB_WIDTH, TAB_HEIGHT)
	b.clip_text = true
	Style.style_button(b)
	Icons.on_button(b, QUEUE_ICONS[queue_name], Style.TEXT_DIM)
	b.pressed.connect(_on_tab_pressed.bind(queue_name))

	# Depth badge. Top-right so it never collides with the icon on the left.
	var badge := Style.readout("", Style.SZ_MICRO, Style.WARN)
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -22
	badge.offset_right = -4
	badge.offset_top = 2
	badge.offset_bottom = 14
	b.add_child(badge)

	# Head-job progress, along the very bottom edge of the tab. This is the
	# reason the tab strip is worth having: five of these means the player can
	# see all five lines advancing without opening anything.
	var bar := Style.bar(2, Style.TEAM_FRIENDLY, Color(0, 0, 0, 0))
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_left = 2
	bar.offset_right = -2
	bar.offset_top = -3
	bar.offset_bottom = -1
	b.add_child(bar)

	_tabs[queue_name] = {"button": b, "badge": badge, "bar": bar}
	return b


func _on_tab_pressed(queue_name: String) -> void:
	set_active(queue_name)


func set_active(queue_name: String) -> void:
	if not _tabs.has(queue_name):
		return
	_active = queue_name
	for q in _tabs:
		var pressed: bool = q == queue_name
		_tabs[q]["button"].set_pressed_no_signal(pressed)
		_tabs[q]["button"].add_theme_color_override("icon_normal_color",
			Style.TEAM_FRIENDLY if pressed else Style.TEXT_DIM)
	_rebuild_palette()
	_refresh_strip()
	_refresh_context()


# Cycles to the next tab. Bound to the build hotkey so the keyboard can reach
# every queue without the mouse.
func cycle(step: int) -> void:
	var qs := BuildingCatalog.QUEUES
	var i := qs.find(_active)
	set_active(qs[posmod(i + step, qs.size())])


func active_queue() -> String:
	return _active


# --- Setup ------------------------------------------------------------------

func setup(director: Node, local_team: int) -> void:
	_director = director
	_local_team = local_team
	var production = director.production if "production" in director else null
	if production != null and production.has_signal("queue_changed"):
		production.queue_changed.connect(_on_queue_changed)
	# A structure going up or down changes contributor counts AND opens or
	# closes tech gates, both of which are visible in this panel. Signal rather
	# than poll because the throttled refresh below would leave up to a quarter
	# second of stale UI between "lab finished" and "button lights up", which is
	# exactly the lag a playtest reads as a broken button.
	if director.has_signal("structure_built"):
		director.structure_built.connect(_on_structures_changed)
	if director.has_signal("structure_lost"):
		director.structure_lost.connect(_on_structures_changed)
	set_active(_active)


func _on_queue_changed(team: int, queue_name: String) -> void:
	if team != _local_team:
		return
	_refresh_tab(queue_name)
	if queue_name == _active:
		_refresh_strip()
		_refresh_context()


func _on_structures_changed(team: int, _kind: String) -> void:
	if team != _local_team:
		return
	_refresh_context()
	_re_evaluate_gates()


# --- Per-tick ---------------------------------------------------------------
# Only the progress readouts. Everything structural is signal-driven, so this
# does no allocation and touches no layout.
func refresh(_delta: float) -> void:
	if _director == null or _director.production == null:
		return
	for q in _tabs:
		var st: Dictionary = _director.production.status(_local_team, q)
		var bar: ProgressBar = _tabs[q]["bar"]
		bar.value = st.get("progress", 0.0)
		bar.visible = not st.get("empty", true)
		var badge: Label = _tabs[q]["badge"]
		var depth: int = st.get("depth", 0)
		badge.text = str(depth) if depth > 0 else ""
		if st.get("stalled", false):
			badge.add_theme_color_override("font_color", Style.BAD)
			bar.add_theme_stylebox_override("fill", Style.fill_box(Style.BAD, 0))
		elif st.get("done", false):
			badge.add_theme_color_override("font_color", Style.OK)
			bar.add_theme_stylebox_override("fill", Style.fill_box(Style.OK, 0))
		else:
			badge.add_theme_color_override("font_color", Style.WARN)
			bar.add_theme_stylebox_override("fill", Style.fill_box(Style.TEAM_FRIENDLY, 0))
	_refresh_chip_progress()
	_refresh_affordability()


func _refresh_tab(queue_name: String) -> void:
	if not _tabs.has(queue_name) or _director == null:
		return
	var st: Dictionary = _director.production.status(_local_team, queue_name)
	var depth: int = st.get("depth", 0)
	_tabs[queue_name]["badge"].text = str(depth) if depth > 0 else ""


# --- Context line -----------------------------------------------------------

func _refresh_context() -> void:
	if _director == null or _director.production == null:
		return
	var n: int = _director.production.contributor_count(_local_team, _active)
	var kinds: Array = BuildingCatalog.contributors_for(_active)
	var kind_name := "structure"
	if not kinds.is_empty():
		kind_name = str(kinds[0]).replace("_", " ")

	if n <= 0:
		_contrib_label.text = "NO %s - THIS QUEUE CANNOT BUILD" % kind_name.to_upper()
		_contrib_label.add_theme_color_override("font_color", Style.BAD)
		_speed_label.text = ""
		return

	_contrib_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	# "2 x LIGHT MANUFACTORY", not "2 light manufactorys". The kind comes straight
	# off a BuildingCatalog key, so there is no correct English plural to reach for
	# and "hq" lowercased read as a typo.
	_contrib_label.text = "%d x %s feeding this line" % [n, kind_name.to_upper()]
	# The speed table is latched at enqueue (see production_service._make_job),
	# so this is what the NEXT job will be quoted, not what the current one is
	# running at. Labelled that way on purpose.
	var idx: int = clampi(n - 1, 0, ProductionService.SPEED_PCT.size() - 1)
	var pct: int = ProductionService.SPEED_PCT[idx]
	_speed_label.text = "next job at %d%% time" % pct
	_speed_label.add_theme_color_override("font_color",
		Style.OK if pct < 100 else Style.TEXT_DIM)


# --- Queue strip ------------------------------------------------------------

func _refresh_strip() -> void:
	# remove_child BEFORE queue_free. queue_free is deferred to the end of the
	# frame, so a plain queue_free() loop leaves the old controls parented while
	# the new ones are added - the container lays out both and the panel visibly
	# double-renders for one frame.
	for c in _strip.get_children():
		_strip.remove_child(c)
		c.queue_free()
	if _director == null or _director.production == null:
		return
	var jobs: Array = _director.production.queue(_local_team, _active)
	if jobs.is_empty():
		var idle := Style.label("QUEUE EMPTY", Style.SZ_MICRO, Style.TEXT_FAINT)
		_strip.add_child(idle)
		return
	for i in range(mini(jobs.size(), MAX_CHIPS)):
		_strip.add_child(_make_chip(jobs[i], i))
	if jobs.size() > MAX_CHIPS:
		_strip.add_child(Style.label("+%d" % (jobs.size() - MAX_CHIPS),
			Style.SZ_SMALL, Style.TEXT_DIM, true))


func _make_chip(job: Dictionary, index: int) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(CHIP_WIDTH, CHIP_HEIGHT)
	b.tooltip_text = "%s\nClick to cancel (refunds what has been paid so far)" % str(
		job.get("label", ""))
	Style.style_button(b)
	b.pressed.connect(_on_chip_pressed.bind(index))

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 4
	v.offset_right = -4
	v.offset_top = 3
	v.offset_bottom = -3
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)

	var name_lbl := Style.label(str(job.get("label", "")).to_upper(),
		Style.SZ_MICRO, Style.TEXT)
	name_lbl.clip_text = true
	v.add_child(name_lbl)

	var bar := Style.bar(3, Style.TEAM_FRIENDLY)
	v.add_child(bar)

	var eta := Style.readout("", Style.SZ_MICRO, Style.TEXT_DIM)
	eta.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	v.add_child(eta)

	# The chip keeps a reference to the live job dictionary rather than a copy of
	# its numbers, so the per-tick progress update is a read, not a search.
	b.set_meta("job", job)
	b.set_meta("bar", bar)
	b.set_meta("eta", eta)
	return b


func _refresh_chip_progress() -> void:
	for c in _strip.get_children():
		if not (c is Button) or not c.has_meta("job"):
			continue
		var job: Dictionary = c.get_meta("job")
		var bar: ProgressBar = c.get_meta("bar")
		var eta: Label = c.get_meta("eta")
		var total: float = maxf(float(job.get("total_time", 1.0)), 0.001)
		var left: float = float(job.get("time_left", 0.0))
		bar.value = clampf(1.0 - left / total, 0.0, 1.0)
		if job.get("done", false):
			eta.text = "READY"
			eta.add_theme_color_override("font_color", Style.OK)
			bar.add_theme_stylebox_override("fill", Style.fill_box(Style.OK, 0))
		elif job.get("stalled", false):
			# Stalled means the drip-feed has no money to draw. Saying WAIT and
			# nothing else is what made this state read as a hang; this says why.
			eta.text = "NO FUNDS"
			eta.add_theme_color_override("font_color", Style.BAD)
			bar.add_theme_stylebox_override("fill", Style.fill_box(Style.BAD, 0))
		elif job.get("paused", false):
			eta.text = "HELD"
			eta.add_theme_color_override("font_color", Style.WARN)
		else:
			eta.text = "%ds" % int(ceil(left))
			eta.add_theme_color_override("font_color", Style.TEXT_DIM)


func _on_chip_pressed(index: int) -> void:
	if _director == null or _director.production == null:
		return
	# A finished structure at the head of the line is waiting to be sited, not
	# waiting to be cancelled - clicking it should resume placement, which is
	# the action the player actually wants and the one the old HUD had no button
	# for at all.
	var jobs: Array = _director.production.queue(_local_team, _active)
	if index < jobs.size() and jobs[index].get("done", false) \
			and jobs[index].get("is_structure", false) and index == 0:
		if _director.has_method("resume_placement"):
			_director.resume_placement(_active)
		return
	_director.production.cancel(_local_team, _active, index)


# --- Build palette ----------------------------------------------------------

func _rebuild_palette() -> void:
	for c in _palette.get_children():
		_palette.remove_child(c)
		c.queue_free()
	_cards.clear()
	if _director == null:
		return
	var items := _items_for(_active)
	_empty_hint.visible = items.is_empty()
	if items.is_empty():
		_empty_hint.text = _empty_reason(_active)
		return
	# No live contributor means nothing in this palette can be ordered at all -
	# ProductionService.enqueue_* refuses at the door. Without this the cards
	# looked available and a click produced only a flash message, which reads as a
	# broken button rather than as a missing building.
	var kinds: Array = BuildingCatalog.contributors_for(_active)
	var no_contributor: bool = _director.production != null 		and _director.production.contributor_count(_local_team, _active) <= 0
	var gate_reason := ""
	if no_contributor and not kinds.is_empty():
		gate_reason = "Needs a %s" % str(kinds[0]).replace("_", " ")
	for item in items:
		var card := _make_card(item)
		if no_contributor:
			card.disabled = true
			card.tooltip_text = gate_reason
			# modulate, not just `disabled`. The disabled StyleBox differs from
			# normal only by PANEL vs PANEL_RAISE - about 3% luminance - so a
			# palette that cannot be ordered from looked identical to one that
			# could. Dimming the whole card is unambiguous at a glance.
			card.modulate = Color(1, 1, 1, 0.42)
		_palette.add_child(card)
		_cards.append({"card": card, "item": item})


func _empty_reason(queue_name: String) -> String:
	match queue_name:
		"defense":
			return "No defence designs saved. Build a foundation-hull design in the Design Lab."
		"building":
			return "No structures available."
		_:
			return "No %s-weight designs saved. Anything you design lands in the tier its hull weight puts it in." % QUEUE_LABELS[queue_name].to_lower()


func _items_for(queue_name: String) -> Array:
	var out: Array = []
	if queue_name == BuildingCatalog.QUEUE_BUILDING:
		for kind in BuildingCatalog.buildable_kinds():
			out.append({
				"kind": kind,
				"label": str(kind).replace("_", " ").to_upper(),
				# Through ResourceCatalog, not an inlined "crystal is worth 2":
				# CRYSTAL_TO_CREDITS lives there and this must not become a
				# second copy of it.
				"cost": ResourceCatalog.credits_from_materials(Vector2i(
					int(BuildingCatalog.get_stat(kind, "cost_metal", 0)),
					int(BuildingCatalog.get_stat(kind, "cost_crystal", 0)))),
				"time": BuildingCatalog.get_stat(kind, "build_time", 10.0),
				"structure": true,
				"missing": [],
			})
		return out

	var want_defence: bool = queue_name == BuildingCatalog.QUEUE_DEFENSE
	for slot in range(_director.roster.size()):
		var design: Dictionary = _director.roster[slot]
		var is_def: bool = _director.is_defence_design(design)
		if is_def != want_defence:
			continue
		if not want_defence and DesignCosting.queue_for_design(design) != queue_name:
			continue
		var cost: int = DesignCosting.blueprint_cost(design)
		out.append({
			"blueprint": design,
			"kind": "defense" if want_defence else "",
			"slot": slot,
			"label": str(design.get("name", "DESIGN")).to_upper(),
			"cost": cost,
			"time": DesignCosting.build_time_for_cost(cost),
			"structure": want_defence,
			"missing": _director.production.missing_required_buildings(_local_team, design),
		})
	return out


func _make_card(item: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	Style.style_button(b)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 6
	v.offset_right = -6
	v.offset_top = 4
	v.offset_bottom = -4
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)

	var name_lbl := Style.label(str(item["label"]), Style.SZ_SMALL, Style.TEXT)
	# Ellipsis rather than a hard clip, so a name that still does not fit reads as
	# truncated instead of as a different word.
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(name_lbl)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", Style.SP_SM)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(meta)
	var cost_lbl := Style.label("%d cr" % int(item["cost"]), Style.SZ_MICRO, Style.TEXT_DIM, true)
	meta.add_child(cost_lbl)
	meta.add_child(Style.label("%ds" % int(item["time"]), Style.SZ_MICRO, Style.TEXT_FAINT, true))

	b.set_meta("cost_label", cost_lbl)
	b.set_meta("cost", int(item["cost"]))

	var missing: Array = item.get("missing", [])
	if not missing.is_empty():
		b.disabled = true
		b.modulate = Color(1, 1, 1, 0.55)
		var names: Array = []
		for k in missing:
			names.append(str(k).replace("_", " ").capitalize())
		b.tooltip_text = "Requires: %s" % ", ".join(names)
		v.add_child(Style.label("LOCKED", Style.SZ_MICRO, Style.BAD))
	else:
		b.tooltip_text = "%s\n%d credits, %ds\nClick to queue one, Shift+Click for five" % [
			str(item["label"]), int(item["cost"]), int(item["time"])]
		b.pressed.connect(_on_card_pressed.bind(item))
	return b


# Recolours the cost on every card by whether the player can currently pay it.
# Cheap enough to run per tick: a dictionary read and a colour override per card,
# no layout and no allocation.
func _refresh_affordability() -> void:
	if _director == null or _director.economy == null:
		return
	var credits: int = _director.economy.credits(_local_team)
	for entry in _cards:
		var card: Button = entry["card"]
		if not is_instance_valid(card) or card.disabled:
			continue
		var lbl: Label = card.get_meta("cost_label")
		var cost: int = card.get_meta("cost")
		lbl.add_theme_color_override("font_color",
			Style.TEXT_DIM if credits >= cost else Style.BAD)


# Re-runs the tech-tree gate for every card. The gate was correct when the card
# was built; a lab finished or destroyed since then makes it stale, and a
# disabled button that should be live is indistinguishable from a broken one.
func _re_evaluate_gates() -> void:
	if _director == null or _director.production == null:
		return
	var needs_rebuild := false
	for entry in _cards:
		var card: Button = entry["card"]
		if not is_instance_valid(card):
			continue
		var item: Dictionary = entry["item"]
		var bp: Dictionary = item.get("blueprint", {})
		if bp.is_empty():
			continue
		var missing: Array = _director.production.missing_required_buildings(_local_team, bp)
		if missing.is_empty() == card.disabled:
			# The gate flipped. The card carries a LOCKED row and a connected or
			# disconnected signal, so it has to be rebuilt rather than just
			# re-enabled.
			needs_rebuild = true
			break
	if needs_rebuild:
		_rebuild_palette()


func _on_card_pressed(item: Dictionary) -> void:
	var count := 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	for _i in range(count):
		_enqueue_one(item)


func _enqueue_one(item: Dictionary) -> void:
	if _director == null:
		return
	if item.get("structure", false):
		# Structures and defences are sited before they are paid for, so the
		# player picks the spot first and the job only enters the queue once the
		# ghost is confirmed. match_director owns that whole lifecycle.
		_director.start_building_placement(_active, item)
		return
	_director.production.enqueue_unit(
		_local_team, item["blueprint"], int(item["cost"]),
		float(item["time"]), _active, int(item.get("slot", -1)))
