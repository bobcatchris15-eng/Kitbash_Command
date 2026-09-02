extends Node
class_name BlueprintThumbnail
# Renders a saved blueprint to a flat ImageTexture, once, for use in 2D UI.
#
# WHY BAKE TO A TEXTURE instead of showing a live SubViewport per entry: a
# roster screen shows a dozen designs at once, and a dozen live 3D viewports
# updating every frame is a real cost for content that never moves. Baking
# gives an ordinary Texture2D that a TextureRect, a button icon and a drag
# preview can all share with no per-frame work.
#
# It is also the only practical way to get a drag preview. set_drag_preview()
# takes a Control, and Godot reparents it under the viewport's drag layer -
# handing it a live SubViewportContainer means a 3D render target following the
# cursor, which is both expensive and prone to rendering a frame late.
#
# HOW THE ONE-SHOT RENDER WORKS, since this is the part that silently returns
# blank if done wrong: a SubViewport does not produce a texture until the
# renderer has actually drawn it. Setting UPDATE_ONCE queues exactly one draw,
# but get_texture().get_image() immediately afterwards reads the frame BEFORE
# that draw. The await on RenderingServer.frame_post_draw is what puts the read
# after the draw. Without it every thumbnail comes back transparent, and it
# looks like a material or lighting bug rather than a timing one.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const DesignStatsScript = preload("res://scripts/design_stats.gd")

# Square, and generous enough that a wide airship still reads at slot size.
const SIZE = 192

var _viewport: SubViewport = null
var _model_holder: Node3D = null
var _camera: Camera3D = null

# DesignStats for the most recent bake() call. A companion output rather than a
# second return value because bake() is a coroutine - `await`ing it already
# yields the texture, and returning a tuple would force every caller to unpack
# one even when it only wants the picture.
var last_stats: Dictionary = {}


func _ready() -> void:
	_build_rig()


func _build_rig() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	# TRANSPARENT so the thumbnail composites onto whatever plate the slot uses
	# rather than carrying its own opaque square, which would defeat the recessed
	# well look entirely.
	_viewport.transparent_bg = true
	# DISABLED, not UPDATE_ONCE, as the resting state. Each bake explicitly asks
	# for a single frame; leaving it enabled would have the rig redrawing an empty
	# scene forever after the last thumbnail was taken.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.own_world_3d = true
	_viewport.world_3d = World3D.new()
	add_child(_viewport)

	_model_holder = Node3D.new()
	_viewport.add_child(_model_holder)

	_camera = Camera3D.new()
	# Three-quarter view from slightly above: the angle that shows a vehicle's
	# length, width and height at once, which is what makes two kitbashes
	# distinguishable at thumbnail size. A pure side or top view collapses one
	# of the three and makes half the roster look identical.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.rotation_degrees = Vector3(-25.0, 35.0, 0.0)
	_viewport.add_child(_camera)

	# Flat, even light. This is a catalogue photograph, not a battlefield - see
	# CORE_DESIGN_LANGUAGE.md on why the showcase register differs from the
	# in-match one. Strong directional light here would throw half of every
	# thumbnail into shadow at exactly the size where that costs legibility.
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


# Bakes one blueprint. Returns null if the blueprint could not be reconstructed,
# so callers can fall back to a text-only card rather than showing a blank slot.
func bake(blueprint_data: Dictionary) -> ImageTexture:
	# Cleared FIRST, before any of the early returns below. bake() can bail at
	# four points, and leaving the previous design's figures in last_stats would
	# have a failed bake silently attribute one unit's HP and DPS to another.
	last_stats = {}
	if blueprint_data.is_empty() or _viewport == null:
		return null

	for child in _model_holder.get_children():
		child.free()

	var bp := BlueprintManagerScript.new()
	add_child(bp)
	var model: Node3D = bp.reconstruct_vehicle(blueprint_data, _model_holder, true)
	bp.queue_free()
	if model == null:
		return null

	# Stats come from the SAME reconstructed node the thumbnail is rendered from,
	# read before the scale-model finish flattens its materials (the finish touches
	# appearance only, but taking the measurement first keeps the ordering
	# obviously irrelevant rather than merely happening to be safe).
	#
	# This is the whole reason the stats are trustworthy: DesignStats.analyze()
	# makes the same Drivetrain/WeaponRange/ModuleCatalog calls unit.gd
	# makes on the unit it spawns, against a real hull node - not a re-derivation
	# from the JSON. Reconstructing was already necessary for the picture, so the
	# numbers cost nothing extra.
	last_stats = DesignStatsScript.analyze(model)

	HullMaterialBuilderScript.apply_scale_model_finish(model)
	_frame_model(model)

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# See the header note: the read must land after the draw, not after the
	# request for one.
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	for child in _model_holder.get_children():
		child.free()

	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


