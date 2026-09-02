extends Node
class_name PartThumbnailCache
# Renders a single module/parts-menu entry to a flat ImageTexture, once, for
# use in 2D UI - today just the parts-menu drag preview (see part_button.gd),
# potentially also the parts-menu cards themselves later.
#
# WHY A ONE-SHOT BAKE per part, not a live SubViewport per drag. The same
# reasoning blueprint_thumbnail.gd gives: a live 3D render target per drag
# preview is both expensive and one-frame late. Drag previews are pulled
# under the viewport's drag layer and re-rendered as the cursor moves, so
# any cost paid per frame compounds. The catalog has ~60 entries that
# never animate on the parts menu, so a baked Texture2D is the right
# shape.
#
# SHARED RIG, NOT ONE PER CALL. The SubViewport, camera, lights and rig
# nodes live on this cache node and are reused for every render - a new
# SubViewport per drag (or per part-card hover, if it ever comes to that)
# would create one render target per part the player has ever picked up,
# which is the obvious leak. Rig is created once in _ready, then each
# bake() call just swaps in a fresh model and reads the texture.
#
# CACHING, AND WHY IT IS PER-INSTANCE NOT STATIC. A per-instance dictionary
# means a Design Lab reload (clear-and-reload path) does not carry stale
# baked textures from the previous session, and tests that instantiate the
# cache in isolation cannot pollute each other. Static would be faster but
# would also leak a baked texture's mesh dependency into the next session
# and would make test teardown depend on a globally-shared state.
#
# FRAMING IS SHARED WITH blueprint_thumbnail.gd, not a second implementation.
# Parts vary in real extent by far more than a "2x range" (a Plasma Thruster
# vs a set of Wheels) - the premise this comment used to state was false and
# was the actual root cause of parts rendering at wildly different apparent
# sizes. `BlueprintThumbnail.frame_camera()` is the one place that AABB→camera
# math lives; this rig just calls it with its own three-quarter angle.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const BlueprintThumbnailScript = preload("res://scripts/blueprint_thumbnail.gd")

# Three-quarter angle for the parts rig. Kept as a constant here (rather than
# only living on the Camera3D) so _frame_model can pass it to the shared
# framing helper without re-reading it back off the node.
const CAMERA_ROTATION_DEGREES := Vector3(-22.0, -32.0, 0.0)

# Square, large enough that an artillery barrel fits but small enough that
# the parts-menu cards do not need to be retrofitted if/when the bake
# gets reused. 128 was the in-house design number; the drag preview is
# then scaled down inside part_button.gd, so the bake does not need to
# match the drag-preview size exactly.
const SIZE = 128

# Per-part tweak values. The drag preview is a generic catalogue card, not
# a per-instance design view, so showing every gun at default caliber/
# length is the right read - the player is choosing a part, not
# previewing their exact design. Empty tweaks means a 1.0 default for
# everything that has a tweak slider, which is the same default a fresh
# design ships with.
const PREVIEW_TWEAKS: Dictionary = {}

var _viewport: SubViewport = null
var _model_holder: Node3D = null
var _camera: Camera3D = null
var _cache: Dictionary = {}
# Negative result cache: parts whose bake failed (no mesh, build crashed,
# whatever) are recorded so a repeated get() does not retry the work.
# Without this, a hovered card that fails to render would re-allocate
# the rig every frame.
var _failures: Dictionary = {}
var _bake_queue: Array[String] = []
var _is_baking: bool = false
signal queue_advanced
func _ready() -> void:
	_build_rig()


func _build_rig() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	# TRANSPARENT so the thumbnail composites onto whatever backing the drag
	# preview gives it (PanelContainer with a tinted stylebox today), rather
	# than carrying its own opaque square that would clash with the chrome.
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.own_world_3d = true
	_viewport.world_3d = World3D.new()
	add_child(_viewport)

	_model_holder = Node3D.new()
	_viewport.add_child(_model_holder)

	_camera = Camera3D.new()
	# ORTHOGONAL because a perspective camera's apparent size depends on the
	# part's distance to camera, which means two parts of the same catalog
	# size but different real extent (autocannon receiver vs sensor mast)
	# would render at different on-screen sizes. Orthogonal makes "part fits
	# the frame" a property of the rig, not of the part.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.rotation_degrees = CAMERA_ROTATION_DEGREES
	# Placeholder only - every real bake calls _frame_model(), which sizes
	# this to the part's own bounds via the shared BlueprintThumbnail helper.
	_camera.size = 1.6
	_camera.near = 0.05
	_camera.far = 32.0
	_viewport.add_child(_camera)

	# Three-quarter view, slightly above. The same angle production chose
	# for the turntable and the blueprint previews; consistency matters
	# because a player who has learned "this is what a gun looks like
	# at menu size" should see the same silhouette in the drag preview.
	# The basis is reused below to position the camera, not just to aim it.

	# Flat, even light. Catalogue photograph, not a battlefield - the
	# same reasoning blueprint_thumbnail.gd gives. A strong directional
	# light would throw half of every part into shadow at exactly the
	# size where that costs legibility.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	key.light_energy = 1.1
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.74, 0.78)
	env.ambient_light_energy = 0.75
	var cam_env := WorldEnvironment.new()
	cam_env.environment = env
	_viewport.add_child(cam_env)


