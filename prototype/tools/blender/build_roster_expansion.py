import bpy
import bmesh
import math
import os
import mathutils

# Authored sub-parts for the roster expansion (MK19 grenade launcher,
# recoilless rifle, coil gun, autocannon, napalm mortar, mine layer,
# ballista, smoke discharger).
#
# Conventions copied exactly from build_hmg.py / build_artillery.py so these
# parts drop into visual_builder.gd's existing _part() assembly path with no
# special handling:
#   - Blender +Y is FORWARD (the barrel/muzzle direction). Godot's glTF
#     import turns that into the -Z the whole codebase treats as "front".
#   - Blender +Z is UP.
#   - MOUNT parts have their origin at deck level (Z=0), so they sit flush
#     on the hull surface a module is placed against.
#   - RECEIVER/BREECH parts have their origin at trunnion height, matching
#     how visual_builder positions them at Vector3(x, trunnion_y, 0).
#   - BARREL parts have their origin at the receiver's front face and
#     extend along +Y, so barrel_length scaling grows them forward.
#   - Parts are authored at roughly 0.1-0.6 units, the same scale as the
#     existing weapon parts, since visual_builder applies only tweak-driven
#     scaling on top.
#
# Detail level deliberately matches basic_cannon/HMG rather than the
# "primitive box" fallback: latches, bolt rings, cooling slots, hinges,
# handles. VISUAL_ART_DIRECTION.md puts the goofiness at DETAIL scale, never
# in silhouette, so every part here reads as straight-faced hardware.

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
PARTS_DIR = os.path.join(PROJECT_ROOT, "assets", "models", "parts")
os.makedirs(PARTS_DIR, exist_ok=True)


def clear_scene():
	bpy.ops.object.select_all(action='SELECT')
	bpy.ops.object.delete(use_global=False)


def add_box(bm, pos, size, bevel=0.0):
	loc = mathutils.Vector(pos)
	res = bmesh.ops.create_cube(bm, size=1.0)
	for v in res['verts']:
		v.co = loc + mathutils.Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
	if bevel > 0.001:
		edges = [e for e in bm.edges if any(v in res['verts'] for v in e.verts)]
		try:
			bmesh.ops.bevel(bm, geom=edges, offset=bevel, segments=2, affect='EDGES')
		except Exception:
			pass


def _cone(bm, pos, r1, r2, depth, segments, rot=None):
	res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
								radius1=r1, radius2=r2, depth=depth)
	loc = mathutils.Vector(pos)
	for v in res['verts']:
		v.co = (rot @ v.co if rot else v.co) + loc


def add_cyl_z(bm, pos, radius, height, segments=16):
	_cone(bm, pos, radius, radius, height, segments)


def add_cyl_y(bm, pos, radius, height, segments=16):
	_cone(bm, pos, radius, radius, height, segments, mathutils.Matrix.Rotation(math.radians(90), 4, 'X'))


def add_cyl_x(bm, pos, radius, height, segments=16):
	_cone(bm, pos, radius, radius, height, segments, mathutils.Matrix.Rotation(math.radians(90), 4, 'Y'))


def add_taper_y(bm, pos, r_back, r_front, height, segments=16):
	"""Truncated cone along +Y. r_back is the -Y end, r_front the +Y end."""
	# create_cone's radius1 is at -depth/2, radius2 at +depth/2; the X
	# rotation below flips Z->Y, so radius1 ends up at the +Y side.
	_cone(bm, pos, r_front, r_back, height, segments, mathutils.Matrix.Rotation(math.radians(90), 4, 'X'))


def bolt_ring(bm, y, radius, count=8, bolt_r=0.008, bolt_len=0.014):
	"""A ring of small bolt heads around a barrel/collar at station `y`."""
	for i in range(count):
		a = (i / count) * math.tau
		add_cyl_y(bm, (math.cos(a) * radius, y, math.sin(a) * radius), bolt_r, bolt_len, segments=6)



def add_helix(bm, pos, coil_r, length, turns, wire_r, segs_per_turn=12, minor_seg=6, axis='Z'):
	"""A swept helical coil spring. Built as a real swept tube rather than a
	stack of separate rings: at these sizes a ring stack reads as a threaded
	collar, and the whole point of putting a spring on the model is that a
	spring is instantly legible as 'this absorbs recoil'."""
	total = int(turns * segs_per_turn)
	rings = []
	for i in range(total + 1):
		t = i / segs_per_turn
		a = t * math.tau
		h = (i / max(1, total)) * length - length / 2.0
		# Centre of the wire cross-section at this station, and the tangent.
		cx, cy = math.cos(a) * coil_r, math.sin(a) * coil_r
		tangent = mathutils.Vector((-math.sin(a) * coil_r * math.tau / segs_per_turn,
									 math.cos(a) * coil_r * math.tau / segs_per_turn,
									 length / max(1, total))).normalized()
		# Any two vectors perpendicular to the tangent give the cross-section.
		up = mathutils.Vector((0, 0, 1))
		if abs(tangent.dot(up)) > 0.95:
			up = mathutils.Vector((1, 0, 0))
		n1 = tangent.cross(up).normalized()
		n2 = tangent.cross(n1).normalized()
		ring = []
		for j in range(minor_seg):
			b = (j / minor_seg) * math.tau
			off = n1 * (math.cos(b) * wire_r) + n2 * (math.sin(b) * wire_r)
			co = mathutils.Vector((cx, cy, h)) + off
			if axis == 'Y':
				co = mathutils.Vector((co.x, co.z, co.y))
			elif axis == 'X':
				co = mathutils.Vector((co.z, co.y, co.x))
			ring.append(bm.verts.new(co + mathutils.Vector(pos)))
		rings.append(ring)
	for i in range(total):
		for j in range(minor_seg):
			a0 = rings[i][j]
			a1 = rings[i][(j + 1) % minor_seg]
			b0 = rings[i + 1][j]
			b1 = rings[i + 1][(j + 1) % minor_seg]
			try:
				bm.faces.new((a0, a1, b1, b0))
			except ValueError:
				pass


def add_tube_between(bm, p0, p1, radius, segments=8):
	"""A round tube spanning two points - for welded tubular framing, which
	is what makes a mount read as fabricated structure instead of as a solid
	milled block."""
	a = mathutils.Vector(p0)
	b = mathutils.Vector(p1)
	d = b - a
	length = d.length
	if length < 1e-5:
		return
	res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
								radius1=radius, radius2=radius, depth=length)
	rot = mathutils.Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
	mid = (a + b) / 2.0
	for v in res['verts']:
		v.co = (rot @ v.co) + mid


def export_bmesh(bm, object_name, filename, color=(0.20, 0.22, 0.24, 1.0),
				 metallic=0.75, roughness=0.30):
	me = bpy.data.meshes.new(object_name + "_mesh")
	bm.to_mesh(me)
	bm.free()

	obj = bpy.data.objects.new(object_name, me)
	bpy.context.collection.objects.link(obj)

	bpy.ops.object.select_all(action='DESELECT')
	obj.select_set(True)
	bpy.context.view_layer.objects.active = obj
	bpy.ops.object.shade_smooth()
	try:
		obj.data.use_auto_smooth = True
		obj.data.auto_smooth_angle = math.radians(35)
	except Exception:
		pass

	mat = bpy.data.materials.new(name=object_name + "_mat")
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	if bsdf:
		bsdf.inputs['Base Color'].default_value = color
		bsdf.inputs['Metallic'].default_value = metallic
		bsdf.inputs['Roughness'].default_value = roughness
	obj.data.materials.append(mat)

	filepath = os.path.join(PARTS_DIR, filename)
	bpy.ops.export_scene.gltf(filepath=filepath, use_selection=True, export_format='GLB')
	print("Exported:", filepath)
	clear_scene()


