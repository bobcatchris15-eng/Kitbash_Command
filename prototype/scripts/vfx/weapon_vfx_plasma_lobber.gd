extends RefCounted
class_name WeaponVFXPlasmaLobber

# PLASMA_LOBBER VFX Identity
# Arcing energy glob: glowing green-cyan orb with flicker halo + ion trail,
# splashy energy burst — glassy scorch decal + steam hiss, NO dirt crater,
# brief light bloom. Energy damage class, exotics_lab tier.
#
# Wire-in for auto_weapon._fire_plasma_lobber():
#   var shell = WeaponVFXPlasmaLobber.make_plasma_shell(0.35, laser_color)
#   _effects_parent().add_child(shell)
#   WeaponVFXPlasmaLobber.attach_ion_trail(shell, 0.35)
#   _fire_arcing_shell_at(0.35, 4.0, laser_color, 4.5, dps * fire_rate, Vector3.ZERO, 0.6,
#       {"body": "bomb", "custom_shell": shell})
#   # On impact: WeaponVFXPlasmaLobber.plasma_impact(_effects_parent(), end, 4.5, laser_color)

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const MunitionPool = preload("res://scripts/munition_pool.gd")

# Plasma shell: green-cyan emissive core with flickering halo ring.
# Returns a pivot Node3D (oriented -Z forward) containing core + halo.
static func make_plasma_shell(radius: float, colour: Color) -> Node3D:
	var pivot = Node3D.new()
	
	# Core orb: bright additive sphere
	var core = MeshInstance3D.new()
	core.mesh = MunitionPool.unit_sphere()
	core.scale = Vector3.ONE * radius
	core.material_override = MunitionPool.emissive(colour, Color(0.2, 1.0, 0.6), 3.0)
	pivot.add_child(core)
	
	# Flicker halo: larger additive ring that pulses via shader-like scale wobble
	# Done as a child MeshInstance3D with a repeating tween (no per-frame script cost)
	var halo = MeshInstance3D.new()
	halo.mesh = MunitionPool.unit_taper(0.0)  # flat ring
	halo.scale = Vector3(radius * 1.8, 0.02, radius * 1.8)
	halo.material_override = MunitionPool.additive_emissive(Color(colour.r, colour.g, colour.b, 0.45), colour, 1.8)
	halo.rotate_x(-PI / 2)
	pivot.add_child(halo)
	
	# Store halo reference for the flight tween to pulse it
	pivot.set_meta("_plasma_halo", halo)
	pivot.set_meta("_plasma_colour", colour)
	
	return pivot


# Ion trail: thin GPUParticles3D plume (world-space, local_coords=false)
# Scaled for a lobber shell — lighter than rocket_artillery's 2.6 bulk.
static func attach_ion_trail(shell_node: Node3D, shell_radius: float) -> void:
	var trail_bulk = 0.7  # distinct from rocket_artillery (2.6) and missile_pod (1.0)
	var plume = VFXEffects.make_missile_trail(shell_node, trail_bulk)
	# Position at shell rear; shell rotates to face velocity each frame
	plume.position = Vector3(0.0, 0.0, shell_radius * 0.9)
	plume.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, true,
		Color(0.15, 0.95, 0.65, 0.55))  # ionized cyan-green, additive
	_detach_trail_on_free(shell_node, plume)


# Clean detach so trail doesn't snap off at impact.
# Mirrors auto_weapon._detach_trail_on_free but kept local to this identity.
static func _detach_trail_on_free(round_node: Node3D, plume: GPUParticles3D) -> void:
	round_node.tree_exiting.connect(func():
		if not is_instance_valid(plume) or not plume.is_inside_tree():
			return
		var scene = round_node.get_tree().current_scene
		if scene == null:
			scene = round_node.get_tree().root
		var world_pos = plume.global_position
		plume.get_parent().remove_child(plume)
		scene.add_child(plume)
		plume.global_position = world_pos
		plume.emitting = false
		var drain = plume.create_tween()
		drain.tween_interval(plume.lifetime + 0.1)
		drain.finished.connect(func():
			if is_instance_valid(plume):
				plume.queue_free())
	)


