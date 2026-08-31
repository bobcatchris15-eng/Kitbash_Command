class_name Structure
extends StaticBody3D
# A base building: HQ, refinery, manufactory, power plant.
#
# Thinner than the 687-line building.gd it replaces, because the things that file
# also did - production queues, energy bookkeeping, repair, placement legality -
# are services now. What is left is genuinely per-building: where it is, how much
# of it is left, where units come out, and where harvesters dock.
#
# GEOMETRY IS A PLACEHOLDER, inherited deliberately from the old implementation.
# Chris is replacing every building mesh with authored art later, so this pass is
# data and wiring only and the boxes are on purpose.

const BuildingCatalogScript = preload("res://scripts/battle/economy/building_catalog.gd")
const LayersScript = preload("res://scripts/battle/battle_layers.gd")
const DamageModelScript = preload("res://scripts/battle/units/damage_model.gd")
const UnitAssemblyScript = preload("res://scripts/battle/units/unit_assembly.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const BuildingMeshScript = preload("res://scripts/battle/buildings/building_mesh.gd")
const BattleFinishScript = preload("res://scripts/battle/battle_finish.gd")
const TerrainBuilder = preload("res://scripts/terrain_builder.gd")

signal died(structure)

var kind: String = "hq"
var team: int = 0
var max_hp: float = 1000.0
var hp: float = 1000.0
var is_dead: bool = false
var footprint := Vector3(5, 3, 5)
var display_name: String = ""

# Construction lifecycle
var build_incomplete: bool = false
var construction_progress: float = 1.0
var is_under_construction: bool = false
var _construction_root: Node3D = null
var _progress_label: Label3D = null
var _progress_bar_fill: MeshInstance3D = null
var _spark_particles: CPUParticles3D = null
var _visual_nodes: Array[Node3D] = []

# Set only on blueprint-built defences: the reconstructed hull carrying the
# weapon modules. Null on every catalog building.
var defense_hull: Node3D = null
# Longest weapon reach, for the AI's siting decisions. Zero on anything unarmed.
var attack_range: float = 0.0

# How far this building sees, which is what lifts fog around a base.
#
# THIS WAS MISSING ENTIRELY and buildings lifted no fog at all. VisionService
# reads `vision_range` off anything in the `damageable` group and defaults to 0.0
# for anything that does not declare one - a deliberately quiet default, because
# not everything damageable is an observer - so structures counted as things to
# be SEEN and never as things that SEE. A base that does not light its own ground
# is the symptom; a missing property is the cause.
#
# 45.0 is well above the typical hull's effective vision (base_vision authored
# 12-30, scaled by VISION_SCALE=1.9 in module_catalog.gd to ~23-57m, most
# hulls landing near the middle of that band) rather than the old runtime's
# own default of 15.0 - well under hull vision, which is what "buildings
# never lift fog" looked like.
# Per-kind overrides come from the catalog so an HQ or a sensor building can
# out-see a power plant without special-casing anything here.
const DEFAULT_VISION_RANGE := 45.0
var vision_range: float = DEFAULT_VISION_RANGE

# bay index -> the unit holding it, or null. Fixed length, allocated at setup
# from the catalog, so a refinery's capacity is authored data rather than an
# emergent property of how many harvesters happen to be nearby.
var _bays: Array = []
var _bay_offsets: Array = []

var _mesh: MeshInstance3D = null


func _ready() -> void:
	add_to_group("structures")
	add_to_group("damageable")


func get_display_name() -> String:
	if not display_name.is_empty():
		return display_name
	return BuildingCatalogScript.get_display_name(kind)


func setup(structure_kind: String, structure_team: int) -> void:
	kind = structure_kind
	team = structure_team
	display_name = BuildingCatalogScript.get_display_name(kind)
	set_meta("team", team)
	collision_layer = LayersScript.BUILDINGS
	collision_mask = 0

	var stats := BuildingCatalogScript.get_stats(kind)
	max_hp = stats.get("hp", 1000.0)
	hp = max_hp
	footprint = stats.get("size", Vector3(5, 3, 5))
	vision_range = stats.get("vision_range", DEFAULT_VISION_RANGE)

	_bay_offsets = BuildingCatalogScript.dock_bays_for(kind)
	_bays.resize(_bay_offsets.size())
	_bays.fill(null)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = footprint
	col.shape = box
	col.position = Vector3(0, footprint.y * 0.5, 0)
	add_child(col)

	# Authored art first, box second. Every catalog kind has a GLB in
	# assets/models/buildings/ and the old runtime has been using them all along;
	# the fallback stays because a kind added to the catalog before its model is
	# authored should appear as a grey box rather than as nothing at all.
	if BuildingMeshScript.build(self, kind, footprint,
			LiveryScript.PLAYER_ID, team) == null:
		_mesh = MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = footprint
		_mesh.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = stats.get("color", Color(0.6, 0.6, 0.6))
		mat.roughness = 0.85
		_mesh.material_override = mat
		_mesh.position = Vector3(0, footprint.y * 0.5, 0)
		add_child(_mesh)

	_add_dock_pads()
	_add_selection_proxy()
	# LAST, once every mesh this building will ever have exists - the GLB, its
	# decals, the fallback box. The finish walks what is there when it runs, so
	# calling it any earlier silently skips whatever is added afterwards.
	BattleFinishScript.apply(self)


# A DEFENCE built from a player blueprint rather than a catalog entry.
#
# This is what makes a turret design mean anything. Everything else a base builds
# is a catalog kind with a box mesh; a defence is a design the player authored in
# the Lab on a foundation hull, so it has to be reconstructed the way a unit is -
# real hull geometry, real modules - and then armed, or it is a decorative box
# that cannot shoot.
#
# It stays a Structure rather than becoming a unit: it has no locomotion, it
# occupies a footprint, it carves the navmesh, and it dies like a building. The
# only thing it borrows from the unit path is assembly.
func setup_from_blueprint(blueprint: Dictionary, structure_team: int, bp_manager: Node) -> bool:
	kind = "defense"
	team = structure_team
	display_name = str(blueprint.get("name", "Defense Turret"))
	set_meta("team", team)
	collision_layer = LayersScript.BUILDINGS
	collision_mask = 0

	defense_hull = bp_manager.reconstruct_vehicle(blueprint, self, false, blueprint.get("faction", ""))
	if defense_hull == null:
		return false

	var hull_type: String = blueprint.get("hull_type", "bunker_main_meridian")
	var thickness: float = blueprint.get("armor_thickness", 1.0)
	var material: String = blueprint.get("armor_material", "hardened_steel")
	var hull_scale: Vector3 = Vector3.ONE
	if defense_hull.has_meta("hull_scale"):
		hull_scale = defense_hull.get_meta("hull_scale")
	max_hp = ModuleCatalog.compute_hull_max_hp(hull_type, thickness, material, hull_scale)
	hp = max_hp

	var catalog: Dictionary = ModuleCatalog.get_module_data(hull_type)
	footprint = catalog.get("size", Vector3(3, 2, 3))
	# A turret sees off its own foundation hull, the way a vehicle sees off its
	# hull - so a design with a sensor mast on it spots further, and a picket
	# turret is worth placing forward for what it reveals as well as what it
	# shoots. Falls back to the flat structure default for a hull the catalog has
	# no base vision for.
	vision_range = maxf(ModuleCatalog.get_base_vision(hull_type), DEFAULT_VISION_RANGE)
	# Defences dock nothing, so they publish no bays. Leaving the array unsized
	# would have reserve_bay() report a turret as a valid delivery point.
	_bay_offsets = []
	_bays.clear()

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = footprint
	col.shape = box
	col.position = Vector3(0, footprint.y * 0.5, 0)
	add_child(col)

	# The guns. Same script-swap the unit path uses, so a turret fires by exactly
	# the same rules a tank does and needs no defence-specific weapon code.
	attack_range = UnitAssemblyScript.attach_weapons(defense_hull)
	_add_selection_proxy()
	# Defences are built from a player blueprint, so they carry the same hull and
	# module materials a unit does and need the same battlefield finish. Omitting
	# it here left turrets glossy while the tanks beside them were not.
	BattleFinishScript.apply(self)
	return true


# Structures are clickable for the same reason units are, and through the same
# Ground-level parking bays, so where a harvester unloads is something you can
# SEE rather than an invisible offset in the catalog. Read as the apron of a
# grain elevator: a dark slab per bay with a lighter kerb around it.
#
# Purely decorative - no collision and no navmesh hole. A pad marks walkable
# ground, so giving it either would carve away the exact surface the harvester
# has to stand on to use it.
const DOCK_PAD_SIZE := Vector3(7.0, 0.08, 9.0)
const DOCK_PAD_KERB := 0.6

# PR8 (2026-08-16). The dock pad materials used to be a per-instance
# StandardMaterial3D.new() per kerb, per pad, per bay. With a refinery
# running 2 bays, that's 4 unique materials per refinery; with 50
# structures, that's 200+ unique materials, each a fresh state
# change for the renderer. The fix: build the kerb and pad
# materials ONCE per process (static, so they survive scene reloads
# the same way the building material cache does) and share them
# across every structure. Visual is identical; draw-call cost
# collapses to 2 draw calls (one per material) for every dock pad
# on the field.
static var _kerb_material: StandardMaterial3D = null
static var _pad_material: StandardMaterial3D = null

func _add_dock_pads() -> void:
	if _bay_offsets.is_empty():
		return
	# Lazy-init the shared materials. Doing it lazily rather than at
	# class load avoids paying for the materials when no structure
	# ever builds (e.g. Test Range, which uses defenses not catalog
	# buildings with bays).
	if _kerb_material == null:
		_kerb_material = StandardMaterial3D.new()
		_kerb_material.albedo_color = Color(0.62, 0.60, 0.54)
		_kerb_material.roughness = 0.95
	if _pad_material == null:
		_pad_material = StandardMaterial3D.new()
		_pad_material.albedo_color = Color(0.17, 0.17, 0.19)
		_pad_material.roughness = 0.98
	# Sampled once: the current_map dictionary lives on the match director,
	# which is the parent of this StaticBody3D at setup time. Caching
	# avoids four tree-walks per refinery (4 bays).
	var world_map: Dictionary = _resolve_world_map()
	for offset in _bay_offsets:
		var bay: Vector3 = offset
		# The pad's long axis points at the building, so it reads as a bay you
		# reverse into rather than a square patch.
		var facing_x: bool = absf(bay.x) > absf(bay.z)
		var pad_size := DOCK_PAD_SIZE
		if facing_x:
			pad_size = Vector3(DOCK_PAD_SIZE.z, DOCK_PAD_SIZE.y, DOCK_PAD_SIZE.x)

		# CONFORM TO TERRAIN. The pad's world XZ is the building's footprint
		# centre plus the bay's local offset. The terrain height there is
		# rarely the same as the building's centre height on a sloped map -
		# placing the pad at fixed local Y=0.07 made it float above (or sink
		# into) the slope. We sample terrain_height_at() at the bay's world
		# XZ and offset the pad's local Y to match.
		#
		# If the world map can't be resolved (e.g. building instantiated in
		# a test fixture without a match director), fall back to the
		# previous fixed local Y so a pad always renders, just maybe
		# slightly sunken / floating on a slope.
		var pad_y: float = 0.07
		if not world_map.is_empty():
			var bay_world := global_position + Vector3(bay.x, 0.0, bay.z)
			var bay_terrain_y: float = TerrainBuilder.terrain_height_at(world_map, bay_world)
			pad_y = bay_terrain_y - global_position.y + 0.07

		var kerb := MeshInstance3D.new()
		var kerb_mesh := BoxMesh.new()
		kerb_mesh.size = pad_size + Vector3(DOCK_PAD_KERB * 2.0, -0.02, DOCK_PAD_KERB * 2.0)
		kerb.mesh = kerb_mesh
		kerb.material_override = _kerb_material
		kerb.position = Vector3(bay.x, pad_y - 0.04, bay.z)
		add_child(kerb)

		var pad := MeshInstance3D.new()
		var pad_mesh := BoxMesh.new()
		pad_mesh.size = pad_size
		pad.mesh = pad_mesh
		pad.material_override = _pad_material
		pad.position = Vector3(bay.x, pad_y, bay.z)
		add_child(pad)


# Find the match director's current_map so _add_dock_pads can sample terrain
# height at each bay's world XZ. Walks the tree to the first node with a
# `current_map` member (the director is the only one in a live match).
# Returns an empty dict if none found - callers fall back to fixed Y offsets.
func _resolve_world_map() -> Dictionary:
	if not is_inside_tree():
		return {}
	var root: Window = get_tree().root
	if root == null:
		return {}
	for child in root.get_children():
		if "current_map" in child and child.current_map is Dictionary:
			return child.current_map
	return {}


# mechanism - a proxy on the selection layer carrying a back-reference. Clicking
# a manufactory is how the radial menu for its queue is raised.
func _add_selection_proxy() -> void:
	var area := Area3D.new()
	area.name = "SelectionProxy"
	area.collision_layer = LayersScript.SELECTION
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("structure", self)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = footprint
	col.shape = box
	col.position = Vector3(0, footprint.y * 0.5, 0)
	area.add_child(col)
	add_child(area)


# --- Dock bays ---------------------------------------------------------------

func bay_count() -> int:
	return _bays.size()


func bay_position(index: int) -> Vector3:
	if index < 0 or index >= _bay_offsets.size():
		return global_position
	return global_position + (_bay_offsets[index] as Vector3)


# Claims a free bay for `unit`, or returns -1 if all are taken.
#
# Idempotent: a unit that already holds a bay gets the same one back rather than
# a second. Without that, a harvester re-asking on any state re-entry would leak
# reservations until the refinery permanently reported itself full.
func reserve_bay(unit: Node) -> int:
	for i in range(_bays.size()):
		if _bays[i] == unit:
			return i
	for i in range(_bays.size()):
		# A reservation held by a freed unit is reclaimed here rather than
		# needing the dying unit to have cleaned up. Deaths happen in any order.
		if _bays[i] == null or not is_instance_valid(_bays[i]):
			_bays[i] = unit
			return i
	return -1


func release_bay(unit: Node) -> void:
	for i in range(_bays.size()):
		if _bays[i] == unit:
			_bays[i] = null
			return


# --- Unit exit ---------------------------------------------------------------

# Where a finished unit appears. Mirrored for team 1 so both bases eject toward
# the middle of the map rather than one of them ejecting into its own back wall.
func exit_position() -> Vector3:
	var offset: Vector3 = BuildingCatalogScript.get_stat(kind, "exit_offset", Vector3(0, 0.5, 6.0))
	if team != 0:
		offset.z = -offset.z
	return global_position + offset


# --- Damage ------------------------------------------------------------------

# Same three-argument contract as BattleUnit, because auto_weapon.gd does not
# know or care which one it hit - it duck-types anything in the `damageable`
# group. A one-argument version here is a runtime error on every shell that lands
# on a building.
#
# Structures take the damage-class reduction but NOT the facet or subsystem
# rules: a building has no armour facets to flank and no modules to strip, so
# there is nothing for those to act on. Routing through the resolver anyway is
# what keeps a thermal weapon good against buildings and a kinetic one mediocre,
# instead of every gun doing flat damage to bases.
func take_damage(amount: float, damage_type: String = "kinetic", hit_origin = null) -> void:
	if is_dead:
		return

	var resolved := DamageModelScript.resolve(null, [], damage_type, self, hit_origin)
	hp = maxf(0.0, hp - DamageModelScript.hull_damage(amount, resolved.x, resolved.y))
	if hp > 0.0:
		return

	is_dead = true
	# Every held bay is freed, or harvesters queued on a dead refinery wait
	# on a reservation that will never come.
	_bays.fill(null)
	died.emit(self)
	queue_free()


func repair_hp(amount: float) -> void:
	if is_dead or hp >= max_hp:
		return
	hp = minf(max_hp, hp + amount)


# --- Fog of war --------------------------------------------------------------
#
# Structures are THREE-state, unlike units. A building the player has seen once
# stays drawn where it was after it leaves vision, because a base does not move
# and forgetting it would be a lie the player can trivially disprove. Only a
# never-seen building is hidden outright.
var fog_hidden: bool = false
var fog_ever_seen: bool = false


func set_fog_visible(value: bool) -> void:
	fog_hidden = not value
	if value:
		fog_ever_seen = true
	visible = value or fog_ever_seen


# --- Construction Animation and Lifecycle ------------------------------------

func begin_construction(_build_time: float = 0.0) -> void:
	build_incomplete = true
	is_under_construction = true
	construction_progress = 0.0
	_gather_visual_nodes()
	_build_construction_visuals()
	update_construction_progress(0.0, false)


var _visual_node_transforms: Dictionary = {}
var _last_progress_pct: int = -1

func _gather_visual_nodes() -> void:
	_visual_nodes.clear()
	_visual_node_transforms.clear()
	var b_mesh = get_node_or_null("BuildingMesh")
	if b_mesh is Node3D:
		_visual_nodes.append(b_mesh)
	if _mesh != null and is_instance_valid(_mesh):
		_visual_nodes.append(_mesh)
	if defense_hull != null and is_instance_valid(defense_hull):
		_visual_nodes.append(defense_hull)
	for node in _visual_nodes:
		_visual_node_transforms[node.get_instance_id()] = {
			"scale": node.scale,
			"position": node.position,
		}


func _build_construction_visuals() -> void:
	if _construction_root != null and is_instance_valid(_construction_root):
		_construction_root.queue_free()
	
	_construction_root = Node3D.new()
	_construction_root.name = "ConstructionVisuals"
	add_child(_construction_root)

	# 1. Scaffolding cage around the footprint
	var scaffold := MeshInstance3D.new()
	scaffold.name = "ScaffoldMesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = footprint + Vector3(0.4, 0.4, 0.4)
	scaffold.mesh = box_mesh
	scaffold.position = Vector3(0, footprint.y * 0.5, 0)
	
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.75, 0.2, 0.2)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	scaffold.material_override = mat
	_construction_root.add_child(scaffold)

	# 2. Corner steel posts for industrial scaffolding feel
	var half_x: float = footprint.x * 0.5 + 0.2
	var half_z: float = footprint.z * 0.5 + 0.2
	var corners = [
		Vector3(-half_x, footprint.y * 0.5, -half_z),
		Vector3(half_x, footprint.y * 0.5, -half_z),
		Vector3(-half_x, footprint.y * 0.5, half_z),
		Vector3(half_x, footprint.y * 0.5, half_z),
	]
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.9, 0.7, 0.1)
	post_mat.roughness = 0.6
	for c_pos in corners:
		var post := MeshInstance3D.new()
		var p_mesh := BoxMesh.new()
		p_mesh.size = Vector3(0.2, footprint.y + 0.5, 0.2)
		post.mesh = p_mesh
		post.material_override = post_mat
		post.position = c_pos
		_construction_root.add_child(post)

	# 3. Welding sparks particles
	_spark_particles = CPUParticles3D.new()
	_spark_particles.name = "WeldingSparks"
	_spark_particles.amount = 32
	_spark_particles.lifetime = 0.5
	_spark_particles.explosiveness = 0.1
	_spark_particles.randomness = 0.5
	_spark_particles.lifetime_randomness = 0.4
	_spark_particles.direction = Vector3(0, 1, 0)
	_spark_particles.spread = 160.0
	_spark_particles.gravity = Vector3(0, -12.0, 0)
	_spark_particles.initial_velocity_min = 2.5
	_spark_particles.initial_velocity_max = 6.0
	_spark_particles.color = Color(1.0, 0.85, 0.35, 1.0)
	_spark_particles.position = Vector3(0, 0.5, 0)
	_spark_particles.emitting = true
	_construction_root.add_child(_spark_particles)

	# 4. 3D Diegetic Progress Display (Label + Progress Bar)
	var ui_anchor := Node3D.new()
	ui_anchor.name = "ProgressUI"
	ui_anchor.position = Vector3(0, footprint.y + 1.2, 0)
	_construction_root.add_child(ui_anchor)

	_progress_label = Label3D.new()
	_progress_label.name = "ProgressLabel"
	_progress_label.text = "CONSTRUCTING 0%"
	_progress_label.font_size = 28
	_progress_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_progress_label.outline_size = 6
	_progress_label.modulate = Color(0.4, 0.9, 1.0)
	_progress_label.position = Vector3(0, 0.4, 0)
	ui_anchor.add_child(_progress_label)

	# Background bar
	var bar_bg := MeshInstance3D.new()
	var bg_mesh := BoxMesh.new()
	bg_mesh.size = Vector3(2.4, 0.18, 0.04)
	bar_bg.mesh = bg_mesh
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.05, 0.06, 0.08, 0.85)
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bar_bg.material_override = bg_mat
	ui_anchor.add_child(bar_bg)

	# Fill bar
	_progress_bar_fill = MeshInstance3D.new()
	var fill_mesh := BoxMesh.new()
	fill_mesh.size = Vector3(2.36, 0.14, 0.06)
	_progress_bar_fill.mesh = fill_mesh
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.2, 0.85, 0.95, 1.0)
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_progress_bar_fill.material_override = fill_mat
	ui_anchor.add_child(_progress_bar_fill)