# ---------------------------------------------------------------------------
# MK19 GRENADE LAUNCHER
# Squat, boxy, belt-fed. The real weapon's read is a big rectangular
# receiver with a short fat low-velocity tube and a chunky side feed.
# ---------------------------------------------------------------------------
def build_mk19():
	# 1. CRADLE MOUNT - origin at deck level
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.025), 0.17, 0.05, segments=18)      # deck ring
	add_cyl_z(bm, (0, 0, 0.07), 0.12, 0.05, segments=14)       # swivel collar
	for i in range(6):                                          # ring of bolts
		a = (i / 6) * math.tau
		add_cyl_z(bm, (math.cos(a) * 0.145, math.sin(a) * 0.145, 0.055), 0.012, 0.02, segments=6)
	for side in (-1, 1):                                        # trunnion fork
		add_box(bm, (side * 0.13, 0, 0.16), (0.045, 0.15, 0.19), bevel=0.008)
		add_cyl_x(bm, (side * 0.15, 0, 0.25), 0.038, 0.035, segments=12)
	add_box(bm, (0, -0.11, 0.11), (0.10, 0.05, 0.07), bevel=0.006)  # elevation screw block
	add_cyl_z(bm, (0, -0.11, 0.19), 0.014, 0.14, segments=10)
	export_bmesh(bm, "mk19_mount", "mk19_mount.glb", color=(0.16, 0.18, 0.15, 1.0))

	# 2. RECEIVER - origin at trunnion height
	bm = bmesh.new()
	rw, rd, rh = 0.17, 0.40, 0.20
	add_box(bm, (0, -0.04, 0.0), (rw, rd, rh), bevel=0.012)          # main body
	add_box(bm, (0, -0.02, 0.115), (rw * 0.86, rd * 0.62, 0.035), bevel=0.006)  # feed cover
	add_box(bm, (0, -0.20, 0.115), (rw * 0.45, 0.05, 0.045), bevel=0.005)       # cover latch
	add_cyl_x(bm, (0, -0.20, 0.115), 0.012, rw * 0.5, segments=8)              # hinge pin
	# Side cocking rails, both sides
	for side in (-1, 1):
		add_box(bm, (side * (rw * 0.5 + 0.012), -0.02, 0.03), (0.02, rd * 0.7, 0.03), bevel=0.004)
		add_cyl_x(bm, (side * (rw * 0.5 + 0.04), 0.06, 0.03), 0.018, 0.05, segments=10)
	# Rear servo drive + firing solenoid, replacing spade grips and a
	# butterfly trigger. Both of those only make sense with a gunner standing
	# behind the weapon; this is an exterior module on a vehicle.
	add_box(bm, (0, -0.245, 0.02), (rw * 0.8, 0.045, rh * 0.7), bevel=0.006)
	add_cyl_y(bm, (0, -0.305, 0.02), 0.050, 0.075, segments=16)          # servo can
	add_cyl_y(bm, (0, -0.352, 0.02), 0.034, 0.025, segments=14)          # end bell
	add_box(bm, (0, -0.300, -0.045), (0.07, 0.06, 0.045), bevel=0.005)   # solenoid block
	for d in (-1, 1):                                                     # cable glands
		add_cyl_y(bm, (d * 0.050, -0.352, -0.015), 0.011, 0.035, segments=6)
	# Top sensor rail with a compact sight head instead of an iron blade sight
	add_box(bm, (0, 0.06, 0.14), (0.035, 0.16, 0.016), bevel=0.003)
	add_box(bm, (0, 0.125, 0.170), (0.052, 0.060, 0.044), bevel=0.006)
	add_cyl_y(bm, (0, 0.160, 0.170), 0.017, 0.020, segments=12)
	export_bmesh(bm, "mk19_receiver", "mk19_receiver.glb", color=(0.17, 0.19, 0.16, 1.0))

	# 3. BARREL - origin at receiver front face, extends +Y
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.045, 0), 0.062, 0.09, segments=16)      # breech collar
	bolt_ring(bm, 0.045, 0.052, count=8)
	add_cyl_y(bm, (0, 0.20, 0), 0.045, 0.22, segments=16)       # short fat tube
	for i in range(4):                                          # cooling bands
		add_cyl_y(bm, (0, 0.115 + i * 0.055, 0), 0.052, 0.016, segments=16)
	add_taper_y(bm, (0, 0.335, 0), 0.045, 0.055, 0.06, segments=16)  # flared muzzle
	export_bmesh(bm, "mk19_barrel", "mk19_barrel.glb", color=(0.13, 0.14, 0.13, 1.0))

	# 4. AMMO CAN - origin at the side feed tray
	bm = bmesh.new()
	add_box(bm, (-0.15, 0.0, 0.0), (0.19, 0.24, 0.20), bevel=0.012)   # can body
	add_box(bm, (-0.15, 0.0, 0.105), (0.17, 0.22, 0.02), bevel=0.005)  # lid
	for lug_s in (-1, 1):                                              # bolted hoist lugs
		add_box(bm, (-0.15, lug_s * 0.07, 0.122), (0.030, 0.022, 0.030), bevel=0.004)
		add_cyl_x(bm, (-0.15, lug_s * 0.07, 0.130), 0.011, 0.034, segments=8)
	for i in range(3):                                                  # rib stiffeners
		add_box(bm, (-0.15, -0.08 + i * 0.08, -0.02), (0.20, 0.014, 0.13), bevel=0.003)
	# Belt of linked rounds curving up into the receiver
	for i in range(5):
		add_box(bm, (-0.10 + i * 0.018, 0.02 + i * 0.012, 0.06 + i * 0.012),
				(0.030, 0.028, 0.022), bevel=0.004)
	export_bmesh(bm, "mk19_ammo_can", "mk19_ammo_can.glb", color=(0.22, 0.26, 0.18, 1.0),
				 metallic=0.4, roughness=0.6)


# ---------------------------------------------------------------------------
# RECOILLESS RIFLE
# One long open tube with a flared venturi at the BACK. The venturi is the
# whole visual identity, and it points where the backblast damage cone goes.
# ---------------------------------------------------------------------------
def build_recoilless():
	# 1. TRIPOD/PINTLE MOUNT - origin at deck
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.02), 0.15, 0.04, segments=18)
	for i in range(3):                                       # three splayed legs
		a = (i / 3) * math.tau + 0.5
		lx, ly = math.cos(a) * 0.16, math.sin(a) * 0.16
		add_box(bm, (lx * 0.6, ly * 0.6, 0.05), (0.05, 0.05, 0.03), bevel=0.005)
		add_cyl_z(bm, (lx, ly, 0.03), 0.022, 0.06, segments=8)
	add_cyl_z(bm, (0, 0, 0.10), 0.055, 0.12, segments=14)    # centre post
	for side in (-1, 1):                                     # yoke arms
		add_box(bm, (side * 0.10, 0, 0.20), (0.035, 0.13, 0.16), bevel=0.007)
		add_cyl_x(bm, (side * 0.115, 0, 0.27), 0.032, 0.03, segments=12)
	export_bmesh(bm, "recoilless_mount", "recoilless_mount.glb", color=(0.24, 0.23, 0.20, 1.0))

	# 2. BREECH ASSEMBLY - origin at trunnion. Split out of the tube so
	#    barrel_length stretches ONLY the tube: the breech ring, sight and
	#    trigger grip are fixed hardware and must keep their proportions
	#    whatever length the tube is set to.
	bm = bmesh.new()
	add_cyl_y(bm, (0, -0.04, 0), 0.082, 0.12, segments=20)    # breech ring
	bolt_ring(bm, -0.04, 0.070, count=10)
	add_cyl_y(bm, (0, 0.03, 0), 0.070, 0.03, segments=20)     # tube collar
	# Sensor head on a riser, offset left. A long eyepieced telescope on a
	# riser reads as something a gunner puts their face to; a short boxed
	# camera with the lens on the front does not.
	add_box(bm, (-0.075, 0.045, 0.078), (0.052, 0.075, 0.060), bevel=0.006)
	add_cyl_y(bm, (-0.075, 0.092, 0.078), 0.024, 0.030, segments=14)
	add_cyl_y(bm, (-0.075, 0.112, 0.078), 0.019, 0.014, segments=14)
	add_box(bm, (-0.075, 0.100, 0.104), (0.058, 0.048, 0.012), bevel=0.003)  # sunshade
	# Firing solenoid and conduit under the breech, not a trigger grip
	add_cyl_z(bm, (0, 0.005, -0.075), 0.030, 0.070, segments=14)
	add_box(bm, (0, 0.005, -0.115), (0.052, 0.048, 0.026), bevel=0.005)
	for i in range(3):
		add_cyl_y(bm, (0.018, -0.030 - i * 0.006, -0.098 + i * 0.012), 0.008, 0.070, segments=6)
	export_bmesh(bm, "recoilless_breech", "recoilless_breech.glb", color=(0.24, 0.23, 0.20, 1.0))

	# 3. TUBE - origin at the breech's front face, extends +Y so a
	#    barrel_length scale grows it forward and nothing else moves.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.36, 0), 0.062, 0.72, segments=20)     # main tube
	add_cyl_y(bm, (0, 0.70, 0), 0.070, 0.05, segments=20)     # muzzle collar
	for i in range(3):                                        # reinforcing bands
		add_cyl_y(bm, (0, 0.14 + i * 0.20, 0), 0.070, 0.022, segments=20)
	# Cable conduit clipped along the top, replacing a carry handle - nobody
	# shoulder-carries a module bolted to a vehicle.
	add_cyl_y(bm, (0, 0.30, 0.080), 0.011, 0.34, segments=8)
	for hy in (0.19, 0.30, 0.41):
		add_box(bm, (0, hy, 0.074), (0.024, 0.020, 0.022), bevel=0.003)
	export_bmesh(bm, "recoilless_tube", "recoilless_tube.glb", color=(0.26, 0.25, 0.21, 1.0))

	# 4. VENTURI / BLAST NOZZLE - origin at tube rear, flares toward -Y
	bm = bmesh.new()
	add_cyl_y(bm, (0, -0.03, 0), 0.075, 0.06, segments=20)          # throat
	add_taper_y(bm, (0, -0.14, 0), 0.155, 0.072, 0.17, segments=22)  # bell, wide at -Y
	add_cyl_y(bm, (0, -0.228, 0), 0.158, 0.022, segments=22)         # lip ring
	for i in range(6):                                               # external ribs
		a = (i / 6) * math.tau
		add_box(bm, (math.cos(a) * 0.115, -0.14, math.sin(a) * 0.115),
				(0.016, 0.16, 0.016), bevel=0.003)
	export_bmesh(bm, "recoilless_venturi", "recoilless_venturi.glb", color=(0.12, 0.12, 0.12, 1.0),
				 metallic=0.85, roughness=0.45)


