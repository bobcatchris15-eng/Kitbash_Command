extends SceneTree
# One-off audit (Chris, 2026-08): which catalog modules define one or zero
# tweaks in their spec tables? Walks ModuleCatalog.get_catalog() against
# LabDocument.TWEAK_SPECS (weapons/utility) and ModuleCatalog.LOcomotion_
# TWEAK_SPECS (locomotion), printing every non-hull module's declared tweak
# count plus a summary of the <=1 offenders.
#
# Run: godot --headless --path . --script res://tools/probe_tweak_coverage.gd --quit

const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const LabDocumentScript = preload("res://scripts/lab_document.gd")

func _init():
	var catalog: Dictionary = ModuleCatalogScript.get_catalog()
	var weapon_specs: Dictionary = LabDocumentScript.TWEAK_SPECS
	var loco_specs: Dictionary = ModuleCatalogScript.LOCOMOTION_TWEAK_SPECS

	var rows: Array = []
	for type_id in catalog.keys():
		var entry = catalog[type_id]
		if not entry is Dictionary:
			continue
		var category := str(entry.get("category", ""))
		if category == "" or category == "hull" or category == "foundation":
			continue
		var table: Dictionary = loco_specs if category == "locomotion" else weapon_specs
		var specs: Array = table.get(type_id, [])
		rows.append({
			"id": type_id,
			"category": category,
			"count": specs.size(),
			"names": specs.map(func(s): return str(s.get("name", "?"))),
			"ammo": ModuleCatalogScript.is_ammo_capable(type_id),
			"drone": type_id == "drone_carrier",
		})

	rows.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))

	print("--- all modules (%d) ---" % rows.size())
	for r in rows:
		print("%-28s %-10s %d  %s%s%s" % [
			r["id"], r["category"], r["count"],
			r["names"],
			" [+ammo]" if r["ammo"] else "",
			" [+drone_type]" if r["drone"] else "",
		])

	print("\n--- ZERO tweaks ---")
	var n0 := 0
	for r in rows:
		if r["count"] == 0 and not r["ammo"] and not r["drone"]:
			print("%s (%s)" % [r["id"], r["category"]])
			n0 += 1
	print("(only an ammo/drone selector does NOT count as parametric tweaks)")
	for r in rows:
		if r["count"] == 0 and (r["ammo"] or r["drone"]):
			print("%s (%s) - selector only" % [r["id"], r["category"]])

	print("\n--- ONE tweak ---")
	for r in rows:
		if r["count"] == 1:
			print("%s (%s): %s" % [r["id"], r["category"], r["names"][0]])

	quit(0)