func update_construction_progress(progress: float, is_stalled: bool = false) -> void:
	construction_progress = clampf(progress, 0.0, 1.0)
	var pct := int(round(construction_progress * 100.0))
	
	# Animate the visual model rising / scaling from foundation
	var y_scale = clampf(construction_progress, 0.04, 1.0)
	for node in _visual_nodes:
		if is_instance_valid(node):
			var orig = _visual_node_transforms.get(node.get_instance_id(), {"scale": Vector3.ONE, "position": node.position})
			var orig_scale: Vector3 = orig["scale"]
			var orig_pos: Vector3 = orig["position"]
			node.scale = Vector3(orig_scale.x, orig_scale.y * y_scale, orig_scale.z)
			# Anchor base to ground during scale
			node.position = Vector3(orig_pos.x, orig_pos.y * y_scale, orig_pos.z)

	# Move welding spark height with the rising roof
	if _spark_particles != null and is_instance_valid(_spark_particles):
		_spark_particles.position.y = footprint.y * construction_progress + 0.2
		_spark_particles.emitting = not is_stalled and construction_progress < 1.0

	# Throttle 3D Progress readout updates to whole percentage changes
	if pct != _last_progress_pct:
		_last_progress_pct = pct
		if _progress_label != null and is_instance_valid(_progress_label):
			if is_stalled:
				_progress_label.text = "STALLED (%d%%)" % pct
				_progress_label.modulate = Color(1.0, 0.4, 0.3)
			else:
				_progress_label.text = "BUILDING %d%%" % pct
				_progress_label.modulate = Color(0.35, 0.9, 1.0)

		if _progress_bar_fill != null and is_instance_valid(_progress_bar_fill):
			var fill_pct = maxf(0.01, construction_progress)
			_progress_bar_fill.scale = Vector3(fill_pct, 1.0, 1.0)
			_progress_bar_fill.position.x = -1.18 * (1.0 - fill_pct)
			if _progress_bar_fill.material_override != null:
				_progress_bar_fill.material_override.albedo_color = (
					Color(1.0, 0.4, 0.2) if is_stalled else Color(0.2, 0.85, 0.95)
				)


