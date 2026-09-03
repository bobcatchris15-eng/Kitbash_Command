class_name HUDCommandCard
extends Panel
# What is selected, and what it can be told to do.
#
# WHAT THIS REPLACES AND WHY. Three panels used to split this job between them:
# selection_panel.gd aggregated the selection into rows, context_drawer.gd wrapped
# it in a five-tab slide-up (STATUS / WEAPONS / TARGETING / MOVE / SPECIAL), and
# right_rail.gd was a fourth panel built to hold the first two because they
# overlapped the production toolboxes. That is a stack of containers deep enough
# that the header comment of right_rail.gd is mostly an explanation of which
# other panel it is avoiding.
#
# ONE PANEL, TWO PARTS: what is selected (aggregated by design, because 24 tanks
# is one fact and not 24), and the orders that apply to it. Five tabs of unit
# detail is a reference screen, and the player is not reading reference material
# while under fire - the numbers that matter mid-fight are count and health, and
# both are on the face of it.
#
# STANCE IS SHOWN, NOT JUST SET. Stance is a standing policy that outlives every
# order (see stance.gd), so it is the one piece of unit state that is invisible
# and consequential. The three stance buttons act as a radio group AND as the
# readout of what the selection is currently on - mixed selections show no
# button lit, which is itself the answer.

const Style = preload("res://scripts/hud/hud_style.gd")
const Icons = preload("res://scripts/hud/hud_icons.gd")
const Stance = preload("res://scripts/battle/orders/stance.gd")

const ROW_HEIGHT := 26
const MAX_ROWS := 5

var _director: Node = null
var _local_team: int = 0

var _title: Label = null
var _rows_box: VBoxContainer = null
var _order_row: HBoxContainer = null
var _stance_row: HBoxContainer = null
var _stance_buttons: Dictionary = {}
var _range_toggle_btn: Button = null
var _hint: Label = null

var _ability_row: HBoxContainer = null
var _barrage_btn: Button = null
var _smoke_btn: Button = null
var _beacon_btn: Button = null
var _mine_btn: Button = null
var _boost_btn: Button = null

# design_id -> {name, units, hp, max_hp}
var _groups: Dictionary = {}
var _rows: Dictionary = {}


func _init() -> void:
	name = "CommandCard"
	custom_minimum_size = Vector2(Style.CARD_WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	Style.apply_panel(self, false, Style.EDGE_BRIGHT)
	_build()


func _build() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = Style.SP_MD
	col.offset_right = -Style.SP_MD
	col.offset_top = Style.SP_SM
	col.offset_bottom = -Style.SP_SM
	col.add_theme_constant_override("separation", Style.SP_SM)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	_title = Style.heading("no selection")
	col.add_child(_title)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 2)
	_rows_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_rows_box)

	_hint = Style.label("Drag to select. Right-click to move.",
		Style.SZ_MICRO, Style.TEXT_FAINT)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_hint)

	col.add_child(Style.divider())

	_order_row = HBoxContainer.new()
	_order_row.add_theme_constant_override("separation", Style.SP_XS)
	_order_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_order_row)
	_add_order("stop", "Stop (S)", _on_stop)
	_add_order("hold", "Hold position", _on_hold)
	_add_order("attack", "Attack-move (A), then right-click a destination", _on_attack_move)
	_range_toggle_btn = _add_toggle_order("contact", "Toggle Range & Vision Indicators (F12)", _on_toggle_range_overlay)

	_ability_row = HBoxContainer.new()
	_ability_row.add_theme_constant_override("separation", Style.SP_XS)
	_ability_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_ability_row)
	_barrage_btn = _add_ability_btn("barrage", "Barrage Ground Area (B)", _on_barrage)
	_smoke_btn = _add_ability_btn("smoke", "Deploy Smoke Screen (K)", _on_smoke)
	_beacon_btn = _add_ability_btn("beacon", "Launch Recon Probe", _on_beacon)
	_mine_btn = _add_ability_btn("mine", "Deploy Proximity Mines", _on_mine)
	_boost_btn = _add_ability_btn("boost", "Rocket Booster Sprint", _on_boost)
	_ability_row.visible = false

	_stance_row = HBoxContainer.new()
	_stance_row.add_theme_constant_override("separation", Style.SP_XS)
	_stance_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_stance_row)
	_add_stance(Stance.Kind.HOLD_POSITION, "stance_hold")
	_add_stance(Stance.Kind.RETURN_FIRE, "stance_return")
	_add_stance(Stance.Kind.AGGRESSIVE, "stance_aggressive")

	_set_enabled(false)