# Sizes the orthogonal camera to the model's real bounds so every design fills
# its thumbnail equally. Without this a scout and an airship render at the same
# world scale, so the scout is a speck and the airship overflows - and the
# Design Lab's continuous stretch sliders mean bounds vary a lot more than the
# hull-size tiers alone suggest.
#
# SHARED IMPLEMENTATION. `frame_camera()` and `merged_aabb()` below are static
# and take the camera/rotation as parameters instead of reading `self`, so
# part_thumbnail.gd's per-part rig can call the exact same math instead of
# carrying a near-duplicate. The single-axis version part_thumbnail.gd used to
# keep had its own drift bug (a floor that clamped every sub-1m part to the
# same apparent size); one implementation means that class of bug can only
# exist once.
func _frame_model(model: Node3D) -> void:
	frame_camera(_camera, model, Vector3(-25.0, 35.0, 0.0))


# Static so it has no `self` to smuggle framing state between unrelated
# bakes. `rotation_degrees` is passed in because part_thumbnail.gd's rig uses
# a different three-quarter angle than the blueprint rig.
static func frame_camera(camera: Camera3D, model: Node3D, rotation_degrees: Vector3, margin: float = 1.15) -> void:
	var aabb := merged_aabb(model, Transform3D.IDENTITY)
	camera.rotation_degrees = rotation_degrees
	if aabb.size == Vector3.ZERO:
		camera.size = 4.0
		camera.position = Vector3(6.0, 6.0, 6.0)
		camera.look_at(Vector3.ZERO, Vector3.UP)
		camera.rotation_degrees = rotation_degrees
		return

	var centre := aabb.get_center()
	# Longest diagonal rather than the largest axis: a long thin hull viewed at
	# three-quarters presents its diagonal to the camera, so fitting the widest
	# axis alone still clips the nose and tail.
	var extent: float = aabb.size.length()
	# NO FLOOR on camera.size. A `maxf(1.0, ...)` floor here used to force
	# every part/design under ~0.87m diagonal to share the same apparent
	# size regardless of how much smaller it actually was - which is exactly
	# why a small scout hull or a small module (Plasma Thruster, Anti-Grav
	# Plate) still rendered as a speck next to a larger one even though this
	# function already framed to real bounds. Framing must be a pure
	# function of the subject's own size with no clamp, or "uniform fraction
	# of the cell" breaks for anything smaller than the floor.
	camera.size = extent * margin

	# Pull back along the camera's own forward axis from the model centre. The
	# distance barely matters for an orthogonal projection - only `size` sets the
	# framing - but it has to clear the near plane and the model itself.
	var basis := Basis.from_euler(Vector3(deg_to_rad(rotation_degrees.x), deg_to_rad(rotation_degrees.y), deg_to_rad(rotation_degrees.z)))
	camera.position = centre + basis.z * (extent + 8.0)
	camera.near = 0.05
	camera.far = extent * 4.0 + 32.0


static func merged_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var has_any := false
	var local := xform
	if node is Node3D:
		local = xform * (node as Node3D).transform
	# Only count nodes that contribute real, visible geometry. Light3D
	# extends VisualInstance3D but get_aabb() returns a sphere sized by
	# omni_range, not by anything rendered - it dwarfed small modules'
	# (Plasma Thruster, Anti-Grav Plate glow lights) actual mesh bounds and
	# inflated the framing camera. GPUParticles3D / CPUParticles3D have the
	# same failure mode via visibility_aabb. Exclude all three from bounds.
	if node is VisualInstance3D and not (node is Light3D) and not (node is GPUParticles3D) and not (node is CPUParticles3D):
		var vi := node as VisualInstance3D
		var box := vi.get_aabb()
		if box.size != Vector3.ZERO:
			out = local * box
			has_any = true
	for child in node.get_children():
		var child_box := merged_aabb(child, local)
		if child_box.size == Vector3.ZERO:
			continue
		if has_any:
			out = out.merge(child_box)
		else:
			out = child_box
			has_any = true
	return out
