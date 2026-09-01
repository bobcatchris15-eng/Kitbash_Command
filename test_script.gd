extends SceneTree

func _init():
	var ModuleCatalog = preload("res://scripts/module_catalog.gd")
	var pb = preload("res://scripts/power_budget.gd")
	var data = preload("res://scripts/module_data.gd").new()
	data.type_id = "gauss_railgun"
	data.base_dps = 99.0
	print("Max shot cost: ", pb._single_shot_cost(data))
	quit()

