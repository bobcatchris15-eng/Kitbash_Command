extends SceneTree
# Screenshots a UI scene so interface work can be checked without a human
# taking the picture.
#
# MUST run WITHOUT --headless (it needs a rendering device):
#   Godot_v4.7.1-stable_win64.exe --path <prototype>
#     --script res://tools/capture_screen.gd --
#     --scene res://scenes/MatchSetup.tscn --out <abs.png> [--frames 40]
#     [--size 1920x1080]

var _out := "screen.png"
var _scene := "res://scenes/MatchSetup.tscn"
var _frames_to_wait := 40
var _frames := 0
var _armed := false


func _arg(name: String, def: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == name and i + 1 < a.size():
			return a[i + 1]
	return def


func _initialize() -> void:
	_scene = _arg("--scene", _scene)
	_out = _arg("--out", _out)
	_frames_to_wait = int(_arg("--frames", str(_frames_to_wait)))
	var size_s := _arg("--size", "1920x1080").split("x")
	var w := int(size_s[0]) if size_s.size() == 2 else 1920
	var h := int(size_s[1]) if size_s.size() == 2 else 1080

	DisplayServer.window_set_size(Vector2i(w, h))
	root.content_scale_size = Vector2i(w, h)

	var packed: PackedScene = load(_scene)
	if packed == null:
		push_error("capture_screen: could not load %s" % _scene)
		quit(1)
		return
	root.add_child(packed.instantiate())
	print("[screen] loaded %s at %dx%d" % [_scene, w, h])
	_armed = true


func _process(_delta: float) -> bool:
	if not _armed:
		return false
	_frames += 1
	# UI here animates in (stagger_in / fade), and thumbnails are baked
	# asynchronously a frame or more apart, so an early grab catches a
	# half-built screen.
	if _frames < _frames_to_wait:
		return false
	var img := root.get_texture().get_image()
	img.save_png(_out)
	print("[screen] wrote %s after %d frames" % [_out, _frames])

	# Value distribution, because "too dark / not enough contrast" is a
	# measurable claim and a thumbnail does not settle it.
	var buckets := PackedInt32Array()
	buckets.resize(10)
	var total := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			var c := img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			buckets[clampi(int(l * 10.0), 0, 9)] += 1
			total += 1
	var line := ""
	for i in range(10):
		line += "%d0s:%.0f%%  " % [i, 100.0 * float(buckets[i]) / float(maxi(total, 1))]
	print("[screen] luminance %s" % line)
	quit(0)
	return true