# ---------------------------------------------------------------------------
# COIL GUN
# Reads as a related-but-distinct sibling to the railgun: a slim rail
# wrapped in a stack of copper accelerator coils, fed by capacitor cans.
# ---------------------------------------------------------------------------
def build_coilgun():
	# 1. MOUNT - origin at deck
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.025), 0.19, 0.05, segments=20)
	add_cyl_z(bm, (0, 0, 0.075), 0.14, 0.05, segments=16)
	for i in range(8):
		a = (i / 8) * math.tau
		add_box(bm, (math.cos(a) * 0.165, math.sin(a) * 0.165, 0.05), (0.03, 0.03, 0.035), bevel=0.004)
	for side in (-1, 1):
		add_box(bm, (side * 0.145, -0.02, 0.17), (0.05, 0.18, 0.20), bevel=0.008)
		add_cyl_x(bm, (side * 0.17, 0.02, 0.27), 0.042, 0.035, segments=14)
	# Cable conduit running up the rear of the mount
	add_cyl_z(bm, (0, -0.14, 0.13), 0.026, 0.24, segments=12)
	add_cyl_y(bm, (0, -0.10, 0.25), 0.026, 0.09, segments=12)
	export_bmesh(bm, "coilgun_mount", "coilgun_mount.glb", color=(0.20, 0.24, 0.28, 1.0))

	# 2. BREECH BLOCK - origin at trunnion. Separate from the rail so the
	#    stage-count tweak can lengthen the rail without stretching the
	#    breech, its hatch or its hinge.
	bm = bmesh.new()
	add_box(bm, (0, -0.06, 0.0), (0.17, 0.20, 0.17), bevel=0.014)    # breech block
	add_box(bm, (0, -0.06, 0.10), (0.12, 0.14, 0.03), bevel=0.005)   # loading hatch
	add_cyl_x(bm, (0, -0.13, 0.10), 0.012, 0.13, segments=8)         # hatch hinge
	add_box(bm, (0, -0.16, 0.0), (0.14, 0.03, 0.14), bevel=0.005)    # rear plate
	export_bmesh(bm, "coilgun_breech", "coilgun_breech.glb", color=(0.22, 0.25, 0.28, 1.0))

	# 3. RAIL SPINE - origin at the breech's front face, extends +Y.
	bm = bmesh.new()
	add_box(bm, (0, 0.40, 0), (0.085, 0.80, 0.075), bevel=0.010)     # spine
	for side in (-1, 1):                                             # guide rails
		add_box(bm, (side * 0.055, 0.40, 0), (0.018, 0.78, 0.035), bevel=0.004)
	add_cyl_y(bm, (0, 0.82, 0), 0.072, 0.10, segments=18)            # muzzle shroud
	add_cyl_y(bm, (0, 0.885, 0), 0.058, 0.035, segments=18)
	export_bmesh(bm, "coilgun_rail", "coilgun_rail.glb", color=(0.24, 0.27, 0.30, 1.0))

	# 4. ACCELERATOR COIL - a single copper coil, repeated along the rail by
	#    visual_builder so the stage-count tweak is visible. Origin centred.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0, 0), 0.105, 0.055, segments=20)              # winding body
	add_cyl_y(bm, (0, 0, 0), 0.118, 0.014, segments=20)              # outer band
	for i in range(4):                                               # winding grooves
		add_cyl_y(bm, (0, -0.018 + i * 0.012, 0), 0.112, 0.005, segments=20)
	add_box(bm, (0, 0, 0.115), (0.035, 0.045, 0.035), bevel=0.005)   # terminal block
	add_cyl_z(bm, (0, 0, 0.145), 0.010, 0.035, segments=8)           # lug
	export_bmesh(bm, "coilgun_coil", "coilgun_coil.glb", color=(0.62, 0.36, 0.14, 1.0),
				 metallic=0.9, roughness=0.30)

	# 5. CAPACITOR BANK - origin at its mounting face under the breech
	bm = bmesh.new()
	add_box(bm, (0, 0, -0.06), (0.26, 0.24, 0.10), bevel=0.010)      # chassis
	for cx in (-1, 1):                                               # four cans
		for cy in (-1, 1):
			add_cyl_z(bm, (cx * 0.07, cy * 0.07, 0.03), 0.048, 0.14, segments=14)
			add_cyl_z(bm, (cx * 0.07, cy * 0.07, 0.105), 0.030, 0.02, segments=10)
	add_box(bm, (0, 0, 0.115), (0.20, 0.03, 0.016), bevel=0.003)     # busbar
	export_bmesh(bm, "coilgun_capacitors", "coilgun_capacitors.glb", color=(0.30, 0.33, 0.36, 1.0))