func _add_ability_btn(icon: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, Style.HIT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = tip
	Style.style_button(b)
	Icons.on_button(b, icon, Style.TEXT)
	b.pressed.connect(handler)
	_ability_row.add_child(b)
	b.visible = false
	return b


func _add_order(icon: String, tip: String, handler: Callable) -> void:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, Style.HIT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = tip
	Style.style_button(b)
	Icons.on_button(b, icon, Style.TEXT)
	b.pressed.connect(handler)
	_order_row.add_child(b)


func _add_toggle_order(icon: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, Style.HIT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggle_mode = true
	b.tooltip_text = tip
	Style.style_button(b)
	Icons.on_button(b, icon, Style.TEXT_DIM)
	b.pressed.connect(handler)
	_order_row.add_child(b)
	return b


func _add_stance(kind: int, icon: String) -> void:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, Style.HIT)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggle_mode = true
	b.tooltip_text = Stance.label(kind).capitalize()
	Style.style_button(b)
	Icons.on_button(b, icon, Style.TEXT_DIM)
	b.pressed.connect(_on_stance.bind(kind))
	_stance_row.add_child(b)
	_stance_buttons[kind] = b


func setup(director: Node, local_team: int) -> void:
	_director = director
	_local_team = local_team
	var selection = director.selection if "selection" in director else null
	if selection != null and selection.has_signal("selection_changed"):
		selection.selection_changed.connect(update_selection)


# --- Selection --------------------------------------------------------------

func update_selection(units: Array) -> void:
	_groups.clear()
	for u in units:
		if not is_instance_valid(u) or ("is_dead" in u and u.is_dead):
			continue
		var id := _design_id(u)
		if not _groups.has(id):
			_groups[id] = {"name": _design_name(u), "units": [], "hp": 0.0, "max_hp": 0.0}
		var g: Dictionary = _groups[id]
		g["units"].append(u)
		g["hp"] += float(u.hp) if "hp" in u else 0.0
		g["max_hp"] += float(u.max_hp) if "max_hp" in u else 0.0

	var total := 0
	for id in _groups:
		total += _groups[id]["units"].size()

	if total == 0:
		_title.text = "NO SELECTION"
		_hint.visible = true
		_set_enabled(false)
	else:
		_title.text = "%d SELECTED" % total
		_hint.visible = false
		_set_enabled(true)

	_rebuild_rows()
	_refresh_stance_lamps()
	_refresh_range_lamp()

	var has_indirect := false
	var has_smoke := false
	var has_beacon := false
	var has_mine := false
	var has_boost := false
	for u in units:
		if not is_instance_valid(u) or ("is_dead" in u and u.is_dead): continue
		if u.has_method("has_boost_ability") and u.has_boost_ability(): has_boost = true
		if "hull_node" in u and is_instance_valid(u.hull_node):
			for c in u.hull_node.get_children():
				if c.has_meta("module_data"):
					var tid: String = c.get_meta("module_data").type_id
					if ModuleCatalog.is_indirect_fire(tid): has_indirect = true
					elif tid == "smoke_discharger": has_smoke = true
					elif tid == "sensor_beacon_launcher": has_beacon = true
					elif tid == "mine_layer": has_mine = true
	
	if _barrage_btn: _barrage_btn.visible = has_indirect
	if _smoke_btn: _smoke_btn.visible = has_smoke
	if _beacon_btn: _beacon_btn.visible = has_beacon
	if _mine_btn: _mine_btn.visible = has_mine
	if _boost_btn: _boost_btn.visible = has_boost
	if _ability_row:
		_ability_row.visible = has_indirect or has_smoke or has_beacon or has_mine or has_boost


func _rebuild_rows() -> void:
	# remove_child BEFORE queue_free. queue_free is deferred to the end of the
	# frame, so a plain queue_free() loop leaves the old controls parented while
	# the new ones are added - the container lays out both and the panel visibly
	# double-renders for one frame.
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	_rows.clear()

	# Biggest group first: with a mixed army the row order has to be stable
	# between frames or the thing you were about to click moves.
	var ids := _groups.keys()
	ids.sort_custom(func(a, b): return _groups[a]["units"].size() > _groups[b]["units"].size())

	for i in range(mini(ids.size(), MAX_ROWS)):
		var id: String = ids[i]
		_rows_box.add_child(_make_row(id, _groups[id]))
	if ids.size() > MAX_ROWS:
		_rows_box.add_child(Style.label("+%d more design%s" % [
			ids.size() - MAX_ROWS, "" if ids.size() - MAX_ROWS == 1 else "s"],
			Style.SZ_MICRO, Style.TEXT_FAINT))


func _make_row(design_id: String, g: Dictionary) -> Control:
	# Clickable: selecting one design out of a mixed selection is the sub-group
	# grammar the old selection panel had, and it is genuinely useful - it is how
	# you tell the artillery to hold while the tanks push.
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	b.tooltip_text = "Click to select only these"
	Style.style_button(b)
	b.pressed.connect(_on_row_pressed.bind(design_id))

	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 5
	h.offset_right = -5
	h.add_theme_constant_override("separation", Style.SP_SM)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)

	var count := Style.readout("%d" % g["units"].size(), Style.SZ_SMALL, Style.TEXT)
	count.custom_minimum_size = Vector2(22, 0)
	h.add_child(count)

	var name_lbl := Style.label(str(g["name"]).to_upper(), Style.SZ_MICRO, Style.TEXT)
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(name_lbl)

	var frac: float = 1.0 if g["max_hp"] <= 0.0 else clampf(g["hp"] / g["max_hp"], 0.0, 1.0)
	var bar := Style.bar(4, Style.health_color(frac))
	bar.value = frac
	bar.custom_minimum_size = Vector2(56, 4)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bar)

	_rows[design_id] = {"bar": bar, "count": count}
	return b


