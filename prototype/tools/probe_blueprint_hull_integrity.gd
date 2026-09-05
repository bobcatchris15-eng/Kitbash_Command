extends SceneTree

const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")

const BLUEPRINT_DIRS := [
	"res://assets/blueprints/default_roster",
	"res://data/loadout",
	"res://data/enemy",
	"user://blueprints",
]

func _init() -> void:
	var invalid: Array[String] = []
	var checked := 0
	for directory in BLUEPRINT_DIRS:
		var dir := DirAccess.open(directory)
		if dir == null:
			continue
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.get_extension().to_lower() == "json":
				var path := "%s/%s" % [directory, file_name]
				var file := FileAccess.open(path, FileAccess.READ)
				if file != null:
					var data = JSON.parse_string(file.get_as_text())
					file.close()
					if data is Dictionary and data.has("hull_type"):
						checked += 1
						var hull_id := str(data.get("hull_type", ""))
						if hull_id == "" or not ModuleCatalogScript.hull_exists(hull_id):
							invalid.append("%s|%s|%s" % [path, hull_id, str(data.get("name", file_name.get_basename()))])
			file_name = dir.get_next()
		dir.list_dir_end()
	print("BLUEPRINT_HULL_AUDIT checked=%d invalid=%d" % [checked, invalid.size()])
	for entry in invalid:
		print("INVALID_BLUEPRINT|%s" % entry)
	quit(1 if not invalid.is_empty() else 0)