# ---------------------------------------------------------------------------
# AUTOCANNON - M230 chain gun, second pass
#
# The first remodel was still reading as "bigger machine gun": a boxy receiver
# with a stubby barrel on a pintle, which is the same silhouette as the HMG at
# 120% scale. Rebuilt against Chris's reference photo of an airframe-mounted
# installation, which is a completely different object, and the differences
# are all structural rather than decorative:
#
#   1. THE BARREL IS THE SILHOUETTE. Very long, very slim, and projecting a
#      long way clear of everything else - so the gun reads as "reach" rather
#      than "volume of fire". The old one was barely longer than its receiver.
#   2. A DISTINCTIVE MUZZLE: a ribbed/fluted sleeve near the tip and then a
#      flared bell, unmistakable at a distance and nothing like the plain
#      crowned pipe an HMG carries.
#   3. EXPOSED HELICAL RECOIL SPRINGS. The single most legible cue in the
#      reference - big open coil springs you can see daylight through. No
#      machine gun has these on the outside.
#   4. TUBULAR WELDED FRAMING, not milled blocks. Round tube stock triangulated
#      into an A-frame, so the mount reads as fabricated aircraft structure.
#   5. HYDRAULIC HOSES AND CABLE RUNS everywhere, with connector blocks and
#      P-clips, draped rather than routed in straight lines.
#
# The chain drive housing stays - it is what makes it an M230 rather than a
# generic cannon - but it no longer dominates, because in the reference the
# structure and the barrel do.
# ---------------------------------------------------------------------------
def build_autocannon():
	# 1. TUBULAR CHIN MOUNT - origin at deck. Welded tube A-frame with the
	#    recoil springs standing in it, not a solid pintle.
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.018), 0.170, 0.036, segments=22)          # deck ring
	for i in range(12):
		a = (i / 12) * math.tau
		add_cyl_z(bm, (math.cos(a) * 0.150, math.sin(a) * 0.150, 0.040), 0.010, 0.016, segments=6)
	add_cyl_z(bm, (0, 0, 0.062), 0.108, 0.052, segments=20)          # azimuth drum
	add_box(bm, (0, 0.080, 0.062), (0.115, 0.050, 0.060), bevel=0.007)   # drive gearbox
	add_cyl_y(bm, (0, 0.112, 0.062), 0.026, 0.026, segments=12)

	# Welded tube A-frame: two forward legs up to the trunnions, two rear
	# legs, cross-braced. This is the shape doing most of the work.
	for side in (-1, 1):
		add_tube_between(bm, (side * 0.055, 0.030, 0.090), (side * 0.145, 0.050, 0.265), 0.020)
		add_tube_between(bm, (side * 0.055, -0.045, 0.090), (side * 0.145, 0.010, 0.265), 0.020)
		add_tube_between(bm, (side * 0.145, 0.050, 0.265), (side * 0.145, 0.010, 0.265), 0.018)
		# Cross-brace back down to the drum
		add_tube_between(bm, (side * 0.145, 0.010, 0.265), (0, -0.060, 0.100), 0.014)
		# Trunnion bearing at the apex
		add_cyl_x(bm, (side * 0.150, 0.030, 0.268), 0.040, 0.036, segments=16)
		add_cyl_x(bm, (side * 0.172, 0.030, 0.268), 0.020, 0.014, segments=10)
		for i in range(6):
			a = (i / 6) * math.tau
			add_cyl_x(bm, (side * 0.170, 0.030 + math.cos(a) * 0.028, 0.268 + math.sin(a) * 0.028),
					  0.006, 0.010, segments=6)

	# EXPOSED RECOIL SPRINGS - the reference's loudest cue. Big open coils
	# standing between the deck and the cradle, one each side.
	for side in (-1, 1):
		add_cyl_z(bm, (side * 0.098, -0.075, 0.058), 0.038, 0.028, segments=14)   # lower seat
		add_helix(bm, (side * 0.098, -0.075, 0.150), 0.033, 0.170, 6.0, 0.0085)
		add_cyl_z(bm, (side * 0.098, -0.075, 0.242), 0.038, 0.026, segments=14)   # upper seat
		add_cyl_z(bm, (side * 0.098, -0.075, 0.150), 0.013, 0.190, segments=10)   # guide rod
		add_box(bm, (side * 0.098, -0.075, 0.264), (0.048, 0.036, 0.024), bevel=0.004)

	# Hydraulic actuator on the centreline behind the springs
	add_cyl_z(bm, (0, -0.115, 0.115), 0.030, 0.130, segments=14)
	add_cyl_z(bm, (0, -0.115, 0.200), 0.014, 0.070, segments=10)
	add_box(bm, (0, -0.115, 0.240), (0.040, 0.032, 0.022), bevel=0.004)

	# HOSES AND CABLE RUNS - draped, with P-clips and a connector block.
	for i in range(3):
		add_tube_between(bm, (-0.100, -0.100 + i * 0.014, 0.100 + i * 0.010),
						 (0.100, -0.100 + i * 0.014, 0.100 + i * 0.010), 0.008, segments=6)
	for side in (-1, 1):
		add_tube_between(bm, (side * 0.100, -0.096, 0.106), (side * 0.140, -0.030, 0.230), 0.009, segments=6)
		add_tube_between(bm, (side * 0.140, -0.030, 0.230), (side * 0.120, 0.060, 0.262), 0.009, segments=6)
	add_box(bm, (0, -0.140, 0.072), (0.072, 0.040, 0.036), bevel=0.005)      # connector block
	for i in range(3):
		add_cyl_y(bm, (-0.022 + i * 0.022, -0.166, 0.072), 0.008, 0.020, segments=6)
	export_bmesh(bm, "autocannon_mount", "autocannon_mount.glb", color=(0.19, 0.20, 0.22, 1.0))

	# 2. RECEIVER - origin at trunnion. Slimmer and lower than the last pass:
	#    in the reference the receiver is a modest part of the object, and it
	#    was the chunky receiver that made this read as a machine gun.
	bm = bmesh.new()
	rw, rd, rh = 0.135, 0.285, 0.140
	add_box(bm, (0, -0.040, 0.0), (rw, rd, rh), bevel=0.011)
	add_box(bm, (0, -0.030, 0.080), (rw * 0.78, rd * 0.75, 0.022), bevel=0.005)  # top cover
	for i in range(3):
		add_box(bm, (0, -0.120 + i * 0.080, 0.094), (rw * 0.52, 0.016, 0.010), bevel=0.002)

	# Chain drive housing on the left flank - present and readable, but no
	# longer the widest thing on the gun.
	add_box(bm, (-0.086, -0.040, 0.006), (0.040, 0.225, 0.108), bevel=0.017)
	add_cyl_x(bm, (-0.110, 0.038, 0.006), 0.044, 0.022, segments=18)
	add_cyl_x(bm, (-0.110, -0.116, 0.006), 0.038, 0.022, segments=16)
	add_cyl_x(bm, (-0.124, 0.038, 0.006), 0.017, 0.018, segments=10)
	for i in range(6):
		a = (i / 6) * math.tau
		add_cyl_x(bm, (-0.106, 0.038 + math.cos(a) * 0.053, 0.006 + math.sin(a) * 0.053),
				  0.006, 0.012, segments=6)
	add_cyl_y(bm, (-0.086, -0.196, 0.006), 0.036, 0.068, segments=14)       # drive motor
	add_cyl_y(bm, (-0.086, -0.234, 0.006), 0.026, 0.018, segments=12)

	# Right flank: ejection chute and inspection plate
	add_box(bm, (rw * 0.5 + 0.008, -0.066, -0.018), (0.013, 0.095, 0.050), bevel=0.004)
	add_box(bm, (rw * 0.5 + 0.005, 0.030, 0.016), (0.009, 0.075, 0.062), bevel=0.004)

	# Recoil rails running back either side, with their own small springs -
	# echoes the mount's springs and ties the two together.
	for side in (-1, 1):
		add_cyl_y(bm, (side * 0.082, -0.075, 0.048), 0.020, 0.230, segments=12)
		add_helix(bm, (side * 0.082, -0.075, 0.048), 0.026, 0.140, 5.0, 0.0060, axis='Y')
		add_cyl_y(bm, (side * 0.082, 0.048, 0.048), 0.028, 0.024, segments=12)
		add_cyl_y(bm, (side * 0.082, -0.198, 0.048), 0.030, 0.028, segments=12)

	# Trunnion lugs
	for side in (-1, 1):
		add_box(bm, (side * (rw * 0.5 + 0.010), 0.015, 0.0), (0.024, 0.062, 0.066), bevel=0.005)
		add_cyl_x(bm, (side * (rw * 0.5 + 0.026), 0.015, 0.0), 0.028, 0.018, segments=14)

	# Feed throat underneath
	add_box(bm, (0, -0.015, -0.088), (0.092, 0.100, 0.040), bevel=0.007)
	# Breech backplate. This is now the face the buffer group below bolts to,
	# rather than a bare end cap with two hoses on it.
	add_box(bm, (0, -0.190, 0.010), (0.120, 0.024, 0.120), bevel=0.006)

	# ------------------------------------------------------------------
	# REARWARD BUFFER GROUP (Chris, 2026-08-03: "buffer tubes and mechanical
	# parts projecting backwards from the trunnion").
	#
	# WHY. Every other gun in this family carries real hardware behind the
	# trunnion, and the autocannon did not:
	#   hmg_receiver    reaches y = -0.345 (rear plate, servo can, end bell,
	#                   cable glands, junction box)
	#   amr_buffer      reaches y = -0.360 (fat buffer tube with cooling ribs,
	#                   twin hydraulic rams, accumulators, manifold)
	#   recoilless      reaches y = -0.228 (flared venturi)
	#   autocannon      reached y = -0.225, and that was a flat plate with two
	#                   hose stubs on it - nothing with any mass to it.
	# So from behind, or in profile past the trunnion, this read as a barrel
	# stuck straight into a box while its siblings read as machinery.
	#
	# The exposed recoil-spring rails above (z = +0.048) are deliberately left
	# alone and NOT enclosed: they are the visual tie to the mount's big open
	# springs. The new group sits at and below trunnion height instead, so the
	# rear stacks up in layers rather than one system hiding another.
	#
	# No charging handle, no spade grips, no gunner's controls - see
	# build_hmg.py's note on why the HMG's spade grips became a servo can.
	# Everything here is a gas/hydraulic part or a cable run.

	# Central recuperator, straight back off the breech face on the trunnion
	# axis - the "buffer tube" proper, and the dominant new mass.
	add_cyl_y(bm, (0, -0.207, 0.006), 0.068, 0.030, segments=22)          # front gland
	bolt_ring(bm, -0.207, 0.058, count=10, bolt_r=0.009, bolt_len=0.018)
	add_cyl_y(bm, (0, -0.270, 0.006), 0.056, 0.140, segments=22)          # tube body
	for i in range(4):                                                     # cooling ribs
		add_cyl_y(bm, (0, -0.228 - i * 0.038, 0.006), 0.064, 0.015, segments=22)
	add_cyl_y(bm, (0, -0.352, 0.006), 0.062, 0.022, segments=22)           # rear cap
	add_cyl_y(bm, (0, -0.372, 0.006), 0.030, 0.018, segments=14)           # charging boss
	add_cyl_y(bm, (0, -0.386, 0.006), 0.012, 0.012, segments=10)           # gas port

	# Twin buffer cylinders flanking it, slung lower, with exposed rods running
	# forward into the receiver - the same arrangement as amr_buffer's rams.
	for side in (-1, 1):
		add_cyl_y(bm, (side * 0.088, -0.252, -0.048), 0.036, 0.145, segments=16)
		add_cyl_y(bm, (side * 0.088, -0.176, -0.048), 0.042, 0.022, segments=16)   # gland
		add_cyl_y(bm, (side * 0.088, -0.135, -0.048), 0.015, 0.068, segments=12)   # rod
		add_cyl_y(bm, (side * 0.088, -0.332, -0.048), 0.042, 0.022, segments=16)   # rear cap
		# Accumulator standing off each cylinder
		add_cyl_z(bm, (side * 0.088, -0.286, -0.008), 0.025, 0.052, segments=14)
		add_cyl_z(bm, (side * 0.088, -0.286, 0.026), 0.017, 0.016, segments=12)

	# Rear yoke plate the three tubes pass through, tying them into one group
	# instead of three separate sticks.
	add_box(bm, (0, -0.312, -0.020), (0.215, 0.018, 0.125), bevel=0.005)
	for side in (-1, 1):
		add_cyl_y(bm, (side * 0.098, -0.312, 0.048), 0.012, 0.026, segments=8)

	# Underslung hydraulic manifold with its ports, and the cable run forward
	# to the receiver. Same role as hmg_receiver's junction box.
	add_box(bm, (0, -0.262, -0.098), (0.165, 0.078, 0.038), bevel=0.006)
	for i in range(4):
		add_cyl_z(bm, (-0.052 + i * 0.035, -0.262, -0.126), 0.010, 0.026, segments=8)
	for i in range(3):
		add_cyl_x(bm, (0, -0.222 - i * 0.052, -0.082), 0.009, 0.205, segments=8)
	add_tube_between(bm, (0.070, -0.226, -0.086), (0.070, -0.060, -0.070), 0.008, segments=6)
	add_tube_between(bm, (-0.070, -0.226, -0.086), (-0.070, -0.060, -0.070), 0.008, segments=6)
	export_bmesh(bm, "autocannon_receiver", "autocannon_receiver.glb", color=(0.20, 0.21, 0.23, 1.0))

	# 3. BARREL - origin at receiver face, extends +Y. LONG and SLIM, with the
	#    reference's ribbed sleeve and flared bell at the muzzle. This part is
	#    doing most of the work of not looking like a machine gun.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.040, 0), 0.050, 0.080, segments=18)       # barrel nut
	bolt_ring(bm, 0.040, 0.042, count=8)
	add_taper_y(bm, (0, 0.110, 0), 0.044, 0.030, 0.060, segments=16)
	add_cyl_y(bm, (0, 0.700, 0), 0.026, 1.120, segments=16)       # the long thin tube
	# Barrel clamps at intervals, with hose clips hanging off them
	for i in range(3):
		band_y = 0.300 + i * 0.290
		add_cyl_y(bm, (0, band_y, 0), 0.034, 0.020, segments=16)
		add_box(bm, (0, band_y, 0.038), (0.024, 0.016, 0.024), bevel=0.003)
	# RIBBED MUZZLE SLEEVE - a stack of raised bands, the reference's tell
	for i in range(7):
		add_cyl_y(bm, (0, 1.190 + i * 0.026, 0), 0.040, 0.017, segments=18)
	add_cyl_y(bm, (0, 1.280, 0), 0.031, 0.070, segments=18)       # gap before the bell
	# FLARED BELL at the tip
	add_taper_y(bm, (0, 1.340, 0), 0.034, 0.052, 0.055, segments=20)
	add_cyl_y(bm, (0, 1.376, 0), 0.052, 0.022, segments=20)
	add_cyl_y(bm, (0, 1.392, 0), 0.044, 0.014, segments=20)
	export_bmesh(bm, "autocannon_barrel", "autocannon_barrel.glb", color=(0.13, 0.14, 0.15, 1.0))

	# 4. LINKLESS AMMO MAGAZINE - its own part so the drum_size tweak scales
	#    ONLY the magazine. Origin at the receiver's underside feed throat.
	bm = bmesh.new()
	# Deliberately modest. At its first size this drum was physically wider
	# than the receiver and stood taller than the trunnion, so it read as the
	# main body of the weapon with a gun bolted to it - the drum, not the
	# barrel, became the silhouette. An ammunition store should be legible
	# and subordinate.
	add_cyl_z(bm, (0, -0.040, -0.128), 0.092, 0.110, segments=20)      # drum body
	add_cyl_z(bm, (0, -0.040, -0.070), 0.074, 0.016, segments=20)      # lid
	add_cyl_z(bm, (0, -0.040, -0.186), 0.080, 0.014, segments=20)      # floor
	for i in range(8):
		a = (i / 8) * math.tau
		add_box(bm, (math.cos(a) * 0.086, -0.040 + math.sin(a) * 0.086, -0.128),
				(0.016, 0.016, 0.100), bevel=0.003)
	add_cyl_z(bm, (0, -0.040, -0.128), 0.026, 0.124, segments=12)      # centre auger
	# Linkless chute curving up into the throat, with a hose clipped alongside
	for i in range(5):
		add_box(bm, (0, -0.036 + i * 0.009, -0.070 + i * 0.019), (0.054, 0.030, 0.026), bevel=0.004)
	add_tube_between(bm, (0.040, -0.040, -0.090), (0.040, 0.000, 0.010), 0.007, segments=6)
	add_box(bm, (0, 0.004, 0.010), (0.062, 0.042, 0.030), bevel=0.005)
	export_bmesh(bm, "autocannon_ammo_box", "autocannon_ammo_box.glb", color=(0.21, 0.24, 0.20, 1.0),
				 metallic=0.4, roughness=0.6)


