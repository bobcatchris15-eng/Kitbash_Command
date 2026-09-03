class_name VisualBuilder
# Assembles the visual mesh tree for a placed module. Prefers authored .glb
# "kit" parts (tools/blender/build_meshes.py) for a detailed/greebled look,
# falling back to the original procedural primitives when no authored asset
# exists yet. Authored cylindrical/dome/leg/mast/tank/wheel parts are built
# along local Y (matching Godot's own CylinderMesh default axis), so every
# existing runtime rotation/positioning call below applies identically to
# both the authored and procedural mesh - only the `.mesh` source differs.

const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const GlobalConfigScript = preload("res://scripts/global_config.gd")
const PartMaterialsScript = preload("res://scripts/part_materials.gd")
const HullProjectionScript = preload("res://scripts/hull_projection.gd")
const MountReachScript = preload("res://scripts/mount_reach.gd")
const ModuleVolumeScript = preload("res://scripts/module_volume.gd")
const LocomotionLayoutScript = preload("res://scripts/locomotion_layout.gd")

# mesh instance-id -> PartMaterials role, populated by _part() as assets load.
#
# This exists so material ROLES can be applied to all ~190 authored parts
# without touching the several hundred `_mesh_inst(_part("x"), colour)` call
# sites in this file. _part() is the single chokepoint every authored asset
# passes through and it is the only place that still knows the part's NAME -
# by the time _mesh_inst() sees it, it's an anonymous Mesh. So the name's
# classification is recorded here on the way past, keyed by the mesh resource
# MeshAssetLoader already caches (identity is stable for the process, so one
# entry per part, not one per instance).
#
# A mesh that isn't in here - every procedural BoxMesh/CylinderMesh fallback
# in this file - resolves to PartMaterials.DEFAULT_ROLE, which is still a
# properly finished metal rather than the flat matte plastic everything used
# to get. Nothing degrades; unclassified things just stay generic.
static var _part_roles: Dictionary = {}

static func _part(part_name: String) -> Mesh:
	var mesh: Mesh = MeshAssetLoader.get_part_mesh(part_name)
	if mesh != null:
		var id := mesh.get_instance_id()
		if not _part_roles.has(id):
			_part_roles[id] = PartMaterialsScript.role_for_part(part_name)
	return mesh

# Procedural running-gear slab (locomotion grounding fix). A flat dark-metal
# chassis that sits under the hull, sized to the hull's XZ with a small
# inset, with the wheels/treads/legs/screws/hover-pads mounting to its
# sides instead of to the hull's bare underside. Two real jobs at once:
#
# 1. Visual chassis: previously, side-mount locomotion (wheels/treads/etc.)
#    were placed straight against the hull skin, with the hull's authored
#    mesh often leaving a visible gap between the part and the hull surface
#    on hulls whose underside doesn't sit at the catalog bottom (per the
#    underside_y_bias hack). A real chassis reads as a deliberate
#    intermediary between hull and running gear.
# 2. Physics grounding: the CharacterBody3D's collider in unit.gd
#    was sized to the hull only, so a wheeled unit sat on the hull's
#    underside with wheels dangling in midair (test arena: "vehicle slides
#    on its belly"). The unit's collider now extends to include the
#    running-gear height (see unit.gd), and the running gear's
#    StaticBody3D carries the matching physics shape so designer-mode ray
#    casts and click-to-select also see a flat bottom, not a hull-bottom.
#
# Returns the StaticBody3D so callers can re-position or query it.
# The body is returned at the parent's local origin - callers are
# responsible for translating it to the right hull-local Y (conventionally
# -hull_size.y/2 - dimensions.y/2, so the chassis's TOP sits flush with
# the hull's underside and the chassis hangs BELOW the hull).
#
# collision_layer defaults to 1 (matching the designer-mode hull's own
# StaticBody3D layer, for click/raycast selection) but MUST be 0 when built
# under a unit.gd CharacterBody3D: that body's collision_mask is 1
# ("Ground only"), so a layer-1 RunningGear sitting right at its own feet
# reads as terrain and it perpetually pushes itself off its own chassis -
# the battle-arena "constantly bouncing" bug. unit.gd's own
# CollisionShape3D already provides the real physics collider in that case;
# this body's collider is purely for the designer-raycast/dimension-lookup
# use, so it can safely be collision-free there.
## The tight bounds of everything a module actually DRAWS, in that module's own
## local space. Used to find where running gear really ends so the hull can be
## lifted until it touches the ground.
##
## Lives here, rather than in whichever file needed it first, because both the
## Design Lab (module_placer.gd's GROUND CONTACT block) and the battle spawner
## (blueprint_manager.gd's reconstruct_vehicle) have to measure ride height
## identically or a design sits at a different height in a match than it did in
## the lab. That is exactly the drift that made the second caller necessary -
## the battle path had its own hand-tuned constants, which only covered wheels
## and legs and read a tweak key that does not exist.
##
## Walks up through intermediate pivots deliberately: locomotion builders nest
## parts under named pivots (rotor hubs, leg knees) that carry real offsets, so
## a mesh's own AABB means nothing without them.
##
## DELEGATES to module_volume.gd, which owns the measurement now. This used to
## be its own copy of the walk, and the copy had drifted: it skipped overlay
## geometry by matching the MESH's name only, so a module that was SELECTED
## measured its Gizmo3D handle meshes (all named plain "MeshInstance3D", parked
## out at the module's extents) into its own bounds. module_volume filters by
## the whole ancestor chain instead, which is what module_placer's separate
## _find_meshes_recursive() had always done.
##
## Kept as the entry point because ride-height and click-collider callers want
## the single merged box, not the parallelepiped list underneath it.
static func measure_visual_bounds(module: Node3D) -> AABB:
	return ModuleVolumeScript.bounds(module)

static func build_running_gear(parent_node: Node3D, dimensions: Vector3, base_color: Color, collision_layer: int = 1, type_id: String = "", hardpoints: Array = []) -> StaticBody3D:
	var body = StaticBody3D.new()
	body.name = "RunningGear"
	body.collision_layer = collision_layer
	body.collision_mask = 0

	# Collider: matching box for grounding and raycast selection.
	var col = CollisionShape3D.new()
	var col_box = BoxShape3D.new()
	col_box.size = dimensions
	col.shape = col_box
	body.add_child(col)

	parent_node.add_child(body)
	# Ground and hover types ride a real subframe; naval and airborne ones do
	# not (see build_subframe). An empty hardpoint list still yields a frame -
	# just a plain two-bay one - so a type that has not published its stations
	# yet degrades to something sensible rather than to nothing.
	if LocomotionLayoutScript.uses_subframe(type_id):
		build_subframe(body, dimensions, base_color, hardpoints)
	return body

static func _mesh_inst(mesh: Mesh, color: Color, emission: Color = Color(0, 0, 0, 0), emission_energy: float = 0.0, role_override: String = "") -> MeshInstance3D:
	var inst = MeshInstance3D.new()
	inst.mesh = mesh
	# This used to build a bare StandardMaterial3D with nothing set but
	# albedo_color, which is Godot's default metallic 0.0 / roughness 1.0 -
	# i.e. matte plastic - for every barrel, lens, tyre and brass fitting
	# alike. See part_materials.gd for the full reasoning; the short version
	# is that the parts were differentiated by geometry and by paint colour
	# but not by SUBSTANCE, and materials are shared per role+tint so the
	# battle-side mesh merge still collapses them.
	var role := role_override
	if role == "" and mesh != null:
		role = _part_roles.get(mesh.get_instance_id(), PartMaterialsScript.DEFAULT_ROLE)
	inst.material_override = PartMaterialsScript.get_material(role, color, emission, emission_energy)
	return inst

# Plain albedo material for a procedurally-built primitive. The roster
# expansion's fallback paths each needed the same four lines of
# StandardMaterial3D setup, which is a lot of noise repeated ~15 times in
# what is only ever the "authored mesh is missing" branch.
static func _flat_mat(color: Color) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

# --- Structural piece helpers ----------------------------------------------
# See the `structural_` branch of build_visual() for the design: parametric
# body, fixed-size authored hardware bolted onto it.

# Every authored hardware instance is named with this prefix. module_placer.gd
# repaints a structural piece's meshes with the faction hull shader so the
# piece matches the vehicle it's bolted to; that pass skips anything named
# with this prefix, which is what keeps the fasteners reading as bare steel
# against faction-liveried plate instead of the whole thing turning into one
# flat shader.
const HARDWARE_PREFIX := "Hardware_"

# Names of the pivot nodes unit.gd spins. Locomotion animation has always
# worked by looking a pivot up BY NAME, but the names were string literals
# duplicated across the builder and the animator, and three types
# (wheels, tracked_treads, fixed_wing_engine) simply never got a pivot - so a
# rolling tank's treads and road wheels sat frozen while the helicopter parked
# next to it span its rotor forever. Declared here so the two files agree.
#
# Godot uniquifies duplicate sibling names ("WheelSpin", "WheelSpin2", ...),
# which is why the animator matches these as a PREFIX rather than exactly.
const SPIN_PIVOT_WHEEL := "WheelSpin"
const SPIN_PIVOT_TREAD := "TreadSpin"
const SPIN_PIVOT_TURBINE := "TurbineFan"

# Belt band mesh instances are named with this prefix so unit.gd can find
# them and scroll their UVs, instead of rotate_x-ing the whole band/bogie
# (which used to either not animate at all - tracked_treads - or tumble the
# entire assembly end-over-end - half_track / heavy_quad_tracks).
const BELT_BAND_NAME := "TreadBeltBand"
const TREAD_BELT_SHADER := preload("res://shaders/tread_belt.gdshader")

# Remaining animated-pivot names, unified for the same reason as the
# SPIN_PIVOT_*/BELT_BAND_NAME block above: every one of these used to be a
# bare string literal independently duplicated across visual_builder.gd,
# module_placer.gd (Lab preview animation) and unit.gd (battle animation).
# hover_engine's rings and plasma_thruster's ring specifically caused live
# bugs (a Lab-only path that looked fine and a battle bake that silently
# dropped the animated part) - see the commit history at _ANIMATED_PART_NAMES
# below. Reference these constants everywhere; never retype the string.
const PIVOT_BARREL_CLUSTER := "BarrelCluster"
const PIVOT_ROTOR_BLADES := "RotorBlades"
const PIVOT_WING := "WingPivot"
const PIVOT_WING_FORE := "WingPivotFore"
const PIVOT_WING_HIND := "WingPivotHind"
const PIVOT_PROP_BLADES := "PropBlades"
const PIVOT_SCREW_SPIN := "ScrewSpin"
const HOVER_RING_OUTER := "HoverRingOuter"
const HOVER_RING_MID := "HoverRingMid"
const HOVER_RING_INNER := "HoverRingInner"
const PIVOT_PLASMA_RING := "PlasmaRing"

# One ShaderMaterial per belt instance - uv_offset is per-vehicle animation
# state, so this must never be a single cached/shared material the way
# get_flame_arc_material() is for a VFX emitter.
static func _belt_material(color: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TREAD_BELT_SHADER
	mat.set_shader_parameter("albedo_color", color)
	mat.set_shader_parameter("uv_offset", 0.0)
	return mat

# The leg chain. LegSwing is ours - built by _build_legs() and, unlike the spin
# pivots above, matched EXACTLY rather than as a prefix, because there is one
# per leg module and Godot never has to uniquify it.
#
# The three Bone_* names come from the authored .glb files and are identical
# across all six leg sets. That shared naming IS the contract that lets one
# animation path drive every set - if a re-exported leg renames a bone, the limb
# below it silently stops articulating, which is what
# test_leg_sets_expose_the_full_bone_chain exists to catch.
const LEG_PIVOT_SWING := "LegSwing"
const LEG_PIVOT_HIP := "Bone_Part1_HipMount"
const LEG_PIVOT_THIGH := "Bone_Part2_Thigh"
const LEG_PIVOT_SHIN := "Bone_Part3_ShinFoot"

# Where _build_legs() stashes a bone's rest rotation so the animator can add to
# it instead of overwriting it. The .glb ships each bone in a posed rest
# rotation; without this the first animated frame would snap it to zero and the
# limb would look like it collapsed the moment the machine started walking.
const LEG_REST_META := "leg_rest_x"

# How far the sole hangs below the leg's station, per unit of leg_length.
#
# 1.632 is the previously-shipped ride height (1.088) times the half-again Chris
# asked for after seeing the authored sets in the Lab: "the default legs need to
# be larger to sell it, probably half again as tall".
#
# Where 1.088 came from, since it looks arbitrary: the procedural build used
# 1.35 here, but its splayed assembly tripped the layout's outboard width clamp,
# which scaled the whole module to 0.7958 - so what a player actually saw was
# 1.35 * 0.7958 = 1.088. The authored sets are narrow enough not to trip that
# clamp, so they arrive at scale 1.0 and the effective drop has to be spelled
# out here instead of emerging from a clamp firing.
#
# Worth knowing before raising it further: "the body should sit LOW between the
# legs" is a standing note, and two earlier passes had to undo giant-spider
# proportions. This is the one number that decides it.
const LEG_DROP_PER_LENGTH := 1.632

# Cross-section multiplier, applied to the limb's X and Z but NOT its Y.
#
# The height solve owns Y (that is what lands the sole on the ground at a
# predictable ride height), so "make them chunkier" cannot be a uniform scale -
# it has to be the two axes the solve does not care about. Chris, on first
# seeing them in the Lab: "at least double the girthiness".
const LEG_GIRTH := 2.0
const HARDWARE_COLOR := Color(0.27, 0.27, 0.30)

static var _hardware_mat_cache: StandardMaterial3D = null

static func _hardware_mat() -> StandardMaterial3D:
	if _hardware_mat_cache == null:
		_hardware_mat_cache = StandardMaterial3D.new()
		_hardware_mat_cache.albedo_color = HARDWARE_COLOR
		# Harder and shinier than the painted plate it sits on - the contrast
		# between bare fastener and liveried structure is the whole reason the
		# faction repaint skips these.
		_hardware_mat_cache.metallic = 0.85
		_hardware_mat_cache.roughness = 0.35
	return _hardware_mat_cache

static func _structural_body_mat(color: Color) -> StandardMaterial3D:
	# Routed through the shared role palette rather than a hand-rolled
	# StandardMaterial3D so structural plate gets the same triplanar wear
	# texture everything else now has. It matters most in BATTLE: the Design
	# Lab repaints these with the faction hull shader (module_placer), but
	# blueprint_manager's battle reconstruction doesn't, so on the field this
	# is the material a structural piece actually wears - and unpainted it
	# was a flat matte slab next to hulls carrying a full wear/grime shader.
	return PartMaterialsScript.get_material("painted", color)

# Instances one authored hardware part at its TRUE authored size. There is
# deliberately no scale argument: the whole point of the split is that this
# geometry never stretches with the body. Silently no-ops if the .glb is
# missing so a fresh checkout that hasn't run the Blender build yet still
# renders the bodies rather than erroring out mid-build.
#
# `uniform_scale` is the ONE scaling allowance, and it is uniform on purpose:
# stretching authored hardware anisotropically is the smearing this whole
# design exists to prevent, but scaling it evenly just makes a bigger version
# of the same object with every proportion intact. Used for the handful of
# details that are crew-scale references rather than fasteners - a dome hatch
# authored at fastener size reads as a coin on a 2.5-unit cupola.
static func _hardware(parent_node: Node3D, part_name: String, pos: Vector3, rot: Vector3, uniform_scale: float = 1.0) -> MeshInstance3D:
	var mesh = _part(part_name)
	if mesh == null:
		return null
	var inst = MeshInstance3D.new()
	inst.mesh = mesh
	# ONE shared material across every hardware instance, not one per instance
	# like _mesh_inst() would make. A stretched block can carry 60 of these,
	# and bake_module_visual() groups its merge by material IDENTITY - 60
	# separate-but-identical StandardMaterial3Ds would defeat the merge
	# entirely and ship 60 draw calls per structural piece into a battle.
	inst.material_override = _hardware_mat()
	inst.position = pos
	inst.rotation = rot
	if not is_equal_approx(uniform_scale, 1.0):
		inst.scale = Vector3.ONE * uniform_scale
	parent_node.add_child(inst)
	# Named AFTER add_child, and with an explicit unique suffix. Setting a
	# colliding name on a not-yet-parented node makes Godot 4 throw the name
	# away entirely and fall back to a generated "@MeshInstance3D@7" - so with
	# the obvious ordering, only the FIRST of each hardware kind kept its name
	# and every other one silently lost the HARDWARE_PREFIX that the faction-
	# repaint exemption in module_placer keys off.
	inst.name = "%s%s_%d" % [HARDWARE_PREFIX, part_name, parent_node.get_child_count()]
	return inst

# How many fixed-size details fit along `span` at roughly `spacing` apart.
# This is the function that makes stretching work: it is the COUNT that grows
# with the body, never the size of the individual detail.
static func _hardware_count(span: float, spacing: float, lo: int = 1, hi: int = 20) -> int:
	return clampi(int(round(abs(span) / max(0.01, spacing))), lo, hi)

# Yaw that points a corner bracket's two arms inward along the faces meeting
# at corner (sx, sz). The bracket is authored with arms along +X and -Z.
static func _corner_yaw(sx: float, sz: float) -> float:
	if sx > 0.0 and sz > 0.0: return PI / 2.0
	if sx < 0.0 and sz > 0.0: return PI
	if sx < 0.0 and sz < 0.0: return -PI / 2.0
	return 0.0

# Tie-down grid across a deck surface at height `y`. Spacing is fixed, so a
# bigger deck gets more tie-downs rather than bigger ones.
static func _deck_tie_downs(parent_node: Node3D, base_size: Vector3, y: float, spacing: float = 0.95) -> void:
	var nx = _hardware_count(base_size.x, spacing, 1, 8)
	var nz = _hardware_count(base_size.z, spacing, 1, 8)
	for i in range(nx):
		for j in range(nz):
			var tx = (float(i) + 0.5) / float(nx) - 0.5
			var tz = (float(j) + 0.5) / float(nz) - 0.5
			_hardware(parent_node, "struct_tie_down",
				Vector3(tx * base_size.x * 0.82, y, tz * base_size.z * 0.82), Vector3.ZERO)

# Shared beam dressing for the girder and the I-beam: splice collars at fixed
# stations along the run, and a bolted end cap on each end. The collar's ring
# axis is authored along -Z (Blender +Y), which is already the beam's run, so
# no rotation is needed on those.
static func _beam_hardware(parent_node: Node3D, base_size: Vector3) -> void:
	var collars = _hardware_count(base_size.z, 1.05, 1, 8)
	for i in range(collars):
		var t = (float(i) + 0.5) / float(collars) - 0.5
		_hardware(parent_node, "struct_splice_collar",
			Vector3(0, base_size.y / 2.0, t * base_size.z * 0.86), Vector3.ZERO)
	for sz in [-1.0, 1.0]:
		# The cap is authored facing -Z; the +Z end needs a half turn.
		_hardware(parent_node, "struct_beam_end_cap",
			Vector3(0, base_size.y / 2.0, sz * base_size.z * 0.5),
			Vector3(0, 0.0 if sz < 0.0 else PI, 0))

# Which monolithic authored parts get their mesh wrapped in a named animation
# pivot, and under what name - see the pivot block in build_visual() below.
#
# Only types where rotating the WHOLE module is the correct motion are listed.
# rotary_cannon is deliberately absent: its "BarrelCluster" pivot is meant to
# spin the barrel ring while the mount stays put, and the authored mesh fuses
# barrels and mount into one object - wrapping it would spin the entire gun on
# its side, which is worse than leaving it static. That one needs the barrels
# authored as a separate mesh before it can animate.
const MONOLITHIC_ANIMATION_PIVOTS := {
	"helicopter_rotors": PIVOT_ROTOR_BLADES,
	"ornithopter_wing": PIVOT_WING,
	"ship_screw": PIVOT_PROP_BLADES,
	"propeller_prop": PIVOT_PROP_BLADES,
	"pusher_prop": PIVOT_PROP_BLADES,
	"paddle_wheel": PIVOT_PROP_BLADES,
}

const LOCOMOTION_MODULAR_TYPES := {
	"wheels": true, "helicopter_rotors": true, "tracked_treads": true, "heavy_quad_tracks": true, "legs": true,
	"hover_engine": true, "ornithopter_wing": true,
	"buoyant_envelope": true, "screw_drive": true,
	"half_track": true, "rocker_bogie": true, "air_cushion_skirt": true,
	"anti_grav_plate": true, "plasma_thruster": true,
}

# What _assert_animated_pivots() (called right after the match dispatch below)
# requires each modular locomotion type to have actually produced, keyed by
# the SAME constants unit.gd/module_placer.gd look up at animation time. This
# is the guard against the exact failure class fixed in 29e63230: a type in
# this table that resolves an empty pivot set is a builder/animator naming
# mismatch, and it fails loudly here at build time instead of silently
# freezing in the Lab or (worse) in battle. "prefix" true means the animator
# matches this name as a find_children() prefix (Godot uniquifies duplicate
# sibling names); false means it is looked up by exact name, possibly nested
# (plasma_thruster's ring sits under PodRoot, not a direct child).
const EXPECTED_ANIMATED_PIVOTS := {
	"wheels": [{"name": SPIN_PIVOT_WHEEL, "prefix": true}],
	"rocker_bogie": [{"name": SPIN_PIVOT_WHEEL, "prefix": true}],
	"tracked_treads": [{"name": SPIN_PIVOT_TREAD, "prefix": true}],
	"heavy_quad_tracks": [{"name": BELT_BAND_NAME, "prefix": true}],
	"half_track": [{"name": BELT_BAND_NAME, "prefix": true}, {"name": SPIN_PIVOT_WHEEL, "prefix": true}],
	"helicopter_rotors": [{"name": PIVOT_ROTOR_BLADES, "prefix": false}],
	"ornithopter_wing": [
		{"name": PIVOT_WING_FORE, "prefix": false},
		{"name": PIVOT_WING_HIND, "prefix": false},
	],
	"hover_engine": [
		{"name": HOVER_RING_MID, "prefix": false},
		{"name": HOVER_RING_INNER, "prefix": false},
	],
	"screw_drive": [{"name": PIVOT_SCREW_SPIN, "prefix": false}],
	"buoyant_envelope": [{"name": PIVOT_PROP_BLADES, "prefix": false}],
	"plasma_thruster": [{"name": PIVOT_PLASMA_RING, "prefix": false}],
	"legs": [{"name": LEG_PIVOT_SWING, "prefix": false}],
}

# Fails loudly (push_error, not a comment asking future readers to be
# careful) if a locomotion type in EXPECTED_ANIMATED_PIVOTS just built a
# module with none of its required pivots present. This is a build-time
# check of exactly the defect class that shipped hover_engine broken: the
# keep-list and the writer disagreeing about a name with no error anywhere.
static func _assert_animated_pivots(type_id: String, module: Node3D) -> void:
	if not EXPECTED_ANIMATED_PIVOTS.has(type_id):
		return
	for req in EXPECTED_ANIMATED_PIVOTS[type_id]:
		var pivot_name: String = req["name"]
		var found: Node = null
		if req["prefix"]:
			var matches := module.find_children(pivot_name + "*", "Node3D", true, false)
			if matches.size() > 0:
				found = matches[0]
		else:
			found = module.find_child(pivot_name, true, false)
		if found == null:
			push_error("VisualBuilder: locomotion type '%s' built with no '%s' animation pivot - builder/animator name mismatch, this part will not animate" % [type_id, pivot_name])

# Firing elevation applied as a PIVOT ROTATION for the two weapons whose barrels
# used to have their elevation baked into the mesh. Must match
# ASSEMBLY_ELEVATION_DEG in tools/blender/build_artillery.py / build_mortar.py -
# those scripts author the tube along -Z at zero elevation and record here the
# angle the mount is supposed to restore.
const ARTILLERY_ELEVATION_DEG := 35.0
const MORTAR_ELEVATION_DEG := 60.0
const NAPALM_ELEVATION_DEG := 55.0

# Anti-materiel rifle assembly stations, MEASURED from the authored .glb
# AABBs rather than estimated. amr_breech's front face sits at z = -0.168 and
# amr_barrel spans z = -1.040 .. 0.0 with its origin on its own rear face, so
# the barrel mounts exactly at the breech's face and the muzzle brake belongs
# one authored barrel-length beyond it. These were estimated at first and the
# barrel hung 0.11 units clear of the breech in mid-air; re-measure if the
# meshes change.
const AMR_BREECH_FRONT_Z := -0.168
const AMR_BARREL_LEN := 1.040
const AMR_BUFFER_Z := 0.42

# Same story for the two receivers that share the mk19/autocannon assembly
# branch - measured off their own meshes, not shared between them.
const MK19_RECEIVER_FRONT_Z := -0.16
const AUTOCANNON_RECEIVER_FRONT_Z := -0.102
const AUTOCANNON_DRUM_FLOOR := 0.262
const AUTOCANNON_DRUM_Z := 0.11

# Energy-bracket stations, measured from the exported AABBs.
const ARC_BODY_FRONT_Z := -0.040
const MICROWAVE_BODY_FRONT_Z := -0.080
const LANCE_BREECH_FRONT_Z := -0.130
const LANCE_BREECH_REAR_Z := 0.160

# Indirect-fire and missile stations, measured from the exported AABBs.
const SPIGOT_BREECH_FRONT_Z := -0.060
const ROCKET_CRADLE_FRONT_Z := -0.070
const AA_RECEIVER_FRONT_Z := -0.082

# The six guided launchers share a pedestal and an assembly path. Each entry
# names the body that gives the launcher its identity, the round it carries,
# how many it carries by default (1 = a single centreline round), the tweak
# that scales that round, the measured front face of its body, and how far
# the whole assembly is canted up. Kept as data rather than as six
# near-identical match arms.
const MISSILE_LAUNCHER_PARTS := {
	"hypervelocity_missile": {"body": "hvm_body", "round": "hvm_canister", "default_count": 2,
		"scale_tweak": "seeker_size", "front_z": -0.064, "cant_deg": 6.0, "tint": Color(0.24, 0.25, 0.22)},
	"sam_launcher": {"body": "sam_body", "round": "sam_missile", "default_count": 2,
		"scale_tweak": "radar_dish", "front_z": -0.035, "cant_deg": 34.0, "tint": Color(0.72, 0.72, 0.70)},
	"loitering_munition": {"body": "loiter_body", "round": "loiter_tube", "default_count": 2,
		"scale_tweak": "seeker_size", "front_z": -0.098, "cant_deg": 62.0, "tint": Color(0.25, 0.27, 0.23)},
	"anti_radiation_missile": {"body": "arm_body", "round": "arm_missile", "default_count": 2,
		"scale_tweak": "seeker_size", "front_z": -0.106, "cant_deg": 14.0, "tint": Color(0.34, 0.36, 0.33)},
	"bunker_buster": {"body": "bb_body", "round": "bb_penetrator", "default_count": 1,
		"scale_tweak": "warhead_size", "front_z": -0.080, "cant_deg": 46.0, "tint": Color(0.19, 0.20, 0.21)},
	"cruise_missile": {"body": "cruise_body", "round": "cruise_container", "default_count": 1,
		"scale_tweak": "warhead_size", "front_z": -0.035, "cant_deg": 26.0, "tint": Color(0.29, 0.31, 0.27)},
}

const MODULAR_ASSEMBLY_TYPES := {
	"basic_cannon": true, "heavy_machine_gun": true, "rotary_cannon": true, "gauss_railgun": true,
	"artillery": true, "mortar_array": true, "guided_missile": true, "missile_pod": true,
	"cluster_dispenser": true, "flamethrower": true, "ion_cannon": true,
	"heavy_laser": true, "plasma_lobber": true, "ciws": true, "pd_laser": true, "flak_cannon": true,
	"smoke_discharger": true,
	"mk19_grenade_launcher": true, "recoilless_rifle": true, "coil_gun": true,
	"autocannon": true, "napalm_mortar": true, "mine_layer": true,
	"anti_materiel_rifle": true,
	"arc_projector": true, "microwave_emitter": true, "particle_lance": true,
	"spigot_mortar": true, "rocket_artillery": true,
	"hypervelocity_missile": true, "sam_launcher": true, "loitering_munition": true,
	"anti_radiation_missile": true, "bunker_buster": true, "cruise_missile": true,
	"aa_autocannon": true,
	"sensor_beacon_launcher": true,
	"wheels": true, "helicopter_rotors": true, "tracked_treads": true, "heavy_quad_tracks": true, "legs": true,
	"hover_engine": true, "ornithopter_wing": true,
	"buoyant_envelope": true, "screw_drive": true,
	"half_track": true, "rocker_bogie": true, "air_cushion_skirt": true,
	"anti_grav_plate": true, "plasma_thruster": true,
	# Support modules with dedicated modular assembly code - must bypass the
	# monolithic _part(type_id) path or their sub-part assembly branches are never reached.
	"sensor_suite": true, "heavy_sensor_suite": true, "directional_radar": true,
	"resource_harvester": true, "resource_bay": true,
	"repair_array": true, "drone_carrier": true,
	"energy_barrier_projector": true, "heavy_barrier_projector": true,
	"bubble_shield_projector": true,
	# Power & energy generation / storage modules
	"fusion_generator": true, "diesel_generator": true, "thermo_generator": true,
	"capacitor_bank": true, "flywheel_storage": true, "solid_state_battery": true,
}

const MODULAR_AUTHORED_SIZES := {
	"basic_cannon": Vector3(0.6, 0.6, 2.0),
	"heavy_machine_gun": Vector3(0.5, 0.5, 1.8),
	"rotary_cannon": Vector3(0.6, 0.6, 2.2),
	"gauss_railgun": Vector3(0.7, 0.7, 3.2),
	"artillery": Vector3(0.8, 0.8, 3.5),
	"mortar_array": Vector3(1.2, 0.6, 1.4),
	"guided_missile": Vector3(0.8, 0.6, 1.8),
	"missile_pod": Vector3(1.0, 0.8, 1.6),
	"cluster_dispenser": Vector3(0.9, 0.7, 1.5),
	"flamethrower": Vector3(0.5, 0.5, 1.6),
	"ion_cannon": Vector3(0.7, 0.7, 2.4),
	"heavy_laser": Vector3(0.6, 0.6, 2.2),
	"plasma_lobber": Vector3(0.8, 0.8, 2.0),
	"ciws": Vector3(0.8, 1.0, 1.2),
	"pd_laser": Vector3(0.5, 0.6, 0.8),
	"flak_cannon": Vector3(0.7, 0.7, 2.0),
	"wheels": Vector3(0.8, 0.8, 0.8),
	"tracked_treads": Vector3(0.9, 0.8, 2.8),
	"heavy_quad_tracks": Vector3(0.9, 0.7, 1.4),
	"helicopter_rotors": Vector3(2.4, 0.3, 2.4),
	"hover_engine": Vector3(0.9, 0.4, 0.9),
	"legs": Vector3(0.6, 1.2, 0.6),
	"ornithopter_wing": Vector3(2.6, 0.2, 0.8),
	"buoyant_envelope": Vector3(1.0, 0.5, 1.0),
	"screw_drive": Vector3(0.8, 0.8, 3.0),
	"half_track": Vector3(0.7, 0.6, 2.2),
	"rocker_bogie": Vector3(0.65, 0.9, 2.6),
	"air_cushion_skirt": Vector3(1.6, 0.45, 1.6),
	"anti_grav_plate": Vector3(0.9, 0.25, 0.9),
	"plasma_thruster": Vector3(0.9, 0.5, 1.2),
	"sensor_suite": Vector3(0.6, 2.2, 0.6),
	"heavy_sensor_suite": Vector3(1.1, 2.5, 1.1),
	"directional_radar": Vector3(1.0, 2.4, 0.8),
	"smoke_discharger": Vector3(0.5, 0.4, 0.5),
	"mk19_grenade_launcher": Vector3(0.4, 0.4, 1.1),
	"recoilless_rifle": Vector3(0.35, 0.35, 2.0),
	"coil_gun": Vector3(0.5, 0.5, 2.2),
	"autocannon": Vector3(0.35, 0.35, 1.4),
	"napalm_mortar": Vector3(0.7, 0.6, 0.7),
	"mine_layer": Vector3(0.9, 0.5, 0.9),
	"anti_materiel_rifle": Vector3(0.4, 0.4, 2.2),
	"arc_projector": Vector3(0.5, 0.5, 1.0),
	"microwave_emitter": Vector3(0.7, 0.6, 0.9),
	"particle_lance": Vector3(0.6, 0.6, 2.4),
	"spigot_mortar": Vector3(0.6, 0.6, 1.2),
	"rocket_artillery": Vector3(0.9, 0.7, 1.8),
	"hypervelocity_missile": Vector3(0.6, 0.5, 1.3),
	"sam_launcher": Vector3(0.7, 0.6, 1.4),
	"loitering_munition": Vector3(0.7, 0.6, 1.2),
	"anti_radiation_missile": Vector3(0.6, 0.6, 1.4),
	"bunker_buster": Vector3(0.7, 0.7, 1.5),
	"cruise_missile": Vector3(0.8, 0.7, 2.0),
	"aa_autocannon": Vector3(0.7, 0.6, 1.5),
	"sensor_beacon_launcher": Vector3(0.6, 0.5, 0.8),
	"resource_harvester": Vector3(1.5, 1.0, 1.5),
	"resource_bay": Vector3(1.4, 1.0, 1.8),
	"repair_array": Vector3(2.0, 2.0, 2.5),
	"drone_carrier": Vector3(2.0, 1.2, 3.0),
	"energy_barrier_projector": Vector3(1.0, 0.4, 1.0),
	"heavy_barrier_projector": Vector3(1.2, 0.9, 1.4),
	"bubble_shield_projector": Vector3(1.1, 0.6, 1.1),
	"fusion_generator": Vector3(0.56, 0.48, 0.72),
	"diesel_generator": Vector3(0.48, 0.36, 0.60),
	"thermo_generator": Vector3(0.36, 0.28, 0.40),
	"capacitor_bank": Vector3(0.32, 0.32, 0.40),
	"flywheel_storage": Vector3(0.48, 0.36, 0.48),
	"solid_state_battery": Vector3(0.44, 0.24, 0.56)
}

static func _repeat_along_axis(parent: Node3D, count: int, spacing: float, axis_vec: Vector3, builder_func: Callable):
	var start_pos = -axis_vec * ((count - 1) * spacing / 2.0)
	for i in range(count):
		var pos = start_pos + axis_vec * (i * spacing)
		builder_func.call(parent, pos, i)

static func _ring_of(parent: Node3D, count: int, radius: float, builder_func: Callable):
	for i in range(count):
		var angle = i * (TAU / max(1, count))
		var pos = Vector3(cos(angle) * radius, 0, sin(angle) * radius)
		builder_func.call(parent, pos, angle, i)

# Wrapper so the sponson blister is always built LAST, after the weapon's own
# geometry exists. It has to be: the housing is sized and positioned by
# MEASURING that geometry (_sponson_blister), so it can wrap the actual barrel
# at the actual barrel height instead of guessing from catalog numbers. An
# earlier version built it first and sat it at the module's base, which put a
# housing round the gun's feet rather than its barrel.
#
# A wrapper rather than a call at each exit point, because _build_visual_body()
# returns early on the monolithic-mesh path and would quietly grow more exits.
static func build_visual(type_id: String, parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary = {}):
	_build_visual_body(type_id, parent_node, base_size, base_color, tweaks)
	if parent_node.get_meta("sponson", false):
		_sponson_blister(parent_node, type_id)


# One self-contained module node, visual + stats payload, ready to parent.
#
# build_visual() POPULATES a node you already own; this CREATES one. Three call
# sites wanted the second thing and called a "build_module" that did not exist
# (lab_document.gd's hover preview, lab_toolbar.gd's armor autofill), which
# raised "Nonexistent function 'build_module' in base 'GDScript'" the moment you
# hovered a part in the Lab. drag_drop_manager.gd had privately reimplemented it
# as _build_module_ghost_node() and was the only path that worked.
#
# The "module_data" meta must be a ModuleData OBJECT, not the catalog
# Dictionary: design_stats.analyze() reads it with property access
# (`data.type_id`), which a Dictionary does not answer to. Anything that
# overwrites this meta with get_module_data()'s raw dict re-breaks stats for
# that module.
static func build_module(type_id: String) -> Node3D:
	var container := Node3D.new()
	var catalog_data: Dictionary = ModuleCatalog.get_module_data(type_id)
	var cat_size: Vector3 = catalog_data.get("size", Vector3.ONE)

	container.name = type_id
	build_visual(type_id, container, cat_size,
		catalog_data.get("color", Color.WHITE), {})

	# A part whose .glb is missing AND whose procedural fallback produced
	# nothing. A bare box reads as "no preview available" rather than
	# pretending to be the real silhouette.
	if container.get_child_count() == 0:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = cat_size
		mi.mesh = box
		container.add_child(mi)

	container.set_meta("type_id", type_id)
	container.set_meta("module_data", make_module_data(type_id))
	return container


# The catalog-Dictionary -> ModuleData translation, in one place. Every field is
# copied explicitly and defaulted, because ModuleData is a Resource with typed
# properties and a missing catalog key would otherwise assign null.
static func make_module_data(type_id: String) -> ModuleData:
	var catalog_data: Dictionary = ModuleCatalog.get_module_data(type_id)
	var mod_data := ModuleData.new()
	mod_data.type_id = type_id
	mod_data.category = catalog_data.get("category", "module")
	mod_data.module_name = catalog_data.get("name", "Unknown Module")
	mod_data.base_hp = catalog_data.get("base_hp", 100.0)
	mod_data.base_weight = catalog_data.get("base_weight", 50.0)
	mod_data.cost_metal = catalog_data.get("cost_metal", 10)
	mod_data.cost_crystal = catalog_data.get("cost_crystal", 0)
	mod_data.base_dps = catalog_data.get("base_dps", 0.0)
	mod_data.base_energy_capacity = catalog_data.get("energy_capacity", 0.0)
	mod_data.base_power_output = catalog_data.get("power_output", 0.0)
	mod_data.base_heal_rate = catalog_data.get("base_heal_rate", 0.0)
	mod_data.base_vision_bonus = catalog_data.get("vision_bonus", catalog_data.get("base_vision_bonus", 0.0))
	if catalog_data.has("default_tweaks"):
		mod_data.tweaks = catalog_data["default_tweaks"].duplicate()
	return mod_data

static func _build_visual_body(type_id: String, parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary = {}):
	# Clear any existing visual children. remove_child() BEFORE queue_free() -
	# queue_free() alone doesn't actually detach the node until end-of-frame,
	# so a caller that immediately calls build_visual() again on the same
	# parent (blueprint_manager.gd's reconstruct_vehicle() does exactly this:
	# build_visual() then rebuild_visual() back to back, same frame) would
	# have its freshly-created "RotorBlades"/"HoverRingMid"/"LegSwing" pivot
	# collide in name with the still-present old one and get silently
	# auto-renamed by add_child() - breaking every by-name animation lookup
	# for any vehicle reconstructed from a blueprint (Skirmish, Test Range,
	# defense buildings). remove_child() first frees the name immediately;
	# queue_free() still handles the actual node deletion safely.
	for child in parent_node.get_children():
		if child is StaticBody3D:
			continue
		parent_node.remove_child(child)
		child.queue_free()

	# Every mesh this module had is now gone, so the cached volume describes
	# geometry that no longer exists. This is the ONLY invalidation point that
	# matters: tweak drags, struct_scale resizes and sponson blister rebuilds
	# all reach the module through here.
	ModuleVolumeScript.invalidate(parent_node)

	# Try to load a monolithic authored mesh for this entire module first (modular sub-part assemblies bypass this)
	var monolithic_mesh = _part(type_id) if not MODULAR_ASSEMBLY_TYPES.has(type_id) else null
	if monolithic_mesh:
		var inst = _mesh_inst(monolithic_mesh, base_color)
		inst.rotation.y = deg_to_rad(90.0) # TripoSG native orientation offset
		# We scale the mesh uniformly so its largest dimension matches the largest dimension
		# defined in base_size. This prevents squishing/stretching while ensuring it fits the scale curve.
		var aabb = monolithic_mesh.get_aabb()
		var max_target = max(base_size.x, max(base_size.y, base_size.z))
		var max_authored = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		var fit_scale = max_target / max_authored if max_authored > 0.0 else 1.0
		inst.scale = Vector3(fit_scale, fit_scale, fit_scale) * _monolithic_tweak_scale(type_id, tweaks, inst.rotation)

		# Mounting-gap fix: the old `Vector3(0, base_size.y / 2.0, 0)` assumed
		# every authored mesh was perfectly centered on its own origin AND
		# that its natural (post-scale) height exactly matched the catalog's
		# target height - true for almost none of them (checked via a
		# headless AABB dump across several parts: most are already
		# bottom-anchored near their own local origin already, e.g.
		# sensor_suite's aabb.position.y is -0.025 against a 1.32-unit tall
		# mesh, not -0.66; a few are height-centered but their largest
		# dimension - the one fit_scale actually matches - is a different
		# axis). That mismatch left the mesh's REAL bottom floating above
		# the module's local origin (where _place_weapon() flush-mounts it
		# against the hull surface) by anywhere from a few cm up to over a
		# meter for sensor_suite's mast - "noticeable gaps beneath most
		# modules." Using the mesh's own actual AABB minimum Y (scaled by
		# the same fit_scale) instead puts its real bottom exactly on the
		# module's origin regardless of how the source mesh happens to be
		# centered.
		inst.position = Vector3(0, -aabb.position.y * fit_scale, 0)

		# Animation pivot. unit.gd and auto_weapon.gd animate moving
		# parts by looking up a child node BY NAME ("WingPivot", "RotorBlades",
		# "PropBlades") - names the procedural build creates. A monolithic
		# authored mesh has no such child, so those lookups came back null and
		# the motion silently stopped: ornithopter wings in particular never
		# flapped at all, since that arm isn't behind the
		# enable_animated_monolithic_parts flag the others sit behind.
		#
		# Wrap the mesh in a correctly-named pivot rather than bolting a second
		# procedural copy of the blades on top (what the flag does) - the
		# authored mesh already sculpts them, so a second copy would double the
		# geometry, which is exactly the caveat _attach_moving_parts() warns
		# about. A WRAPPER, not a rename: the animation writes whole rotations
		# onto the pivot (pivot.rotation.x = ...), which would otherwise
		# clobber the mesh's own orientation offset.
		var pivot_name = MONOLITHIC_ANIMATION_PIVOTS.get(type_id, "")
		if pivot_name != "":
			var pivot = Node3D.new()
			pivot.name = pivot_name
			pivot.add_child(inst)
			parent_node.add_child(pivot)
		else:
			parent_node.add_child(inst)
		# Feature-flagged (GlobalConfig.enable_animated_monolithic_parts,
		# default off): attach the same named moving-part pivots (barrels,
		# rotors) the procedural fallback below builds, so a detailed
		# monolithic body doesn't lose animation just because it replaced
		# the procedural base mesh. Off by default so this can be A/B tested
		# without changing today's shipped behavior.
		if GlobalConfigScript.enable_animated_monolithic_parts:
			_attach_moving_parts(type_id, parent_node, base_size, base_color, tweaks)
		return

	# Locomotion dispatch: handled BEFORE the weapon if/elif/else chain below,
	# not after it. Every locomotion type_id is in MODULAR_ASSEMBLY_TYPES (so
	# it skips the monolithic-mesh branch above), but none of them ever
	# matched any of the weapon-specific `if type_id == "..."` branches in
	# that chain either - so every locomotion instance fell through to the
	# chain's final `else: Fallback: Simple box mesh for armor and basic
	# parts`, which unconditionally added a plain uncolored BoxMesh sized to
	# the catalog's flat base_size (not scaled by any tweak) at the module's
	# mount point, BEFORE _build_wheels()/etc. below ever ran - a second,
	# unwanted, unchamfered box baked into every locomotion instance ("box
	# outboard of them and above, no chamfered edges" - visually indistinguishable
	# from a failed/fallback mount). The dispatch below also wasn't passing
	# `tweaks` through to most _build_X() calls, so wheel_size/blade_length/
	# etc. tweaks never reached the actual sub-part geometry at all. Returning
	# here after the real per-type build fixes both: no more stray fallback
	# box, and every per-instance tweak now actually reaches its _build_X().
	if LOCOMOTION_MODULAR_TYPES.has(type_id):
		match type_id:
			"wheels": _build_wheels(parent_node, base_size, base_color, tweaks)
			"tracked_treads": _build_tracked_treads(parent_node, base_size, base_color, tweaks)
			"heavy_quad_tracks": _build_heavy_quad_tracks(parent_node, base_size, base_color, tweaks)
			"helicopter_rotors": _build_helicopter_rotors(parent_node, base_size, base_color, tweaks)
			"hover_engine": _build_hover_engine(parent_node, base_size, base_color, tweaks)
			"legs": _build_legs(parent_node, base_size, base_color, tweaks)
			"ornithopter_wing": _build_ornithopter_wing(parent_node, base_size, base_color, tweaks)
			"buoyant_envelope": _build_buoyant_envelope(parent_node, base_size, base_color, tweaks)
			"screw_drive": _build_screw_drive(parent_node, base_size, base_color, tweaks)
			"half_track": _build_half_track(parent_node, base_size, base_color, tweaks)
			"rocker_bogie": _build_rocker_bogie(parent_node, base_size, base_color, tweaks)
			"air_cushion_skirt": _build_air_cushion_skirt(parent_node, base_size, base_color, tweaks)
			"anti_grav_plate": _build_anti_grav_plate(parent_node, base_size, base_color, tweaks)
			"plasma_thruster": _build_plasma_thruster(parent_node, base_size, base_color, tweaks)
		_apply_tweak_deformations(type_id, parent_node, tweaks, base_size)
		_assert_animated_pivots(type_id, parent_node)

		return

	if MODULAR_ASSEMBLY_TYPES.has(type_id) and MODULAR_AUTHORED_SIZES.has(type_id):
		var old_size: Vector3 = MODULAR_AUTHORED_SIZES[type_id]
		var max_old = max(old_size.x, max(old_size.y, old_size.z))
		var max_new = max(base_size.x, max(base_size.y, base_size.z))
		var visual_scale = max_new / max_old if max_old > 0.0 else 1.0
		
		if not is_equal_approx(visual_scale, 1.0):
			var wrapper = Node3D.new()
			wrapper.name = "ModularScaleWrapper"
			wrapper.scale = Vector3(visual_scale, visual_scale, visual_scale)
			parent_node.add_child(wrapper)
			parent_node = wrapper
			base_size = old_size


	if type_id == "basic_cannon":
		var b_count = int(tweaks.get("barrel_count", 1.0))
		b_count = clamp(b_count, 1, 4)
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)

		# 1. MOUNT / PINTLE (m3_pintle_mount.glb)
		var base_w_scale = (1.0 + (b_count - 1) * 0.35) * caliber
		var pintle_mesh = _part("m3_pintle_mount")
		if not pintle_mesh:
			pintle_mesh = _part("pintle_mount")
		var pintle: MeshInstance3D
		var pintle_h = base_size.y * 0.45 * caliber
		if pintle_mesh:
			pintle = _mesh_inst(pintle_mesh, base_color.darkened(0.3), Color(0, 0, 0, 0), 0.0, "accent")
			pintle.scale = Vector3(base_w_scale, caliber, caliber)
			pintle.position = Vector3(0, 0, 0)
		else:
			pintle = MeshInstance3D.new()
			var p_box = BoxMesh.new()
			p_box.size = Vector3(base_size.x * 1.2 * base_w_scale, pintle_h, base_size.x * 1.2 * caliber)
			pintle.mesh = p_box
			var p_mat = StandardMaterial3D.new()
			p_mat.albedo_color = base_color.darkened(0.3)
			pintle.material_override = p_mat
			pintle.position = Vector3(0, p_box.size.y / 2.0, 0)
		parent_node.add_child(pintle)

		# 2. ACTION / BREECH & BARREL (Per barrel count 1 to 4)
		var breech_mesh = _part("m3_action_breech")
		if not breech_mesh:
			breech_mesh = _part("howitzer_breech")
		var barrel_mesh = _part("m3_barrel")
		if not barrel_mesh:
			barrel_mesh = _part("barrel_standard")

		var x_spacing = 0.28 * caliber
		var start_x = -((b_count - 1) * x_spacing) / 2.0
		var trunnion_y = 0.26 * caliber

		for i in range(b_count):
			var cur_x = start_x + i * x_spacing

			# 2A. ACTION / BREECH
			var breech: MeshInstance3D
			if breech_mesh:
				breech = _mesh_inst(breech_mesh, Color(0.22, 0.24, 0.26))
				breech.scale = Vector3(caliber, caliber, caliber)
				breech.position = Vector3(cur_x, trunnion_y, 0.0)
			else:
				breech = MeshInstance3D.new()
				var b_box = BoxMesh.new()
				b_box.size = Vector3(0.22 * caliber, 0.26 * caliber, 0.38 * caliber)
				breech.mesh = b_box
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.22, 0.24, 0.26)
				breech.material_override = b_mat
				breech.position = Vector3(cur_x, trunnion_y, 0.0)
			parent_node.add_child(breech)

			# 2B. BARREL (Mounted at breech muzzle port, scaling with caliber and barrel_length)
			var barrel: MeshInstance3D
			if barrel_mesh:
				barrel = _mesh_inst(barrel_mesh, Color(0.18, 0.19, 0.21))
				barrel.scale = Vector3(caliber, caliber, length * caliber)
				barrel.position = Vector3(cur_x, trunnion_y, -0.05 * caliber)
			else:
				barrel = MeshInstance3D.new()
				var b_cyl = CylinderMesh.new()
				b_cyl.top_radius = 0.045 * caliber
				b_cyl.bottom_radius = 0.065 * caliber
				b_cyl.height = 1.25 * length
				barrel.mesh = b_cyl
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.18, 0.19, 0.21)
				barrel.material_override = b_mat
				barrel.position = Vector3(cur_x, trunnion_y, -(1.25 * length / 2.0) - 0.05 * caliber)
				barrel.rotation = Vector3(PI / 2, 0, 0)
			parent_node.add_child(barrel)

	elif type_id == "heavy_machine_gun":
		var multi_b = bool(tweaks.get("multi_barrel", false))
		var drum_scale = tweaks.get("drum_size", 1.0)
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)
		var b_count = 2 if multi_b else 1

		# 1. PINTLE MOUNT (hmg_pintle_mount.glb)
		var pintle_mesh = _part("hmg_pintle_mount")
		if not pintle_mesh:
			pintle_mesh = _part("pintle_mount")
		var pintle: MeshInstance3D
		var base_w_scale = (1.4 if multi_b else 1.0) * caliber
		if pintle_mesh:
			pintle = _mesh_inst(pintle_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			pintle.scale = Vector3(base_w_scale, caliber, caliber)
			pintle.position = Vector3(0, 0, 0)
		else:
			pintle = MeshInstance3D.new()
			var p_box = BoxMesh.new()
			p_box.size = Vector3(0.28 * base_w_scale, 0.22 * caliber, 0.28 * caliber)
			pintle.mesh = p_box
			var p_mat = StandardMaterial3D.new()
			p_mat.albedo_color = base_color.darkened(0.2)
			pintle.material_override = p_mat
			pintle.position = Vector3(0, 0.11 * caliber, 0)
		parent_node.add_child(pintle)

		# 2. RECEIVER(S) & BARREL(S)
		var rec_mesh = _part("hmg_receiver")
		var barrel_mesh = _part("hmg_barrel")
		var trunnion_y = 0.22 * caliber
		var x_spacing = 0.22 * caliber
		var start_x = -((b_count - 1) * x_spacing) / 2.0

		for i in range(b_count):
			var cur_x = start_x + i * x_spacing

			# 2A. RECEIVER
			var receiver: MeshInstance3D
			if rec_mesh:
				receiver = _mesh_inst(rec_mesh, Color(0.20, 0.22, 0.24))
				receiver.scale = Vector3(caliber, caliber, caliber)
				receiver.position = Vector3(cur_x, trunnion_y, 0.0)
			else:
				receiver = MeshInstance3D.new()
				var r_box = BoxMesh.new()
				r_box.size = Vector3(0.14 * caliber, 0.16 * caliber, 0.34 * caliber)
				receiver.mesh = r_box
				var r_mat = StandardMaterial3D.new()
				r_mat.albedo_color = Color(0.20, 0.22, 0.24)
				receiver.material_override = r_mat
				receiver.position = Vector3(cur_x, trunnion_y, -0.06 * caliber)
			parent_node.add_child(receiver)

			# 2B. BARREL (Mounted at front of receiver socket, scaling with caliber and barrel_length)
			var barrel: MeshInstance3D
			if barrel_mesh:
				barrel = _mesh_inst(barrel_mesh, Color(0.15, 0.16, 0.18))
				barrel.scale = Vector3(caliber, caliber, length * caliber)
				barrel.position = Vector3(cur_x, trunnion_y, 0.0)
			else:
				barrel = MeshInstance3D.new()
				var b_cyl = CylinderMesh.new()
				b_cyl.top_radius = 0.03 * caliber
				b_cyl.bottom_radius = 0.04 * caliber
				b_cyl.height = 0.85 * length
				barrel.mesh = b_cyl
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.15, 0.16, 0.18)
				barrel.material_override = b_mat
				barrel.position = Vector3(cur_x, trunnion_y, -0.425 * length)
				barrel.rotation = Vector3(PI / 2, 0, 0)
			parent_node.add_child(barrel)

		# 3. SIDE AMMO DRUM (hmg_ammo_drum.glb) - Deformed by drum_size slider!
		var drum_mesh = _part("hmg_ammo_drum")
		if not drum_mesh:
			drum_mesh = _part("ammo_drum")
		var drum: MeshInstance3D
		var drum_x = start_x - 0.07 * caliber
		var total_drum_s = drum_scale * caliber
		if drum_mesh:
			drum = _mesh_inst(drum_mesh, Color(0.25, 0.28, 0.25))
			drum.scale = Vector3(total_drum_s, total_drum_s, total_drum_s)
			drum.position = Vector3(drum_x, trunnion_y, -0.06 * caliber)
		else:
			drum = MeshInstance3D.new()
			var drum_cyl = CylinderMesh.new()
			drum_cyl.top_radius = 0.13 * total_drum_s
			drum_cyl.bottom_radius = 0.13 * total_drum_s
			drum_cyl.height = 0.14 * total_drum_s
			drum.mesh = drum_cyl
			var d_mat = StandardMaterial3D.new()
			d_mat.albedo_color = Color(0.25, 0.28, 0.25)
			drum.material_override = d_mat
			drum.position = Vector3(drum_x - 0.10 * caliber, trunnion_y, -0.06 * caliber)
			drum.rotation = Vector3(0, 0, PI / 2)
		parent_node.add_child(drum)

	elif type_id == "rotary_cannon":
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)
		var b_count = int(tweaks.get("barrel_count", 6.0))
		b_count = clamp(b_count, 3, 9)
		var motor_s = tweaks.get("motor_size", 1.0)

		# 1. PINTLE MOUNT (rotary_pintle_mount.glb)
		var pintle_mesh = _part("rotary_pintle_mount")
		if not pintle_mesh:
			pintle_mesh = _part("pintle_mount")
		var pintle: MeshInstance3D
		if pintle_mesh:
			pintle = _mesh_inst(pintle_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			pintle.scale = Vector3(caliber, caliber, caliber)
			pintle.position = Vector3(0, 0, 0)
		else:
			pintle = MeshInstance3D.new()
			var p_box = BoxMesh.new()
			p_box.size = Vector3(0.36 * caliber, 0.24 * caliber, 0.36 * caliber)
			pintle.mesh = p_box
			var p_mat = StandardMaterial3D.new()
			p_mat.albedo_color = base_color.darkened(0.2)
			pintle.material_override = p_mat
			pintle.position = Vector3(0, 0.12 * caliber, 0)
		parent_node.add_child(pintle)

		# 2. ROTOR HOUSING & DRIVE MOTOR (rotary_housing.glb)
		var trunnion_y = 0.24 * caliber
		var housing_mesh = _part("rotary_housing")
		if not housing_mesh:
			housing_mesh = _part("rotary_jacket")
		var housing: MeshInstance3D
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.22, 0.24, 0.26))
			housing.scale = Vector3(caliber, caliber, motor_s * caliber)
			housing.position = Vector3(0, trunnion_y, 0)
		else:
			housing = MeshInstance3D.new()
			var h_cyl = CylinderMesh.new()
			h_cyl.top_radius = 0.20 * caliber
			h_cyl.bottom_radius = 0.20 * caliber
			h_cyl.height = 0.35 * motor_s * caliber
			housing.mesh = h_cyl
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.22, 0.24, 0.26)
			housing.material_override = h_mat
			housing.position = Vector3(0, trunnion_y, 0)
			housing.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(housing)

		# 3. SPINNING BARREL CLUSTER (under "BarrelCluster" pivot for spin animation)
		_attach_rotary_barrels(parent_node, base_size, tweaks)

	elif type_id == "gauss_railgun":
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)

		# 1. HEAVY CASEMATE HULL MOUNT (railgun_casemate_mount.glb) - Non-traversing hull citadel
		var mount_mesh = _part("railgun_casemate_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(caliber, caliber, caliber)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.58 * caliber, 0.26 * caliber, 0.68 * caliber)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.13 * caliber, 0)
		parent_node.add_child(mount)

		# 2. CAPACITOR / BREECH HOUSING (railgun_capacitor_housing.glb)
		var trunnion_y = 0.24 * caliber
		var cap_mesh = _part("railgun_capacitor_housing")
		var capacitor: MeshInstance3D
		if cap_mesh:
			capacitor = _mesh_inst(cap_mesh, Color(0.18, 0.20, 0.22))
			capacitor.scale = Vector3(caliber, caliber, caliber)
			capacitor.position = Vector3(0, trunnion_y, 0.0)
		else:
			capacitor = MeshInstance3D.new()
			var c_box = BoxMesh.new()
			c_box.size = Vector3(0.28 * caliber, 0.22 * caliber, 0.42 * caliber)
			capacitor.mesh = c_box
			var c_mat = StandardMaterial3D.new()
			c_mat.albedo_color = Color(0.18, 0.20, 0.22)
			capacitor.material_override = c_mat
			capacitor.position = Vector3(0, trunnion_y, -0.12 * caliber)
		parent_node.add_child(capacitor)

		# 3. ACCELERATOR RAILS (railgun_rails.glb) - Deformed ONLY by barrel_length and caliber!
		var rail_mesh = _part("railgun_rails")
		var rails: MeshInstance3D
		if rail_mesh:
			rails = _mesh_inst(rail_mesh, Color(0.15, 0.16, 0.18), Color.BLUE_VIOLET, 1.2)
			rails.scale = Vector3(caliber, caliber, length * caliber)
			rails.position = Vector3(0, trunnion_y, 0.0)
		else:
			rails = MeshInstance3D.new()
			var r_box = BoxMesh.new()
			r_box.size = Vector3(0.16 * caliber, 0.20 * caliber, 1.40 * length)
			rails.mesh = r_box
			var r_mat = StandardMaterial3D.new()
			r_mat.albedo_color = Color(0.15, 0.16, 0.18)
			r_mat.emission_enabled = true
			r_mat.emission = Color.BLUE_VIOLET
			r_mat.emission_energy_multiplier = 1.2
			rails.material_override = r_mat
			rails.position = Vector3(0, trunnion_y, -(1.40 * length / 2.0))
		parent_node.add_child(rails)

	elif type_id == "artillery":
		var b_count = int(tweaks.get("barrel_count", 1.0))
		b_count = clamp(b_count, 1, 2)
		var caliber = tweaks.get("caliber", 1.0) * 2.0  # Doubled visual size per user request
		var length = tweaks.get("barrel_length", 1.0)

		# 1. HEAVY CASEMATE HULL MOUNT (artillery_casemate_mount.glb)
		var base_w_scale = (1.0 + (b_count - 1) * 0.45) * caliber
		var mount_mesh = _part("artillery_casemate_mount")
		if not mount_mesh:
			mount_mesh = _part("railgun_casemate_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(base_w_scale, caliber, caliber)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.64 * base_w_scale, 0.28 * caliber, 0.72 * caliber)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.14 * caliber, 0)
		parent_node.add_child(mount)

		# 2. BREECH & BARREL (1 or 2 heavy artillery barrels side-by-side)
		var breech_mesh = _part("artillery_breech")
		var barrel_mesh = _part("artillery_barrel")
		var trunnion_y = 0.26 * caliber
		var x_spacing = 0.36 * caliber
		var start_x = -((b_count - 1) * x_spacing) / 2.0

		for i in range(b_count):
			var cur_x = start_x + i * x_spacing

			# ELEVATION PIVOT. artillery_barrel.glb / artillery_breech.glb are now
			# authored along -Z at zero elevation (see build_artillery.py's
			# ELEV_ANGLE); the gun's 35-degree elevation is applied here instead.
			#
			# This is what makes the barrel_length tweak work: the barrel's own
			# local -Z is the tube axis, so scaling its Z lengthens the tube. When
			# the elevation was baked into the mesh, the long axis was a tilted
			# Y/Z diagonal and scaling Z sheared the gun sideways.
			var elev_pivot = Node3D.new()
			elev_pivot.name = "ElevationPivot" if i == 0 else "ElevationPivot%d" % i
			elev_pivot.position = Vector3(cur_x, trunnion_y, 0.0)
			elev_pivot.rotation = Vector3(deg_to_rad(ARTILLERY_ELEVATION_DEG), 0, 0)
			parent_node.add_child(elev_pivot)

			# 2A. BREECH BLOCK
			var breech: MeshInstance3D
			if breech_mesh:
				breech = _mesh_inst(breech_mesh, Color(0.20, 0.22, 0.24))
				breech.scale = Vector3(caliber, caliber, caliber)
				elev_pivot.add_child(breech)
			else:
				breech = MeshInstance3D.new()
				var b_box = BoxMesh.new()
				b_box.size = Vector3(0.30 * caliber, 0.28 * caliber, 0.45 * caliber)
				breech.mesh = b_box
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.20, 0.22, 0.24)
				breech.material_override = b_mat
				breech.position = Vector3(0, 0, -0.12 * caliber)
				elev_pivot.add_child(breech)

			# 2B. BARREL. Authored along -Z, so scaling Z lengthens the tube.
			var barrel: MeshInstance3D
			if barrel_mesh:
				barrel = _mesh_inst(barrel_mesh, Color(0.16, 0.17, 0.19))
				barrel.scale = Vector3(caliber, caliber, length * caliber)
			else:
				barrel = MeshInstance3D.new()
				var b_cyl = CylinderMesh.new()
				b_cyl.top_radius = 0.05 * caliber
				b_cyl.bottom_radius = 0.08 * caliber
				b_cyl.height = 1.35 * length
				barrel.mesh = b_cyl
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.16, 0.17, 0.19)
				barrel.material_override = b_mat
				barrel.position = Vector3(0, 0, -(1.35 * length / 2.0))
				barrel.rotation = Vector3(PI / 2, 0, 0)
			elev_pivot.add_child(barrel)

	elif type_id == "mortar_array":
		var t_count = int(tweaks.get("tube_count", 2.0))
		t_count = clamp(t_count, 1, 4)
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)

		# 1. SWIVEL TURNTABLE MOUNT PLATE (mortar_swivel_mount.glb)
		var base_w_scale = (1.0 + (t_count - 1) * 0.18) * caliber
		var mount_mesh = _part("mortar_swivel_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(base_w_scale, caliber, base_w_scale)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_cyl = CylinderMesh.new()
			m_cyl.top_radius = 0.32 * base_w_scale
			m_cyl.bottom_radius = 0.34 * base_w_scale
			m_cyl.height = 0.12 * caliber
			mount.mesh = m_cyl
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.25)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.06 * caliber, 0)
		parent_node.add_child(mount)

		# 2. CLUSTERED MORTAR TUBES WITH RECOIL COLLARS (mortar_tube_single.glb)
		var tube_mesh = _part("mortar_tube_single")
		var trunnion_y = 0.16 * caliber
		var r_off = 0.18 * caliber

		var tube_offsets = [Vector3(0, 0, 0)]
		if t_count == 2:
			tube_offsets = [Vector3(-r_off, 0, 0), Vector3(r_off, 0, 0)]
		elif t_count == 3:
			tube_offsets = [
				Vector3(0, 0, -r_off * 0.9),
				Vector3(-r_off * 0.866, 0, r_off * 0.5),
				Vector3(r_off * 0.866, 0, r_off * 0.5)
			]
		elif t_count >= 4:
			tube_offsets = [
				Vector3(-r_off * 0.85, 0, -r_off * 0.85),
				Vector3(r_off * 0.85, 0, -r_off * 0.85),
				Vector3(-r_off * 0.85, 0, r_off * 0.85),
				Vector3(r_off * 0.85, 0, r_off * 0.85)
			]

		for offset in tube_offsets:
			# ELEVATION PIVOT, same reasoning as artillery: mortar_tube_single.glb
			# is now authored along -Z at zero elevation (build_mortar.py's
			# ELEV_60_DEG), and the 60-degree firing elevation is a pivot rotation.
			# Scaling the tube's Z therefore lengthens the tube along its own axis
			# instead of shearing it, which is what barrel_length needs.
			var m_pivot = Node3D.new()
			m_pivot.name = "TubePivot"
			m_pivot.position = Vector3(offset.x, trunnion_y, offset.z)
			m_pivot.rotation = Vector3(deg_to_rad(MORTAR_ELEVATION_DEG), 0, 0)
			parent_node.add_child(m_pivot)

			var tube: MeshInstance3D
			if tube_mesh:
				tube = _mesh_inst(tube_mesh, Color(0.22, 0.25, 0.20))
				tube.scale = Vector3(caliber, caliber, length * caliber)
			else:
				tube = MeshInstance3D.new()
				var t_cyl = CylinderMesh.new()
				t_cyl.top_radius = 0.075 * caliber
				t_cyl.bottom_radius = 0.09 * caliber
				t_cyl.height = 1.10 * length
				tube.mesh = t_cyl
				var t_mat = StandardMaterial3D.new()
				t_mat.albedo_color = Color(0.22, 0.25, 0.20)
				tube.material_override = t_mat
				# Procedural fallback: CylinderMesh runs along Y, so a quarter turn
				# puts it along the pivot's -Z like the authored tube.
				tube.position = Vector3(0, 0, -(1.10 * length * 0.5))
				tube.rotation = Vector3(PI / 2, 0, 0)
			m_pivot.add_child(tube)


	elif type_id == "missile_pod":
		# missile_pod is in MODULAR_ASSEMBLY_TYPES, so build_visual() never tries
		# the monolithic _part(type_id) path for it - it comes straight here. There
		# was no branch, so it fell through to the generic box fallback at the end
		# of this function and the swarm pod rendered as a plain orange box, while
		# its three authored meshes (missile_pod_pintle_mount, missile_pod_housing,
		# missile_pod_missile) sat unused in assets/models/parts.
		var warhead = tweaks.get("warhead_size", 1.0)
		var motor = tweaks.get("motor_length", 1.0)
		var grid = int(clamp(tweaks.get("grid_size", 4.0), 2.0, 6.0))

		# 1. PINTLE MOUNT
		var pod_mount_mesh = _part("missile_pod_pintle_mount")
		if not pod_mount_mesh:
			pod_mount_mesh = _part("pintle_mount")
		var pod_mount: MeshInstance3D
		if pod_mount_mesh:
			pod_mount = _mesh_inst(pod_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
			pod_mount.scale = Vector3(warhead, warhead, warhead)
		else:
			pod_mount = MeshInstance3D.new()
			var pm_box = BoxMesh.new()
			pm_box.size = Vector3(base_size.x * 0.45, base_size.y * 0.25, base_size.z * 0.45)
			pod_mount.mesh = pm_box
			var pm_mat = StandardMaterial3D.new()
			pm_mat.albedo_color = base_color.darkened(0.25)
			pod_mount.material_override = pm_mat
			pod_mount.position = Vector3(0, pm_box.size.y * 0.5, 0)
		parent_node.add_child(pod_mount)

		# 2. LAUNCHER HOUSING - the boxy multi-tube pod body.
		# The housing GLB was reshaped so the trunnion brackets sit at Z=0
		# (the mount trunnion height) and the main shell sits on top of the
		# brackets. Park pod_body_y at the trunnion so the brackets meet
		# the mount's trunnion pins and the shell clears the yoke arms.
		var pod_body_y: float = 0.24 * warhead
		var housing_mesh = _part("missile_pod_housing")
		var pod_housing: MeshInstance3D
		if housing_mesh:
			pod_housing = _mesh_inst(housing_mesh, base_color)
			pod_housing.scale = Vector3(warhead, warhead, motor * warhead)
			pod_housing.position = Vector3(0, pod_body_y, 0)
		else:
			pod_housing = MeshInstance3D.new()
			var ph_box = BoxMesh.new()
			ph_box.size = Vector3(base_size.x * 0.9 * warhead,
				base_size.y * 0.6 * warhead, base_size.z * 0.8 * motor)
			pod_housing.mesh = ph_box
			var ph_mat = StandardMaterial3D.new()
			ph_mat.albedo_color = base_color
			pod_housing.material_override = ph_mat
			pod_housing.position = Vector3(0, pod_body_y, 0)
		parent_node.add_child(pod_housing)

		# 3. ROCKET GRID - grid x rows of tube muzzles across the pod's front
		# face plate. The plate is 0.48x0.38 in the housing GLB (X by Y) and
		# sits at the shell's vertical centre; constrain the grid to fit
		# inside it, leaving one missile-radius of margin on every edge so
		# adjacent cells touch but never overlap. Centring on the plate
		# (not on the trunnion) keeps the warheads visually emerging from
		# the face instead of from the deck.
		var rocket_mesh = _part("missile_pod_missile")
		var rows: int = maxi(int(round(float(grid) * 0.66)), 2)
		var face_plate_w: float = 0.48 * 0.92 * warhead
		var face_plate_h: float = 0.38 * 0.90 * warhead
		var rocket_r: float = 0.066 * warhead
		var cell_w: float = (face_plate_w - 2.0 * rocket_r) / float(maxi(grid - 1, 1))
		var cell_h: float = (face_plate_h - 2.0 * rocket_r) / float(maxi(rows - 1, 1))
		var grid_center_y: float = pod_body_y + 0.19 * warhead
		var grid_z: float = -0.42 * motor * warhead
		for gx in range(grid):
			for gy in range(rows):
				var rx: float = (float(gx) - float(grid - 1) * 0.5) * cell_w
				var ry: float = grid_center_y + (float(gy) - float(rows - 1) * 0.5) * cell_h
				var rocket: MeshInstance3D
				if rocket_mesh:
					rocket = _mesh_inst(rocket_mesh, Color(0.75, 0.72, 0.66))
					rocket.scale = Vector3(warhead, warhead, motor * warhead)
				else:
					rocket = MeshInstance3D.new()
					var r_cyl = CylinderMesh.new()
					r_cyl.top_radius = cell_w * 0.3
					r_cyl.bottom_radius = cell_w * 0.3
					r_cyl.height = cell_w * 0.5
					rocket.mesh = r_cyl
					rocket.rotation = Vector3(PI / 2.0, 0, 0)
					var r_mat = StandardMaterial3D.new()
					r_mat.albedo_color = Color(0.75, 0.72, 0.66)
					rocket.material_override = r_mat
				rocket.position = Vector3(rx, ry, grid_z)
				parent_node.add_child(rocket)

	elif type_id == "guided_missile":
		var b_count = int(tweaks.get("barrel_count", 1.0))
		b_count = clamp(b_count, 1, 4)
		var seeker = tweaks.get("seeker_size", 1.0)
		var engine = tweaks.get("barrel_length", 1.0)

		# 1. PINTLE MOUNT & GUIDANCE OPTIC SIGHT (tow_pintle_mount.glb)
		var base_w_scale = (1.0 + (b_count - 1) * 0.35) * seeker
		var mount_mesh = _part("tow_pintle_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(base_w_scale, seeker, seeker)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.34 * base_w_scale, 0.22 * seeker, 0.34 * seeker)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.11 * seeker, 0)
		parent_node.add_child(mount)

		# 2. FIBERGLASS LAUNCH CANISTER TUBES & TOW MISSILES (1 to 4 tubes side-by-side)
		var tube_mesh = _part("tow_launch_tube")
		var missile_mesh = _part("tow_missile_warhead")
		var trunnion_y = 0.24 * seeker
		var x_spacing = 0.28 * seeker
		var start_x = -((b_count - 1) * x_spacing) / 2.0

		for i in range(b_count):
			var cur_x = start_x + i * x_spacing

			# 2A. LAUNCH TUBE CANISTER
			var tube: MeshInstance3D
			if tube_mesh:
				tube = _mesh_inst(tube_mesh, Color(0.24, 0.26, 0.22))
				tube.scale = Vector3(seeker, seeker, engine * seeker)
				tube.position = Vector3(cur_x, trunnion_y, 0.0)
			else:
				tube = MeshInstance3D.new()
				var t_box = BoxMesh.new()
				t_box.size = Vector3(0.20 * seeker, 0.20 * seeker, 1.20 * engine)
				tube.mesh = t_box
				var t_mat = StandardMaterial3D.new()
				t_mat.albedo_color = Color(0.24, 0.26, 0.22)
				tube.material_override = t_mat
				tube.position = Vector3(cur_x, trunnion_y, -(1.20 * engine / 2.0))
			parent_node.add_child(tube)

			# 2B. TOW MISSILE WARHEAD PROBE (Protruding out front of tube opening)
			var missile: MeshInstance3D
			if missile_mesh:
				missile = _mesh_inst(missile_mesh, Color(0.85, 0.85, 0.85))
				missile.scale = Vector3(seeker, seeker, seeker)
				missile.position = Vector3(cur_x, trunnion_y, -0.60 * engine * seeker)
			else:
				missile = MeshInstance3D.new()
				var m_cyl = CylinderMesh.new()
				m_cyl.top_radius = 0.01
				m_cyl.bottom_radius = 0.075 * seeker
				m_cyl.height = 0.30
				missile.mesh = m_cyl
				var m_mat = StandardMaterial3D.new()
				m_mat.albedo_color = Color.WHITE
				missile.material_override = m_mat
				missile.position = Vector3(cur_x, trunnion_y, -(1.20 * engine + 0.15))
				missile.rotation = Vector3(PI / 2, 0, 0)
			parent_node.add_child(missile)


	elif type_id == "drone_carrier":
		var hangar_size = int(tweaks.get("hangar_size", 2.0))
		hangar_size = clamp(hangar_size, 1, 5)
		var launch_catapult = tweaks.get("launch_catapult", 1.0)

		# 1. CATAPULT LAUNCH DECK MOUNT (drone_carrier_mount.glb)
		var mount_mesh = _part("drone_carrier_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		var mount_w = 0.8 + (hangar_size - 1) * 0.15
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(mount_w, 1.0, launch_catapult)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.50 * mount_w, 0.06, 0.80 * launch_catapult)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.03, 0)
		parent_node.add_child(mount)

		# 2. HANGAR BAY ENCLOSURE (drone_carrier_housing.glb)
		var housing_mesh = _part("drone_carrier_housing")
		var housing: MeshInstance3D
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.28, 0.30, 0.34))
			housing.scale = Vector3(mount_w, 1.0, 1.0)
			housing.position = Vector3(0, 0, 0)
		else:
			housing = MeshInstance3D.new()
			var h_box = BoxMesh.new()
			h_box.size = Vector3(0.46 * mount_w, 0.44, 0.22)
			housing.mesh = h_box
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.28, 0.30, 0.34)
			housing.material_override = h_mat
			housing.position = Vector3(0, 0.22, 0.15)
		parent_node.add_child(housing)

		# 3. SCOUT DRONES (drone_carrier_drone.glb) mounted on catapult launch rails
		var drone_mesh = _part("drone_carrier_drone")
		var front_z_start = -0.35 * launch_catapult
		for i in range(hangar_size):
			var drone: MeshInstance3D
			var dz = front_z_start + i * (0.15 * launch_catapult)
			if drone_mesh:
				drone = _mesh_inst(drone_mesh, Color(0.85, 0.85, 0.88))
				drone.scale = Vector3(1.0, 1.0, 1.0)
				drone.position = Vector3(0, 0.08, dz)
			else:
				drone = MeshInstance3D.new()
				var d_box = BoxMesh.new()
				d_box.size = Vector3(0.18, 0.04, 0.12)
				drone.mesh = d_box
				var d_mat = StandardMaterial3D.new()
				d_mat.albedo_color = Color(0.85, 0.85, 0.88)
				drone.material_override = d_mat
				drone.position = Vector3(0, 0.08, dz)
			parent_node.add_child(drone)

	elif type_id in ["cluster_dispenser", "cluster_launcher"]:
		var dispersion = tweaks.get("dispersion", 1.0)
		var payload_size = tweaks.get("payload_size", 1.0)
		var barrel_len = tweaks.get("barrel_length", 1.0)
		var tube_count = int(tweaks.get("tube_count", 2.0))
		tube_count = clamp(tube_count, 1, 4)

		# 1. MOUNT (cluster_dispenser_mount.glb)
		var mount_mesh = _part("cluster_dispenser_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		var base_w_scale = (0.85 + (tube_count - 1) * 0.15) * dispersion
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(base_w_scale, payload_size, base_w_scale)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.42 * base_w_scale, 0.16 * payload_size, 0.42 * base_w_scale)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08 * payload_size, 0)
		parent_node.add_child(mount)

		# 2. CONTAINER HOUSING (cluster_dispenser_housing.glb)
		var trunnion_y = 0.22 * payload_size
		var housing_mesh = _part("cluster_dispenser_housing")
		var housing: MeshInstance3D
		var house_w = (0.85 + (tube_count - 1) * 0.15) * dispersion
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.28, 0.22, 0.18))
			housing.scale = Vector3(house_w, payload_size, dispersion * barrel_len)
			housing.position = Vector3(0, trunnion_y, 0)
		else:
			housing = MeshInstance3D.new()
			var h_box = BoxMesh.new()
			h_box.size = Vector3(0.42 * house_w, 0.32 * payload_size, 0.70 * dispersion * barrel_len)
			housing.mesh = h_box
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.28, 0.22, 0.18)
			housing.material_override = h_mat
			housing.position = Vector3(0, trunnion_y, 0)
		parent_node.add_child(housing)

		# 3. SUBMUNITION CANISTERS / DEPTH CHARGES (cluster_dispenser_canister.glb)
		var canister_mesh = _part("cluster_dispenser_canister")
		var offsets: Array[Vector2] = []
		if tube_count == 1:
			offsets = [Vector2(0, 0)]
		elif tube_count == 2:
			offsets = [Vector2(-0.10 * dispersion, 0), Vector2(0.10 * dispersion, 0)]
		elif tube_count == 3:
			offsets = [Vector2(0, -0.12 * dispersion), Vector2(-0.11 * dispersion, 0.08 * dispersion), Vector2(0.11 * dispersion, 0.08 * dispersion)]
		else:
			offsets = [Vector2(-0.11 * dispersion, -0.11 * dispersion), Vector2(0.11 * dispersion, -0.11 * dispersion), Vector2(-0.11 * dispersion, 0.11 * dispersion), Vector2(0.11 * dispersion, 0.11 * dispersion)]

		for off in offsets:
			var can: MeshInstance3D
			var can_scale = payload_size
			if canister_mesh:
				can = _mesh_inst(canister_mesh, Color(0.70, 0.40, 0.20))
				can.scale = Vector3(can_scale, can_scale, can_scale)
				can.position = Vector3(off.x, trunnion_y, off.y)
			else:
				can = MeshInstance3D.new()
				var c_cyl = CylinderMesh.new()
				c_cyl.top_radius = 0.05 * can_scale
				c_cyl.bottom_radius = 0.05 * can_scale
				c_cyl.height = 0.18 * payload_size
				can.mesh = c_cyl
				var c_mat = StandardMaterial3D.new()
				c_mat.albedo_color = Color(0.70, 0.40, 0.20)
				can.material_override = c_mat
				can.position = Vector3(off.x, trunnion_y, off.y)
				can.rotation = Vector3(PI / 2, 0, 0)
			parent_node.add_child(can)

	elif type_id == "flamethrower":
		var nozzle_width = tweaks.get("nozzle_width", 1.0)
		var pressure_valve = tweaks.get("pressure_valve", 1.0)
		var nozzle_len = tweaks.get("barrel_length", 1.0)

		# 1. MOUNT (flamethrower_mount.glb)
		var mount_mesh = _part("flamethrower_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(1.0, 1.0, 1.0)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.32, 0.16, 0.32)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		# 2. BODY & DUAL FUEL TANKS (flamethrower_body.glb) - pressure_valve deforms body only
		var trunnion_y = 0.20
		var body_mesh = _part("flamethrower_body")
		var body: MeshInstance3D
		if body_mesh:
			body = _mesh_inst(body_mesh, Color(0.35, 0.20, 0.12))
			body.scale = Vector3(pressure_valve, 1.0, pressure_valve)
			body.position = Vector3(0, trunnion_y, 0)
		else:
			body = MeshInstance3D.new()
			var b_box = BoxMesh.new()
			b_box.size = Vector3(0.22 * pressure_valve, 0.22, 0.45 * pressure_valve)
			body.mesh = b_box
			var b_mat = StandardMaterial3D.new()
			b_mat.albedo_color = Color(0.35, 0.20, 0.12)
			body.material_override = b_mat
			body.position = Vector3(0, trunnion_y, 0)
		parent_node.add_child(body)

		# 3. NOZZLE & IGNITER TIP (flamethrower_nozzle.glb) - nozzle_width deforms nozzle only
		var nozzle_mesh = _part("flamethrower_nozzle")
		var nozzle: MeshInstance3D
		var nozzle_z = 0.0
		if nozzle_mesh:
			nozzle = _mesh_inst(nozzle_mesh, Color(0.15, 0.15, 0.15))
			nozzle.scale = Vector3(nozzle_width, nozzle_width, nozzle_len)
			nozzle.position = Vector3(0, trunnion_y, nozzle_z - 0.05 * (nozzle_len - 1.0))
		else:
			nozzle = MeshInstance3D.new()
			var n_cyl = CylinderMesh.new()
			n_cyl.top_radius = 0.08 * nozzle_width
			n_cyl.bottom_radius = 0.05 * nozzle_width
			n_cyl.height = 0.35 * nozzle_len
			nozzle.mesh = n_cyl
			var n_mat = StandardMaterial3D.new()
			n_mat.albedo_color = Color(0.15, 0.15, 0.15)
			nozzle.material_override = n_mat
			nozzle.position = Vector3(0, trunnion_y, -0.37 - 0.175 * (nozzle_len - 1.0))
			nozzle.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(nozzle)

	elif type_id == "ion_cannon":
		var lens_aperture = tweaks.get("lens_aperture", 1.0)
		var barrel_length = tweaks.get("barrel_length", 1.0)

		# 1. MOUNT (ion_cannon_mount.glb)
		var mount_mesh = _part("ion_cannon_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(lens_aperture, 1.0, lens_aperture)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.50 * lens_aperture, 0.16, 0.50 * lens_aperture)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		# 2. ACCELERATOR HOUSING (ion_cannon_housing.glb)
		var trunnion_y = 0.26
		var housing_mesh = _part("ion_cannon_housing")
		var housing: MeshInstance3D
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.20, 0.24, 0.30))
			housing.scale = Vector3(lens_aperture, lens_aperture, barrel_length)
			housing.position = Vector3(0, trunnion_y, 0)
		else:
			housing = MeshInstance3D.new()
			var h_cyl = CylinderMesh.new()
			h_cyl.top_radius = 0.14 * lens_aperture
			h_cyl.bottom_radius = 0.14 * lens_aperture
			h_cyl.height = 1.20 * barrel_length
			housing.mesh = h_cyl
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.20, 0.24, 0.30)
			housing.material_override = h_mat
			housing.position = Vector3(0, trunnion_y, -0.60 * barrel_length)
			housing.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(housing)

		# 3. FOCUSING LENS (ion_cannon_lens.glb)
		var lens_mesh = _part("ion_cannon_lens")
		var lens: MeshInstance3D
		var lens_z = -0.60 * barrel_length
		if lens_mesh:
			lens = _mesh_inst(lens_mesh, Color(0.25, 0.60, 0.85))
			lens.scale = Vector3(lens_aperture, lens_aperture, lens_aperture)
			lens.position = Vector3(0, trunnion_y, lens_z)
		else:
			lens = MeshInstance3D.new()
			var l_cyl = CylinderMesh.new()
			l_cyl.top_radius = 0.08 * lens_aperture
			l_cyl.bottom_radius = 0.14 * lens_aperture
			l_cyl.height = 0.20
			lens.mesh = l_cyl
			var l_mat = StandardMaterial3D.new()
			l_mat.albedo_color = Color.CYAN
			lens.material_override = l_mat
			lens.position = Vector3(0, trunnion_y, lens_z - 0.10)
			lens.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(lens)

	elif type_id in ["heavy_laser", "laser_cannon"]:
		var lens_aperture = tweaks.get("lens_aperture", 1.0)
		var barrel_len = tweaks.get("barrel_length", tweaks.get("focal_length", 1.0))

		# 1. MOUNT (heavy_laser_mount.glb)
		var mount_mesh = _part("heavy_laser_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(1.0, 1.0, 1.0)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.44, 0.16, 0.44)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		# 2. OPTICAL CAVITY BARREL HOUSING (heavy_laser_housing.glb)
		var trunnion_y = 0.25
		var housing_mesh = _part("heavy_laser_housing")
		var housing: MeshInstance3D
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.24, 0.28, 0.32))
			housing.scale = Vector3(lens_aperture, lens_aperture, 1.0)
			housing.position = Vector3(0, trunnion_y, 0)
		else:
			housing = MeshInstance3D.new()
			var h_cyl = CylinderMesh.new()
			h_cyl.top_radius = 0.12 * lens_aperture
			h_cyl.bottom_radius = 0.12 * lens_aperture
			h_cyl.height = 0.50
			housing.mesh = h_cyl
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.24, 0.28, 0.32)
			housing.material_override = h_mat
			housing.position = Vector3(0, trunnion_y, -0.25)
			housing.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(housing)

		# 3. LENS TELESCOPE BARREL (heavy_laser_lens.glb)
		var lens_mesh = _part("heavy_laser_lens")
		var lens: MeshInstance3D
		var lens_z = 0.0
		if lens_mesh:
			lens = _mesh_inst(lens_mesh, Color(0.15, 0.18, 0.22))
			lens.scale = Vector3(lens_aperture, lens_aperture, barrel_len)
			lens.position = Vector3(0, trunnion_y, lens_z)
		else:
			lens = MeshInstance3D.new()
			var l_cyl = CylinderMesh.new()
			l_cyl.top_radius = 0.14 * lens_aperture
			l_cyl.bottom_radius = 0.12 * lens_aperture
			l_cyl.height = 0.50 * barrel_len
			lens.mesh = l_cyl
			var l_mat = StandardMaterial3D.new()
			l_mat.albedo_color = Color(0.15, 0.18, 0.22)
			lens.material_override = l_mat
			lens.position = Vector3(0, trunnion_y, -(0.25 + 0.25 * barrel_len))
			lens.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(lens)

	elif type_id in ["plasma_lobber", "plasma_launcher"]:
		var containment = tweaks.get("containment", 1.0)
		var barrel_len = tweaks.get("barrel_length", tweaks.get("charge_rate", 1.0))

		# 1. MOUNT (plasma_lobber_mount.glb)
		var mount_mesh = _part("plasma_lobber_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(1.0, 1.0, 1.0)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.56, 0.16, 0.56)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		var trunnion_y = 0.28
		var barrel_group = Node3D.new()
		barrel_group.position = Vector3(0, trunnion_y, 0)
		barrel_group.rotation.x = deg_to_rad(35.0)
		parent_node.add_child(barrel_group)

		# 2. CONTAINMENT VESSEL CHAMBER (plasma_lobber_chamber.glb)
		var chamber_mesh = _part("plasma_lobber_chamber")
		var chamber: MeshInstance3D
		if chamber_mesh:
			chamber = _mesh_inst(chamber_mesh, Color(0.30, 0.20, 0.35))
			chamber.scale = Vector3(containment, containment, containment)
			chamber.position = Vector3(0, 0, 0)
		else:
			chamber = MeshInstance3D.new()
			var h_cyl = CylinderMesh.new()
			h_cyl.top_radius = 0.24 * containment
			h_cyl.bottom_radius = 0.24 * containment
			h_cyl.height = 0.40 * containment
			chamber.mesh = h_cyl
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.30, 0.20, 0.35)
			chamber.material_override = h_mat
			chamber.position = Vector3(0, 0, -0.20 * containment)
			chamber.rotation = Vector3(PI / 2, 0, 0)
		barrel_group.add_child(chamber)

		# 3. ACCELERATOR BARREL (plasma_lobber_barrel.glb)
		var barrel_mesh = _part("plasma_lobber_barrel")
		var barrel: MeshInstance3D
		if barrel_mesh:
			barrel = _mesh_inst(barrel_mesh, Color(0.20, 0.18, 0.25))
			barrel.scale = Vector3(containment, containment, barrel_len)
			barrel.position = Vector3(0, 0, 0)
		else:
			barrel = MeshInstance3D.new()
			var n_cyl = CylinderMesh.new()
			n_cyl.top_radius = 0.13 * containment
			n_cyl.bottom_radius = 0.13 * containment
			n_cyl.height = 0.45 * barrel_len
			barrel.mesh = n_cyl
			var n_mat = StandardMaterial3D.new()
			n_mat.albedo_color = Color(0.20, 0.18, 0.25)
			barrel.material_override = n_mat
			barrel.position = Vector3(0, 0, -0.45 * barrel_len)
			barrel.rotation = Vector3(PI / 2, 0, 0)
		barrel_group.add_child(barrel)

	elif type_id == "ciws":
		var caliber = tweaks.get("caliber", 1.0)
		var barrel_len = tweaks.get("barrel_length", 1.0)
		var radar_dish = tweaks.get("radar_dish", 1.0)

		# 1. MOUNT (ciws_mount.glb)
		var mount_mesh = _part("ciws_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(caliber, 1.0, caliber)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.58 * caliber, 0.16, 0.58 * caliber)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		# 2. RADOME & RECEIVER HOUSING (ciws_radar.glb)
		var trunnion_y = 0.32
		var radar_mesh = _part("ciws_radar")
		var radar: MeshInstance3D
		if radar_mesh:
			radar = _mesh_inst(radar_mesh, Color(0.90, 0.90, 0.90))
			radar.scale = Vector3(radar_dish, radar_dish, radar_dish)
			radar.position = Vector3(0, trunnion_y, 0)
		else:
			radar = MeshInstance3D.new()
			var h_cyl = CylinderMesh.new()
			h_cyl.top_radius = 0.24 * radar_dish
			h_cyl.bottom_radius = 0.24 * radar_dish
			h_cyl.height = 0.50 * radar_dish
			radar.mesh = h_cyl
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.90, 0.90, 0.90)
			radar.material_override = h_mat
			radar.position = Vector3(0, trunnion_y + 0.25 * radar_dish, 0)
		parent_node.add_child(radar)

		# 3. 6-BARREL ROTARY GATLING CLUSTER (ciws_barrel.glb)
		var barrel_mesh = _part("ciws_barrel")
		var barrel: MeshInstance3D
		if barrel_mesh:
			barrel = _mesh_inst(barrel_mesh, Color(0.20, 0.22, 0.25))
			barrel.scale = Vector3(caliber, caliber, barrel_len)
			barrel.position = Vector3(0, trunnion_y, 0)
		else:
			barrel = MeshInstance3D.new()
			var b_cyl = CylinderMesh.new()
			b_cyl.top_radius = 0.08 * caliber
			b_cyl.bottom_radius = 0.08 * caliber
			b_cyl.height = 0.85 * barrel_len
			barrel.mesh = b_cyl
			var b_mat = StandardMaterial3D.new()
			b_mat.albedo_color = Color(0.20, 0.22, 0.25)
			barrel.material_override = b_mat
			barrel.position = Vector3(0, trunnion_y, -0.42 * barrel_len)
			barrel.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(barrel)

	elif type_id in ["pd_laser", "point_defense_laser"]:
		var cooling_jacket = tweaks.get("cooling_jacket", 1.0)
		var barrel_len = tweaks.get("barrel_length", 1.0)

		# 1. GIMBAL MOUNT (pd_laser_mount.glb)
		var mount_mesh = _part("pd_laser_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(1.0, 1.0, 1.0)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.32, 0.14, 0.32)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.07, 0)
		parent_node.add_child(mount)

		# 2. DIODE RECEIVER HOUSING (pd_laser_housing.glb)
		var trunnion_y = 0.20
		var housing_mesh = _part("pd_laser_housing")
		var housing: MeshInstance3D
		if housing_mesh:
			housing = _mesh_inst(housing_mesh, Color(0.25, 0.30, 0.35))
			housing.scale = Vector3(cooling_jacket, cooling_jacket, 1.0)
			housing.position = Vector3(0, trunnion_y, 0)
		else:
			housing = MeshInstance3D.new()
			var h_box = BoxMesh.new()
			h_box.size = Vector3(0.18 * cooling_jacket, 0.18, 0.32)
			housing.mesh = h_box
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.25, 0.30, 0.35)
			housing.material_override = h_mat
			housing.position = Vector3(0, trunnion_y, -0.16)
		parent_node.add_child(housing)

		# 3. TWIN LENS EMITTERS (pd_laser_lens.glb)
		var lens_mesh = _part("pd_laser_lens")
		var lens: MeshInstance3D
		if lens_mesh:
			lens = _mesh_inst(lens_mesh, Color(0.15, 0.50, 0.75))
			lens.scale = Vector3(cooling_jacket, cooling_jacket, barrel_len)
			lens.position = Vector3(0, trunnion_y, 0)
		else:
			lens = MeshInstance3D.new()
			var l_cyl = CylinderMesh.new()
			l_cyl.top_radius = 0.04 * cooling_jacket
			l_cyl.bottom_radius = 0.04 * cooling_jacket
			l_cyl.height = 0.28 * barrel_len
			lens.mesh = l_cyl
			var l_mat = StandardMaterial3D.new()
			l_mat.albedo_color = Color(0.15, 0.50, 0.75)
			lens.material_override = l_mat
			lens.position = Vector3(0, trunnion_y, -0.14 * barrel_len)
			lens.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(lens)

	elif type_id in ["flak_cannon", "flak_battery"]:
		var caliber = tweaks.get("caliber", 1.0) * 0.75  # Cut flak scale to 0.75 per user request
		var barrel_len = tweaks.get("barrel_length", 1.0) * 0.75
		var barrel_count = int(tweaks.get("barrel_count", 2.0))
		barrel_count = clamp(barrel_count, 1, 4)
		var fuse_tweak = clampf(tweaks.get("fuse_setting", 1.0), 0.5, 2.0)

		# 1. MOUNT (flak_cannon_mount.glb)
		var mount_mesh = _part("flak_cannon_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		var mount_w = (1.0 + (barrel_count - 1) * 0.15) * caliber
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(mount_w, 1.0, caliber)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.52 * mount_w, 0.16, 0.52 * caliber)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.08, 0)
		parent_node.add_child(mount)

		var trunnion_y = 0.28
		var barrel_group = Node3D.new()
		barrel_group.position = Vector3(0, trunnion_y, 0)
		barrel_group.rotation.x = deg_to_rad(45.0)
		parent_node.add_child(barrel_group)

		# 2. BREECH BLOCK & RECUPERATOR (flak_cannon_breech.glb)
		var breech_mesh = _part("flak_cannon_breech")
		if not breech_mesh:
			breech_mesh = _part("flak_cannon_housing")
		var breech: MeshInstance3D
		if breech_mesh:
			breech = _mesh_inst(breech_mesh, Color(0.20, 0.22, 0.18))
			breech.scale = Vector3(mount_w, caliber, caliber)
			breech.position = Vector3(0, 0, 0)
		else:
			breech = MeshInstance3D.new()
			var h_box = BoxMesh.new()
			h_box.size = Vector3(0.34 * mount_w, 0.32 * caliber, 0.50 * caliber)
			breech.mesh = h_box
			var h_mat = StandardMaterial3D.new()
			h_mat.albedo_color = Color(0.20, 0.22, 0.18)
			breech.material_override = h_mat
			breech.position = Vector3(0, 0, -0.25 * caliber)
		barrel_group.add_child(breech)

		# 3. CLUSTERED FLAK BARRELS (flak_cannon_barrel.glb) - clustered formation, not line abreast
		var barrel_mesh = _part("flak_cannon_barrel")
		var offsets: Array[Vector2] = []
		if barrel_count == 1:
			offsets = [Vector2(0, 0)]
		elif barrel_count == 2:
			# Vertical stack cluster
			offsets = [Vector2(0, -0.06 * caliber), Vector2(0, 0.06 * caliber)]
		elif barrel_count == 3:
			# Delta triangle cluster
			offsets = [Vector2(0, 0.07 * caliber), Vector2(-0.06 * caliber, -0.05 * caliber), Vector2(0.06 * caliber, -0.05 * caliber)]
		else:
			# 2x2 Box cluster
			offsets = [Vector2(-0.06 * caliber, -0.06 * caliber), Vector2(0.06 * caliber, -0.06 * caliber), Vector2(-0.06 * caliber, 0.06 * caliber), Vector2(0.06 * caliber, 0.06 * caliber)]

		for off in offsets:
			var barrel: MeshInstance3D
			if barrel_mesh:
				barrel = _mesh_inst(barrel_mesh, Color(0.15, 0.16, 0.14))
				barrel.scale = Vector3(caliber, caliber, barrel_len)
				barrel.position = Vector3(off.x, off.y, 0.0)
				barrel_group.add_child(barrel)
			else:
				barrel = MeshInstance3D.new()
				var b_cyl = CylinderMesh.new()
				b_cyl.top_radius = 0.07 * caliber
				b_cyl.bottom_radius = 0.07 * caliber
				b_cyl.height = 1.10 * barrel_len
				barrel.mesh = b_cyl
				var b_mat = StandardMaterial3D.new()
				b_mat.albedo_color = Color(0.15, 0.16, 0.14)
				barrel.material_override = b_mat
				barrel.position = Vector3(off.x, off.y, -0.55 * barrel_len)
				barrel.rotation = Vector3(PI / 2, 0, 0)
				barrel_group.add_child(barrel)
			# The proximity fuse setter rides the barrel near the muzzle: a
			# brass ring whose size tracks the fuse setting dial.
			var fr_torus = TorusMesh.new()
			fr_torus.inner_radius = 0.055 * caliber * fuse_tweak
			fr_torus.outer_radius = 0.078 * caliber * fuse_tweak
			fr_torus.rings = 12
			fr_torus.ring_segments = 6
			var fuse_ring = MeshInstance3D.new()
			fuse_ring.mesh = fr_torus
			fuse_ring.material_override = _flat_mat(Color(0.83, 0.55, 0.20))
			fuse_ring.position = Vector3(off.x, off.y, -0.30 * barrel_len)
			barrel_group.add_child(fuse_ring)

	elif type_id == "repair_array":
		var arm_count = int(tweaks.get("welder_count", 2.0))
		arm_count = clamp(arm_count, 1, 4)
		var arm_reach = clampf(float(tweaks.get("arm_reach", 1.0)), 0.5, 2.0)
		var scale_mult = 2.5

		# 1. MOUNT PEDESTAL BASE (repair_array_mount.glb)
		var mount_mesh = _part("repair_array_mount")
		if not mount_mesh:
			mount_mesh = _part("pintle_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
			mount.scale = Vector3(scale_mult, scale_mult, scale_mult)
			mount.position = Vector3(0, 0, 0)
		else:
			mount = MeshInstance3D.new()
			var m_box = BoxMesh.new()
			m_box.size = Vector3(0.52 * scale_mult, 0.12 * scale_mult, 0.52 * scale_mult)
			mount.mesh = m_box
			var m_mat = StandardMaterial3D.new()
			m_mat.albedo_color = base_color.darkened(0.2)
			mount.material_override = m_mat
			mount.position = Vector3(0, 0.06 * scale_mult, 0)
		parent_node.add_child(mount)

		# 2. ARTICULATED FOLDED FACTORY ROBOT ARMS & WELDER TIPS
		var arm_mesh = _part("repair_array_arm")
		var welder_mesh = _part("repair_array_welder")
		for a in range(arm_count):
			var angle = (float(a) / float(arm_count)) * TAU
			var ax = cos(angle) * (0.14 * scale_mult)
			var az = sin(angle) * (0.14 * scale_mult)
			var arm: MeshInstance3D
			if arm_mesh:
				arm = _mesh_inst(arm_mesh, Color(0.25, 0.28, 0.32))
				arm.scale = Vector3(scale_mult, scale_mult * arm_reach, scale_mult * arm_reach)
				arm.position = Vector3(ax, 0, az)
				arm.rotation.y = -angle
			else:
				arm = MeshInstance3D.new()
				var a_cyl = CylinderMesh.new()
				a_cyl.top_radius = 0.03 * scale_mult
				a_cyl.bottom_radius = 0.04 * scale_mult
				a_cyl.height = 0.40 * scale_mult
				arm.mesh = a_cyl
				var a_mat = StandardMaterial3D.new()
				a_mat.albedo_color = Color(0.25, 0.28, 0.32)
				arm.material_override = a_mat
				arm.position = Vector3(ax, 0.20 * scale_mult, az)
			parent_node.add_child(arm)

			var welder: MeshInstance3D
			if welder_mesh:
				welder = _mesh_inst(welder_mesh, Color(0.20, 0.23, 0.28))
				welder.scale = Vector3(scale_mult, scale_mult * arm_reach, scale_mult * arm_reach)
				welder.position = Vector3(ax, 0, az)
				welder.rotation.y = -angle
			else:
				welder = MeshInstance3D.new()
				var w_sph = SphereMesh.new()
				w_sph.radius = 0.05 * scale_mult
				w_sph.height = 0.10 * scale_mult
				welder.mesh = w_sph
				var w_mat = StandardMaterial3D.new()
				w_mat.albedo_color = Color.CYAN
				w_mat.emission_enabled = true
				w_mat.emission = Color.CYAN
				welder.material_override = w_mat
				welder.position = Vector3(ax, 0.38 * scale_mult, az)
			parent_node.add_child(welder)

	elif type_id == "sensor_suite":
		var mast_h = clampf(float(tweaks.get("mast_height", 1.0)), 0.5, 2.0)
		var dish_ap = clampf(float(tweaks.get("dish_aperture", 1.0)), 0.5, 2.0)
		var whip_len = clampf(float(tweaks.get("whip_length", 1.0)), 0.6, 1.8)

		# 1. RUGGED ELECTRONICS HOUSING BASE (sensor_housing_rugged.glb)
		var mount_mesh = _part("sensor_housing_rugged")
		if not mount_mesh:
			mount_mesh = _part("sensor_suite_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
		else:
			mount = MeshInstance3D.new()
		mount.position = Vector3(0, 0, 0)
		parent_node.add_child(mount)

		# 2. LATTICE MAST COLUMN (sensor_suite_mast.glb)
		var mast_mesh = _part("sensor_suite_mast")
		var mast: MeshInstance3D = _mesh_inst(mast_mesh, Color(0.25, 0.28, 0.32)) if mast_mesh else MeshInstance3D.new()
		mast.scale = Vector3(1.0, mast_h, 1.0)
		mast.position = Vector3(0, 0, 0)
		parent_node.add_child(mast)

		# 3. ROTATING PARABOLIC DISH (sensor_dish_parabolic.glb / sensor_suite_dish.glb)
		var dish_mesh = _part("sensor_dish_parabolic")
		if not dish_mesh:
			dish_mesh = _part("sensor_suite_dish")
		var dish: MeshInstance3D = _mesh_inst(dish_mesh, Color(0.85, 0.88, 0.90)) if dish_mesh else MeshInstance3D.new()
		dish.name = "sensor_suite_dish"
		dish.scale = Vector3(dish_ap, dish_ap, dish_ap)
		dish.position = Vector3(0, 1.00 * mast_h, 0)
		parent_node.add_child(dish)

		# 4. COILED WHIP ANTENNA (antenna_whip_coiled.glb)
		var whip_mesh = _part("antenna_whip_coiled")
		if not whip_mesh:
			whip_mesh = _part("antenna_whip")
		if whip_mesh:
			var whip: MeshInstance3D = _mesh_inst(whip_mesh, Color(0.75, 0.78, 0.80))
			whip.scale = Vector3(1.0, whip_len, 1.0)
			whip.position = Vector3(0.18, 0.12, -0.14)
			parent_node.add_child(whip)

	elif type_id == "heavy_sensor_suite":
		var pylon_h = clampf(float(tweaks.get("pylon_height", 1.0)), 0.5, 2.0)
		var radome_s = clampf(float(tweaks.get("radome_scale", 1.0)), 0.6, 1.8)
		var optics_ap = clampf(float(tweaks.get("optics_aperture", 1.0)), 0.6, 1.8)

		# 1. HEAVY RUGGED ELECTRONICS HOUSING BASE (sensor_housing_rugged.glb)
		var mount_mesh = _part("sensor_housing_rugged")
		if not mount_mesh:
			mount_mesh = _part("sensor_suite_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
		else:
			mount = MeshInstance3D.new()
		mount.scale = Vector3(1.2, 1.0, 1.2)
		parent_node.add_child(mount)

		# 2. HEAVY SENSOR PYLON (sensor_pylon_heavy.glb)
		var pylon_mesh = _part("sensor_pylon_heavy")
		if not pylon_mesh:
			pylon_mesh = _part("sensor_suite_mast")
		var pylon: MeshInstance3D = _mesh_inst(pylon_mesh, Color(0.24, 0.27, 0.30)) if pylon_mesh else MeshInstance3D.new()
		pylon.scale = Vector3(1.1, pylon_h, 1.1)
		parent_node.add_child(pylon)

		# 3. MULTISPECTRUM RADOME (sensor_radome_multispectrum.glb)
		var radome_mesh = _part("sensor_radome_multispectrum")
		if not radome_mesh:
			radome_mesh = _part("sensor_dome")
		var radome: MeshInstance3D = _mesh_inst(radome_mesh, Color(0.88, 0.90, 0.92)) if radome_mesh else MeshInstance3D.new()
		radome.name = "multispectrum_radome"
		radome.scale = Vector3(radome_s, radome_s, radome_s)
		radome.position = Vector3(0, 0.98 * pylon_h, 0)
		parent_node.add_child(radome)

		# 4. SECONDARY EO/IR OPTICAL TURRET (amr_sensor_pod.glb)
		var pod_mesh = _part("amr_sensor_pod")
		if pod_mesh:
			var pod: MeshInstance3D = _mesh_inst(pod_mesh, Color(0.85, 0.50, 0.25))
			pod.scale = Vector3(optics_ap, optics_ap, optics_ap)
			pod.position = Vector3(0.14 * radome_s, 0.52 * pylon_h, 0.08)
			parent_node.add_child(pod)

		# 5. DUAL COILED WHIP ANTENNAS (antenna_whip_coiled.glb)
		var whip_mesh = _part("antenna_whip_coiled")
		if not whip_mesh:
			whip_mesh = _part("antenna_whip")
		if whip_mesh:
			var whip1: MeshInstance3D = _mesh_inst(whip_mesh, Color(0.75, 0.78, 0.80))
			whip1.position = Vector3(-0.24, 0.12, -0.16)
			parent_node.add_child(whip1)
			var whip2: MeshInstance3D = _mesh_inst(whip_mesh, Color(0.75, 0.78, 0.80))
			whip2.position = Vector3(0.24, 0.12, -0.16)
			parent_node.add_child(whip2)

	elif type_id == "directional_radar":
		var mast_h = clampf(float(tweaks.get("mast_height", 1.0)), 0.5, 2.0)
		var arc_deg = clampf(float(tweaks.get("scan_arc", 60.0)), 40.0, 120.0)
		var gain = clampf(float(tweaks.get("array_gain", 1.0)), 0.6, 1.8)
		var array_width = clampf(arc_deg / 60.0, 0.6, 2.0)

		# 1. RUGGED RADAR MOUNT BASE (sensor_housing_rugged.glb)
		var mount_mesh = _part("sensor_housing_rugged")
		if not mount_mesh:
			mount_mesh = _part("fire_control_radar_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
		else:
			mount = MeshInstance3D.new()
		parent_node.add_child(mount)

		# 2. GIMBAL MAST COLUMN (sensor_pylon_heavy.glb / fire_control_radar_mast.glb)
		var mast_mesh = _part("sensor_pylon_heavy")
		if not mast_mesh:
			mast_mesh = _part("fire_control_radar_mast")
		var mast: MeshInstance3D = _mesh_inst(mast_mesh, Color(0.22, 0.25, 0.28)) if mast_mesh else MeshInstance3D.new()
		mast.scale = Vector3(1.0, mast_h, 1.0)
		parent_node.add_child(mast)

		# 3. PHASED ARRAY SECTOR DISH (sensor_phased_array.glb / fire_control_radar_dish.glb)
		var dish_mesh = _part("sensor_phased_array")
		if not dish_mesh:
			dish_mesh = _part("fire_control_radar_dish")
		var dish: MeshInstance3D = _mesh_inst(dish_mesh, Color(0.40, 0.60, 0.90)) if dish_mesh else MeshInstance3D.new()
		dish.name = "directional_radar_dish"
		dish.scale = Vector3(array_width, gain, 1.0)
		dish.position = Vector3(0, 0.88 * mast_h, 0)
		parent_node.add_child(dish)

		# 4. COILED WHIP ANTENNA (antenna_whip_coiled.glb)
		var whip_mesh = _part("antenna_whip_coiled")
		if not whip_mesh:
			whip_mesh = _part("antenna_whip")
		if whip_mesh:
			var whip: MeshInstance3D = _mesh_inst(whip_mesh, Color(0.75, 0.78, 0.80))
			whip.position = Vector3(0.22, 0.12, -0.16)
			parent_node.add_child(whip)

	elif type_id == "energy_barrier_projector":
		var mount_mesh = _part("energy_barrier_projector_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
		else:
			mount = MeshInstance3D.new()
		parent_node.add_child(mount)

		# projector_diameter radially sizes the array ring; coil_count thickens
		# its coil stack, so both sliders move the visible emitter.
		var proj_d = clampf(tweaks.get("projector_diameter", 1.0), 0.5, 2.0)
		var coils = clampf(tweaks.get("coil_count", 4.0), 2.0, 6.0)
		var array_mesh = _part("energy_barrier_projector_array")
		var array: MeshInstance3D = _mesh_inst(array_mesh, Color(0.15, 0.65, 0.85)) if array_mesh else MeshInstance3D.new()
		array.name = "energy_barrier_projector_array"
		array.scale = Vector3(proj_d, proj_d, proj_d * (1.0 + (coils - 4.0) * 0.12))
		parent_node.add_child(array)

		var facet = parent_node.get_meta("facet", "front") if parent_node.has_meta("facet") else "front"
		var hull_node = parent_node.get_parent()
		var full_aabb = get_full_hull_aabb(hull_node as Node3D) if (is_instance_valid(hull_node) and hull_node is Node3D) else AABB(Vector3(-2, -0.75, -3), Vector3(4, 1.5, 6))

		var shield_arc = build_shield_facet_arc(facet, full_aabb, parent_node.transform)
		shield_arc.name = "BarrierShield"
		parent_node.add_child(shield_arc)

	elif type_id == "heavy_barrier_projector":
		var mount_mesh = _part("heavy_barrier_mount")
		var mount: MeshInstance3D
		if mount_mesh:
			mount = _mesh_inst(mount_mesh, base_color.darkened(0.2), Color(0, 0, 0, 0), 0.0, "accent")
		else:
			mount = MeshInstance3D.new()
		parent_node.add_child(mount)

		var turret_pivot = Node3D.new()
		turret_pivot.name = "TurretBody"
		parent_node.add_child(turret_pivot)

		var turret_mesh = _part("heavy_barrier_turret")
		var turret: MeshInstance3D = _mesh_inst(turret_mesh, base_color) if turret_mesh else MeshInstance3D.new()
		turret_pivot.add_child(turret)

		var emitter_pivot = Node3D.new()
		emitter_pivot.name = "EmitterHorn"
		emitter_pivot.position = Vector3(0, 0.24, 0.06)
		turret_pivot.add_child(emitter_pivot)

		# barrier_capacity is how much the emitter can absorb - a bigger
		# absorber is visibly a bigger emitter horn.
		var bcap = clampf(tweaks.get("barrier_capacity", 1.0), 0.5, 2.5)
		var emitter_mesh = _part("heavy_barrier_emitter")
		var emitter: MeshInstance3D = _mesh_inst(emitter_mesh, Color(0.2, 0.75, 0.95)) if emitter_mesh else MeshInstance3D.new()
		emitter.scale = Vector3.ONE * bcap
		emitter_pivot.add_child(emitter)

		var field_shield = build_projected_aegis_field(parent_node, tweaks)
		field_shield.name = "ProjectedAegisField"
		parent_node.add_child(field_shield)

	elif type_id == "bubble_shield_projector":
		var mount_mesh = _part("energy_barrier_projector_mount")
		var mount: MeshInstance3D = _mesh_inst(mount_mesh, base_color.darkened(0.2)) if mount_mesh else MeshInstance3D.new()
		parent_node.add_child(mount)

		var emitter_mesh = _part("armor_shield_emitter")
		if emitter_mesh == null:
			emitter_mesh = _part("energy_barrier_projector_array")
		# barrier_capacity is shield strength - the generator ring visibly
		# grows with the capacity dial.
		var bcap = clampf(tweaks.get("barrier_capacity", 1.0), 0.5, 2.5)
		var emitter: MeshInstance3D = _mesh_inst(emitter_mesh, Color(0.2, 0.75, 0.95)) if emitter_mesh else MeshInstance3D.new()
		emitter.scale = Vector3.ONE * bcap
		emitter.position = Vector3(0, 0.12, 0)
		parent_node.add_child(emitter)

		var hull_node = parent_node.get_parent()
		var full_aabb = get_full_hull_aabb(hull_node as Node3D) if (is_instance_valid(hull_node) and hull_node is Node3D) else AABB(Vector3(-2, -0.75, -3), Vector3(4, 1.5, 6))

		var bubble_shield = build_enclosing_bubble_shield(full_aabb, parent_node.transform, tweaks)
		bubble_shield.name = "BubbleShield"
		parent_node.add_child(bubble_shield)

	elif type_id == "resource_harvester":
		var cutter_scale = clampf(tweaks.get("cutter_head", tweaks.get("extractor_size", 1.0)), 0.5, 2.0)
		var mount_depth = 0.45 * clampf(tweaks.get("mount_extension", 1.0), 0.6, 1.5)

		# 1. MEASURE FACET OR READ METADATA
		var facet_w = 2.0
		var facet_h = 1.0
		if parent_node.has_meta("facet_size"):
			var fs = parent_node.get_meta("facet_size")
			if fs is Vector2 and fs.x > 0.1 and fs.y > 0.1:
				facet_w = fs.x
				facet_h = fs.y
		elif parent_node.get_parent() != null and is_instance_valid(parent_node.get_parent()):
			var p = parent_node.get_parent()
			if p.has_node("CollisionShape3D"):
				var cshape = p.get_node("CollisionShape3D")
				if cshape.shape is BoxShape3D:
					facet_w = cshape.shape.size.x
					facet_h = cshape.shape.size.y

		# 2. PROCEDURAL SOLID TAPERED MOUNTING BLOCK
		var mount_inst = MeshInstance3D.new()
		mount_inst.name = "HarvesterMountBlock"
		var w_tip = clampf(0.96 * cutter_scale, 0.6, maxf(facet_w, 0.96 * cutter_scale))
		var h_tip = clampf(0.96 * cutter_scale, 0.6, maxf(facet_h, 0.96 * cutter_scale))
		mount_inst.mesh = _build_frustum_block_mesh(facet_w, facet_h, w_tip, h_tip, mount_depth)
		mount_inst.material_override = PartMaterialsScript.get_material("painted", base_color.darkened(0.25))
		parent_node.add_child(mount_inst)

		# Perimeter mounting flange trim at the hull contact base
		var flange_inst = MeshInstance3D.new()
		flange_inst.name = "HarvesterMountFlange"
		var f_box = BoxMesh.new()
		f_box.size = Vector3(facet_w + 0.04, 0.04, facet_h + 0.04)
		flange_inst.mesh = f_box
		flange_inst.material_override = PartMaterialsScript.get_material("painted", base_color.darkened(0.35))
		flange_inst.position = Vector3(0, 0.02, 0)
		parent_node.add_child(flange_inst)

		# 3. TRICONE DRILL HEAD WITH PROTECTIVE CAGE SHROUD (resource_harvester_drill.glb)
		var drill_mesh = _part("resource_harvester_drill")
		var drill: MeshInstance3D
		if drill_mesh:
			drill = _mesh_inst(drill_mesh, Color(0.30, 0.32, 0.35))
			drill.name = "HarvesterDrillHead"
			drill.scale = Vector3(cutter_scale, cutter_scale, cutter_scale)
			drill.position = Vector3(0, mount_depth, 0)
			drill.rotation = Vector3.ZERO
		else:
			drill = MeshInstance3D.new()
			drill.name = "HarvesterDrillHead"
			var d_cyl = CylinderMesh.new()
			d_cyl.top_radius = 0.04 * cutter_scale
			d_cyl.bottom_radius = 0.45 * cutter_scale
			d_cyl.height = 0.90 * cutter_scale
			drill.mesh = d_cyl
			var d_mat = StandardMaterial3D.new()
			d_mat.albedo_color = Color(0.30, 0.32, 0.35)
			drill.material_override = d_mat
			drill.position = Vector3(0, mount_depth + 0.45 * cutter_scale, 0)
		parent_node.add_child(drill)

	elif type_id == "resource_bay":
		# An open ore tub with a hinged spill lid. Two authored parts rather
		# than one, so the three tweaks can drive different axes of each - see
		# build_resource_bay_tub()'s docstring in tools/blender/build_meshes.py
		# for why the geometry is built to survive a non-uniform scale.
		#
		# bay_volume is the stat tweak, so it scales EVERYTHING - the part that
		# carries more has to look like it carries more, or the one tweak that
		# changes the unit's behaviour is the one tweak with no visual. The
		# other two are pure proportion: hopper_depth is height, hatch_width is
		# width, and neither touches capacity.
		var vol: float = clampf(tweaks.get("bay_volume", 1.0), 0.5, 2.0)
		var depth_t: float = clampf(tweaks.get("hopper_depth", 1.0), 0.6, 1.6)
		var width_t: float = clampf(tweaks.get("hatch_width", 1.0), 0.6, 1.6)
		# Cube root, not the raw value: bay_volume reads as a VOLUME and is
		# spent as one (capacity is linear in it), so growing all three axes by
		# the raw figure would make a 2.0 bay eight times the size on screen
		# while carrying only twice the ore.
		var vol_lin: float = pow(vol, 1.0 / 3.0)

		var tub_mesh = _part("resource_bay_tub")
		var tub: MeshInstance3D
		if tub_mesh:
			tub = _mesh_inst(tub_mesh, base_color)
			tub.scale = Vector3(vol_lin * width_t, vol_lin * depth_t, vol_lin)
			tub.position = Vector3.ZERO
		else:
			tub = MeshInstance3D.new()
			var t_box = BoxMesh.new()
			t_box.size = Vector3(vol_lin * width_t, vol_lin * depth_t, vol_lin)
			tub.mesh = t_box
			var t_mat = StandardMaterial3D.new()
			t_mat.albedo_color = base_color
			tub.material_override = t_mat
			tub.position = Vector3(0, vol_lin * depth_t * 0.5, 0)
		parent_node.add_child(tub)

		var lid_mesh = _part("resource_bay_lid")
		if lid_mesh:
			var lid: MeshInstance3D = _mesh_inst(lid_mesh, base_color.darkened(0.35))
			lid.scale = Vector3(vol_lin * width_t, 1.0, vol_lin)
			# Sits at the tub's mouth. The tub is modelled with its floor at
			# y=0 and a nominal height of 1.0, so the lip tracks the height
			# scale exactly rather than needing its own constant.
			lid.position = Vector3(0, vol_lin * depth_t * 1.03, 0)
			parent_node.add_child(lid)

	elif type_id == "fusion_generator":
		# Fusion reactor with embedded hull collar, magnetic containment core,
		# and cooling radiator fins (compact 0.40 scale).
		var r_len: float = clampf(tweaks.get("reactor_length", 1.0), 0.5, 2.0)
		var r_fins: float = clampf(tweaks.get("cooling_radiator", 1.0), 0.5, 2.0)
		const S_PWR := 0.40
		
		# Embedded hull collar/blister base
		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.4 * S_PWR, 0.25 * S_PWR, 1.6 * r_len * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.08 * S_PWR, 0)
		parent_node.add_child(collar)

		var core_mesh = _part("fusion_generator_core")
		if core_mesh:
			var core = _mesh_inst(core_mesh, base_color)
			core.scale = Vector3(S_PWR, S_PWR, r_len * S_PWR)
			core.position = Vector3.ZERO
			parent_node.add_child(core)

		var rad_mesh = _part("fusion_generator_radiator")
		if rad_mesh:
			var rad = _mesh_inst(rad_mesh, base_color.darkened(0.25))
			rad.scale = Vector3(r_fins * S_PWR, S_PWR, r_len * S_PWR)
			rad.position = Vector3.ZERO
			parent_node.add_child(rad)

	elif type_id == "diesel_generator":
		# Combustion turbine generator: heavy cast engine block with exhaust stacks and louvers.
		var disp: float = clampf(tweaks.get("engine_displacement", 1.0), 0.5, 2.0)
		var fins: float = clampf(tweaks.get("radiator_fins", 1.0), 0.5, 2.0)
		const S_PWR := 0.40

		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.3 * disp * S_PWR, 0.22 * S_PWR, 1.6 * disp * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.07 * S_PWR, 0)
		parent_node.add_child(collar)

		var block_mesh = _part("diesel_generator_block")
		if block_mesh:
			var block = _mesh_inst(block_mesh, base_color)
			block.scale = Vector3(disp * S_PWR, disp * S_PWR, disp * S_PWR)
			block.position = Vector3.ZERO
			parent_node.add_child(block)

		var vent_mesh = _part("diesel_generator_vents")
		if vent_mesh:
			var vents = _mesh_inst(vent_mesh, Color(0.2, 0.2, 0.22))
			vents.scale = Vector3(fins * S_PWR, disp * S_PWR, fins * S_PWR)
			vents.position = Vector3.ZERO
			parent_node.add_child(vents)

	elif type_id == "thermo_generator":
		# Thermoelectric Stirling generator: compact heat sink casing with copper pipe runners.
		var core_d: float = clampf(tweaks.get("core_diameter", 1.0), 0.5, 2.0)
		var hs_fins: float = clampf(tweaks.get("heatsink_fins", 1.0), 0.5, 2.0)
		const S_PWR := 0.40

		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.0 * core_d * S_PWR, 0.18 * S_PWR, 1.1 * core_d * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.06 * S_PWR, 0)
		parent_node.add_child(collar)

		var case_mesh = _part("thermo_generator_casing")
		if case_mesh:
			var casing = _mesh_inst(case_mesh, base_color)
			casing.scale = Vector3(core_d * S_PWR, S_PWR, core_d * S_PWR)
			casing.position = Vector3.ZERO
			parent_node.add_child(casing)

		var pipe_mesh = _part("thermo_generator_pipes")
		if pipe_mesh:
			var pipes = _mesh_inst(pipe_mesh, Color(0.65, 0.45, 0.25))
			pipes.scale = Vector3(hs_fins * S_PWR, S_PWR, hs_fins * S_PWR)
			pipes.position = Vector3.ZERO
			parent_node.add_child(pipes)

	elif type_id == "capacitor_bank":
		# Segmented cylindrical supercapacitor cells with heavy busbars.
		var cells_t: float = clampf(tweaks.get("bank_capacity", 4.0), 2.0, 6.0)
		var busbar_t: float = clampf(tweaks.get("busbar_gauge", 1.0), 0.5, 2.0)
		var cell_scale_z = cells_t / 4.0
		const S_PWR := 0.40

		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.0 * S_PWR, 0.16 * S_PWR, 1.2 * cell_scale_z * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.05 * S_PWR, 0)
		parent_node.add_child(collar)

		var cells_mesh = _part("capacitor_bank_cells")
		if cells_mesh:
			var cells = _mesh_inst(cells_mesh, Color(0.22, 0.24, 0.28))
			cells.scale = Vector3(S_PWR, S_PWR, cell_scale_z * S_PWR)
			cells.position = Vector3.ZERO
			parent_node.add_child(cells)

		var bus_mesh = _part("capacitor_bank_busbar")
		if bus_mesh:
			var bus = _mesh_inst(bus_mesh, Color(0.72, 0.55, 0.20))
			bus.scale = Vector3(busbar_t * S_PWR, busbar_t * S_PWR, cell_scale_z * S_PWR)
			bus.position = Vector3.ZERO
			parent_node.add_child(bus)

	elif type_id == "flywheel_storage":
		# High-velocity kinetic storage rotor with vacuum containment ring.
		var r_mass: float = clampf(tweaks.get("rotor_mass", 1.0), 0.5, 2.0)
		var c_armor: float = clampf(tweaks.get("containment_armor", 1.0), 0.5, 2.0)
		const S_PWR := 0.40

		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.3 * c_armor * S_PWR, 0.20 * S_PWR, 1.3 * c_armor * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.06 * S_PWR, 0)
		parent_node.add_child(collar)

		var house_mesh = _part("flywheel_storage_housing")
		if house_mesh:
			var housing = _mesh_inst(house_mesh, base_color)
			housing.scale = Vector3(c_armor * S_PWR, S_PWR, c_armor * S_PWR)
			housing.position = Vector3.ZERO
			parent_node.add_child(housing)

		var rotor_mesh = _part("flywheel_storage_rotor")
		if rotor_mesh:
			var rotor = _mesh_inst(rotor_mesh, Color(0.35, 0.37, 0.40))
			rotor.scale = Vector3(r_mass * S_PWR, r_mass * S_PWR, r_mass * S_PWR)
			rotor.position = Vector3.ZERO
			parent_node.add_child(rotor)

	elif type_id == "solid_state_battery":
		# Matrix cell array: low-profile hull-conforming tray with modular packs.
		var layers_t: float = clampf(tweaks.get("cell_layers", 4.0), 2.0, 6.0)
		var thick_t: float = clampf(tweaks.get("dielectric_thickness", 1.0), 0.5, 2.0)
		var layer_scale_z = layers_t / 4.0
		const S_PWR := 0.40

		var collar = MeshInstance3D.new()
		var col_box = BoxMesh.new()
		col_box.size = Vector3(1.2 * S_PWR, 0.14 * S_PWR, 1.4 * layer_scale_z * S_PWR)
		collar.mesh = col_box
		collar.material_override = _structural_body_mat(base_color)
		collar.position = Vector3(0, 0.05 * S_PWR, 0)
		parent_node.add_child(collar)

		var tray_mesh = _part("solid_state_battery_tray")
		if tray_mesh:
			var tray = _mesh_inst(tray_mesh, base_color)
			tray.scale = Vector3(S_PWR, thick_t * S_PWR, layer_scale_z * S_PWR)
			tray.position = Vector3.ZERO
			parent_node.add_child(tray)

		var cell_mesh = _part("solid_state_battery_cells")
		if cell_mesh:
			var cells = _mesh_inst(cell_mesh, Color(0.18, 0.20, 0.24))
			cells.scale = Vector3(S_PWR, thick_t * S_PWR, layer_scale_z * S_PWR)
			cells.position = Vector3.ZERO
			parent_node.add_child(cells)

	elif type_id in ["mk19_grenade_launcher", "autocannon", "recoilless_rifle", "coil_gun",
					 "napalm_mortar", "mine_layer", "smoke_discharger",
					 "anti_materiel_rifle", "arc_projector", "microwave_emitter",
					 "particle_lance", "spigot_mortar", "rocket_artillery",
					 "hypervelocity_missile", "sam_launcher", "loitering_munition",
					 "anti_radiation_missile", "bunker_buster", "cruise_missile",
					 "aa_autocannon", "sensor_beacon_launcher"]:
		# --- Roster expansion ------------------------------------------------
		# Assembled from authored .glb sub-parts (tools/blender/
		# build_roster_expansion.py) exactly like basic_cannon and the HMG
		# above, each with a primitive fallback so a broken or missing import
		# degrades to a readable shape rather than to nothing.
		#
		# The sub-part SPLIT is load-bearing, not cosmetic: every part a tweak
		# has to resize is its own mesh with its own origin, so barrel_length
		# stretches only the tube (never the breech, sight or grips),
		# drum_size scales only the magazine, and repeated parts (coils,
		# mines, discharger tubes) can be instanced N times. That is why, for
		# example, recoilless_breech and recoilless_tube are two files.
		var caliber = tweaks.get("caliber", 1.0)
		var length = tweaks.get("barrel_length", 1.0)

		match type_id:
			"mk19_grenade_launcher", "autocannon":
				var is_mk19 = type_id == "mk19_grenade_launcher"
				var prefix = "mk19" if is_mk19 else "autocannon"
				var trunnion_y = 0.25 if is_mk19 else 0.24
				var drum_scale = tweaks.get("drum_size", 1.0)

				# 1. CRADLE MOUNT
				var mount_mesh = _part(prefix + "_mount")
				if not mount_mesh:
					mount_mesh = _part("hmg_pintle_mount")
				if mount_mesh:
					var mount = _mesh_inst(mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					mount.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mount)
				else:
					var mount = MeshInstance3D.new()
					var m_box = BoxMesh.new()
					m_box.size = Vector3(0.34 * caliber, trunnion_y, 0.34 * caliber)
					mount.mesh = m_box
					mount.material_override = _flat_mat(base_color.darkened(0.25))
					mount.position = Vector3(0, trunnion_y / 2.0, 0)
					parent_node.add_child(mount)

				# 2. RECEIVER - scaled by caliber only, never by barrel length
				var rec_mesh = _part(prefix + "_receiver")
				if not rec_mesh:
					rec_mesh = _part("hmg_receiver")
				# MEASURED from each receiver's own .glb AABB, not shared and
				# not estimated: the MK19's front face sits at z = -0.16, the
				# remodelled M230's at -0.102. They used one shared -0.16,
				# which left the autocannon's barrel floating 0.058 clear of
				# its receiver - the same defect the anti-materiel rifle had.
				# Re-measure if either mesh changes.
				var rec_front_z = (MK19_RECEIVER_FRONT_Z if is_mk19 else AUTOCANNON_RECEIVER_FRONT_Z) * caliber
				if rec_mesh:
					var receiver = _mesh_inst(rec_mesh, Color(0.20, 0.22, 0.23))
					receiver.scale = Vector3(caliber, caliber, caliber)
					receiver.position = Vector3(0, trunnion_y, 0)
					parent_node.add_child(receiver)
				else:
					var receiver = MeshInstance3D.new()
					var r_box = BoxMesh.new()
					r_box.size = Vector3(0.17, 0.20, 0.42) * caliber
					receiver.mesh = r_box
					receiver.material_override = _flat_mat(Color(0.20, 0.22, 0.23))
					receiver.position = Vector3(0, trunnion_y, 0)
					parent_node.add_child(receiver)

				# 3. BARREL - the only part barrel_length touches
				var bar_mesh = _part(prefix + "_barrel")
				if not bar_mesh:
					bar_mesh = _part("hmg_barrel")
				if bar_mesh:
					var barrel = _mesh_inst(bar_mesh, Color(0.13, 0.14, 0.15))
					barrel.scale = Vector3(caliber, caliber, length * caliber)
					barrel.position = Vector3(0, trunnion_y, rec_front_z)
					parent_node.add_child(barrel)
				else:
					var barrel = MeshInstance3D.new()
					var b_cyl = CylinderMesh.new()
					b_cyl.top_radius = (0.075 if is_mk19 else 0.042) * caliber
					b_cyl.bottom_radius = (0.085 if is_mk19 else 0.055) * caliber
					b_cyl.height = (0.4 if is_mk19 else 0.85) * length
					barrel.mesh = b_cyl
					barrel.material_override = _flat_mat(Color(0.13, 0.14, 0.15))
					barrel.position = Vector3(0, trunnion_y, rec_front_z - b_cyl.height / 2.0)
					barrel.rotation = Vector3(PI / 2, 0, 0)
					parent_node.add_child(barrel)

				# 4. AMMO CAN - the only part drum_size touches
				var can_mesh = _part(prefix + ("_ammo_can" if is_mk19 else "_ammo_box"))
				if not can_mesh:
					can_mesh = _part("ammo_drum")
				if can_mesh:
					var can = _mesh_inst(can_mesh, Color(0.22, 0.26, 0.18))
					can.scale = Vector3.ONE * drum_scale * caliber
					# The M230's magazine is a linkless drum 0.28 units deep,
					# which simply does not fit under a receiver whose
					# trunnion sits 0.24 above the deck - so it mounts BEHIND
					# the gun and stands on the deck instead, which is also
					# where an ammunition drum that size would really go.
					# Its floor tracks drum_size so a big drum grows upward
					# rather than sinking through the deck.
					var can_y = trunnion_y * 0.85
					var can_z = 0.0
					if not is_mk19:
						can_y = AUTOCANNON_DRUM_FLOOR * drum_scale * caliber
						can_z = AUTOCANNON_DRUM_Z * caliber
					can.position = Vector3(0, can_y, can_z)
					parent_node.add_child(can)
				else:
					var can = MeshInstance3D.new()
					var c_box = BoxMesh.new()
					c_box.size = Vector3(0.19, 0.20, 0.24) * drum_scale * caliber
					can.mesh = c_box
					can.material_override = _flat_mat(Color(0.22, 0.26, 0.18))
					can.position = Vector3(-0.16 * drum_scale * caliber, trunnion_y * 0.85, 0)
					parent_node.add_child(can)

			"anti_materiel_rifle":
				# Long, thin, deliberate. The proportions are the point: the
				# breech runs back THROUGH the trunnions rather than hanging
				# off them, so the gun reads as balanced about its middle,
				# and the tube is long enough that the muzzle brake has to be
				# its own part or barrel_length would stretch the baffles.
				#
				# The Z constants below are MEASURED off the authored meshes'
				# own AABBs, not estimated. They were estimated originally,
				# and the barrel ended up mounted 0.11 units in front of the
				# breech's actual face - visibly floating in mid-air. Any
				# change to the .glb geometry has to re-measure them; a probe
				# that prints Mesh.get_aabb() for each part is the check.
				var amr_trunnion_y = 0.28
				var optic = tweaks.get("optic_power", 1.0)
				var bipod_down = tweaks.get("bipod_deploy", 0.0) >= 0.5

				# 1. TRUNNION CRADLE
				var amr_mount_mesh = _part("amr_mount")
				if not amr_mount_mesh:
					amr_mount_mesh = _part("pintle_mount")
				if amr_mount_mesh:
					var amr_mount = _mesh_inst(amr_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					amr_mount.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(amr_mount)
				else:
					var amr_mount = MeshInstance3D.new()
					var am_cyl = CylinderMesh.new()
					am_cyl.top_radius = 0.13 * caliber
					am_cyl.bottom_radius = 0.20 * caliber
					am_cyl.height = amr_trunnion_y
					amr_mount.mesh = am_cyl
					amr_mount.material_override = _flat_mat(base_color.darkened(0.25))
					amr_mount.position = Vector3(0, amr_trunnion_y / 2.0, 0)
					parent_node.add_child(amr_mount)

				# 2. BREECH - scaled by caliber only. barrel_length must never
				#    touch it, or the sight rail and feed chutes stretch too.
				var amr_has_breech = _part("amr_breech") != null
				var amr_breech_front_z = (AMR_BREECH_FRONT_Z if amr_has_breech else -0.52) * caliber
				if amr_has_breech:
					var amr_breech = _mesh_inst(_part("amr_breech"), Color(0.20, 0.22, 0.21))
					amr_breech.scale = Vector3.ONE * caliber
					amr_breech.position = Vector3(0, amr_trunnion_y, 0)
					parent_node.add_child(amr_breech)
				else:
					var amr_breech = MeshInstance3D.new()
					var ab_box = BoxMesh.new()
					ab_box.size = Vector3(0.30, 0.33, 1.04) * caliber
					amr_breech.mesh = ab_box
					amr_breech.material_override = _flat_mat(Color(0.20, 0.22, 0.21))
					amr_breech.position = Vector3(0, amr_trunnion_y, 0.15 * caliber)
					parent_node.add_child(amr_breech)

				# 3. BARREL - the only part barrel_length touches.
				var amr_bar_mesh = _part("amr_barrel")
				if not amr_bar_mesh:
					amr_bar_mesh = _part("barrel_thin")
				var amr_barrel_len: float
				if amr_bar_mesh:
					amr_barrel_len = AMR_BARREL_LEN * length * caliber
					var amr_barrel = _mesh_inst(amr_bar_mesh, Color(0.13, 0.14, 0.15))
					amr_barrel.scale = Vector3(caliber, caliber, length * caliber)
					amr_barrel.position = Vector3(0, amr_trunnion_y, amr_breech_front_z)
					parent_node.add_child(amr_barrel)
				else:
					amr_barrel_len = 0.95 * length * caliber
					var amr_barrel = MeshInstance3D.new()
					var abr_cyl = CylinderMesh.new()
					abr_cyl.top_radius = 0.035 * caliber
					abr_cyl.bottom_radius = 0.048 * caliber
					abr_cyl.height = amr_barrel_len
					amr_barrel.mesh = abr_cyl
					amr_barrel.material_override = _flat_mat(Color(0.13, 0.14, 0.15))
					amr_barrel.position = Vector3(0, amr_trunnion_y, amr_breech_front_z - amr_barrel_len / 2.0)
					amr_barrel.rotation = Vector3(PI / 2, 0, 0)
					parent_node.add_child(amr_barrel)

				# 4. MUZZLE BRAKE - own part, positioned at the barrel's ACTUAL
				#    tip so a longer barrel moves it rather than stretching it.
				var amr_brake_mesh = _part("amr_muzzle_brake")
				if not amr_brake_mesh:
					amr_brake_mesh = _part("muzzle_brake")
				if amr_brake_mesh:
					var amr_brake = _mesh_inst(amr_brake_mesh, Color(0.115, 0.10, 0.095))
					amr_brake.scale = Vector3.ONE * caliber
					amr_brake.position = Vector3(0, amr_trunnion_y, amr_breech_front_z - amr_barrel_len)
					parent_node.add_child(amr_brake)

				# 5. SENSOR HEAD - camera + LIDAR, not a scope. optic_power is
				#    the only thing that scales it, and it scales UNIFORMLY: a
				#    better sensor head is a bigger one, not a stretched one.
				var amr_pod_mesh = _part("amr_sensor_pod")
				if not amr_pod_mesh:
					amr_pod_mesh = _part("sensor_dome")
				if amr_pod_mesh:
					var amr_pod = _mesh_inst(amr_pod_mesh, Color(0.17, 0.19, 0.18))
					amr_pod.scale = Vector3.ONE * caliber * optic
					amr_pod.position = Vector3(-0.20 * caliber, amr_trunnion_y + 0.12 * caliber, 0.02 * caliber)
					parent_node.add_child(amr_pod)

				# 6. RECOIL BUFFER + HYDRAULICS - deliberately oversized, out
				#    the back past the breech's rear face. Caliber only: this
				#    absorbs the shot, it has nothing to do with barrel length.
				var amr_buf_mesh = _part("amr_buffer")
				if amr_buf_mesh:
					var amr_buf = _mesh_inst(amr_buf_mesh, Color(0.19, 0.20, 0.21))
					amr_buf.scale = Vector3.ONE * caliber
					amr_buf.position = Vector3(0, amr_trunnion_y, AMR_BUFFER_Z * caliber)
					parent_node.add_child(amr_buf)

				# 7. BIPOD - present ONLY when deployed. The tweak has a real
				#    combat effect (auto_weapon._bipod_blocks_firing), so it
				#    has to be visible on the model or the player has no way
				#    to tell a deployed rifle from a stowed one at a glance.
				if bipod_down:
					var amr_bipod_mesh = _part("amr_bipod")
					if amr_bipod_mesh:
						var amr_bipod = _mesh_inst(amr_bipod_mesh, Color(0.18, 0.19, 0.20))
						amr_bipod.scale = Vector3.ONE * caliber
						amr_bipod.position = Vector3(0, 0.0, amr_breech_front_z * 1.4)
						parent_node.add_child(amr_bipod)

			"arc_projector":
				# Jacob's-ladder apparatus, not a gun. The transformer body
				# sits BEHIND the trunnion and is most of the module's mass -
				# it is both the counterweight the balance test wants and the
				# visible answer to "where does the charge come from".
				var arc_trunnion_y = 0.352
				var contain = tweaks.get("containment", 1.0)
				var arc_len = tweaks.get("barrel_length", 1.0)

				var arc_mount_mesh = _part("arc_projector_mount")
				if arc_mount_mesh:
					var am = _mesh_inst(arc_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					am.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(am)

				var arc_body_mesh = _part("arc_projector_body")
				if arc_body_mesh:
					var ab = _mesh_inst(arc_body_mesh, Color(0.22, 0.24, 0.26))
					ab.scale = Vector3.ONE * caliber
					ab.position = Vector3(0, arc_trunnion_y, 0)
					parent_node.add_child(ab)

				# The ONLY part containment scales - the field emitter and its
				# electrodes. Measured: the body's front face is at z=-0.040.
				var arc_em_mesh = _part("arc_projector_emitter")
				if arc_em_mesh:
					var ae = _mesh_inst(arc_em_mesh, Color(0.30, 0.33, 0.36),
						Color(0.35, 0.85, 1.0), 0.7)
					ae.scale = Vector3(caliber * contain, caliber * contain, caliber * contain * arc_len)
					ae.position = Vector3(0, arc_trunnion_y, ARC_BODY_FRONT_Z * caliber - 0.05 * (arc_len - 1.0))
					parent_node.add_child(ae)

			"microwave_emitter":
				# The dish IS the silhouette; nothing else in the roster has
				# one. The magnetron can behind the trunnion is the ballast
				# that stops a 2.0-aperture dish tipping the module forward.
				var mw_trunnion_y = 0.262
				var dish = tweaks.get("dish_aperture", 1.0)
				var horn_len = tweaks.get("barrel_length", 1.0)

				var mw_mount_mesh = _part("microwave_mount")
				if mw_mount_mesh:
					var mm = _mesh_inst(mw_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					mm.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mm)

				var mw_body_mesh = _part("microwave_body")
				if mw_body_mesh:
					var mb = _mesh_inst(mw_body_mesh, Color(0.24, 0.25, 0.27))
					mb.scale = Vector3.ONE * caliber
					mb.position = Vector3(0, mw_trunnion_y, 0)
					parent_node.add_child(mb)

				# The ONLY part dish_aperture scales, and uniformly - a bigger
				# dish is a bigger dish, not a stretched one.
				var mw_dish_mesh = _part("microwave_dish")
				if mw_dish_mesh:
					var md = _mesh_inst(mw_dish_mesh, Color(0.62, 0.62, 0.60))
					md.scale = Vector3(caliber * dish, caliber * dish, caliber * dish * horn_len)
					md.position = Vector3(0, mw_trunnion_y, MICROWAVE_BODY_FRONT_Z * caliber - 0.06 * (horn_len - 1.0))
					parent_node.add_child(md)

			"particle_lance":
				# Charge-up heavy. The capacitor stack out the back is both
				# the counterweight and the thing charge_time scales, which is
				# the read the tweak needs: a longer wind-up is visibly more
				# stored charge bolted to the back of the gun.
				var pl_trunnion_y = 0.318
				var charge = tweaks.get("charge_time", 1.0)
				var focal = tweaks.get("focal_length", 1.0)
				var pl_len = tweaks.get("barrel_length", 1.0)

				var pl_mount_mesh = _part("lance_mount")
				if pl_mount_mesh:
					var pm = _mesh_inst(pl_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					pm.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(pm)

				var pl_breech_mesh = _part("lance_breech")
				if pl_breech_mesh:
					var pb = _mesh_inst(pl_breech_mesh, Color(0.21, 0.23, 0.25))
					pb.scale = Vector3.ONE * caliber
					pb.position = Vector3(0, pl_trunnion_y, 0)
					parent_node.add_child(pb)

				# UNIFORM scale, and no emission. Scaling only Z stretched the
				# individual capacitor cans into long tubes - the exact
				# smearing the part-separation rule exists to prevent - and a
				# 0.35 emission on the whole part turned the stack into one
				# solid glowing slab that read as a lightsaber rather than as
				# stored charge. Uniform keeps every can's proportions, and
				# the glow belongs on the accelerator when it fires, not baked
				# into the battery.
				var pl_cap_mesh = _part("lance_capacitors")
				if pl_cap_mesh:
					var pc = _mesh_inst(pl_cap_mesh, Color(0.28, 0.30, 0.34))
					pc.scale = Vector3.ONE * caliber * charge
					pc.position = Vector3(0, pl_trunnion_y, LANCE_BREECH_REAR_Z * caliber)
					parent_node.add_child(pc)

				var pl_acc_mesh = _part("lance_accelerator")
				if pl_acc_mesh:
					var pa = _mesh_inst(pl_acc_mesh, Color(0.16, 0.18, 0.21))
					pa.scale = Vector3(caliber, caliber, focal * pl_len * caliber)
					pa.position = Vector3(0, pl_trunnion_y, LANCE_BREECH_FRONT_Z * caliber)
					parent_node.add_child(pa)

			"spigot_mortar":
				# The bomb is bigger than the weapon. A spigot has no barrel:
				# the round slides OVER a rod, so rod_thickness and
				# payload_size scale two genuinely separate parts and the
				# silhouette changes shape rather than just size.
				var sp_trunnion_y = 0.250
				var sp_rod = tweaks.get("rod_thickness", 1.0)
				var sp_pay = tweaks.get("payload_size", 1.0)
				var sp_len = tweaks.get("barrel_length", 1.0)
				var sp_elev = deg_to_rad(50.0)

				var sp_mount_mesh = _part("spigot_mount")
				if sp_mount_mesh:
					var spm = _mesh_inst(sp_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					spm.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(spm)

				var sp_pivot = Node3D.new()
				sp_pivot.name = "ElevationPivot"
				sp_pivot.position = Vector3(0, sp_trunnion_y, 0)
				sp_pivot.rotation = Vector3(sp_elev, 0, 0)
				parent_node.add_child(sp_pivot)

				var sp_breech_mesh = _part("spigot_breech")
				if sp_breech_mesh:
					var spb = _mesh_inst(sp_breech_mesh, Color(0.21, 0.22, 0.20))
					spb.scale = Vector3.ONE * caliber
					sp_pivot.add_child(spb)

				var sp_rod_mesh = _part("spigot_rod")
				if sp_rod_mesh:
					var spr = _mesh_inst(sp_rod_mesh, Color(0.14, 0.15, 0.16))
					spr.scale = Vector3(sp_rod * caliber, sp_rod * caliber, caliber * sp_len)
					spr.position = Vector3(0, 0, SPIGOT_BREECH_FRONT_Z * caliber)
					sp_pivot.add_child(spr)

				var sp_bomb_mesh = _part("spigot_bomb")
				if sp_bomb_mesh:
					var spbomb = _mesh_inst(sp_bomb_mesh, Color(0.30, 0.32, 0.26))
					spbomb.scale = Vector3.ONE * sp_pay * caliber
					# Rides ON the rod, and rides FURTHER forward as the rod
					# grows (barrel_length). A longer spigot in the real
					# weapon also means the round sits further out on it -
					# without this the rod's extra length was hidden behind
					# the bomb, so the slider appeared to do nothing.
					spbomb.position = Vector3(0, 0, (SPIGOT_BREECH_FRONT_Z - 0.20 + 0.25 * (sp_len - 1.0)) * caliber)
					sp_pivot.add_child(spbomb)

			"rocket_artillery":
				# tube_count spawns more RAILS rather than scaling one, so the
				# rack visibly grows. Damage is split across the salvo (see
				# _fire_rocket_artillery), so this is a spread slider and not
				# a free upgrade.
				var ra_trunnion_y = 0.272
				var ra_rails = clampi(int(tweaks.get("tube_count", 4.0)), 2, 8)
				var ra_spread = clampf(tweaks.get("dispersion", 1.0), 0.5, 2.0)
				var ra_elev = deg_to_rad(32.0)

				var ra_mount_mesh = _part("rocket_arty_mount")
				if ra_mount_mesh:
					var ram = _mesh_inst(ra_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					ram.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(ram)

				var ra_pivot = Node3D.new()
				ra_pivot.name = "ElevationPivot"
				ra_pivot.position = Vector3(0, ra_trunnion_y, 0)
				ra_pivot.rotation = Vector3(ra_elev, 0, 0)
				parent_node.add_child(ra_pivot)

				var ra_cradle_mesh = _part("rocket_arty_cradle")
				if ra_cradle_mesh:
					var rac = _mesh_inst(ra_cradle_mesh, Color(0.22, 0.24, 0.21))
					rac.scale = Vector3.ONE * caliber
					ra_pivot.add_child(rac)

				var ra_rail_mesh = _part("rocket_arty_rail")
				if ra_rail_mesh:
					# Two rows when there are more than four, so a big rack
					# reads as a rack rather than as a very wide comb.
					var rows = 2 if ra_rails > 4 else 1
					var per_row = int(ceil(float(ra_rails) / float(rows)))
					var placed = 0
					for row in range(rows):
						for i in range(per_row):
							if placed >= ra_rails:
								break
							placed += 1
							var t = 0.0 if per_row == 1 else (float(i) / float(per_row - 1) - 0.5)
							var rail = _mesh_inst(ra_rail_mesh, Color(0.26, 0.27, 0.24))
							rail.scale = Vector3.ONE * caliber
							rail.position = Vector3(t * 0.26 * caliber * ra_spread,
								row * 0.13 * caliber * ra_spread,
								ROCKET_CRADLE_FRONT_Z * caliber)
							ra_pivot.add_child(rail)

			"hypervelocity_missile", "sam_launcher", "loitering_munition", \
			"anti_radiation_missile", "bunker_buster", "cruise_missile":
				# The six guided launchers share one authored pedestal and one
				# assembly path, differing in the body that gives each its
				# identity and in what it carries. That is honest reuse - they
				# genuinely are the same class of bolt-on launcher - and it
				# keeps six near-identical pedestal .glbs out of the repo.
				var ml_trunnion_y = 0.242
				var ml_spec = MISSILE_LAUNCHER_PARTS[type_id]
				var ml_count = clampi(int(tweaks.get("tube_count", ml_spec["default_count"])), 1, 4)
				var ml_cant = deg_to_rad(ml_spec["cant_deg"])

				var ml_ped_mesh = _part("missile_pedestal")
				if ml_ped_mesh:
					var mlp = _mesh_inst(ml_ped_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					mlp.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mlp)

				var ml_pivot = Node3D.new()
				ml_pivot.name = "ElevationPivot"
				ml_pivot.position = Vector3(0, ml_trunnion_y, 0)
				ml_pivot.rotation = Vector3(ml_cant, 0, 0)
				parent_node.add_child(ml_pivot)

				var ml_body_mesh = _part(ml_spec["body"])
				if ml_body_mesh:
					var mlb = _mesh_inst(ml_body_mesh, Color(0.21, 0.23, 0.25))
					mlb.scale = Vector3.ONE * caliber
					ml_pivot.add_child(mlb)

				# bunker_buster's climb rocket and cruise's fuel load stretch the round
				# itself along its long axis - a bigger climb motor or a longer
				# tank literally is a longer round.
				var round_bonus_z = 1.0
				if type_id == "bunker_buster":
					round_bonus_z = maxf(float(tweaks.get("ascent_thruster", 1.0)), 0.1)
				elif type_id == "cruise_missile":
					round_bonus_z = maxf(float(tweaks.get("motor_length", 1.0)), 0.1)
				var ml_round_mesh = _part(ml_spec["round"])
				if ml_round_mesh:
					# Single-round launchers (bunker buster, cruise) mount on
					# the centreline; multi-round ones spread across the body.
					var singles = ml_spec["default_count"] == 1
					var n = 1 if singles else ml_count
					for i in range(n):
						var t = 0.0 if n == 1 else (float(i) / float(n - 1) - 0.5)
						var rnd = _mesh_inst(ml_round_mesh, Color(ml_spec["tint"]))
						rnd.scale = Vector3.ONE * caliber * float(tweaks.get(ml_spec["scale_tweak"], 1.0))
						rnd.scale.z *= round_bonus_z
						rnd.position = Vector3(t * 0.20 * caliber, 0.0,
							float(ml_spec["front_z"]) * caliber)
						ml_pivot.add_child(rnd)

			"aa_autocannon":
				var aa_trunnion_y = 0.268
				var aa_len = tweaks.get("barrel_length", 1.0)
				var aa_mount_mesh = _part("aa_mount")
				if aa_mount_mesh:
					var aam = _mesh_inst(aa_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					aam.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(aam)
				# High fixed elevation - it is looking up, which is the point.
				var aa_pivot = Node3D.new()
				aa_pivot.name = "ElevationPivot"
				aa_pivot.position = Vector3(0, aa_trunnion_y, 0)
				aa_pivot.rotation = Vector3(deg_to_rad(38.0), 0, 0)
				parent_node.add_child(aa_pivot)
				var aa_rec_mesh = _part("aa_receiver")
				if aa_rec_mesh:
					var aar = _mesh_inst(aa_rec_mesh, Color(0.22, 0.24, 0.22))
					aar.scale = Vector3.ONE * caliber
					aa_pivot.add_child(aar)
				var aa_bar_mesh = _part("aa_barrel")
				if aa_bar_mesh:
					for side in [-1.0, 1.0]:
						var bar = _mesh_inst(aa_bar_mesh, Color(0.13, 0.14, 0.15))
						bar.scale = Vector3(caliber, caliber, aa_len * caliber)
						bar.position = Vector3(side * 0.055 * caliber, 0, AA_RECEIVER_FRONT_Z * caliber)
						aa_pivot.add_child(bar)

			"sensor_beacon_launcher":
				var beacon_size = clampf(tweaks.get("payload_size", 1.0), 0.6, 1.8)
				var sb_body_mesh = _part("beacon_body")
				if sb_body_mesh:
					var sbb = _mesh_inst(sb_body_mesh, base_color.darkened(0.1))
					sbb.scale = Vector3.ONE * caliber
					parent_node.add_child(sbb)
				var sb_tube_mesh = _part("beacon_tube")
				if sb_tube_mesh:
					var sbt = _mesh_inst(sb_tube_mesh, Color(0.26, 0.29, 0.25))
					sbt.scale = Vector3.ONE * caliber
					sbt.position = Vector3(0, 0.196 * caliber, -0.02 * caliber)
					sbt.rotation = Vector3(deg_to_rad(58.0), 0, 0)
					parent_node.add_child(sbt)
					# The beacon round itself rides the tube's far end - an
					# emitter orb scaled by Beacon Size, so the payload is the
					# part the slider moves.
					var beacon_sphere = SphereMesh.new()
					beacon_sphere.radius = 0.09 * caliber * beacon_size
					beacon_sphere.height = 0.18 * caliber * beacon_size
					beacon_sphere.radial_segments = 16
					beacon_sphere.rings = 10
					var beacon_orb = MeshInstance3D.new()
					beacon_orb.mesh = beacon_sphere
					var b_mat = StandardMaterial3D.new()
					b_mat.albedo_color = Color(0.95, 0.45, 0.20)
					b_mat.emission_enabled = true
					b_mat.emission = Color(0.95, 0.25, 0.05) * beacon_size
					beacon_orb.material_override = b_mat
					beacon_orb.position = Vector3(0, 0.34 * caliber, 0)
					sbt.add_child(beacon_orb)

			"recoilless_rifle":
				var trunnion_y = 0.27

				# 1. TRIPOD MOUNT
				var rr_mount_mesh = _part("recoilless_mount")
				if not rr_mount_mesh:
					rr_mount_mesh = _part("pintle_mount")
				if rr_mount_mesh:
					var mount = _mesh_inst(rr_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					mount.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mount)
				else:
					var mount = MeshInstance3D.new()
					var m_cyl = CylinderMesh.new()
					m_cyl.top_radius = 0.10 * caliber
					m_cyl.bottom_radius = 0.16 * caliber
					m_cyl.height = trunnion_y
					mount.mesh = m_cyl
					mount.material_override = _flat_mat(base_color.darkened(0.25))
					mount.position = Vector3(0, trunnion_y / 2.0, 0)
					parent_node.add_child(mount)

				# 2. BREECH + SIGHT + GRIP - fixed hardware, caliber only
				var breech_mesh = _part("recoilless_breech")
				if breech_mesh:
					var breech = _mesh_inst(breech_mesh, Color(0.24, 0.23, 0.20))
					breech.scale = Vector3(caliber, caliber, caliber)
					breech.position = Vector3(0, trunnion_y, 0)
					parent_node.add_child(breech)

				# 3. TUBE - grows forward with barrel_length, nothing else moves
				var rr_tube_mesh = _part("recoilless_tube")
				if not rr_tube_mesh:
					rr_tube_mesh = _part("barrel_standard")
				if rr_tube_mesh:
					var tube = _mesh_inst(rr_tube_mesh, Color(0.26, 0.25, 0.21))
					tube.scale = Vector3(caliber, caliber, length * caliber)
					tube.position = Vector3(0, trunnion_y, -0.045 * caliber)
					parent_node.add_child(tube)
				else:
					var tube = MeshInstance3D.new()
					var t_cyl = CylinderMesh.new()
					t_cyl.top_radius = 0.062 * caliber
					t_cyl.bottom_radius = 0.062 * caliber
					t_cyl.height = 0.8 * length
					tube.mesh = t_cyl
					tube.material_override = _flat_mat(Color(0.26, 0.25, 0.21))
					tube.position = Vector3(0, trunnion_y, -0.045 - t_cyl.height / 2.0)
					tube.rotation = Vector3(PI / 2, 0, 0)
					parent_node.add_child(tube)

				# 4. VENTURI - sits at the BREECH end, so it is deliberately
				# independent of barrel_length: the backblast nozzle points
				# where _fire_recoilless_rifle()'s damage cone goes, and that
				# must not drift when the tube is lengthened.
				var ven_mesh = _part("recoilless_venturi")
				if not ven_mesh:
					ven_mesh = _part("exhaust_cone")
				if ven_mesh:
					var venturi = _mesh_inst(ven_mesh, Color(0.12, 0.12, 0.12))
					venturi.scale = Vector3(caliber, caliber, caliber)
					venturi.position = Vector3(0, trunnion_y, 0.10 * caliber)
					parent_node.add_child(venturi)

			"coil_gun":
				var trunnion_y = 0.27
				# Barrel length drives BOTH the coil instance count and the rail
				# length, so the tweak reads as "a longer accelerator with more
				# stages" rather than just a number changing.
				var stage_tweak = tweaks.get("barrel_length", 1.0)
				var stages = clamp(int(round(stage_tweak * 5.0)), 3, 9)

				# 1. MOUNT
				var cg_mount_mesh = _part("coilgun_mount")
				if not cg_mount_mesh:
					cg_mount_mesh = _part("railgun_pintle_mount")
				if cg_mount_mesh:
					var mount = _mesh_inst(cg_mount_mesh, base_color.darkened(0.25), Color(0, 0, 0, 0), 0.0, "accent")
					mount.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mount)
				else:
					var mount = MeshInstance3D.new()
					var m_box = BoxMesh.new()
					m_box.size = Vector3(0.38 * caliber, trunnion_y, 0.38 * caliber)
					mount.mesh = m_box
					mount.material_override = _flat_mat(base_color.darkened(0.25))
					mount.position = Vector3(0, trunnion_y / 2.0, 0)
					parent_node.add_child(mount)

				# 2. BREECH - fixed, never stretched by the stage tweak
				var cg_breech_mesh = _part("coilgun_breech")
				if cg_breech_mesh:
					var breech = _mesh_inst(cg_breech_mesh, Color(0.22, 0.25, 0.28))
					breech.scale = Vector3(caliber, caliber, caliber)
					breech.position = Vector3(0, trunnion_y, 0)
					parent_node.add_child(breech)

				# 3. RAIL SPINE
				var rail_mesh = _part("coilgun_rail")
				if not rail_mesh:
					rail_mesh = _part("railgun_rails")
				var rail_z = -0.04 * caliber
				if rail_mesh:
					var rail = _mesh_inst(rail_mesh, Color(0.24, 0.27, 0.30))
					rail.scale = Vector3(caliber, caliber, stage_tweak * caliber)
					rail.position = Vector3(0, trunnion_y, rail_z)
					parent_node.add_child(rail)
				else:
					var rail = MeshInstance3D.new()
					var r_box = BoxMesh.new()
					r_box.size = Vector3(0.085 * caliber, 0.075 * caliber, 0.8 * stage_tweak)
					rail.mesh = r_box
					rail.material_override = _flat_mat(Color(0.24, 0.27, 0.30))
					rail.position = Vector3(0, trunnion_y, rail_z - r_box.size.z / 2.0)
					parent_node.add_child(rail)

				# 4. ACCELERATOR COILS - one instance per stage, spread along
				# the rail's actual (scaled) length so they always sit ON it.
				var coil_mesh = _part("coilgun_coil")
				var rail_span = 0.78 * stage_tweak * caliber
				for i in range(stages):
					var t = float(i) / float(max(1, stages - 1))
					var cz = rail_z - 0.06 * caliber - t * rail_span
					if coil_mesh:
						var coil = _mesh_inst(coil_mesh, Color(0.62, 0.36, 0.14))
						coil.scale = Vector3.ONE * caliber
						coil.position = Vector3(0, trunnion_y, cz)
						parent_node.add_child(coil)
					else:
						var coil = MeshInstance3D.new()
						var c_cyl = CylinderMesh.new()
						c_cyl.top_radius = 0.11 * caliber
						c_cyl.bottom_radius = 0.11 * caliber
						c_cyl.height = 0.05
						coil.mesh = c_cyl
						coil.material_override = _flat_mat(Color(0.62, 0.36, 0.14))
						coil.position = Vector3(0, trunnion_y, cz)
						coil.rotation = Vector3(PI / 2, 0, 0)
						parent_node.add_child(coil)

				# 5. CAPACITOR BANK
				var cap_mesh = _part("coilgun_capacitors")
				if not cap_mesh:
					cap_mesh = _part("railgun_capacitor_housing")
				if cap_mesh:
					var caps = _mesh_inst(cap_mesh, Color(0.30, 0.33, 0.36))
					caps.scale = Vector3.ONE * caliber
					caps.position = Vector3(0, trunnion_y * 0.45, 0.14 * caliber)
					parent_node.add_child(caps)

			"napalm_mortar":
				var trunnion_y = 0.18
				# Steep fixed elevation, applied as a pivot rotation on the
				# tube group rather than baked into the mesh - the same
				# approach ARTILLERY_ELEVATION_DEG/MORTAR_ELEVATION_DEG use.
				# SIGN: positive, same as ARTILLERY_/MORTAR_ELEVATION_DEG. The
				# parts are authored with the bore along -Z, and a POSITIVE X
				# rotation pitches -Z upward. This read -55.0, which pitched
				# the assembly nose-down through the deck - the flared muzzle
				# ended up below the breech, which is what made the barrel
				# look like it had been fitted upside down.
				var elev = deg_to_rad(NAPALM_ELEVATION_DEG)

				# 1. BASEPLATE
				var np_mount_mesh = _part("napalm_mount")
				if not np_mount_mesh:
					np_mount_mesh = _part("mortar_swivel_mount")
				if np_mount_mesh:
					var mount = _mesh_inst(np_mount_mesh, base_color.darkened(0.3), Color(0, 0, 0, 0), 0.0, "accent")
					mount.scale = Vector3(caliber, 1.0, caliber)
					parent_node.add_child(mount)
				else:
					var mount = MeshInstance3D.new()
					var m_cyl = CylinderMesh.new()
					m_cyl.top_radius = 0.12 * caliber
					m_cyl.bottom_radius = 0.24 * caliber
					m_cyl.height = trunnion_y
					mount.mesh = m_cyl
					mount.material_override = _flat_mat(base_color.darkened(0.3))
					mount.position = Vector3(0, trunnion_y / 2.0, 0)
					parent_node.add_child(mount)

				# Elevation pivot carries breech + tube together so they stay
				# aligned at any barrel_length.
				var elev_pivot = Node3D.new()
				elev_pivot.name = "ElevationPivot"
				elev_pivot.position = Vector3(0, trunnion_y, 0)
				elev_pivot.rotation = Vector3(elev, 0, 0)
				parent_node.add_child(elev_pivot)

				# 2. BREECH CAP
				var np_breech_mesh = _part("napalm_breech")
				if np_breech_mesh:
					var breech = _mesh_inst(np_breech_mesh, Color(0.30, 0.28, 0.24))
					breech.scale = Vector3(caliber, caliber, caliber)
					elev_pivot.add_child(breech)

				# 3. TUBE
				var np_tube_mesh = _part("napalm_tube")
				if not np_tube_mesh:
					np_tube_mesh = _part("mortar_tube_single")
				if np_tube_mesh:
					var tube = _mesh_inst(np_tube_mesh, Color(0.32, 0.30, 0.26))
					tube.scale = Vector3(caliber, caliber, length * caliber)
					elev_pivot.add_child(tube)
				else:
					var tube = MeshInstance3D.new()
					var t_cyl = CylinderMesh.new()
					t_cyl.top_radius = 0.13 * caliber
					t_cyl.bottom_radius = 0.115 * caliber
					t_cyl.height = 0.55 * length
					tube.mesh = t_cyl
					tube.material_override = _flat_mat(Color(0.32, 0.30, 0.26))
					tube.position = Vector3(0, 0, -t_cyl.height / 2.0)
					tube.rotation = Vector3(PI / 2, 0, 0)
					elev_pivot.add_child(tube)

				# 4. FUEL DRUM - deliberately OUTSIDE the elevation pivot: the
				# drum is hull-mounted plumbing, it doesn't swing with the tube.
				var drum_mesh = _part("napalm_fuel_drum")
				if not drum_mesh:
					drum_mesh = _part("fuel_tank")
				if drum_mesh:
					var drum = _mesh_inst(drum_mesh, Color(0.52, 0.24, 0.09))
					drum.scale = Vector3.ONE * caliber
					drum.position = Vector3(-0.22 * caliber, 0, 0.10 * caliber)
					parent_node.add_child(drum)

			"mine_layer":
				# Mines-per-volley and charge size are both visible on the
				# rack: more mines means more canisters loaded, a bigger
				# charge means bigger canisters.
				var mine_rows = clamp(int(tweaks.get("tube_count", 1.0)), 1, 4)
				var pay = tweaks.get("payload_size", 1.0)

				# 1. RACK CHASSIS
				var rack_mesh = _part("mine_layer_rack")
				if rack_mesh:
					var rack = _mesh_inst(rack_mesh, base_color.darkened(0.15))
					parent_node.add_child(rack)
				else:
					var rack = MeshInstance3D.new()
					var rk_box = BoxMesh.new()
					rk_box.size = Vector3(0.46, 0.32, 0.56)
					rack.mesh = rk_box
					rack.material_override = _flat_mat(base_color.darkened(0.15))
					rack.position = Vector3(0, 0.16, 0)
					parent_node.add_child(rack)

				# 2. LOADED MINE CANISTERS - two per row, rows from the tweak
				var can2_mesh = _part("mine_canister")
				if not can2_mesh:
					can2_mesh = _part("canister_small")
				for row in range(mine_rows):
					for col in range(2):
						var cz = -0.18 + row * 0.13
						var cx = (col - 0.5) * 0.19
						if can2_mesh:
							var m = _mesh_inst(can2_mesh, Color(0.28, 0.30, 0.18))
							m.scale = Vector3.ONE * pay
							m.position = Vector3(cx, 0.31, cz)
							parent_node.add_child(m)
						else:
							var m = MeshInstance3D.new()
							var mc = CylinderMesh.new()
							mc.top_radius = 0.085 * pay
							mc.bottom_radius = 0.085 * pay
							mc.height = 0.07 * pay
							m.mesh = mc
							m.material_override = _flat_mat(Color(0.28, 0.30, 0.18))
							m.position = Vector3(cx, 0.34, cz)
							parent_node.add_child(m)

				# 3. DISPENSER CHUTE
				var chute_mesh = _part("mine_layer_chute")
				if chute_mesh:
					var chute = _mesh_inst(chute_mesh, Color(0.19, 0.20, 0.17))
					chute.position = Vector3(0, 0.08, 0.28)
					parent_node.add_child(chute)

			"smoke_discharger":
				var tube_count = clamp(int(tweaks.get("tube_count", 4.0)), 2, 6)

				# 1. BRACKET
				var br_mesh = _part("smoke_discharger_bracket")
				if br_mesh:
					var bracket = _mesh_inst(br_mesh, base_color.darkened(0.2))
					parent_node.add_child(bracket)
				else:
					var bracket = MeshInstance3D.new()
					var br_box = BoxMesh.new()
					br_box.size = Vector3(0.36, 0.12, 0.24)
					bracket.mesh = br_box
					bracket.material_override = _flat_mat(base_color.darkened(0.2))
					bracket.position = Vector3(0, 0.06, 0)
					parent_node.add_child(bracket)

				# 2. LAUNCHER TUBES - one instance per tube, canted up and
				# splayed OUTWARD.
				#
				# The splay sign matters and is easy to get backwards (it was,
				# first time round - the bank converged into a point instead
				# of fanning out). Weapons face -Z, and a POSITIVE yaw about
				# +Y turns -Z toward -X. So the tube at the most negative X -
				# the leftmost, i == 0 - needs a POSITIVE yaw to lean further
				# left, i.e. outward. The lerp therefore runs from + down to
				# -, matching x running from - up to +.
				var tube_mesh = _part("smoke_discharger_tube")
				var spacing = 0.30 / max(1, tube_count - 1) if tube_count > 1 else 0.0
				var start_x = -0.15 if tube_count > 1 else 0.0
				for i in range(tube_count):
					var splay = 0.0
					if tube_count > 1:
						splay = lerp(0.25, -0.25, float(i) / float(tube_count - 1))
					var tx = start_x + i * spacing
					if tube_mesh:
						var tube = _mesh_inst(tube_mesh, Color(0.20, 0.21, 0.19))
						tube.position = Vector3(tx, 0.12, 0)
						tube.rotation = Vector3(deg_to_rad(35.0), splay, 0)
						parent_node.add_child(tube)
					else:
						var tube = MeshInstance3D.new()
						var t_cyl = CylinderMesh.new()
						t_cyl.top_radius = 0.048
						t_cyl.bottom_radius = 0.055
						t_cyl.height = 0.24
						tube.mesh = t_cyl
						tube.material_override = _flat_mat(Color(0.20, 0.21, 0.19))
						tube.position = Vector3(tx, 0.12, 0)
						tube.rotation = Vector3(deg_to_rad(-55.0), splay, 0)
						parent_node.add_child(tube)

	elif type_id == "booster_rack":
		_build_booster_rack(parent_node, base_color, tweaks)

	else:
		# Fallback: Simple box mesh for armor and basic parts
		var mesh_inst = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = base_size
		mesh_inst.mesh = box
		var mat = StandardMaterial3D.new()
		mat.albedo_color = base_color
		mesh_inst.material_override = mat
		mesh_inst.position = Vector3(0, base_size.y / 2.0, 0)
		parent_node.add_child(mesh_inst)

	# Apply deformations to the newly constructed meshes based on the tweaks
	_apply_tweak_deformations(type_id, parent_node, tweaks, base_size)



# Dispatcher for GlobalConfig.enable_animated_monolithic_parts: attaches the
# same named moving-part pivots the procedural fallback builds, on top of a
# monolithic authored body. No-op for any type_id without a moving-part
# helper - a monolithic body renders exactly as it did before this feature
# unless it's one of the types listed here.
#
# CAVEAT worth checking visually once this is toggled on: unlike a cannon
# barrel (which pokes out beyond its housing either way), a TripoSG-authored
# monolithic mesh for a rotor/propeller/dish/wing type may already sculpt
# the blades/dish/membrane INTO the single mesh. If so, attaching a second
# procedural copy on top will double the geometry rather than animate the
# existing one - inspect each type after enabling the flag and drop its
# _attach_moving_parts() case below if that's what's happening (the fix at
# that point is authoring the monolithic mesh WITHOUT the moving piece, not
# a code change here).
static func _attach_moving_parts(type_id: String, parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary):
	match type_id:
		"rotary_cannon":
			_attach_rotary_barrels(parent_node, base_size, tweaks)
		"helicopter_rotors":
			_attach_rotor_blades(parent_node, base_size)
		"ornithopter_wing":
			_attach_ornithopter_pivot(parent_node, base_size, base_color)
		"sensor_suite":
			_attach_radar_dish(parent_node, base_size, base_color)
		"ship_screw":
			_attach_ship_screw_blades(parent_node, base_size)
		"paddle_wheel":
			_attach_paddle_wheel_blades(parent_node, base_size, base_color)
		"propeller_prop":
			_attach_propeller_blades(parent_node, base_size, base_color, false)
		"pusher_prop":
			_attach_propeller_blades(parent_node, base_size, base_color, true)


static func get_full_hull_aabb(hull_node: Node3D) -> AABB:
	if not is_instance_valid(hull_node):
		return AABB(Vector3(-2.0, -0.75, -3.0), Vector3(4.0, 1.5, 6.0))

	var combined_aabb := AABB()
	var has_mesh := false
	var h_trans: Transform3D = hull_node.global_transform if hull_node.is_inside_tree() else hull_node.transform

	var stack = [hull_node]
	while not stack.is_empty():
		var curr = stack.pop_back()
		for child in curr.get_children():
			if child.has_meta("module_data"):
				continue
			if child is MeshInstance3D:
				var m_aabb = child.get_aabb()
				var c_trans: Transform3D = child.global_transform if child.is_inside_tree() else child.transform
				var rel_trans = h_trans.affine_inverse() * c_trans
				var loc_box = rel_trans * m_aabb
				if not has_mesh:
					combined_aabb = loc_box
					has_mesh = true
				else:
					combined_aabb = combined_aabb.merge(loc_box)
			if child.get_child_count() > 0:
				stack.append(child)

	if not has_mesh or combined_aabb.size.length_squared() < 0.01:
		var hull_type = hull_node.get_meta("type_id", "brenntal_medium_a") if hull_node.has_meta("type_id") else "brenntal_medium_a"
		var cat_data = ModuleCatalog.get_module_data(hull_type)
		var h_scale = hull_node.get_meta("hull_scale", Vector3.ONE) if hull_node.has_meta("hull_scale") else Vector3.ONE
		var sz = cat_data.get("size", Vector3(4.0, 1.5, 6.0)) * h_scale
		combined_aabb = AABB(-sz / 2.0, sz)

	return combined_aabb

static func build_shield_facet_arc(facet: String, full_hull_aabb: AABB, module_transform: Transform3D = Transform3D.IDENTITY) -> MeshInstance3D:
	var shield_inst = MeshInstance3D.new()

	var full_size = full_hull_aabb.size
	var full_center = full_hull_aabb.get_center()

	var w: float
	var h: float
	if facet == "left" or facet == "right":
		w = full_size.y * 1.25
		h = full_size.z * 1.05
	elif facet == "top" or facet == "bottom":
		w = full_size.x * 1.05
		h = full_size.z * 1.05
	else:
		w = full_size.x * 1.05
		h = full_size.y * 1.25

	var segs_u = 24
	var segs_v = 18

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var standoff = 3.0
	var bulge = 0.85

	var local_center = module_transform.inverse() * full_center

	for iv in range(segs_v + 1):
		var tv = float(iv) / float(segs_v)
		var v = lerpf(-PI / 2.0, PI / 2.0, tv)
		var cos_v = cos(v)
		var sin_v = sin(v)

		for iu in range(segs_u + 1):
			var tu = float(iu) / float(segs_u)
			var u = lerpf(-PI / 2.0, PI / 2.0, tu)
			var cos_u = cos(u)
			var sin_u = sin(u)

			var px = local_center.x + (w * 0.5) * sin_u
			var py = standoff + bulge * cos_u * cos_v
			var pz = local_center.z + (h * 0.5) * sin_v

			var nx = sin_u
			var ny = 1.2 * cos_u * cos_v
			var nz = sin_v

			st.set_normal(Vector3(nx, ny, nz).normalized())
			st.set_uv(Vector2(tu, tv))
			st.add_vertex(Vector3(px, py, pz))

	for iv in range(segs_v):
		for iu in range(segs_u):
			var i0 = iv * (segs_u + 1) + iu
			var i1 = i0 + 1
			var i2 = (iv + 1) * (segs_u + 1) + iu
			var i3 = i2 + 1

			st.add_index(i0)
			st.add_index(i1)
			st.add_index(i2)

			st.add_index(i1)
			st.add_index(i3)
			st.add_index(i2)

	var arr_mesh = st.commit()
	shield_inst.mesh = arr_mesh

	var mat = ShaderMaterial.new()
	mat.shader = preload("res://shaders/energy_shield.gdshader")
	mat.set_shader_parameter("shield_color", Color(0.35, 0.72, 1.0))
	mat.set_shader_parameter("base_opacity", 0.18)
	mat.set_shader_parameter("fresnel_power", 2.2)
	mat.set_shader_parameter("crackle_speed", 1.2)
	shield_inst.material_override = mat
	shield_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shield_inst

static func build_projected_aegis_field(parent_node: Node3D, tweaks: Dictionary) -> MeshInstance3D:
	var shield_inst = MeshInstance3D.new()
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var field_width_mult = float(tweaks.get("field_width", 1.0))
	var proj_dist = float(tweaks.get("projection_distance", 25.0))

	var half_w = 9.0 * field_width_mult
	var wall_height = 6.0 * sqrt(field_width_mult)
	var curve_depth = 2.5 * field_width_mult

	var segs_u = 18
	var segs_v = 10

	for iv in range(segs_v + 1):
		var tv = float(iv) / float(segs_v)
		for iu in range(segs_u + 1):
			var tu = float(iu) / float(segs_u)
			var u_rad = (tu - 0.5) * (PI * 0.70) # -63° to +63° horizontal arc
			var sin_u = sin(u_rad)
			var cos_u = cos(u_rad)

			var px = half_w * (sin_u / sin(PI * 0.35))
			var pz = -proj_dist + curve_depth * (1.0 - cos_u)
			# Top edge has a slight protective crest arch
			var arch_factor = 0.88 + 0.12 * cos_u
			var py = tv * wall_height * arch_factor

			# Normal pointing forward toward threat (-Z)
			var nx = sin_u * 0.6
			var ny = 0.05
			var nz = -cos_u

			st.set_normal(Vector3(nx, ny, nz).normalized())
			st.set_uv(Vector2(tu, tv))
			st.add_vertex(Vector3(px, py, pz))

	for iv in range(segs_v):
		for iu in range(segs_u):
			var i0 = iv * (segs_u + 1) + iu
			var i1 = i0 + 1
			var i2 = (iv + 1) * (segs_u + 1) + iu
			var i3 = i2 + 1

			# Front facing triangles (visible from both sides with cull_disabled)
			st.add_index(i0)
			st.add_index(i2)
			st.add_index(i1)

			st.add_index(i1)
			st.add_index(i2)
			st.add_index(i3)

	var arr_mesh = st.commit()
	shield_inst.mesh = arr_mesh

	var mat = ShaderMaterial.new()
	mat.shader = preload("res://shaders/energy_shield.gdshader")
	mat.set_shader_parameter("shield_color", Color(0.25, 0.78, 1.0))
	mat.set_shader_parameter("base_opacity", 0.16)
	mat.set_shader_parameter("fresnel_power", 2.4)
	mat.set_shader_parameter("crackle_speed", 1.1)
	mat.set_shader_parameter("warp_strength", 0.4)
	shield_inst.material_override = mat
	shield_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shield_inst

static func build_enclosing_bubble_shield(full_hull_aabb: AABB, module_transform: Transform3D = Transform3D.IDENTITY, tweaks: Dictionary = {}) -> MeshInstance3D:
	var shield_inst = MeshInstance3D.new()
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var full_size = full_hull_aabb.size
	var full_center = full_hull_aabb.get_center()
	var local_center = module_transform.inverse() * full_center

	# 1.0m base separation / standoff from the unit's bounding envelope (scaled with tweak)
	var standoff_mult = float(tweaks.get("bubble_standoff", tweaks.get("bubble_scale", 1.0)))
	var margin = 1.0 * standoff_mult
	var hx = full_size.x * 0.5
	var hy = full_size.y * 0.5
	var hz = full_size.z * 0.5

	# Elliptical balloon radii maintaining 1m clearance across all axes
	var rx = hx + margin
	var ry = hy + margin
	var rz = hz + margin

	var segs_u = 32
	var segs_v = 20

	for iv in range(segs_v + 1):
		var tv = float(iv) / float(segs_v)
		var theta = lerpf(-PI * 0.5, PI * 0.5, tv)
		var cos_theta = cos(theta)
		var sin_theta = sin(theta)

		for iu in range(segs_u + 1):
			var tu = float(iu) / float(segs_u)
			var phi = tu * TAU
			var cos_phi = cos(phi)
			var sin_phi = sin(phi)

			var ox = rx * cos_theta * sin_phi
			var oy = ry * sin_theta
			var oz = rz * cos_theta * cos_phi

			var px = local_center.x + ox
			var py = local_center.y + oy
			var pz = local_center.z + oz

			# Analytical surface normal for ellipsoid: gradient of (x/rx)^2 + (y/ry)^2 + (z/rz)^2
			var nx = ox / (rx * rx)
			var ny = oy / (ry * ry)
			var nz = oz / (rz * rz)

			st.set_normal(Vector3(nx, ny, nz).normalized())
			st.set_uv(Vector2(tu, tv))
			st.add_vertex(Vector3(px, py, pz))

	for iv in range(segs_v):
		for iu in range(segs_u):
			var i0 = iv * (segs_u + 1) + iu
			var i1 = i0 + 1
			var i2 = (iv + 1) * (segs_u + 1) + iu
			var i3 = i2 + 1

			st.add_index(i0)
			st.add_index(i2)
			st.add_index(i1)

			st.add_index(i1)
			st.add_index(i2)
			st.add_index(i3)

	var arr_mesh = st.commit()
	shield_inst.mesh = arr_mesh

	var mat = ShaderMaterial.new()
	mat.shader = preload("res://shaders/energy_shield.gdshader")
	mat.set_shader_parameter("shield_color", Color(0.32, 0.76, 1.0))
	mat.set_shader_parameter("base_opacity", 0.12)
	mat.set_shader_parameter("fresnel_power", 2.2)
	mat.set_shader_parameter("crackle_speed", 1.0)
	mat.set_shader_parameter("warp_strength", 0.35)
	shield_inst.material_override = mat
	shield_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shield_inst

static func _attach_rotary_barrels(parent_node: Node3D, base_size: Vector3, tweaks: Dictionary):
	var pivot = Node3D.new()
	pivot.name = PIVOT_BARREL_CLUSTER
	parent_node.add_child(pivot)

	var b_count = int(tweaks.get("barrel_count", 6.0))
	b_count = clamp(b_count, 3, 9)
	var caliber = tweaks.get("caliber", 1.0)
	var length = tweaks.get("barrel_length", 1.0)

	var trunnion_y = 0.24 * caliber
	pivot.position = Vector3(0, trunnion_y, 0)

	var barrel_mesh = _part("rotary_barrel_single")
	var clamp_mesh = _part("rotary_clamp_ring")

	var ring_r = 0.12 * caliber

	for i in range(b_count):
		var angle = i * (2.0 * PI / b_count)
		var barrel: MeshInstance3D
		var offset_x = cos(angle) * ring_r
		var offset_y = sin(angle) * ring_r

		if barrel_mesh:
			barrel = _mesh_inst(barrel_mesh, Color(0.15, 0.16, 0.18))
			barrel.scale = Vector3(caliber, caliber, length * caliber)
			barrel.position = Vector3(offset_x, offset_y, 0)
		else:
			barrel = MeshInstance3D.new()
			var b_cyl = CylinderMesh.new()
			b_cyl.top_radius = 0.024 * caliber
			b_cyl.bottom_radius = 0.024 * caliber
			b_cyl.height = 1.10 * length
			barrel.mesh = b_cyl
			var b_mat = StandardMaterial3D.new()
			b_mat.albedo_color = Color(0.15, 0.16, 0.18)
			barrel.material_override = b_mat
			barrel.position = Vector3(offset_x, offset_y, -(1.10 * length / 2.0))
			barrel.rotation = Vector3(PI / 2, 0, 0)
		pivot.add_child(barrel)

	if clamp_mesh:
		var clamp_inst = _mesh_inst(clamp_mesh, Color(0.20, 0.22, 0.24))
		var clamp_scale_xy = (ring_r + 0.05 * caliber) / 0.18
		clamp_inst.scale = Vector3(clamp_scale_xy, clamp_scale_xy, caliber)
		clamp_inst.position = Vector3(0, 0, -0.60 * length * caliber)
		pivot.add_child(clamp_inst)


# Spinning radar grid dish for sensor_suite, named "RadarDish" (already spun
# directly by auto_weapon.gd - see get_node_or_null("RadarDish") there, no
# rename needed since it was never nested under another pivot).
static func _attach_radar_dish(parent_node: Node3D, base_size: Vector3, base_color: Color):
	var dish = MeshInstance3D.new()
	dish.name = "RadarDish"
	var dish_cyl = CylinderMesh.new()
	dish_cyl.top_radius = base_size.x * 0.6
	dish_cyl.bottom_radius = base_size.x * 0.6
	dish_cyl.height = 0.06
	dish.mesh = dish_cyl
	var dish_mat = StandardMaterial3D.new()
	dish_mat.albedo_color = base_color
	dish.material_override = dish_mat
	dish.position = Vector3(0, base_size.y, 0)
	dish.rotation = Vector3(PI / 2 - 0.2, 0, 0)
	parent_node.add_child(dish)

static func _attach_rotor_blades(parent_node: Node3D, base_size: Vector3):
	var pivot = Node3D.new()
	pivot.name = PIVOT_ROTOR_BLADES
	var shaft_h = base_size.y * 0.8
	pivot.position = Vector3(0, shaft_h, 0)
	parent_node.add_child(pivot)
	var blade_mat = StandardMaterial3D.new()
	blade_mat.albedo_color = Color(0.1, 0.1, 0.1)
	var blades = MeshInstance3D.new()
	var blade_mesh = BoxMesh.new()
	blade_mesh.size = Vector3(base_size.x, 0.03, 0.2)
	blades.mesh = blade_mesh
	blades.material_override = blade_mat
	pivot.add_child(blades)

static func _attach_ornithopter_pivot(parent_node: Node3D, base_size: Vector3, base_color: Color):
	var pivot = Node3D.new()
	pivot.name = PIVOT_WING
	pivot.position = Vector3(base_size.x * 0.2, base_size.y * 0.15, 0)
	parent_node.add_child(pivot)

## The wheel mount: an angled driveshaft housing running up and inboard into a
## gearbox, with the hub hanging off the outboard end of it.
##
## Authored once, here, because Chris called the pontoon version "excellent" and
## asked for the same assembly on the screw drive and the legs. It works for the
## same reason the original wheel mounting did: the locomotion module's origin
## ALREADY SITS AT THE HULL'S UNDERSIDE (module_placer.gd puts it there), so a
## shaft angling up and inboard from a point just below that origin arrives
## inside the hull's solid volume by construction - no hull measurement, no
## reach solving, no subframe to bridge a gap that was never open. That
## invariant is the whole trick, and it is why four types can share one mount.
##
## `s` scales the whole assembly, `z` slides it fore/aft, `span` is its
## thickness along Z (a dually cluster or a wide drum wants a fatter housing).
## Returns the outboard hub position in the parent's local space so the caller
## can hang a wheel, a drum end or a leg on it without redoing the arithmetic.
## `hub_drop` overrides how far the hub hangs below the origin. A wheel wants
## the default (the mount is as deep as the wheel is big); a screw drum wants to
## hang well clear so the hull rides high over terrain, WITHOUT inflating the
## gearbox to get there. The driveshaft lengthens to match, so it still arrives
## inside the hull however deep the hub goes.
static func build_wheel_mount(parent_node: Node3D, base_color: Color,
		s: float = 1.0, z: float = 0.0, span: float = 0.3,
		hub_drop: float = -1.0, tweaks: Dictionary = {}) -> Vector3:
	# THE INVARIANT IN THE DOC COMMENT ABOVE IS NOW ACTUALLY TRUE.
	#
	# It claimed the module origin already sits at the hull's underside, so a
	# shaft angling up and inboard arrives inside the hull's solid volume by
	# construction. That held on a literal box and failed on everything else:
	# module_placer.gd put the origin at the fitted collision box's underside,
	# which on a keeled, chamfered or tumblehome hull is in open air, so the
	# shaft angled up into nothing and the whole assembly read as floating.
	# Measured across the roster, that point sat a mean of 0.335 units - max
	# 2.09 - from the hull's real lower edge.
	#
	# locomotion_mount.gd now seats the origin on the real chine, so the premise
	# this mount was built on finally holds, and the four types that share it
	# inherit the fix without their own geometry changing.
	#
	# Nothing generic is added on top: the driveshaft and gearbox below ARE this
	# family's mounting gear, and they only ever read as floating because they
	# were anchored to a point that was not on the hull. See the CHINE MOUNT
	# FRAME note for the bracket that was tried here and removed.
	# OUTBOARD STANDOFF. With the origin now on the hull skin rather than out at
	# the box corner, every x below is measured from the body itself, so the whole
	# assembly shifts out by the clearance the gear needs. Zero when unseated, so
	# the pre-existing look is untouched on anything this does not apply to.
	var stand: float = chine_standoff(chine_frame_from(tweaks), s)

	var hub_y: float = -0.2 * s if hub_drop < 0.0 else -hub_drop
	var gearbox_x := stand - 0.24 * s
	var ds_mesh := _part("wheel_driveshaft")
	var gb_mesh := _part("wheel_gearbox")
	if ds_mesh:
		# wheel_driveshaft is authored spanning Y=0 (top/pivot) to Y=-1
		# (bottom), so its bottom end after scale+rotation is
		# `position + Rz(angle)*(0,-len,0)`. Anchor the BOTTOM at the gearbox
		# and solve the pivot backward from it: the fixed end is the one that
		# has to meet the hub, and the free end is the one that should be
		# allowed to run as deep into the hull as the angle takes it.
		var shaft := _mesh_inst(ds_mesh, base_color.darkened(0.25).lightened(0.35))
		# Default depth keeps the original 55 degrees and length verbatim - the
		# wheels' look is settled and must not drift.
		#
		# A DEEP hub is a different structural problem: holding 55 degrees just
		# makes the strut longer, and at a full drum-diameter drop the two
		# struts ran so far inboard they crossed past each other under the hull
		# centreline. A deep leg should get STEEPER, not longer. So the angle is
		# solved from the drop instead: rise is whatever it takes to clear the
		# hull's underside, run is a bounded step inboard.
		var shaft_angle := deg_to_rad(55.0)
		var shaft_len: float = 1.0 * s
		if hub_drop >= 0.0:
			var rise: float = absf(hub_y) + 0.25 * s
			var run: float = 0.55 * s
			shaft_angle = atan2(run, rise)
			shaft_len = sqrt(run * run + rise * rise)
		var bottom_target := Vector3(gearbox_x + 0.05 * s, hub_y, z)

		# SOLVED TO REACH THE HULL, not left at its authored length.
		#
		# Chris, 2026-08-12: "the wheels axles not poke up through small hulls".
		# The 1.0 * s default was eyeballed against the reference hull (4 x 1 x 6);
		# on a shallow scout hull that shaft is longer than the hull is tall, so it
		# came out through the roof, and on a deep hull it stopped short inside.
		# The shaft starts below and outboard of the body and runs up and inboard,
		# so casting along its own axis gives the exact distance to the skin, and
		# MountReach adds the bite past it.
		shaft_len = MountReachScript.solve(parent_node,
			MountReachScript.station_from(tweaks), bottom_target,
			Vector3(-sin(shaft_angle), cos(shaft_angle), 0.0), shaft_len,
			MountReachScript.node_scale_from(tweaks))

		var drop := Vector3(sin(shaft_angle), -cos(shaft_angle), 0.0) * shaft_len
		shaft.scale = Vector3(0.32 * s, shaft_len, span)
		shaft.position = bottom_target - drop
		shaft.rotation = Vector3(0, 0, shaft_angle)
		parent_node.add_child(shaft)
	if gb_mesh:
		var gearbox := _mesh_inst(gb_mesh, base_color.darkened(0.1).lightened(0.3))
		var gb := 0.46 * s
		gearbox.scale = Vector3(gb, gb, span)
		gearbox.position = Vector3(gearbox_x, hub_y, z)
		parent_node.add_child(gearbox)
	# Pulled slightly INBOARD of the module origin, not outboard: the hub and
	# the gearbox should visibly overlap rather than sit adjacent (Chris's ask,
	# twice, on the original wheels).
	#
	# Chris reported the wheels "angling inward rather than outward from the
	# hull" and this offset was the obvious suspect, but it was not the cause -
	# the stations themselves had collapsed onto the centreline (see the
	# missing `else` in locomotion_layout.gd's x_offset block). This value is
	# left where it was rather than "fixed" alongside the real bug.
	#
	# The -0.05 is now relative to the STANDOFF rather than to the hull skin. It
	# was authored when the module origin sat out at the box corner, where pulling
	# the hub slightly inboard of the origin overlapped it with the gearbox. The
	# origin has since moved onto the hull, so keeping the offset absolute would
	# have pulled the hub INTO the body - the overlap it was tuned for is now
	# between the hub and the gearbox at the outboard end, which is where it was
	# always meant to be.
	return Vector3(stand - 0.05 * s, hub_y, z)


static func _build_wheels(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.BLACK, tweaks: Dictionary = {}):
	var wheel_size = float(tweaks.get("wheel_size", tweaks.get("size", 1.0)))
	var w_per_axle = int(tweaks.get("wheels_per_axle", 1.0))

	# Strict GLB part mesh loading - fails with assertion if asset is missing
	var wheel_mesh = _part("wheel_hub")

	var cluster_width = 0.3 * wheel_size * float(w_per_axle)

	# Lateral layout along local X. X=0 is the module's own local origin, i.e.
	# the hull mount point. build_wheel_mount() puts the gearbox inboard of it
	# and returns the hub point just outboard, keeping the whole cluster inside
	# the vehicle's footprint instead of hanging past its silhouette.
	var hub := build_wheel_mount(parent_node, base_color, wheel_size, 0.0, cluster_width, -1.0, tweaks)
	var hub_x_offset := hub.x
	var wheel_y := hub.y

	var spacing = 0.38 * wheel_size
	_repeat_along_axis(parent_node, w_per_axle, spacing, Vector3.RIGHT, func(p, pos, _idx):
		# Each wheel hangs under its own spin pivot rather than being parented
		# straight to the module. A wheel has to rotate about its OWN axle, and
		# the axle is offset from the module origin - spinning the module node
		# would swing the whole cluster around the mount point instead. Named
		# so unit.gd can find it: same by-name pivot convention as
		# "RotorBlades", "PropBlades", "LegSwing" and "ScrewSpin".
		var axle = Node3D.new()
		axle.name = SPIN_PIVOT_WHEEL
		axle.position = pos + Vector3(hub_x_offset, wheel_y, 0)
		p.add_child(axle)
		var wheel = _mesh_inst(wheel_mesh, Color(0.1, 0.1, 0.12))
		wheel.scale = Vector3(wheel_size, wheel_size, wheel_size)
		# wheel_hub.glb's hub-cap/lug-bolt detail is authored at its +Y end
		# (the "outward-facing" side of the tire, per build_wheel() in
		# build_meshes.py) - rotation.z = -PI/2 (not +PI/2) maps that +Y face
		# to +X, i.e. outboard/away from the mount column above, so the
		# visible hub face points away from the vehicle instead of backwards
		# into the gearbox.
		wheel.rotation = Vector3(0, 0, -PI / 2.0)
		axle.add_child(wheel)
	)


# The numbers tread_belt_loop.glb was authored with (see _track_path in
# tools/blender/build_locomotion_rework.py). EVERY placement below derives from
# these, so the mesh and the runtime cannot disagree about where the sprocket
# centreline, the road-wheel line or the belt path are. When the mesh changes,
# these change in the same commit.
const BELT_HALF_SPAN := 2.6     # sprocket centre to idler centre, halved
const BELT_DRIVE_RADIUS := 0.46 # sprocket / idler radius
const BELT_ROAD_DROP := 0.38    # road-wheel centre below the sprocket centreline
const BELT_ROAD_RADIUS := 0.22  # road-wheel radius

static func _deform_tread_loop_mesh(source_mesh: Mesh, front_z: float, rear_z: float, radius_scale: float, width_scale: float, belt_scale: float) -> ArrayMesh:
	var target_wheel_bottom_y: float = -(BELT_ROAD_DROP + BELT_ROAD_RADIUS) * belt_scale
	var new_mesh = ArrayMesh.new()
	for surface_idx in range(source_mesh.get_surface_count()):
		var mdt = MeshDataTool.new()
		var err = mdt.create_from_surface(source_mesh, surface_idx)
		if err != OK:
			continue
		for i in range(mdt.get_vertex_count()):
			var v = mdt.get_vertex(i)
			var new_z: float = v.z
			if v.z <= -1.0:
				# Front end arc: center at local z = -1.0. Pin center to front_z, scale radius curve by radius_scale.
				new_z = front_z + (v.z + 1.0) * radius_scale
			elif v.z >= 1.0:
				# Rear end arc: center at local z = +1.0. Pin center to rear_z, scale radius curve by radius_scale.
				new_z = rear_z + (v.z - 1.0) * radius_scale
			else:
				# Middle span: stretch Z to connect front_z and rear_z.
				new_z = v.z * (abs(front_z))

			var new_y: float = v.y * radius_scale
			if v.y < -0.2:
				# Bottom run: adjust flat middle section so its top inner surface touches the bottom of the road wheels
				var y_bottom_flat: float = target_wheel_bottom_y + (v.y - (-0.62)) * belt_scale
				var blend: float = clamp((abs(v.z) - 0.55) / 0.45, 0.0, 1.0)
				new_y = lerp(y_bottom_flat, new_y, blend)

			var new_x: float = v.x * width_scale
			mdt.set_vertex(i, Vector3(new_x, new_y, new_z))
		mdt.commit_to_surface(new_mesh)
	return new_mesh


## Builds a thick trapezoid block gearbox for track sprockets: longer than wide,
## wider than tall, with narrow side inboard.
static func _make_trapezoid_gearbox_mesh(r: float) -> ArrayMesh:
	var l_out: float = r * 1.50
	var l_in: float = r * 0.85
	var w: float = r * 1.05
	var h: float = r * 0.60

	var v0 := Vector3(0.0, h * 0.5, -l_out * 0.5)
	var v1 := Vector3(0.0, h * 0.5, l_out * 0.5)
	var v2 := Vector3(-w, h * 0.5, l_in * 0.5)
	var v3 := Vector3(-w, h * 0.5, -l_in * 0.5)
	var v4 := Vector3(0.0, -h * 0.5, -l_out * 0.5)
	var v5 := Vector3(0.0, -h * 0.5, l_out * 0.5)
	var v6 := Vector3(-w, -h * 0.5, l_in * 0.5)
	var v7 := Vector3(-w, -h * 0.5, -l_in * 0.5)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var add_quad = func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3):
		st.set_normal(n)
		st.add_vertex(a)
		st.add_vertex(b)
		st.add_vertex(c)
		st.add_vertex(a)
		st.add_vertex(c)
		st.add_vertex(d)

	add_quad.call(v0, v4, v5, v1, Vector3.RIGHT)
	add_quad.call(v3, v2, v6, v7, Vector3.LEFT)
	add_quad.call(v0, v1, v2, v3, Vector3.UP)
	add_quad.call(v4, v7, v6, v5, Vector3.DOWN)
	add_quad.call(v0, v3, v7, v4, (v3 - v0).cross(v4 - v0).normalized())
	add_quad.call(v1, v5, v6, v2, (v1 - v5).cross(v6 - v5).normalized())

	return st.commit()


static func _build_tracked_treads(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DARK_SLATE_GRAY, tweaks: Dictionary = {}):
	var width = tweaks.get("tread_width", tweaks.get("width", tweaks.get("size", 1.0)))
	var road_wheels = 5
	var sprocket = tweaks.get("drive_sprocket", true)

	var loop_mesh = _part("tread_belt_loop")
	var sprocket_mesh = _part("drive_sprocket")
	var wheel_mesh = _part("wheel_hub")
	var gearbox_mesh = _part("wheel_gearbox")
	var driveshaft_mesh = _part("wheel_driveshaft")

	var target_length = tweaks.get("target_length", base_size.z)
	var length_scale = target_length / base_size.z
	var actual_size = Vector3(base_size.x * length_scale, base_size.y * length_scale, target_length)

	var target_radius = actual_size.y * 0.48
	var target_half_span = actual_size.z * 0.5 - target_radius
	var authored_radius = 0.45
	var authored_drop = 0.4
	var authored_half_span = 1.0
	var y_scale = target_radius / authored_radius
	var target_drop = authored_drop * y_scale
	var ground_offset = target_radius + target_drop
	var y_shift = -target_radius * 0.9

	var outboard_x = 0.0

	# Sprocket center hubs are pulled in by one full diameter (2 radii)
	# from the front and back ends of the hull.
	var belt_scale: float = target_length / (BELT_HALF_SPAN * 2.0 + BELT_DRIVE_RADIUS * 4.0)
	var sprocket_scale: float = (BELT_DRIVE_RADIUS * belt_scale) / 0.4
	var sprocket_width_authored: float = 0.3
	var sprocket_radius: float = BELT_DRIVE_RADIUS * belt_scale

	var front_z: float = -target_length * 0.5 + 2.0 * sprocket_radius
	var rear_z: float = target_length * 0.5 - 2.0 * sprocket_radius
	var span: float = rear_z - front_z

	var belt_center_x: float = outboard_x - sprocket_width_authored * 0.5 * sprocket_scale * width

	# Pin the track assembly and sprocket center hubs directly at the
	# hull's lower chine (Y = 0 in module local space).
	var loop_center_y: float = 0.0

	# Match radius of treads radius curves to wheels + 5% (1.05 * sprocket_radius)
	var tread_arc_radius: float = sprocket_radius * 1.05
	var radius_scale_val: float = tread_arc_radius / 0.45
	var width_scale_val: float = sprocket_scale * width

	var loop: MeshInstance3D
	if loop_mesh:
		var deformed_loop_mesh = _deform_tread_loop_mesh(loop_mesh, front_z, rear_z, radius_scale_val, width_scale_val, belt_scale)
		loop = _mesh_inst(deformed_loop_mesh, base_color)
	else:
		loop = MeshInstance3D.new()
		var loop_box = BoxMesh.new()
		loop_box.size = Vector3(actual_size.x * width, actual_size.y, actual_size.z)
		loop.mesh = loop_box
	loop.name = BELT_BAND_NAME
	loop.material_override = _belt_material(base_color)
	loop.position = Vector3(belt_center_x, loop_center_y, 0)
	parent_node.add_child(loop)

	# Helper to build an armored gearbox and MountReach-verified driveshaft.
	# Checks for actual hull intersection before finalizing - never spawns floating shafts.
	var _add_track_mount = func(axle_y: float, z_pos: float, r: float, is_sprocket: bool = false):
		var station := MountReachScript.station_from(tweaks)
		var node_scale := MountReachScript.node_scale_from(tweaks)
		var shaft_angle := deg_to_rad(40.0)
		var bottom_target := Vector3.ZERO
		var shaft_thickness := 0.0

		if is_sprocket:
			var sp_inboard_x: float = outboard_x - sprocket_width_authored * sprocket_scale * width
			var trap_mesh := _make_trapezoid_gearbox_mesh(r)
			var trap_inst := _mesh_inst(trap_mesh, base_color.darkened(0.15).lightened(0.25))
			trap_inst.position = Vector3(sp_inboard_x, axle_y, z_pos)
			parent_node.add_child(trap_inst)

			var w: float = r * 1.05
			# If the trapezoidal gearbox already touches or intersects the hull skin,
			# no driveshaft extension is needed.
			var trap_reach := MountReachScript.solve(parent_node, station, Vector3(sp_inboard_x, axle_y, z_pos), Vector3.LEFT, -1.0, node_scale, 0.0)
			if trap_reach > 0.0 and trap_reach <= w + 0.05:
				return

			bottom_target = Vector3(sp_inboard_x - w, axle_y, z_pos)
			shaft_thickness = r * 0.70
		else:
			if gearbox_mesh:
				var gb_size: float = r * 1.25
				var gearbox := _mesh_inst(gearbox_mesh, base_color.darkened(0.15).lightened(0.25))
				gearbox.scale = Vector3(gb_size, gb_size, gb_size)
				gearbox.position = Vector3(outboard_x - r * 0.50, axle_y, z_pos)
				parent_node.add_child(gearbox)

			bottom_target = Vector3(outboard_x - r * 0.40, axle_y + r * 0.35, z_pos)
			shaft_thickness = r * 0.80

		if driveshaft_mesh:
			var candidate_dirs: Array[Vector3] = []
			var z_bias := 0.0
			if is_sprocket:
				z_bias = 0.60 if z_pos < 0.0 else -0.60
			elif absf(z_pos) > 0.1:
				z_bias = -signf(z_pos) * 0.35

			var elev_angles := [35.0, 45.0, 25.0, 55.0, 15.0, 0.0, -15.0, -25.0]
			var z_offsets := [z_bias, z_bias * 1.4, z_bias * 0.6, 0.0, -z_bias * 0.5]
			for el in elev_angles:
				var r_el := deg_to_rad(el)
				for zo in z_offsets:
					var v := Vector3(-cos(r_el), sin(r_el), zo).normalized()
					if not candidate_dirs.has(v):
						candidate_dirs.append(v)

			var solved_dir := Vector3.ZERO
			var solved_len := -1.0
			for c_dir in candidate_dirs:
				var l := MountReachScript.solve(parent_node, station, bottom_target, c_dir, -1.0, node_scale)
				if l > 0.0:
					solved_dir = c_dir
					solved_len = l
					break

			# ONLY spawn the driveshaft if it genuinely intersects the hull skin!
			if solved_len > 0.0:
				var shaft := _mesh_inst(driveshaft_mesh, base_color.darkened(0.3).lightened(0.3))
				var top_pos := bottom_target + solved_dir * solved_len
				var up_vec := solved_dir
				var side_vec := up_vec.cross(Vector3.FORWARD).normalized()
				if side_vec.length_squared() < 0.001:
					side_vec = Vector3.RIGHT
				var fwd_vec := side_vec.cross(up_vec).normalized()
				shaft.transform = Transform3D(
					Basis(side_vec * shaft_thickness, up_vec * solved_len, fwd_vec * shaft_thickness),
					top_pos
				)
				parent_node.add_child(shaft)

	# Sprockets at the true forward/rear corners, at the loop's wrap height
	if sprocket and sprocket_mesh:
		var sp_front_axle = Node3D.new()
		sp_front_axle.name = SPIN_PIVOT_TREAD
		sp_front_axle.set_meta("spin_radius", sprocket_radius)
		sp_front_axle.position = Vector3(outboard_x, loop_center_y, front_z)
		parent_node.add_child(sp_front_axle)
		var sp_front = _mesh_inst(sprocket_mesh, Color(0.18, 0.18, 0.2))
		sp_front.scale = Vector3(sprocket_scale, sprocket_scale, sprocket_scale)
		sp_front.rotation = Vector3(0, 0, PI / 2.0)
		sp_front_axle.add_child(sp_front)
		_add_track_mount.call(loop_center_y, front_z, sprocket_radius, true)

		var sp_rear_axle = Node3D.new()
		sp_rear_axle.name = SPIN_PIVOT_TREAD
		sp_rear_axle.set_meta("spin_radius", sprocket_radius)
		sp_rear_axle.position = Vector3(outboard_x, loop_center_y, rear_z)
		parent_node.add_child(sp_rear_axle)
		var sp_rear = _mesh_inst(sprocket_mesh, Color(0.18, 0.18, 0.2))
		sp_rear.scale = Vector3(sprocket_scale, sprocket_scale, sprocket_scale)
		sp_rear.rotation = Vector3(0, 0, PI / 2.0)
		sp_rear_axle.add_child(sp_rear)
		_add_track_mount.call(loop_center_y, rear_z, sprocket_radius, true)

	# Road wheels: clustered along the lower run strictly between sprockets
	var wheel_span: float = span * 0.58
	var wheel_radius_target: float = BELT_ROAD_RADIUS * belt_scale
	var wheel_scale: float = wheel_radius_target / 0.45
	var spacing: float = wheel_span / float(max(1, road_wheels - 1)) if road_wheels > 1 else target_radius
	var roller_y: float = loop_center_y - BELT_ROAD_DROP * belt_scale

	_repeat_along_axis(parent_node, road_wheels, spacing, Vector3.FORWARD, func(p, pos, _idx):
		var roller: MeshInstance3D
		if wheel_mesh:
			roller = _mesh_inst(wheel_mesh, Color.DARK_SLATE_GRAY)
			roller.scale = Vector3(wheel_scale, wheel_scale, wheel_scale)
		else:
			roller = MeshInstance3D.new()
			var cyl = CylinderMesh.new()
			cyl.top_radius = wheel_radius_target
			cyl.bottom_radius = wheel_radius_target
			cyl.height = actual_size.x * 1.05
			roller.mesh = cyl
			var mat = StandardMaterial3D.new()
			mat.albedo_color = Color.DARK_SLATE_GRAY
			roller.material_override = mat
		# Road wheels spin with the belt, same as the sprockets.
		var roller_axle = Node3D.new()
		roller_axle.name = SPIN_PIVOT_TREAD
		roller_axle.set_meta("spin_radius", wheel_radius_target)
		roller_axle.position = Vector3(outboard_x, roller_y, pos.z)
		p.add_child(roller_axle)
		roller.rotation = Vector3(0, 0, PI / 2.0)
		roller_axle.add_child(roller)

		_add_track_mount.call(roller_y, pos.z, wheel_radius_target, false)
	)


static func _build_helicopter_rotors(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DARK_GRAY, tweaks: Dictionary = {}):
	# NO MOUNT KIT. Chris: "what are those things dangling beneath each
	# nacelle?" - that was the kit's mk_pylon_collar, sitting at a FIXED
	# -0.92 below the module. That offset is the far end of the kit's own
	# stub pylon, which assumes the module is bolted straight onto the hull.
	# A rotor is not: module_placer.gd hangs it 1.2 outboard and 0.3 above the
	# hull top, and this function then solves a real strut down to the hull's
	# centre. So the kit was a second, shorter, unsolved pylon ending in a
	# collar clamped around nothing. The solved strut below is the mounting.
	var blade_count = int(tweaks.get("blade_count", 4.0))
	var blade_length = tweaks.get("blade_length", tweaks.get("size", 1.0))
	var duct = tweaks.get("duct", false)

	var mast_mesh = _part("rotor_mast")
	var hub_mesh = _part("rotor_hub")
	var blade_mesh = _part("rotor_blade")
	var duct_mesh = _part("rotor_duct_ring")
	var strut_mesh = _part("mount_strut_tapered")
	var mount_mesh = _part("rg_mount_box")

	var mount_side = float(tweaks.get("mount_side", 1.0))
	var station := MountReachScript.station_from(tweaks)
	var surface := MountReachScript.surface_for(parent_node)

	# Direct vector towards the hull flank in 3D:
	# Inward in X, angled slightly down in Y, and slight inward pull in Z
	var z_pull: float = -signf(station.z) * 0.12 if absf(station.z) > 0.1 else 0.0
	var dir_to_hull := Vector3(-mount_side, -0.38, z_pull).normalized()

	var span_vec := dir_to_hull * 1.5
	var hull_normal := -dir_to_hull

	if not surface.is_empty():
		var hit: Dictionary = HullProjectionScript.raycast(surface, station, dir_to_hull)
		if hit.get("hit", false):
			span_vec = hit["position"] - station
			hull_normal = hit["normal"]
		else:
			for pitch_deg in [-10.0, 10.0, -20.0, 20.0, -35.0, 35.0]:
				var found_hit := false
				for yaw_deg in [-15.0, 15.0]:
					var test_dir := dir_to_hull.rotated(Vector3.UP, deg_to_rad(yaw_deg))
					var test_axis := Vector3.UP.cross(test_dir).normalized()
					test_dir = test_dir.rotated(test_axis, deg_to_rad(pitch_deg))
					var hit2: Dictionary = HullProjectionScript.raycast(surface, station, test_dir)
					if hit2.get("hit", false):
						span_vec = hit2["position"] - station
						hull_normal = hit2["normal"]
						found_hit = true
						break
				if found_hit:
					break

	var span_len: float = span_vec.length()
	var spar_reach: float = span_len + 0.08

	# Main structural spar pointing directly at the hull contact point
	var arm := Node3D.new()
	arm.name = "RotorBoom"
	parent_node.add_child(arm)

	# Align arm's local +Y with span_vec
	var y_axis := span_vec.normalized()
	var z_axis := y_axis.cross(Vector3.UP)
	if z_axis.length_squared() < 0.001:
		z_axis = y_axis.cross(Vector3.FORWARD)
	z_axis = z_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	arm.transform.basis = Basis(x_axis, y_axis, z_axis)

	if strut_mesh:
		var strut = _mesh_inst(strut_mesh, base_color.darkened(0.3))
		strut.scale = Vector3(0.38, spar_reach, 0.28)
		strut.position = Vector3.ZERO
		arm.add_child(strut)

		# Second bracing strut forming a rigid triangular outrigger
		var brace_orig := Vector3(0, -0.22, 0)
		var brace_target := span_vec + Vector3(0, -0.32, 0)
		var brace_vec := brace_target - brace_orig
		var brace_len := brace_vec.length() + 0.08
		
		var brace_arm := Node3D.new()
		brace_arm.name = "RotorBrace"
		brace_arm.position = brace_orig
		var b_y := brace_vec.normalized()
		var b_z := b_y.cross(Vector3.UP)
		if b_z.length_squared() < 0.001:
			b_z = b_y.cross(Vector3.FORWARD)
		b_z = b_z.normalized()
		var b_x := b_y.cross(b_z).normalized()
		brace_arm.transform.basis = Basis(b_x, b_y, b_z)
		
		var brace = _mesh_inst(strut_mesh, base_color.darkened(0.35))
		brace.scale = Vector3(0.24, brace_len, 0.18)
		brace.position = Vector3.ZERO
		brace_arm.add_child(brace)
		parent_node.add_child(brace_arm)

		# Heavy hull mounting flange bracket at the contact point, flush against the hull skin
		var bracket := BoxMesh.new()
		bracket.size = Vector3(0.38, 0.58, 0.14)
		var bracket_inst := _mesh_inst(bracket, base_color.darkened(0.45).lightened(0.1))
		bracket_inst.position = span_vec + Vector3(0, -0.16, 0)
		if absf(hull_normal.dot(Vector3.UP)) < 0.95:
			var b_forward := -hull_normal.normalized()
			var b_right := b_forward.cross(Vector3.UP).normalized()
			var b_up := b_right.cross(b_forward).normalized()
			bracket_inst.transform.basis = Basis(b_right, b_up, -b_forward)
		parent_node.add_child(bracket_inst)
	elif mount_mesh:
		var strut = _mesh_inst(mount_mesh, base_color.darkened(0.3))
		strut.scale = Vector3(0.3, spar_reach / 0.4, 0.3)
		strut.position = Vector3(0, spar_reach * 0.5, 0)
		arm.add_child(strut)

	# --- VERTICAL TURBOSHAFT ENGINE NACELLE POD ---
	# Bulky aerodynamic nacelle housing bridging the upper boom and lower brace
	# into a unified mechanical power unit under the rotor mast.
	var nacelle := Node3D.new()
	nacelle.name = "EngineNacelle"
	parent_node.add_child(nacelle)

	# 1. Main Nacelle Body Block
	var nac_body := BoxMesh.new()
	nac_body.size = Vector3(0.30, 0.48, 0.38)
	var nac_inst := _mesh_inst(nac_body, base_color.darkened(0.22))
	nac_inst.position = Vector3(0, -0.14, 0)
	nacelle.add_child(nac_inst)

	# 2. Upper Gearbox Transmission Collar surrounding the mast root
	var gb_collar := CylinderMesh.new()
	gb_collar.top_radius = 0.14
	gb_collar.bottom_radius = 0.17
	gb_collar.height = 0.12
	var collar_inst := _mesh_inst(gb_collar, Color(0.20, 0.22, 0.24))
	collar_inst.position = Vector3(0, 0.10, 0)
	nacelle.add_child(collar_inst)

	# 3. Lower Sump Housing / Maintenance Cap
	var sump := CylinderMesh.new()
	sump.top_radius = 0.14
	sump.bottom_radius = 0.10
	sump.height = 0.10
	var sump_inst := _mesh_inst(sump, Color(0.18, 0.19, 0.21))
	sump_inst.position = Vector3(0, -0.38, 0)
	nacelle.add_child(sump_inst)

	# 4. Front Aerodynamic Intake Scoop
	var intake := BoxMesh.new()
	intake.size = Vector3(0.22, 0.26, 0.14)
	var intake_inst := _mesh_inst(intake, Color(0.16, 0.17, 0.19))
	intake_inst.position = Vector3(0, -0.12, -0.22)
	nacelle.add_child(intake_inst)

	# 5. Rear Turboshaft Exhaust Shroud
	var exhaust := CylinderMesh.new()
	exhaust.top_radius = 0.07
	exhaust.bottom_radius = 0.09
	exhaust.height = 0.12
	var ex_inst := _mesh_inst(exhaust, Color(0.25, 0.26, 0.28))
	ex_inst.rotation = Vector3(deg_to_rad(-45.0), 0, 0)
	ex_inst.position = Vector3(0, -0.22, 0.22)
	nacelle.add_child(ex_inst)

	var shaft_h = base_size.y * 0.8
	if mast_mesh:
		var mast = _mesh_inst(mast_mesh, Color.DARK_GRAY)
		mast.scale = Vector3(1.0, shaft_h / 0.6, 1.0)
		mast.position = Vector3(0, 0, 0)
		parent_node.add_child(mast)
	else:
		var shaft = MeshInstance3D.new()
		var shaft_cyl = CylinderMesh.new()
		shaft_cyl.top_radius = 0.05
		shaft_cyl.bottom_radius = 0.05
		shaft_cyl.height = shaft_h
		shaft.mesh = shaft_cyl
		var shaft_mat = StandardMaterial3D.new()
		shaft_mat.albedo_color = Color.DARK_GRAY
		shaft.material_override = shaft_mat
		shaft.position = Vector3(0, shaft_h / 2.0, 0)
		parent_node.add_child(shaft)

	if hub_mesh:
		var hub = _mesh_inst(hub_mesh, Color(0.2, 0.2, 0.22))
		hub.position = Vector3(0, shaft_h, 0)
		parent_node.add_child(hub)

	var pivot = Node3D.new()
	pivot.name = PIVOT_ROTOR_BLADES
	pivot.position = Vector3(0, shaft_h + 0.05, 0)
	parent_node.add_child(pivot)

	_ring_of(pivot, blade_count, 0.0, func(p, _pos, angle, _idx):
		var blade: MeshInstance3D
		if blade_mesh:
			blade = _mesh_inst(blade_mesh, Color(0.1, 0.1, 0.1))
			# SPANWISE IS Z. Chris: "the rotor size tweak doesn't change the
			# blades lengths." It was scaling X, but the re-authored
			# rotor_blade mesh runs 1.2 along Z and 0.16 along X - measured,
			# so the slider was fattening the blade by a hair instead of
			# lengthening it. The old flat-plank blade this replaced was
			# authored along X; the axis moved in the rework and this call
			# site did not follow it. Z is the span, scaled by blade_length.
			blade.scale = Vector3(1.0, 1.0, blade_length)
			blade.rotation.y = angle
		else:
			blade = MeshInstance3D.new()
			var b_box = BoxMesh.new()
			b_box.size = Vector3(0.1, 0.03, base_size.x * blade_length)
			blade.mesh = b_box
			var b_mat = StandardMaterial3D.new()
			b_mat.albedo_color = Color(0.1, 0.1, 0.1)
			blade.material_override = b_mat
			blade.position = Vector3(0, 0, base_size.x * blade_length * 0.5)
			blade.rotation.y = angle
		p.add_child(blade)
	)

	if duct and duct_mesh:
		var shroud = _mesh_inst(duct_mesh, base_color.darkened(0.2))
		shroud.scale = Vector3(blade_length, 1.0, blade_length)
		shroud.position = Vector3(0, shaft_h, 0)
		parent_node.add_child(shroud)


static func _build_hover_engine(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DEEP_SKY_BLUE, tweaks: Dictionary = {}):
	var emv: float = float(tweaks.get("emv_level", 1.0))
	var ring_mesh := _part("hover_ring")
	var struct_color := Color(0.28, 0.30, 0.33).lerp(base_color, 0.08)

	var authored_diameter := 1.0
	const HEAD_SCALE := 2.1
	var ring_scale: float = (base_size.x / authored_diameter) * HEAD_SCALE
	var ring_radii := [1.0, 0.65, 0.35]
	var ring_names := [HOVER_RING_OUTER, HOVER_RING_MID, HOVER_RING_INNER]
	var ring_y: float = base_size.y * 0.5

	# 1. Concentric Hover Rings
	for idx in range(3):
		var ring: MeshInstance3D
		if ring_mesh:
			if idx == 2:
				ring = _mesh_inst(ring_mesh, Color(0.26, 0.30, 0.34),
					Color(0.35, 0.72, 1.0), 0.55)
			else:
				ring = _mesh_inst(ring_mesh, Color(0.30, 0.32, 0.35))
			ring.scale = Vector3(ring_scale * ring_radii[idx], emv, ring_scale * ring_radii[idx])
		else:
			ring = MeshInstance3D.new()
			var torus = TorusMesh.new()
			torus.outer_radius = ring_scale * ring_radii[idx] * 0.5
			torus.inner_radius = torus.outer_radius * 0.8
			ring.mesh = torus
			var mat = StandardMaterial3D.new()
			mat.albedo_color = base_color
			mat.emission_enabled = (idx == 2)
			mat.emission = Color(0.35, 0.72, 1.0)
			ring.material_override = mat
			ring.scale = Vector3(1.0, emv, 1.0)
		ring.name = ring_names[idx]
		ring.position = Vector3(0, ring_y, 0)
		parent_node.add_child(ring)

	# 2. Central Gimbal Hub
	var hub_mesh := _part("wheel_gearbox")
	if hub_mesh:
		var hub := _mesh_inst(hub_mesh, struct_color)
		var hub_s: float = 0.32 * ring_scale
		hub.scale = Vector3(hub_s, hub_s * 0.5, hub_s)
		hub.position = Vector3(0, ring_y, 0)
		parent_node.add_child(hub)

	# 3. Radial Outrigger Pylon / Mounting Arm spanning from pad hub to hull contact point
	var pad_radius: float = ring_scale * 0.5
	var anchor := Vector3(
		float(tweaks.get("kit_anchor_x", tweaks.get("mount_reach_x", 0.0))),
		float(tweaks.get("kit_anchor_y", tweaks.get("mount_reach_y", 0.0))),
		float(tweaks.get("kit_anchor_z", tweaks.get("mount_reach_z", 0.0)))
	)
	var station := MountReachScript.station_from(tweaks)
	var surface := MountReachScript.surface_for(parent_node)
	
	var dir_to_hull := anchor.normalized() if anchor.length_squared() > 0.001 else (-station).normalized()
	var span_vec := dir_to_hull * (anchor.length() if anchor.length() > 0.05 else pad_radius)
	var hull_normal := -dir_to_hull

	if not surface.is_empty():
		var eff_station := station + Vector3(0, ring_y, 0)
		var hit: Dictionary = HullProjectionScript.raycast(surface, eff_station, dir_to_hull)
		if hit.get("hit", false):
			span_vec = hit["position"] - eff_station
			hull_normal = hit["normal"]
		else:
			for pitch_deg in [-10.0, 10.0, -20.0, 20.0, -35.0, 35.0]:
				var test_axis := Vector3.UP.cross(dir_to_hull)
				if test_axis.length_squared() > 0.001:
					test_axis = test_axis.normalized()
					var test_dir := dir_to_hull.rotated(test_axis, deg_to_rad(pitch_deg))
					var hit2: Dictionary = HullProjectionScript.raycast(surface, eff_station, test_dir)
					if hit2.get("hit", false):
						span_vec = hit2["position"] - eff_station
						hull_normal = hit2["normal"]
						break

	var span_len: float = span_vec.length()
	if span_len > 0.05:
		var arm := Node3D.new()
		arm.name = "MountArm"
		parent_node.add_child(arm)
		
		# Look towards span vector
		arm.look_at_from_position(Vector3(0, ring_y, 0), Vector3(0, ring_y, 0) + span_vec, Vector3.UP)

		var beam_thick: float = 0.22
		var beam_reach: float = span_len + 0.08
		var beam := BoxMesh.new()
		beam.size = Vector3(beam_thick * 1.4, beam_thick * 1.1, 1.0)
		var beam_inst := _mesh_inst(beam, struct_color)
		beam_inst.position = Vector3(0, 0, -beam_reach * 0.5)
		beam_inst.scale = Vector3(1, 1, beam_reach)
		arm.add_child(beam_inst)

		# Diagonal upper reinforcement gusset
		var diag_strut := BoxMesh.new()
		diag_strut.size = Vector3(beam_thick * 1.0, beam_thick * 0.7, 1.0)
		var diag_inst := _mesh_inst(diag_strut, struct_color.darkened(0.1))
		diag_inst.position = Vector3(0, beam_thick * 0.45, -beam_reach * 0.5)
		diag_inst.scale = Vector3(1, 1, beam_reach * 0.9)
		diag_inst.rotation = Vector3(deg_to_rad(-8.0), 0, 0)
		arm.add_child(diag_inst)

		# Heavy structural hull mounting flange bracket placed directly on hull contact point
		# and oriented FLUSH and ALIGNED with the hull face normal!
		var bracket := BoxMesh.new()
		bracket.size = Vector3(beam_thick * 2.4, beam_thick * 2.2, beam_thick * 0.8)
		var bracket_inst := _mesh_inst(bracket, struct_color.darkened(0.25).lightened(0.2))
		bracket_inst.position = Vector3(span_vec.x, ring_y + span_vec.y, span_vec.z)
		
		# Align bracket basis flush with hull normal
		var b_norm := hull_normal.normalized()
		if absf(b_norm.dot(Vector3.UP)) < 0.95:
			var b_forward := -b_norm
			var b_right := b_forward.cross(Vector3.UP).normalized()
			var b_up := b_right.cross(b_forward).normalized()
			bracket_inst.transform.basis = Basis(b_right, b_up, -b_forward)
		parent_node.add_child(bracket_inst)


static func _build_legs(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.GRAY, tweaks: Dictionary = {}):
	# AUTHORED, not procedural. This used to assemble a limb from four
	# primitives (leg_thigh/leg_shin/leg_foot/leg_joint), solving a femur and a
	# tibia as two spans between computed points, with the WHEELS' own
	# build_wheel_mount() borrowed as a hip. It is now one of six authored sets
	# under assets/models/parts/leg_<id>.glb, picked by the "leg_type" tweak the
	# same way a weapon picks its ammo - see ModuleCatalog.LEG_TYPES.
	#
	# Each set is a real three-segment chain:
	#
	#   Bone_Part1_HipMount  >  Bone_Part2_Thigh  >  Bone_Part3_ShinFoot
	#
	# with a mesh hanging off each bone and no baked animation, so the walk
	# cycle stays code-driven - see pose_leg() below, which is what the three
	# animator call sites share.
	var leg_length: float = float(tweaks.get("leg_length", tweaks.get("size", 1.0)))
	var leg_width: float = float(tweaks.get("leg_width", 1.0))
	var foot_size: float = float(tweaks.get("foot_size", 1.0))

	# Runtime load, not a preload: module_catalog.gd sits upstream of this file
	# in the preload graph, so a preload here would close a cycle. Same reason
	# mesh_asset_loader.gd resolves it this way.
	var ModuleCatalogScript = load("res://scripts/module_catalog.gd")
	var leg_id: String = ModuleCatalogScript.get_leg_type(tweaks)
	var profile: Dictionary = ModuleCatalogScript.get_leg_profile(leg_id)
	var is_flank: bool = str(profile.get("mount", "underside")) == "flank"

	# RIDE HEIGHT, unchanged from the procedural build. The old code put the
	# sole at exactly -1.35 * leg_length below the module origin (hip_y cancels
	# out of its own foot_y maths), and every ride-height suite plus the golden
	# layout fixture is calibrated to that. Keeping the target and solving the
	# model's SCALE from it - rather than scaling the model by some nominal
	# factor and letting the sole land where it lands - is what makes all six
	# sets stand the hull at the same height despite spanning 2.50 to 3.85
	# units of authored drop.
	#
	# mount_rise is how far above the hull's underside the layout put this
	# station - zero for a belly mount, a third of the hull's height for a
	# shouldered one. Added rather than ignored so a flank-mounted set reaches
	# the same ground plane instead of leaving the vehicle standing taller on
	# Mantis than on Stryker.
	var target_drop: float = LEG_DROP_PER_LENGTH * leg_length + float(tweaks.get("mount_rise", 0.0))

	# NO MOUNTING PLATE. There was one - a bolted steel slab standing in for the
	# hardpoint - and it is gone at Chris's request: the legs "just mount
	# directly to the VISIBLE hull mesh" instead. The seating is done by
	# module_placer.gd's _seat_legs_on_hull_skin(), which raycasts the hull's
	# real triangles and puts the module's origin on the skin, so the gearbox
	# meets the hull wherever the hull actually IS rather than wherever its
	# bounding box says it is.
	#
	# That is why nothing here offsets the limb any more: the module origin iss
	# already on the surface by the time this geometry is seen.

	# LegRoot / LegSwing, both preserved verbatim from the procedural build.
	#
	# module_placer.gd's _apply_mirror_flip() reflects every DIRECT child of the
	# leg module once at placement time by rewriting its whole Transform3D;
	# Godot then decomposes that reflected Transform3D back into
	# .rotation/.scale, and for a pure X-mirror it is free to pick EITHER
	# (rotation=0, scale=(-1,1,1)) OR (rotation=(PI,0,0), scale=(-1,-1,-1)) -
	# both represent the identical transform, but Godot actually picks the
	# second one here. Writing the swing angle onto that SAME node means
	# overwriting the baked-in PI (the mirror's own encoding) instead of adding
	# to it, which destroys the mirror and renders the leg inside-out ("upside
	# down", Chris's report).
	#
	# So: LegRoot carries the mirror and is never touched again after placement;
	# the animation rotates the NESTED LegSwing, which is always freshly created
	# at identity and is never mirrored itself (mirror-flip only walks
	# parent_node's DIRECT children) - it just inherits LegRoot's already-correct
	# mirrored frame the way any child node does.
	#
	# This is a real, reproduced Godot behaviour, not a defensive guess. Do not
	# collapse these two nodes into one.
	var leg_root := Node3D.new()
	leg_root.name = "LegRoot"
	# At the module origin, which _seat_legs_on_hull_skin() has already placed on
	# the hull's visible surface.
	leg_root.position = Vector3.ZERO
	parent_node.add_child(leg_root)

	var swing := Node3D.new()
	swing.name = LEG_PIVOT_SWING
	swing.position = Vector3.ZERO
	leg_root.add_child(swing)

	var scene: PackedScene = MeshAssetLoader.get_part_scene(
		ModuleCatalogScript.get_leg_part_name(leg_id))
	if scene == null:
		# No authored asset - leave the platform and the pivots in place rather
		# than half-building a limb. The pivots existing keeps the animator's
		# by-name lookups safe, and the module still has a visible hardpoint.
		push_warning("VisualBuilder: no authored mesh for leg set '%s'" % leg_id)
		return

	var limb: Node3D = scene.instantiate()
	# Y is solved to land the sole on the ground; X and Z carry the girth on top
	# of that. Not uniform, deliberately: a uniform scale cannot express "thicker
	# but the same height", and the height is spoken for by the ride-height
	# solve. LEG_GIRTH is the baseline chunkiness; leg_width is the player's
	# multiplier on it.
	var authored_drop: float = maxf(float(profile.get("drop", 1.0)), 0.001)
	var fit: float = maxf(target_drop, 0.01) / authored_drop
	var girth: float = fit * LEG_GIRTH * leg_width
	limb.scale = Vector3(girth, fit, girth)
	swing.add_child(limb)

	# CamTarget is an authoring aid (a framing helper for the model's own turntable
	# renders), not part of the limb. Dropped rather than left as an invisible
	# empty, so the node count per leg reflects what is actually rendered.
	for child in limb.get_children():
		if child.name == "CamTarget":
			child.queue_free()

	_apply_authored_leg_materials(limb, base_color)

	# EVERY animated bone records its rest rotation. pose_leg() assigns
	# rotation.x outright each frame, so a bone with no recorded rest would be
	# snapped to zero on the first animated frame - wiping the pose the artist
	# built into the .glb and making the limb look like it collapsed the instant
	# the machine started walking.
	var thigh: Node3D = find_leg_bone(limb, LEG_PIVOT_THIGH)
	var shin: Node3D = find_leg_bone(limb, LEG_PIVOT_SHIN)
	if thigh:
		thigh.set_meta(LEG_REST_META, thigh.rotation.x)
	if shin:
		shin.set_meta(LEG_REST_META, shin.rotation.x)
		# foot_size scales the shin/foot segment alone, so a wider pad reads as
		# the same leg wearing a bigger boot rather than as a bigger leg.
		if not is_equal_approx(foot_size, 1.0):
			shin.scale = Vector3.ONE * foot_size


## Repaints an instantiated leg's surfaces through the shared role materials.
##
## The .glb ships named materials (Gunmetal, CarbonBlack, IndustrialYellow, ...)
## and they are deliberately NOT kept: every other part in the game resolves to
## one of part_materials.gd's cached role materials, which is what makes faction
## tint reach the right surfaces and lets the battle-side mesh merge collapse
## them. Keeping the authored materials would have cost both.
##
## The authored NAME is still doing the work though - it is the artist saying
## which surface is which substance, which is exactly the question ROLE_HINTS
## answers from a filename for single-material parts.
static func _apply_authored_leg_materials(node: Node, base_color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh: Mesh = mi.mesh
		if mesh != null:
			for i in range(mesh.get_surface_count()):
				var authored: Material = mesh.surface_get_material(i)
				var mat_name: String = authored.resource_name if authored else ""
				var role: String = PartMaterialsScript.role_for_authored_material(mat_name)
				mi.set_surface_override_material(i,
					PartMaterialsScript.get_material(role, base_color))
	for child in node.get_children():
		_apply_authored_leg_materials(child, base_color)


## Finds one of the leg's authored bones beneath an instantiated set.
##
## By name and recursive, because the .glb wraps its chain in a per-set rig node
## ("Apex_Rig", "Mantis_Rig", ...) whose name differs per set - so a fixed path
## would need six of them. The BONE names are identical across all six, which is
## the contract that makes one animation path work for every set.
static func find_leg_bone(root: Node, bone_name: String) -> Node3D:
	if root == null:
		return null
	if root.name == bone_name and root is Node3D:
		return root as Node3D
	for child in root.get_children():
		var found := find_leg_bone(child, bone_name)
		if found != null:
			return found
	return null


## Poses one leg for a walk cycle. THE single implementation - unit.gd,
## battlefield.gd and the battle layer's unit script all call this.
##
## One copy rather than three because three copies is exactly how the Test
## Range's rotors ended up spinning the wrong node for months (see the comment
## in battlefield.gd's _physics_process): the pivot lookup drifted in one file
## and nothing failed.
##
## `phase` is the per-leg walk offset locomotion_layout.gd already assigns so
## adjacent legs step out of sync; `t` is elapsed seconds; `moving` parks the
## limb in its rest pose when the machine is stationary.
##
## The three bones are driven against each other rather than in parallel: the
## hip swings fore-aft, the thigh lifts as the hip comes forward, and the shin
## counter-rotates so the sole stays roughly level through the stance instead of
## sweeping through the ground like a pendulum. That counter-rotation is the
## whole reason these sets are worth having over a single rigid pivot.
const LEG_STRIDE := 0.42
const LEG_LIFT := 0.30
const LEG_TUCK := 0.55
const LEG_GAIT_RATE := 6.0

## `rate` is how fast the machine is actually moving, 0..1 - the same
## ground_rate the wheel and tread spins are already driven by. At or below
## MOVING_EPSILON the limb settles into its rest pose instead of holding a
## mid-stride freeze, which is what a parked walker should do.
const LEG_MOVING_EPSILON := 0.04
const LEG_SETTLE_RATE := 8.0

static func pose_leg(leg_module: Node3D, t: float, phase: float, rate: float,
		delta: float = 0.0) -> void:
	if not is_instance_valid(leg_module):
		return
	var swing := leg_module.get_node_or_null("LegRoot/%s" % LEG_PIVOT_SWING) as Node3D
	if swing == null:
		return

	if rate <= LEG_MOVING_EPSILON:
		# Settle, don't snap: stopping should read as the machine coming to
		# rest, not as the animation being switched off. Frame-rate independent
		# when a delta is supplied; the 0.15 fallback keeps a headless test that
		# calls this without one behaving sensibly.
		var w: float = clampf(LEG_SETTLE_RATE * delta, 0.0, 1.0) if delta > 0.0 else 0.15
		swing.rotation.x = lerpf(swing.rotation.x, 0.0, w)
		_pose_leg_bones(swing, 0.0, w)
		return

	# Gait speeds up with the machine, with a floor so a unit crawling under an
	# overload penalty still visibly walks rather than sliding along.
	var cycle: float = t * LEG_GAIT_RATE * maxf(rate, 0.35) + phase
	swing.rotation.x = sin(cycle) * LEG_STRIDE
	_pose_leg_bones(swing, cycle, 1.0)


static func _pose_leg_bones(swing: Node3D, cycle: float, weight: float) -> void:
	var limb: Node3D = null
	for child in swing.get_children():
		if child is Node3D:
			limb = child
			break
	if limb == null:
		return

	# The lift half-cycle only: a leg rises on the forward swing and stays
	# planted on the way back, which is what separates a walk from a paddle.
	var lift: float = maxf(sin(cycle), 0.0)

	var thigh := find_leg_bone(limb, LEG_PIVOT_THIGH)
	if thigh:
		# Added to the bone's authored rest pose, never replacing it - see
		# LEG_REST_META.
		var rest: float = float(thigh.get_meta(LEG_REST_META, 0.0))
		thigh.rotation.x = lerpf(thigh.rotation.x, rest - lift * LEG_LIFT, weight)
	var shin := find_leg_bone(limb, LEG_PIVOT_SHIN)
	if shin:
		# Counter-rotation, and MORE of it than the thigh gave - the knee has to
		# fold further than the hip opens for the foot to clear the ground
		# rather than being dragged forward through it.
		var shin_rest: float = float(shin.get_meta(LEG_REST_META, 0.0))
		shin.rotation.x = lerpf(shin.rotation.x, shin_rest + lift * LEG_TUCK, weight)



static func _gather_hull_only_surface(chassis_node: Node3D) -> Dictionary:
	var tris := PackedVector3Array()
	var aabb := AABB()
	var first := true
	if not is_instance_valid(chassis_node):
		return {"tris": tris, "aabb": aabb}

	var hull_mi: MeshInstance3D = null
	if chassis_node.has_node("MeshInstance3D") and chassis_node.get_node("MeshInstance3D") is MeshInstance3D:
		hull_mi = chassis_node.get_node("MeshInstance3D") as MeshInstance3D
	else:
		for child in chassis_node.get_children():
			if child is MeshInstance3D and not child.has_meta("module_data") and child.visible and not child.name.contains("Ground") and not child.name.contains("Greeble") and not child.name.contains("Shield") and not child.name.contains("AGP"):
				hull_mi = child as MeshInstance3D
				break

	if hull_mi != null and hull_mi.mesh != null:
		var xform := hull_mi.transform
		var faces := hull_mi.mesh.get_faces()
		for v in faces:
			var world_v := xform * v
			tris.append(world_v)
			if first:
				aabb = AABB(world_v, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(world_v)

	return {"tris": tris, "aabb": aabb, "hull_mi": hull_mi}


static func _build_ornithopter_wing(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.BROWN, tweaks: Dictionary = {}):
	# Dragonfly-style rebuild (Chris's ask, 2026-07-24): TWO independent
	# wing pairs per mount node (fore + hind, like a dragonfly's wing
	# root) instead of one wing on one pivot, each on its own named pivot
	# ("WingPivotFore"/"WingPivotHind") so unit.gd can flap them in
	# opposition to each other - real dragonflies beat their fore and hind
	# wing pairs roughly 180 degrees out of phase. The wings themselves are
	# also now authored substantially longer and narrower (see
	# build_wing_membrane's rebuilt defaults in build_meshes.py) - a real
	# slender dragonfly silhouette, not the old short stubby panel.
	#
	# wing_sweep was declared in TWEAK_SPECS but never read anywhere -
	# wired in here now (scales the same leading-edge sweep angle the old
	# single wing used a fixed 12deg for).
	# ABSURD BY DESIGN (Chris, 2026-08-02): "they're kind of an absurd choice
	# and they need to feel like it. Impractically long, a bulky attachment
	# that takes up most of the hull's roofspace with gearboxes and struts."
	# So the span grows and, more importantly, the machinery that drives it
	# stops being a single palm-sized shoulder block and becomes a flapping
	# rig bolted across the whole roof - which is also what fixes the "not
	# attached" half of the report, since there is now real structure between
	# the wing root and the vehicle.
	var wingspan = tweaks.get("wingspan", tweaks.get("size", 1.0))
	var sweep = tweaks.get("wing_sweep", 1.0)

	# node_scale for this type is (2, 1, 2), so hull measurements handed over
	# in world units are HALF that many units in the module's own local space.
	# Getting this wrong builds a frame twice the length of the roof it is
	# supposed to sit on.
	const NODE_S := 2.0
	var roof_len: float = float(tweaks.get("target_length", base_size.z * 4.0)) / NODE_S
	var roof_reach: float = float(tweaks.get("roof_reach", base_size.x * 2.0)) / NODE_S

	var wing_root: Vector3 = _build_ornithopter_rig(parent_node, base_size, base_color, roof_len, roof_reach)

	# Fore/hind wing roots sit close together fore-and-aft on the thorax
	# (a real dragonfly's two wing bases are close but distinct), not
	# spread across the whole hull like the old single-wing rib fan was.
	# Hind wing reads slightly broader than fore (size_mult 1.15), matching
	# a real dragonfly's hindwing being the bigger of the pair.
	# Keyed to the rig's own rail length now, not base_size, so the two roots
	# sit at the gearboxes the rig actually placed.
	var root_gap = roof_len * 0.30
	_build_ornithopter_wing_unit(parent_node, base_size, base_color, wingspan, sweep, PIVOT_WING_FORE, root_gap, wing_root, 1.0)
	_build_ornithopter_wing_unit(parent_node, base_size, base_color, wingspan, sweep, PIVOT_WING_HIND, -root_gap, wing_root, 1.15)


## The flapping rig: a two-rail frame lying fore-and-aft along the hull roof,
## cross-braced, carrying a gearbox at each wing root and strutted down into
## the roof itself. Returns the Y the wing pivots should hang off.
##
## Same invariant that makes build_wheel_mount() work, reflected: the module's
## origin sits ON THE HULL'S TOP EDGE (locomotion_layout puts it there), so a
## rail raised slightly above the origin and a strut running down and INBOARD
## from it arrives inside the hull's solid volume by construction. No hull
## measurement past the two spans the layout already publishes, no reach solve.
##
## `roof_len`/`roof_reach` are the hull's length and half-width, in the
## module's LOCAL units. Inboard is -X on both sides (the layout mirrors the
## port instance), so the frame is built on -X and the wings on +X.
static func _build_ornithopter_rig(parent_node: Node3D, base_size: Vector3, base_color: Color, roof_len: float, roof_reach: float) -> Vector3:
	var rail_z: float = roof_len * 0.44        # spans full working area of the roof
	var inboard_x: float = -roof_reach * 0.85  # stops just short of the centreline
	var rail_y: float = roof_reach * 0.22      # clear of the roof, so struts have a run
	var beam := roof_reach * 0.24             # Heavy structural box girders (Chris: bulkier rack)

	var box_mesh := _part("rg_mount_box")
	var gb_mesh := _part("wheel_gearbox")
	var strut_mesh := _part("mount_strut_tapered")
	var metal := base_color.darkened(0.25).lightened(0.2)

	var box_len := 1.0
	var box_wide := 1.0
	if box_mesh:
		var ba := box_mesh.get_aabb()
		box_len = maxf(ba.size.y, 0.001)
		box_wide = maxf(maxf(ba.size.x, ba.size.z), 0.001)

	var _beamed := func(span: Vector3, at: Vector3, w: float) -> void:
		if box_mesh == null:
			return
		var l: float = span.length()
		if l <= 0.0001:
			return
		var dir: Vector3 = span / l
		var right: Vector3 = dir.cross(Vector3.FORWARD)
		if right.length_squared() < 0.001:
			right = dir.cross(Vector3.RIGHT)
		right = right.normalized()
		var fwd: Vector3 = right.cross(dir).normalized()
		var b := _mesh_inst(box_mesh, metal)
		b.transform = Transform3D(
			Basis(right * (w / box_wide), dir * (l / box_len), fwd * (w / box_wide)), at)
		parent_node.add_child(b)

	# 1. Heavy longitudinal rails, outboard and inboard
	for x in [0.0, inboard_x]:
		_beamed.call(Vector3(0, 0, rail_z * 2.0), Vector3(x, rail_y, -rail_z), beam)

	# 2. Heavy cross-girders connecting the rails
	for z in [-rail_z, -rail_z * 0.45, 0.0, rail_z * 0.45, rail_z]:
		_beamed.call(Vector3(inboard_x, 0, 0), Vector3(0, rail_y, z), beam * 0.90)

	# 3. Bulky industrial gearboxes and drive transmission (Chris: bulkier gearboxes)
	var gb: float = roof_reach * 0.88
	var root_z_offset := roof_len * 0.30

	if gb_mesh:
		for z in [root_z_offset, -root_z_offset]:
			# Main wing-root gearbox housing
			var gearbox := _mesh_inst(gb_mesh, base_color.darkened(0.15).lightened(0.25))
			gearbox.scale = Vector3(gb * 1.15, gb * 1.20, gb * 1.40)
			gearbox.position = Vector3(-gb * 0.20, rail_y, z)
			parent_node.add_child(gearbox)

			# Outboard Flapping Pivot Bearing Collar
			var bearing := CylinderMesh.new()
			bearing.top_radius = gb * 0.24
			bearing.bottom_radius = gb * 0.28
			bearing.height = gb * 0.32
			var bearing_inst := _mesh_inst(bearing, Color(0.22, 0.24, 0.26))
			bearing_inst.rotation = Vector3(0, 0, deg_to_rad(90.0))
			bearing_inst.position = Vector3(gb * 0.35, rail_y, z)
			parent_node.add_child(bearing_inst)

			# Inboard Motor / Hydraulic Actuator Housing
			var actuator := BoxMesh.new()
			actuator.size = Vector3(gb * 0.40, gb * 0.80, gb * 0.80)
			var act_inst := _mesh_inst(actuator, Color(0.18, 0.19, 0.21))
			act_inst.position = Vector3(-gb * 0.70, rail_y, z)
			parent_node.add_child(act_inst)

		# Heavy central drive transmission unit spanning the gap between gearboxes
		var drive := _mesh_inst(gb_mesh, base_color.darkened(0.25))
		drive.scale = Vector3(gb * 0.85, gb * 0.95, roof_len * 0.65)
		drive.position = Vector3(-gb * 0.20, rail_y, 0.0)
		parent_node.add_child(drive)

		# Mechanical cooling / stiffener ribs along top of central transmission
		var rib := BoxMesh.new()
		rib.size = Vector3(gb * 0.50, gb * 0.12, roof_len * 0.55)
		var rib_inst := _mesh_inst(rib, Color(0.15, 0.16, 0.18))
		rib_inst.position = Vector3(-gb * 0.20, rail_y + gb * 0.50, 0.0)
		parent_node.add_child(rib_inst)

	# 4. Thick structural pylons solved against the hull surface mesh (Chris: thicker & extend to hull skin)
	var station := MountReachScript.station_from({})
	var surface := MountReachScript.surface_for(parent_node)

	var pylon_w := beam * 1.55 # Thick, load-bearing legs

	var pylon_z_stations := [-rail_z * 0.75, -rail_z * 0.25, rail_z * 0.25, rail_z * 0.75]
	for z_pos in pylon_z_stations:
		for x in [0.0, inboard_x]:
			var p_local := Vector3(x, rail_y, z_pos)
			# Station in hull space (accounting for node_scale of (2,1,2))
			var p_hull := station + Vector3(p_local.x * 2.0, p_local.y, p_local.z * 2.0)

			var drop_len: float = rail_y + roof_reach * 0.85
			var hit_norm := Vector3.UP

			if not surface.is_empty():
				var hit: Dictionary = HullProjectionScript.raycast(surface, p_hull, Vector3.DOWN)
				if hit.get("hit", false):
					var hit_pos: Vector3 = hit["position"]
					hit_norm = hit.get("normal", Vector3.UP)
					drop_len = (p_hull.y - hit_pos.y) + 0.08
				else:
					# Fan search if vertical hit missed a chamfered shoulder
					for ang in [-15.0, 15.0, -30.0, 30.0]:
						var test_dir := Vector3.DOWN.rotated(Vector3.FORWARD, deg_to_rad(ang))
						var hit2: Dictionary = HullProjectionScript.raycast(surface, p_hull, test_dir)
						if hit2.get("hit", false):
							var hit_pos2: Vector3 = hit2["position"]
							hit_norm = hit2.get("normal", Vector3.UP)
							drop_len = (p_hull.y - hit_pos2.y) + 0.08
							break

			# Splay slightly for triangular trestle stability
			var lean: float = (roof_reach * 0.10) * (-1.0 if x == 0.0 else 1.0)
			var span := Vector3(lean, -drop_len, 0.0)
			var l: float = span.length()
			var dir: Vector3 = span / l
			var right: Vector3 = dir.cross(Vector3.FORWARD).normalized()
			var fwd: Vector3 = right.cross(dir).normalized()

			if strut_mesh:
				var strut := _mesh_inst(strut_mesh, base_color.darkened(0.32))
				strut.transform = Transform3D(
					Basis(right * pylon_w, dir * l, fwd * pylon_w),
					p_local)
				parent_node.add_child(strut)
			else:
				var leg := BoxMesh.new()
				leg.size = Vector3(pylon_w, l, pylon_w)
				var leg_inst := _mesh_inst(leg, base_color.darkened(0.32))
				leg_inst.transform = Transform3D(
					Basis(right * pylon_w, dir * l, fwd * pylon_w),
					p_local)
				parent_node.add_child(leg_inst)

			# Mounting flange baseplate flush against the hull roof skin
			var baseplate := BoxMesh.new()
			baseplate.size = Vector3(pylon_w * 1.6, 0.08, pylon_w * 1.6)
			var baseplate_inst := _mesh_inst(baseplate, base_color.darkened(0.45).lightened(0.1))
			baseplate_inst.position = p_local + span
			if absf(hit_norm.dot(Vector3.UP)) < 0.95:
				var b_forward := -hit_norm.normalized()
				var b_right := b_forward.cross(Vector3.UP).normalized()
				var b_up := b_right.cross(b_forward).normalized()
				baseplate_inst.transform.basis = Basis(b_right, b_up, -b_forward)
			parent_node.add_child(baseplate_inst)

	# Wing root emerges directly from the outboard pivot bearing
	return Vector3(gb * 0.35, rail_y, 0.0)


# One wing (membrane + a single main spar) of an ornithopter_wing's fore/
# hind pair, on its own named flap pivot. size_mult lets the hind wing read
# as the broader of the two. Split out of _build_ornithopter_wing() so the
# fore and hind units share identical construction logic.
#
# Rebuilt (Chris's ask, 2026-07-24): "each wing should have a single
# wing-rib that connects to the gearbox/mount, and extends about 2/3rds of
# the total length of the wing membrane" - the old rib_count-driven fan of
# 2-6 parallel ribs (rib_count was never actually wired to any UI control,
# so it silently always defaulted to 3) read as a loose bundle of sticks
# radiating from the mount rather than a single readable wing spar,
# especially once the wing got much longer earlier in this rebuild. One
# spar, root-anchored at the same point as the membrane, 2/3 of the
# membrane's own rendered length, replaces it - rib_count is gone
# entirely, not just defaulted differently (see the matching removals in
# module_catalog.gd's LOCOMOTION_TWEAK_SPECS, module_placer.gd, and
# module_data.gd's weight/cost tweak tables).
static func _build_ornithopter_wing_unit(parent_node: Node3D, base_size: Vector3, base_color: Color, wingspan: float, sweep: float, pivot_name: String, z_offset: float, wing_root: Vector3, size_mult: float):
	var mem_mesh = _part("wing_membrane")
	var rib_mesh = _part("wing_rib")
	# IMPRACTICALLY LONG (Chris, 2026-08-02). Sized to land just inside
	# locomotion_layout's 5.5x width clamp at the default wingspan of 1.0:
	# any further and the clamp fires and shrinks the roof rig along with the
	# wing, which is not a trade worth making - the rig is the half of this
	# module that has to stay legible.
	const SPAN_MULT := 1.5
	var span = wingspan * size_mult * SPAN_MULT
	var sweep_angle = deg_to_rad(12.0) * sweep

	var pivot = Node3D.new()
	pivot.name = pivot_name
	# Hung off the rig's rail height, at the gearbox, rather than at a fixed
	# fraction of the part's own size out in space.
	pivot.position = Vector3(wing_root.x, wing_root.y, z_offset)
	parent_node.add_child(pivot)

	# root_x/mem_len track the membrane's actual root position and
	# rendered length so the single spar below can be anchored and sized
	# to match, whichever branch (authored vs procedural fallback) built it.
	# root_x is 0 (not base_size.x*0.2 again) because the pivot ABOVE
	# already carries that same offset out from the gearbox - doubling it
	# here used to put the wing's actual root a further 0.2*base_size.x
	# past the pivot, floating well clear of the gearbox mesh instead of
	# meeting it (Chris's report, 2026-07-24).
	var root_x = 0.0
	var mem_len: float

	if mem_mesh:
		var mem = _mesh_inst(mem_mesh, base_color)
		# CHORD. The membrane is authored 0.3 wide against a 2.4 length; at the
		# new span that ratio put a 0.3-wide panel on an 8-unit wing, which
		# rendered as a black sliver you could miss entirely from three
		# quarters. Widened so the wing still reads AS a wing at a span this
		# silly - the absurdity should be legible, not invisible.
		const CHORD := 3.2
		mem.scale = Vector3(span, 1.0, CHORD)
		mem.position = Vector3(root_x, 0, 0)
		mem.rotation = Vector3(0, 0, sweep_angle)
		pivot.add_child(mem)
		mem_len = 2.4 * span # 2.4 = build_wing_membrane's authored "length" default

		# Inner connector panel (Chris's ask, 2026-07-24): a mirrored
		# duplicate of the very same tapered membrane mesh, rotated 180deg
		# so its NARROW end now points inward and reaches back past the
		# pivot to intersect the gearbox, while its WIDE end sits at
		# exactly the same point as the outer panel's own wide root above
		# (both positioned at pivot-local x=0) - so the two meet seamlessly
		# at full root width, with no visible gap or step. This also gives
		# the wing the fast inside taper Chris asked for: the widest point
		# of the whole wing is now out at this root/hinge, not smeared
		# uniformly from the gearbox itself, since the connector pinches
		# back down to the membrane's narrow-tip width as it nears the hull.
		# scale.x is deliberately NOT `span` - wingspan only stretches the
		# OUTER panel's reach; the connector only needs to be exactly long
		# enough to bridge the gearbox gap (pivot.position.x) plus a 40%
		# overshoot so it visibly overlaps/intersects the gearbox mesh
		# rather than just grazing its surface.
		var connector_len = pivot.position.x * 1.4
		var connector = _mesh_inst(mem_mesh, base_color)
		connector.scale = Vector3(connector_len / 2.4, 1.0, CHORD)
		connector.rotation = Vector3(0, PI, sweep_angle)
		pivot.add_child(connector)
	else:
		var mem = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(base_size.x * 0.75 * span, base_size.y * 0.15, base_size.z * 0.85)
		mem.mesh = box
		var mat = StandardMaterial3D.new()
		mat.albedo_color = base_color
		mem.material_override = mat
		# BoxMesh is centered on its own origin (unlike the authored
		# membrane's root-at-zero convex hull), so root_x here is HALF the
		# box's own length - that puts its near edge (the root) at
		# pivot-local x=0, matching the authored branch's convention above.
		root_x = box.size.x * 0.5
		mem.position = Vector3(root_x, 0, 0)
		mem.rotation = Vector3(0, 0, sweep_angle)
		pivot.add_child(mem)
		mem_len = base_size.x * 0.75 * span

	var rib_len = mem_len * (2.0 / 3.0)
	var rib: MeshInstance3D
	if rib_mesh:
		rib = _mesh_inst(rib_mesh, Color(0.22, 0.17, 0.12))
		rib.scale = Vector3(rib_len / 2.3, 1.0, 1.0) # 2.3 = build_wing_rib's authored "length" default
	else:
		rib = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(rib_len, base_size.y * 0.04, base_size.z * 0.06)
		rib.mesh = box
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.22, 0.17, 0.12)
		rib.material_override = mat
	rib.position = Vector3(root_x, base_size.y * 0.08, 0)
	rib.rotation = Vector3(0, 0, sweep_angle)
	pivot.add_child(rib)


# Used by buoyant_envelope (Chris's ask, 2026-07-24): it used to spawn
# entirely inside the hull mesh with no visible structure reaching it clear
# of it - a fixed side-mounted offset that landed well within the hull's
# own collision box on most hull shapes. Rebuilt to reuse the exact stern/
# reach-vector pylon technique already established for helicopter_rotors/
# hover_engine/fixed_wing_engine: module_placer.gd now places the propeller
# itself well aft of the hull's own mesh and passes a mount_reach vector
# pointing back to the hull's geometric center, and this function builds a
# mount_strut_aerofoil pylon along that vector, with the propeller hub+
# blades at the far (outboard) end. hub_scale scales this single reuse of
# the prop_housing/rotor_blade GLBs (buoyant_envelope's smaller cruise
# motor) without needing separate authored assets.
static func _build_pylon_mounted_propeller(parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary, hub_scale: float, blade_scale: float = 1.0):
	var blade_count = int(tweaks.get("blade_count", 3.0))
	var blade_pitch = tweaks.get("blade_pitch", 1.0)

	var housing_mesh = _part("prop_housing")
	var blade_mesh = _part("rotor_blade")
	var strut_mesh = _part("mount_strut_aerofoil")

	var actual_size = base_size * hub_scale
	if housing_mesh:
		var house = _mesh_inst(housing_mesh, base_color.darkened(0.2))
		house.scale = Vector3(hub_scale, hub_scale, hub_scale)
		parent_node.add_child(house)
	else:
		var house = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = actual_size.x * 0.4
		cyl.bottom_radius = actual_size.x * 0.5
		cyl.height = actual_size.z * 0.7
		house.mesh = cyl
		var mat = StandardMaterial3D.new()
		mat.albedo_color = base_color.darkened(0.2)
		house.material_override = mat
		house.rotation = Vector3(PI / 2.0, 0, 0)
		parent_node.add_child(house)

	var pivot = Node3D.new()
	pivot.name = PIVOT_PROP_BLADES
	pivot.position = Vector3(0, 0, actual_size.z * 0.35)
	parent_node.add_child(pivot)

	_ring_of(pivot, blade_count, 0.0, func(p, _pos, angle, _idx):
		var blade: MeshInstance3D
		if blade_mesh:
			# rotor_blade is authored with its span along LOCAL Z (root at
			# z=0, tip at z=length - see build_rotor_blade) - correct as-is
			# for helicopter_rotors, which spins its blades around Y (a
			# Z-reaching blade sweeps properly through the horizontal
			# plane there). This hub spins around Z instead (PropBlades
			# rotates_z in unit.gd, matching a boat/aircraft
			# propeller shaft), and rotating a Z-REACHING blade around Z
			# does nothing - Z-axis rotation leaves the Z component
			# unchanged, which is exactly why every blade used to end up
			# overlapping at the same spot regardless of `angle` (Chris's
			# report, 2026-07-24). Fix: reorient the blade's span from Z
			# onto X first (a fixed -90deg turn around Y), then pitch it
			# around its own new (X) spanwise axis, THEN fan each blade out
			# by its own angle around Z - now that the blade actually has
			# an X/Y component, the Z fan-out rotation genuinely spreads
			# them around the hub. Built as a pure-rotation quaternion
			# (not Euler) so it composes correctly and doesn't disturb the
			# scale set right after.
			var reorient = Basis(Vector3(0, 1, 0), -PI / 2.0)
			var pitch_rot = Basis(Vector3(1, 0, 0), 0.3 * blade_pitch)
			var fan_rot = Basis(Vector3(0, 0, 1), angle)
			blade = _mesh_inst(blade_mesh, Color.SILVER)
			blade.quaternion = (fan_rot * pitch_rot * reorient).get_rotation_quaternion()
			blade.scale = Vector3(0.5 * blade_scale, 1.0, actual_size.x * 0.4 * blade_scale)
		else:
			# The procedural fallback box is built fresh here with its long
			# dimension already along Y (box.size.y), perpendicular to the
			# Z fan-out axis - correctly spreads with a plain rotate_z(),
			# no reorientation needed (unlike the authored branch above).
			blade = MeshInstance3D.new()
			var box = BoxMesh.new()
			box.size = Vector3(0.04 * blade_scale, actual_size.x * 0.7 * blade_scale, 0.12 * blade_scale)
			blade.mesh = box
			var mat = StandardMaterial3D.new()
			mat.albedo_color = Color.SILVER
			blade.material_override = mat
			blade.rotate_z(angle)
			blade.rotate_y(0.3 * blade_pitch)
		p.add_child(blade)
	)

	# Pylon reaching back to the hull's geometric center - same reach-
	# vector technique as _build_fixed_wing_engine's pylon (see that
	# function's comment for the full explanation). module_placer.gd
	# computes mount_reach as the offset from THIS propeller's placed
	# position back to the hull's own local origin (0,0,0), so the far end
	# of this strut always lands exactly at the hull's geometric center
	# regardless of where the propeller itself was placed.
	var mount_reach = Vector3(tweaks.get("mount_reach_x", 0.0), tweaks.get("mount_reach_y", 0.0), tweaks.get("mount_reach_z", 1.0))
	if mount_reach.length() > 0.001:
		var reach_len = mount_reach.length()
		var dir = mount_reach / reach_len
		var reference = Vector3(0, 1, 0)
		if abs(dir.dot(reference)) > 0.95:
			reference = Vector3(1, 0, 0)
		var right = dir.cross(reference).normalized()
		var forward = right.cross(dir).normalized()
		if strut_mesh:
			var strut = _mesh_inst(strut_mesh, base_color.darkened(0.2))
			strut.transform = Transform3D(Basis(right * 1.4, dir * reach_len, forward * 1.4), Vector3.ZERO)
			parent_node.add_child(strut)
		else:
			var mount_mesh = _part("rg_mount_box")
			if mount_mesh:
				var strut = _mesh_inst(mount_mesh, base_color.darkened(0.2))
				strut.transform = Transform3D(Basis(right * 1.2, dir * reach_len, forward * 0.6), Vector3.ZERO)
				parent_node.add_child(strut)


static func _build_buoyant_envelope(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.TAN, tweaks: Dictionary = {}):
	# AIRSHIP CRUISE / LOITER ENGINE
	# Mechanical exposed turboprop/radial engine pod on structural outrigger pylons.
	var blade_count := int(tweaks.get("blade_count", 3.0))
	var blade_pitch := float(tweaks.get("blade_pitch", 1.0))
	var is_belly: bool = bool(tweaks.get("pod_belly", false))

	var nose_mesh := _part("be_nose_cone")
	var block_mesh := _part("be_engine_block")
	var blade_mesh := _part("rotor_blade")
	var strut_mesh := _part("mount_strut_tapered")
	if not strut_mesh:
		strut_mesh = _part("mount_strut_aerofoil")

	var pod_mult: float = float(tweaks.get("engine_size", tweaks.get("size", tweaks.get("scale", 1.0))))
	var s: float = maxf(float(tweaks.get("pod_scale", base_size.x)), 0.5) * 0.95 * pod_mult
	var struct_color := base_color.darkened(0.25)

	# 1. Structural Outrigger Poles: Continuous stretched poles spanning directly to the hull skin
	var station := MountReachScript.station_from(tweaks)
	if station.length_squared() < 0.001 and parent_node.position.length_squared() > 0.001:
		station = parent_node.position

	var surface := MountReachScript.surface_for(parent_node)
	if surface.is_empty() and parent_node.get_parent() != null and (parent_node.get_parent() is Node3D):
		surface = HullProjectionScript.build_surface(parent_node.get_parent())

	var mount_side := float(tweaks.get("mount_side", 1.0 if station.x >= 0.0 else -1.0))
	var station_x: float = absf(station.x) if station.length_squared() > 0.001 else 2.5
	var eff_station := Vector3(station_x, station.y, station.z)

	var dist_to_skin: float = 0.0
	var found_skin := false

	if not surface.is_empty():
		var hit: Dictionary = HullProjectionScript.raycast(surface, eff_station, Vector3(-1.0, 0, 0))
		if hit.get("hit", false):
			dist_to_skin = (hit["position"] - eff_station).length()
			found_skin = true
		else:
			for ang in [-15.0, 15.0, -30.0, 30.0]:
				var test_dir := Vector3(-1.0, 0, 0).rotated(Vector3.UP, deg_to_rad(ang))
				var hit2: Dictionary = HullProjectionScript.raycast(surface, eff_station, test_dir)
				if hit2.get("hit", false):
					dist_to_skin = (hit2["position"] - eff_station).length()
					found_skin = true
					break

	if not found_skin:
		dist_to_skin = maxf(station_x * 0.75, 2.0)

	# Extend deeply into the hull skin (at least 0.35m past skin or 75% of standoff distance)
	var total_reach: float = maxf(dist_to_skin + 0.35, maxf(station_x * 0.75 + 0.3, 2.4))
	var dir_x: float = -1.0 if mount_side >= 0.0 else 1.0

	var pole_cyl := CylinderMesh.new()
	pole_cyl.top_radius = 0.055 * s
	pole_cyl.bottom_radius = 0.065 * s
	pole_cyl.height = total_reach
	pole_cyl.radial_segments = 12

	if is_belly:
		for z_off in [0.05 * s, 0.35 * s]:
			var pole := _mesh_inst(pole_cyl, struct_color)
			pole.position = Vector3(0, total_reach * 0.5, z_off)
			parent_node.add_child(pole)
	else:
		# Forward mounting pole
		var p1 := _mesh_inst(pole_cyl, struct_color)
		p1.position = Vector3(dir_x * (total_reach * 0.5), 0.05 * s, 0.05 * s)
		p1.rotation = Vector3(0, 0, deg_to_rad(90.0))
		parent_node.add_child(p1)

		# Aft mounting pole
		var p2 := _mesh_inst(pole_cyl, struct_color)
		p2.position = Vector3(dir_x * (total_reach * 0.5), 0.05 * s, 0.35 * s)
		p2.rotation = Vector3(0, 0, deg_to_rad(90.0))
		parent_node.add_child(p2)

	# 2. Engine Block (Center)
	if block_mesh:
		var block := _mesh_inst(block_mesh, struct_color)
		block.scale = Vector3.ONE * s
		block.rotation = Vector3(0, PI, 0) # Face forward (-Z)
		block.position = Vector3.ZERO
		parent_node.add_child(block)
	else:
		var block := BoxMesh.new()
		block.size = Vector3(0.40 * s, 0.45 * s, 0.65 * s)
		var b_inst := _mesh_inst(block, struct_color)
		b_inst.position = Vector3.ZERO
		parent_node.add_child(b_inst)

	# 3. Front Nose Cone / Fairing (Snug against front face of engine block)
	if nose_mesh:
		var nose := _mesh_inst(nose_mesh, struct_color.lightened(0.06))
		nose.scale = Vector3.ONE * s
		nose.rotation = Vector3(0, PI, 0) # Point forward (-Z)
		nose.position = Vector3(0, 0, -0.03 * s) # Collar meets front of block
		parent_node.add_child(nose)

	# 4. Rear Propeller Hub & Blades (Snug against rear reduction gear at Z = +0.45 * s)
	var pivot := Node3D.new()
	pivot.name = PIVOT_PROP_BLADES
	pivot.position = Vector3(0, 0.04 * s, 0.45 * s)
	parent_node.add_child(pivot)

	# Spinner bullet cone pointing aft (+Z)
	var spinner := CylinderMesh.new()
	spinner.top_radius = 0.02 * s
	spinner.bottom_radius = 0.15 * s
	spinner.height = 0.20 * s
	var spinner_inst := _mesh_inst(spinner, Color(0.24, 0.26, 0.28))
	spinner_inst.rotation = Vector3(deg_to_rad(90.0), 0, 0)
	spinner_inst.position = Vector3(0, 0, 0.10 * s)
	pivot.add_child(spinner_inst)

	# Spinner backing plate collar
	var backing := CylinderMesh.new()
	backing.top_radius = 0.16 * s
	backing.bottom_radius = 0.16 * s
	backing.height = 0.04 * s
	var back_inst := _mesh_inst(backing, Color(0.18, 0.20, 0.22))
	back_inst.rotation = Vector3(deg_to_rad(90.0), 0, 0)
	back_inst.position = Vector3(0, 0, 0.01 * s)
	pivot.add_child(back_inst)

	# Propeller Blades spanning radially in the XY plane (shrunk by 30%)
	const AUTHORED_BLADE_LEN := 1.20
	var blade_len: float = 0.95 * s
	var blade_scale_z: float = blade_len / AUTHORED_BLADE_LEN

	_ring_of(pivot, blade_count, 0.0, func(p, _pos, angle, _idx):
		var span_dir := Vector3(cos(angle), sin(angle), 0.0)
		var chord_dir := span_dir.cross(Vector3(0, 0, 1.0)).normalized()
		var thrust_dir := Vector3(0, 0, 1.0)

		var pitch_rad: float = deg_to_rad(25.0 * blade_pitch)
		var pitched_chord: Vector3 = chord_dir.rotated(span_dir, pitch_rad)
		var pitched_thrust: Vector3 = thrust_dir.rotated(span_dir, pitch_rad)

		if blade_mesh:
			var blade := _mesh_inst(blade_mesh, Color(0.22, 0.22, 0.24))
			blade.transform.basis = Basis(pitched_chord, pitched_thrust, span_dir)
			blade.scale = Vector3(0.85 * s, 0.85 * s, blade_scale_z)
			blade.position = span_dir * (0.12 * s)
			p.add_child(blade)
		else:
			var blade_box := BoxMesh.new()
			blade_box.size = Vector3(0.12 * s, 0.025 * s, blade_len)
			var blade_inst := _mesh_inst(blade_box, Color(0.22, 0.22, 0.24))
			blade_inst.transform.basis = Basis(pitched_chord, pitched_thrust, span_dir)
			blade_inst.position = span_dir * (0.12 * s + blade_len * 0.5)
			p.add_child(blade_inst)
	)

	# 5. Blimp Envelope attached to top of hull with rigging cables
	_build_blimp_envelope(parent_node, base_size, base_color, tweaks)


## Blimp Gasbag Envelope & Suspension Rigging Cables
static func _build_blimp_envelope(parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary = {}) -> void:
	if not is_instance_valid(parent_node):
		return
	if not parent_node.is_inside_tree() or parent_node.get_parent() == null:
		# BATTLE TEMPLATE CASE. unit_assembly.gd builds its cached hull template
		# into a DETACHED holder and never puts it in a tree - so tree_entered
		# below would never fire for it - and Node.duplicate() drops signal
		# connections anyway, so every spawned copy used to silently miss the
		# envelope entirely (the "blimp drive has no blimp in battle" report).
		# Park the build params as metadata; ensure_blimp_envelope() picks them
		# up once the live copy is inside the match tree.
		parent_node.set_meta("blimp_pending", {
			"base_size": base_size,
			"base_color": base_color,
			"tweaks": tweaks.duplicate(true),
		})
		if not parent_node.is_connected("tree_entered", Callable(VisualBuilder, "_on_blimp_parent_tree_entered")):
			parent_node.tree_entered.connect(_on_blimp_parent_tree_entered.bind(parent_node, base_size, base_color, tweaks), CONNECT_ONE_SHOT)
		return
	_apply_blimp_envelope(parent_node, base_size, base_color, tweaks)

static func _on_blimp_parent_tree_entered(parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary) -> void:
	Callable(VisualBuilder, "_apply_blimp_envelope").call_deferred(parent_node, base_size, base_color, tweaks)

# Apply any deferred envelopes riding on this subtree. Called once per spawned
# unit from unit.gd's setup(), after the duplicated template is inside the
# match tree. The meta is consumed on apply, so a node can never be built twice.
static func ensure_blimp_envelope(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if not is_instance_valid(n):
			continue
		if n.has_meta("blimp_pending"):
			var p: Dictionary = n.get_meta("blimp_pending")
			n.remove_meta("blimp_pending")
			_apply_blimp_envelope(n, p.get("base_size", Vector3.ONE),
				p.get("base_color", Color(0.4, 0.44, 0.4)), p.get("tweaks", {}))
		for c in n.get_children():
			stack.append(c)

static func _apply_blimp_envelope(parent_node: Node3D, base_size: Vector3, base_color: Color, tweaks: Dictionary = {}) -> void:
	if not is_instance_valid(parent_node) or not parent_node.is_inside_tree():
		return

	var chassis_node: Node3D = parent_node.get_parent() as Node3D if (parent_node.get_parent() != null and parent_node.get_parent() is Node3D) else parent_node
	while chassis_node != null and chassis_node.get_parent() != null and (chassis_node.get_parent() is Node3D) and not (chassis_node.get_parent() is SubViewport or chassis_node.get_parent() is Window):
		if chassis_node.name.contains("Hull") or chassis_node.name.contains("Vehicle") or chassis_node.name == "VisualModel" or chassis_node.has_meta("hull_data"):
			break
		chassis_node = chassis_node.get_parent() as Node3D

	if chassis_node.has_node("BlimpEnvelope"):
		return

	var blimp_container := Node3D.new()
	blimp_container.name = "BlimpEnvelope"
	chassis_node.add_child(blimp_container)

	var surface_data := _gather_hull_only_surface(chassis_node)
	var hull_aabb: AABB = surface_data.get("aabb", get_full_hull_aabb(chassis_node))

	var hull_w: float = maxf(hull_aabb.size.x, 2.2)
	var hull_h: float = maxf(hull_aabb.size.y, 1.2)
	var hull_l: float = maxf(hull_aabb.size.z, 3.8)
	var hull_roof_y: float = hull_aabb.position.y + hull_aabb.size.y
	var hull_center_z: float = hull_aabb.position.z + hull_aabb.size.z * 0.5

	# Gasbag Ellipsoid Dimensions. envelope_volume is capacity - lift is
	# linear in it - so it shapes the bag like resource_bay's bay_volume:
	# cube-root, so a 2.0-volume envelope reads ~1.26x on each axis while
	# carrying exactly twice as much.
	var env_vol_lin: float = pow(clampf(float(tweaks.get("envelope_volume", 1.0)), 0.5, 2.0), 1.0 / 3.0)
	var env_radius_z: float = hull_l * 0.72 * env_vol_lin
	var env_radius_x: float = hull_w * 0.68 * env_vol_lin
	var env_radius_y: float = hull_w * 0.60 * env_vol_lin
	var cable_gap: float = maxf(hull_h * 0.40, 0.75)
	var env_center_y: float = hull_roof_y + cable_gap + env_radius_y
	var env_center := Vector3(0, env_center_y, hull_center_z)

	var fabric_color: Color = base_color.lightened(0.18)
	var struct_color: Color = base_color.darkened(0.35)

	# 1. Main Ellipsoid Gasbag Mesh
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 36
	sphere.rings = 18
	var gasbag := _mesh_inst(sphere, fabric_color)
	gasbag.scale = Vector3(env_radius_x, env_radius_y, env_radius_z)
	gasbag.position = env_center
	blimp_container.add_child(gasbag)

	# 2. Longitudinal Keel Spar along lower belly of gasbag
	var keel := BoxMesh.new()
	keel.size = Vector3(0.20, 0.16, env_radius_z * 1.65)
	var keel_inst := _mesh_inst(keel, struct_color)
	keel_inst.position = env_center + Vector3(0, -env_radius_y * 0.94, 0)
	blimp_container.add_child(keel_inst)

	# 3. Girth Reinforcement Rings (Forward, Mid, Aft)
	for z_frac in [-0.45, 0.0, 0.45]:
		var rz: float = z_frac * env_radius_z
		var factor: float = sqrt(maxf(0.01, 1.0 - (z_frac * z_frac)))
		var ring_rx: float = env_radius_x * factor + 0.02
		var ring_ry: float = env_radius_y * factor + 0.02
		var ring_torus := TorusMesh.new()
		ring_torus.inner_radius = maxf(ring_rx - 0.03, 0.1)
		ring_torus.outer_radius = ring_rx
		ring_torus.rings = 24
		ring_torus.ring_segments = 8
		var ring_inst := _mesh_inst(ring_torus, struct_color)
		ring_inst.rotation = Vector3(deg_to_rad(90.0), 0, 0)
		ring_inst.scale = Vector3(1.0, 1.0, ring_ry / maxf(ring_rx, 0.1))
		ring_inst.position = env_center + Vector3(0, 0, rz)
		blimp_container.add_child(ring_inst)

	# 4. Tail Empennage (Stabilizer Fins at Aft)
	var fin_z: float = hull_center_z + env_radius_z * 0.72
	var fin_len: float = env_radius_z * 0.38
	var fin_span_x: float = env_radius_x * 0.55
	var fin_span_y: float = env_radius_y * 0.55

	# Dorsal (Top) Fin
	var fin_d := BoxMesh.new()
	fin_d.size = Vector3(0.08, fin_span_y, fin_len)
	var fd_inst := _mesh_inst(fin_d, struct_color.lightened(0.05))
	fd_inst.position = Vector3(0, env_center_y + env_radius_y * 0.85, fin_z)
	blimp_container.add_child(fd_inst)

	# Ventral (Bottom) Fin
	var fin_v := BoxMesh.new()
	fin_v.size = Vector3(0.08, fin_span_y * 0.7, fin_len)
	var fv_inst := _mesh_inst(fin_v, struct_color.lightened(0.05))
	fv_inst.position = Vector3(0, env_center_y - env_radius_y * 0.85, fin_z)
	blimp_container.add_child(fv_inst)

	# Port & Starboard Horizontal Fins
	for sx in [-1.0, 1.0]:
		var fin_h := BoxMesh.new()
		fin_h.size = Vector3(fin_span_x, 0.08, fin_len)
		var fh_inst := _mesh_inst(fin_h, struct_color.lightened(0.05))
		fh_inst.position = Vector3(sx * (env_radius_x * 0.85), env_center_y, fin_z)
		blimp_container.add_child(fh_inst)

	# 5. Nose Mooring Spindle Cap (Front)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.04
	cone.bottom_radius = 0.28
	cone.height = 0.40
	var cone_inst := _mesh_inst(cone, struct_color)
	cone_inst.rotation = Vector3(deg_to_rad(-90.0), 0, 0)
	cone_inst.position = Vector3(0, env_center_y, hull_center_z - env_radius_z - 0.12)
	blimp_container.add_child(cone_inst)

	# 6. Suspension Rigging Cables (Attaching Hull Roof to Blimp Envelope dynamically)
	var cable_color := Color(0.20, 0.21, 0.23)

	# Ensure complete surface triangle cache for accurate raycasting against hull skin
	if not surface_data.has("tris") or surface_data["tris"].is_empty():
		surface_data = MountReachScript.surface_for(parent_node)
	if not surface_data.has("tris") or surface_data["tris"].is_empty():
		surface_data = HullProjectionScript.build_surface(chassis_node)

	var anchor_specs: Array[Dictionary] = [
		{"x": -hull_w * 0.35, "z": hull_center_z - hull_l * 0.28, "env_x": -env_radius_x * 0.48, "env_z": -env_radius_z * 0.35},
		{"x":  hull_w * 0.35, "z": hull_center_z - hull_l * 0.28, "env_x":  env_radius_x * 0.48, "env_z": -env_radius_z * 0.35},
		{"x": -hull_w * 0.40, "z": hull_center_z,                  "env_x": -env_radius_x * 0.55, "env_z": 0.0},
		{"x":  hull_w * 0.40, "z": hull_center_z,                  "env_x":  env_radius_x * 0.55, "env_z": 0.0},
		{"x": -hull_w * 0.35, "z": hull_center_z + hull_l * 0.28, "env_x": -env_radius_x * 0.48, "env_z":  env_radius_z * 0.35},
		{"x":  hull_w * 0.35, "z": hull_center_z + hull_l * 0.28, "env_x":  env_radius_x * 0.48, "env_z":  env_radius_z * 0.35},
	]

	for spec in anchor_specs:
		var env_attach := env_center + Vector3(spec["env_x"], -env_radius_y * 0.65, spec["env_z"])
		var target_x: float = spec["x"]
		var target_z: float = spec["z"]

		# Raycast dynamically from high above down toward the hull surface
		var ray_origin := Vector3(target_x, env_center_y, target_z)
		var ray_hit: Dictionary = HullProjectionScript.raycast(surface_data, ray_origin, Vector3.DOWN)

		var p_hull := Vector3.ZERO
		var n_hull := Vector3.UP

		if ray_hit.get("hit", false):
			p_hull = ray_hit["position"]
			n_hull = ray_hit.get("normal", Vector3.UP)
		else:
			var dir_to_target := (Vector3(target_x, hull_roof_y - 0.2, target_z) - env_attach).normalized()
			var angled_hit: Dictionary = HullProjectionScript.raycast(surface_data, env_attach, dir_to_target)
			if angled_hit.get("hit", false):
				p_hull = angled_hit["position"]
				n_hull = angled_hit.get("normal", Vector3.UP)
			else:
				p_hull = Vector3(target_x, hull_roof_y, target_z)
				n_hull = Vector3.UP

		# Cable extends dynamically deep into the hull skin (0.04m penetration to avoid gaps)
		var p_hull_deep := p_hull - n_hull * 0.04
		_build_blimp_cable(blimp_container, p_hull_deep, env_attach, 0.016, cable_color)

		# Mounting bracket pad seated flush against the hull surface
		var pad := BoxMesh.new()
		pad.size = Vector3(0.18, 0.05, 0.18)
		var p_inst := _mesh_inst(pad, struct_color)
		p_inst.position = p_hull + n_hull * 0.02

		var pad_y := n_hull.normalized()
		var pad_z := pad_y.cross(Vector3.RIGHT)
		if pad_z.length_squared() < 0.001:
			pad_z = pad_y.cross(Vector3.FORWARD)
		pad_z = pad_z.normalized()
		var pad_x := pad_y.cross(pad_z).normalized()
		p_inst.transform.basis = Basis(pad_x, pad_y, pad_z)
		blimp_container.add_child(p_inst)

static func _build_blimp_cable(root: Node3D, p_from: Vector3, p_to: Vector3, radius: float = 0.016, color: Color = Color(0.20, 0.21, 0.23)) -> void:
	var diff := p_to - p_from
	var length := diff.length()
	if length < 0.01:
		return
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = length
	cyl.radial_segments = 8
	var inst := _mesh_inst(cyl, color)
	inst.position = (p_from + p_to) * 0.5
	var y_axis := diff.normalized()
	var z_axis := y_axis.cross(Vector3.UP)
	if z_axis.length_squared() < 0.001:
		z_axis = y_axis.cross(Vector3.FORWARD)
	z_axis = z_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	inst.transform.basis = Basis(x_axis, y_axis, z_axis)
	root.add_child(inst)


static func _build_screw_drive(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DARK_GOLDENROD, tweaks: Dictionary = {}):
	var diameter = tweaks.get("drum_diameter", tweaks.get("drum_width", tweaks.get("size", 1.0)))
	var depth = tweaks.get("helix_depth", 1.0)
	var span = tweaks.get("drum_length", base_size.z) # total hull length

	var drum_variant = "screw_drum"
	if depth < 0.85:
		drum_variant = "screw_drum_shallow"
	elif depth > 1.15:
		drum_variant = "screw_drum_deep"
	var drum_mesh = _part(drum_variant)
	if not drum_mesh:
		drum_mesh = _part("screw_drum")

	var bore: float = float(tweaks.get("drum_bore", base_size.y))
	var mount_ref: float = bore * 0.46 * float(diameter)
	var drum_d: float = mount_ref * 2.1
	var drum_radius: float = drum_d * 0.5

	# Pin gearboxes at 10% in from each end of the hull (80% total span)
	var front_z: float = -span * 0.40
	var rear_z: float = span * 0.40
	var gearbox_span: float = rear_z - front_z

	# 1.5 drum radii out from the hull
	var outboard_x: float = 1.5 * drum_radius
	var hub_y: float = -mount_ref * 0.75

	var station := MountReachScript.station_from(tweaks)
	var node_scale := MountReachScript.node_scale_from(tweaks)

	var gb_mesh := _part("wheel_gearbox")
	var ds_mesh := _part("wheel_driveshaft")
	var gb_sz: float = 0.50 * mount_ref

	for z_end in [front_z, rear_z]:
		if gb_mesh:
			var gb := _mesh_inst(gb_mesh, base_color.darkened(0.1).lightened(0.3))
			gb.scale = Vector3(gb_sz, gb_sz, gb_sz * 1.2)
			gb.position = Vector3(outboard_x, hub_y, z_end)
			parent_node.add_child(gb)

		if ds_mesh:
			var bottom_target := Vector3(outboard_x - 0.5 * gb_sz, hub_y, z_end)
			var z_aim: float = 0.20 if z_end < 0.0 else -0.20
			var c_dirs: Array[Vector3] = [
				Vector3(-cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)), z_aim).normalized(),
				Vector3(-cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)), 0.0),
				Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), z_aim).normalized(),
				Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0),
				Vector3(-1.0, 0.0, 0.0)
			]
			var best_dir := c_dirs[0]
			var best_len := -1.0
			for cd in c_dirs:
				var l := MountReachScript.solve(parent_node, station, bottom_target, cd, -1.0, node_scale)
				if l > 0.0:
					best_dir = cd
					best_len = l
					break

			# Reliable fallback if raycast missed chamfer edge
			if best_len <= 0.0:
				best_dir = Vector3(-cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)), z_aim).normalized()
				best_len = (outboard_x / maxf(cos(deg_to_rad(45.0)), 0.1)) + 0.35 * mount_ref

			var shaft := _mesh_inst(ds_mesh, base_color.darkened(0.25).lightened(0.35))
			var top_pos := bottom_target + best_dir * best_len
			var up_vec := best_dir
			var side_vec := up_vec.cross(Vector3.FORWARD).normalized()
			if side_vec.length_squared() < 0.001:
				side_vec = Vector3.RIGHT
			var fwd_vec := side_vec.cross(up_vec).normalized()
			var shaft_thickness: float = 0.32 * mount_ref
			shaft.transform = Transform3D(
				Basis(side_vec * shaft_thickness, up_vec * best_len, fwd_vec * shaft_thickness),
				top_pos
			)
			parent_node.add_child(shaft)

	# Drum slung between gearboxes at outboard_x
	var spin = Node3D.new()
	spin.name = PIVOT_SCREW_SPIN
	spin.position = Vector3(outboard_x, hub_y, 0)
	parent_node.add_child(spin)

	var drum_target_len: float = gearbox_span * 1.05
	var actual_size = Vector3(drum_d, drum_d, drum_target_len)

	var drum: MeshInstance3D
	if drum_mesh:
		drum = _mesh_inst(drum_mesh, base_color)
		var da: AABB = drum_mesh.get_aabb()
		drum.scale = Vector3(
			actual_size.y / maxf(da.size.x, 0.001),
			actual_size.y / maxf(da.size.y, 0.001),
			drum_target_len / maxf(da.size.z, 0.001)
		)
	else:
		drum = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = actual_size.y * 0.4
		cyl.bottom_radius = actual_size.y * 0.4
		cyl.height = drum_target_len
		drum.mesh = cyl
		var mat = StandardMaterial3D.new()
		mat.albedo_color = base_color
		drum.material_override = mat
		drum.rotation = Vector3(PI / 2.0, 0, 0)
	spin.add_child(drum)


## Geometric Polish Pass (Section 3): a real thinning taper for
## propeller/screw blades - thick chord at the hub, narrow at the tip -
## instead of a constant-cross-section BoxMesh. Spans along local Y
## (0=root, span=tip); tapers chord along local Z; thickness (local X)
## stays constant along the span, matching how a real blade is built.
static func _build_tapered_blade_mesh(thickness: float, root_chord: float, tip_chord: float, span: float) -> ArrayMesh:
	var hx = thickness * 0.5
	var hz0 = root_chord * 0.5
	var hz1 = tip_chord * 0.5
	var root_pts = [
		Vector3(-hx, 0.0, -hz0), Vector3(hx, 0.0, -hz0),
		Vector3(hx, 0.0, hz0), Vector3(-hx, 0.0, hz0),
	]
	var tip_pts = [
		Vector3(-hx, span, -hz1), Vector3(hx, span, -hz1),
		Vector3(hx, span, hz1), Vector3(-hx, span, hz1),
	]
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(4):
		var a = root_pts[i]
		var b = root_pts[(i + 1) % 4]
		var c = tip_pts[(i + 1) % 4]
		var d = tip_pts[i]
		st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
		st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
	st.add_vertex(root_pts[0]); st.add_vertex(root_pts[2]); st.add_vertex(root_pts[1])
	st.add_vertex(root_pts[0]); st.add_vertex(root_pts[3]); st.add_vertex(root_pts[2])
	st.add_vertex(tip_pts[0]); st.add_vertex(tip_pts[1]); st.add_vertex(tip_pts[2])
	st.add_vertex(tip_pts[0]); st.add_vertex(tip_pts[2]); st.add_vertex(tip_pts[3])
	st.generate_normals()
	return st.commit()

## Procedural solid tapered block mesh (frustum/prism) for front facet mounting hardware.
## Snaps to front facet (w_base, h_base) at y=0 and tapers forward to (w_tip, h_tip) at y=depth.
static func _build_frustum_block_mesh(w_base: float, h_base: float, w_tip: float, h_tip: float, depth: float) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var hw0 = w_base * 0.5
	var hh0 = h_base * 0.5
	var hw1 = w_tip * 0.5
	var hh1 = h_tip * 0.5

	# Base vertices (at y = 0)
	var b0 = Vector3(-hw0, 0.0, -hh0)
	var b1 = Vector3( hw0, 0.0, -hh0)
	var b2 = Vector3( hw0, 0.0,  hh0)
	var b3 = Vector3(-hw0, 0.0,  hh0)

	# Tip vertices (at y = depth)
	var t0 = Vector3(-hw1, depth, -hh1)
	var t1 = Vector3( hw1, depth, -hh1)
	var t2 = Vector3( hw1, depth,  hh1)
	var t3 = Vector3(-hw1, depth,  hh1)

	# 4 Tapered Side Quads
	# Bottom face (-Z side)
	st.add_vertex(b0); st.add_vertex(t1); st.add_vertex(b1)
	st.add_vertex(b0); st.add_vertex(t0); st.add_vertex(t1)

	# Right face (+X side)
	st.add_vertex(b1); st.add_vertex(t2); st.add_vertex(b2)
	st.add_vertex(b1); st.add_vertex(t1); st.add_vertex(t2)

	# Top face (+Z side)
	st.add_vertex(b2); st.add_vertex(t3); st.add_vertex(b3)
	st.add_vertex(b2); st.add_vertex(t2); st.add_vertex(t3)

	# Left face (-X side)
	st.add_vertex(b3); st.add_vertex(t0); st.add_vertex(b0)
	st.add_vertex(b3); st.add_vertex(t3); st.add_vertex(t0)

	# Tip / Front face (at y = depth)
	st.add_vertex(t0); st.add_vertex(t2); st.add_vertex(t1)
	st.add_vertex(t0); st.add_vertex(t3); st.add_vertex(t2)

	# Base / Back face (at y = 0)
	st.add_vertex(b0); st.add_vertex(b1); st.add_vertex(b2)
	st.add_vertex(b0); st.add_vertex(b2); st.add_vertex(b3)

	st.generate_normals()
	return st.commit()


# 3-blade tractor/pusher fan, wrapped under a "PropBlades" pivot so it can
# spin (about local Z, matching the rotate_z fan arrangement below)
# independently of the (static) hub.
static func _attach_propeller_blades(parent_node: Node3D, base_size: Vector3, base_color: Color, pusher: bool):
	var facing = 1.0 if pusher else -1.0
	var pivot = Node3D.new()
	pivot.name = PIVOT_PROP_BLADES
	pivot.position = Vector3(0, 0, facing * base_size.z * 0.55)
	parent_node.add_child(pivot)

	var blade_mat = StandardMaterial3D.new()
	blade_mat.albedo_color = Color.SILVER
	var blade_mesh = _build_tapered_blade_mesh(0.03, 0.14, 0.045, base_size.x * 0.9)
	for i in range(3):
		var blade = MeshInstance3D.new()
		blade.mesh = blade_mesh
		blade.material_override = blade_mat
		blade.rotate_z(i * (TAU / 3.0))
		pivot.add_child(blade)


# 6 radial paddle blades, wrapped under a "PropBlades" pivot so they can spin
# (about local X, matching the rotate_x fan arrangement below) independently
# of the (static) disc.
static func _attach_paddle_wheel_blades(parent_node: Node3D, base_size: Vector3, base_color: Color):
	var pivot = Node3D.new()
	pivot.name = PIVOT_PROP_BLADES
	parent_node.add_child(pivot)

	var paddle_mat = StandardMaterial3D.new()
	paddle_mat.albedo_color = base_color.darkened(0.35)
	for i in range(6):
		var paddle = MeshInstance3D.new()
		var paddle_box = BoxMesh.new()
		paddle_box.size = Vector3(base_size.y * 0.18, base_size.x * 0.35, base_size.z * 0.85)
		paddle.mesh = paddle_box
		paddle.material_override = paddle_mat
		paddle.rotation = Vector3(0, 0, PI / 2.0)
		paddle.rotate_x(i * (TAU / 6.0))
		pivot.add_child(paddle)


# 4 twisted (pitched) blades, wrapped under a "PropBlades" pivot so they can
# spin (about local Z, matching the rotate_z fan arrangement below)
# independently of the (static) hub.
static func _attach_ship_screw_blades(parent_node: Node3D, base_size: Vector3):
	var pivot = Node3D.new()
	pivot.name = PIVOT_PROP_BLADES
	parent_node.add_child(pivot)

	var blade_mat = StandardMaterial3D.new()
	blade_mat.albedo_color = Color.SILVER
	var blade_mesh = _build_tapered_blade_mesh(0.025, base_size.x * 0.38, base_size.x * 0.12, base_size.x * 0.55)
	for i in range(4):
		var blade = MeshInstance3D.new()
		blade.mesh = blade_mesh
		blade.material_override = blade_mat
		blade.rotation.x = 0.5
		blade.rotate_z(i * (TAU / 4.0))
		pivot.add_child(blade)


# Procedural mount hardware (post + bolted base plate) was removed
# 2026-07-21: authored module meshes now bring their own baked-in mounting
# post/base (see build_visual()'s monolithic-mesh path), and
# module_placer.gd flush-rotates the whole module to the surface normal
# instead of extruding it outward along a separate column axis - see
# MOUNTING_AND_ARMOR_SPEC.md addendum. A weapon type still on the
# procedural-primitive fallback path (no authored .glb yet) simply has no
# extra mount geometry drawn until it gets one.
#
# THAT RULE STILL HOLDS, and _sponson_blister() below does not break it.
# What was deleted drew a COLUMN and a BASE PLATE - a second mounting post
# underneath a mesh that already had one baked in. The blister draws neither.
# It is a HOUSING around the point where an embedded weapon's barrel leaves
# the hull; the weapon's own post is inside the hull, unseen and unduplicated.
# If you are ever tempted to add a post, hub or base plate to that function,
# that is the moment it becomes the thing that was removed.

const SPONSON_BLISTER_PART := "sponson_blister"
const SPONSON_BLISTER_NODE := "SponsonBlister"
# sponson_blister.glb's authored height, base at Y=0 (build_meshes.py's
# build_sponson_blister default). Needed to re-centre it on the barrel axis;
# keep in step if the mesh is re-authored taller or shorter.
const SPONSON_BLISTER_AUTHORED_HEIGHT := 0.4
# Neutral armour-plate grey. Not the weapon's own base_color - the housing is
# hull, and tinting it to match the gun would undo that read.
const HULL_PLATE_COLOR := Color(0.34, 0.35, 0.36)

# The armoured housing an embedded weapon fires out through. Called from
# build_visual() (NOT from the placer) because build_visual() destroys every
# non-StaticBody3D child on entry - anything bolted on afterwards is wiped by
# the next tweak-slider drag, blueprint reconstruct, or drag-reclassify.
# Building it here means all four rebuild paths get it for free.
#
# MATERIAL, and this is a deliberate departure from _hardware(): the blister
# reads as a piece of hull, not as a fastener, so it must NOT carry
# HARDWARE_PREFIX (that prefix is the EXEMPTION that keeps bolts bare steel -
# module_placer.gd:1028) and must not take _hardware_mat(). It uses the shared
# "painted" role material, the same one _structural_body_mat() uses, for the
# same reason given there: the Design Lab repaints structural pieces with the
# faction hull shader but blueprint_manager's battle reconstruction does not,
# so the role palette is what actually gets worn on the field. Going through
# the shared palette also keeps bake_module_visual()'s material-identity merge
# working. Upgrading this to the true faction hull shader would need faction +
# armor material + texture world size plumbed into a static builder that has
# no hull reference at first-placement time; the role material is consistent
# everywhere instead of correct in one path and wrong in another.
# How much barrel must stick out past the hull skin. Below this a stubby
# weapon reads as swallowed by its own housing rather than mounted in it.
const SPONSON_MIN_PROTRUSION := 0.30
# Floor on the embed, so a weapon with almost no reach is still recessed
# enough for the housing to have something to sit against.
const SPONSON_MIN_EMBED := 0.10

# Embed depth, barrel-axis height and wrap radius for one module, MEASURED off
# its actual built geometry rather than guessed from catalog numbers.
#
# Three things this fixes that the catalog cannot answer:
#   * where the barrel actually is vertically. The housing has to wrap the
#     BARREL; sitting it at the module's base put it round the gun's feet.
#   * whether the barrel still protrudes after embedding. A stubby weapon
#     embedded by a flat fraction of its catalog depth disappeared into the
#     hull entirely, which is what "make it protrude even for stubby barrels"
#     is about - the embed is now capped by the weapon's own reach.
#   * how wide the housing has to be to wrap what is actually there, tweaks
#     and all, rather than the untweaked catalog size.
#
# Deterministic for a given module, so the placer and the blister builder can
# both call it and cannot drift. The blister node itself is excluded from the
# measurement or it would grow every rebuild.
static func sponson_geometry_for(module: Node3D, type_id: String) -> Dictionary:
	var catalog = preload("res://scripts/module_catalog.gd")
	var fallback := {
		"embed": catalog.get_sponson_embed_depth(type_id),
		"axis_y": catalog.get_module_data(type_id).get("size", Vector3.ONE).y * 0.5,
		"scale": catalog.get_sponson_blister_scale(type_id),
	}
	if module == null or not is_instance_valid(module):
		return fallback
	var existing = module.get_node_or_null(SPONSON_BLISTER_NODE)
	if existing:
		module.remove_child(existing)
	var bounds := measure_visual_bounds(module)
	if existing:
		module.add_child(existing)
		existing.name = SPONSON_BLISTER_NODE
	if bounds.size.length_squared() < 0.000001:
		return fallback

	# -Z is the muzzle axis, so the barrel's reach is how far the geometry
	# extends in -Z from the module origin.
	var reach: float = maxf(0.0, -bounds.position.z)
	var wanted: float = catalog.get_sponson_embed_depth(type_id)
	var embed: float = clampf(minf(wanted, reach - SPONSON_MIN_PROTRUSION),
		SPONSON_MIN_EMBED, catalog.SPONSON_EMBED_MAX)
	# Barrel axis height: the vertical middle of what is actually built.
	var axis_y: float = bounds.position.y + bounds.size.y * 0.5
	# Wrap the larger of the two cross-section axes, with headroom, so the
	# housing encloses the barrel instead of intersecting it.
	var wrap: float = maxf(bounds.size.x, bounds.size.y) * catalog.SPONSON_BLISTER_COVER
	return {
		"embed": embed,
		"axis_y": axis_y,
		"scale": clampf(wrap, catalog.SPONSON_BLISTER_MIN, catalog.SPONSON_BLISTER_MAX),
	}

static func _sponson_blister(parent_node: Node3D, type_id: String) -> MeshInstance3D:
	var mesh = _part(SPONSON_BLISTER_PART)
	if mesh == null:
		return null
	var inst = MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = PartMaterialsScript.get_material("painted", HULL_PLATE_COLOR)
	var geo := sponson_geometry_for(parent_node, type_id)
	var depth: float = geo["embed"]
	var blister_scale: float = geo["scale"]
	var axis_y: float = geo["axis_y"]
	# Cached so module_placer can offset the module by the SAME embed without
	# re-deriving it - one number, two readers, no drift between the hole and
	# the thing covering it.
	parent_node.set_meta("sponson_embed", depth)
	# The module origin is buried `depth` inside the hull; the housing belongs
	# back out at the skin. -Z is the muzzle axis, so that is -depth on Z.
	#
	# Then the yaw is cancelled. The blister is welded to the hull face while
	# the gun spins on it, so BOTH its rotation and its offset have to be
	# counter-rotated - rotating alone would leave it orbiting the module
	# origin and swinging round to a different part of the hull at 90 degrees.
	inst.transform = _sponson_blister_transform(parent_node.get_meta("yaw_offset", 0.0),
		depth, blister_scale, axis_y)
	parent_node.add_child(inst)
	# Named after add_child for the same Godot 4 reason _hardware() documents:
	# a colliding name set before parenting is discarded outright.
	inst.name = SPONSON_BLISTER_NODE
	return inst

static func _sponson_blister_transform(yaw: float, depth: float, blister_scale: float,
									   axis_y: float) -> Transform3D:
	var counter := Basis(Vector3.UP, -yaw)
	# sponson_blister.glb is authored base-at-Y=0 per the house convention, so
	# drop it by half its scaled height to centre it on the barrel axis rather
	# than stand it on the module's base. Standing it on the base is what left
	# the housing sitting too low, under the barrel instead of around it.
	var lift := axis_y - blister_scale * SPONSON_BLISTER_AUTHORED_HEIGHT * 0.5
	# Y is NOT counter-rotated: the yaw cancellation is about the vertical
	# axis, so height is unaffected by it, but the in-plane offset must be.
	return Transform3D(counter.scaled(Vector3.ONE * blister_scale),
		counter * Vector3(0, 0, -depth) + Vector3(0, lift, 0))

# Re-applies the blister's yaw cancellation without rebuilding the whole
# module. rotate_selected_module() and the gizmo's rotate ring change
# yaw_offset without going through build_visual() - the ring does it every
# frame of a drag, where a full rebuild would be wasteful - so the housing
# would otherwise swing around the hull with the gun instead of staying
# welded to the face it covers. No-ops on any module without a blister.
static func refresh_sponson_blister(module: Node3D) -> void:
	if module == null or not is_instance_valid(module):
		return
	var inst = module.get_node_or_null(SPONSON_BLISTER_NODE)
	if inst == null:
		return
	var data = module.get_meta("module_data", null)
	if data == null:
		return
	var geo := sponson_geometry_for(module, data.type_id)
	inst.transform = _sponson_blister_transform(
		module.get_meta("yaw_offset", 0.0),
		geo["embed"], geo["scale"], geo["axis_y"])

static func rebuild_visual(module: Node3D):
	if not module or not module.has_meta("module_data"): return
	var data = module.get_meta("module_data")
	var catalog_data = preload("res://scripts/module_catalog.gd").get_module_data(data.type_id)
	if catalog_data:
		var size: Vector3 = catalog_data.get("size", Vector3.ONE)
		# Structural pieces use SCALE ISOLATION, the same trick the hull uses
		# (gizmo_3d.gd's _apply_scale_to_node): their resize is carried as a
		# meta multiplier on the BASE SIZE and rebuilt here, rather than
		# written to the node's own `scale`. Scaling the node would drag the
		# fixed-size authored hardware along with it and smear every bolt
		# head, which is exactly what the parametric-body split exists to
		# avoid - the body has to be rebuilt at the new size so the detail
		# count can change instead.
		if module.has_meta("struct_scale"):
			var ss: Vector3 = module.get_meta("struct_scale")
			size = Vector3(size.x * ss.x, size.y * ss.y, size.z * ss.z)
		build_visual(data.type_id, module, size, catalog_data.color, data.tweaks)

# PERFORMANCE_PLAN.md P4: MODULAR_ASSEMBLY_TYPES modules (every weapon,
# every locomotion type, and the structural hull-extenders) build_visual()
# as many individually-instanced MeshInstance3Ds - up to ~9 for a 4-barrel
# cannon, more for multi-axle wheels - each with its own freshly-allocated
# StandardMaterial3D, none of it batchable. That's real in a battle instance
# (draw calls, per-node culling/AABB overhead) and pointless in the Design
# Lab, where those same nodes ARE the editable representation (gizmo drag
# handles, per-part tweak deformation all target them by name/index).
#
# Call this ONLY on a battle-spawned module (never a Design-Lab one - see
# blueprint_manager.gd's reconstruct_vehicle(), which gates this on
# `not is_designer`), after rebuild_visual() has built the module's real
# geometry. Merges this module's direct-child MeshInstance3D siblings into
# one baked MeshInstance3D per distinct material (SurfaceTool, grouped so a
# module with e.g. a metal pintle + a darker barrel still ends up as 2 draw
# calls, not 1 with the wrong color) - typically collapses 3-9 nodes down to
# 1-3. Named animation pivots (MONOLITHIC_ANIMATION_PIVOTS' values, plus the
# procedural equivalents the modular-assembly branches build under the same
# names - BarrelCluster, RotorBlades, WingPivot, PropBlades) are left
# untouched: those rotate independently every frame (auto_weapon.gd's
# rotary-cannon spin-up, unit.gd's rotor/prop animation) and merging
# them into a static mesh would freeze that motion.
# Single source of truth: every name here is one of the SPIN_PIVOT_*/
# BELT_BAND_NAME constants above (or a literal that unit.gd/module_placer.gd
# look up by the same string), so a builder and an animator can never again
# name the same node two different things and silently go dead. hover_engine's
# rings and the belt band mesh are the two that used to fall through here as
# bare literals and get merged away by the bake below - "HoverRingMid" and
# "HoverRingInner" specifically (not "HoverRingOuter", which never animates).
const _ANIMATED_PART_NAMES := [
	PIVOT_BARREL_CLUSTER, PIVOT_ROTOR_BLADES, PIVOT_WING, PIVOT_PROP_BLADES,
	BELT_BAND_NAME, HOVER_RING_MID, HOVER_RING_INNER,
]

static func bake_module_visual(module: Node3D) -> void:
	if not module:
		return
	# material_override -> Array[MeshInstance3D] sharing that exact material
	# resource. null is a valid dictionary key here (an unmaterialed part) and
	# groups correctly with other unmaterialed parts.
	var groups: Dictionary = {}
	var to_remove: Array = []
	for child in module.get_children():
		if not (child is MeshInstance3D):
			continue
		if child.name in _ANIMATED_PART_NAMES:
			continue
		if child.mesh == null:
			continue
		var mat = child.material_override
		if not groups.has(mat):
			groups[mat] = []
		groups[mat].append(child)
		to_remove.append(child)

	# Nothing to gain merging a single part (most monolithic-mesh modules hit
	# this - they're already one node) or an empty module.
	if to_remove.size() <= 1:
		return

	for mat in groups.keys():
		var parts: Array = groups[mat]
		var surface_tool = SurfaceTool.new()
		surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		for part in parts:
			# Iterate every surface, not just 0 - _mesh_inst() overrides the
			# WHOLE MeshInstance3D's material regardless of how many surfaces
			# its source mesh has, so a multi-surface authored part would
			# silently lose geometry merging only surface 0.
			for s in range(part.mesh.get_surface_count()):
				surface_tool.append_from(part.mesh, s, part.transform)
		surface_tool.generate_normals()
		var baked_inst = MeshInstance3D.new()
		baked_inst.name = "BakedVisual"
		baked_inst.mesh = _with_lods(surface_tool.commit())
		baked_inst.material_override = mat
		module.add_child(baked_inst)

	for part in to_remove:
		module.remove_child(part)
		part.queue_free()

	# The measured volume described the sub-parts that were just merged away.
	# Anything measuring after this gets the merged geometry instead - same
	# union, coarser subdivision - which is why blueprint_manager builds a
	# battle module's collision shapes BEFORE calling this.
	ModuleVolumeScript.invalidate(module)


# Regenerates level-of-detail data on a runtime-merged mesh.
#
# Every authored .glb imports with meshes/generate_lods=true, so a part drawn
# straight from the asset already sheds triangles at distance. SurfaceTool
# merging throws that away: commit() returns a plain ArrayMesh with a single
# LOD level, so a BAKED module - which is most of them, since a weapon is an
# assembly of six to ten parts - rendered its full density at every zoom. An
# autocannon is ~9k triangles across its parts, and an RTS draws a dozen
# vehicles carrying several modules each.
#
# ImporterMesh is the same simplifier the import pipeline uses, exposed at
# runtime. It is wrapped defensively because it is editor-adjacent API: if it
# is unavailable or throws, the un-LODded mesh is still perfectly correct,
# just as expensive as it was before.
static func _with_lods(mesh: ArrayMesh) -> ArrayMesh:
	if mesh == null or mesh.get_surface_count() == 0:
		return mesh
	var im := ImporterMesh.new()
	for s in range(mesh.get_surface_count()):
		im.add_surface(mesh.surface_get_primitive_type(s), mesh.surface_get_arrays(s),
			[], {}, mesh.surface_get_material(s), "", mesh.surface_get_format(s))
	# 25 deg merge / 60 deg split are the import defaults - the angles below
	# which the simplifier may weld normals, and above which it must keep a
	# hard edge. These meshes are hard-surface greebles, so preserving the
	# hard edges is what keeps a decimated breech from turning to mush.
	im.generate_lods(25.0, 60.0, [])
	var out := im.get_mesh()
	return out if out != null else mesh


# --- Tweak deformation for monolithic authored meshes ----------------------
#
# _apply_tweak_deformations() below reshapes a module by scaling individual
# sub-meshes of the procedural build (children[1] is the barrel, children[2]
# is the drum, and so on). A monolithic authored .glb has no sub-meshes - the
# whole module is one MeshInstance3D - and build_visual()'s monolithic branch
# returns before ever reaching that function. Since every module now ships an
# authored .glb, that made EVERY tweak slider in the Design Lab, and the
# gizmo's drag-to-tweak handles, visually inert: the stat readout moved (stats
# come from stat_calculator.gd, which was never affected) while the model on
# screen never changed.
#
# A single mesh can still express its tweaks by scaling along the axis the
# tweak is about, which is what this table encodes: which of the module's own
# axes each tweak stretches. Vector3 components are flags, not magnitudes -
# (1,1,0) means "this tweak fattens the cross-section", (0,0,1) means "this
# tweak extends it forward", (1,1,1) means "this tweak grows the whole part".
# The axis each tweak maps to matches what the procedural path already did to
# the corresponding sub-mesh, and what gizmo_3d.gd's get_tweak_for_axis()
# binds to the X and Z drag handles.
const MONOLITHIC_TWEAK_AXES := {
	"basic_cannon": {"caliber": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1)},
	"heavy_machine_gun": {"caliber": Vector3(1, 1, 0), "drum_size": Vector3(1, 1, 1)},
	"rotary_cannon": {"caliber": Vector3(1, 1, 0), "motor_size": Vector3(1, 1, 1)},
	"artillery": {"caliber": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1)},
	"guided_missile": {"seeker_size": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1)},
	"flamethrower": {"nozzle_width": Vector3(1, 1, 0), "pressure_valve": Vector3(1, 1, 1)},
	"heavy_laser": {"lens_aperture": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1), "focal_length": Vector3(0, 0, 1)},
	"plasma_lobber": {"containment": Vector3(1, 1, 1), "caliber": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1), "charge_rate": Vector3(0, 0, 1)},
	"ciws": {"caliber": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1), "radar_dish": Vector3(1, 1, 1), "burst_length": Vector3(0, 0, 1)},
	"pd_laser": {"cooling_jacket": Vector3(1, 1, 1), "barrel_length": Vector3(0, 0, 1), "tracking_speed": Vector3(1, 0, 0)},
	"flak_cannon": {"caliber": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1), "barrel_count": Vector3(1, 0, 0), "fuse_setting": Vector3(1, 1, 1), "burst_size": Vector3(0, 0, 1)},
	"drone_carrier": {"hangar_size": Vector3(1, 0, 0), "launch_catapult": Vector3(0, 0, 1)},
	"resource_harvester": {"cutter_head": Vector3(1, 1, 1), "extractor_size": Vector3(1, 1, 1), "mount_extension": Vector3(0, 1, 0)},
	# Which axis each bay tweak grows, for the footprint/clipping side. The
	# builder applies the same mapping to the meshes; this is what makes a
	# deeper hopper actually claim more deck height in the Lab, so "does a
	# third bay fit" is answered by the geometry rather than by a guess.
	"resource_bay": {"bay_volume": Vector3(1, 1, 1), "hopper_depth": Vector3(0, 1, 0), "hatch_width": Vector3(1, 0, 0)},
	"sensor_suite": {"mast_height": Vector3(0, 1, 0)},
	"cluster_dispenser": {"dispersion": Vector3(1, 0, 1), "payload_size": Vector3(1, 1, 1), "tube_count": Vector3(1, 0, 0)},
	"mortar_array": {"tube_count": Vector3(1, 0, 1)},
	"missile_pod": {"grid_size": Vector3(1, 0, 1), "warhead_size": Vector3(1, 1, 0), "motor_length": Vector3(0, 0, 1), "seeker_size": Vector3(1, 1, 0), "engine_length": Vector3(0, 0, 1)},
	"ion_cannon": {"lens_aperture": Vector3(1, 1, 0), "barrel_length": Vector3(0, 0, 1)},
}

# Per-axis multiplier for a monolithic mesh, expressed in MESH-local axes.
#
# The table above is written in the module's own frame (x = width,
# y = height, z = forward), but the authored mesh is mounted with a yaw offset
# to correct TripoSG's native orientation, and Godot composes a node's basis
# as rotation * scale - so a scale assigned to the node is applied along mesh
# axes and only then rotated. The multiplier therefore has to be permuted back
# through that rotation, otherwise "lengthen the barrel" would fatten the gun
# sideways instead.
static func _monolithic_tweak_scale(type_id: String, tweaks: Dictionary, mesh_rotation: Vector3) -> Vector3:
	if tweaks.is_empty() or not MONOLITHIC_TWEAK_AXES.has(type_id):
		return Vector3.ONE
	var module_space = Vector3.ONE
	for tweak_name in MONOLITHIC_TWEAK_AXES[type_id]:
		if not tweaks.has(tweak_name):
			continue
		var value = float(tweaks[tweak_name])
		if value <= 0.0:
			continue
		var axes: Vector3 = MONOLITHIC_TWEAK_AXES[type_id][tweak_name]
		# Flag set -> this tweak scales that axis; flag clear -> leave it be.
		module_space *= Vector3(
			value if axes.x > 0.5 else 1.0,
			value if axes.y > 0.5 else 1.0,
			value if axes.z > 0.5 else 1.0)
	return (Basis.from_euler(mesh_rotation).transposed() * module_space).abs()

# Propulsion modules (speed pass, 2026-08-08): one call per type_id, each
# piece scaled ONLY by the tweak that names it - the rule the roster
# expansion weapons above already follow (barrel_length stretches the tube,
# never the breech). Parts are authored .glb files when present
# (tools/blender/build_meshes.py's "Propulsion module parts" section) and
# Rocket Booster assembly: frame + scaled booster tubes
static func _build_booster_rack(parent_node: Node3D, base_color: Color, tweaks: Dictionary) -> void:
	var nozzles = int(tweaks.get("nozzle_count", 3.0))
	var tube_length = float(tweaks.get("booster_length", tweaks.get("motor_length", 1.0)))
	var tube_width = float(tweaks.get("booster_width", tweaks.get("tube_diameter", 1.0)))

	var frame_mesh = _part("booster_rack_frame")
	var frame_scale_x = maxf(1.0, float(nozzles) / 3.0 * tube_width)
	if frame_mesh:
		var frame = _mesh_inst(frame_mesh, base_color.darkened(0.2))
		frame.scale = Vector3(frame_scale_x, 1.0, 1.0)
		frame.position = Vector3(0, 0.06, 0)
		parent_node.add_child(frame)
	else:
		var frame = MeshInstance3D.new()
		var fr_box = BoxMesh.new()
		fr_box.size = Vector3(0.85 * frame_scale_x, 0.12, 0.5)
		frame.mesh = fr_box
		frame.material_override = _flat_mat(base_color.darkened(0.2))
		frame.position = Vector3(0, 0.06, 0)
		parent_node.add_child(frame)

	var tube_mesh = _part("booster_tube")
	var rack_span: float = 0.85 * frame_scale_x
	var spacing: float = rack_span / max(nozzles, 1)
	var start_x: float = -rack_span / 2.0 + spacing / 2.0
	for i in range(max(nozzles, 1)):
		var tx: float = start_x + i * spacing
		var tube: MeshInstance3D
		if tube_mesh:
			tube = _mesh_inst(tube_mesh, base_color.darkened(0.35))
			tube.scale = Vector3(tube_width, tube_length, tube_width)
		else:
			tube = MeshInstance3D.new()
			var tb_cyl = CylinderMesh.new()
			tb_cyl.top_radius = 0.09 * tube_width
			tb_cyl.bottom_radius = 0.09 * tube_width
			tb_cyl.height = 0.7 * tube_length
			tube.mesh = tb_cyl
			tube.material_override = _flat_mat(base_color.darkened(0.35))
		tube.position = Vector3(tx, 0.12, 0.25)
		tube.rotation = Vector3(PI / 2, 0, 0)
		parent_node.add_child(tube)

static func _apply_tweak_deformations(type_id: String, parent: Node3D, tweaks: Dictionary, base_size: Vector3):
	var children = parent.get_children().filter(func(c): return c is MeshInstance3D)
	if children.is_empty(): return

	match type_id:
		"basic_cannon", "heavy_machine_gun", "rotary_cannon", "gauss_railgun", "artillery", "mortar_array", "guided_missile", "missile_pod", "cluster_dispenser", "flamethrower", "ion_cannon", "heavy_laser", "laser_cannon", "plasma_lobber", "plasma_launcher", "ciws", "pd_laser", "point_defense_laser", "flak_cannon", "flak_battery", "drone_carrier", "resource_harvester", "repair_array", "sensor_suite", "smoke_discharger", "mk19_grenade_launcher", "recoilless_rifle", "coil_gun", "autocannon", 		"napalm_mortar", "mine_layer", "anti_materiel_rifle", "arc_projector", "microwave_emitter", "particle_lance", "spigot_mortar", "rocket_artillery", "hypervelocity_missile", "sam_launcher", "loitering_munition", "anti_radiation_missile", "bunker_buster", "cruise_missile", "aa_autocannon", "sensor_beacon_launcher", "booster_rack":
			return

# Builds a wedge (triangular prism) mesh from a base_size Vector3.
# The wedge has a flat base (full width X and depth Z) that tapers to a
# ridge along the top centerline (Y-direction apex). This is a simple
# ArrayMesh with 5 faces: base, back, and two sloped sides, + 2 end caps.
# Fraction of the piece's depth taken up by the flat top deck at the back.
# The rest is the sloped glacis. Zero here would give a knife edge, which is
# not a thing anyone fabricates out of armour plate.
const WEDGE_DECK_FRACTION := 0.30

static func _build_wedge_mesh(size: Vector3) -> ArrayMesh:
	# A REAL wedge. What was here before declared eight vertices and then put
	# the top four at the full size on all axes - i.e. it built a plain box,
	# with comments describing an "apex" and a "top ridge" that the geometry
	# never had. "Wedge Breech" has therefore always rendered as a rectangular
	# block indistinguishable from Structure Block.
	#
	# Shape: bottom rectangle, a glacis rising from the FRONT edge (-Z, which
	# is forward everywhere in this codebase) to a knuckle, then a flat deck
	# running back from the knuckle to the rear face.
	#
	# Flat-shaded, not smooth-normal averaged: this is folded plate, and
	# averaging normals across the knuckle rounded the fold into a soft blob
	# and darkened the deck (which is what made the old box look hollow).
	var hw = size.x / 2.0
	var h = size.y
	var hd = size.z / 2.0
	var zk = -hd + size.z * (1.0 - WEDGE_DECK_FRACTION)

	var p_bfl = Vector3(-hw, 0, -hd)  # bottom front left
	var p_bfr = Vector3( hw, 0, -hd)
	var p_brl = Vector3(-hw, 0,  hd)  # bottom rear left
	var p_brr = Vector3( hw, 0,  hd)
	var p_kl  = Vector3(-hw, h, zk)   # knuckle (top of the glacis)
	var p_kr  = Vector3( hw, h, zk)
	var p_trl = Vector3(-hw, h,  hd)  # top rear
	var p_trr = Vector3( hw, h,  hd)

	var verts = PackedVector3Array()
	var normals = PackedVector3Array()

	# Each quad emitted as two triangles with one shared face normal.
	var quads = [
		[p_bfl, p_brl, p_brr, p_bfr],  # bottom
		[p_bfl, p_bfr, p_kr,  p_kl],   # glacis
		[p_kl,  p_kr,  p_trr, p_trl],  # top deck
		[p_brl, p_trl, p_trr, p_brr],  # rear face
		[p_bfl, p_kl,  p_trl, p_brl],  # left flank
		[p_bfr, p_brr, p_trr, p_kr],   # right flank
	]
	for q in quads:
		var n = (q[1] - q[0]).cross(q[2] - q[0]).normalized()
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for idx in tri:
				verts.append(q[idx])
				normals.append(n)

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Where the glacis surface sits at depth fraction `t` (0 = front edge, 1 =
# knuckle). Used to lay step cleats onto the actual slope instead of guessing
# at a diagonal, and to pitch them to match it.
static func _wedge_slope_point(size: Vector3, t: float) -> Vector3:
	var hd = size.z / 2.0
	var zk = -hd + size.z * (1.0 - WEDGE_DECK_FRACTION)
	return Vector3(0, size.y * t, lerp(-hd, zk, t))

static func _wedge_slope_pitch(size: Vector3) -> float:
	var run = size.z * (1.0 - WEDGE_DECK_FRACTION)
	return atan2(size.y, max(0.001, run))

# ===========================================================================
# LOCOMOTION EXPANSION BUILDERS (LOCOMOTION_EXPANSION_PLAN.md 4)
#
# Each is a straight assembly of authored parts. Placement of the module as a
# whole is locomotion_layout.gd's job - these only decide where a type's own
# sub-parts sit relative to its mount point, and which of them a tweak scales.
#
# The rule the rest of the roster follows and these keep: a tweak scales the
# PART it is about and nothing else, so a slider can never smear a bolt head.
# ===========================================================================

## Half-track: steered wheels forward, a short track bogie aft. The two ends
## are separate parts because bogie_count and front_axle_size move
## independently - the whole pitch of the type is that its two halves are
## different machines bolted to one frame.
static func _build_half_track(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DARK_OLIVE_GREEN, tweaks: Dictionary = {}):
	var bogies := int(tweaks.get("bogie_count", 3.0))
	var front_size := float(tweaks.get("front_axle_size", 1.0))
	var width := float(tweaks.get("tread_width", 1.0))
	var target_length := float(tweaks.get("target_length", base_size.z))
	var half := target_length * 0.5

	const AUTHORED_LOOP_DEPTH := 0.430881
	const AUTHORED_WHEEL_DIAM := 0.936
	var depth: float = target_length * 0.22
	var v_scale: float = depth / AUTHORED_LOOP_DEPTH

	var station := MountReachScript.station_from(tweaks)
	var node_scale := MountReachScript.node_scale_from(tweaks)

	# 1. Front Steered Wheel (uses the exact same Wheel Hub mesh & mount as Wheel drive)
	var wheel_mesh := _part("wheel_hub")
	var gb_mesh := _part("wheel_gearbox")
	var ds_mesh := _part("wheel_driveshaft")

	# Scale wheel so its diameter matches the track bogie height
	var wheel_s: float = (depth / AUTHORED_WHEEL_DIAM) * front_size
	var wheel_radius: float = 0.468 * wheel_s
	var front_wheel_z: float = -half + wheel_radius * 1.5

	if wheel_mesh:
		var axle_pivot := Node3D.new()
		axle_pivot.name = SPIN_PIVOT_WHEEL
		axle_pivot.position = Vector3(0.0, 0.0, front_wheel_z)
		parent_node.add_child(axle_pivot)

		var wheel := _mesh_inst(wheel_mesh, Color(0.1, 0.1, 0.12))
		wheel.scale = Vector3(wheel_s, wheel_s, wheel_s)
		wheel.rotation = Vector3(0, 0, -PI / 2.0)
		axle_pivot.add_child(wheel)

		# Sturdy steering knuckle / gearbox affixed to inboard face of wheel hub
		var front_gb_x: float = -0.18 * wheel_s
		var gb_dim: float = 0.44 * wheel_s
		if gb_mesh:
			var front_gb := _mesh_inst(gb_mesh, base_color.darkened(0.1).lightened(0.3))
			front_gb.scale = Vector3(gb_dim, gb_dim, gb_dim)
			front_gb.position = Vector3(front_gb_x, 0.0, front_wheel_z)
			parent_node.add_child(front_gb)

		var front_reach := MountReachScript.solve(parent_node, station, Vector3(front_gb_x, 0.0, front_wheel_z), Vector3.LEFT, -1.0, node_scale, 0.0)
		var front_touches_skin := (front_reach > 0.0 and front_reach <= gb_dim + 0.05)

		if ds_mesh and not front_touches_skin:
			var shaft_angle := deg_to_rad(45.0)
			var shaft_dir := Vector3(-cos(shaft_angle), sin(shaft_angle), 0.0)
			var bottom_target := Vector3(front_gb_x - 0.5 * gb_dim, 0.0, front_wheel_z)
			var shaft_len := MountReachScript.solve(parent_node, station, bottom_target, shaft_dir, 1.2 * wheel_s, node_scale)
			if shaft_len > 0.0:
				var shaft := _mesh_inst(ds_mesh, base_color.darkened(0.25).lightened(0.35))
				var top_pos := bottom_target + shaft_dir * shaft_len
				var up_vec := shaft_dir
				var side_vec := up_vec.cross(Vector3.FORWARD).normalized()
				if side_vec.length_squared() < 0.001:
					side_vec = Vector3.RIGHT
				var fwd_vec := side_vec.cross(up_vec).normalized()
				var shaft_thickness: float = 0.28 * wheel_s
				shaft.transform = Transform3D(
					Basis(side_vec * shaft_thickness, up_vec * shaft_len, fwd_vec * shaft_thickness),
					top_pos
				)
				parent_node.add_child(shaft)

	# 2. Track Bogie Portion
	var bogie_mesh := _part("ht_track_bogie")
	if bogie_mesh:
		var run: float = target_length * 0.50 * (1.0 + 0.14 * float(bogies - 3))
		# NOT named SPIN_PIVOT_TREAD: this used to be the rotate_x pivot for the
		# WHOLE bogie assembly, tumbling it end-over-end. The bogie mesh is the
		# belt band now - it gets a scrolling-UV shader material instead of a
		# rotation, so this stays a plain static mount node.
		var bogie_pivot := Node3D.new()
		bogie_pivot.name = "TrackBogieMount"
		bogie_pivot.position = Vector3(0, 0, half - run * 0.5)
		parent_node.add_child(bogie_pivot)

		var bogie := _mesh_inst(bogie_mesh, Color(0.18, 0.18, 0.2))
		bogie.name = BELT_BAND_NAME
		bogie.material_override = _belt_material(Color(0.18, 0.18, 0.2))
		# 20% narrower track width (1.24 factor instead of 1.55)
		var bogie_width_scale: float = width * v_scale * 1.24
		bogie.scale = Vector3(bogie_width_scale, v_scale, run / 1.2)
		bogie_pivot.add_child(bogie)

		# 3. Bulky, Sturdy Mounting Gear Affixed Directly to Track Inner Spine
		var n: int = maxi(2, bogies)
		var inner_spine_x: float = -0.025 * bogie_width_scale
		var gb_sz: float = 0.36 * depth

		for i in range(n):
			var t: float = (float(i) + 0.5) / float(n)
			var z_station: float = half - run * t

			# Gearbox / mounting bracket seated directly against inner frame of track
			var bogie_gb_x: float = inner_spine_x - 0.5 * gb_sz
			if gb_mesh:
				var bogie_gb := _mesh_inst(gb_mesh, base_color.darkened(0.15).lightened(0.25))
				bogie_gb.scale = Vector3(gb_sz, gb_sz, gb_sz * 1.2)
				bogie_gb.position = Vector3(bogie_gb_x, 0.0, z_station)
				parent_node.add_child(bogie_gb)

			# Check if gearbox is already touching the hull skin
			var gb_reach := MountReachScript.solve(parent_node, station, Vector3(inner_spine_x, 0.0, z_station), Vector3.LEFT, -1.0, node_scale, 0.0)
			var gb_touches_skin := (gb_reach > 0.0 and gb_reach <= gb_sz + 0.05)

			# Only extend driveshaft if gearbox is not already in direct contact with skin
			if ds_mesh and not gb_touches_skin:
				var c_dirs: Array[Vector3] = [
					Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0),
					Vector3(-cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)), 0.0),
					Vector3(-cos(deg_to_rad(15.0)), sin(deg_to_rad(15.0)), 0.0),
					Vector3(-1.0, 0.0, 0.0)
				]
				var start_pt := Vector3(bogie_gb_x - 0.5 * gb_sz, 0.0, z_station)
				var best_dir := Vector3.ZERO
				var best_len := -1.0
				for cd in c_dirs:
					var l := MountReachScript.solve(parent_node, station, start_pt, cd, -1.0, node_scale)
					if l > 0.0:
						best_dir = cd
						best_len = l
						break

				if best_len > 0.0:
					var strut := _mesh_inst(ds_mesh, base_color.darkened(0.3).lightened(0.3))
					var top_p := start_pt + best_dir * best_len
					var up_v := best_dir
					var side_v := up_v.cross(Vector3.FORWARD).normalized()
					if side_v.length_squared() < 0.001:
						side_v = Vector3.RIGHT
					var fwd_v := side_v.cross(up_v).normalized()
					var strut_thick: float = 0.30 * depth
					strut.transform = Transform3D(
						Basis(side_v * strut_thick, up_v * best_len, fwd_v * strut_thick),
						top_p
					)
					parent_node.add_child(strut)


## Heavy Quad Tracks: 4 articulated track pods (2 per side).
## Front sprocket pinned 1 radius in from front corner, covering 35% hull length.
## Rear sprocket pinned 1 radius in from rear corner, covering 35% hull length.
static func _build_heavy_quad_tracks(parent_node: Node3D, base_size: Vector3, base_color: Color = Color.DARK_SLATE_GRAY, tweaks: Dictionary = {}):
	var width := float(tweaks.get("tread_width", 1.0))
	var target_length := float(tweaks.get("target_length", base_size.z))
	var half := target_length * 0.5

	var total_count: int = int(tweaks.get("track_count", tweaks.get("pod_count", 4)))
	var per_side: int = maxi(2, int(total_count / 2))

	const AUTHORED_LOOP_DEPTH := 0.430881
	var depth: float = target_length * 0.20
	var v_scale: float = depth / AUTHORED_LOOP_DEPTH
	var bogie_width_scale: float = width * v_scale * 1.24
	var sprocket_radius: float = depth * 0.5

	# Pod length scales dynamically based on count (35% for 4 tracks, 25% for 6 tracks)
	var pod_len_frac: float = 0.35 if per_side == 2 else clampf(0.75 / float(per_side), 0.18, 0.35)
	var pod_length: float = target_length * pod_len_frac

	var station := MountReachScript.station_from(tweaks)
	var node_scale := MountReachScript.node_scale_from(tweaks)

	# Front Pod: front sprocket pinned 1 radius in from front corner
	var front_sprocket_z: float = -half + sprocket_radius
	var front_pod_center_z: float = front_sprocket_z + 0.5 * pod_length

	# Rear Pod: rear sprocket pinned 1 radius in from rear corner
	var rear_sprocket_z: float = half - sprocket_radius
	var rear_pod_center_z: float = rear_sprocket_z - 0.5 * pod_length

	var bogie_mesh := _part("ht_track_bogie")
	var gb_mesh := _part("wheel_gearbox")
	var ds_mesh := _part("wheel_driveshaft")
	var inner_spine_x: float = -0.025 * bogie_width_scale
	var gb_sz: float = 0.36 * depth

	var pods: Array[Dictionary] = []
	for i in range(per_side):
		var t: float = float(i) / float(per_side - 1)
		var cz: float = lerpf(front_pod_center_z, rear_pod_center_z, t)
		pods.append({
			# NOT named SPIN_PIVOT_TREAD, deliberately - same reasoning as
			# half_track's TrackBogieMount (see _build_half_track above): the
			# bogie mesh under this pivot is BELT_BAND_NAME, animated by
			# scrolling its shader's uv_offset. If this mount pivot matched
			# SPIN_PIVOT_TREAD, unit.gd would ALSO rotate_x() it every frame,
			# physically tumbling the whole pod on top of its own UV-scroll -
			# reintroducing the exact end-over-end bug the belt rewrite
			# replaced. The old literal "SpinPivot_Tread_%d" never matched
			# unit.gd's "TreadSpin*" search anyway (harmless coincidence, not
			# by design) - renamed to make the non-participation explicit.
			"name": "TrackPodMount_%d" % i,
			"center_z": cz
		})

	for pod_info in pods:
		var z_center: float = pod_info["center_z"]
		if bogie_mesh:
			var bogie_pivot := Node3D.new()
			bogie_pivot.name = pod_info["name"]
			bogie_pivot.position = Vector3(0, 0, z_center)
			parent_node.add_child(bogie_pivot)

			var bogie := _mesh_inst(bogie_mesh, Color(0.18, 0.18, 0.2))
			bogie.name = BELT_BAND_NAME
			bogie.material_override = _belt_material(Color(0.18, 0.18, 0.2))
			bogie.scale = Vector3(bogie_width_scale, v_scale, pod_length / 1.2)
			bogie_pivot.add_child(bogie)

		# 2 Mounting Gearboxes & Struts per pod (fore & aft of the pod)
		for z_offset_frac in [-0.32, 0.32]:
			var z_station: float = z_center + z_offset_frac * pod_length
			var bogie_gb_x: float = inner_spine_x - 0.5 * gb_sz
			if gb_mesh:
				var bogie_gb := _mesh_inst(gb_mesh, base_color.darkened(0.15).lightened(0.25))
				bogie_gb.scale = Vector3(gb_sz, gb_sz, gb_sz * 1.2)
				bogie_gb.position = Vector3(bogie_gb_x, 0.0, z_station)
				parent_node.add_child(bogie_gb)

			var gb_reach := MountReachScript.solve(parent_node, station, Vector3(inner_spine_x, 0.0, z_station), Vector3.LEFT, -1.0, node_scale, 0.0)
			var gb_touches_skin := (gb_reach > 0.0 and gb_reach <= gb_sz + 0.05)

			if ds_mesh and not gb_touches_skin:
				var c_dirs: Array[Vector3] = [
					Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0),
					Vector3(-cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)), 0.0),
					Vector3(-cos(deg_to_rad(15.0)), sin(deg_to_rad(15.0)), 0.0),
					Vector3(-1.0, 0.0, 0.0)
				]
				var start_pt := Vector3(bogie_gb_x - 0.5 * gb_sz, 0.0, z_station)
				var best_dir := Vector3.ZERO
				var best_len := -1.0
				for cd in c_dirs:
					var l := MountReachScript.solve(parent_node, station, start_pt, cd, -1.0, node_scale)
					if l > 0.0:
						best_dir = cd
						best_len = l
						break

				if best_len <= 0.0:
					best_dir = Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0)
					best_len = 0.5 * depth

				var strut := _mesh_inst(ds_mesh, base_color.darkened(0.3).lightened(0.3))
				var top_p := start_pt + best_dir * best_len
				var up_v := best_dir
				var side_v := up_v.cross(Vector3.FORWARD).normalized()
				if side_v.length_squared() < 0.001:
					side_v = Vector3.RIGHT
				var fwd_v := side_v.cross(up_v).normalized()
				var strut_thick: float = 0.30 * depth
				strut.transform = Transform3D(
					Basis(side_v * strut_thick, up_v * best_len, fwd_v * strut_thick),
					top_p
				)
				parent_node.add_child(strut)


## Rocker-bogie: a free-pivoting arm chain. Built as a real linkage - primary
## rocker, secondary bogie, wheels at the knuckles - because the articulation
## IS the silhouette, and a rigid axle would read as a normal wheeled chassis.
static func _build_rocker_bogie(parent_node: Node3D, base_size: Vector3, base_color: Color = Color(0.42, 0.38, 0.30), tweaks: Dictionary = {}):
	var pairs := int(tweaks.get("bogie_pairs", 3.0))
	var arm_len := float(tweaks.get("arm_length", 1.0))
	var wheel_size := float(tweaks.get("wheel_size", 1.0))
	var target_length := float(tweaks.get("target_length", base_size.z))
	var span := target_length * 0.42

	const AUTHORED_ARM_Z := 0.83
	var z_s: float = maxf(0.4, (span * 2.0) / AUTHORED_ARM_Z)
	var p_s: float = clampf(z_s * 0.42, 0.85, 1.7)
	var v_scale: float = p_s

	var rocker_mesh := _part("rb_rocker_arm")
	var bogie_mesh := _part("rb_bogie_arm")
	var wheel_mesh := _part("rb_wheel")
	var gb_mesh := _part("wheel_gearbox")

	# Heavy differential trunnion mount connecting the rocker suspension to the hull
	const WHEEL_GROWTH := 2.0
	var pivot_s: float = 0.90 * v_scale
	var hub := build_wheel_mount(parent_node, base_color, pivot_s, 0.0, 0.55 * pivot_s, -1.0, tweaks)

	var chain := Node3D.new()
	chain.position = hub
	parent_node.add_child(chain)

	if rocker_mesh:
		var rocker := _mesh_inst(rocker_mesh, base_color)
		# Heavy forged cross-section for the primary rocker arm
		rocker.scale = Vector3(p_s * 2.2, arm_len * p_s * 1.5, z_s)
		chain.add_child(rocker)

	for i in range(pairs):
		var t: float = 0.5 if pairs <= 1 else float(i) / float(pairs - 1)
		var z: float = (-span + 2.0 * span * t)
		if bogie_mesh and i > 0:
			var bogie := _mesh_inst(bogie_mesh, base_color.darkened(0.08))
			# Heavy forged cross-section for the bogie arm
			bogie.scale = Vector3(p_s * 2.0, arm_len * p_s * 1.4, z_s * 0.48)
			bogie.position = Vector3(0, -0.08 * arm_len * v_scale, z)
			chain.add_child(bogie)
		if wheel_mesh:
			var wheel_pivot := Node3D.new()
			wheel_pivot.name = SPIN_PIVOT_WHEEL
			var wheel_scale: float = wheel_size * p_s * WHEEL_GROWTH
			wheel_pivot.position = Vector3(
				0.18 * wheel_size * p_s + 0.12 * wheel_scale,
				-0.10 * arm_len * p_s, z)
			chain.add_child(wheel_pivot)
			var wheel := _mesh_inst(wheel_mesh, Color(0.18, 0.18, 0.20))
			wheel.scale = Vector3.ONE * wheel_scale
			wheel_pivot.add_child(wheel)

			# Sturdy, heavy-duty hub carrier / axle gearbox
			if gb_mesh:
				var carrier := _mesh_inst(gb_mesh, base_color.lightened(0.2))
				var c_w: float = 0.35 * wheel_scale
				carrier.scale = Vector3(c_w, 0.32 * wheel_scale, 0.32 * wheel_scale)
				carrier.position = Vector3(
					0.18 * wheel_size * p_s,
					-0.10 * arm_len * p_s, z)
				chain.add_child(carrier)


## Air-cushion skirt: one continuous bag around the module's footprint, with
## the lift fans set into the sealed plenum deck above it.
static func _build_air_cushion_skirt(parent_node: Node3D, base_size: Vector3, base_color: Color = Color(0.55, 0.52, 0.42), tweaks: Dictionary = {}):
	var diameter := float(tweaks.get("skirt_diameter", 1.0))
	var fans := int(tweaks.get("lift_fan_count", 3.0))
	var plenum := float(tweaks.get("plenum_pressure", 1.0))
	# The hull's own plan dimensions, from locomotion_layout.gd's FOOTPRINT
	# pattern. Internal geometry channel, not a player tweak.
	var fx := float(tweaks.get("footprint_x", base_size.x))
	var fz := float(tweaks.get("footprint_z", base_size.z))

	const SKIRT_INNER_UNIT := 0.5
	const AUTHORED_SECTION_HEIGHT := 0.52
	var proud: float = 1.0 + 0.08 * (diameter - 1.0)
	var depth: float = 0.86 * (0.85 + 0.30 * plenum)

	# 1. Continuous rubber bag wrapping the lower hull chine
	var skirt_mesh := _part("acs_skirt")
	if skirt_mesh:
		var skirt := _mesh_inst(skirt_mesh, base_color.darkened(0.35))
		skirt.scale = Vector3(
			(fx * proud) / (SKIRT_INNER_UNIT * 2.0),
			depth / AUTHORED_SECTION_HEIGHT,
			(fz * proud) / (SKIRT_INNER_UNIT * 2.0))
		skirt.position = Vector3(0, -depth * 0.40, 0)
		parent_node.add_child(skirt)

	# 2. Rubberized Plenum Sealing Deck / Collar
	# Closes the interior opening of the bag and extends upward into the hull belly,
	# ensuring an airtight visual seal on all hull geometries.
	var deck := BoxMesh.new()
	deck.size = Vector3(fx * 0.94, depth * 0.75, fz * 0.94)
	var deck_inst := _mesh_inst(deck, base_color.darkened(0.65))
	deck_inst.position = Vector3(0, -depth * 0.18, 0)
	parent_node.add_child(deck_inst)

	# Sealing rim flange overlapping the hull chine contact edge
	var seal_lip := BoxMesh.new()
	seal_lip.size = Vector3(fx * 1.01, 0.09, fz * 1.01)
	var lip_inst := _mesh_inst(seal_lip, base_color.darkened(0.48))
	lip_inst.position = Vector3(0, 0.02, 0)
	parent_node.add_child(lip_inst)

	# 3. Lift Fans set into the sealed plenum deck
	var fan_mesh := _part("acs_lift_fan")
	if fan_mesh:
		var fan_s: float = (0.75 + 0.25 * diameter) * maxf(1.0, fx * 0.35)
		for i in range(fans):
			var t: float = 0.0 if fans <= 1 else (float(i) / float(fans - 1)) - 0.5
			var fan_pos := Vector3(0.0, 0.04, t * fz * 0.55)

			# Protective cowling bezel ring
			var cowl := CylinderMesh.new()
			cowl.top_radius = fan_s * 0.46
			cowl.bottom_radius = fan_s * 0.48
			cowl.height = 0.14
			var cowl_inst := _mesh_inst(cowl, Color(0.22, 0.23, 0.25))
			cowl_inst.position = fan_pos
			parent_node.add_child(cowl_inst)

			var fan_pivot := Node3D.new()
			fan_pivot.name = SPIN_PIVOT_TURBINE
			fan_pivot.position = fan_pos
			fan_pivot.rotation = Vector3(PI / 2.0, 0, 0)
			parent_node.add_child(fan_pivot)

			var fan := _mesh_inst(fan_mesh, Color(0.30, 0.32, 0.34))
			fan.scale = Vector3.ONE * fan_s
			fan_pivot.add_child(fan)


## Anti-grav plate: emitter plates in a cluster under an optional stabiliser
## toroid. The only locomotor with no moving contact surface at all, so its
## motion cue is the ring - which is exactly why dropping the ring for speed
## is a visible trade and not just a number.
static func _build_anti_grav_plate(parent_node: Node3D, base_size: Vector3, base_color: Color = Color(0.35, 0.65, 0.85), tweaks: Dictionary = {}):
	var plates := int(tweaks.get("plate_count", 4.0))
	var field := float(tweaks.get("field_strength", 1.0))
	var has_ring: bool = bool(tweaks.get("stabilizer_ring", true))
	var struct_color := Color(0.28, 0.30, 0.33).lerp(base_color, 0.08)

	const HEAD_SCALE := 2.3
	var pad_radius: float = 0.5 * HEAD_SCALE * (0.8 + 0.3 * field)

	# 1. Radial Outrigger Pylon / Mounting Arm spanning from emitter hub to hull contact point
	var anchor := Vector3(
		float(tweaks.get("kit_anchor_x", tweaks.get("mount_reach_x", 0.0))),
		float(tweaks.get("kit_anchor_y", tweaks.get("mount_reach_y", 0.0))),
		float(tweaks.get("kit_anchor_z", tweaks.get("mount_reach_z", 0.0)))
	)
	var station := MountReachScript.station_from(tweaks)
	var surface := MountReachScript.surface_for(parent_node)
	
	var dir_to_hull := anchor.normalized() if anchor.length_squared() > 0.001 else (-station).normalized()
	var span_vec := dir_to_hull * (anchor.length() if anchor.length() > 0.05 else pad_radius)
	var hull_normal := -dir_to_hull

	if not surface.is_empty():
		var eff_station := station
		var hit: Dictionary = HullProjectionScript.raycast(surface, eff_station, dir_to_hull)
		if hit.get("hit", false):
			span_vec = hit["position"] - eff_station
			hull_normal = hit["normal"]
		else:
			for pitch_deg in [-10.0, 10.0, -20.0, 20.0, -35.0, 35.0]:
				var test_axis := Vector3.UP.cross(dir_to_hull)
				if test_axis.length_squared() > 0.001:
					test_axis = test_axis.normalized()
					var test_dir := dir_to_hull.rotated(test_axis, deg_to_rad(pitch_deg))
					var hit2: Dictionary = HullProjectionScript.raycast(surface, eff_station, test_dir)
					if hit2.get("hit", false):
						span_vec = hit2["position"] - eff_station
						hull_normal = hit2["normal"]
						break

	var span_len: float = span_vec.length()
	if span_len > 0.05:
		var arm := Node3D.new()
		arm.name = "MountArm"
		parent_node.add_child(arm)
		
		# Look towards span vector
		arm.look_at_from_position(Vector3.ZERO, span_vec, Vector3.UP)

		var beam_thick: float = 0.22
		var beam_reach: float = span_len + 0.08
		var beam := BoxMesh.new()
		beam.size = Vector3(beam_thick * 1.4, beam_thick * 1.1, 1.0)
		var beam_inst := _mesh_inst(beam, struct_color)
		beam_inst.position = Vector3(0, 0, -beam_reach * 0.5)
		beam_inst.scale = Vector3(1, 1, beam_reach)
		arm.add_child(beam_inst)

		# Diagonal upper reinforcement gusset
		var diag_strut := BoxMesh.new()
		diag_strut.size = Vector3(beam_thick * 1.0, beam_thick * 0.7, 1.0)
		var diag_inst := _mesh_inst(diag_strut, struct_color.darkened(0.1))
		diag_inst.position = Vector3(0, beam_thick * 0.45, -beam_reach * 0.5)
		diag_inst.scale = Vector3(1, 1, beam_reach * 0.9)
		diag_inst.rotation = Vector3(deg_to_rad(-8.0), 0, 0)
		arm.add_child(diag_inst)

		# Heavy structural hull mounting flange bracket placed directly on hull contact point
		# and oriented FLUSH and ALIGNED with the hull face normal!
		var bracket := BoxMesh.new()
		bracket.size = Vector3(beam_thick * 2.4, beam_thick * 2.2, beam_thick * 0.8)
		var bracket_inst := _mesh_inst(bracket, struct_color.darkened(0.25).lightened(0.2))
		bracket_inst.position = Vector3(span_vec.x, span_vec.y, span_vec.z)
		
		# Align bracket basis flush with hull normal
		var b_norm := hull_normal.normalized()
		if absf(b_norm.dot(Vector3.UP)) < 0.95:
			var b_forward := -b_norm
			var b_right := b_forward.cross(Vector3.UP).normalized()
			var b_up := b_right.cross(b_forward).normalized()
			bracket_inst.transform.basis = Basis(b_right, b_up, -b_forward)
		parent_node.add_child(bracket_inst)

	# PROMINENCE. Chris: both this and the hover pad "need to be larger and
	# more prominent on the ends of their pylons". The emitter is the point of
	# the module - the pylon is just what holds it out there - so the head
	# grows and the mount does not.
	var plate_mesh := _part("agp_plate")
	if plate_mesh:
		for i in range(plates):
			var a: float = float(i) / float(maxi(1, plates)) * TAU
			var r: float = 0.0 if plates <= 1 else 0.22 * HEAD_SCALE
			# NO EMISSION on the pad body. Chris: "that hoop in the middle
			# can stay, the rest of the pad part should be the dark metal."
			# The exotic role was already doing its job - emission is applied
			# on top of ANY material, so a blue glow across the whole plate
			# was what kept it reading as sky-blue plastic no matter what the
			# substrate said. The tint is neutral too, so the team colour
			# cannot leak back in through the role's own tint weight.
			var plate := _mesh_inst(plate_mesh, Color(0.30, 0.32, 0.35))
			plate.scale = Vector3(0.8 + 0.3 * field, 1.0, 0.8 + 0.3 * field) * HEAD_SCALE
			plate.position = Vector3(cos(a) * r, 0.0, sin(a) * r)
			parent_node.add_child(plate)

	if has_ring:
		var ring_mesh := _part("agp_ring")
		if ring_mesh:
			var ring_pivot := Node3D.new()
			ring_pivot.name = SPIN_PIVOT_TURBINE
			ring_pivot.position = Vector3(0, -0.10 * HEAD_SCALE, 0)
			ring_pivot.rotation = Vector3(PI / 2.0, 0, 0)
			parent_node.add_child(ring_pivot)
			var ring := _mesh_inst(ring_mesh, base_color.darkened(0.45),
				Color(0.35, 0.75, 1.0), 0.45 * field)
			ring.scale = Vector3.ONE * (0.9 + 0.25 * field) * HEAD_SCALE
			ring_pivot.add_child(ring)

	# THE FIELD ITSELF, in two parts: light cast onto the ground, and the
	# ground seen through a lens. Chris asked for both - "a glow under them,
	# and an effect that it looks like its bending light under them as well" -
	# and they are genuinely different phenomena, so neither one fakes the
	# other.
	var head_r: float = 0.42 * HEAD_SCALE * (0.8 + 0.3 * field)

	# 1. The glow. A real OmniLight3D, so it lights the actual terrain under
	# the vehicle and moves with it, rather than a painted blob that would sit
	# flat on whatever it is over.
	var glow := OmniLight3D.new()
	glow.name = "GravGlow"
	glow.position = Vector3(0, -0.55 * HEAD_SCALE, 0)
	glow.light_color = Color(0.34, 0.68, 1.0)
	# 1.2, not 2.2: at the higher value the light washed the hull's whole
	# underside flat blue and the hardware stopped reading as metal at all.
	glow.light_energy = 1.2 * field
	glow.omni_range = 3.4 * HEAD_SCALE * (0.7 + 0.3 * field)
	glow.omni_attenuation = 1.6
	glow.shadow_enabled = false
	# Distance-fade the under-vehicle glow. The unit's omni_range already
	# kills it past a few metres; this lets the cluster grid stop allocating
	# a slot for off-screen units without waiting for light_cap.gd to do it.
	glow.distance_fade_enabled = true
	glow.distance_fade_begin = glow.omni_range * 0.7
	glow.distance_fade_length = glow.omni_range * 0.3
	parent_node.add_child(glow)

	# 2. The lens. A disc lying flat under the plates carrying
	# gravitic_lens.gdshader, which displaces its screen sample radially - so
	# what warps is whatever is really behind it. See that shader for why it
	# is unshaded and never writes depth.
	var lens_shader: Shader = load("res://shaders/gravitic_lens.gdshader")
	if lens_shader:
		var lens := MeshInstance3D.new()
		lens.name = "GravLens"
		var quad := QuadMesh.new()
		quad.size = Vector2(head_r * 5.2, head_r * 5.2)
		lens.mesh = quad
		var mat := ShaderMaterial.new()
		mat.shader = lens_shader
		mat.set_shader_parameter("strength", 0.028 + 0.022 * field)
		mat.set_shader_parameter("tint", Color(0.30, 0.62, 0.95))
		lens.material_override = mat
		# Flat, facing down at the ground it is bending.
		lens.rotation = Vector3(PI / 2.0, 0, 0)
		lens.position = Vector3(0, -0.62 * HEAD_SCALE, 0)
		# The lens must not be culled when the plates themselves are on screen
		# but its own small quad is not.
		lens.extra_cull_margin = 4.0
		parent_node.add_child(lens)


static func _build_plasma_thruster(parent_node: Node3D, base_size: Vector3, base_color: Color = Color(0.3, 0.45, 0.95), tweaks: Dictionary = {}):
	var nozzle_w: float = float(tweaks.get("nozzle_width", 1.0))
	var afterburner: bool = bool(tweaks.get("afterburner", false))
	var struct_color := Color(0.22, 0.25, 0.28).lerp(base_color, 0.10)
	var armor_color := Color(0.26, 0.28, 0.32)
	var plasma_color := Color(0.85, 0.35, 1.0) if afterburner else Color(0.28, 0.72, 1.0)
	var glow_color := Color(0.75, 0.30, 0.95) if afterburner else Color(0.25, 0.65, 1.0)

	const POD_SCALE := 1.6
	var pod_radius: float = 0.45 * POD_SCALE * (0.8 + 0.25 * nozzle_w)

	# 1. Structural Outrigger Mounting Arm connecting to hull contact point
	var anchor := Vector3(
		float(tweaks.get("kit_anchor_x", tweaks.get("mount_reach_x", 0.0))),
		float(tweaks.get("kit_anchor_y", tweaks.get("mount_reach_y", 0.0))),
		float(tweaks.get("kit_anchor_z", tweaks.get("mount_reach_z", 0.0)))
	)
	var station := MountReachScript.station_from(tweaks)
	var surface := MountReachScript.surface_for(parent_node)

	var dir_to_hull := anchor.normalized() if anchor.length_squared() > 0.001 else (-station).normalized()
	var span_vec := dir_to_hull * (anchor.length() if anchor.length() > 0.05 else pod_radius)
	var hull_normal := -dir_to_hull

	if not surface.is_empty():
		var eff_station := station
		var hit: Dictionary = HullProjectionScript.raycast(surface, eff_station, dir_to_hull)
		if hit.get("hit", false):
			span_vec = hit["position"] - eff_station
			hull_normal = hit["normal"]
		else:
			for pitch_deg in [-10.0, 10.0, -20.0, 20.0, -35.0, 35.0]:
				var test_axis := Vector3.UP.cross(dir_to_hull)
				if test_axis.length_squared() > 0.001:
					test_axis = test_axis.normalized()
					var test_dir := dir_to_hull.rotated(test_axis, deg_to_rad(pitch_deg))
					var hit2: Dictionary = HullProjectionScript.raycast(surface, eff_station, test_dir)
					if hit2.get("hit", false):
						span_vec = hit2["position"] - eff_station
						hull_normal = hit2["normal"]
						break

	var span_len: float = span_vec.length()
	if span_len > 0.05:
		var arm := Node3D.new()
		arm.name = "MountArm"
		parent_node.add_child(arm)
		arm.look_at_from_position(Vector3.ZERO, span_vec, Vector3.UP)

		var beam_thick: float = 0.20
		var beam_reach: float = span_len + 0.08
		var beam := BoxMesh.new()
		beam.size = Vector3(beam_thick * 1.5, beam_thick * 1.0, 1.0)
		var beam_inst := _mesh_inst(beam, struct_color)
		beam_inst.position = Vector3(0, 0, -beam_reach * 0.5)
		beam_inst.scale = Vector3(1, 1, beam_reach)
		arm.add_child(beam_inst)

		# Diagonal reinforcement strut
		var diag_strut := BoxMesh.new()
		diag_strut.size = Vector3(beam_thick * 1.1, beam_thick * 0.7, 1.0)
		var diag_inst := _mesh_inst(diag_strut, struct_color.darkened(0.15))
		diag_inst.position = Vector3(0, beam_thick * 0.4, -beam_reach * 0.5)
		diag_inst.scale = Vector3(1, 1, beam_reach * 0.88)
		diag_inst.rotation = Vector3(deg_to_rad(-10.0), 0, 0)
		arm.add_child(diag_inst)

		# Heavy hull flange bracket
		var bracket := BoxMesh.new()
		bracket.size = Vector3(beam_thick * 2.5, beam_thick * 2.2, beam_thick * 0.9)
		var bracket_inst := _mesh_inst(bracket, struct_color.darkened(0.2))
		bracket_inst.position = Vector3(span_vec.x, span_vec.y, span_vec.z)
		var b_norm := hull_normal.normalized()
		if absf(b_norm.dot(Vector3.UP)) < 0.95:
			var b_forward := -b_norm
			var b_right := b_forward.cross(Vector3.UP).normalized()
			var b_up := b_right.cross(b_forward).normalized()
			bracket_inst.transform.basis = Basis(b_right, b_up, -b_forward)
		parent_node.add_child(bracket_inst)

	# 2. Main Thruster Pod Body (Elongated aerodynamic nacelle)
	var pod_root := Node3D.new()
	pod_root.name = "PodRoot"
	parent_node.add_child(pod_root)

	var body_len: float = 0.95 * POD_SCALE
	var body_w: float = 0.42 * POD_SCALE * nozzle_w
	var body_h: float = 0.38 * POD_SCALE

	var nacelle_mesh := BoxMesh.new()
	nacelle_mesh.size = Vector3(body_w, body_h, body_len)
	var nacelle := _mesh_inst(nacelle_mesh, armor_color)
	nacelle.name = "NacelleBody"
	nacelle.position = Vector3(0, 0.05 * POD_SCALE, 0)
	pod_root.add_child(nacelle)

	# Top radiator cooling fins
	for f in [-1.0, 1.0]:
		var fin := BoxMesh.new()
		fin.size = Vector3(0.04 * POD_SCALE, 0.16 * POD_SCALE, body_len * 0.7)
		var fin_inst := _mesh_inst(fin, struct_color.darkened(0.1))
		fin_inst.position = Vector3(f * body_w * 0.32, body_h * 0.5 + 0.08 * POD_SCALE, 0)
		pod_root.add_child(fin_inst)

	# Forward intake shroud
	var intake := CylinderMesh.new()
	intake.top_radius = body_w * 0.46
	intake.bottom_radius = body_w * 0.52
	intake.height = 0.22 * POD_SCALE
	intake.radial_segments = 12
	var intake_inst := _mesh_inst(intake, struct_color.lightened(0.1))
	intake_inst.rotation = Vector3(PI * 0.5, 0, 0)
	intake_inst.position = Vector3(0, 0.05 * POD_SCALE, -body_len * 0.52)
	pod_root.add_child(intake_inst)

	# 3. Magnetic Confinement Nozzle & Plasma Discharge Chamber
	var nozzle_ring := TorusMesh.new()
	nozzle_ring.outer_radius = body_w * 0.54
	nozzle_ring.inner_radius = body_w * 0.38
	nozzle_ring.rings = 16
	nozzle_ring.ring_segments = 8
	var nozzle_inst := _mesh_inst(nozzle_ring, struct_color.darkened(0.2))
	nozzle_inst.rotation = Vector3(PI * 0.5, 0, 0)
	nozzle_inst.position = Vector3(0, 0.05 * POD_SCALE, body_len * 0.50)
	pod_root.add_child(nozzle_inst)

	# Ventral Plasma Emitter Ring (Downwards thrust for ground-cushion hover)
	var ventral_nozzle := TorusMesh.new()
	ventral_nozzle.outer_radius = body_w * 0.48
	ventral_nozzle.inner_radius = body_w * 0.32
	ventral_nozzle.rings = 16
	ventral_nozzle.ring_segments = 8
	var ventral_inst := _mesh_inst(ventral_nozzle, struct_color.darkened(0.15))
	ventral_inst.position = Vector3(0, -body_h * 0.48, 0)
	pod_root.add_child(ventral_inst)

	# 4. Emissive Plasma Core (Ventral & Aft)
	var plasma_mat := StandardMaterial3D.new()
	plasma_mat.albedo_color = plasma_color
	plasma_mat.emission_enabled = true
	plasma_mat.emission = plasma_color
	plasma_mat.emission_energy_multiplier = 2.4 if afterburner else 1.8
	plasma_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var aft_plasma := CylinderMesh.new()
	aft_plasma.top_radius = body_w * 0.36
	aft_plasma.bottom_radius = body_w * 0.20
	aft_plasma.height = 0.30 * POD_SCALE
	aft_plasma.radial_segments = 10
	var aft_plasma_inst := MeshInstance3D.new()
	aft_plasma_inst.mesh = aft_plasma
	aft_plasma_inst.material_override = plasma_mat
	aft_plasma_inst.rotation = Vector3(PI * 0.5, 0, 0)
	aft_plasma_inst.position = Vector3(0, 0.05 * POD_SCALE, body_len * 0.58)
	pod_root.add_child(aft_plasma_inst)

	var ventral_plasma := CylinderMesh.new()
	ventral_plasma.top_radius = body_w * 0.32
	ventral_plasma.bottom_radius = body_w * 0.16
	ventral_plasma.height = 0.24 * POD_SCALE
	ventral_plasma.radial_segments = 10
	var ventral_plasma_inst := MeshInstance3D.new()
	ventral_plasma_inst.mesh = ventral_plasma
	ventral_plasma_inst.material_override = plasma_mat
	ventral_plasma_inst.position = Vector3(0, -body_h * 0.55, 0)
	pod_root.add_child(ventral_plasma_inst)

	# 5. Spinning Magnetic Induction Ring (for runtime animation)
	var spin_pivot := Node3D.new()
	spin_pivot.name = PIVOT_PLASMA_RING
	spin_pivot.position = Vector3(0, 0.05 * POD_SCALE, body_len * 0.38)
	pod_root.add_child(spin_pivot)

	var rotor_mesh := CylinderMesh.new()
	rotor_mesh.top_radius = body_w * 0.42
	rotor_mesh.bottom_radius = body_w * 0.42
	rotor_mesh.height = 0.06 * POD_SCALE
	rotor_mesh.radial_segments = 8
	var rotor_inst := _mesh_inst(rotor_mesh, Color(0.18, 0.20, 0.24), plasma_color, 0.6)
	rotor_inst.rotation = Vector3(PI * 0.5, 0, 0)
	spin_pivot.add_child(rotor_inst)

	# 6. Real Downward Dynamic OmniLight for Ground Glow
	var glow := OmniLight3D.new()
	glow.name = "PlasmaGlow"
	glow.position = Vector3(0, -body_h * 0.8, 0)
	glow.light_color = glow_color
	glow.light_energy = 1.6 * nozzle_w
	glow.omni_range = 3.6 * POD_SCALE
	glow.omni_attenuation = 1.5
	glow.shadow_enabled = false
	glow.distance_fade_enabled = true
	glow.distance_fade_begin = glow.omni_range * 0.7
	glow.distance_fade_length = glow.omni_range * 0.3
	parent_node.add_child(glow)


# ===========================================================================
# CHINE MOUNT FRAME
#
# The measured attachment frame each seated locomotion instance receives, and
# the standoff it needs to clear the hull. locomotion_mount.gd solves these off
# the real mesh (hull_chine.gd) and publishes them through the tweaks dict; the
# helpers below just read them back out.
#
# THERE IS DELIBERATELY NO GENERIC MOUNT BRACKET HERE.
#
# One was written and removed the same day. The reasoning for building it: with
# stations seated onto the hull skin there is no gap left for build_mount_kit()'s
# MountArm to span (it would be a degenerate zero-length beam), so the arm should
# give way to something that provides contact AREA instead - a plate lying along
# the flank with its lower edge on the chine.
#
# The reasoning for removing it, which is better (Chris, 2026-08-12): "A wheel
# wouldn't have that sticking out over it. You're also adding on mounting gear to
# the mounting gear that the old system generated."
#
# Both halves of that are right. Every seated type ALREADY has authored mount
# geometry - a driveshaft and gearbox for the four types sharing
# build_wheel_mount(), a track frame for the treads, an authored hip for the leg
# sets, pads and standoffs for the kit types. A generic plate on top of those is
# a second structure doing the first one's job, which is the same
# two-structures mistake the retired running-gear slab and subframe both made.
#
# And it looked wrong for a specific geometric reason worth recording: on a
# 45-degree chine the flank_up axis is diagonal, so a plate tall enough to read
# as structure travels roughly as far OUTBOARD as it does up, and ends up
# projecting over the top of the wheel it was supposed to be mounting.
#
# What actually fixed the mounting was seating the stations (they were computed
# against the bounding box, a mean of 0.335 units off the real hull edge) and
# then standing the gear off the body. The existing per-type geometry was never
# the problem; it was correct geometry anchored to the wrong point.
# ===========================================================================

## Reads the measured mount frame out of a builder's tweaks dict.
##
## Returns an empty dict when this instance was not seated - an airborne type, a
## centreline station, or a hull whose mesh could not be sliced. Every caller
## treats that as "build the old way", so an unseated instance is unchanged
## rather than broken.
static func chine_frame_from(tweaks: Dictionary) -> Dictionary:
	if float(tweaks.get("chine_seated", 0.0)) < 0.5:
		return {}
	var n := Vector3(float(tweaks.get("chine_normal_x", 0.0)),
		float(tweaks.get("chine_normal_y", 0.0)), 0.0)
	var u := Vector3(float(tweaks.get("chine_up_x", 0.0)),
		float(tweaks.get("chine_up_y", 0.0)), 0.0)
	if n.length_squared() < 1e-8 or u.length_squared() < 1e-8:
		return {}
	return {
		"normal": n.normalized(),
		"up": u.normalized(),
		"flank_height": float(tweaks.get("chine_flank_height", 0.0)),
		"belly_drop": float(tweaks.get("chine_belly_drop", 0.0)),
		"half_width": float(tweaks.get("chine_half_width", 0.0)),
		"clear_x": float(tweaks.get("chine_clear_x", 0.0)),
	}


## How far outboard running gear must sit, in module space, to clear the hull.
##
## Chris, 2026-08-12: "The wheels are too close to the hull body."
##
## That was a real regression from chine seating and worth naming precisely. The
## old box placement put a station at the fitted collision box's side, which on
## any hull with a chamfer or tumblehome is OUTBOARD of the mesh - so the wheels
## were being held clear of the hull by the very error this pass removed. Seating
## the station onto the real chine deleted that accidental clearance along with
## the gap it came from, and the gear closed onto the body.
##
## The clearance now has to be asked for explicitly, which is the right way round:
## it is a design quantity (running gear stands off the hull) rather than a
## by-product of a measurement mistake. Two terms, both real:
##   clear_x   the hull's own bulge above the chine, so the tyre misses the body
##   margin    an air gap, scaled, so gear and hull never visually kiss
##
## An earlier version added a third term for the thickness of a generic mount
## bracket. That bracket has since been removed (see the note at the top of this
## section), so the term was padding the standoff on behalf of geometry that is
## no longer built - which pushed the gearbox outboard of the hull side it is
## supposed to tuck against.
static func chine_standoff(frame: Dictionary, s: float = 1.0) -> float:
	if frame.is_empty():
		return 0.0
	return float(frame.get("clear_x", 0.0)) + 0.18 * s


# ===========================================================================
# MOUNT KIT ASSEMBLY
#
# One function, five archetypes, every locomotion type. See
# locomotion_layout.gd's Kit enum for why this exists rather than a generic
# chassis: locomotion had no mounting CONVENTION, so each type improvised one,
# and anything generic added underneath fought them.
#
# Kit parts are authored with their ORIGIN AT THE ATTACHMENT POINT, -Z toward
# the running gear and +X outboard (tools/blender/build_mount_kits.py), so a kit
# is positioned by putting its origin on the mount station and nothing else.
# Everything below is placed in the MODULE's local space, which is exactly that
# station - so the kit needs no per-type fudge factors, which is the whole point.
# ===========================================================================

## Builds the structural mount for one locomotion instance, under a child node
## named "MountKit" so it can be found, hidden or restyled as a unit.
##
## `outboard` is +1 for the starboard side and -1 for port; the kit is authored
## once and mirrored here rather than authored twice.
static func build_mount_kit(parent_node: Node3D, type_id: String,
		base_color: Color, outboard: float = 1.0, scale_hint: float = 1.0,
		kit_reach: float = 0.0, anchor: Vector3 = Vector3.ZERO,
		tweaks: Dictionary = {}) -> Node3D:
	var spec: Dictionary = LocomotionLayoutScript.mount_kit(type_id)
	var kit: int = int(spec.get("kit", 0))
	if kit == LocomotionLayoutScript.Kit.NONE:
		return null

	# A seated station has no gap to span: locomotion_mount.gd has already put the
	# origin on the hull skin, so the arm below would be a degenerate beam of
	# length ~0. See the CHINE MOUNT FRAME retirement note.
	var seated := not chine_frame_from(tweaks).is_empty()

	var root := Node3D.new()
	root.name = "MountKit"
	parent_node.add_child(root)
	var drop: float = float(spec.get("drop", 0.0)) * scale_hint
	var stations: int = int(spec.get("stations", 1))
	var frame_col := base_color.darkened(0.30)
	var hw_col := base_color.darkened(0.10)
	var side: float = signf(outboard) if not is_zero_approx(outboard) else 1.0

	# THE SPANNING MEMBER. This is the generalisation of the one thing that
	# already worked: the OLD wheels' driveshaft was solved to bridge the actual
	# distance from the wheel back into the hull, angling inboard and up, rather
	# than being a fixed lump sitting at the mount point. Everything else
	# improvised, and a fixed kit plus a vertical riser could never close the
	# gaps, because the gap differs per type, per hull and per station.
	#
	# `anchor` is the vector from this kit's origin to its hull attachment, in
	# module space. The member is built one unit long on -Z, then scaled to the
	# vector's length and rotated onto it - so it spans exactly, at any size, for
	# any type, with no per-type numbers at all.
	if anchor.length() > 0.05 and not seated:
		var span_len := anchor.length()
		var arm := Node3D.new()
		arm.name = "MountArm"
		root.add_child(arm)
		arm.look_at_from_position(Vector3.ZERO, anchor, Vector3.UP)

		# Scaled off the SPAN it carries, not off a tweak. A 1.2-unit arm holding
		# a road wheel needs real section; the first pass used a flat 0.14 and the
		# structural probe promptly flagged half the roster FRAGILE at 0.02-0.05
		# thinnest section. Floored so a short arm is still a fabrication rather
		# than a wire.
		var thickness: float = clampf(0.12 * span_len + 0.06 * scale_hint, 0.10, 0.32)
		var beam := BoxMesh.new()
		beam.size = Vector3(thickness, thickness * 1.25, 1.0)
		var beam_inst := _mesh_inst(beam, frame_col, Color(0, 0, 0, 0), 0.0, "steel")
		beam_inst.name = "MountArmBeam"
		# look_at aims -Z at the target, so the beam runs from 0 to -span_len.
		beam_inst.position = Vector3(0, 0, -span_len * 0.5)
		beam_inst.scale = Vector3(1, 1, span_len)
		arm.add_child(beam_inst)

		# A web down one side turns a bar into a fabricated arm.
		var web := BoxMesh.new()
		web.size = Vector3(thickness * 0.35, thickness * 2.1, 0.82)
		var web_inst := _mesh_inst(web, frame_col.darkened(0.08), Color(0, 0, 0, 0), 0.0, "steel")
		web_inst.name = "MountArmWeb"
		web_inst.position = Vector3(0, -thickness * 0.35, -span_len * 0.5)
		web_inst.scale = Vector3(1, 1, span_len)
		arm.add_child(web_inst)

		# Bracket where it lands on the hull, and a pivot boss at the gear end,
		# so both ends read as joined rather than butted.
		var pad := BoxMesh.new()
		pad.size = Vector3(thickness * 2.4, thickness * 0.6, thickness * 2.4)
		var pad_inst := _mesh_inst(pad, hw_col, Color(0, 0, 0, 0), 0.0, "steel")
		pad_inst.name = "MountArmPad"
		pad_inst.position = Vector3(0, 0, -span_len)
		arm.add_child(pad_inst)

		var boss := CylinderMesh.new()
		boss.top_radius = thickness * 0.85
		boss.bottom_radius = thickness * 0.85
		boss.height = thickness * 2.0
		var boss_inst := _mesh_inst(boss, hw_col, Color(0, 0, 0, 0), 0.0, "steel")
		boss_inst.name = "MountArmBoss"
		boss_inst.rotation = Vector3(0, 0, PI / 2.0)
		arm.add_child(boss_inst)

	match kit:
		LocomotionLayoutScript.Kit.SUSPENSION_ARM:
			_kit_part(root, "mk_susp_anchor", frame_col, Vector3.ZERO, Vector3.ONE * scale_hint, side)
			_kit_part(root, "mk_susp_arm", hw_col, Vector3(0, -drop * 0.35, 0),
				Vector3.ONE * scale_hint, side)
			_kit_part(root, "mk_susp_spring", base_color.lightened(0.05),
				Vector3(side * 0.20 * scale_hint, -drop * 0.30, 0), Vector3.ONE * scale_hint, side)
			# One hub per station, spread fore/aft - a rocker-bogie carries two
			# on the same arm, a road wheel one.
			for i in range(maxi(1, stations)):
				var t: float = 0.0 if stations <= 1 else (float(i) / float(stations - 1)) - 0.5
				_kit_part(root, "mk_susp_hub", hw_col,
					Vector3(side * 0.34 * scale_hint, -drop, t * 0.55 * scale_hint),
					Vector3.ONE * scale_hint, side)

		LocomotionLayoutScript.Kit.TRACK_FRAME:
			# The frame is authored one unit long on its own fore/aft axis so
			# the runtime stretches only it, never the bearings bolted to it.
			var frame := _kit_part(root, "mk_track_frame", frame_col,
				Vector3(0, -drop * 0.5, 0), Vector3(scale_hint, scale_hint, 1.0), side)
			if frame:
				frame.scale = Vector3(scale_hint, scale_hint, maxf(0.2, scale_hint))
			for i in range(maxi(1, stations)):
				var t2: float = 0.0 if stations <= 1 else (float(i) / float(stations - 1)) - 0.5
				_kit_part(root, "mk_track_bearing", hw_col,
					Vector3(0, -drop * 0.5, t2 * 0.86 * scale_hint),
					Vector3.ONE * scale_hint, side)
			for zz in [-1.0, 1.0]:
				_kit_part(root, "mk_track_finaldrive", hw_col.lightened(0.06),
					Vector3(0, -drop * 0.4, zz * 0.46 * scale_hint),
					Vector3.ONE * scale_hint, side)

		LocomotionLayoutScript.Kit.STRUT_LEG:
			_kit_part(root, "mk_strut_flange", frame_col, Vector3.ZERO,
				Vector3.ONE * scale_hint, side)
			var blade := _kit_part(root, "mk_strut_blade", hw_col,
				Vector3(0, -drop * 0.5, 0), Vector3.ONE * scale_hint, side)
			if blade:
				# Authored one unit tall, so the drop stretches the blade alone.
				blade.scale = Vector3(scale_hint, maxf(0.2, drop), scale_hint)
			_kit_part(root, "mk_strut_actuator", base_color.lightened(0.04),
				Vector3(side * 0.16 * scale_hint, -drop * 0.25, -0.12 * scale_hint),
				Vector3.ONE * scale_hint, side)

		LocomotionLayoutScript.Kit.PYLON:
			_kit_part(root, "mk_pylon_root", frame_col, Vector3.ZERO,
				Vector3.ONE * scale_hint, side)
			var strut := _kit_part(root, "mk_pylon_strut", hw_col, Vector3.ZERO,
				Vector3.ONE * scale_hint, side)
			if strut:
				strut.scale = Vector3(scale_hint, maxf(0.2, scale_hint), scale_hint)
			_kit_part(root, "mk_pylon_collar", hw_col.lightened(0.05),
				Vector3(0, -0.92 * scale_hint, 0), Vector3.ONE * scale_hint, side)

		LocomotionLayoutScript.Kit.HARDPOINT_PAD:
			_kit_part(root, "mk_pad_plate", frame_col, Vector3.ZERO,
				Vector3.ONE * scale_hint, side)
			for i in range(maxi(1, stations)):
				var a: float = float(i) / float(maxi(1, stations)) * TAU
				_kit_part(root, "mk_pad_standoff", hw_col,
					Vector3(cos(a) * 0.24 * scale_hint, -drop * 0.5, sin(a) * 0.24 * scale_hint),
					Vector3.ONE * scale_hint, side)
			_kit_part(root, "mk_pad_conduit", base_color.lightened(0.03),
				Vector3(side * 0.20 * scale_hint, -drop * 0.2, 0.16 * scale_hint),
				Vector3.ONE * scale_hint, side)

	return root


## One kit part. Returns null (quietly) when the asset is missing, so a kit is
## degraded rather than fatal if a part fails to import.
static func _kit_part(root: Node3D, part_name: String, colour: Color,
		pos: Vector3, part_scale: Vector3, side: float) -> MeshInstance3D:
	var mesh := _part(part_name)
	if mesh == null:
		return null
	var inst := _mesh_inst(mesh, colour, Color(0, 0, 0, 0), 0.0, "steel")
	inst.name = part_name
	# Mirroring on X rather than authoring a port-side variant. Negative scale
	# flips winding, so cull mode is switched to match - the same compensation
	# module_mirror.gd applies to mirrored weapon modules.
	inst.scale = Vector3(part_scale.x * side, part_scale.y, part_scale.z)
	inst.position = pos
	if side < 0.0:
		var mat := inst.material_override
		if mat is BaseMaterial3D:
			var flipped: BaseMaterial3D = mat.duplicate()
			flipped.cull_mode = BaseMaterial3D.CULL_FRONT
			inst.material_override = flipped
	root.add_child(inst)
	return inst


# ===========================================================================
# SUBFRAME - the chassis every ground and hover locomotor bolts to.
#
# Chris's design, and the answer the per-type improvising kept failing to be:
# a space-frame of tubes and beams that DYNAMICALLY grows attachment points
# wherever the fitted locomotor needs them, with the locomotors lining up on
# those points, and the whole thing slung under the hull as the running gear.
#
# This is how a real modular chassis works, and it is why it fixes the class of
# bug rather than an instance of it. Previously each type invented its own way
# of reaching the hull, so a hardpoint was wherever that type's author put it,
# and nothing could line up with anything. Now the frame publishes the
# hardpoints and the locomotor consumes them - one contract, ten types.
#
# Naval and airborne types deliberately do NOT use this: a propeller on a stern
# pylon and a rotor on a mast are not carried by a chassis under the hull, and
# forcing them onto one is what made the first generic frame collide with
# everything. They keep their own structure until they get a system of their own.
# ===========================================================================

## Builds the subframe into `body`, with a mounting pad at each hardpoint.
##
## `hardpoints` are in the running gear's own local space (X outboard, Y up,
## Z fore/aft). The frame is generated around them, so a four-wheeled chassis
## gets four bays and a five-road-wheel track gets five - the geometry follows
## the fitment rather than being a fixed prop the parts sit near.
static func build_subframe(body: StaticBody3D, dimensions: Vector3,
		base_color: Color, hardpoints: Array) -> void:
	var half := dimensions * 0.5
	var beam_col := base_color.darkened(0.34)
	var tube_col := base_color.darkened(0.20)
	var pad_col := base_color.darkened(0.06)
	# Section scales with the chassis so a big hull gets a frame that looks like
	# it could hold one, without a per-hull constant.
	var tube_r: float = clampf(dimensions.y * 0.16, 0.035, 0.085)
	var rail_x: float = half.x - tube_r * 1.6

	var tube := func(a: Vector3, b: Vector3, r: float, colour: Color, nm: String) -> void:
		var d := b - a
		if d.length() < 0.02:
			return
		var mesh := CylinderMesh.new()
		mesh.top_radius = r
		mesh.bottom_radius = r
		mesh.height = d.length()
		mesh.radial_segments = 10
		var inst := _mesh_inst(mesh, colour, Color(0, 0, 0, 0), 0.0, "steel")
		inst.name = nm
		inst.position = (a + b) * 0.5
		# CylinderMesh runs along local Y; aim that at the span.
		var up := Vector3.UP
		if absf(d.normalized().dot(up)) > 0.99:
			up = Vector3.FORWARD
		inst.basis = Basis.looking_at(d.normalized(), up) * Basis(Vector3.RIGHT, PI / 2.0)
		body.add_child(inst)

	var beam := func(centre: Vector3, size: Vector3, colour: Color, nm: String) -> void:
		var mesh := BoxMesh.new()
		mesh.size = size
		var inst := _mesh_inst(mesh, colour, Color(0, 0, 0, 0), 0.0, "steel")
		inst.name = nm
		inst.position = centre
		body.add_child(inst)

	# Longitudinal main rails - the frame's backbone, one per side.
	for side in [-1.0, 1.0]:
		beam.call(Vector3(side * rail_x, 0.0, 0.0),
			Vector3(tube_r * 2.2, dimensions.y * 0.62, dimensions.z * 0.98),
			beam_col, "SubframeRail")
		# Top and bottom chords, so the rail reads as fabricated section.
		for sy in [-1.0, 1.0]:
			beam.call(Vector3(side * rail_x, sy * dimensions.y * 0.30, 0.0),
				Vector3(tube_r * 3.0, dimensions.y * 0.13, dimensions.z * 0.98),
				tube_col, "SubframeChord")

	# Sort the hardpoints fore-to-aft so cross members and bracing run between
	# NEIGHBOURS rather than criss-crossing the frame.
	var stations: Array = []
	for hp in hardpoints:
		var v: Vector3 = hp
		if not stations.has(v.z):
			stations.append(v.z)
	stations.sort()
	if stations.is_empty():
		stations = [-half.z * 0.5, half.z * 0.5]

	var y_top: float = dimensions.y * 0.26
	var y_bot: float = -dimensions.y * 0.26

	for i in range(stations.size()):
		var z: float = stations[i]
		# Cross member at every station - this is what makes it a frame.
		tube.call(Vector3(-rail_x, y_bot, z), Vector3(rail_x, y_bot, z),
			tube_r, tube_col, "SubframeCross")
		tube.call(Vector3(-rail_x * 0.72, y_top, z), Vector3(rail_x * 0.72, y_top, z),
			tube_r * 0.82, tube_col, "SubframeCrossUpper")
		# Vertical posts tying the two chords together at the rail.
		for side in [-1.0, 1.0]:
			tube.call(Vector3(side * rail_x, y_bot, z), Vector3(side * rail_x, y_top, z),
				tube_r * 0.8, tube_col, "SubframePost")
		# Diagonal bracing into the next bay - a ladder without diagonals is a
		# ladder, not a frame, and reads as flimsy from every angle.
		if i + 1 < stations.size():
			var z2: float = stations[i + 1]
			for side in [-1.0, 1.0]:
				tube.call(Vector3(side * rail_x, y_bot, z), Vector3(side * rail_x * 0.55, y_top, z2),
					tube_r * 0.62, tube_col, "SubframeBrace")

	# Belly skids rather than one full tray. A solid plate closed the frame off
	# completely and hid the tubes and bracing behind it, which defeats the point
	# of building a space-frame - two narrow skid rails give it a floor to read
	# against while leaving the structure visible from below.
	for side in [-0.55, 0.55]:
		beam.call(Vector3(rail_x * side, -dimensions.y * 0.40, 0.0),
			Vector3(tube_r * 3.2, dimensions.y * 0.12, dimensions.z * 0.86),
			beam_col, "SubframeSkid")

	# HARDPOINTS. A machined pad and a boss at every attachment the fitted
	# locomotor asked for - this is the contract the locomotors line up on.
	for hp in hardpoints:
		var p: Vector3 = hp
		var pad_x: float = signf(p.x) * rail_x if not is_zero_approx(p.x) else 0.0
		beam.call(Vector3(pad_x, p.y, p.z),
			Vector3(tube_r * 3.4, tube_r * 2.6, tube_r * 4.2), pad_col, "SubframeHardpoint")
		var boss := CylinderMesh.new()
		boss.top_radius = tube_r * 1.15
		boss.bottom_radius = tube_r * 1.15
		boss.height = tube_r * 3.2
		boss.radial_segments = 10
		var boss_inst := _mesh_inst(boss, pad_col, Color(0, 0, 0, 0), 0.0, "steel")
		boss_inst.name = "SubframeBoss"
		boss_inst.rotation = Vector3(0, 0, PI / 2.0)
		boss_inst.position = Vector3(pad_x + signf(pad_x) * tube_r * 1.4, p.y, p.z)
		body.add_child(boss_inst)


# --- Analytical View Modes ---------------------------------------------------

static var _stored_materials: Dictionary = {}

static func apply_analytical_mode(root: Node, mode: int) -> void:
	if root == null or not is_instance_valid(root):
		return

	var mesh_instances = root.find_children("*", "MeshInstance3D", true, false)
	for mesh_inst in mesh_instances:
		var inst_id = mesh_inst.get_instance_id()

		# Store original material override if not already saved
		if not _stored_materials.has(inst_id):
			_stored_materials[inst_id] = mesh_inst.material_override

		match mode:
			0: # DEFAULT
				mesh_inst.material_override = _stored_materials[inst_id]
			1: # WIREFRAME
				var mat = StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.albedo_color = Color(0.2, 0.9, 0.4, 0.8)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mesh_inst.material_override = mat
			2: # XRAY
				var mat = StandardMaterial3D.new()
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color = Color(0.4, 0.6, 0.9, 0.3)
				mesh_inst.material_override = mat
			3: # STRUCTURAL
				var mat = StandardMaterial3D.new()
				var m_name = mesh_inst.name.to_lower()
				if "hull" in m_name or "plate" in m_name:
					mat.albedo_color = Color(0.8, 0.3, 0.3) # Red for Hull/Armor
				elif "weapon" in m_name or "cannon" in m_name or "turret" in m_name:
					mat.albedo_color = Color(0.9, 0.8, 0.2) # Yellow for Weapons
				elif "engine" in m_name or "tread" in m_name or "wheel" in m_name:
					mat.albedo_color = Color(0.2, 0.7, 0.9) # Blue for Propulsion
				else:
					mat.albedo_color = Color(0.5, 0.5, 0.5) # Gray for Chassis/Other
				mesh_inst.material_override = mat
