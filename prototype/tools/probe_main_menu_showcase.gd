extends SceneTree

const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/MainMenu.tscn") as PackedScene
	if packed == null:
		push_error("Main menu scene did not load.")
		quit(1)
		return
	var menu := packed.instantiate()
	root.add_child(menu)
	await process_frame
	var items: Array = menu.get("_showcase_items")
	for item in items:
		if str(item.get("type", "")) != "blueprint":
			push_error("Main menu showcase contains a non-blueprint item: %s" % item)
			quit(1)
			return
		var blueprint: Dictionary = item.get("blueprint", {})
		var hull_id := str(blueprint.get("hull_type", ""))
		if hull_id == "" or not ModuleCatalogScript.hull_exists(hull_id):
			push_error("Main menu showcase contains invalid hull '%s'." % hull_id)
			quit(1)
			return
	print("[PASS] main menu showcase contains %d valid saved blueprints and no bare hulls." % items.size())
	menu.queue_free()
	quit(0)