# ---------------------------------------------------------------------------
# ANTI-MATERIEL RIFLE - Bushmaster-III-derived precision cannon
#
# The roster has no PRECISION weapon at all: everything is DPS or splash.
# This one lives or dies on a single very large per-shot number against the
# armor thresholds, so its silhouette has to promise that - long, thin,
# deliberate, and covered in sighting equipment rather than ammunition.
#
# Reference read (Bushmaster III 35mm), plus Chris's two specifics:
#   - a LONG greebled breech running back THROUGH the trunnions, so the gun
#     is visibly balanced about its middle rather than hung off its back end
#   - an expanded sensor package: day/thermal sight block, laser rangefinder
#     and a meteorological probe, all on the left of the breech
#   - a very long slim tube with a big multi-baffle muzzle brake, authored as
#     a SEPARATE part so barrel_length stretches only the tube
# ---------------------------------------------------------------------------
def build_anti_materiel_rifle():
	# 1. TRUNNION CRADLE MOUNT - origin at deck
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.018), 0.180, 0.036, segments=24)         # base ring
	for i in range(14):
		a = (i / 14) * math.tau
		add_cyl_z(bm, (math.cos(a) * 0.160, math.sin(a) * 0.160, 0.040), 0.009, 0.016, segments=6)
	add_cyl_z(bm, (0, 0, 0.078), 0.120, 0.084, segments=20)         # traverse drum
	add_box(bm, (0, -0.115, 0.070), (0.10, 0.075, 0.075), bevel=0.008)   # traverse gearbox
	add_cyl_y(bm, (0, -0.155, 0.070), 0.028, 0.030, segments=12)

	# Tall trunnion forks - taller than the autocannon's, because the breech
	# they carry passes right through them.
	for side in (-1, 1):
		add_box(bm, (side * 0.150, -0.010, 0.190), (0.046, 0.130, 0.210), bevel=0.009)
		add_cyl_x(bm, (side * 0.176, -0.010, 0.278), 0.046, 0.036, segments=16)
		add_cyl_x(bm, (side * 0.198, -0.010, 0.278), 0.022, 0.016, segments=10)
		for i in range(8):
			a = (i / 8) * math.tau
			add_cyl_x(bm, (side * 0.194, -0.010 + math.cos(a) * 0.033, 0.278 + math.sin(a) * 0.033),
					  0.007, 0.012, segments=6)
		# Equilibrator spring stack alongside each fork
		add_cyl_z(bm, (side * 0.105, -0.100, 0.150), 0.030, 0.150, segments=14)
		for i in range(5):
			add_cyl_z(bm, (side * 0.105, -0.100, 0.090 + i * 0.030), 0.036, 0.012, segments=14)
		add_cyl_z(bm, (side * 0.105, -0.100, 0.240), 0.014, 0.070, segments=10)
	export_bmesh(bm, "amr_mount", "amr_mount.glb", color=(0.19, 0.20, 0.22, 1.0))

	# 2. BREECH - origin at the trunnion. Deliberately LONG, running well
	#    behind the trunnion line, and heavily greebled.
	bm = bmesh.new()
	add_box(bm, (0, -0.150, 0.0), (0.150, 0.520, 0.165), bevel=0.013)      # long breech body
	add_box(bm, (0, -0.140, 0.096), (0.120, 0.440, 0.030), bevel=0.006)    # top rail deck
	for i in range(7):                                                     # rail teeth
		add_box(bm, (0, -0.320 + i * 0.062, 0.117), (0.100, 0.026, 0.016), bevel=0.003)

	# Vertical sliding breech block, part-open, with its operating lever
	add_box(bm, (0, 0.050, 0.010), (0.130, 0.075, 0.150), bevel=0.008)
	add_box(bm, (0, 0.050, 0.058), (0.108, 0.055, 0.030), bevel=0.005)
	add_cyl_x(bm, (0.088, 0.050, 0.052), 0.018, 0.055, segments=12)
	add_box(bm, (0.115, 0.012, 0.052), (0.022, 0.090, 0.020), bevel=0.004)  # operating lever

	# Recoil slides either side, with exposed rods and buffer heads
	for side in (-1, 1):
		add_cyl_y(bm, (side * 0.098, -0.060, 0.070), 0.028, 0.380, segments=14)
		add_cyl_y(bm, (side * 0.098, 0.145, 0.070), 0.036, 0.045, segments=14)
		add_cyl_y(bm, (side * 0.098, -0.265, 0.070), 0.040, 0.055, segments=14)
		for i in range(4):
			add_cyl_y(bm, (side * 0.098, -0.190 + i * 0.075, 0.070), 0.034, 0.014, segments=14)

	# Dual feed chutes off the rear quarters - the Bushmaster's other
	# signature. Kept small: this weapon is not about volume of fire.
	for side in (-1, 1):
		add_box(bm, (side * 0.105, -0.330, -0.030), (0.062, 0.140, 0.085), bevel=0.007)
		add_box(bm, (side * 0.088, -0.240, -0.020), (0.040, 0.080, 0.060), bevel=0.005)
		for i in range(3):
			add_box(bm, (side * 0.105, -0.395 + i * 0.030, -0.075), (0.058, 0.020, 0.016), bevel=0.003)

	# Rear plate: buffer cap, junction box, cable runs
	add_box(bm, (0, -0.415, 0.010), (0.140, 0.030, 0.150), bevel=0.007)
	add_cyl_y(bm, (0, -0.445, 0.010), 0.050, 0.040, segments=16)
	add_box(bm, (-0.075, -0.440, -0.055), (0.055, 0.045, 0.050), bevel=0.005)
	for i in range(4):
		add_cyl_y(bm, (-0.075 + i * 0.012, -0.470, -0.055), 0.006, 0.030, segments=6)
	# Ammunition ready-rack strapped along the right flank
	add_box(bm, (0.098, -0.230, 0.075), (0.055, 0.190, 0.055), bevel=0.006)
	for i in range(4):
		add_cyl_y(bm, (0.098, -0.305 + i * 0.050, 0.075), 0.020, 0.042, segments=10)
	export_bmesh(bm, "amr_breech", "amr_breech.glb", color=(0.20, 0.22, 0.21, 1.0))

	# 3. BARREL - origin at the breech's front face, along +Y. Long and thin.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.055, 0), 0.062, 0.110, segments=18)       # barrel nut
	bolt_ring(bm, 0.055, 0.052, count=10)
	add_taper_y(bm, (0, 0.155, 0), 0.052, 0.034, 0.090, segments=18)  # chamber taper
	add_cyl_y(bm, (0, 0.620, 0), 0.030, 0.840, segments=18)       # the long tube
	for i in range(4):                                             # barrel bands
		add_cyl_y(bm, (0, 0.290 + i * 0.200, 0), 0.037, 0.020, segments=18)
	# Fluting along the tube, so it doesn't read as a plain pipe at length
	for i in range(3):
		a = (i / 3) * math.tau
		add_box(bm, (math.cos(a) * 0.031, 0.620, math.sin(a) * 0.031), (0.010, 0.700, 0.010))
	export_bmesh(bm, "amr_barrel", "amr_barrel.glb", color=(0.13, 0.14, 0.15, 1.0))

	# 4. MUZZLE BRAKE - separate part, positioned at the barrel's actual tip
	#    by visual_builder so barrel_length never stretches it. Origin at its
	#    own rear face.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.020, 0), 0.048, 0.040, segments=18)       # collar
	add_cyl_y(bm, (0, 0.115, 0), 0.058, 0.155, segments=18)       # body
	for i in range(3):                                            # baffle slots
		for side in (-1, 1):
			add_box(bm, (side * 0.056, 0.060 + i * 0.045, 0), (0.026, 0.024, 0.070), bevel=0.004)
			add_cyl_x(bm, (side * 0.058, 0.060 + i * 0.045, 0), 0.016, 0.024, segments=10)
	add_cyl_y(bm, (0, 0.205, 0), 0.050, 0.030, segments=18)       # crown ring
	add_cyl_y(bm, (0, 0.228, 0), 0.038, 0.020, segments=16)
	export_bmesh(bm, "amr_muzzle_brake", "amr_muzzle_brake.glb", color=(0.115, 0.10, 0.095, 1.0),
				 metallic=0.62, roughness=0.72)

	# 5. SENSOR HEAD - the "expanded sensors", and deliberately NOT a scope.
	#    An optic sitting on a rifle reads as a telescope by default, which is
	#    the wrong story: this is an unmanned electro-optical head, so every
	#    cue has to say camera and LIDAR rather than eyepiece.
	#      - a rotating LIDAR drum standing proud on top, with a dark glass
	#        band around it and a cap - the single most legible "this is a
	#        sensor" silhouette there is
	#      - a camera in a rectangular housing with a stepped lens barrel
	#        PROTRUDING forward under a sunshade, so the glass is on the
	#        outside where a lens is, not recessed where an eyepiece would be
	#      - heat-sink fins and a data conduit, because this is electronics
	#      - explicitly no eyepiece, no tube running back along the breech
	#    Origin at its mounting face on the breech; apertures face +Y.
	bm = bmesh.new()
	add_box(bm, (0, -0.010, 0.010), (0.140, 0.235, 0.130), bevel=0.010)    # avionics box
	add_box(bm, (0, -0.115, 0.010), (0.120, 0.030, 0.110), bevel=0.006)    # rear bulkhead

	# Heat-sink fins down the flanks - electronics, not glass.
	for side in (-1, 1):
		for i in range(6):
			add_box(bm, (side * 0.074, -0.075 + i * 0.032, 0.010), (0.012, 0.016, 0.100), bevel=0.002)

	# CAMERA: rectangular housing, stepped lens barrel standing proud of it.
	add_box(bm, (-0.030, 0.075, -0.012), (0.078, 0.070, 0.078), bevel=0.007)
	add_cyl_y(bm, (-0.030, 0.122, -0.012), 0.032, 0.036, segments=18)      # lens mount
	add_cyl_y(bm, (-0.030, 0.146, -0.012), 0.028, 0.020, segments=18)      # lens step
	add_cyl_y(bm, (-0.030, 0.160, -0.012), 0.024, 0.014, segments=18)      # front element
	add_box(bm, (-0.030, 0.140, 0.030), (0.086, 0.060, 0.014), bevel=0.004)  # sunshade hood
	for side in (-1, 1):                                                    # hood cheeks
		add_box(bm, (-0.030 + side * 0.040, 0.140, 0.008), (0.010, 0.060, 0.036), bevel=0.003)

	# LIDAR: a drum standing on top, glass band around its middle, capped.
	add_cyl_z(bm, (0.028, 0.010, 0.078), 0.044, 0.026, segments=20)        # base collar
	add_cyl_z(bm, (0.028, 0.010, 0.118), 0.038, 0.056, segments=20)        # drum body
	add_cyl_z(bm, (0.028, 0.010, 0.118), 0.042, 0.030, segments=20)        # glass band
	add_cyl_z(bm, (0.028, 0.010, 0.152), 0.040, 0.014, segments=20)        # cap
	add_cyl_z(bm, (0.028, 0.010, 0.162), 0.014, 0.010, segments=10)        # spindle boss
	for i in range(4):                                                      # cap screws
		a = (i / 4) * math.tau
		add_cyl_z(bm, (0.028 + math.cos(a) * 0.030, 0.010 + math.sin(a) * 0.030, 0.158),
				  0.006, 0.010, segments=6)

	# Small ranging/illuminator aperture beside the camera.
	add_cyl_y(bm, (0.052, 0.090, -0.026), 0.020, 0.060, segments=14)
	add_cyl_y(bm, (0.052, 0.122, -0.026), 0.024, 0.012, segments=14)

	# Data conduit and shock mounts back toward the breech.
	for side in (-1, 1):
		add_cyl_x(bm, (side * 0.072, -0.090, -0.052), 0.016, 0.030, segments=10)
	for i in range(5):
		add_cyl_y(bm, (-0.086, -0.132 - i * 0.005, -0.034 + i * 0.011), 0.008, 0.070, segments=6)
	add_box(bm, (-0.086, -0.128, -0.062), (0.030, 0.040, 0.030), bevel=0.004)  # connector block
	export_bmesh(bm, "amr_sensor_pod", "amr_sensor_pod.glb", color=(0.17, 0.19, 0.18, 1.0),
				 metallic=0.45, roughness=0.55)

	# 5b. RECOIL BUFFER + HYDRAULICS - deliberately OVERSIZED, hanging off the
	#     back of the breech. This is the honest read for a weapon whose whole
	#     premise is one enormous per-shot number: something has to absorb it,
	#     and it should look like it barely can. Its own part rather than baked
	#     into the breech so it can sit past the breech's rear face without
	#     enlarging the part barrel_length scaling has to stay clear of.
	#     Origin at the breech rear face; the assembly runs back along -Y.
	bm = bmesh.new()
	# The big central buffer tube, fat and long
	add_cyl_y(bm, (0, -0.150, 0.010), 0.090, 0.300, segments=22)
	add_cyl_y(bm, (0, 0.005, 0.010), 0.104, 0.030, segments=22)            # front gland
	bolt_ring(bm, 0.005, 0.092, count=10, bolt_r=0.010, bolt_len=0.020)
	for i in range(4):                                                      # cooling ribs
		add_cyl_y(bm, (0, -0.070 - i * 0.062, 0.010), 0.100, 0.022, segments=22)
	add_cyl_y(bm, (0, -0.312, 0.010), 0.100, 0.036, segments=22)           # rear cap
	add_cyl_y(bm, (0, -0.340, 0.010), 0.052, 0.028, segments=16)           # charging boss
	add_cyl_y(bm, (0, -0.360, 0.010), 0.020, 0.020, segments=10)

	# Twin hydraulic rams flanking it, with exposed chromed rods
	for side in (-1, 1):
		add_cyl_y(bm, (side * 0.115, -0.130, -0.030), 0.046, 0.230, segments=16)
		add_cyl_y(bm, (side * 0.115, -0.005, -0.030), 0.052, 0.026, segments=16)
		add_cyl_y(bm, (side * 0.115, 0.055, -0.030), 0.022, 0.100, segments=12)   # ram rod
		add_box(bm, (side * 0.115, 0.108, -0.030), (0.052, 0.030, 0.038), bevel=0.005)
		add_cyl_y(bm, (side * 0.115, -0.256, -0.030), 0.052, 0.030, segments=16)  # rear cap
		# Accumulator sphere on each ram
		add_cyl_z(bm, (side * 0.115, -0.190, 0.048), 0.036, 0.070, segments=14)
		add_cyl_z(bm, (side * 0.115, -0.190, 0.090), 0.026, 0.020, segments=12)

	# Hydraulic plumbing looping between the rams and across the buffer
	for i in range(3):
		add_cyl_x(bm, (0, -0.060 - i * 0.070, -0.062), 0.011, 0.240, segments=8)
	for side in (-1, 1):
		for i in range(3):
			add_cyl_y(bm, (side * 0.150, -0.100 - i * 0.020, -0.045 + i * 0.010), 0.009, 0.170, segments=6)
	# Manifold block underslung between the rams
	add_box(bm, (0, -0.230, -0.070), (0.150, 0.075, 0.048), bevel=0.007)
	for i in range(4):
		add_cyl_z(bm, (-0.048 + i * 0.032, -0.230, -0.100), 0.011, 0.028, segments=8)
	export_bmesh(bm, "amr_buffer", "amr_buffer.glb", color=(0.19, 0.20, 0.21, 1.0),
				 metallic=0.62, roughness=0.42)

	# 6. BIPOD - shown only when the bipod_deploy tweak is on. Origin at the
	#    deck under the barrel; legs splay out and forward.
	bm = bmesh.new()
	add_box(bm, (0, 0.020, 0.140), (0.070, 0.055, 0.045), bevel=0.006)   # yoke clamp
	add_cyl_x(bm, (0, 0.020, 0.140), 0.020, 0.090, segments=12)
	for side in (-1, 1):
		# Upper leg, splayed out and down
		add_cyl_z(bm, (side * 0.075, 0.020, 0.080), 0.016, 0.130, segments=10)
		add_cyl_z(bm, (side * 0.115, 0.020, 0.020), 0.013, 0.055, segments=10)
		# Foot pad with a spade
		add_cyl_z(bm, (side * 0.130, 0.020, 0.008), 0.038, 0.016, segments=14)
		add_box(bm, (side * 0.130, 0.045, 0.006), (0.050, 0.030, 0.012), bevel=0.003)
		# Adjustment collar
		add_cyl_z(bm, (side * 0.105, 0.020, 0.048), 0.022, 0.020, segments=12)
	export_bmesh(bm, "amr_bipod", "amr_bipod.glb", color=(0.18, 0.19, 0.20, 1.0))