func finish_construction() -> void:
	build_incomplete = false
	is_under_construction = false
	construction_progress = 1.0

	# Restore full original mesh transforms and scales
	for node in _visual_nodes:
		if is_instance_valid(node):
			var orig = _visual_node_transforms.get(node.get_instance_id(), {"scale": Vector3.ONE, "position": node.position})
			node.scale = orig["scale"]
			node.position = orig["position"]

	# Remove scaffolding and progress UI
	if _construction_root != null and is_instance_valid(_construction_root):
		_construction_root.queue_free()
		_construction_root = null

	# Spawn brief completion burst particles
	var burst := CPUParticles3D.new()
	burst.amount = 24
	burst.lifetime = 0.8
	burst.one_shot = true
	burst.explosiveness = 0.9
	burst.direction = Vector3(0, 1, 0)
	burst.spread = 180.0
	burst.gravity = Vector3(0, -9.8, 0)
	burst.initial_velocity_min = 3.0
	burst.initial_velocity_max = 7.0
	burst.color = Color(0.4, 1.0, 0.6, 0.9)
	burst.position = Vector3(0, footprint.y * 0.5, 0)
	burst.emitting = true
	add_child(burst)
	
	# Auto-free completion burst
	get_tree().create_timer(1.2).timeout.connect(func():
		if is_instance_valid(burst):
			burst.queue_free()
	)

