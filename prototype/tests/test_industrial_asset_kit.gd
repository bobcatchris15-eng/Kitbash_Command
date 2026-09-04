extends SceneTree

const UITheme = preload("res://scripts/ui_theme.gd")
const MANIFEST_PATH := "res://assets/ui/industrial/manifest.json"
const GENERATED_THEME_PATH := "res://resources/bomber_theme.tres"
const VECTOR_KEYS := [
	"nav_design_lab",
	"nav_match_setup",
	"nav_main_menu",
	"slot_module",
	"state_selected",
	"state_ready",
	"state_invalid",
	"drop_target",
	"map_spawn_marker",
	"blueprint_status",
]
const MATERIAL_KEYS := [
	"cutting_mat", "cardboard", "kraft", "cork", "chipboard",
	"powdercoat", "steel", "moulded", "canvas", "carbon",
	"fiberglass", "toolbox", "bakelite", "wood",
]
const PLATE_MATERIAL_KEYS := [
	"powdercoat", "steel", "moulded", "canvas", "carbon",
	"fiberglass", "toolbox", "bakelite", "wood",
]
const ROLE_KEYS := [
	"surface", "control", "inset", "frame",
	"primary", "danger", "workbench", "parts_dock",
]
const CONTROL_STATES := ["normal", "hover", "pressed", "disabled"]

var failures := 0
var checks := 0

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] ", message)

func _svg_attribute(source: String, attribute: String) -> String:
	var regex := RegEx.new()
	if regex.compile("\\b%s=\"([^\"]+)\"" % attribute) != OK:
		return ""
	var found := regex.search(source)
	return found.get_string(1) if found else ""

func _check_image(path: String, expected_size: Vector2i, label: String) -> void:
	check(FileAccess.file_exists(path), label + " file exists")
	check(ResourceLoader.exists(path), label + " imports as a Godot resource")
	var texture := load(path) as Texture2D if ResourceLoader.exists(path) else null
	check(texture != null, label + " loads as a Texture2D")
	if texture != null:
		check(texture.get_size() == Vector2(expected_size),
			label + " dimensions are %s" % expected_size)

func _size_metadata(value: Variant) -> Vector2i:
	if not value is Array or value.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(value[0]), int(value[1]))