# Health only. Called per tick; no layout, no allocation.
func refresh(_delta: float) -> void:
	if _groups.is_empty():
		return
	for id in _groups:
		if not _rows.has(id):
			continue
		var g: Dictionary = _groups[id]
		var hp := 0.0
		var max_hp := 0.0
		var alive := 0
		for u in g["units"]:
			if not is_instance_valid(u) or ("is_dead" in u and u.is_dead):
				continue
			alive += 1
			hp += float(u.hp) if "hp" in u else 0.0
			max_hp += float(u.max_hp) if "max_hp" in u else 0.0
		var frac: float = 1.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
		var bar: ProgressBar = _rows[id]["bar"]
		bar.value = frac
		bar.add_theme_stylebox_override("fill", Style.fill_box(Style.health_color(frac), 0))
		_rows[id]["count"].text = str(alive)


func _refresh_stance_lamps() -> void:
	# Lit only when the whole selection agrees. A mixed selection showing one
	# stance lit would be a lie, and showing all three lit would be noise.
	var seen := -1
	var mixed := false
	for id in _groups:
		for u in _groups[id]["units"]:
			if not is_instance_valid(u) or not ("stance" in u):
				continue
			if seen == -1:
				seen = int(u.stance)
			elif int(u.stance) != seen:
				mixed = true
	for kind in _stance_buttons:
		var lit: bool = not mixed and kind == seen
		var b: Button = _stance_buttons[kind]
		b.set_pressed_no_signal(lit)
		b.add_theme_color_override("icon_normal_color",
			Style.TEAM_FRIENDLY if lit else Style.TEXT_DIM)


