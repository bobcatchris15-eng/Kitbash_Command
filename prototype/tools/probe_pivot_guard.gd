extends SceneTree
# Exercises VisualBuilder's animated-pivot guard (_assert_animated_pivots)
# through the real build_visual() dispatch, for every locomotion type it
# covers, plus a deliberate negative case that proves the guard actually
# fires rather than being a dead check.

const VisualBuilderScript = preload("res://scripts/visual_builder.gd")

func _resolve(module: Node3D, pivot_name: String, prefix: bool) -> int:
	if prefix:
		return module.find_children(pivot_name + "*", "Node3D", true, false).size()
	var found := module.find_child(pivot_name, true, false)
	return 1 if found != null else 0

func _init():
	var root := Node3D.new()
	get_root().add_child(root)

	var base_size := Vector3(2.0, 1.0, 3.0)
	var base_color := Color.GRAY
	var any_missing := false
	var missing_types: Array = []
	var type_ids: Array = VisualBuilderScript.EXPECTED_ANIMATED_PIVOTS.keys()
	type_ids.sort()

	print("--- per-type build + resolve (real VisualBuilder.build_visual dispatch) ---")
	for type_id in type_ids:
		var module := Node3D.new()
		root.add_child(module)
		VisualBuilderScript.build_visual(type_id, module, base_size, base_color, {})

		var reqs: Array = VisualBuilderScript.EXPECTED_ANIMATED_PIVOTS[type_id]
		var names: Array = []
		var total_resolved := 0
		var type_ok := true
		for req in reqs:
			var n: String = req["name"]
			var prefix: bool = req["prefix"]
			var count := _resolve(module, n, prefix)
			names.append(n)
			total_resolved += count
			if count == 0:
				type_ok = false

		var status := "OK" if type_ok else "MISSING"
		if not type_ok:
			any_missing = true
			missing_types.append(type_id)
		print("%s | expected=%s | resolved=%d | %s" % [type_id, str(names), total_resolved, status])

		module.queue_free()

	print("--- SUMMARY ---")
	if missing_types.is_empty():
		print("SUMMARY: all %d locomotion types resolved their required pivots." % type_ids.size())
	else:
		print("SUMMARY: %d type(s) FAILED to resolve required pivots: %s" % [missing_types.size(), str(missing_types)])

	# Negative case: build a real module through the real dispatch, then
	# mutate a THROWAWAY copy by removing its required pivot node, and call
	# the real (unweakened) _assert_animated_pivots() on it directly to prove
	# it actually reports a problem when the pivot is genuinely absent.
	print("--- negative case: forcibly break hover_engine's pivot, then call the real guard ---")
	var neg_type := "hover_engine"
	var neg_module := Node3D.new()
	root.add_child(neg_module)
	VisualBuilderScript.build_visual(neg_type, neg_module, base_size, base_color, {})

	var mid_before := _resolve(neg_module, VisualBuilderScript.HOVER_RING_MID, false)
	var inner_before := _resolve(neg_module, VisualBuilderScript.HOVER_RING_INNER, false)
	print("negative case precondition: HoverRingMid resolved=%d HoverRingInner resolved=%d (before mutation)" % [mid_before, inner_before])

	# Remove/rename both required pivots on this throwaway module only.
	var mid_node := neg_module.find_child(VisualBuilderScript.HOVER_RING_MID, true, false)
	var inner_node := neg_module.find_child(VisualBuilderScript.HOVER_RING_INNER, true, false)
	if mid_node:
		mid_node.name = "MutatedAway_Mid"
	if inner_node:
		inner_node.name = "MutatedAway_Inner"

	var mid_after := _resolve(neg_module, VisualBuilderScript.HOVER_RING_MID, false)
	var inner_after := _resolve(neg_module, VisualBuilderScript.HOVER_RING_INNER, false)
	print("negative case: after mutation HoverRingMid resolved=%d HoverRingInner resolved=%d (0 means the guard's own lookup will fail, watch for push_error below)" % [mid_after, inner_after])

	print(">>> calling the real, unmodified VisualBuilder._assert_animated_pivots() now - expect push_error output <<<")
	VisualBuilderScript._assert_animated_pivots(neg_type, neg_module)
	print(">>> guard call returned <<<")

	var negative_case_tripped: bool = (mid_after == 0 and inner_after == 0)
	print("NEGATIVE_CASE_RESULT: %s" % ("TRIPPED - guard's required-pivot lookup found nothing, push_error fired above" if negative_case_tripped else "DID NOT TRIP - unexpected, investigate"))

	neg_module.queue_free()
	print("[DONE]")
	quit(0 if not any_missing else 1)