# ---------------------------------------------------------------------------
# NAPALM MORTAR
# Short very fat tube at a steep fixed elevation, with a pressurised fuel
# drum and plumbing alongside.
# ---------------------------------------------------------------------------
def build_napalm_mortar():
	# 1. BASEPLATE MOUNT - origin at deck
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.02), 0.24, 0.04, segments=22)          # baseplate
	for i in range(8):                                            # plate ribs
		a = (i / 8) * math.tau
		add_box(bm, (math.cos(a) * 0.15, math.sin(a) * 0.15, 0.045), (0.10, 0.02, 0.02), bevel=0.003)
	add_cyl_z(bm, (0, 0, 0.075), 0.09, 0.07, segments=16)         # swivel
	add_box(bm, (0, 0.06, 0.14), (0.14, 0.10, 0.10), bevel=0.010)  # elevation cradle
	for side in (-1, 1):
		add_cyl_x(bm, (side * 0.075, 0.06, 0.18), 0.028, 0.03, segments=12)
	export_bmesh(bm, "napalm_mount", "napalm_mount.glb", color=(0.30, 0.24, 0.16, 1.0))

	# 2. BREECH CAP - origin at cradle trunnion. Separate part so
	#    barrel_length stretches only the tube, never the sealed breech or
	#    its ignition gear.
	bm = bmesh.new()
	add_cyl_y(bm, (0, -0.05, 0), 0.135, 0.10, segments=20)        # breech cap
	bolt_ring(bm, -0.05, 0.115, count=10, bolt_r=0.010, bolt_len=0.018)
	add_box(bm, (0.10, -0.02, 0.06), (0.045, 0.06, 0.045), bevel=0.005)  # igniter box
	add_cyl_z(bm, (0.10, -0.02, 0.10), 0.010, 0.05, segments=8)
	export_bmesh(bm, "napalm_breech", "napalm_breech.glb", color=(0.30, 0.28, 0.24, 1.0))

	# 3. TUBE - origin at the breech's front face, bore along +Y
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.25, 0), 0.115, 0.50, segments=20)         # fat short tube
	add_taper_y(bm, (0, 0.53, 0), 0.115, 0.135, 0.07, segments=20)  # flared mouth
	for i in range(4):                                            # cooling bands
		add_cyl_y(bm, (0, 0.09 + i * 0.11, 0), 0.126, 0.022, segments=20)
	add_cyl_y(bm, (0.10, 0.23, 0.06), 0.012, 0.42, segments=10)   # ignition line
	export_bmesh(bm, "napalm_tube", "napalm_tube.glb", color=(0.32, 0.30, 0.26, 1.0))

	# 4. FUEL DRUM - origin at its mounting face beside the tube
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.16), 0.115, 0.30, segments=20)         # drum
	add_cyl_z(bm, (0, 0, 0.315), 0.09, 0.03, segments=16)         # top dome
	add_cyl_z(bm, (0, 0, 0.012), 0.12, 0.025, segments=20)        # foot ring
	for i in range(3):                                            # banding hoops
		add_cyl_z(bm, (0, 0, 0.07 + i * 0.09), 0.122, 0.018, segments=20)
	add_cyl_z(bm, (0.0, 0.0, 0.35), 0.022, 0.05, segments=10)     # filler neck
	add_box(bm, (0, 0.0, 0.375), (0.06, 0.06, 0.02), bevel=0.004)  # pressure gauge plate
	# Feed hose curving out toward the tube
	for i in range(5):
		add_cyl_y(bm, (0.0, -0.02 - i * 0.03, 0.30 - i * 0.045), 0.016, 0.05, segments=8)
	export_bmesh(bm, "napalm_fuel_drum", "napalm_fuel_drum.glb", color=(0.52, 0.24, 0.09, 1.0),
				 metallic=0.35, roughness=0.62)


