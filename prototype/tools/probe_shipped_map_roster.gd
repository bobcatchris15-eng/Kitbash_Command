extends SceneTree

const MapCatalogScript = preload("res://scripts/map_catalog.gd")

const EXPECTED_MAP_IDS := [
	"blask_forest",
	"delta_blues",
	"dry_ambition",
	"noble_oaks",
	"pine_branch_dugout",
	"test_range",
	"the_great_valley",
	"twin_bluffs",
	"twin_streams_v2",
]

func _init() -> void:
	MapCatalogScript.reset_cache_for_tests()
	var actual: Array = MapCatalogScript.get_map_ids()
	var expected: Array = EXPECTED_MAP_IDS.duplicate()
	actual.sort()
	expected.sort()
	if actual != expected:
		push_error("Shipped map roster mismatch. Expected %s, got %s" % [expected, actual])
		quit(1)
		return
	print("[PASS] shipped map roster contains only %d approved authored/test maps." % actual.size())
	quit(0)
