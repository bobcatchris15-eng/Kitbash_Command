class_name AdminMenu
extends Control
# The session menu: pause, and the ways out of a match.
#
# WHERE IT SITS, AND WHY THAT CHANGED. It used to be a chamfered bakelite plate
# pinned at `TOP_OFFSET = 64 + 180 + 20` down the right-hand edge of the
# viewport - a hard-coded number derived from the OLD minimap, which was a 180 px
# square in the top-right corner. The minimap is now a 224 px square in the
# bottom-left, so that offset left a MENU plate floating unattached in the middle
# of the right-hand side of the screen with nothing above or below it.
#
# It is now anchored to the top-right of HUDRoot's column (see
# HUDRoot.attach_to_column), which means it shares the centred, width-capped
# layout with every other region and sits directly above the alert log - which
# reserves HUDRoot.MENU_STRIP_HEIGHT for exactly this.
#
# THE CHROME IS hud_style.gd NOW, not ToolboxPlate + StampedLabel. Those generate
# a chamfered metal plate and enamel lettering at runtime; the in-match HUD
# deliberately does not use them (see hud_style.gd's header). A single panel in
# the out-of-match language sitting on an otherwise flat HUD read as a leftover
# from a different game, which is precisely what it was.
#
# OPENING IT PAUSES. That is the normal contract for a menu in a real-time game
# and the reason to have it at all: the alternative is a player reading a list of
# options while their base is under attack. Closing it resumes, and so does
# Escape - the same key that already backs out of placement and selection.
#
# PAUSING IS get_tree().paused, WHICH STOPS THIS NODE TOO unless it opts out.
# Both this menu and SceneRouter's fade overlay run with PROCESS_MODE_ALWAYS,
# because a pause menu that freezes itself cannot be dismissed and a transition
# started from one would hang halfway through its fade.
#
# SAVE AND LOAD ARE PRESENT AND DISABLED. There is no save system in this project
# - not in the battle layer, not in the old runtime, nowhere - so there is
# nothing for them to call. They are shown greyed with a reason rather than
# omitted, because "can I save?" is a question the player will ask on their own
# and an empty menu answers it worse than a disabled row does.

const Style = preload("res://scripts/hud/hud_style.gd")

signal main_menu_requested
signal quit_requested

const WIDTH := 168.0
# Matches HUDRoot.MENU_STRIP_HEIGHT. The alert log below is positioned off that
# constant, so the two must agree or they overlap or leave a gap.
const HEADER_HEIGHT := 28.0
const ROW_HEIGHT := 30.0

var _header: Button = null
var _panel: PanelContainer = null
var _body: VBoxContainer = null
var _open: bool = false


func _ready() -> void:
	# Runs while paused, or the menu that caused the pause freezes with it.
	# PROCESS_MODE_ALWAYS is absolute, so this holds even though the parent
	# (HUDRoot's column) inherits.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Anchored to the top-right of whatever it is parented to. When that is
	# HUDRoot's column it inherits the ultrawide-capped layout for free; when it
	# is a bare CanvasLayer (a test, or a rule set with the HUD off) it falls back
	# to the viewport, which is the old behaviour minus the magic number.
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(WIDTH + Style.SP_MD)
	offset_right = -Style.SP_MD
	offset_top = Style.SP_MD
	offset_bottom = Style.SP_MD + HEADER_HEIGHT
	# PASS, not IGNORE: the header takes clicks, the empty area below the closed
	# header must not eat them.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build()


func _build() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_TOP_WIDE)
	col.add_theme_constant_override("separation", Style.SP_XS)
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(col)

	_header = Button.new()
	_header.name = "MenuHeader"
	_header.text = "MENU"
	_header.tooltip_text = "Pause match & open session menu (Esc)"
	_header.toggle_mode = true
	_header.custom_minimum_size = Vector2(0, HEADER_HEIGHT)
	Style.style_button(_header)
	_header.toggled.connect(_set_open)
	col.add_child(_header)

	_panel = PanelContainer.new()
	_panel.visible = false
	Style.apply_panel(_panel, false, Style.EDGE_BRIGHT)
	col.add_child(_panel)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", Style.SP_XS)
	_panel.add_child(_body)

	_add_action("RESUME", _close, "Resume match", Style.TEAM_FRIENDLY)
	# The two that have nothing to call. The reason rides on the tooltip AND the
	# label, because a disabled button with no explanation reads as a bug.
	_add_disabled("SAVE - UNAVAILABLE", "No save system exists in this build.")
	_add_disabled("LOAD - UNAVAILABLE", "No save system exists in this build.")
	_add_action("ABANDON MATCH", func(): _leave(main_menu_requested), "Surrender match and return to Main Menu")
	# The only destructive row, so it is the only one that carries the warning
	# accent - a red MENU list would make every option look dangerous.
	_add_action("EXIT TO DESKTOP", func(): _leave(quit_requested), "Quit Kitbash Command to desktop", Style.BAD)


func _add_action(label: String, action: Callable, tip: String = "", accent: Color = Style.TEAM_FRIENDLY) -> void:
	var btn := Style.button(label, accent)
	btn.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	if not tip.is_empty():
		btn.tooltip_text = tip
	_body.add_child(btn)
	btn.pressed.connect(action)


func _add_disabled(label: String, why: String) -> void:
	var btn := Style.button(label)
	btn.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	btn.disabled = true
	btn.tooltip_text = why
	_body.add_child(btn)


func _set_open(open: bool) -> void:
	_open = open
	_panel.visible = open
	# Grow the control's own rect when open, so the panel below the header is
	# inside it and takes its own clicks. Anchored top-right, so only the bottom
	# offset moves.
	offset_bottom = Style.SP_MD + HEADER_HEIGHT
	if open:
		offset_bottom += Style.SP_XS + _body.get_combined_minimum_size().y \
			+ Style.SP_MD * 2.0
	# The pause itself. Set here rather than in the caller so every route into
	# the menu - header click, Escape, a future hotkey - pauses identically.
	get_tree().paused = open


func _close() -> void:
	_header.set_pressed_no_signal(false)
	_set_open(false)


func is_open() -> bool:
	return _open


# Toggles from outside, so Escape can reach it.
func toggle() -> void:
	_header.set_pressed_no_signal(not _open)
	_set_open(not _open)


# Unpauses BEFORE handing off. A scene change made under get_tree().paused
# leaves the incoming scene paused too - the tree flag outlives the scene that
# set it - so the next screen would arrive frozen.
func _leave(what: Signal) -> void:
	get_tree().paused = false
	what.emit()