func _run() -> void:
	var manifest_file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	check(manifest_file != null, "industrial asset manifest is readable")
	if manifest_file == null:
		quit(1)
		return
	var parsed = JSON.parse_string(manifest_file.get_as_text())
	check(parsed is Dictionary, "industrial asset manifest is valid JSON")
	if not parsed is Dictionary:
		quit(1)
		return
	var manifest: Dictionary = parsed
	check(manifest.get("schema", "") == "kitbash-command.ui.industrial.v2",
		"manifest schema identifies the integrated asset contract")

	var vectors: Dictionary = manifest.get("vectors", {})
	check(vectors.size() == VECTOR_KEYS.size(), "manifest contains only the approved vector semantics")
	for key: String in VECTOR_KEYS:
		check(vectors.has(key), "manifest declares vector semantic: " + key)
		if not vectors.has(key):
			continue
		check(vectors[key] is Dictionary, "vector semantic carries metadata: " + key)
		if not vectors[key] is Dictionary:
			continue
		var spec: Dictionary = vectors[key]
		var path: String = spec.get("path", "")
		check(spec.get("width", 0) == 64 and spec.get("height", 0) == 64,
			"vector metadata uses the 64-unit grid: " + key)
		check(spec.get("view_box", "") == "0 0 64 64", "vector metadata has canonical viewBox: " + key)
		check(FileAccess.file_exists(path), "vector exists: " + key)
		check(ResourceLoader.exists(path), "vector imports as a Godot texture: " + key)
		if not FileAccess.file_exists(path):
			continue
		var svg := FileAccess.get_file_as_string(path)
		check(svg.begins_with("<?xml"), "vector has explicit XML header: " + key)
		check(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""), "vector has SVG namespace: " + key)
		check(not svg.contains("href=\"http"), "vector has no external dependency: " + key)
		check(_svg_attribute(svg, "width") == str(int(spec["width"])), "vector width matches metadata: " + key)
		check(_svg_attribute(svg, "height") == str(int(spec["height"])), "vector height matches metadata: " + key)
		check(_svg_attribute(svg, "viewBox") == spec["view_box"], "vector viewBox matches metadata: " + key)

	var roles: Dictionary = manifest.get("theme_roles", {})
	check(roles.size() == ROLE_KEYS.size(), "manifest contains only the approved material roles")
	for key: String in ROLE_KEYS:
		check(roles.has(key), "manifest declares material role: " + key)

	var materials: Dictionary = manifest.get("materials", {})
	check(materials.size() == MATERIAL_KEYS.size(), "manifest contains the complete material vocabulary")
	for key: String in MATERIAL_KEYS:
		check(materials.has(key), "manifest declares material: " + key)
		if not materials.has(key):
			continue
		var material: Dictionary = materials[key]
		var field: Dictionary = material.get("field", {})
		check(field.get("tile", false), "material field is explicitly tileable: " + key)
		check(_size_metadata(field.get("size", [])) == Vector2i(512, 512), "material field metadata is 512x512: " + key)
		_check_image(field.get("path", ""), Vector2i(512, 512), "material field " + key)
		var wear: Dictionary = material.get("wear", {})
		for control: String in ["wear", "grime", "scale", "vignette", "brightness"]:
			check(wear.has(control), "material controls " + control + ": " + key)

	for key: String in PLATE_MATERIAL_KEYS:
		if not materials.has(key):
			continue
		var plate: Dictionary = materials[key].get("plate", {})
		check(_size_metadata(plate.get("size", [])) == Vector2i(128, 128), "plate metadata is 128x128: " + key)
		check(plate.get("slice", 0) == 28, "plate reserves the authored 28px 9-slice frame: " + key)
		check(plate.get("expand", 0) == 16, "plate preserves the authored 16px shadow pad: " + key)
		var states: Dictionary = plate.get("states", {})
		check(states.size() == CONTROL_STATES.size(), "plate has exactly four control states: " + key)
		for state: String in CONTROL_STATES:
			check(states.has(state), "plate declares %s state: %s" % [state, key])
			if states.has(state):
				_check_image(states[state], Vector2i(128, 128), "%s plate %s" % [key, state])

	var style_api := UITheme.new()
	check(style_api.has_method("industrial_manifest"), "runtime theme exposes the industrial manifest")
	check(style_api.has_method("industrial_icon"), "runtime theme resolves semantic vector icons")
	check(style_api.has_method("industrial_plate_texture"), "runtime theme resolves material state plates")
	check(style_api.has_method("industrial_material_field"), "runtime theme resolves workbench/material fields")
	if style_api.has_method("industrial_icon"):
		for key: String in VECTOR_KEYS:
			check(style_api.call("industrial_icon", key) is Texture2D, "runtime resolves vector: " + key)
	if style_api.has_method("industrial_plate_texture"):
		for key: String in PLATE_MATERIAL_KEYS:
			for state: String in CONTROL_STATES:
				check(style_api.call("industrial_plate_texture", key, state) is Texture2D,
					"runtime resolves plate: %s/%s" % [key, state])

	var generated := load(GENERATED_THEME_PATH) as Theme
	check(generated != null, "generated production theme loads")
	if generated:
		for key: String in VECTOR_KEYS:
			check(generated.has_icon(key, "IndustrialIcons"), "generated theme embeds vector: " + key)
		for key: String in MATERIAL_KEYS:
			check(generated.has_icon(key, "IndustrialFields"), "generated theme embeds material field: " + key)
		for key: String in PLATE_MATERIAL_KEYS:
			var type_name: String = materials[key].get("theme_type", "") if materials.has(key) else ""
			check(not type_name.is_empty(), "plate declares a generated theme type: " + key)
			for state: String in CONTROL_STATES:
				check(generated.has_stylebox(state, type_name), "generated theme embeds plate: %s/%s" % [key, state])

	print("Industrial asset kit: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