# ---------------------------------------------------------------------------
# MINE LAYER
# Reads as cargo being dispensed, not as a gun: a rack of canisters over a
# rear chute.
# ---------------------------------------------------------------------------
def build_mine_layer():
	# 1. RACK CHASSIS - origin at deck
	bm = bmesh.new()
	add_box(bm, (0, 0, 0.05), (0.46, 0.52, 0.10), bevel=0.010)     # deck pallet
	for cx in (-1, 1):                                             # corner posts
		for cy in (-1, 1):
			add_box(bm, (cx * 0.20, cy * 0.23, 0.20), (0.03, 0.03, 0.22), bevel=0.004)
	add_box(bm, (0, 0, 0.30), (0.46, 0.52, 0.025), bevel=0.005)    # top rail frame
	# Cross bracing on both sides
	for side in (-1, 1):
		add_box(bm, (side * 0.21, 0, 0.19), (0.012, 0.50, 0.02), bevel=0.003)
	add_box(bm, (0, -0.27, 0.16), (0.14, 0.03, 0.12), bevel=0.005)  # control box
	add_cyl_y(bm, (0.05, -0.29, 0.20), 0.012, 0.03, segments=8)
	export_bmesh(bm, "mine_layer_rack", "mine_layer_rack.glb", color=(0.34, 0.32, 0.20, 1.0))

	# 2. SINGLE MINE CANISTER - repeated by visual_builder so the
	#    mines-per-volley tweak is visible on the rack. Origin at its base.
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.035), 0.085, 0.07, segments=18)         # puck body
	add_cyl_z(bm, (0, 0, 0.075), 0.055, 0.02, segments=14)         # fuze well
	add_cyl_z(bm, (0, 0, 0.09), 0.018, 0.02, segments=10)          # pressure plug
	add_cyl_z(bm, (0, 0, 0.035), 0.092, 0.014, segments=18)        # carry band
	for i in range(4):                                             # handle lugs
		a = (i / 4) * math.tau + 0.4
		add_box(bm, (math.cos(a) * 0.088, math.sin(a) * 0.088, 0.05), (0.02, 0.02, 0.02), bevel=0.003)
	export_bmesh(bm, "mine_canister", "mine_canister.glb", color=(0.28, 0.30, 0.18, 1.0),
				 metallic=0.4, roughness=0.6)

	# 3. DISPENSER CHUTE - origin at the rack's rear face, opens toward -Y
	bm = bmesh.new()
	add_box(bm, (0, -0.06, 0.06), (0.20, 0.16, 0.14), bevel=0.008)   # chute body
	add_box(bm, (0, -0.16, 0.02), (0.22, 0.06, 0.10), bevel=0.006)   # exit lip
	for side in (-1, 1):                                             # guide rails
		add_box(bm, (side * 0.10, -0.12, 0.01), (0.014, 0.14, 0.05), bevel=0.003)
	add_cyl_x(bm, (0, -0.02, 0.14), 0.016, 0.20, segments=10)        # feed roller
	export_bmesh(bm, "mine_layer_chute", "mine_layer_chute.glb", color=(0.19, 0.20, 0.17, 1.0))