func _refresh_range_lamp() -> void:
	if _range_toggle_btn == null:
		return
	var sel: Array = _selected()
	if sel.is_empty():
		_range_toggle_btn.set_pressed_no_signal(false)
		_range_toggle_btn.add_theme_color_override("icon_normal_color", Style.TEXT_DIM)
		return
	var any_on: bool = false
	for u in sel:
		if is_instance_valid(u) and ("show_range_overlay" in u) and u.show_range_overlay:
			any_on = true
			break
	_range_toggle_btn.set_pressed_no_signal(any_on)
	_range_toggle_btn.add_theme_color_override("icon_normal_color",
		Style.TEAM_FRIENDLY if any_on else Style.TEXT_DIM)


func _set_enabled(on: bool) -> void:
	for b in _order_row.get_children():
		b.disabled = not on
	for b in _stance_row.get_children():
		b.disabled = not on
	if _ability_row:
		for b in _ability_row.get_children():
			b.disabled = not on


# --- Handlers ---------------------------------------------------------------

func _selected() -> Array:
	if _director == null or _director.selection == null:
		return []
	return _director.selection.selected


func _on_stop() -> void:
	if _director != null and _director.orders != null:
		_director.orders.stop(_selected())


func _on_hold() -> void:
	if _director != null and _director.orders != null:
		_director.orders.hold(_selected())


func _on_attack_move() -> void:
	# Arms the same cursor mode the A hotkey does, rather than issuing anything -
	# an attack-move needs a destination, and the destination comes from the next
	# right-click in the world.
	if _director != null and _director.has_method("_set_armed"):
		_director._set_armed(true)


func _on_toggle_range_overlay() -> void:
	var sel: Array = _selected()
	if sel.is_empty():
		return
	var first = sel[0]
	var new_value: bool = not (("show_range_overlay" in first) and first.show_range_overlay)
	for u in sel:
		if is_instance_valid(u) and "set_range_overlay_visible" in u:
			u.set_range_overlay_visible(new_value)
	_refresh_range_lamp()


func _on_stance(kind: int) -> void:
	if _director != null and _director.orders != null:
		_director.orders.set_stance(_selected(), kind)
	_refresh_stance_lamps()


func _on_row_pressed(design_id: String) -> void:
	if not _groups.has(design_id) or _director == null or _director.selection == null:
		return
	var live: Array = []
	for u in _groups[design_id]["units"]:
		if is_instance_valid(u) and not ("is_dead" in u and u.is_dead):
			live.append(u)
	if not live.is_empty():
		_director.selection.set_selection(live)


func _on_barrage() -> void:
	if _director and _director.has_method("arm_barrage"): _director.arm_barrage(true)


func _on_smoke() -> void:
	if _director and _director.has_method("arm_smoke"): _director.arm_smoke(true)


func _on_beacon() -> void:
	if _director and _director.has_method("arm_sensor_beacon"): _director.arm_sensor_beacon(true)


func _on_mine() -> void:
	if _director and _director.has_method("arm_mine"): _director.arm_mine(true)


func _on_boost() -> void:
	if _director and _director.has_method("trigger_boost"): _director.trigger_boost()


# --- Identity ---------------------------------------------------------------
# Kept in the same shape selection_panel.gd used, because units are tagged
# inconsistently: some carry a blueprint_id meta, some a property, some neither.

func _design_id(unit: Node) -> String:
	if unit.has_meta("blueprint_id"):
		return String(unit.get_meta("blueprint_id"))
	if "blueprint_id" in unit and unit.blueprint_id != "":
		return String(unit.blueprint_id)
	if unit.has_meta("design_id"):
		return String(unit.get_meta("design_id"))
	if "blueprint" in unit and unit.blueprint is Dictionary:
		var n = unit.blueprint.get("name", "")
		if n != "":
			return String(n)
	return unit.name


func _design_name(unit: Node) -> String:
	if unit.has_meta("blueprint_name"):
		return String(unit.get_meta("blueprint_name"))
	if "blueprint_name" in unit and unit.blueprint_name != "":
		return String(unit.blueprint_name)
	if "blueprint" in unit and unit.blueprint is Dictionary:
		var n = unit.blueprint.get("name", "")
		if n != "":
			return String(n)
	return _design_id(unit).capitalize()
