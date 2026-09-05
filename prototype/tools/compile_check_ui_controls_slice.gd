extends SceneTree

const FILES := [
	"res://scripts/ui/controls/ui_button.gd",
	"res://scripts/ui_feedback.gd",
	"res://scripts/ui/system_layer.gd",
	"res://scripts/ui/settings_panel.gd",
	"res://scripts/main_menu.gd",
]

func _initialize() -> void:
	for path in FILES:
		if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) == null:
			push_error("Compile check failed: %s" % path)
			quit(1)
			return
	print("[PASS] modern UI control slice compiled: %d" % FILES.size())
	quit(0)
