extends SceneTree

const MANIFEST_PATH := "res://assets/ui/industrial/manifest.json"
const VECTOR_ROOT := "res://assets/ui/industrial/vectors/"

var failures := 0
var checks := 0

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] ", message)

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
	check(manifest.get("schema", "") == "kitbash-command.ui.industrial.v1", "manifest schema is stable")
	var vectors: Dictionary = manifest.get("vectors", {})
	check(vectors.size() == 10, "manifest contains the complete vector state set")
	for key: String in vectors:
		var path := VECTOR_ROOT + str(vectors[key])
		check(FileAccess.file_exists(path), "vector exists: " + key)
		if not FileAccess.file_exists(path):
			continue
		var svg := FileAccess.get_file_as_string(path)
		check(svg.begins_with("<?xml"), "vector has explicit XML header: " + key)
		check(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""), "vector has SVG namespace: " + key)
		check(not svg.contains("href=\"http"), "vector has no external dependency: " + key)
	for key: String in manifest.get("raster_reuse", {}):
		var raster_path: String = manifest["raster_reuse"][key]
		check(ResourceLoader.exists(raster_path), "reused raster exists: " + key)
	print("Industrial asset kit: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