# ---------------------------------------------------------------------------
# SMOKE DISCHARGER
# Replaces the procedural stub with real hardware: a bracket and a proper
# launcher tube with a fitted canister.
# ---------------------------------------------------------------------------
def build_smoke_discharger():
	# 1. BRACKET - origin at deck
	bm = bmesh.new()
	add_box(bm, (0, 0, 0.03), (0.36, 0.20, 0.06), bevel=0.008)      # base plate
	for cx in (-1, 1):
		add_cyl_z(bm, (cx * 0.15, 0, 0.032), 0.018, 0.024, segments=8)  # bolt bosses
	add_box(bm, (0, 0.02, 0.09), (0.30, 0.13, 0.06), bevel=0.006)   # riser
	add_box(bm, (0, -0.08, 0.075), (0.10, 0.04, 0.045), bevel=0.004)  # wiring junction
	add_cyl_y(bm, (0, -0.115, 0.075), 0.012, 0.04, segments=8)
	export_bmesh(bm, "smoke_discharger_bracket", "smoke_discharger_bracket.glb",
				 color=(0.26, 0.27, 0.28, 1.0))

	# 2. SINGLE LAUNCHER TUBE with canister - repeated and splayed by
	#    visual_builder so the tube-count tweak is visible. Origin at its
	#    base, bore along +Y (visual_builder cants it upward).
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.10, 0), 0.048, 0.20, segments=16)           # tube
	add_cyl_y(bm, (0, 0.005, 0), 0.058, 0.03, segments=16)          # base flange
	bolt_ring(bm, 0.005, 0.050, count=6, bolt_r=0.007, bolt_len=0.012)
	add_cyl_y(bm, (0, 0.19, 0), 0.054, 0.025, segments=16)          # muzzle ring
	add_cyl_y(bm, (0, 0.215, 0), 0.042, 0.03, segments=14)          # canister nose
	add_box(bm, (0.05, 0.06, 0), (0.022, 0.05, 0.022), bevel=0.003)  # firing lead boss
	export_bmesh(bm, "smoke_discharger_tube", "smoke_discharger_tube.glb",
				 color=(0.20, 0.21, 0.19, 1.0))


if __name__ == "__main__":
	clear_scene()
	build_mk19()
	build_recoilless()
	build_coilgun()
	build_autocannon()
	build_anti_materiel_rifle()
	build_napalm_mortar()
	build_mine_layer()
	build_smoke_discharger()
	print("ROSTER_EXPANSION_PARTS_DONE")