# Plasma impact: splashy energy burst + glassy scorch decal + steam hiss + brief light bloom.
# NO crater (energy weapon), uses VFXEffects.scorch with emission for the glassy look.
static func plasma_impact(parent: Node3D, world_pos: Vector3, blast_radius: float, colour: Color) -> void:
	# 1. Energy burst — additive flipbook, tighter than fire_burst
	var burst = GPUParticles3D.new()
	burst.name = "PlasmaBurst"
	burst.amount = int(clampf(blast_radius * 8.0, 8, 20))
	burst.lifetime = 0.25
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.emitting = false
	burst.draw_pass_1 = VFXEffects._get_quad()
	burst.material_override = VFXEffects._billboard_material(VFXEffects.FLAME_TEX, true, Color(0.3, 1.0, 0.7, 1.0))
	burst.process_material = VFXEffects._process_material(
		"plasma_burst|%.1f" % blast_radius,
		Vector3(0, 1, 0), 80.0, blast_radius * 1.2, blast_radius * 2.8,
		Vector3(0, 3.0, 0), blast_radius * 0.4, blast_radius * 1.0, 1.5, 2.5, 0.6)
	parent.add_child(burst)
	burst.global_position = world_pos
	burst.emitting = true
	burst.finished.connect(func(): if is_instance_valid(burst): burst.queue_free())
	
	# 2. Ion spark burst (mesh particles) — sharp debris-like flecks
	VFXBurst.spawn(parent, world_pos, Color(0.2, 1.0, 0.6), 14, 0.18, 45.0,
		4.0, 10.0, Vector3(0, -2.0, 0), 0.15, 0.45, VFXBurst.get_sphere_mesh(),
		Vector3.ZERO, colour, 6.0, 8.0)
	
	# 3. Thin ionized smoke veil (replaces heavy smoke_puff)
	var veil = VFXEffects.smoke_puff(parent, world_pos, blast_radius * 0.7, 6,
		Color(0.1, 0.35, 0.25, 0.35))
	
	# 4. Glassy scorch decal — uses emission map for the "wet glass" glow,
	#    then fades to cold albedo. NO crater call.
	var scorch = VFXEffects.scorch(parent, world_pos, blast_radius * 0.85,
		1.2, 14.0)  # burn_seconds=1.2 for the emission pulse
	if is_instance_valid(scorch):
		scorch.texture_emission = VFXEffects.SCORCH_EMISSION_TEX
		scorch.emission_energy = 3.0
		var burn_tween = scorch.create_tween()
		burn_tween.tween_property(scorch, "emission_energy", 0.0, 1.2)
	
	# 5. Brief light bloom — sharp cyan-green pop
	var light = OmniLight3D.new()
	light.light_color = Color(0.2, 1.0, 0.6)
	light.light_energy = 12.0 * blast_radius
	light.omni_range = 8.0 * blast_radius
	light.light_bake_mode = Light3D.BAKE_DISABLED
	parent.add_child(light)
	light.global_position = world_pos
	var lt = parent.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.12)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())
	
	# 6. Audio: steam hiss (energy impact) — via AudioManager
	var am = parent.get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx_3d("energy_impact", world_pos, null, -6.0)


# Flight pulse: call from the arcing shell's tween each frame to pulse the halo.
# Expects the shell pivot to have "_plasma_halo" and "_plasma_colour" meta.
static func pulse_plasma_halo(shell_pivot: Node3D, flight_val: float) -> void:
	var halo = shell_pivot.get_meta("_plasma_halo", null)
	var colour = shell_pivot.get_meta("_plasma_colour", Color.MEDIUM_SPRING_GREEN)
	if not is_instance_valid(halo):
		return
	# Pulse at ~10 Hz over the flight; scale oscillates 0.85-1.15
	var pulse = sin(flight_val * TAU * 5.0) * 0.15 + 1.0
	var base_scale = halo.scale.x
	halo.scale = Vector3(base_scale * pulse, halo.scale.y, base_scale * pulse)
	# Flicker alpha via material modulate (cached material, so create unique per-shell)
	if halo.material_override is StandardMaterial3D:
		var mat = halo.material_override.duplicate() as StandardMaterial3D
		mat.albedo_color = Color(colour.r, colour.g, colour.b, 0.35 + 0.15 * sin(flight_val * TAU * 8.0))
		halo.material_override = mat