# Returns a Texture2D for the given module type_id, baking it on first
# call and returning the cached texture thereafter. Returns null for a
# type_id that does not exist in the catalog, so the caller can fall back
# to a text-only card.
func get_thumbnail(type_id: String) -> Texture2D:
	if _cache.has(type_id):
		return _cache[type_id]
	if _failures.has(type_id):
		return null
	
	if not _bake_queue.has(type_id):
		_bake_queue.append(type_id)
		
	if not _is_baking:
		_process_queue()
		
	while not _cache.has(type_id) and not _failures.has(type_id):
		await queue_advanced
		
	if _cache.has(type_id):
		return _cache[type_id]
	return null

func _process_queue() -> void:
	_is_baking = true
	if _viewport == null:
		# Tests that construct a cache without _ready() running (e.g. add_child
		# + immediate get) hit this path. The rig is cheap to build, so build
		# it on demand rather than failing the call.
		_build_rig()
		
	while _bake_queue.size() > 0:
		var current_id = _bake_queue.pop_front()
		if _cache.has(current_id) or _failures.has(current_id):
			continue
			
		var tex := await _bake(current_id)
		if tex == null:
			_failures[current_id] = true
		else:
			_cache[current_id] = tex
			
		queue_advanced.emit()
		
	_is_baking = false


# Synchronous variant. Used when the caller knows the bake is already
# cached (and so a frame wait is pointless) and is fine to return null
# for a not-yet-baked part. Drag previews on cached entries take this
# path; the first drag of a session takes the async path.
func get_thumbnail_now(type_id: String) -> Texture2D:
	if _cache.has(type_id):
		return _cache[type_id]
	return null


func _bake(type_id: String) -> ImageTexture:
	# Cleared FIRST. _bake can bail at several points, and leaving the
	# previous part's children behind would render a ghost of the last
	# part under this one. This is the same pattern blueprint_thumbnail.gd
	# follows, with the same justification.
	for child in _model_holder.get_children():
		child.queue_free()

	if not ModuleCatalog.module_exists(type_id):
		return null

	var catalog_data = ModuleCatalog.get_module_data(type_id)
	# HUDDLES the part at the world origin, NOT at its own catalog size's
	# bottom-face. The whole point of the rig is to show the part sitting
	# on the camera plane; an offset origin would have every part hanging
	# in the middle of the frame or buried under the bottom edge.
	var model: Node3D = Node3D.new()
	_model_holder.add_child(model)

	# Hulls go through a different load path than weapons/support - they
	# ship as authored .glb files under res://assets/models/hulls (or as
	# player mods under user://), not as the procedural-and-glb hybrid
	# that visual_builder.gd handles for everything else. Calling
	# build_visual() on a hull id produces nothing - no monolithic .glb
	# in the parts directory, no modular branch matches - and the bake
	# falls through to the bare box fallback. That is the "card with the
	# bounding box on it" symptom Chris hit: a hull preview that is
	# technically a "hull" but renders as a plain box.
	#
	# The right path is the same one module_placer.gd's
	# _place_hull_from_ui() takes: MeshAssetLoader.get_hull_mesh() for
	# the geometry, ModuleCatalog.get_hull_mesh_fit() for the per-hull
	# orientation+scale correction, then a MeshInstance3D carrying both.
	# apply_scale_model_finish() is what gives it the same flat grey-green
	# plastic the rest of the lab shows, so the drag preview is not the
	# only place a hull wears the kit material.
	if String(catalog_data.get("category", "")) == "hull":
		var hull_mesh: Mesh = MeshAssetLoader.get_hull_mesh(type_id)
		if hull_mesh == null:
			model.queue_free()
			return null
		var mi := MeshInstance3D.new()
		mi.mesh = hull_mesh
		var fit: Dictionary = ModuleCatalog.get_hull_mesh_fit(type_id, hull_mesh)
		mi.rotation = fit.get("rotation", Vector3.ZERO)
		mi.scale = fit.get("scale", Vector3.ONE)
		mi.position = fit.get("position", Vector3.ZERO)
		model.add_child(mi)
	else:
		VisualBuilder.build_visual(type_id, model, catalog_data.get("size", Vector3.ONE),
			catalog_data.get("color", Color.WHITE), PREVIEW_TWEAKS)

	# No part should fail to build any meshes, but a broken import (a missing
	# .glb that the procedural fallback also can't satisfy) can leave model
	# with zero children. Bail with a cached failure so the next call does
	# not retry.
	if model.get_child_count() == 0:
		model.queue_free()
		return null

	# The "scale-model finish" matches what blueprint_thumbnail.gd applies
	# and what the rest of the lab shows. A baked preview that used a
	# different material recipe would read as a different part.
	HullMaterialBuilderScript.apply_scale_model_finish(model)

	_frame_model(model)

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# blueprint_thumbnail.gd's header documents the timing trap: the read
	# must land AFTER the draw, not after the request. Same constraint here.
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	for child in _model_holder.get_children():
		child.queue_free()

	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


# Frames the part so it fills the rig at a uniform fraction of the frame,
# regardless of the part's real-world scale. Delegates the AABB→camera math
# to BlueprintThumbnail.frame_camera() - see that function's header for why
# there is no size floor here (a floor is what made small parts render as
# specks even though this function has always called into per-part bounds).
func _frame_model(model: Node3D) -> void:
	BlueprintThumbnailScript.frame_camera(_camera, model, CAMERA_ROTATION_DEGREES, 1.25)


# Drops every cached thumbnail. Exposed for tests and for any future
# "blueprint roster just changed, invalidate thumbnails" hook. The rig
# itself is kept - it is expensive to rebuild and is stateless once the
# last bake finished.
func clear_cache() -> void:
	_cache.clear()
	_failures.clear()
