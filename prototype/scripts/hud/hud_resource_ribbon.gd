class_name HUDResourceRibbon
extends Panel
# Top-left standing readout: credits, income, power, army size, match clock.
#
# ONE CREDIT POOL, NOT TWO. The old desk bar and the project docs both describe
# "metal and crystal" as separate stocks; EconomyService has never worked that
# way. It keeps a single credit ledger per team (economy_service.gd credits()),
# and the four resource types in ResourceCatalog differ only in credits-per-unit
# and where they sit on the map. Showing two stock numbers meant showing one real
# number and one invented one, so this shows the pool and the rate that feeds it.
#
# WHY A RIBBON AND NOT A BAR. This is the only always-on chrome above the bottom
# band, so it is deliberately one line tall and hugs the corner: it has to be
# glanceable without eating viewport. Everything that needs more room than one
# line belongs in the bottom band.

const Style = preload("res://scripts/hud/hud_style.gd")
const Icons = preload("res://scripts/hud/hud_icons.gd")

# 4 Hz. Fast enough that a purchase feels instant, slow enough that the digits
# are readable rather than a blur during harvesting.
const REFRESH_PERIOD := 0.25

var _director: Node = null
var _local_team: int = 0

var _credits: Label = null
var _income: Label = null
var _power: Label = null
var _power_bar: ProgressBar = null
var _army: Label = null
var _clock: Label = null

var _accum: float = 0.0
var _elapsed: float = 0.0


func _init() -> void:
	name = "ResourceRibbon"
	custom_minimum_size = Vector2(0, Style.RIBBON_HEIGHT)
	# STOP so a click on the ribbon does not fall through and issue a move order
	# to the world underneath it.
	mouse_filter = Control.MOUSE_FILTER_STOP
	Style.apply_panel(self, false, Style.EDGE_BRIGHT)
	_build()


func _build() -> void:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = Style.SP_MD
	row.offset_right = -Style.SP_MD
	row.add_theme_constant_override("separation", Style.SP_MD)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	row.add_child(Icons.rect("metal", 16, Style.METAL))
	_credits = Style.readout("0", Style.SZ_HEAD, Style.TEXT)
	_credits.custom_minimum_size = Vector2(64, 0)
	row.add_child(_credits)

	row.add_child(Icons.rect("income", 14, Style.OK))
	_income = Style.readout("0.0/s", Style.SZ_HEAD, Style.TEXT_DIM)
	_income.custom_minimum_size = Vector2(64, 0)
	row.add_child(_income)

	row.add_child(Style.divider(true))

	row.add_child(Icons.rect("power", 16, Style.POWER))
	# The bar and the number together, because either alone answers half the
	# question: the number says how close to the ceiling, the bar says it at a
	# glance without reading.
	var power_col := VBoxContainer.new()
	power_col.custom_minimum_size = Vector2(88, 0)
	power_col.add_theme_constant_override("separation", 1)
	power_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	power_col.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(power_col)
	_power = Style.readout("0 / 0", Style.SZ_HEAD, Style.TEXT_DIM)
	_power.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	power_col.add_child(_power)
	_power_bar = Style.bar(3, Style.POWER)
	power_col.add_child(_power_bar)

	row.add_child(Style.divider(true))

	row.add_child(Style.heading("army"))
	_army = Style.readout("0", Style.SZ_HEAD, Style.TEXT)
	# 20, not 32: right-aligned in a 32 px box left the count sitting a visible gap
	# away from its own ARMY label.
	_army.custom_minimum_size = Vector2(20, 0)
	row.add_child(_army)

	row.add_child(Style.divider(true))

	_clock = Style.readout("0:00", Style.SZ_HEAD, Style.TEXT_DIM)
	_clock.custom_minimum_size = Vector2(44, 0)
	row.add_child(_clock)


func setup(director: Node, local_team: int) -> void:
	_director = director
	_local_team = local_team
	var economy = director.economy if "economy" in director else null
	# Signal-driven for the stock, throttled polling for the rates. A credit
	# total that lags a purchase by up to 250 ms reads as an unresponsive HUD;
	# an income rate that does is invisible.
	if economy != null and economy.has_signal("resources_changed"):
		economy.resources_changed.connect(_on_resources_changed)
	_refresh()


func _on_resources_changed(team: int) -> void:
	if team == _local_team:
		_refresh_credits()


func refresh(delta: float) -> void:
	_elapsed += delta
	_accum += delta
	if _accum < REFRESH_PERIOD:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	_refresh_credits()
	_refresh_power()
	_refresh_army()
	_clock.text = "%d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60]


func _refresh_credits() -> void:
	if _director == null or _director.economy == null:
		return
	_credits.text = str(_director.economy.credits(_local_team))
	var rate: float = _director.economy.income_rate(_local_team)
	_income.text = "%.1f/s" % rate
	_income.add_theme_color_override("font_color",
		Style.TEXT_DIM if rate > 0.0 else Style.WARN)


func _refresh_power() -> void:
	if _director == null or _director.economy == null:
		return
	var cap: float = _director.economy.power_capacity(_local_team)
	var draw: float = _director.economy.power_draw(_local_team)
	_power.text = "%d / %d" % [int(draw), int(cap)]
	_power_bar.value = 0.0 if cap <= 0.0 else clampf(draw / cap, 0.0, 1.0)
	# Brownout is a real mechanic (economy_service.is_low_power gates production
	# and energy weapons), so it gets the warning colour rather than just a full
	# bar the player has to interpret.
	var low: bool = _director.economy.is_low_power(_local_team)
	var c: Color = Style.BAD if low else Style.POWER
	_power_bar.add_theme_stylebox_override("fill", Style.fill_box(c, 0))
	_power.add_theme_color_override("font_color", Style.BAD if low else Style.TEXT_DIM)


func _refresh_army() -> void:
	if _director == null or not _director.has_method("get_team_units"):
		return
	_army.text = str(_director.get_team_units(_local_team).size())
