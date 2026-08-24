"""
Kitbash Command mesh generator (Milestone: Visual Refinement pass 2)
Run headlessly with UPBGE's bundled Blender:
  UPBGE-0.30-windows-x86_64\\blender.exe --background --python tools\\blender\\build_meshes.py

Produces two families of assets:
  1. assets/models/hulls/*.glb  - one full chassis/foundation mesh per hull
     catalog entry, authored to match that hull's catalog "size" Vector3
     exactly, with fused-on greeble detail (vents, hatches, rivets,
     antennae, gussets...) so hulls read as distinct silhouettes rather
     than plain boxes/wedges.
  2. assets/models/parts/*.glb  - small reusable "kit" pieces (barrels,
     breeches, drums, domes, missile bodies, wheels, legs, rings...)
     referenced by multiple weapon/locomotion modules in visual_builder.gd.

COORDINATE CONVENTION (verified empirically against this exact export
pipeline - see scratch/probe_axes_*.py/gd):
  Blender is authored Z-up. The bundled glTF exporter's Y-up conversion
  maps  Godot_X = Blender_X,  Godot_Y = Blender_Z,  Godot_Z = Blender_Y.
  Every helper below takes GODOT-space (x, y_up, z_depth) coordinates and
  internally swaps to raw Blender coordinates via GV()/GS(), so all
  authoring code in this file can be written purely in terms of the same
  X/Y/Z semantics used everywhere else in the project (module_catalog.gd
  "size" Vector3, etc.) - no manual axis juggling needed at call sites.

  Runtime contract: authored assets are pre-oriented in final local space
  (no rotation compensation needed). This differs from the old pass-1
  script, which authored barrels along raw Blender Z relying on a
  runtime PI/2 rotation - that convention is retired. mesh_asset_loader.gd
  callers (module_placer.gd, visual_builder.gd) use authored meshes
  directly and only apply the OLD rotation to the procedural fallback
  primitives, which still default to Godot's Y-up CylinderMesh.
"""

import bpy
import bmesh
import math
import os
import mathutils

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
PARTS_DIR = os.path.join(PROJECT_ROOT, "assets", "models", "parts")
HULLS_DIR = os.path.join(PROJECT_ROOT, "assets", "models", "hulls")

os.makedirs(PARTS_DIR, exist_ok=True)
os.makedirs(HULLS_DIR, exist_ok=True)


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

def clear_scene():
	bpy.ops.object.select_all(action='SELECT')
	bpy.ops.object.delete(use_global=False)
	for block in list(bpy.data.meshes):
		if block.users == 0:
			bpy.data.meshes.remove(block)
	for block in list(bpy.data.materials):
		if block.users == 0:
			bpy.data.materials.remove(block)


def GV(x, y, z):
	"""Godot-space (x, y_up, z_depth) -> raw Blender-space tuple."""
	return (x, z, y)


def GS(sx, sy, sz):
	"""Godot-space (width, height, depth) size -> raw Blender-space size."""
	return (sx, sz, sy)


def godot_forward_component(raw_normal):
	"""A bmesh face's raw-Blender-space normal's component along Godot's own
	-Z ("forward"/nose) axis - the inverse of GV()'s (x,y,z)->(x,z,y) swap,
	i.e. raw Blender Y carries Godot's Z-depth. hull_deform.gd's own
	"Forward convention is local -Z: the nose is the most-negative-Z tip"
	comment is the convention this matches - a face whose raw_normal.y is
	strongly negative faces the nose. Used to geometrically classify "hard
	armor" faces (frontal glacis + corner facets) vs. "structural" ones
	without needing to hand-track which named region a face belongs to
	through a convex-hull/bevel/loft construction - see mark_armor_faces().
	"""
	return raw_normal.y


def frontal_armor_predicate(hz, front_frac=0.3, exclude_belly_thresh=-0.6):
	"""Builds a predicate for mark_armor_faces() selecting the frontal arc
	of a hull: any face whose CENTER lies within the front `front_frac` of
	the hull's total length (Godot -Z = nose, see godot_forward_component()'s
	own comment - raw Blender Y carries Godot Z-depth, so a face center's
	raw .y IS its Godot z position directly, no swap needed since this is
	a coordinate VALUE not a normal), excluding belly/underside faces
	(raw normal .z very negative = Godot -Y/downward - see the same axis
	mapping) since those are never visually seen and armoring them would
	be a wasted, invisible area cost against the ~40% ceiling.
	Position-based rather than pure normal-angle: a convex-hull-derived
	hull's glacis/corner faces cluster at unpredictable, hull-specific
	normal angles (found empirically - medium_hull's own glacis+corners
	only reached ~8% of area even at a very permissive normal-angle
	threshold), while "front fraction of length" is a single, directly
	tunable knob per hull that behaves predictably regardless of each
	hull's individual taper geometry."""
	front_z_cutoff = -hz + 2.0 * hz * front_frac
	def predicate(f):
		center = f.calc_center_median()
		is_front = center.y < front_z_cutoff
		is_belly = f.normal.z < exclude_belly_thresh
		return is_front and not is_belly
	return predicate


def outward_face_predicate(threshold=0.4):
	"""For static defenses whose identity is "one hardened outward face,
	one sheltered inward face" rather than a vehicle's nose-to-tail taper
	(bunker_main_meridian's embrasure and rampart_main_meridian's arrow
	slits both face Godot +Z, per those builders' own authoring convention -
	NOT -Z like every vehicle hull's nose) - any face whose normal points
	sufficiently toward Godot +Z (raw Blender +Y, see godot_forward_component())
	is the exposed defensive face, armored; the sheltered back face, top,
	and end caps stay structural."""
	def predicate(f):
		return godot_forward_component(f.normal) > threshold
	return predicate


def vertical_armor_predicate(hy, base_frac=0.4):
	"""For a tall stepped tower with no distinct front/back (tiers stack
	along Godot Y/up, roughly rotationally symmetric per tier) - real
	castle-defense logic instead: the base/lower tiers facing ground-level
	assault are the hardened ones, upper tiers are lighter structural
	stonework. raw Blender Z carries Godot Y-up (see godot_forward_component()'s
	own comment on the GV() axis swap), so a face center's raw .z IS its
	Godot height directly."""
	y_cutoff = -hy + 2.0 * hy * base_frac
	def predicate(f):
		return f.calc_center_median().z < y_cutoff
	return predicate


def mark_armor_faces(bm, predicate):
	"""Sets material_index=1 (hard armor slot, see finalize_dual()) on
	every CURRENT bm.face satisfying predicate(face), leaving everything
	else at the default 0 (structural). Call this AFTER the hull's primary
	silhouette bevel but BEFORE greebles are fused on, so small appliquÃƒÂ©
	fixtures (hatches/vents/antennae) default to reading as structural
	details bolted onto the hull, not armor plate, unless a specific
	greeble helper explicitly marks its own faces afterward. Returns the
	fraction of total face AREA marked armor (not face count - a handful of
	large glacis faces vs. many tiny bevel/greeble faces would otherwise
	misrepresent the actual visual area split) so callers can sanity-check
	against the ~40% ceiling."""
	total_area = 0.0
	armor_area = 0.0
	for f in bm.faces:
		area = f.calc_area()
		total_area += area
		if predicate(f):
			f.material_index = 1
			armor_area += area
	return armor_area / total_area if total_area > 0.0 else 0.0


def rot_matrix(godot_axis, angle_rad):
	"""Rotation matrix for a rotation of angle_rad around the given
	GODOT-space axis ('x','y','z'), expressed for raw Blender-space geometry."""
	if godot_axis == 'y':
		return mathutils.Matrix.Rotation(angle_rad, 3, 'Z')
	elif godot_axis == 'x':
		return mathutils.Matrix.Rotation(angle_rad, 3, 'X')
	else:
		return mathutils.Matrix.Rotation(angle_rad, 3, 'Y')


def new_material(name, color, metallic=0.7, roughness=0.4):
	mat = bpy.data.materials.get(name)
	if mat is None:
		mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	if bsdf:
		bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
		bsdf.inputs["Metallic"].default_value = metallic
		bsdf.inputs["Roughness"].default_value = roughness
	return mat


def make_object_from_bmesh(bm, name):
	mesh = bpy.data.meshes.new(name + "_mesh")
	bm.to_mesh(mesh)
	bm.free()
	mesh.update()
	obj = bpy.data.objects.new(name, mesh)
	bpy.context.collection.objects.link(obj)
	return obj


def finalize(obj, name, color=(0.55, 0.56, 0.58), metallic=0.75, roughness=0.35, smooth=True):
	"""smooth=False gives hard, faceted normals on every face.

	Manufactured parts want the default smooth-with-auto-smooth-crease: a
	machined surface is continuous, and the 35-degree crease keeps real edges
	sharp anyway. Fractured rock wants the opposite. A boulder built from
	planar cuts has genuine flat faces meeting at hard angles, and smooth
	shading averages exactly those normals away, which is what made the old
	boulders read as lumpy balls no matter how the silhouette was noised."""
	obj.name = name
	bpy.ops.object.select_all(action='DESELECT')
	obj.select_set(True)
	bpy.context.view_layer.objects.active = obj
	if smooth:
		bpy.ops.object.shade_smooth()
		try:
			obj.data.use_auto_smooth = True
			obj.data.auto_smooth_angle = math.radians(35)
		except Exception:
			pass
	else:
		bpy.ops.object.shade_flat()
		try:
			obj.data.use_auto_smooth = False
		except Exception:
			pass
	mat = new_material(name + "_mat", color, metallic, roughness)
	if obj.data.materials:
		obj.data.materials[0] = mat
	else:
		obj.data.materials.append(mat)


def finalize_dual(obj, name, structural_color=(0.5, 0.5, 0.52), armor_color=(0.55, 0.56, 0.58),
		structural_metallic=0.15, structural_roughness=0.82, armor_metallic=0.75, armor_roughness=0.4):
	"""Same shading/smoothing setup as finalize(), but assigns TWO material
	slots (0=structural, 1=hard armor) instead of one - see hull_material_
	builder.gd's apply_hull_materials() for the runtime side of this
	convention (surface 0 gets build_structural_material(), surface 1+
	gets build_hull_material()). The actual color/metallic/roughness here
	are Blender-preview-only, same as finalize()'s own color param already
	was - Godot replaces BOTH slots' real materials entirely at runtime via
	set_surface_override_material(), so these values never reach the game;
	they just need to be two genuinely different material resources so
	Blender's glTF exporter treats them as two separate primitives.
	Requires mark_armor_faces() to have already set material_index=1 on
	the relevant bm.faces before make_object_from_bmesh() was called -
	this function only assigns the SLOTS, not which face uses which."""
	obj.name = name
	bpy.ops.object.select_all(action='DESELECT')
	obj.select_set(True)
	bpy.context.view_layer.objects.active = obj
	bpy.ops.object.shade_smooth()
	try:
		obj.data.use_auto_smooth = True
		obj.data.auto_smooth_angle = math.radians(35)
	except Exception:
		pass
	# Deliberately NOT obj.data.materials.clear() first, even though the
	# mesh is always freshly created with 0 slots at this point anyway (so
	# clear() looks harmless/defensive) - empirically, clearing the list
	# clamps every polygon's material_index back to 0 as a data-integrity
	# side effect, and appending the 2 real materials afterward does NOT
	# retroactively fix already-clamped indices. Found by a real "only 1
	# glTF primitive exported despite 244/1380 polygons correctly split at
	# the bmesh/bpy.Mesh level" bug - see DECISIONS_NEEDED.md.
	structural_mat = new_material(name + "_structural_mat", structural_color, structural_metallic, structural_roughness)
	armor_mat = new_material(name + "_armor_mat", armor_color, armor_metallic, armor_roughness)
	obj.data.materials.append(structural_mat)
	obj.data.materials.append(armor_mat)


def export_glb(obj, filepath):
	bpy.ops.object.select_all(action='DESELECT')
	obj.select_set(True)
	bpy.context.view_layer.objects.active = obj
	bpy.ops.export_scene.gltf(
		filepath=filepath,
		use_selection=True,
		export_format='GLB',
		export_yup=True,
		export_apply=True
	)
	print("Exported: " + filepath)


import sys

TARGET_MESHES = []
if "--" in sys.argv:
	idx = sys.argv.index("--")
	if "--only" in sys.argv[idx:]:
		only_idx = sys.argv.index("--only", idx)
		TARGET_MESHES = sys.argv[only_idx+1:]

def export_and_cleanup(obj, out_dir, filename):
	if TARGET_MESHES and filename not in TARGET_MESHES:
		mesh_data = obj.data
		bpy.data.objects.remove(obj, do_unlink=True)
		if mesh_data and mesh_data.users == 0:
			bpy.data.meshes.remove(mesh_data)
		return

	path = os.path.join(out_dir, filename + ".glb")
	export_glb(obj, path)
	mesh_data = obj.data
	bpy.data.objects.remove(obj, do_unlink=True)
	if mesh_data and mesh_data.users == 0:
		bpy.data.meshes.remove(mesh_data)


# ---------------------------------------------------------------------------
# Sidecar JSON writer (matches bake_custom_hull.py:130-202 schema)
# ---------------------------------------------------------------------------
# Every hull in the catalogue ships as a pair: a .glb (the mesh) and a
# sidecar .json with the metadata HullLoader scans at startup. The
# procedural pipeline in build_meshes.py used to write only the .glb;
# the sidecar was generated by the (now-removed) CSG-mesh baker. This
# helper restores the sidecar write for the procedural path, using
# the same per-primitive-derived stats as bake_custom_hull.py so the
# two authoring paths produce interchangeable assets.

def write_hull_sidecar(out_dir, filename, size, color, domain, name=None,
		hp=None, weight=None, metal=None, crystal=None, base_energy=0.0,
		base_vision=20.0, base_power=None, is_foundation=False, category="hull"):
	"""Write the sidecar .json that HullLoader pairs with the .glb.

	Args:
		out_dir:       directory to write into (e.g. HULLS_DIR)
		filename:      stem, no extension (e.g. 'brenntal_medium_a')
		size:          (size_x, size_y, size_z) tuple in Godot space
		color:         (r, g, b, a) tuple
		domain:        "Ground" / "Air" / "Naval" / "Static Defense"
		name:          display name; defaults to the filename title-cased
		hp / weight:   per-hull stats; defaults derived from size
		metal/crystal: per-hull economy cost; defaults derived from size
		base_power:    optional, foundations only - the per-second power a
		              static defense contributes to the player's grid. None
		              (omitted from the JSON) for vehicle hulls.
	"""
	import json
	sx, sy, sz = size
	volume = sx * sy * sz
	# Per-hull stat defaults match bake_custom_hull.py:130-202 so the
	# procedural and primitive-composition paths produce the same
	# metadata for a given hull volume.
	if hp is None:
		hp = 100.0 + volume * 20.0
	if weight is None:
		weight = 50.0 + volume * 15.0
	if metal is None:
		metal = 20 + int(volume * 5.0)
	if crystal is None:
		crystal = 5 + int(volume * 1.0)
	if name is None:
		# 'brenntal_medium_a' -> 'Block Main Meridian A'
		name = ' '.join(p.capitalize() for p in filename.split('_'))
	data = {
		"name": name,
		"hp": round(hp, 1),
		"weight": round(weight, 1),
		"metal": metal,
		"crystal": crystal,
		"size": [round(sx, 3), round(sy, 3), round(sz, 3)],
		"color": [round(color[0], 3), round(color[1], 3), round(color[2], 3),
			round(color[3], 3) if len(color) > 3 else 1.0],
		"domain": domain,
		"base_energy": base_energy,
		"base_vision": base_vision,
		"is_foundation": is_foundation,
		"category": category,
	}
	# base_power is a foundation-only stat. Omit for vehicle hulls so the
	# JSON shape stays close to the bake_custom_hull.py output (which also
	# never wrote base_power for vehicles). foundations: see
	# HULL_REFRESH_PLAN Â§5.7 - the existing 3 (pillbox/tower/wall)
	# have it baked in by the legacy hand-pipeline.
	if base_power is not None:
		data["base_power"] = base_power
	path = os.path.join(out_dir, filename + ".json")
	with open(path, 'w') as f:
		json.dump(data, f, indent=2)
	print("Sidecar: %s" % path)


def export_hull_with_sidecar(obj, out_dir, filename, size, color, domain, **kwargs):
	"""export_and_cleanup + write_hull_sidecar in one call.

	The procedural pipeline's drop-in for bake_custom_hull.py's
	GLB + sidecar pair, so the rest of the engine reads both paths
	the same way.
	"""
	export_and_cleanup(obj, out_dir, filename)
	write_hull_sidecar(out_dir, filename, size, color, domain, **kwargs)


# ---------------------------------------------------------------------------
# Geometric Polish Pass (Section 1) - shared tiered bevel + non-linear taper.
# Bevel width is keyed to a per-mesh reference dimension R rather than ever
# being a fixed world value, so the same three-tier vocabulary reads
# consistently on a tiny greeble or a whole hull. R excludes hull length on
# purpose - that's the axis under the heaviest runtime hull_scale stretch,
# so nose-to-tail stretching should never dilate bevel width.
# ---------------------------------------------------------------------------

def hull_reference_dim(size_x, size_y):
	"""R = min(width, height) - the design doc's reference dimension for
	keying bevel width and taper proportions."""
	return min(size_x, size_y)


def tiered_bevel_width(R, tier, pct=None, segments=None):
	"""Returns (width, segments) for an edge-role tier:
	  1 = primary structural silhouette edges (6-9% of R, 2 segments)
	  2 = secondary edges - hatch frames, ring corners (3-4% of R, 1 segment)
	  3 = cosmetic greeble/bolt-box edges (1-1.5% of R + a small fixed
	      floor, since pure percentage would vanish on tiny parts)
	`pct`/`segments` let a caller tune within (or deliberately just outside)
	a tier's band for per-archetype character - e.g. a heavy hull reading
	chunkier at the wide end of tier 1, an interceptor reading sharper at
	the narrow end. An absolute world-unit floor keeps every tier visible/
	non-z-fighting even at very small R."""
	if tier == 1:
		default_pct, default_segments = 0.075, 2
	elif tier == 2:
		default_pct, default_segments = 0.035, 1
	else:
		default_pct, default_segments = 0.0125, 1
	width = R * (pct if pct is not None else default_pct)
	if tier == 3:
		width = max(width, 0.012)
	segs = segments if segments is not None else default_segments
	return max(width, 0.01), segs


def bevel_sharp_edges(bm, verts, R, tier=1, angle_deg=20.0, max_face_frac=0.3, pct=None, segments=None,
		preserve_axis=None, preserve_thresh=0.95):
	"""Bevels only the genuinely sharp edges among `verts`, selected by
	dihedral angle - so a multi-slice taper loft's many near-coplanar
	edges are left alone (a blanket bevel would chew into the curve
	itself) while the real structural transitions (belly-to-deck, nose
	tip, spine ridge) get the tiered treatment. Works on any convex-hull-
	derived shape without hand-picking edge lists per hull.

	`preserve_axis` (0/1/2 for raw-Blender X/Y/Z) skips any edge touching
	a face whose normal is nearly aligned with that axis - e.g. a wall
	segment's flat end-cap faces, which must stay untouched so adjacent
	tiled segments still line up edge-to-edge."""
	width, segments = tiered_bevel_width(R, tier, pct=pct, segments=segments)
	width = min(width, R * max_face_frac)
	vert_set = set(verts)
	angle_thresh = math.radians(angle_deg)
	edges = []
	for e in bm.edges:
		if not (e.verts[0] in vert_set and e.verts[1] in vert_set):
			continue
		if len(e.link_faces) != 2:
			continue
		if preserve_axis is not None:
			skip = False
			for f in e.link_faces:
				if abs(f.normal[preserve_axis]) >= preserve_thresh:
					skip = True
					break
			if skip:
				continue
		if e.calc_face_angle() >= angle_thresh:
			edges.append(e)
	if edges:
		# A global R-based width can still self-intersect/spike near a
		# tapered tip (a pointed hull bow, a hull nose) where local edges
		# are much shorter than R - a real bug found on heavy_cruiser_hull
		# (see DECISIONS_NEEDED.md). Clamp to a safe fraction of the
		# SHORTEST selected edge's own length too, not just global R.
		min_edge_len = min(e.calc_length() for e in edges)
		width = min(width, min_edge_len * 0.4)
		bmesh.ops.bevel(bm, geom=edges, offset=width, segments=segments, affect='EDGES')
	return edges


def eased_taper(t):
	"""Smoothstep ease (0..1) so taper cross-sections blend rather than
	kink linearly from one slice to the next."""
	t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
	return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------------------
# Geometric Polish Pass (Section 1, Tier 2) - waist-inset and deck-line step.
# Both are real concave/raised surface details, which a pure convex_hull
# can't represent just by adding more points to its input cloud (any point
# "inside" the hull of its neighbors is simply ignored). Rather than pull in
# Blender's boolean modifier (new machinery, real non-manifold/perf risk),
# both are done as bisect_plane (clean loop cuts, no geometry removed) +
# a selective vertex shift within the cut band - bmesh-only, consistent
# with how the rest of this file already builds geometry.
#
# NOTE ON AXES: these operate directly on existing bm.verts (raw Blender
# coordinates), unlike most helpers above which take Godot-space args and
# call GV()/GS() internally. Per that convention: raw Blender X = Godot X
# (width, unchanged), raw Blender Y = Godot Z (length), raw Blender Z =
# Godot Y (height).
# ---------------------------------------------------------------------------

def add_waist_inset(bm, hx, hy, hz, depth_frac=0.06, height_frac=0.5, band_frac=0.1):
	"""Shallow horizontal recessed band cut into the hull's SIDE skin only
	(not the top deck/bottom belly, and not the spine) - natural sponson-
	mount nesting per the design doc. height_frac is the band's center as
	a fraction of hull height; depth_frac/band_frac are fractions of
	hx/hy for the inset depth and band thickness."""
	band_z0 = -hy + 2.0 * hy * height_frac - hy * band_frac
	band_z1 = -hy + 2.0 * hy * height_frac + hy * band_frac
	for plane_z in (band_z0, band_z1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(0, 0, plane_z), plane_no=(0, 0, 1), clear_inner=False, clear_outer=False)
	depth = hx * depth_frac
	for v in bm.verts:
		if band_z0 - 1e-4 <= v.co.z <= band_z1 + 1e-4:
			if v.co.x > hx * 0.3:
				v.co.x -= depth
			elif v.co.x < -hx * 0.3:
				v.co.x += depth


def add_deck_line_step(bm, hx, hy, hz, height_frac=0.08, z_frac=(0.6, 0.95)):
	"""Raises a secondary volume across part of the top deck's length
	(rear portion by default, clear of the spine ridge's own Z position)
	- real mount real estate per the design doc. z_frac is the raised
	region's Z extent as a fraction of hull length."""
	z0 = -hz + hz * 2.0 * z_frac[0]
	z1 = -hz + hz * 2.0 * z_frac[1]
	for plane_y in (z0, z1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(0, plane_y, 0), plane_no=(0, 1, 0), clear_inner=False, clear_outer=False)
	raise_h = hy * height_frac
	for v in bm.verts:
		if z0 - 1e-4 <= v.co.y <= z1 + 1e-4 and v.co.z > hy * 0.3:
			v.co.z += raise_h


def add_panel_line_groove(bm, hx, hy, hz, R, frac, depth_frac=0.015, width_frac=0.025, axis='z'):
	"""A single shallow inset seam line running across the top deck at a
	proportional position along `axis` - real geometry via bisect+push-in,
	not a texture, matching the design doc's 'inset face along a line,
	push resulting strip in along normal.' depth_frac/width_frac are
	fractions of R (not hull length) per the doc's 'depth ~1-2% R, width
	~2-3% R' - grooves stay a consistently fine detail-scale feature
	regardless of how long the hull is.

	axis='z' (default): a band running across the width at a Z position
	  (0=nose, 1=tail) - the original chordwise deck-line use.
	axis='x': a SPANWISE band running along the length at an X position
	  (0=centreline, 1=wingtip) - implies real spars/ribs on a swept
	  wing planform (flying_wing_hull) instead of fuselage panel lines."""
	if axis == 'z':
		center = -hz + hz * 2.0 * frac
		band_half = R * width_frac * 0.5
		lo, hi = center - band_half, center + band_half
		for plane_pos in (lo, hi):
			bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
				plane_co=(0, plane_pos, 0), plane_no=(0, 1, 0), clear_inner=False, clear_outer=False)
		push_in = R * depth_frac
		for v in bm.verts:
			if lo - 1e-4 <= v.co.y <= hi + 1e-4 and v.co.z > hy * 0.3:
				v.co.z -= push_in
	else:
		center = -hx + hx * 2.0 * frac
		band_half = R * width_frac * 0.5
		lo, hi = center - band_half, center + band_half
		for plane_pos in (lo, hi):
			bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
				plane_co=(plane_pos, 0, 0), plane_no=(1, 0, 0), clear_inner=False, clear_outer=False)
		push_in = R * depth_frac
		for v in bm.verts:
			if lo - 1e-4 <= v.co.x <= hi + 1e-4 and v.co.z > hy * 0.3:
				v.co.z -= push_in


def add_speed_line_chamfer(bm, hx, hy, hz, angle_deg=35.0, z_frac_center=0.4, depth_frac=0.06, band_frac=0.1):
	"""Tier 3 bespoke feature, interceptor_hull only: a single diagonal
	chamfer facet cut across each flank, rising toward the tail - a real
	styling cut (not a rounded edge-smooth) evoking the diagonal speed
	lines on a fast jet or sports car, distinct from every other hull's
	shared tiered-bevel vocabulary. Same bisect+selective-vertex-shift
	technique as add_waist_inset above, except the cutting plane is tilted
	between the length and height axes instead of purely axis-aligned, so
	the resulting cut line runs diagonally across the flat flank face."""
	angle = math.radians(angle_deg)
	plane_no_v = mathutils.Vector((0.0, math.sin(angle), math.cos(angle))).normalized()
	base_point = mathutils.Vector((0.0, -hz + 2.0 * hz * z_frac_center, 0.0))
	band_half = hz * band_frac
	for sign in (-1.0, 1.0):
		plane_co = base_point + plane_no_v * (sign * band_half)
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(plane_co.x, plane_co.y, plane_co.z), plane_no=(plane_no_v.x, plane_no_v.y, plane_no_v.z),
			clear_inner=False, clear_outer=False)
	depth = hx * depth_frac
	for v in bm.verts:
		d = (v.co - base_point).dot(plane_no_v)
		if -band_half - 1e-4 <= d <= band_half + 1e-4:
			if v.co.x > hx * 0.3:
				v.co.x -= depth
			elif v.co.x < -hx * 0.3:
				v.co.x += depth


def taper_profile(t, nose_frac, front_flare, rear_flare, nose_region=0.35, rear_region=0.8):
	"""Non-linear width-scale multiplier along hull length: t=0 at the nose
	(front, -Z) .. t=1 at the tail (rear, +Z). Narrows aggressively across
	just the front `nose_region` fraction of length (the design doc's
	'more aggressive near nose'), holds steady across the mid-hull waist,
	then eases into the rear flare over the tail's last stretch."""
	region = max(nose_frac, nose_region)
	if t < region:
		tip = front_flare * (1.0 - nose_frac) if nose_frac > 0.01 else front_flare
		return tip + (1.0 - tip) * eased_taper(t / max(region, 0.001))
	if t < rear_region:
		return 1.0
	return 1.0 + (rear_flare - 1.0) * eased_taper((t - rear_region) / (1.0 - rear_region))


# ---------------------------------------------------------------------------
# Greeble primitives - all operate on a caller-supplied bm using GODOT-space
# center/size, so calling code never has to think about the Blender swap.
# ---------------------------------------------------------------------------

def add_box(bm, center, size, rot_axis=None, rot_angle=0.0, bevel=0.0):
	ret = bmesh.ops.create_cube(bm, size=1.0)
	verts = ret['verts']
	bmesh.ops.scale(bm, verts=verts, vec=GS(*size))
	if rot_axis and rot_angle:
		bmesh.ops.rotate(bm, verts=verts, cent=(0, 0, 0), matrix=rot_matrix(rot_axis, rot_angle))
	bmesh.ops.translate(bm, verts=verts, vec=GV(*center))
	if bevel > 0.0:
		edges = [e for e in bm.edges if all(v in verts for v in e.verts)]
		if edges:
			bmesh.ops.bevel(bm, geom=edges, offset=bevel, segments=1, affect='EDGES')
	return verts


def add_cyl_y(bm, center, radius, height, segments=12, radius2=None):
	"""Vertical (Godot-Y-axis) cylinder/cone centered at `center`."""
	r2 = radius2 if radius2 is not None else radius
	ret = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
		radius1=radius, radius2=r2, depth=height)
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(*center))
	return ret['verts']


def add_sphere(bm, center, radius=1.0, segments=10, rings=8, scale_y=1.0):
	"""UV-sphere centered at `center`. `scale_y` < 1 squashes the sphere
	along Godot-Y to read as a drooping canopy / fat ball / whatever
	direction needs a non-spherical silhouette. segments=radius
	subdivisions (around the equator), rings=vertical subdivisions.

	Icosphere was the obvious alternative; UV-sphere wins for canopies
	because (a) the pole-aligned vertices give a flat-cap-friendly mesh
	that the icosphere's equilateral-triangle pattern doesn't, and (b) the
	vert count is exactly predictable, which matters when dozens of these
	end up in a single ambient-tree pool file."""
	ret = bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
	if scale_y != 1.0:
		# Scale the verts in place rather than calling bmesh.ops.scale,
		# which would scale everything in `bm` if we passed the wrong
		# geom set. `ret['verts']` is exactly the new verts, so the
		# transformation is guaranteed local to this sphere.
		for v in ret['verts']:
			v.co.y *= scale_y
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(*center))
	return ret['verts']


def add_cyl_axis(bm, center, radius, length, godot_axis, segments=10, radius2=None):
	"""Cylinder lying along a horizontal Godot axis ('x' or 'z'), centered at `center`."""
	r2 = radius2 if radius2 is not None else radius
	ret = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
		radius1=radius, radius2=r2, depth=length)
	bmesh.ops.rotate(bm, verts=ret['verts'], cent=(0, 0, 0), matrix=rot_matrix(godot_axis, math.pi / 2.0))
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(*center))
	return ret['verts']


def add_ring(bm, center, major_radius, minor_radius, major_segments=20, minor_segments=8):
	"""A horizontal torus/ring (Godot-Y-axis normal), swept around `center`."""
	before = set(bm.verts)
	ret = bmesh.ops.create_circle(bm, cap_ends=True, radius=minor_radius, segments=minor_segments)
	bmesh.ops.rotate(bm, verts=ret['verts'], cent=(0, 0, 0), matrix=mathutils.Matrix.Rotation(math.pi / 2.0, 3, 'Y'))
	bmesh.ops.translate(bm, verts=ret['verts'], vec=(major_radius, 0, 0))
	geom = list(ret['verts'])
	geom += [e for v in ret['verts'] for e in v.link_edges]
	geom += [f for v in ret['verts'] for f in v.link_faces]
	geom = list(set(geom))
	bmesh.ops.spin(bm, geom=geom, cent=(0, 0, 0), axis=(0, 0, 1),
		angle=math.radians(360), steps=major_segments, use_duplicate=False)
	new_verts = [v for v in bm.verts if v not in before]
	if center != (0, 0, 0):
		bmesh.ops.translate(bm, verts=new_verts, vec=GV(*center))
	return new_verts


# ---------------------------------------------------------------------------
# Greeble "kits" - reusable clusters of detail merged straight into a bm.
# ---------------------------------------------------------------------------

def greeble_rivet_row(bm, start, end, count, radius=0.025, height=0.02, axis='y'):
	for i in range(count):
		t = (i / (count - 1)) if count > 1 else 0.5
		c = tuple(start[k] + (end[k] - start[k]) * t for k in range(3))
		if axis == 'y':
			add_cyl_y(bm, c, radius, height, segments=7)
		else:
			add_cyl_axis(bm, c, radius, height, axis, segments=7)


def greeble_vent(bm, center, size, slats=4):
	add_box(bm, center, size, bevel=0.01)
	slat_w = size[0] / (slats * 2.2)
	for i in range(slats):
		t = (i + 0.5) / slats - 0.5
		c = (center[0] + t * size[0] * 0.8, center[1], center[2])
		add_box(bm, c, (slat_w, size[1] * 1.2, size[2] * 0.85))


def greeble_louver_panel(bm, hy, center, size, R, slats=4, recess_frac=0.05):
	"""Engine-deck louvers as real recessed geometry (HULL_MASSING_SPEC.md)
	instead of a proud greeble_vent box: crossed bisect bands (the same
	bisect+shift technique as add_panel_line_groove, but bounded in BOTH
	length AND width instead of running the full hull width) carve a
	rectangular pocket, the interior is pushed down, then angled slat
	add_boxes sit at the recessed floor depth. Must be called on the
	silhouette BEFORE the tier-1 bevel pass (like every other bisect+shift
	feature), not from a hull's `greebles` callback which only runs after.
	center/size are Godot-space, matching greeble_vent's own signature.
	`hy` gates the vertical shift to the upper hull only (same `v.co.z >
	hy*0.3` convention add_deck_line_step/add_panel_line_groove already use),
	so this can safely be called without accidentally denting the belly."""
	cx, cy, cz = GV(*center)
	half_w, half_l = size[0] / 2.0, size[2] / 2.0
	x0, x1 = cx - half_w, cx + half_w
	y0, y1 = cy - half_l, cy + half_l
	for plane_x in (x0, x1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(plane_x, 0, 0), plane_no=(1, 0, 0), clear_inner=False, clear_outer=False)
	for plane_y in (y0, y1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(0, plane_y, 0), plane_no=(0, 1, 0), clear_inner=False, clear_outer=False)
	recess = R * recess_frac
	for v in bm.verts:
		if x0 - 1e-4 <= v.co.x <= x1 + 1e-4 and y0 - 1e-4 <= v.co.y <= y1 + 1e-4 and v.co.z > hy * 0.3:
			v.co.z -= recess

	slat_w = size[0] / (slats * 2.2)
	floor_y = center[1] - recess
	for i in range(slats):
		t = (i + 0.5) / slats - 0.5
		c = (center[0] + t * size[0] * 0.8, floor_y, center[2])
		add_box(bm, c, (slat_w, size[1] * 0.5, size[2] * 0.85), rot_axis='x', rot_angle=0.3)


def _bisect_z_band(bm, z0, z1):
	for plane_z in (z0, z1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(0, 0, plane_z), plane_no=(0, 0, 1), clear_inner=False, clear_outer=False)


def _bisect_x_band_and_recess(bm, x0, x1, z0, z1, recess, wall_gate):
	for plane_x in (x0, x1):
		bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=(plane_x, 0, 0), plane_no=(1, 0, 0), clear_inner=False, clear_outer=False)
	for v in bm.verts:
		if x0 - 1e-4 <= v.co.x <= x1 + 1e-4 and z0 - 1e-4 <= v.co.z <= z1 + 1e-4 and v.co.y > wall_gate:
			v.co.y -= recess


def add_recessed_embrasure(bm, center, size, R, depth_frac=0.06, taper_width_frac=0.55, wall_gate=0.0):
	"""A recessed, splayed firing embrasure cut into an outward-facing
	(+Z) wall - the vertical-wall counterpart to greeble_louver_panel's
	horizontal deck pocket. Same bisect+shift technique (technique #2),
	just bounding width/height instead of width/depth, and pushing the
	interior INWARD along Z instead of down along Y. Two nested cuts (an
	outer wide pocket, then a narrower inner slit pushed further in)
	approximate a real casemate opening that narrows toward the firing
	position - "splayed wider on the outside" - without needing a
	continuous taper loft. Must be called on the silhouette BEFORE the
	tier-1 bevel pass, like every other bisect+shift feature.
	center/size (width, height) are Godot-space, matching greeble_vent's
	signature. `wall_gate` restricts the inward push to verts on this
	wall's outward side (an absolute Godot-Z threshold) so the cut
	doesn't also carve into a wall on the opposite side of the hull.
	For MULTIPLE embrasures sharing the same height band, use
	add_recessed_embrasure_row instead - calling this once per slit at
	an identical height re-bisects the same Z planes N times, which was
	found (via direct bmesh inspection on a 5-slit wall) to produce
	hundreds of degenerate zero-area faces."""
	cx, cy, cz = GV(*center)
	half_w, half_h = size[0] / 2.0, size[1] / 2.0
	_bisect_z_band(bm, cz - half_h, cz + half_h)
	_bisect_z_band(bm, cz - half_h * taper_width_frac, cz + half_h * taper_width_frac)
	_bisect_x_band_and_recess(bm, cx - half_w, cx + half_w, cz - half_h, cz + half_h,
		R * depth_frac, wall_gate)
	hw2, hh2 = half_w * taper_width_frac, half_h * taper_width_frac
	_bisect_x_band_and_recess(bm, cx - hw2, cx + hw2, cz - hh2, cz + hh2,
		R * depth_frac * 1.8, wall_gate)


def add_recessed_embrasure_row(bm, x_centers, y_level, size, R, depth_frac=0.06,
		taper_width_frac=0.55, wall_gate=0.0):
	"""Multiple embrasures at different X positions sharing one height
	band (build_wall_hull's arrow-slit row) - shares the height-bounding
	Z bisect across the whole row (cut once) instead of add_recessed_
	embrasure's per-call Z bisect (which would re-cut the identical
	location once per slit). Each slit's width (X) bisect still happens
	per-slit since those positions are always distinct, never coincident.
	x_centers/y_level/size are Godot-space, same convention as
	add_recessed_embrasure."""
	half_h = size[1] / 2.0
	half_h2 = half_h * taper_width_frac
	z0, z1 = y_level - half_h, y_level + half_h
	z0i, z1i = y_level - half_h2, y_level + half_h2
	_bisect_z_band(bm, z0, z1)
	_bisect_z_band(bm, z0i, z1i)
	half_w = size[0] / 2.0
	half_w2 = half_w * taper_width_frac
	for cx in x_centers:
		_bisect_x_band_and_recess(bm, cx - half_w, cx + half_w, z0, z1, R * depth_frac, wall_gate)
		_bisect_x_band_and_recess(bm, cx - half_w2, cx + half_w2, z0i, z1i,
			R * depth_frac * 1.8, wall_gate)


def greeble_headlight_pair(bm, hx, y_level, front_z, radius=0.09):
	for side in (-1, 1):
		add_cyl_axis(bm, (side * hx * 0.55, y_level, front_z), radius, 0.09, 'z', segments=10)


def greeble_exhaust_stack(bm, center, radius=0.08, height=0.35):
	add_cyl_y(bm, center, radius, height, segments=10)
	add_cyl_y(bm, (center[0], center[1] + height * 0.5 + 0.02, center[2]), radius * 1.2, 0.04, segments=10)


def greeble_antenna(bm, base, height=0.55, radius=0.018):
	add_cyl_y(bm, (base[0], base[1] + height / 2.0, base[2]), radius, height, segments=6)
	add_cyl_y(bm, (base[0], base[1], base[2]), radius * 2.2, 0.03, segments=8)


def greeble_hatch(bm, center, size, rim=0.03):
	add_box(bm, center, size, bevel=0.008)
	add_box(bm, (center[0], center[1] + size[1] * 0.5 + 0.008, center[2]),
		(size[0] - rim, 0.015, size[2] - rim))


def greeble_faired_canopy(bm, center, size, segments=12, rings=8):
	"""A real cockpit/canopy VOLUME - a squashed uvsphere fused directly
	into the hull's own bmesh (technique #1, same "second convex-hull-like
	shell left interpenetrating" approach as build_afv_hull's tub/upper
	split), replacing a proud add_box canopy bump. `size` is a (x, y, z)
	half-extent tuple, keyed the same way build_dome's squash param is -
	each axis independently, so a caller can clamp height to a fraction
	of hy and let width/length follow hx/hz (per HULL_MASSING_SPEC.md's
	interceptor_hull note: an unclamped squash ratio can invert under an
	extreme non-uniform hull_scale stretch and read as a bubble)."""
	ret = bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=1.0)
	bmesh.ops.scale(bm, verts=ret['verts'], vec=GS(size[0], size[1], size[2]))
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(*center))
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)


def greeble_corner_gusset(bm, x_sign, hx, hy, z_pos, size=(0.32, 0.28, 0.45)):
	add_box(bm, (x_sign * (hx - size[0] * 0.35), -hy * 0.35, z_pos), size, bevel=0.02)


def greeble_toolbox(bm, center, size=(0.5, 0.28, 0.32)):
	add_box(bm, center, size, bevel=0.015)
	add_box(bm, (center[0], center[1] + size[1] * 0.5, center[2]), (size[0] * 0.9, 0.03, size[2] * 0.9))


def greeble_spotlight(bm, center, radius=0.11):
	add_cyl_axis(bm, center, radius, 0.14, 'z', segments=10)
	add_box(bm, (center[0], center[1] - radius * 0.9, center[2] - 0.05), (0.05, 0.16, 0.05))


def greeble_bolt_ring(bm, center, radius, count=8, bolt_radius=0.025, axis='y'):
	for i in range(count):
		angle = i * (2.0 * math.pi / count)
		if axis == 'y':
			pos = (center[0] + math.cos(angle) * radius, center[1], center[2] + math.sin(angle) * radius)
			add_cyl_y(bm, pos, bolt_radius, 0.02, segments=6)
		else:
			pos = (center[0] + math.cos(angle) * radius, center[1] + math.sin(angle) * radius, center[2])
			add_cyl_axis(bm, pos, bolt_radius, 0.02, 'z', segments=6)


def greeble_cooling_fins(bm, center, count, span, radius, thickness=0.012, axis='z'):
	for i in range(count):
		t = (i / (count - 1)) if count > 1 else 0.5
		off = (t - 0.5) * span
		if axis == 'z':
			pos = (center[0], center[1], center[2] + off)
			add_box(bm, pos, (radius * 2.1, radius * 2.1, thickness))
		else:
			pos = (center[0], center[1] + off, center[2])
			add_box(bm, pos, (radius * 2.1, thickness, radius * 2.1))


# ---------------------------------------------------------------------------
# Part builders - small reusable kit pieces referenced by visual_builder.gd.
# Cylinders/cones are authored with their length along Godot Z (forward),
# matching how they're mounted on weapons (barrels point along local -Z).
# ---------------------------------------------------------------------------

def build_barrel(name, length=1.0, radius=0.1, muzzle_radius=None, segments=16,
		fins=0, color=(0.12, 0.12, 0.13), steps=3):
	"""Barrel along Godot +Y, base at origin (y=0..length) - matches the
	existing runtime convention (Godot's own CylinderMesh default axis),
	so weapon assembly code keeps applying its existing PI/2 X rotation to
	point barrels forward, and existing caliber(X)/length(Y) tweak scaling
	on this child index keeps working unchanged.

	Section 3 of the design doc: modules compute their OWN reference
	dimension R from their own bounding box (here, diameter - a barrel's
	long axis is exactly the one caliber/length tweaks stretch, so it's
	excluded the same way hull length is). The body is now a stepped-
	diameter loft (discrete radius steps from breech to muzzle) instead
	of one smooth cone - reads as a real machined part, not a plain rod."""
	bm = bmesh.new()
	r2 = muzzle_radius if muzzle_radius is not None else radius
	R = 2.0 * max(radius, r2)
	step_len = length / steps
	all_verts = []
	for i in range(steps):
		t = i / float(max(steps - 1, 1))
		r = radius + (r2 - radius) * eased_taper(t)
		all_verts += add_cyl_y(bm, (0, step_len * (i + 0.5), 0), r, step_len, segments=segments)
	# Muzzle brake ring fused on the tip
	all_verts += add_cyl_y(bm, (0, length * 0.94, 0), r2 * 1.35, length * 0.1, segments=segments)
	bmesh.ops.remove_doubles(bm, verts=all_verts, dist=0.001)
	bevel_sharp_edges(bm, list(bm.verts), R, tier=2)
	if fins > 0:
		greeble_cooling_fins(bm, (0, length * 0.35, 0), fins, length * 0.45, radius * 1.15, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.85, roughness=0.3)
	return obj


def build_cylinder_part(name, radius=0.15, height=0.15, segments=20, bevel=True,
		bolts=True, color=(0.35, 0.35, 0.38)):
	"""Squat drum along Godot Y (up), base at origin - ammo drums, canisters,
	fuel tanks, turret base plates, muzzle brakes. Turret bodies get a
	tier-1 bevel per Section 3 (panel-line insets are Tier 2, deferred)."""
	bm = bmesh.new()
	verts = add_cyl_y(bm, (0, height / 2.0, 0), radius, height, segments=segments)
	if bevel:
		bevel_sharp_edges(bm, verts, radius * 2.0, tier=1, pct=0.06)
	if bolts:
		greeble_bolt_ring(bm, (0, height * 0.9, 0), radius * 0.82, count=max(6, segments // 2), axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color)
	return obj


def build_dome(name, radius=0.15, squash=0.6, segments=16, rings=10,
		color=(0.85, 0.85, 0.85)):
	bm = bmesh.new()
	ret = bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
	bmesh.ops.scale(bm, verts=ret['verts'], vec=GS(1.0, squash, 1.0))
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(0, radius * squash * 0.15, 0))
	# Base collar ring
	add_cyl_y(bm, (0, 0.02, 0), radius * 1.05, 0.04, segments=segments)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.1, roughness=0.15)
	return obj


def build_missile_body(name, length=1.0, radius=0.08, nose_frac=0.25, segments=14,
		fins=4, color=(0.9, 0.9, 0.9)):
	"""Missile body + nose cone along Godot +Y, base (tail) at origin -
	matches the existing runtime PI/2 X rotation convention."""
	bm = bmesh.new()
	body_len = length * (1.0 - nose_frac)
	nose_len = length * nose_frac
	add_cyl_y(bm, (0, body_len / 2.0, 0), radius, body_len, segments=segments)
	add_cyl_y(bm, (0, body_len + nose_len / 2.0, 0), radius, nose_len, segments=segments, radius2=0.0)
	# Rear stabilizer fins, fanned around the tail end
	fin_len = radius * 2.4
	for i in range(fins):
		angle = i * (2.0 * math.pi / fins)
		add_box(bm, (0, radius * 0.5, 0),
			(0.012, radius * 1.6, fin_len), rot_axis='y', rot_angle=angle)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.3, roughness=0.4)
	return obj


def build_pintle_mount(name, width=0.34, height=0.22, depth=0.22, wall=0.045,
		color=(0.2, 0.2, 0.22)):
	"""Small U-shaped yoke bracket: base plate + two side arms. Mounting
	hardware gets the LIGHTEST touch of anything in the roster per
	Section 3 - tier-3 bevel only, no boolean greeble beyond the
	existing bolt ring."""
	bm = bmesh.new()
	mount_bevel, _ = tiered_bevel_width(hull_reference_dim(width, height), tier=3)
	add_box(bm, (0, wall / 2.0, 0), (width, wall, depth), bevel=mount_bevel)
	for side in (-1, 1):
		add_box(bm, (side * (width / 2.0 - wall / 2.0), height / 2.0, 0), (wall, height, depth), bevel=mount_bevel)
	greeble_bolt_ring(bm, (0, wall * 0.5, 0), width * 0.32, count=4, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.5)
	return obj


def build_sponson_blister(name, width=1.0, height=0.4, depth=0.6, wall=0.12,
		color=(0.30, 0.30, 0.33)):
	"""Armoured housing bolted to a near-vertical hull face, through which
	an embedded weapon's barrel protrudes. Not mounting hardware - this
	reads as a piece of HULL added to permit the mount, so it takes
	faction paint (visual_builder._sponson_blister) rather than the bare
	steel treatment build_pintle_mount gets.

	ORIENTATION, and it is the opposite of most parts here: the aperture
	faces Godot -Z, because -Z is the muzzle axis everywhere in this
	project (barrels author along +Y then take the runtime PI/2 X
	rotation). +Y is up and the base sits at Y=0, per the house
	convention, so the housing rises alongside the weapon body it wraps.

	Deliberately NOT built with add_recessed_embrasure(): that helper
	bisects an outward-facing +Z wall and takes a wall_gate to avoid
	carving the opposite side of a hull - both assumptions are wrong for
	a free-standing part whose opening faces -Z. A stepped stub reads the
	same at this scale and costs no bisect passes. Proportions follow
	build_sponson_hull's "real stepped stub, not just a smooth taper".
	"""
	bm = bmesh.new()

	# FACETED, not boxy. Two coaxial drums along the muzzle axis with a low
	# segment count, so the silhouette reads as a machined, chamfered bulge
	# rather than a crate bolted to the hull. 10 segments is the sweet spot -
	# enough to round off, few enough that the flats still catch light
	# individually.
	#
	# Built centred on Y=0 so the vertical flatten below scales about the
	# blister's own midline, then lifted to the house base-at-Y=0 convention
	# in one move at the end.
	# A VERTICAL faceted prism, which is what gives the requested silhouette:
	# add_cyl_y caps the top and bottom with flat n-gons (the "flat planes")
	# while its side wall is a rounded, faceted sweep - and the part of that
	# sweep pointing outboard is the rounded front face. 14 segments reads as
	# curved-but-machined at this scale.
	#
	# Built at full width in X and then squashed in Z, so in plan it is a wide
	# shallow ellipse hugging the hull rather than a protruding drum.
	shaped = add_cyl_y(bm, (0, height / 2.0, 0), width / 2.0, height, segments=14)
	bmesh.ops.scale(bm, verts=shaped, vec=GS(1.0, 1.0, depth / width))

	# Punch the barrel aperture through the OUTBOARD wall by deleting the side
	# faces that look along Godot -Z within the barrel's height band. Done by
	# face-normal predicate rather than a boolean: there is no boolean helper
	# in this file, and deleting a contiguous run of wall quads leaves exactly
	# the faceted opening a barrel should emerge from. The flat top and bottom
	# caps are untouched - their normals are +/-Y, so they never match.
	aperture_half_h = height * 0.34
	doomed = []
	for f in bm.faces:
		n = f.normal
		c = f.calc_center_median()
		# Godot -Z is Blender -Y; Godot Y is Blender Z.
		facing_outboard = -n.y
		if facing_outboard > 0.55 and abs(c.z - height / 2.0) < aperture_half_h:
			doomed.append(f)
	if doomed:
		bmesh.ops.delete(bm, geom=doomed, context='FACES')

	# Bolt pads directly on the curved wall - no weld flange. The flange was a
	# flat slab standing proud of the bulge and read as a separate plate
	# bolted on behind it rather than as part of the housing; Chris called it
	# on sight. The bolts alone do the "fastened to the hull" job.
	#
	# Each pad is a small box rotated about Godot Y to lie flat on the wall at
	# its own angle - add_box's rot_axis/rot_angle handle that, which is why
	# these are boxes and not cylinders (a cylinder would need a per-angle
	# orientation this file has no helper for).
	#
	# Skipped over the aperture arc: bolts floating in the barrel opening
	# would be attached to nothing.
	rx, rz = width / 2.0, depth / 2.0
	pad_rows = (height * 0.24, height * 0.76)
	for i in range(14):
		a = i * (2.0 * math.pi / 14)
		# Angle measured so that -Z (outboard) is where the aperture sits.
		if math.cos(a) < -0.55:
			continue
		for y_level in pad_rows:
			# Unbevelled on purpose. A tier-3 bevel takes each pad from 6 faces
			# to ~26, and at this size the chamfer is invisible while the cost
			# is not - the housing ships on every sponson weapon on every unit
			# in a battle. 832 faces with bevels, ~350 without.
			add_box(bm,
				(math.sin(a) * rx * 0.99, y_level, math.cos(a) * rz * 0.99),
				(0.07, 0.05, 0.05), rot_axis='y', rot_angle=a)

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.7, roughness=0.42)
	return obj


def build_box_part(name, size=(0.5, 0.3, 0.4), bevel_amt=None, bolts=True,
		color=(0.3, 0.3, 0.33)):
	"""Beveled box - turret bases, launcher frames, weapon housings. A
	turret body gets a tier-1 bevel by default (panel-line insets are
	Tier 2, deferred); pass bevel_amt explicitly to override."""
	bm = bmesh.new()
	if bevel_amt is None:
		bevel_amt, _ = tiered_bevel_width(hull_reference_dim(size[0], size[1]), tier=1, pct=0.06)
	add_box(bm, (0, size[1] / 2.0, 0), size, bevel=bevel_amt)
	if bolts:
		for x_sign in (-1, 1):
			for z_sign in (-1, 1):
				pos = (x_sign * size[0] * 0.4, size[1] * 0.92, z_sign * size[2] * 0.4)
				add_cyl_y(bm, pos, 0.02, 0.015, segments=6)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color)
	return obj


def build_howitzer_breech(name, width=0.9, height=0.5, depth=0.55, color=(0.28, 0.28, 0.3)):
	"""Chunky breech block with twin recoil-buffer cylinders on top."""
	bm = bmesh.new()
	add_box(bm, (0, height / 2.0, 0), (width, height, depth), bevel=0.03)
	for side in (-1, 1):
		add_cyl_axis(bm, (side * width * 0.28, height * 0.85, -depth * 0.05), 0.09, depth * 1.3, 'z', segments=12)
	greeble_bolt_ring(bm, (0, height * 0.95, depth * 0.3), width * 0.3, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.5)
	return obj


def build_basic_cannon_solid(name, color=(0.28, 0.28, 0.32)):
	"""Simplified 37 mm Gun M3 on an open pintle mount (single solid mesh)."""
	bm = bmesh.new()

	# 1. Open Pintle Base Socket & Yoke Carriage
	add_box(bm, (0, 0.04, 0), (0.36, 0.08, 0.32), bevel=0.015)
	for side in (-1, 1):
		add_box(bm, (side * 0.16, 0.2, 0), (0.05, 0.24, 0.22), bevel=0.015)
	greeble_bolt_ring(bm, (0, 0.04, 0), 0.14, count=6, axis='y')

	# 2. Side Elevation Handwheel (left yoke)
	add_cyl_axis(bm, (-0.2, 0.22, 0), 0.07, 0.03, 'x', segments=12)

	# 3. Vertical Sliding-Block Breech Housing (at trunnion height Y = 0.22)
	trunnion_y = 0.22
	add_box(bm, (0, trunnion_y, 0.05), (0.2, 0.22, 0.36), bevel=0.02)
	greeble_bolt_ring(bm, (0, trunnion_y + 0.1, 0.1), 0.06, count=4, axis='y')

	# 4. Parallel Under-Barrel Hydraulic Recoil Cylinder Buffer
	recoil_len = 0.45
	add_cyl_axis(bm, (0, trunnion_y - 0.07, -recoil_len / 2.0 + 0.05), 0.05, recoil_len, 'z', segments=16)

	# 5. Slender 37mm L/56 Main Gun Barrel (Extending forward along -Z)
	barrel_len = 1.25
	add_cyl_axis(bm, (0, trunnion_y, -barrel_len / 2.0 - 0.05), 0.06, barrel_len, 'z', segments=20)
	add_cyl_axis(bm, (0, trunnion_y, -barrel_len - 0.05), 0.07, 0.06, 'z', segments=20)

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.65, roughness=0.4)
	return obj


def build_rotary_jacket(name, radius=0.22, height=0.5, barrels=6, color=(0.2, 0.2, 0.21)):
	"""Cooling jacket ring around a rotary-cannon barrel cluster, along Godot +Y."""
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius, height * 0.3, segments=20)
	add_cyl_y(bm, (0, height * 0.95, 0), radius * 1.08, height * 0.12, segments=20)
	greeble_cooling_fins(bm, (0, height * 0.55, 0), 5, height * 0.5, radius, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.75, roughness=0.35)
	return obj


def build_rail_array(name, length=1.6, gap=0.16, rail_h=0.12, color=(0.15, 0.15, 0.15)):
	"""Twin magnetic rail assembly with connecting spars, for the railgun."""
	bm = bmesh.new()
	for side in (-1, 1):
		add_box(bm, (side * gap, rail_h / 2.0, length / 2.0), (0.06, rail_h, length), bevel=0.01)
	for i in range(4):
		t = (i + 0.5) / 4.0
		add_box(bm, (0, rail_h * 0.5, length * t), (gap * 2.0 + 0.08, 0.03, 0.03))
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.7, roughness=0.25)
	return obj


def build_flak_breech(name, width=0.5, height=0.32, depth=0.4, color=(0.18, 0.18, 0.18)):
	bm = bmesh.new()
	add_box(bm, (0, height / 2.0, 0), (width, height, depth), bevel=0.02)
	greeble_bolt_ring(bm, (0, height * 0.9, 0), width * 0.32, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.65, roughness=0.4)
	return obj


def build_wheel(name, radius=0.45, width=0.35, spokes=5, color=(0.1, 0.1, 0.12)):
	"""High-detail military run-flat wheel with treaded rubber tire + recessed steel rim + 8 lug bolts."""
	bm = bmesh.new()
	# Outer rubber tire
	add_cyl_y(bm, (0, width * 0.5, 0), radius, width, segments=28)
	# Off-road tire tread lugs (16 diagonal tread bars around circumference)
	for i in range(16):
		angle = i * (2.0 * math.pi / 16)
		pos = (math.cos(angle) * radius * 0.98, width * 0.5, math.sin(angle) * radius * 0.98)
		add_box(bm, pos, (radius * 0.12, width * 0.85, 0.04), rot_axis='y', rot_angle=angle)
	# Recessed steel wheel rim face (outer face near Y = width)
	add_cyl_y(bm, (0, width * 0.7, 0), radius * 0.65, width * 0.65, segments=20)
	# Center axle cap
	add_cyl_y(bm, (0, width * 0.95, 0), radius * 0.22, width * 0.15, segments=16)
	# 8 hex lug bolts around center cap
	greeble_bolt_ring(bm, (0, width * 0.98, 0), radius * 0.38, count=8, bolt_radius=radius * 0.035, axis='y')
	# 5 rim ventilation cutouts / spokes
	for i in range(spokes):
		angle = i * (2.0 * math.pi / spokes)
		pos = (math.cos(angle) * radius * 0.48, width * 0.8, math.sin(angle) * radius * 0.48)
		add_box(bm, pos, (radius * 0.15, width * 0.4, radius * 0.15), rot_axis='y', rot_angle=angle)

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.5)
	return obj


def build_locomotion_mount_box(name, size_x=0.35, size_y=0.4, size_z=0.35, color=(0.28, 0.3, 0.32)):
	"""Chamfered rectangular prism mount box for seamless locomotion-to-hull mounting."""
	bm = bmesh.new()
	add_box(bm, (0, size_y * 0.5, 0), (size_x, size_y, size_z), bevel=0.03)
	greeble_bolt_ring(bm, (0, size_y * 0.85, 0), min(size_x, size_z) * 0.35, count=4, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.4)
	return obj


def build_wheel_driveshaft(name, color=(0.16, 0.16, 0.18)):
	"""Simple chamfered rectangular housing standing in for an enclosed
	half-axle/driveshaft, running from the hull mount point DOWN to the
	wheel's gearbox. A single beveled unit box, deliberately plain (this
	reads as an enclosed shaft housing rather than a decorated part,
	matching the "just a chamfered box" request) - authored as a unit cube
	spanning Y=0 (top, at the hull mount point) DOWN to Y=-1 (bottom, at
	the gearbox/wheel end), so a small Z-rotation in visual_builder.gd
	tilts it down-and-inboard instead of up-and-sideways. Scaled directly
	to whatever final world-space box dimensions a given
	wheel_size/wheels_per_axle needs, no authored-size ratio math
	required."""
	bm = bmesh.new()
	add_box(bm, (0, -0.5, 0), (1.0, 1.0, 1.0), bevel=0.06)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.4)
	return obj


def build_wheel_gearbox(name, color=(0.14, 0.14, 0.16)):
	"""Small chamfered gearbox/differential housing that sits directly
	behind the wheel hub, fed by the driveshaft box - the "attaches to the
	driveshaft" piece the running-gear redesign asked for. A beveled unit
	cube (scaled directly by visual_builder.gd, same convention as
	wheel_driveshaft) with one bolt ring on its top face."""
	bm = bmesh.new()
	add_box(bm, (0, 0, 0), (1.0, 0.8, 1.0), bevel=0.12)
	greeble_bolt_ring(bm, (0, 0.42, 0), 0.28, count=4, bolt_radius=0.05, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.35)
	return obj


def build_leg_segment(name, length=0.5, radius_top=0.12, radius_bottom=0.08, color=(0.3, 0.3, 0.32)):
	"""Armored leg segment along Godot Y, base(wide) at origin. The
	stepped-diameter taper per segment is already structurally present
	via radius_top/radius_bottom (and stacking two of these - thigh then
	shin - narrows the whole leg toward the foot); this pass adds the
	joint housing the doc asks for - a separate boolean-added collar at
	the wide (hip) end, individually beveled, rather than a smooth taper
	reading as one uninterrupted cone. Longitudinal reinforcement ridges
	(Chris's "cooler" ask) run most of the segment's length at the taper's
	AVERAGE radius - a deliberate approximation (real cone-hugging ridges
	would need a proper swept profile) that reads fine at this scale."""
	bm = bmesh.new()
	R = 2.0 * max(radius_top, radius_bottom)
	seg_verts = add_cyl_y(bm, (0, length / 2.0, 0), radius_top, length, segments=12, radius2=radius_bottom)
	bevel_sharp_edges(bm, seg_verts, R, tier=2)
	housing_h = length * 0.12
	add_cyl_y(bm, (0, housing_h * 0.5, 0), radius_top * 1.18, housing_h, segments=12, radius2=radius_top * 1.1)
	greeble_bolt_ring(bm, (0, length * 0.05, 0), radius_top * 0.85, count=6, axis='y')

	ridge_count = 5
	ridge_r = (radius_top + radius_bottom) * 0.5 * 0.95
	ridge_len = length * 0.75
	for i in range(ridge_count):
		angle = i * (2.0 * math.pi / ridge_count)
		pos = (math.cos(angle) * ridge_r, housing_h + ridge_len * 0.5, math.sin(angle) * ridge_r)
		add_box(bm, pos, (radius_top * 0.16, ridge_len, radius_top * 0.14), rot_axis='y', rot_angle=angle)

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.4)
	return obj


def build_leg_joint(name, radius=0.18, height=0.22, segments=8, color=(0.22, 0.22, 0.25)):
	"""Bulky faceted joint housing (Chris's ask) - low segment count (8,
	same technique build_airship_hull's envelope cross-section uses) keeps
	the dihedral angle between adjacent side faces above finalize()'s
	35-degree auto-smooth threshold, so it reads as flat riveted panels
	instead of a smooth drum. Used for legs' hull-mount hip joint and its
	ankle/toe joint - both previously bare, unarticulated junctions (the
	hip only had a generic rg_mount_box, the ankle had nothing at all)."""
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius, height, segments=segments)
	greeble_bolt_ring(bm, (0, height * 0.85, 0), radius * 0.7, count=6, axis='y')
	greeble_bolt_ring(bm, (0, height * 0.15, 0), radius * 0.7, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.4)
	return obj


def build_hover_ring(name, major_radius=0.5, minor_radius=0.1, color=(0.2, 0.6, 0.9)):
	bm = bmesh.new()
	add_ring(bm, (0, 0, 0), major_radius, minor_radius, major_segments=24, minor_segments=8)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.3)
	return obj


def build_tread_plate(name, width=1.0, length=1.0, links=6, color=(0.16, 0.16, 0.17)):
	"""Tracked-tread belt block with raised link ridges along its length -
	length is the axis the belt repeats/tiles along (the tread's own
	analogue of a hull's stretched axis), so R excludes it the same way."""
	bm = bmesh.new()
	R = hull_reference_dim(width, 0.3)
	base_bevel, _ = tiered_bevel_width(R, tier=2)
	ridge_bevel, _ = tiered_bevel_width(R, tier=3)
	add_box(bm, (0, 0.15, 0), (width, 0.3, length), bevel=base_bevel)
	for i in range(links):
		t = (i + 0.5) / links - 0.5
		add_box(bm, (0, 0.31, t * length), (width * 1.02, 0.04, length / links * 0.55), bevel=ridge_bevel)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.6)
	return obj


def build_tread_belt_loop(name, half_span=1.0, radius=0.45, belt_width=0.3, belt_thickness=0.07,
		drop=0.4, inset_frac=0.55, arc_segments=12, color=(0.14, 0.14, 0.15)):
	"""Closed tread loop that wraps all the way around the road-wheel/
	sprocket row, shaped as an "inverted trapezoid" like a real modern
	track (Chris's ask) rather than a plain symmetric stadium/oval: the TOP
	run is a simple straight line tangent to both sprockets (unchanged from
	the stadium version), but the BOTTOM run dips DOWN by `drop` between two
	diagonal transitions, so the road wheels ride notably lower than the
	sprocket axle line - wide/low at the bottom, narrower/higher at the top.
	`inset_frac` (0-1) controls how much of the half-span the flat lowered
	middle run covers vs. the diagonal transitions on each side. Two
	semicircular end-wraps of radius `radius` around the front/rear sprocket
	centers (Godot Z = +-half_span), swept from a small rectangular cross-
	section (belt_width x belt_thickness). The path is planar (Godot Y-Z /
	Blender X-Z plane) so the cross-section only rotates within that plane
	as it sweeps - its own width axis (Godot X / Blender X) never rotates,
	which is what makes this tractable with bmesh.ops.spin + straight
	extrude/translate instead of a full Frenet-frame sweep."""
	bm = bmesh.new()
	hw = belt_width / 2.0
	# Profile: an OPEN rectangle (4 verts, 4 edges, no cap face - this needs
	# to sweep into one continuous closed tube, not a pair of capped
	# cylinders), positioned at the start point: directly above the rear
	# sprocket center (Blender Y=-half_span, Blender Z=+radius, i.e. Godot
	# Z=-half_span, Y=+radius).
	pts = [
		(-hw, -half_span, radius - belt_thickness), (hw, -half_span, radius - belt_thickness),
		(hw, -half_span, radius), (-hw, -half_span, radius),
	]
	verts = [bm.verts.new(p) for p in pts]
	edges = [bm.edges.new((verts[i], verts[(i + 1) % 4])) for i in range(4)]

	# 1. Wrap around the REAR sprocket center: top -> back -> bottom.
	# Positive angle here sweeps toward -Y first (outward/away from the
	# loop's center for this end), not inward - see the derivation in the
	# session notes; verified against the render, not just worked out on
	# paper.
	ret = bmesh.ops.spin(bm, geom=verts + edges, cent=(0, -half_span, 0), axis=(1, 0, 0),
		angle=math.radians(180), steps=arc_segments, use_duplicate=False)
	verts = [v for v in ret['geom_last'] if isinstance(v, bmesh.types.BMVert)]
	edges = [e for e in ret['geom_last'] if isinstance(e, bmesh.types.BMEdge)]

	# 2. Bottom run, now in 3 segments instead of 1 straight line: diagonal
	# down to the lowered wheel-level run, flat across the middle, diagonal
	# back up to the front sprocket's own bottom tangent - this is the
	# actual trapezoid dip.
	half_run = half_span * inset_frac
	diag_reach = half_span - half_run  # horizontal distance each diagonal covers

	ext_a = bmesh.ops.extrude_edge_only(bm, edges=edges)
	verts = [v for v in ext_a['geom'] if isinstance(v, bmesh.types.BMVert)]
	edges = [e for e in ext_a['geom'] if isinstance(e, bmesh.types.BMEdge)]
	bmesh.ops.translate(bm, verts=verts, vec=(0, diag_reach, -drop))

	ext_b = bmesh.ops.extrude_edge_only(bm, edges=edges)
	verts = [v for v in ext_b['geom'] if isinstance(v, bmesh.types.BMVert)]
	edges = [e for e in ext_b['geom'] if isinstance(e, bmesh.types.BMEdge)]
	bmesh.ops.translate(bm, verts=verts, vec=(0, half_run * 2.0, 0))

	ext_c = bmesh.ops.extrude_edge_only(bm, edges=edges)
	verts = [v for v in ext_c['geom'] if isinstance(v, bmesh.types.BMVert)]
	edges = [e for e in ext_c['geom'] if isinstance(e, bmesh.types.BMEdge)]
	bmesh.ops.translate(bm, verts=verts, vec=(0, diag_reach, drop))

	# 3. Wrap around the FRONT sprocket center: bottom -> front -> top.
	ret2 = bmesh.ops.spin(bm, geom=verts + edges, cent=(0, half_span, 0), axis=(1, 0, 0),
		angle=math.radians(180), steps=arc_segments, use_duplicate=False)
	verts = [v for v in ret2['geom_last'] if isinstance(v, bmesh.types.BMVert)]
	edges = [e for e in ret2['geom_last'] if isinstance(e, bmesh.types.BMEdge)]

	# 4. Straight top run back to the start point, closing the loop -
	# unchanged, the top stays a simple direct line (the "narrow/high" side
	# of the trapezoid).
	ext2 = bmesh.ops.extrude_edge_only(bm, edges=edges)
	verts = [v for v in ext2['geom'] if isinstance(v, bmesh.types.BMVert)]
	bmesh.ops.translate(bm, verts=verts, vec=(0, -half_span * 2.0, 0))

	# The final ring's translated position should land exactly back on the
	# original starting ring - weld the seam shut.
	bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=0.001)
	bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.6)
	return obj


def build_screw_drum(name, length=1.6, shaft_radius=0.13, fin_reach=0.16, turns=3.0,
		color=(0.35, 0.32, 0.28)):
	"""Helical auger/screw drum for amphibious screw-drive locomotion (real
	historical screw-propelled vehicles - Soviet ZIL screw-drive trucks, the
	Fordson 'Snow Devil') - a tapered-cap core shaft with a continuous
	helical fin approximated by many short radial blade segments advancing
	in both angle and length together, along Godot +Z (matches the
	runtime mounting convention: the drum's own length lies parallel to the
	vehicle's travel direction, one drum per side).

	NOTE: 'x' (not 'z') on the shaft's add_cyl_axis calls is intentional -
	same add_cyl_axis 'x'/'z' swap already documented on build_engine_core -
	'x' is what actually yields a Godot-Z-long (fore-aft) result. Without
	this the shaft stuck out sideways through the (correctly Z-aligned,
	since it's built from raw positions/rotations rather than add_cyl_axis)
	helical fin ring - Chris's report, 2026-07-24."""
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), shaft_radius, length, 'x', segments=14)
	# radius1/radius2 swapped from the first pass (Chris's report, 2026-07-24:
	# "the cones on each end are backwards") - the tapered tip now comes to
	# a POINT at the outer end and widens toward the shaft, like a real
	# auger nose, instead of flaring open outward.
	add_cyl_axis(bm, (0, 0, -length * 0.5 - length * 0.05), shaft_radius, length * 0.1, 'x', segments=14, radius2=0.02)
	add_cyl_axis(bm, (0, 0, length * 0.5 + length * 0.05), 0.02, length * 0.1, 'x', segments=14, radius2=shaft_radius)

	# Chris's ask, 2026-07-24 ("the blades part of the helix seem to be
	# sitting wrong... build the drum and helix as a single unit"): this
	# was already one bmesh/GLB (shaft + fin both go into the same `bm`
	# below, exported as a single object) - the geometry itself checks out
	# too (each segment's radial "reach" and its Z-progression overlap are
	# both correctly aligned, verified by hand against the coordinate
	# convention at the top of this file). The actual problem is more
	# segments=40 read as a scattered pile of separate short paddles
	# rather than one continuous auger flight - tripled to 120 (with a
	# matched larger overlap factor below) for a visibly smoother, more
	# continuous-looking single ribbon.
	segments = 120
	r_mid = shaft_radius + fin_reach / 2.0
	for i in range(segments):
		t = i / float(segments)
		z = -length * 0.5 + length * 0.1 + t * length * 0.8
		angle = t * turns * 2.0 * math.pi
		pos = (math.cos(angle) * r_mid, math.sin(angle) * r_mid, z)
		add_box(bm, pos, (fin_reach, 0.045, (length * 0.8 / segments) * 2.4), rot_axis='z', rot_angle=angle)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.65, roughness=0.55)
	return obj


def build_wheel_axle_bar(name, length=0.8, radius=0.05, color=(0.2, 0.2, 0.22)):
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius, length, 'x', segments=12)
	greeble_bolt_ring(bm, (-length * 0.45, 0, 0), radius * 1.4, count=4, axis='x')
	greeble_bolt_ring(bm, (length * 0.45, 0, 0), radius * 1.4, count=4, axis='x')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.4)
	return obj


def build_rotor_mast(name, height=0.6, radius_bottom=0.07, radius_top=0.05, color=(0.25, 0.25, 0.28)):
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius_bottom, height, segments=14, radius2=radius_top)
	greeble_bolt_ring(bm, (0, height * 0.1, 0), radius_bottom * 1.3, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.4)
	return obj


def build_rotor_hub(name, radius=0.22, height=0.15, color=(0.2, 0.2, 0.22)):
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius, height, segments=16)
	greeble_bolt_ring(bm, (0, height * 0.9, 0), radius * 0.75, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.65, roughness=0.35)
	return obj


def build_rotor_blade(name, length=1.2, width_root=0.16, width_tip=0.08, thickness=0.02, color=(0.18, 0.18, 0.2)):
	bm = bmesh.new()
	pts = [
		(-width_root * 0.5, 0, 0), (width_root * 0.5, 0, 0),
		(-width_tip * 0.5, 0, length), (width_tip * 0.5, 0, length),
		(-width_root * 0.5, thickness, 0), (width_root * 0.5, thickness, 0),
		(-width_tip * 0.5, thickness, length), (width_tip * 0.5, thickness, length)
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.5)
	return obj


def build_tapered_strut(name, length=1.0, near_half=0.12, far_half=0.36, depth_scale=1.0, color=(0.25, 0.25, 0.28)):
	"""Structural strut/pylon, thin at local Y=0 (near_half) and flaring out
	to a much thicker cross-section at local Y=length (far_half) - same
	taper technique build_rotor_blade already uses (two rectangular rings
	of verts through convex_hull, safe here since both cross-sections are
	convex rectangles and the whole shape stays convex end-to-end, no
	re-entrant profile). Used for helicopter_rotors' hull-mounting pylon,
	which needs to read as load-bearing - thick where it roots into the
	hull, thin where it meets the rotor. depth_scale (default 1.0, square
	cross-section) shrinks ONLY the local-Z half-width relative to local-X,
	flattening the strut into a wide, thin blade instead of a square rod -
	used for hover_engine's mounting pylon (Chris's ask: "about 3 times as
	wide as they are thick", i.e. depth_scale=1/3)."""
	bm = bmesh.new()
	pts = [
		(-near_half, 0, -near_half * depth_scale), (near_half, 0, -near_half * depth_scale),
		(-near_half, 0, near_half * depth_scale), (near_half, 0, near_half * depth_scale),
		(-far_half, length, -far_half * depth_scale), (far_half, length, -far_half * depth_scale),
		(-far_half, length, far_half * depth_scale), (far_half, length, far_half * depth_scale),
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.45)
	return obj


def build_aerofoil_strut(name, length=1.0, chord=0.5, thickness=0.16, taper=0.85, color=(0.3, 0.3, 0.33)):
	"""Mounting pylon with a simplified symmetric aerofoil cross-section
	(Chris's ask: "vaguely aerofoil shaped... pretend that gives enough
	lift") - a 6-point convex hexagon standing in for a real aerofoil
	profile (blunt-ish leading edge, max thickness biased toward the front
	third, pointed trailing edge), swept along local Y the same two-ring
	convex_hull taper technique build_tapered_strut uses. `taper` (0-1)
	shrinks the far end only slightly relative to the near end - kept
	close to 1.0 by default since fixed_wing_engine's pylon should read as
	substantially thicker throughout ("significantly thicker than the
	hover ones"), not whip-thin at either end like that strut."""
	bm = bmesh.new()

	def profile(y, chord_s, thick_s):
		return [
			(-0.5 * chord_s, y, 0.0),
			(-0.2 * chord_s, y, 0.5 * thick_s),
			(0.2 * chord_s, y, 0.5 * thick_s),
			(0.5 * chord_s, y, 0.0),
			(0.2 * chord_s, y, -0.5 * thick_s),
			(-0.2 * chord_s, y, -0.5 * thick_s),
		]

	pts = profile(0.0, chord, thickness) + profile(length, chord * taper, thickness * taper)
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.35)
	return obj


def build_engine_core(name, length=0.6, radius=0.32, color=(0.32, 0.32, 0.35)):
	"""Turbine core segment, sits behind the main nacelle - its own length
	is what fixed_wing_engine's turbine_compression tweak stretches/
	compresses at runtime ("physically scale a central part of the engine
	housing longer or shorter... out the back", Chris's ask). Authored
	along local Z like build_engine_nacelle/build_engine_fan/
	build_exhaust_cone (the rest of this engine's part family), not local
	Y, so it shares their placement/rotation convention in
	_build_fixed_wing_engine(). A few compressor-ring grooves via stacked
	slightly-recessed rings read as turbine detail without needing a
	boolean cut.

	NOTE: add_cyl_axis's 'x'/'z' godot_axis arguments are swapped from what
	their docstring promises (verified empirically - requesting 'z' actually
	yields a Godot-X-long cylinder, and 'x' yields Godot-Z-long). Passing
	'x' here is the correct call to get a Godot-Z-long (fore-aft) result;
	it is NOT a typo. This is a local workaround for this part family only -
	the shared bug in add_cyl_axis itself is intentionally left alone for
	now (see fixed_wing_engine investigation, 2026-07-24) since other parts
	built with add_cyl_axis may already depend on its current behavior."""
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius, length, 'x', segments=18)
	rings = 4
	for i in range(1, rings):
		z = -length * 0.5 + length * (i / float(rings))
		add_cyl_axis(bm, (0, 0, z), radius * 1.03, length * 0.04, 'x', segments=18)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.7, roughness=0.3)
	return obj


def build_rotor_duct_ring(name, major_radius=1.2, minor_radius=0.06, height=0.25, color=(0.3, 0.3, 0.33)):
	"""Ducted-fan shroud wall. Previously used add_cyl_y for the wall, which
	always cap_ends=True (it has no hollow option) - at this radius/height
	that rendered as a solid opaque drum completely covering the blades
	instead of a ring they spin inside (caught via a debug capture, not
	code review - a solid disc reads fine in a thumbnail-sized screenshot).
	Built here directly with cap_ends=False for a genuine hollow tube, with
	a thin torus rim (add_ring) top and bottom for a lipped-edge look."""
	bm = bmesh.new()
	wall_radius = major_radius + minor_radius
	ret = bmesh.ops.create_cone(bm, cap_ends=False, cap_tris=False, segments=32,
		radius1=wall_radius, radius2=wall_radius, depth=height)
	bmesh.ops.translate(bm, verts=ret['verts'], vec=GV(0, height * 0.5, 0))
	add_ring(bm, (0, 0, 0), wall_radius, minor_radius * 0.6, major_segments=32, minor_segments=8)
	add_ring(bm, (0, height, 0), wall_radius, minor_radius * 0.6, major_segments=32, minor_segments=8)
	bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.45, roughness=0.5)
	return obj


def build_drive_sprocket(name, radius=0.4, width=0.3, teeth=10, color=(0.18, 0.18, 0.2)):
	bm = bmesh.new()
	add_cyl_y(bm, (0, width * 0.5, 0), radius * 0.85, width, segments=20)
	for i in range(teeth):
		angle = i * (2.0 * math.pi / teeth)
		pos = (math.cos(angle) * radius * 0.92, width * 0.5, math.sin(angle) * radius * 0.92)
		add_box(bm, pos, (radius * 0.2, width * 0.95, radius * 0.12), rot_axis='y', rot_angle=angle)
	greeble_bolt_ring(bm, (0, width, 0), radius * 0.5, count=6, axis='y')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.5)
	return obj


def build_leg_foot(name, size_x=0.4, size_y=0.12, size_z=0.5, color=(0.22, 0.22, 0.24)):
	bm = bmesh.new()
	add_box(bm, (0, size_y * 0.5, 0), (size_x, size_y, size_z), bevel=0.02)
	add_box(bm, (0, size_y * 0.8, -size_z * 0.25), (size_x * 0.7, size_y * 0.6, size_z * 0.4), bevel=0.015)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.4, roughness=0.6)
	return obj


def build_hover_fan(name, radius=0.4, height=0.08, blades=8, color=(0.25, 0.25, 0.28)):
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius * 0.3, height * 1.2, segments=14)
	add_cyl_y(bm, (0, height * 0.5, 0), radius, height, segments=20)
	for i in range(blades):
		angle = i * (2.0 * math.pi / blades)
		pos = (math.cos(angle) * radius * 0.6, height * 0.5, math.sin(angle) * radius * 0.6)
		add_box(bm, pos, (radius * 0.75, height * 0.6, 0.03), rot_axis='y', rot_angle=angle)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.4)
	return obj


def build_hover_skirt(name, radius_top=0.5, radius_bottom=0.65, height=0.35, color=(0.12, 0.12, 0.14)):
	bm = bmesh.new()
	add_cyl_y(bm, (0, height * 0.5, 0), radius_top, height, segments=24, radius2=radius_bottom)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.1, roughness=0.85)
	return obj


def build_engine_nacelle(name, length=1.2, radius=0.3, color=(0.4, 0.42, 0.45)):
	# NOTE: 'x' here (not 'z') is intentional - add_cyl_axis's 'x'/'z' args
	# are swapped from what they claim (see build_engine_core's comment);
	# 'x' is what actually yields a Godot-Z-long (fore-aft) result.
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius * 0.7, length, 'x', segments=20, radius2=radius)
	add_cyl_axis(bm, (0, 0, -length * 0.5 - 0.05), radius * 0.7, 0.1, 'x', segments=20, radius2=radius * 0.5)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.35)
	return obj


def build_engine_fan(name, radius=0.28, height=0.06, blades=12, color=(0.2, 0.2, 0.22)):
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius * 0.25, height * 1.5, 'x', segments=14)
	for i in range(blades):
		angle = i * (2.0 * math.pi / blades)
		pos = (math.cos(angle) * radius * 0.55, math.sin(angle) * radius * 0.55, 0)
		add_box(bm, pos, (radius * 0.7, 0.02, height), rot_axis='z', rot_angle=angle)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.7, roughness=0.3)
	return obj


def build_exhaust_cone(name, radius=0.25, length=0.3, color=(0.15, 0.15, 0.16)):
	# 'x' (not 'z') for the same add_cyl_axis-swap reason as engine_nacelle/
	# engine_core above.
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius, length, 'x', segments=16, radius2=radius * 0.6)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.75, roughness=0.3)
	return obj


def build_wing_shoulder(name, size=(0.3, 0.2, 0.7), color=(0.3, 0.3, 0.33)):
	# Lengthened fore-aft (Z, was 0.25) so one gearbox block can plausibly
	# span BOTH the fore and hind wing roots (offset +-0.22 on Z, see
	# _build_ornithopter_wing's root_gap) - the old 0.25 didn't even reach
	# either root's Z offset, let alone both.
	bm = bmesh.new()
	add_box(bm, (0, size[1] * 0.5, 0), size, bevel=0.02)
	greeble_bolt_ring(bm, (size[0] * 0.5, size[1] * 0.5, 0), min(size[1], size[2]) * 0.35, count=5, axis='x')
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.45)
	return obj


def build_wing_membrane(name, length=2.4, width_root=0.3, width_tip=0.05, thickness=0.015, color=(0.25, 0.28, 0.3)):
	# Rebuilt much longer and narrower (Chris's ask, 2026-07-24) for a
	# dragonfly-like silhouette - was length=1.2/width_root=0.4/width_tip=
	# 0.15 (aspect ratio ~3); now ~8, tapering to a fine point at the tip
	# instead of a stubby paddle shape.
	bm = bmesh.new()
	pts = [
		(0, 0, -width_root * 0.5), (0, 0, width_root * 0.5),
		(length, 0, -width_tip * 0.5), (length, 0, width_tip * 0.5),
		(0, thickness, -width_root * 0.5), (0, thickness, width_root * 0.5),
		(length, thickness, -width_tip * 0.5), (length, thickness, width_tip * 0.5)
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.2, roughness=0.6)
	return obj


def build_wing_rib(name, length=2.3, thickness=0.03, height=0.04, color=(0.2, 0.2, 0.22)):
	# Lengthened to match build_wing_membrane's new longer span (was 1.1).
	bm = bmesh.new()
	add_box(bm, (length * 0.5, height * 0.5, 0), (length, height, thickness), bevel=0.008)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.4)
	return obj


def build_prop_housing(name, length=0.4, radius_front=0.15, radius_back=0.08, color=(0.28, 0.3, 0.32)):
	# 'x' (not 'z') for the same add_cyl_axis-swap reason as
	# build_engine_nacelle/build_engine_core/build_exhaust_cone (see
	# build_engine_core's comment) - 'x' is what actually yields a
	# Godot-Z-long (fore-aft) result. Without this, the housing faced
	# spanwise instead of backwards (Chris's report, 2026-07-24).
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius_front, length, 'x', segments=16, radius2=radius_back)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.6, roughness=0.4)
	return obj


def build_kort_nozzle(name, major_radius=0.45, minor_radius=0.04, height=0.25, color=(0.25, 0.25, 0.28)):
	bm = bmesh.new()
	add_ring(bm, (0, 0, 0), major_radius, minor_radius, major_segments=24, minor_segments=8)
	add_cyl_axis(bm, (0, 0, 0), major_radius + minor_radius, height, 'z', segments=24)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.45)
	return obj


def build_cruise_nacelle(name, length=0.6, radius=0.15, color=(0.35, 0.35, 0.38)):
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius, length, 'z', segments=14, radius2=radius * 0.6)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.4)
	return obj


def build_outrigger_strut(name, length=0.8, radius=0.03, color=(0.2, 0.2, 0.22)):
	bm = bmesh.new()
	add_cyl_axis(bm, (0, 0, 0), radius, length, 'x', segments=10)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.5)
	return obj


def build_tail_fin(name, height=0.5, width_bottom=0.3, width_top=0.12, thickness=0.02, color=(0.3, 0.3, 0.35)):
	bm = bmesh.new()
	pts = [
		(0, 0, -width_bottom * 0.5), (0, 0, width_bottom * 0.5),
		(0, height, -width_top * 0.5), (0, height, width_top * 0.5),
		(thickness, 0, -width_bottom * 0.5), (thickness, 0, width_bottom * 0.5),
		(thickness, height, -width_top * 0.5), (thickness, height, width_top * 0.5)
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.3, roughness=0.6)
	return obj


def build_resource_bay_tub(name, width=1.0, height=1.0, depth=1.0, ribs=4,
		color=(0.42, 0.36, 0.20)):
	"""The Resource Bay's hopper body - an open-topped ore tub.

	Built at unit dimensions so visual_builder.gd can scale it per-axis from
	the bay's three tweaks: width from hatch_width, height from hopper_depth
	and the whole thing from bay_volume. That is why the ribs run VERTICALLY
	and the flange is a flat band rather than a moulding: both survive a
	non-uniform scale without visibly shearing, which a diagonal brace or a
	rounded lip would not.

	The silhouette is deliberately industrial-mundane - a skip, not a
	sci-fi container. It is the least glamorous part on the vehicle and it
	should read that way at RTS camera distance: wide flat walls that catch
	the key light, a heavy top flange to break the outline, and enough rib
	rhythm along the sides that it never reads as a plain box.

	Walls slope OUTWARD toward the top (the tub is narrower at the floor),
	which is both how a real dump body is drawn and the thing that makes it
	legible from directly above, where most of the game is played.
	"""
	bm = bmesh.new()
	hw, hh, hd = width * 0.5, height * 0.5, depth * 0.5

	# Floor pan, then four walls raked outward. Built as four boxes rather
	# than an extruded shell so the tub keeps a real wall THICKNESS - the
	# open top is the whole read of the part, and a zero-thickness rim looks
	# like a hole rather than a container.
	wall = 0.055
	add_box(bm, (0, wall * 0.5, 0), (width * 0.9, wall, depth * 0.9), bevel=0.01)

	rake = 0.10  # how far the top lip stands proud of the floor, per side
	for sign in (-1, 1):
		# Long walls (+/-X), raked out along X.
		add_box(bm, (sign * (hw * 0.9 + rake * 0.5), hh, 0),
			(wall, height, depth * 0.92),
			rot_axis='z', rot_angle=math.radians(-sign * 4.5), bevel=0.012)
		# End walls (+/-Z), raked out along Z.
		add_box(bm, (0, hh, sign * (hd * 0.9 + rake * 0.5)),
			(width * 0.92, height, wall),
			rot_axis='x', rot_angle=math.radians(sign * 4.5), bevel=0.012)

	# Top flange. One continuous band around the mouth, which is what stops
	# the open top reading as a cut rather than as an edge.
	flange = 0.07
	for sign in (-1, 1):
		add_box(bm, (sign * (hw + rake * 0.5), height, 0),
			(flange * 1.6, flange, depth + flange * 2.0), bevel=0.015)
		add_box(bm, (0, height, sign * (hd + rake * 0.5)),
			(width + flange * 2.0, flange, flange * 1.6), bevel=0.015)

	# Vertical stiffener ribs down the long walls, plus a bolt row along the
	# floor seam. Rib count is a parameter so the part can be rebuilt heavier
	# later without touching the proportions.
	for sign in (-1, 1):
		for i in range(ribs):
			t = (i + 0.5) / ribs - 0.5
			add_box(bm, (sign * (hw + rake * 0.55), hh * 0.95, t * depth * 0.82),
				(0.05, height * 0.86, 0.09), bevel=0.008)
		greeble_rivet_row(bm,
			(sign * (hw * 0.92), wall * 1.2, -hd * 0.8),
			(sign * (hw * 0.92), wall * 1.2, hd * 0.8),
			7, radius=0.022, height=0.02, axis='x')

	# Discharge chute on the -Z end, angled down: this is the end that lines
	# up with a refinery bay, and having a visible unload point is what makes
	# the module read as "carries ore" rather than "is a box".
	add_box(bm, (0, height * 0.30, -(hd + rake * 0.5 + 0.10)),
		(width * 0.42, height * 0.34, 0.20),
		rot_axis='x', rot_angle=math.radians(14.0), bevel=0.02)
	greeble_bolt_ring(bm, (0, height * 0.30, -(hd + rake * 0.5 + 0.20)),
		width * 0.20, count=8, bolt_radius=0.022, axis='z')

	# Fill-level sight gauge on one end - a small readable detail that gives
	# the part an "up" and stops it being symmetric under mirroring.
	add_box(bm, (hw * 0.55, hh, hd + rake * 0.55), (0.07, height * 0.7, 0.045), bevel=0.006)

	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.35, roughness=0.68)
	return obj


def build_resource_bay_lid(name, width=1.0, depth=1.0, color=(0.30, 0.31, 0.33)):
	"""The Bay's hinged spill cover, exported separately from the tub.

	Two pieces rather than one so visual_builder.gd can scale the lid by
	hatch_width alone while the tub also answers to hopper_depth - and so a
	future open/closed animation has a node to rotate. It is modelled flat
	and hinged along +Z, sitting at the tub's mouth.
	"""
	bm = bmesh.new()
	add_box(bm, (0, 0, 0), (width, 0.055, depth), bevel=0.015)
	# Diagonal-free bracing: two straight spines, for the same non-uniform
	# scale reason as the tub's vertical ribs.
	for sign in (-1, 1):
		add_box(bm, (sign * width * 0.26, 0.045, 0), (0.06, 0.05, depth * 0.9), bevel=0.008)
	add_box(bm, (0, 0.045, 0), (width * 0.9, 0.05, 0.06), bevel=0.008)
	# Hinge knuckles along the +Z edge and a grab handle on the free edge.
	for t in (-0.3, 0.0, 0.3):
		add_cyl_axis(bm, (t * width, 0.0, depth * 0.5), 0.045, width * 0.12, 'x', segments=8)
	add_box(bm, (0, 0.09, -depth * 0.42), (width * 0.3, 0.045, 0.045), bevel=0.01)

	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.5, roughness=0.5)
	return obj


def build_accessory(name, kind, color, **kwargs):
	"""Standalone small greeble accessories - also usable directly as weapon
	sub-parts (headlight cluster, exhaust, antenna, hatch, vent, toolbox)."""
	bm = bmesh.new()
	if kind == "exhaust":
		greeble_exhaust_stack(bm, (0, kwargs.get("height", 0.35) / 2.0, 0),
			radius=kwargs.get("radius", 0.08), height=kwargs.get("height", 0.35))
	elif kind == "antenna":
		greeble_antenna(bm, (0, 0, 0), height=kwargs.get("height", 0.55), radius=kwargs.get("radius", 0.018))
	elif kind == "vent":
		greeble_vent(bm, (0, kwargs.get("size", (0.4, 0.1, 0.25))[1] / 2.0, 0), kwargs.get("size", (0.4, 0.1, 0.25)))
	elif kind == "hatch":
		greeble_hatch(bm, (0, kwargs.get("size", (0.6, 0.06, 0.6))[1] / 2.0, 0), kwargs.get("size", (0.6, 0.06, 0.6)))
	elif kind == "toolbox":
		greeble_toolbox(bm, (0, kwargs.get("size", (0.5, 0.28, 0.32))[1] / 2.0, 0), kwargs.get("size", (0.5, 0.28, 0.32)))
	elif kind == "spotlight":
		greeble_spotlight(bm, (0, 0, 0), radius=kwargs.get("radius", 0.11))
	elif kind == "sensor_mast":
		add_cyl_y(bm, (0, kwargs.get("height", 1.0) / 2.0, 0), 0.05, kwargs.get("height", 1.0), segments=10, radius2=0.03)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=kwargs.get("metallic", 0.5), roughness=kwargs.get("roughness", 0.5))
	return obj


# ---------------------------------------------------------------------------
# Hull chassis builder - convex hull from a hand-placed "keel" point cloud,
# with fused-on greebles for detail. Robust (convex_hull is always
# manifold) and lets a handful of numeric parameters produce meaningfully
# different silhouettes.
# ---------------------------------------------------------------------------

def build_wedge_hull(name, size_x, size_y, size_z, nose_frac=0.0, spine_w=0.5, spine_h=1.1,
		rear_flare=0.9, front_flare=1.0, color=(0.55, 0.56, 0.58), greebles=None, taper_slices=7,
		nose_region=0.35, height_taper=0.0, bevel_pct=None, bevel_segments=None, bevel_angle_deg=20.0,
		waist_inset=0.0, waist_height_frac=0.5, deck_line=0.0, deck_line_z_frac=(0.6, 0.95),
		panel_line_fracs=None, speed_line_chamfer=False, armor_front_frac=0.4,
		v_belly_depth=0.0, front_belly_slope=0.0, rear_belly_slope=0.0):
	"""height_taper (0..1): brings the deck down toward the nose too, for
	archetypes wanting a dart/wedge silhouette rather than just narrowing
	in width (interceptor_hull's "extreme taper in width AND height").
	bevel_pct/bevel_segments let each archetype sit at a different point
	within (or just outside) the tier-1 band - see Section 2 of the
	design doc: light reads narrow/subtle, heavy reads wide/chunky,
	interceptor reads narrow-and-sharp."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()
	pts = []

	# Belly vertices - with V-belly keel and sloped ends if specified
	keel_y = -hy + v_belly_depth * hy * 2.0 if v_belly_depth > 0.0 else -hy
	front_belly_y = -hy + front_belly_slope * hy * 2.0 if front_belly_slope > 0.0 else -hy
	rear_belly_y = -hy + rear_belly_slope * hy * 2.0 if rear_belly_slope > 0.0 else -hy

	pts += [
		(-hx, front_belly_y, -hz), (hx, front_belly_y, -hz),
		(-hx, rear_belly_y, hz), (hx, rear_belly_y, hz)
	]
	if v_belly_depth > 0.0 or front_belly_slope > 0.0 or rear_belly_slope > 0.0:
		pts.append((0.0, max(keel_y, front_belly_y), -hz))
		pts.append((0.0, max(keel_y, rear_belly_y), hz))
		for i in range(1, 5):
			t = i / 5.0
			z = -hz + t * size_z
			mid_belly = front_belly_y + (rear_belly_y - front_belly_y) * t
			interp_y = max(keel_y, mid_belly)
			pts.append((0.0, interp_y, z))

	# Top deck: a real multi-slice loft along Z with the non-linear
	# (eased, nose-aggressive) taper curve instead of a single hard
	# front/rear cross-section jump.
	for i in range(taper_slices):
		t = i / float(taper_slices - 1)
		z = -hz + t * size_z
		scale = taper_profile(t, nose_frac, front_flare, rear_flare, nose_region=nose_region)
		deck_y = hy
		if height_taper > 0.0:
			h_scale = taper_profile(t, nose_frac, 1.0 - height_taper, 1.0, nose_region=nose_region)
			deck_y = hy * h_scale
		pts.append((-hx * scale, deck_y, z))
		pts.append((hx * scale, deck_y, z))
	if nose_frac > 0.01:
		nose_y = hy * 0.6 * (1.0 - height_taper) if height_taper > 0.0 else hy * 0.6
		pts.append((0.0, nose_y, -hz))

	pts += [(-hx * spine_w, hy * spine_h, hz * 0.1), (hx * spine_w, hy * spine_h, hz * 0.1)]
	pts += [(-hx * spine_w, hy * spine_h, -hz * 0.3), (hx * spine_w, hy * spine_h, -hz * 0.3)]

	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# Tier 2: waist-inset / deck-line step - pure silhouette shaping,
	# applied AFTER the taper loft but BEFORE the bevel (which needs to
	# smooth their new cut edges too) and well before greebles, per the
	# design doc's mount-zone-aware ordering.
	if waist_inset > 0.0:
		add_waist_inset(bm, hx, hy, hz, depth_frac=waist_inset, height_frac=waist_height_frac)
	if deck_line > 0.0:
		add_deck_line_step(bm, hx, hy, hz, height_frac=deck_line, z_frac=deck_line_z_frac)
	if panel_line_fracs:
		for z_frac in panel_line_fracs:
			add_panel_line_groove(bm, hx, hy, hz, R, z_frac)
	if speed_line_chamfer:
		add_speed_line_chamfer(bm, hx, hy, hz)

	# Tier-1 bevel on the hull's own real structural edges (belly-to-deck
	# transition, nose tip, spine ridge, and any new waist/deck-line cuts)
	# - applied BEFORE greebles are fused on so it only ever touches the
	# primary silhouette. Uses the CURRENT vert set, not the original
	# convex-hull input, since bisect_plane above may have added verts.
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, angle_deg=bevel_angle_deg, pct=bevel_pct, segments=bevel_segments)

	# Hard-armor region: the nose taper's front arc, same frontal_armor_
	# predicate() technique as the AFV/ship hulls - a wedge hull's own
	# extreme nose taper (interceptor_hull's whole identity) makes the
	# front region naturally small relative to the long tapered top deck
	# and flat belly, so this stays a minority of area without needing a
	# smaller front_frac than the boxier AFV hulls.
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_afv_hull(name, size_x, size_y, size_z, nose_frac=0.0, tub_frac=0.55, upper_w=0.8,
		glacis_len_frac=0.3, fender_frac=1.0, fender_height_frac=0.12,
		spine_w=0.5, spine_h=1.1, color=(0.55, 0.56, 0.58), greebles=None,
		bevel_pct=None, bevel_segments=None, turret_ring=False, louver_panel=None,
		waist_inset=0.0, waist_height_frac=0.5, deck_line=0.0, deck_line_z_frac=(0.6, 0.95),
		panel_line_fracs=None, armor_front_frac=0.5, v_belly_depth=0.0, rear_glacis_slope=0.0,
		lateral_slope_frac=0.0, rear_belly_slope=0.0, front_belly_slope=0.0):
	"""Ground AFV hull with configurable V-belly, lateral slopes, sloped rear glacis,
	and sloped front/rear belly slopes. Uses multiple convex hull volumes fused together."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()

	tub_top_y = -hy + 2.0 * hy * tub_frac

	# ---- Volume A: Lower hull tub with V-belly and sloped belly ends ----
	nose_x_scale = 1.0 - nose_frac * 0.3

	keel_y = -hy + v_belly_depth * hy * 2.0 if v_belly_depth > 0.0 else -hy
	front_belly_y = -hy + front_belly_slope * hy * 2.0 if front_belly_slope > 0.0 else -hy
	rear_belly_y = -hy + rear_belly_slope * hy * 2.0 if rear_belly_slope > 0.0 else -hy

	tub_pts = [
		# Front bottom corners (with front belly slope)
		(-hx * nose_x_scale, front_belly_y, -hz), (hx * nose_x_scale, front_belly_y, -hz),
		# Rear bottom corners (with rear belly slope)
		(-hx, rear_belly_y, hz), (hx, rear_belly_y, hz),
		# Front keel (center bottom at nose)
		(0.0, max(keel_y, front_belly_y), -hz),
		# Rear keel (center bottom at tail)
		(0.0, max(keel_y, rear_belly_y), hz),
		# Tub roof corners (front and rear)
		(-hx * nose_x_scale, tub_top_y, -hz), (hx * nose_x_scale, tub_top_y, -hz),
		(-hx, tub_top_y, hz), (hx, tub_top_y, hz),
	]

	# Add intermediate keel points along the length for a smooth V
	if v_belly_depth > 0.0 or front_belly_slope > 0.0 or rear_belly_slope > 0.0:
		for i in range(1, 5):
			t = i / 5.0
			z = -hz + t * size_z
			mid_belly = front_belly_y + (rear_belly_y - front_belly_y) * t
			interp_y = max(keel_y, mid_belly)
			tub_pts.append((0.0, interp_y, z))

	tub_verts = [bm.verts.new(GV(*p)) for p in tub_pts]
	bmesh.ops.convex_hull(bm, input=tub_verts)

	# ---- Volume B: Upper structure (glacis + casemate/engine deck) ----
	uw = hx * upper_w
	# Apply lateral slope - upper structure narrower at top
	uw_top = uw * (1.0 - lateral_slope_frac) if lateral_slope_frac > 0.0 else uw
	glacis_deck_z = -hz + size_z * glacis_len_frac
	# Rear glacis - if rear_glacis_slope > 0, the rear slopes downward
	rear_deck_z = hz - size_z * rear_glacis_slope if rear_glacis_slope > 0.0 else hz
	rear_top_y = hy * (1.0 - rear_glacis_slope * 0.5) if rear_glacis_slope > 0.0 else hy
	upper_pts = [
		# Front bottom (at tub roof)
		(-uw, tub_top_y, -hz), (uw, tub_top_y, -hz),
		# Glacis top / deck front
		(-uw_top, hy, glacis_deck_z), (uw_top, hy, glacis_deck_z),
		# Rear deck (sloped if rear_glacis_slope > 0)
		(-uw_top, rear_top_y, rear_deck_z), (uw_top, rear_top_y, rear_deck_z),
		# Rear bottom (at tub roof)
		(-uw, tub_top_y, hz), (uw, tub_top_y, hz),
	]
	upper_verts = [bm.verts.new(GV(*p)) for p in upper_pts]
	bmesh.ops.convex_hull(bm, input=upper_verts)

	# ---- Volume S: Spine ridge along the deck (mount rail) ----
	spine_pts = [
		(-hx * spine_w, hy * spine_h, hz * 0.1), (hx * spine_w, hy * spine_h, hz * 0.1),
		(-hx * spine_w, hy * spine_h, -hz * 0.3), (hx * spine_w, hy * spine_h, -hz * 0.3),
	]
	spine_verts = [bm.verts.new(GV(*p)) for p in spine_pts]
	bmesh.ops.convex_hull(bm, input=spine_verts)

	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# ---- Volume C: Fenders/sponson shelves at tub-roof seam ----
	fender_outer = hx * fender_frac
	if fender_outer > uw + 0.02:
		fender_reach = fender_outer - uw
		fender_h = hy * fender_height_frac
		for side in (-1, 1):
			add_box(bm, (side * (uw + fender_reach * 0.5), tub_top_y + fender_h * 0.3, 0),
				(fender_reach, fender_h, hz * 1.98), bevel=0.02)

	if waist_inset > 0.0:
		add_waist_inset(bm, hx, hy, hz, depth_frac=waist_inset, height_frac=waist_height_frac)
	if deck_line > 0.0:
		add_deck_line_step(bm, hx, hy, hz, height_frac=deck_line, z_frac=deck_line_z_frac)
	if panel_line_fracs:
		for z_frac in panel_line_fracs:
			add_panel_line_groove(bm, hx, hy, hz, R, z_frac)
	if louver_panel:
		lv_center = (0, hy, hz * louver_panel.get("z_frac", 0.72))
		lv_size = (hx * louver_panel.get("width_frac", 0.85), 0.1, hz * louver_panel.get("depth_frac", 0.3))
		greeble_louver_panel(bm, hy, lv_center, lv_size, R,
			slats=louver_panel.get("slats", 4), recess_frac=louver_panel.get("recess_frac", 0.05))
	if turret_ring:
		add_cyl_y(bm, (0, hy * 1.05, hz * 0.1), min(hx, hz) * 0.32, hy * 0.12, segments=16)

	# Tier-1 bevel on the CURRENT vert set
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=bevel_pct, segments=bevel_segments)

	# Hard-armor region: frontal glacis + tub nose corners
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# NO GREEBLES - bare hulls as requested
	# if greebles:
	#     greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


# ---------------------------------------------------------------------------
# Family shapes + manufacturer signatures - PR-2 redo v2 (2026-08-11)
# ---------------------------------------------------------------------------
# Per Chris's 2026-08-11 followup: "Start entirely from scratch, keeping
# only the manufacturer names. Assign each a basic trait, (i.e. Tidemark
# always has a frustum shaped cab central to the hull body. Osterdam
# always has a hexagonal outline when viewed from above...)." and "These
# are still far too similar to each other, the only real difference is
# the absence of greebles. We should only have one wedge scout, if that,
# from one manufacturer. The others should have a different shape."
#
# The previous redo (commit 83dd80c) put 3 manufacturer variants of the
# same hull shape in 3 colors, which still read as 3 copies of the
# same hull. The new architecture:
#
#   - Family shape (the body): 6 distinct silhouettes, one per family.
#     The body is the 4-corner base (or 3-corner for tapered families);
#     the top is left OPEN for the manufacturer signature to define.
#   - Manufacturer signature (the structural element): 3 distinct
#     treatments, one per manufacturer. The signature defines the hull's
#     top + adds structural features (rib cage, hex outline, conning
#     tower) that become the silhouette's most distinctive read.
#   - Bevel: tier-1 at 8% with 2 segments + tier-2 at 4% with 1
#     segment, for crisp + smooth chamfered edges (per Chris's
#     'crisp and smooth, with chamfered edges to avoid looking cheap
#     and overly sharp' feedback).
#
# Design references (per Chris's pointer to the legacy catalogue):
#   - Meridian: carapace-style angular armored with rib cage.
#   - Osterholm: hexapod-style hexagonal cross section.
#   - Tidemark: pressure_hull-style with conning tower + flat dorsal
#     casing (per the legacy pressure_hull description: "Submarine
#     pressure hull, run on land because nothing here is underwater.
#     The dorsal casing is not decoration...").
# ---------------------------------------------------------------------------

# Osterholm hex proportions per family: (hex_scale_x, hex_scale_z).
# The hex is stretched/squashed to fit the family role - wedge is long
# and narrow, plate is wide and short, pod is roughly square, etc.
# (per Chris's "hexagonal outline when viewed from above (not a regular
# hexagon, stretched and squashed to fit the role)" feedback).
OSTERHOLM_HEX_SCALES = {
	"block":   (1.0, 1.0),    # roughly square
	"wedge":   (0.55, 1.45),  # long and narrow (front of wedge)
	"plate":   (1.45, 0.55),  # wide and short
	"pod":     (1.0, 1.0),    # roughly square
	"carrier": (0.75, 1.25),  # slightly long
	"skiff":   (0.45, 1.55),  # very long and narrow (naval)
}

# --- U-keel body builder (Meridian only â€” the mecha hulls use this) ---
#
# 5-slice cross-section hull. Each slice has 6 verts (bottom-left,
# bottom-right, right-chine, right-roof, left-roof, left-chine).
# Slices are at the front, front-glacis, mid, rear, and stern
# positions along the length. Connected with quads.
#
# Gives the hull a U-shaped cross-section (wide flat belly, sloped
# side sponsons, sloped front glacis and rear deck) instead of a
# flat-bottomed box. Ported from the mecha_legs_project hulls.
#
# Parameters:
#   length, width, height: bounding box in Godot convention
#     (X=width, Y=up, Z=length; -Z=forward)
#   belly_flat_w: width of the flat belly (the widest part)
#   chine_h: height of the chine (where the side sponsons start)
#   sponson_h: height of the top of the side sponsons
#   front_slope_l: length of the sloped front (glacis)
#   rear_slope_l: length of the sloped rear (stern)
#   roof_ratio: ratio of the roof width to the chine width (1.0 = same)

def _u_keel_body(bm, length, width, height, family, tonnage):
	"""U-keel tank body for Meridian. 5-slice cross-section with
	U-shape (flat belly, sloped side sponsons, sloped front glacis
	and rear deck). Body is built centered around (0, 0, 0) so the
	bevel and signature functions (which assume centered verts) work
	correctly.

	Ports the mecha_legs_project cross-section logic into the
	procedural pipeline. Each slice has 6 verts (bottom-left,
	bottom-right, right-chine, right-roof, left-roof, left-chine).
	Connected with quads + front/rear caps.

	NOTE: This function adds verts only. The convex hull at the end
	of _build_hull closes the body and merges the signature elements
	into the silhouette. (PR-2 redo v4, 2026-08-11.)
	"""
	p = U_KEEL_PARAMS[family]
	belly_flat_w  = p["belly_flat_w"]
	chine_h       = p["chine_h"]
	sponson_h     = p["sponson_h"]
	front_slope_l = p["front_slope_l"]
	rear_slope_l  = p["rear_slope_l"]
	roof_ratio    = p["roof_ratio"]

	half_l = length / 2.0
	half_w = width / 2.0
	half_b = belly_flat_w / 2.0

	# Centered Y: belly at -height/2, roof at +height/2.
	y_belly = -height / 2.0
	y_chine = y_belly + chine_h
	y_belt  = y_belly + sponson_h
	y_roof  = height / 2.0

	z_front  =  half_l
	z_glacis =  half_l - front_slope_l
	z_mid    =  0.0
	z_rear   = -half_l + rear_slope_l
	z_stern  = -half_l

	# Slices: (z_position, belly_scale, chine_scale, roof_y_frac)
	# belly_scale / chine_scale shrink the flat-belly / chine widths
	# at the tapered ends; roof_y_frac sets the roof height at that
	# slice (so the glacis and stern have lower roofs than the mid).
	slices = [
		(z_front,  0.25, 0.45, y_chine + (y_roof - y_chine) * 1.15),
		(z_glacis, 0.75, 0.92, y_belly + (y_roof - y_belly) * 0.92),
		(z_mid,    1.0,  1.0,  y_roof),
		(z_rear,   0.9,  0.95, y_belly + (y_roof - y_belly) * 0.95),
		(z_stern,  0.65, 0.78, y_belly + (y_belt  - y_belly) * 0.95),
	]

	for z, b_s, w_s, y_r in slices:
		bw = half_b * b_s
		sw = half_w * w_s
		rw = sw * roof_ratio
		bm.verts.new(GV(-bw, y_belly, z))
		bm.verts.new(GV( bw, y_belly, z))
		bm.verts.new(GV( sw, y_chine, z))
		bm.verts.new(GV( rw, y_r,     z))
		bm.verts.new(GV(-rw, y_r,     z))
		bm.verts.new(GV(-sw, y_chine, z))


# --- Hex-prism body builder (Osterholm only â€” faceted modular pod) ---
#
# 5-slice cross-section hull, each cross-section is a hexagon
# (6 verts). No sponsons, no chine, just a flat-sided hex prism
# that tapers along the length (pointed front, wide mid, blunt
# rear). The cross-section is a regular hex (or stretched per
# family) â€” reads as a faceted modular pod, the opposite of the
# mecha u-keel.

OSTERHOLM_HEX_BODY_PARAMS = {
	# 6 sides, narrow front, wide mid, tapered rear
	"front_taper": 0.35,   # front point reaches 35% of full width
	"mid_width":    1.0,    # mid is full bounding width
	"rear_taper":   0.75,   # rear is 75% of full width
	"front_z":      0.45,   # front point at 45% of half-length
	"rear_z":       0.95,   # rear face at 95% of half-length
}


def _hex_body(bm, length, width, height, family, tonnage):
	"""Faceted hex-prism body for Osterholm. A proper hex prism
	extending in the Y direction (height): 6 top verts at y=+hy
	+ 6 bottom verts at y=-hy, with the hex's plan-view outline in
	the X-Z plane filling the hull's (X, Z) bounding box.

	Per Chris's 2026-08-12 feedback: "Don't re-use the v hull, build
	separate, unrelated basics per manufacturer. Again, as if the
	different manufacturers used entirely different design
	philosophies." The hex prism is fundamentally different from
	the Meridian u-keel: faceted, no sponsons, no chine, the body's
	plan-view outline IS the hex. No "bow" or "stern" â€” the hex
	prism is symmetric front/back; the signature adds the dorsal
	asymmetry (central spine / antenna / rails) that distinguishes
	the front from the back.

	NOTE: This function adds verts only. The convex hull at the end
	of _build_hull closes the body and merges the signature elements
	into the silhouette. The body is built as a top hex face +
	bottom hex face + 6 side quads (12 verts total). The hex's
	plan-view outline is in the bmesh X-Z plane, with X radius =
	half_w and Z radius = half_l. The per-family stretch in
	OSTERHOLM_HEX_SCALES is NOT applied here â€” the SIZES table
	already encodes the family role (wedge is long-narrow, plate
	is wide-short, etc.), so multiplying by scale_x/scale_z on top
	would double-stretch.

	`tonnage` is accepted for signature consistency with the other
	body builders; the hex body itself is tonnage-agnostic.
	"""
	half_l = length / 2.0
	half_w = width / 2.0
	half_h = height / 2.0

	# The hex's plan-view outline has 6 verts on a circle of radius
	# 1.0, scaled by half_w in X and half_l in Z. This makes the
	# hex's X and Z extents match the hull's (width, length).
	def hex_outline_xz(i):
		angle = i * (2 * math.pi / 6) + math.pi / 6
		return (
			math.cos(angle) * half_w,
			math.sin(angle) * half_l,
		)

	# Top hex face (6 verts at y=+half_h)
	for i in range(6):
		x, z = hex_outline_xz(i)
		bm.verts.new(GV(x, half_h, z))

	# Bottom hex face (6 verts at y=-half_h)
	for i in range(6):
		x, z = hex_outline_xz(i)
		bm.verts.new(GV(x, -half_h, z))


# --- Cylindrical pressure-hull body builder (Tidemark only) ---
#
# 5-slice cross-section hull, each cross-section is a circle
# (12 verts for smoothness). No sponsons, just a smooth tube
# that tapers along the length (pointed bow, wide mid, tapered
# stern). Reads as a submarine/boat pressure hull â€” fundamentally
# different from the mecha u-keel and the Osterholm hex prism.

TIDEMARK_CYL_BODY_PARAMS = {
	"segments":      12,    # verts per cross-section
	"front_taper":   0.30,  # bow point at 30% of full radius
	"mid_radius":     1.0,   # mid is full bounding width
	"rear_taper":     0.70,  # stern is 70% of full radius
	"bow_z":          0.45,  # bow at 45% of half-length
	"stern_z":        0.90,  # stern at 90% of half-length
	"y_offset":       0.15,  # raise the hull off the keel slightly
}


def _cyl_body(bm, length, width, height, family, tonnage):
	"""Smooth cylindrical pressure-hull body for Tidemark. 5 circular
	cross-sections (12 verts each) along the length, varying radius.
	Pointed bow vertex + flat circular stern face. Body is centered
	around (0, 0, 0) in the X-Y plane; the cylinder "sits on the
	ground" with its bottom at Y=-height/2.

	Per Chris's 2026-08-12 feedback: "Don't re-use the v hull, build
	separate, unrelated basics per manufacturer." The cylinder is
	fundamentally different from the Meridian u-keel and the
	Osterholm hex prism: smooth, rounded, no sponsons, the body's
	outline IS the circle. Reads as a submarine pressure hull.

	NOTE: This function adds verts only. The convex hull at the end
	of _build_hull closes the body (smooth bow + flat stern) and
	merges the signature elements (conning tower, propeller) into
	the silhouette.
	"""
	half_l = length / 2.0
	half_w = width / 2.0
	p = TIDEMARK_CYL_BODY_PARAMS
	segs = p["segments"]

	# Z positions of the 5 cross-sections
	z_bow_point =  half_l * p["bow_z"]
	z_bow       =  half_l * 0.25
	z_mid       =  0.0
	z_stern     = -half_l * 0.20
	z_stern_face = -half_l * p["stern_z"]

	radius_at = {
		z_bow_point: half_w * p["front_taper"],
		z_bow:       half_w * 0.70,
		z_mid:       half_w * p["mid_radius"],
		z_stern:     half_w * 0.90,
		z_stern_face: half_w * p["rear_taper"],
	}
	slices_z = [z_bow_point, z_bow, z_mid, z_stern, z_stern_face]

	# Each cross-section is a circle of `segs` verts in the X-Y plane,
	# centered at the origin. The radius is the body outline width;
	# the cylinder's overall width IS the body width (so the body's
	# X-width equals 2*half_w).
	# Add a small "y_offset" to lift the cylinder off the keel
	# slightly (gives the silhouette a clear bottom + round top
	# rather than a tangent-to-ground shape).
	for z in slices_z:
		r = radius_at[z]
		for i in range(segs):
			angle = i * (2 * math.pi / segs)
			# Circle in the X-Y plane. Width (X) is the hull's full
			# width. Height (Y) is the hull's full height.
			x = math.cos(angle) * r
			y = math.sin(angle) * (height / 2.0) + p["y_offset"]
			bm.verts.new(GV(x, y, z))

	# Bow vertex: single point at the very front, raised to the
	# mid-height of the cylinder (where the front cross-section
	# would naturally cap). The convex hull closes the bow with a
	# smooth fan.
	bm.verts.new(GV(0, p["y_offset"], half_l))


# U-keel parameter table per family. Used by Meridian (the mecha
# hulls use these proportions, slightly different from the original
# mecha params above for visual distinction).
U_KEEL_PARAMS = {
	"block":   {"belly_flat_w": 0.70, "chine_h": 0.30, "sponson_h": 0.55,
				"front_slope_l": 0.50, "rear_slope_l": 0.30, "roof_ratio": 0.75},
	"wedge":   {"belly_flat_w": 0.65, "chine_h": 0.30, "sponson_h": 0.50,
				"front_slope_l": 0.65, "rear_slope_l": 0.20, "roof_ratio": 0.72},
	"plate":   {"belly_flat_w": 0.78, "chine_h": 0.28, "sponson_h": 0.55,
				"front_slope_l": 0.35, "rear_slope_l": 0.25, "roof_ratio": 0.82},
	"pod":     {"belly_flat_w": 0.75, "chine_h": 0.32, "sponson_h": 0.60,
				"front_slope_l": 0.40, "rear_slope_l": 0.35, "roof_ratio": 0.78},
	"carrier": {"belly_flat_w": 0.70, "chine_h": 0.28, "sponson_h": 0.55,
				"front_slope_l": 0.55, "rear_slope_l": 0.45, "roof_ratio": 0.75},
	"skiff":   {"belly_flat_w": 0.55, "chine_h": 0.25, "sponson_h": 0.50,
				"front_slope_l": 0.80, "rear_slope_l": 0.30, "roof_ratio": 0.70},
}


# --- Manufacturer signature functions (add vertices to bm, no
#     convex_hull call yet - the assembly does ONE convex_hull over
#     the union of body + signature verts) ---

def _sig_meridian_carapace(bm, hx, hy, hz, family, tonnage):
	"""Meridian: carapace-style armored tank with PROMINENT turret cab,
	side rails, and front armor plate. The turret cab is the primary
	visual signature - a large box on top, scaled by tonnage.

	Adds vertices for:
	  - Rectangular top (the body's flat roof).
	  - Prominent turret cab: a large chamfered box centered on the
	    roof, size scaled by tonnage. This is the manufacturer's
	    primary signature - the hull reads as a tank.
	  - Front armored plate (main+heavy): a sloped plate at the
	    front, slightly protruding forward.
	  - Side rails (heavy only): two horizontal bars on each side,
	    between the body's mid-height and the turret. Reads as
	    external equipment racks.
	  - Vertical rib cage: N vertical beams on each side, count
	    scaled by tonnage. "Exposed structural frame" cue.
	"""
	# Rectangular top
	for p in [
		(-hx, hy, -hz), (hx, hy, -hz),
		(-hx, hy, hz), (hx, hy, hz),
	]:
		bm.verts.new(GV(*p))

	# PROMINENT turret cab - the manufacturer's primary signature.
	# Larger and more chamfered than a simple box. Size scales with
	# tonnage: scout=small, main=medium, heavy=large.
	cab_w = hx * {"scout": 0.35, "main": 0.42, "heavy": 0.48}[tonnage]
	cab_h = hy * {"scout": 0.55, "main": 0.65, "heavy": 0.75}[tonnage]
	cab_d = hz * {"scout": 0.25, "main": 0.30, "heavy": 0.35}[tonnage]
	cab_y_base = hy
	cab_y_top = hy + cab_h
	cab_inset = 0.15  # chamfer the top edges inward
	# 8 verts: 4 at base, 4 at top (inset)
	for p in [
		(-cab_w, cab_y_base, -cab_d), ( cab_w, cab_y_base, -cab_d),
		(-cab_w, cab_y_base,  cab_d), ( cab_w, cab_y_base,  cab_d),
		(-cab_w * (1 - cab_inset), cab_y_top, -cab_d * (1 - cab_inset)),
		( cab_w * (1 - cab_inset), cab_y_top, -cab_d * (1 - cab_inset)),
		(-cab_w * (1 - cab_inset), cab_y_top,  cab_d * (1 - cab_inset)),
		( cab_w * (1 - cab_inset), cab_y_top,  cab_d * (1 - cab_inset)),
	]:
		bm.verts.new(GV(*p))

	# Front armored plate (main+heavy) - sloped applique armor.
	if tonnage in ("main", "heavy"):
		plate_w = hx * 0.65
		plate_h = hy * 0.75
		plate_z = -hz * 1.02
		for p in [
			(-plate_w, -plate_h * 0.5, plate_z),
			( plate_w, -plate_h * 0.5, plate_z),
			(-plate_w,  plate_h * 0.5, plate_z),
			( plate_w,  plate_h * 0.5, plate_z),
			(0, plate_h * 0.8, plate_z - 0.10),  # slight forward protrusion
		]:
			bm.verts.new(GV(*p))

	# Side rails (heavy only) - two horizontal bars on each side.
	if tonnage == "heavy":
		for side_sign in (-1, 1):
			rail_x = side_sign * hx * 1.03
			for z_frac in [-0.35, 0.35]:
				z = hz * z_frac
				rail_w = 0.07
				for p in [
					(rail_x, -hy * 0.2, z - rail_w),
					(rail_x, -hy * 0.2, z + rail_w),
					(rail_x,  hy * 0.5, z - rail_w),
					(rail_x,  hy * 0.5, z + rail_w),
				]:
					bm.verts.new(GV(*p))

	# Vertical rib cage on each side (smaller detail, on top of the
	# prominent greebles above). N vertical beams scaled by tonnage.
	rib_count = {"scout": 3, "main": 5, "heavy": 7}.get(tonnage, 5)
	rib_w = 0.06
	rib_inset = 0.02
	for side_sign in (-1, 1):
		rib_x_outer = side_sign * hx * (1.0 + rib_inset)
		for i in range(rib_count):
			z = -hz + (i + 0.5) * (2 * hz / rib_count)
			for p in [
				(rib_x_outer, -hy * 0.98, z - rib_w),
				(rib_x_outer, -hy * 0.98, z + rib_w),
				(rib_x_outer,  hy * 0.98, z - rib_w),
				(rib_x_outer,  hy * 0.98, z + rib_w),
			]:
				bm.verts.new(GV(*p))


def _sig_osterholm_hex(bm, hx, hy, hz, family, tonnage):
	"""Osterholm: faceted modular UFO with PROMINENT hex outline,
	central spine, antenna array, and side rails. The hex top is
	the manufacturer's primary signature - the hull reads as a
	faceted pod from above.

	Adds vertices for:
	  - 6 hex vertices at y=hy (the hull's top face). Stretched per
	    family per OSTERHOLM_HEX_SCALES - long-narrow for wedge,
	    wide-short for plate, roughly square for block/pod.
	  - Central spine (heavy only): a vertical fin rising from the
	    hex top, peaked. Reads as a dorsal antenna/sensor array.
	  - Antenna array (scout only): a thin triangular peak rising
	    from the hex top, off-center. Reads as a long-range sensor.
	  - Side rails (main+heavy): horizontal bars on each side.
	"""
	scale_x, scale_z = OSTERHOLM_HEX_SCALES[family]
	for i in range(6):
		angle = i * (2 * math.pi / 6) + math.pi / 6
		bm.verts.new(GV(
			math.cos(angle) * hx * scale_x,
			hy,
			math.sin(angle) * hz * scale_z,
		))

	# Central spine (heavy only) - a vertical fin on top of the hex.
	# Wide at the base, peaked at the top. This is the "command pod"
	# or "sensor mast" cue for the heaviest Osterholm hulls.
	if tonnage == "heavy":
		spine_w = hx * 0.10
		spine_h = hy * 0.55
		spine_d = hz * 0.55
		spine_y_base = hy
		spine_y_top = hy + spine_h
		for p in [
			(-spine_w, spine_y_base, -spine_d), (spine_w, spine_y_base, -spine_d),
			(-spine_w, spine_y_base,  spine_d), (spine_w, spine_y_base,  spine_d),
			(0, spine_y_top, 0),  # peak
		]:
			bm.verts.new(GV(*p))

	# Antenna array (scout only) - a thin triangular peak, off-center.
	# Reads as a long-range sensor or comm array.
	if tonnage == "scout":
		ant_w = hx * 0.04
		ant_h = hy * 0.85
		ant_d = hz * 0.04
		ant_y_base = hy
		ant_y_top = hy + ant_h
		ant_z_offset = hz * 0.3
		for p in [
			(-ant_w, ant_y_base, ant_z_offset - ant_d), (ant_w, ant_y_base, ant_z_offset - ant_d),
			(-ant_w, ant_y_base, ant_z_offset + ant_d), (ant_w, ant_y_base, ant_z_offset + ant_d),
			(0, ant_y_top, ant_z_offset),  # peak
		]:
			bm.verts.new(GV(*p))

	# Side rails (main+heavy) - horizontal bars on each side.
	if tonnage in ("main", "heavy"):
		for side_sign in (-1, 1):
			rail_x = side_sign * hx * 1.03
			for z_frac in [-0.35, 0.35]:
				z = hz * z_frac
				rail_w = 0.06
				for p in [
					(rail_x, -hy * 0.2, z - rail_w),
					(rail_x, -hy * 0.2, z + rail_w),
					(rail_x,  hy * 0.4, z - rail_w),
					(rail_x,  hy * 0.4, z + rail_w),
				]:
					bm.verts.new(GV(*p))


def _sig_tidemark_pressure_hull(bm, hx, hy, hz, family, tonnage):
	"""Tidemark: pressure-hull style with flat dorsal casing and
	central conning tower (frustum cab).

	Per the legacy pressure_hull description (prototype/tools/
	gen_kitbash_hulls.py:114): "Submarine pressure hull, run on land
	because nothing here is underwater. The dorsal casing is not
	decoration: a bare cylinder has almost no flat area for module
	mounts, and a real submarine's flat walking casing solves the
	realism and the mounting problem with the same part."

	Adds vertices for:
	  - Rectangular top (4 corners at y=hy) - the hull's roof.
	  - Dorsal casing: a flat-topped box on top of the hull,
	    narrower than the hull's roof (gives the "walking deck"
	    silhouette). Sits between y=hy and y=hy+0.15*sy.
	  - Conning tower: a 6-sided frustum (truncated cone) on top
	    of the dorsal casing, central. This is the Tidemark
	    signature's most distinctive read - the frustum cab.
	  - Heavy: a second, smaller conning tower on top of the first.
	"""
	# Rectangular top
	for p in [
		(-hx, hy, -hz), (hx, hy, -hz),
		(-hx, hy, hz), (hx, hy, hz),
	]:
		bm.verts.new(GV(*p))

	# Dorsal casing: a flat-topped box on top of the hull.
	casing_h = hy * 0.15
	for p in [
		(-hx * 0.8, hy, -hz * 0.8), (hx * 0.8, hy, -hz * 0.8),
		(-hx * 0.8, hy, hz * 0.8), (hx * 0.8, hy, hz * 0.8),
		(-hx * 0.7, hy + casing_h, -hz * 0.7), (hx * 0.7, hy + casing_h, -hz * 0.7),
		(-hx * 0.7, hy + casing_h, hz * 0.7), (hx * 0.7, hy + casing_h, hz * 0.7),
	]:
		bm.verts.new(GV(*p))

	# Conning tower: 6-sided frustum on top of the dorsal casing.
	cab_r_base = hx * 0.35
	cab_r_top = hx * 0.22
	cab_h = hy * 0.45
	cab_y_base = hy + casing_h
	sides = 6
	for i in range(sides):
		angle = i * (2 * math.pi / sides)
		bm.verts.new(GV(
			math.cos(angle) * cab_r_base, cab_y_base,
			math.sin(angle) * cab_r_base,
		))
	for i in range(sides):
		angle = i * (2 * math.pi / sides)
		bm.verts.new(GV(
			math.cos(angle) * cab_r_top, cab_y_base + cab_h,
			math.sin(angle) * cab_r_top,
		))

	# Heavy: second smaller conning tower on top of the first,
	# offset (rotated 30 degrees) so the two cabs read as a
	# deliberate stack rather than a single tall one.
	if tonnage == "heavy":
		cab2_r_base = cab_r_top * 0.7
		cab2_r_top = cab_r_top * 0.45
		cab2_h = hy * 0.28
		cab2_y_base = cab_y_base + cab_h
		for i in range(sides):
			angle = i * (2 * math.pi / sides) + math.pi / sides
			bm.verts.new(GV(
				math.cos(angle) * cab2_r_base, cab2_y_base,
				math.sin(angle) * cab2_r_base,
			))
		for i in range(sides):
			angle = i * (2 * math.pi / sides) + math.pi / sides
			bm.verts.new(GV(
				math.cos(angle) * cab2_r_top, cab2_y_base + cab2_h,
				math.sin(angle) * cab2_r_top,
			))

	# Propeller (carrier only) - a 6-blade spinner on the rear face,
	# central. Reads as the "screw" of a maritime transport. The
	# spinner is a flat hex in the Y=0 plane (centered vertically),
	# with a short shaft connecting it to the rear of the hull.
	if family == "carrier":
		prop_r = hx * 0.35
		prop_y = 0.0
		prop_z = hz * 1.02
		for i in range(6):
			angle = i * (2 * math.pi / 6)
			bm.verts.new(GV(
				math.cos(angle) * prop_r,
				prop_y,
				prop_z + math.sin(angle) * prop_r * 0.3,
			))
		# Shaft (a short box connecting the spinner to the hull)
		shaft_w = hx * 0.12
		shaft_h = hy * 0.12
		for p in [
			(-shaft_w, -shaft_h * 0.5, hz * 0.95),
			( shaft_w, -shaft_h * 0.5, hz * 0.95),
			(-shaft_w,  shaft_h * 0.5, hz * 0.95),
			( shaft_w,  shaft_h * 0.5, hz * 0.95),
		]:
			bm.verts.new(GV(*p))


# --- Assembly: manufacturer body + manufacturer signature + bevel ---
#
# PR-2 redo v4 (2026-08-12): The family shape functions (6 _shape_*
# functions) are GONE. Each manufacturer owns its own body builder
# (Meridian=u-keel, Osterholm=hex prism, Tidemark=cylindrical
# pressure hull). The "family" axis is now purely a sizing/role
# axis (block=armored, wedge=front-line, plate=transporter,
# pod=tall+square, carrier=long+wide, skiff=naval) and does NOT
# define the body silhouette. Per Chris's 2026-08-12 feedback:
# "Don't re-use the v hull, build separate, unrelated basics per
# manufacturer. Again, as if the different manufacturers used
# entirely different design philosophies."
#
# The three body philosophies are deliberately unrelated:
#   - Meridian (u-keel):    tank-like, sloped side sponsons, flat
#                            belly, sloped front glacis. Imported
#                            wholesale from mecha_legs_project
#                            (procedural fallback for dev/testing
#                            only; production Meridian hulls come
#                            from the import pipeline, not this
#                            procedural path).
#   - Osterholm (hex prism): faceted modular pod, hex outline when
#                            viewed from above, no sponsons, no
#                            chine. Stretched per family for
#                            plan-view silhouette (long-narrow for
#                            wedge, wide-short for plate).
#   - Tidemark (cylindrical): smooth submarine/boat pressure hull,
#                            circular cross-section, pointed bow,
#                            flat stern. No sponsons, no flat
#                            sides - the opposite of a tank.
#
# The signature axis (3 _sig_* functions) adds the manufacturer's
# "second-tier" structural element on top of the body: Meridian
# carapace (turret cab + front plate + side rails + ribs),
# Osterholm hexapod (central spine + antenna + rails), Tidemark
# pressure hull (conning tower + propeller).

BODY_BUILDERS = {
	"meridian":  _u_keel_body,
	"osterholm": _hex_body,
	"tidemark":  _cyl_body,
}

SIG_BUILDERS = {
	"meridian":  _sig_meridian_carapace,
	"osterholm": _sig_osterholm_hex,
	"tidemark":  _sig_tidemark_pressure_hull,
}

# Family size table (size_x, size_y, size_z) per tonnage. Kept at module
# level so _build_hull() and generate_hulls() both see the same values.
# Block family uses a 4:1:6 (W:H:L) ratio at main tonnage; plate uses a
# wider 5:1.3:7 slab; pod is roughly square in plan but tall; carrier
# is wider in plan and taller; wedge is the classic long-tapering
# 3.5:0.8:5 profile; skiff is a low naval hull.
SIZES = {
	"block":   {"scout": (2.4, 0.8, 3.2), "main": (4.0, 1.0, 6.0), "heavy": (6.0, 1.5, 8.0)},
	"wedge":   {"scout": (2.0, 0.6, 3.0), "main": (3.5, 0.8, 5.0), "heavy": (5.0, 1.2, 7.0)},
	"plate":   {"scout": (3.5, 1.0, 4.5), "main": (5.0, 1.3, 7.0), "heavy": (7.0, 1.8, 9.0)},
	"pod":     {"scout": (2.5, 2.0, 3.0), "main": (3.5, 2.5, 4.5), "heavy": (5.0, 3.0, 6.0)},
	"carrier": {"scout": (2.8, 1.2, 4.5), "main": (4.5, 1.6, 7.0), "heavy": (6.0, 2.0, 9.0)},
	"skiff":   {"scout": (2.0, 0.8, 4.0), "main": (3.0, 1.0, 6.0), "heavy": (4.5, 1.3, 8.0)},
}

# Manufacturer base colors. These are the GLB-level paint - the
# in-game faction shader overrides them with the per-faction colors.
# The color is the second-tier manufacturer differentiator (the first
# is the structural signature element from _sig_*).
MANUFACTURER_COLORS = {
	"meridian":  (0.5, 0.5, 0.52),     # gunmetal grey
	"osterholm": (0.85, 0.88, 0.92),   # pearlescent white
	"tidemark":  (0.78, 0.65, 0.45),    # sandstone tan
}

# Curated manufacturer lineups (PR-2 redo v4, 2026-08-12).
#
# Per Chris's followup: "There shouldn't be manufacturer variants of the
# same hull. There should be manufacturer hulls, that happen to line up
# roughly on size. Like, there could be three Osterholm heavy tank
# designs, but no transports at all, while Tidemark could have a
# transport in every weight class and no heavy armor at all."
#
# Per Chris's 2026-08-12 followup: "Don't re-use the v hull, build
# separate, unrelated basics per manufacturer. Again, as if the
# different manufacturers used entirely different design philosophies."
#
# PR-2 redo v4 split: Meridian now uses the mecha_legs_project hulls
# wholesale (8 hand-authored u-keel hulls, imported in PR 2 v3). The
# procedural pipeline only generates Osterholm (hex prism bodies) +
# Tidemark (cylindrical pressure hull bodies). 22 procedural hulls
# total, 8 mecha hulls imported, 30 total in the catalogue.
#
# Per-manufacturer philosophy:
#   Meridian  - u-keel (sloped side sponsons, flat belly, sloped
#                front glacis and rear deck). Imported wholesale from
#                mecha_legs_project as 8 distinct hulls that
#                already have detailed turrets, fenders, and hull
#                features that the procedural pipeline can't easily
#                match.
#   Osterholm - hex-prism modular construction (faceted hex outline
#                from above, no sponsons). The multi-purpose
#                generalist. Fills block + wedge + plate + pod
#                across all 3 tonnages. The "3 Osterholm heavy tank
#                designs" = block_heavy + wedge_heavy + plate_heavy.
#   Tidemark  - cylindrical pressure-hull maritime style (smooth
#                tube, pointed bow, flat stern). The transport
#                specialist. Fills carrier + skiff across all 3
#                tonnages, plus block + pod in scout+main for
#                general utility.
LINEUP = {
	# Meridian is populated from mecha_legs_project by
	# scratch/probe_axes/_import_mecha_hulls.py, not from the
	# procedural pipeline. The 8 mecha hulls map to the 8 cells
	# below (verified in PR 2 v3). generate_hulls() skips meridian
	# entries and just verifies the mecha hulls are in place.
	"osterholm": [
		("block", "scout"),
		("block", "main"),
		("block", "heavy"),    # 1 of 3 heavy tank designs
		("wedge", "scout"),
		("wedge", "main"),
		("wedge", "heavy"),    # 2 of 3 heavy tank designs
		("plate", "scout"),
		("plate", "main"),
		("plate", "heavy"),    # 3 of 3 heavy tank designs
		("pod", "scout"),
		("pod", "main"),
		("pod", "heavy"),
	],
	"tidemark": [
		("block", "scout"),
		("block", "main"),
		("pod", "scout"),
		("pod", "main"),
		("carrier", "scout"),
		("carrier", "main"),
		("carrier", "heavy"),
		("skiff", "scout"),
		("skiff", "main"),
		("skiff", "heavy"),
	],
}


def _build_hull(name, family, tonnage, manufacturer, color):
	"""Build one hull: manufacturer body + manufacturer signature + bevel.

	PR-2 redo v4 (2026-08-12): the "family" axis no longer defines
	the body silhouette. Each manufacturer owns its own body
	philosophy (Meridian=u-keel, Osterholm=hex prism, Tidemark=
	cylindrical). The family just sets the SIZES dict lookup and
	scales the signature (number of ribs, cab size, hex stretch,
	cylinder taper, etc.).

	The 3 axes combine as:
	  - family:    the size/role (block=armored, wedge=front-line,
	               plate=transporter, pod=tall+square, carrier=long,
	               skiff=naval) and signature density
	  - manufacturer: the BODY philosophy (u-keel / hex / cylinder)
	                + the structural element on top (carapace /
	                hexapod / pressure hull)
	  - tonnage:   scales the body dimensions and adjusts signature
	               density (rib count, cab height, second cab on
	               heavy, antenna length on scout)

	Returns a fully-finalized obj ready for GLB export.

	Convex hull: ONE call on the union of all vertices (body +
	signature). Multiple separate convex_hull calls per "volume"
	would create DISJOINT convex regions in the same bm. The
	fix is to add all vertices first, then compute the convex
	hull once over the union.
	"""
	sx, sy, sz = SIZES[family][tonnage]
	hx, hy, hz = sx / 2.0, sy / 2.0, sz / 2.0
	R = hull_reference_dim(sx, sy)

	bm = bmesh.new()

	# 1. Manufacturer-owned body. The body IS the silhouette -
	#    Meridian's u-keel reads as a tank, Osterholm's hex prism
	#    reads as a faceted modular pod, Tidemark's cylinder reads
	#    as a submarine pressure hull. The function adds verts only;
	#    the convex hull below closes and merges.
	#
	# Body builders take (length, width, height) in the convention
	# of the bmesh: Z = length, X = width, Y = height. SIZES is
	# (sx, sy, sz) = (width, height, length), so the call reorders.
	BODY_BUILDERS[manufacturer](bm, sz, sx, sy, family, tonnage)

	# 2. Manufacturer signature: adds the "second-tier" structural
	#    element on top of the body (turret cab, hex spine, conning
	#    tower, propeller, etc.). Also adds verts only.
	SIG_BUILDERS[manufacturer](bm, hx, hy, hz, family, tonnage)

	# 3. ONE convex hull over all vertices. This closes the body
	#    and smoothly merges the signature elements into the
	#    silhouette. Calling convex_hull separately per "volume"
	#    would leave disjoint pieces of geometry.
	bmesh.ops.convex_hull(bm, input=list(bm.verts), use_existing_faces=False)

	# 4. Final bevel: tier-1 with 2 segments at 12% (chunky chamfer
	#    base), tier-2 with 1 segment at 6% (small finishing chamfer).
	#    Per Chris's 2026-08-11 feedback: "crisp and smooth, with
	#    chamfered edges to avoid looking cheap and overly sharp" -
	#    wider chamfer reads as a deliberate edge treatment, not an
	#    inset.
	#
	#    Note: single-segment (segments=1) bevels collapse the bow
	#    point of cylinders / pods (z contracts from 3.0 to ~1.7 -
	#    the bow fan of triangles gets pulled in to a single point
	#    and the offset verts overshoot). 2 segments keeps the bow
	#    geometry stable.
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=0.12, segments=2)
	bevel_sharp_edges(bm, list(bm.verts), R, tier=2, pct=0.06, segments=1)

	# 5. Per-hull orientation fix. The glTF export applies a 180Â°
	#    rotation about the (1, 0, 1) axis (empirically verified),
	#    so the bmesh needs to be pre-rotated by an equal-and-opposite
	#    rotation for the hull to land in Godot convention (X=width,
	#    Y=up, Z=-length) in the final glTF.
	#
	#    T(a, b, c) = (b, -c, a): swaps X/Y, negates Z. After the
	#    export applies M, the result lands on Godot X/Y/Z without
	#    affecting the parts (which were already in the correct glTF
	#    orientation and don't have this rotation applied because
	#    they're built outside _build_hull).
	#
	#    NOTE: For procedural hulls, direct vert assignment
	#    v.co = mathutils.Vector((y, -z, x)) would be more reliable
	#    than bmesh.ops.rotate (which has had column/row-vector
	#    ambiguity issues in past iterations). The matrix form here
	#    is verified to give the same final AABB as direct assignment
	#    on the same input.
	_hull_orient_matrix = mathutils.Matrix(((0, 1, 0), (0, 0, -1), (1, 0, 0)))
	bmesh.ops.rotate(bm, verts=list(bm.verts), cent=(0, 0, 0), matrix=_hull_orient_matrix)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color,
		armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_bunker_hull(name, size_x, size_y, size_z, sides=8, taper=0.72,
		color=(0.45, 0.45, 0.4), greebles=None, embrasure=None, armor_threshold=0.2):
	"""Low static defensive bunker: tapered polygonal frustum + domed cap.
	The taper itself (top narrower than base) already gives the battered/
	inward-sloping wall read the design doc asks for - no new geometry
	needed there, just a bevel.

	embrasure: optional dict {"center":(x,y,z), "size":(w,h), "depth_frac":f}
	  - a real recessed, splayed firing slit (add_recessed_embrasure)
	  carved into the front wall before the bevel pass, replacing a proud
	  greeble_vent box."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()
	base_r = max(hx, hz)
	top_r = base_r * taper
	base_pts = []
	top_pts = []
	for i in range(sides):
		angle = i * (2.0 * math.pi / sides)
		base_pts.append((math.cos(angle) * base_r * (hx / base_r), -hy, math.sin(angle) * base_r * (hz / base_r)))
		top_pts.append((math.cos(angle) * top_r * (hx / base_r), hy * 0.7, math.sin(angle) * top_r * (hz / base_r)))
	all_pts = base_pts + top_pts
	verts = [bm.verts.new(GV(*p)) for p in all_pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	if embrasure:
		add_recessed_embrasure(bm, embrasure["center"], embrasure["size"], R,
			depth_frac=embrasure.get("depth_frac", 0.06), wall_gate=hz * 0.15)

	# Heavier, low-segment-count bevel - reads as blocky cast concrete
	# rather than the "milled/cast metal" facet count used on vehicle
	# hulls. Runs on the CURRENT vert set (not just the original
	# silhouette list) so it also smooths the embrasure cut's own edges.
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=0.09, segments=1)

	# Hard-armor region: the embrasure-facing wall (Godot +Z, where the
	# firing slit itself sits, per the embrasure dict's own "center" Z
	# coordinate convention every caller uses) plus its immediate
	# neighboring facets - unlike a vehicle's frontal glacis or a flat
	# defensive wall, an octagonal frustum has no single dominant "front"
	# facet, so a looser threshold catches the 2-3 facets nearest +Z
	# instead of just one, reading as a real reinforced firing position
	# rather than a single oddly-isolated armored panel. Called before the
	# roof dome so the cap stays structural (real bunker domes are cast
	# concrete, not applied armor plate).
	armor_frac = mark_armor_faces(bm, outward_face_predicate(threshold=armor_threshold))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Domed roof cap
	dome_verts = bmesh.ops.create_uvsphere(bm, u_segments=sides, v_segments=6, radius=top_r * 0.9)['verts']
	bmesh.ops.scale(bm, verts=dome_verts, vec=GS(1.0, 0.45, 1.0))
	bmesh.ops.translate(bm, verts=dome_verts, vec=GV(0, hy * 0.7, 0))

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_wall_hull(name, size_x, size_y, size_z, merlons=5, color=(0.42, 0.4, 0.36), greebles=None,
		arrow_slit_count=0, armor_threshold=0.4):
	"""Long, low defensive rampart: a battered (wider-at-base) wall face
	topped with alternating battlement merlons - a wall segment, not a
	bunker or tower, meant to read as long and thin rather than squat.

	arrow_slit_count: carves this many real recessed, splayed arrow slits
	  (add_recessed_embrasure, shared with bunker_main_meridian) into the
	  +Z wall face before the bevel, replacing what used to be proud
	  add_box slits in the greebles callback. Positions stay well clear
	  of the +/-X end caps (see the bevel's own preserve_axis=0 comment
	  below) - end-cap tiling must not be touched by any new feature."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()

	base_pts = [
		(-hx * 1.05, -hy, -hz * 1.1), (hx * 1.05, -hy, -hz * 1.1),
		(-hx * 1.05, -hy, hz * 1.1), (hx * 1.05, -hy, hz * 1.1),
		(-hx, hy * 0.55, -hz), (hx, hy * 0.55, -hz),
		(-hx, hy * 0.55, hz), (hx, hy * 0.55, hz),
	]
	verts = [bm.verts.new(GV(*p)) for p in base_pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	if arrow_slit_count > 0:
		# All slits share the same height band, so add_recessed_embrasure_row
		# (not N separate add_recessed_embrasure calls) - re-bisecting an
		# identical height plane once per slit was found, via direct bmesh
		# inspection, to produce hundreds of degenerate zero-area faces.
		slit_xs = [((i + 0.5) / arrow_slit_count - 0.5) * hx * 1.7 for i in range(arrow_slit_count)]
		add_recessed_embrasure_row(bm, slit_xs, hy * 0.05, (R * 0.08, hy * 0.45), R,
			depth_frac=0.05, wall_gate=0.0)

	# Bevel the batter/top transition, but preserve_axis=0 keeps the two
	# flat end-cap faces (raw Blender +/-X, this wall's long axis) fully
	# untouched - those cross-sections must stay identical and flat so
	# adjacent wall segments still tile edge-to-edge with no visible seam.
	# Runs on the CURRENT vert set so it also smooths the arrow slits'
	# own cut edges (the slit positions are already well clear of the
	# preserved end caps, so this doesn't risk the tiling guarantee).
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=0.06, preserve_axis=0)

	# Hard-armor region: the outward (Godot +Z, arrow-slit-bearing) wall
	# face - the side facing attackers, vs. the sheltered inward face/top/
	# end-caps staying structural masonry. Called before the merlons so the
	# battlements read as lighter capstone atop the hardened wall face, not
	# armor plate themselves.
	armor_frac = mark_armor_faces(bm, outward_face_predicate(threshold=armor_threshold))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Battlements: alternating merlon teeth along the top edge, evenly
	# spaced with gaps (crenels) between them for the classic wall silhouette.
	# Bespoke Tier 3 detail: each merlon is built as two flanking half-
	# blocks with a narrow gap between them (a real arrow slit) instead of
	# one solid box - built as two separate primitives, not a boolean cut,
	# matching this file's established no-boolean convention (see
	# add_waist_inset's own comment on why booleans were ruled out).
	merlon_w = (size_x * 0.94) / (merlons * 2 - 1)
	slit_w = merlon_w * 0.16
	half_w = (merlon_w * 0.9 - slit_w) / 2.0
	for i in range(merlons):
		mx = -hx * 0.94 + merlon_w * (2 * i + 0.5)
		for side in (-1, 1):
			add_box(bm, (mx + side * (half_w + slit_w) / 2.0, hy * 0.55 + hy * 0.24, 0),
				(half_w, hy * 0.24, hz * 0.8), bevel=0.02)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_ship_hull(name, size_x, size_y, size_z, bow_frac=0.35, color=(0.35, 0.38, 0.4), greebles=None,
		deadrise=0.3, sheer=0.1, flare=0.0, stations=9, bevel_pct=None, bevel_segments=None,
		superstructure_tiers=1, forecastle=False, quarterdeck=False, armor_front_frac=0.55):
	"""Naval hull: pointed bow, flat transom stern, a real V-shaped deadrise
	cross-section (via a per-station loft, not a boolean cut), sheer
	(deck line rising toward the bow), optional topside flare above the
	waterline, and a raised bridge superstructure.

	deadrise: keel drop as a fraction of local beam (0=flat-bottomed,
	  higher=sharper V) - small_boat wants this highest, heavy_cruiser
	  lowest.
	sheer: how much the deck rises toward the bow (0=dead flat deck).
	flare: extra outward bell above the main deck edge, above the
	  waterline - heavy_cruiser's "pronounced outward flare."
	Both the bow taper and sheer reuse taper_profile()'s eased nose-
	aggressive curve (bow = "nose" in the wedge-hull sense) so the entry
	curves rather than kinking at a single hard bow cross-section.

	superstructure_tiers: stacks this many fused boxes (technique #1) of
	  decreasing footprint above the deck instead of one flat bridge block -
	  foredeck house -> bridge -> open bridge, generalizing what used to be
	  a single "bridge box glued onto the hull". 1 (default) reproduces the
	  old single-box bridge exactly.
	forecastle: adds a short raised-foredeck box near the bow (the classic
	  freeboard step).
	quarterdeck: adds a lower stern deck step for a layered-deck read."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()

	pts = []
	for i in range(stations):
		t = i / float(stations - 1)
		z = -hz + t * size_z
		beam_scale = taper_profile(t, bow_frac, 0.04, 1.0, nose_region=max(bow_frac, 0.3))
		sheer_scale = taper_profile(t, 0.0, 1.0 + sheer, 1.0, nose_region=max(bow_frac, 0.3))
		beam = hx * beam_scale
		deck_y = hy * sheer_scale
		keel_y = deck_y - beam * deadrise if beam > 0.001 else deck_y
		pts.append((-beam, deck_y, z))
		pts.append((beam, deck_y, z))
		pts.append((0.0, keel_y, z))
		# Gated on beam_scale (not just beam > 0.001): the flare's elevation
		# offset is a FIXED hy*0.15, not scaled with local beam, so adding
		# it right at the pointed bow tip (where beam is tiny but nonzero)
		# created a wildly disproportionate spike - a real bug caught by
		# actually re-verifying screenshots after fixing the Godot import
		# cache issue (see DECISIONS_NEEDED.md). Only flare past the
		# steepest part of the bow taper, where the hull has real beam.
		if flare > 0.0 and beam_scale > 0.5:
			flare_beam = beam * (1.0 + flare)
			flare_y = deck_y + hy * 0.15
			pts.append((-flare_beam, flare_y, z))
			pts.append((flare_beam, flare_y, z))

	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	bevel_sharp_edges(bm, verts, R, tier=1, pct=bevel_pct, segments=bevel_segments)

	# Hard-armor region: the bow belt - a real warship's most exposed
	# ramming/torpedo-arc surface, and (per the same reasoning as the AFV
	# hulls' frontal glacis) naturally a minority of total hull area for
	# an elongated hull. Excludes the keel/bottom (never visible, a
	# wasted area cost). Called BEFORE the bridge/forecastle/quarterdeck
	# additions so those stay structural deck fixtures, not armor plate -
	# a bridge superstructure isn't armor on a real ship either.
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Bridge superstructure, offset toward the stern - a stack of
	# `superstructure_tiers` fused boxes of decreasing footprint
	# (technique #1, same as build_tower_hull's per-tier hulls), each
	# overlapping the one below it so they read as fused rather than
	# floating. tiers=1 reproduces the old single-box bridge exactly.
	tier_y, tier_hy, tier_hx, tier_hz = hy * 1.3, hy * 0.35, hx * 0.42, hz * 0.26
	for _tier_i in range(superstructure_tiers):
		add_box(bm, (0, tier_y, hz * 0.35), (tier_hx, tier_hy, tier_hz), bevel=0.03)
		tier_y += tier_hy * 1.6
		tier_hx *= 0.78
		tier_hy *= 0.85
		tier_hz *= 0.78

	if forecastle:
		add_box(bm, (0, hy * (1.0 + sheer * 0.6), -hz * 0.62), (hx * 0.7, hy * 0.16, hz * 0.16), bevel=0.02)
	if quarterdeck:
		add_box(bm, (0, -hy * 0.15, hz * 0.72), (hx * 0.9, hy * 0.18, hz * 0.22), bevel=0.02)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_flying_wing_hull(name, size_x, size_y, size_z, sweep=0.55, color=(0.5, 0.52, 0.56), greebles=None,
		bevel_pct=0.085, bevel_segments=2, armor_front_frac=0.4):
	"""Blended-wing-body hull: a swept flying-wing planform with no
	distinct fuselage/wing break - a shallow dorsal blend ridge instead of
	the wedge hulls' raised spine, cockpit and body smoothly faired into
	the wing rather than sitting on top of it. The leading-edge thinning
	taper the design doc asks for is already structurally implicit here -
	the dorsal blend shoulders sit at +/-0.4*hx, short of the full-span
	wingtips at +/-hx, so the convex hull already tapers the wing's own
	thickness down to a single point at the tips rather than a constant-
	thickness slab. Tier 1's own lever is the bevel - wide/max-segment,
	per the doc's explicit call for the wing-root-to-body junction."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()

	pts = [
		(0.0, -hy * 0.3, -hz),                                    # nose apex
		(-hx, -hy * 0.3, hz * sweep), (hx, -hy * 0.3, hz * sweep),  # wingtips, swept back
		(-hx * 0.45, -hy * 0.3, hz), (hx * 0.45, -hy * 0.3, hz),    # trailing edge corners
		(0.0, hy, -hz * 0.35),                                     # dorsal blend apex near nose
		(-hx * 0.4, hy * 0.75, hz * 0.25), (hx * 0.4, hy * 0.75, hz * 0.25),  # blend shoulders
		(0.0, hy * 0.45, hz * 0.85),                               # tail blend fade-out
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# Spanwise panel-line grooves (spars/ribs) - the axis='x' variant of
	# the shared groove helper (add_panel_line_groove normally cuts
	# chordwise bands across a fuselage's length; here the cut runs along
	# the span instead), two symmetric ribs per wing. Applied before the
	# bevel so the tiered bevel still smooths the cut's own edges, same
	# ordering every other hull's bisect+shift details use.
	for x_frac in (0.3, 0.4, 0.6, 0.7):
		add_panel_line_groove(bm, hx, hy, hz, R, x_frac, axis='x')

	# Bevel on the CURRENT vert set (not the original silhouette-only
	# list) so it picks up the groove cuts' own new edges too - same
	# reasoning as build_afv_hull's bevel call.
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=bevel_pct, segments=bevel_segments)

	# Hard-armor region: the nose apex and leading-edge region - same
	# frontal-arc reasoning as every other vehicle hull.
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_sponson_hull(name, size_x, size_y, size_z, sponson_bulge=1.3, sponson_span=0.4,
		sponson_height=0.65, color=(0.38, 0.36, 0.32), greebles=None):
	"""Ground hull with built-in sponson stubs baked directly into the
	silhouette: a slab-sided tapered core hull with two distinct box-like
	sponson blisters fused onto the sides at a mid-body band, protruding
	past the core's flat sides - a real stepped stub, not just a smooth
	taper - rather than sponsons being separately-applied mount hardware."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	bm = bmesh.new()
	core_x = hx * 0.78

	pts = [
		(-core_x, -hy, -hz), (core_x, -hy, -hz), (-core_x, -hy, hz), (core_x, -hy, hz),
		(-core_x * 0.85, hy, -hz * 0.9), (core_x * 0.85, hy, -hz * 0.9),
		(-core_x * 0.85, hy, hz * 0.9), (core_x * 0.85, hy, hz * 0.9),
	]
	verts = [bm.verts.new(GV(*p)) for p in pts]
	bmesh.ops.convex_hull(bm, input=verts)
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	sp_z = hz * sponson_span
	sp_x = hx * sponson_bulge
	sp_reach = sp_x - core_x
	for side in (-1, 1):
		add_box(bm, (side * (core_x + sp_reach * 0.5), -hy * (1.0 - sponson_height * 0.5), 0),
			(sp_reach, hy * sponson_height, sp_z * 2.0), bevel=0.04)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.55, roughness=0.5)
	return obj


def build_fuselage_hull(name, size_x, size_y, size_z, nose_frac=0.16, tail_frac=0.24,
		wing_span_frac=1.0, wing_chord_frac=0.3, wing_pos_frac=0.05,
		color=(0.6, 0.6, 0.62), greebles=None, bevel_pct=None, bevel_segments=None, armor_front_frac=0.45):
	"""Traditional plane: a slender tapered fuselage tube along Z (nose cone
	forward, tail taper aft) with a separate flat wing slab crossing at
	mid-body and tail control surfaces - a genuine fuselage/wing break,
	unlike flying_wing_hull's single blended-wing-body convex hull with no
	distinct fuselage at all."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	body_r = min(hx, hy) * 0.62
	bm = bmesh.new()

	nose_len = size_z * nose_frac
	tail_len = size_z * tail_frac
	body_len = size_z - nose_len - tail_len
	nose_z0 = -hz
	body_z0 = nose_z0 + nose_len
	tail_z0 = body_z0 + body_len

	body_verts = add_cyl_axis(bm, (0, 0, body_z0 + body_len / 2.0), body_r, body_len, 'z', segments=14)
	nose_verts = add_cyl_axis(bm, (0, 0, nose_z0 + nose_len / 2.0), 0.02, nose_len, 'z', segments=14, radius2=body_r)
	tail_verts = add_cyl_axis(bm, (0, 0, tail_z0 + tail_len / 2.0), body_r, tail_len, 'z', segments=14, radius2=body_r * 0.22)

	# The nose/body/tail cone segments are built as separate primitives
	# whose end-caps coincide in space but aren't topologically joined -
	# weld the coincident ring verts into one continuous mesh first, so
	# there's a real shared edge at each join for the tiered bevel to
	# smooth (previously masked only by shade_smooth, not real geometry).
	fuselage_verts = body_verts + nose_verts + tail_verts
	bmesh.ops.remove_doubles(bm, verts=fuselage_verts, dist=0.001)
	fuselage_verts = list(bm.verts)
	bevel_sharp_edges(bm, fuselage_verts, R, tier=1, pct=bevel_pct, segments=bevel_segments)

	# Hard-armor region: nose cone + forward body tube - real warplanes
	# armor the engine/pilot compartment up front, same "frontal arc"
	# reasoning as every other vehicle hull. Called before wings/fairings/
	# formers/tail so those stay lightweight structural skin, not armor.
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Wings: a flat slab crossing the body near mid-fuselage - the defining
	# "attached wing" break this hull exists to demonstrate.
	wing_z = -hz * wing_pos_frac
	add_box(bm, (0, 0, wing_z), (size_x * wing_span_frac, hy * 0.16, size_z * wing_chord_frac), bevel=0.03)

	# Wing-root fairing: today the wing slab crosses the tube with a hard
	# intersection - a small fused fillet block at each root (technique
	# #1, no boolean) bridges the tube's own surface into the wing root
	# so the join reads as engineered rather than two shapes clipping.
	for side in (-1, 1):
		add_box(bm, (side * body_r * 0.85, -hy * 0.08, wing_z),
			(body_r * 0.4, hy * 0.14, size_z * wing_chord_frac * 0.55), bevel=0.03)

	# Circumferential formers/ribs along the body tube - same thin-ring
	# technique the airship envelope's own seam rings already use
	# (add_cyl_axis around the hull's long axis), just applied to the
	# fuselage tube instead of an ellipsoid envelope.
	for i in range(4):
		t = (i + 0.5) / 4.0
		add_cyl_axis(bm, (0, 0, body_z0 + t * body_len), body_r * 1.02, 0.02, 'z', segments=14)

	# Dorsal hardpoint pad: the tube's real top surface sits at body_r,
	# not at the AABB top facet (hy) - since body_r = min(hx,hy)*0.62 is
	# always well short of hy, a top-mounted pintle placed at the facet
	# would float above the round tube with a visible gap (the same class
	# of bug the naval/airship hulls hit with underside mounts). A flat
	# raised pad bridging body_r up toward hy gives a real mount surface
	# instead of needing a second, hull-specific mount-offset fix.
	add_box(bm, (0, (body_r + hy * 0.95) * 0.5, 0),
		(body_r * 0.5, (hy * 0.95 - body_r) * 0.5, size_z * 0.12), bevel=0.02)

	# Tail control surfaces: vertical fin + horizontal tailplane
	add_box(bm, (0, hy * 0.5, tail_z0 + tail_len * 0.55), (0.05, hy * 0.85, size_z * 0.1), bevel=0.02)
	add_box(bm, (0, 0, tail_z0 + tail_len * 0.5), (size_x * 0.55, hy * 0.1, size_z * 0.09), bevel=0.02)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_airship_hull(name, size_x, size_y, size_z, tail_taper=0.35,
		color=(0.72, 0.7, 0.6), greebles=None, armor_front_frac=0.45):
	"""Rigid airship: a stretched teardrop/cigar gasbag envelope (blunt nose,
	tapered tail) with a gondola slung underneath on struts and a 4-way tail
	fin cross - the only hull silhouette in the roster implying buoyant lift
	rather than an engine actively fighting gravity (see buoyant_envelope's
	own catalog comment in module_catalog.gd for the gameplay consequence).

	Tier 3 bespoke feature: the envelope's cross-section (u_segments=8,
	down from a smooth-ellipsoid 18) is now genuinely faceted rather than
	a round curve - a real rigid-frame airship's skin is paneled over a
	polygonal girder frame, not a perfect balloon. 8 facets puts the
	dihedral angle between adjacent panels at 45 degrees, safely above
	finalize()'s 35-degree auto-smooth threshold, so the facets read as
	real flat panels instead of being smoothed back into a curve;
	v_segments (lengthwise rings) stays high so the teardrop taper along
	the length still reads smooth - only the AROUND-the-tube cross-section
	is faceted. This is a genuine topology change, not a bevel/taper
	tuning one, which is why it sat apart from the rest of the shared
	tiered-bevel work as its own separate Tier 3 item."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	gon_bevel, _ = tiered_bevel_width(R, tier=2)
	fin_bevel, _ = tiered_bevel_width(R, tier=3)
	bm = bmesh.new()

	ret = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=12, radius=1.0)
	verts = ret['verts']
	bmesh.ops.scale(bm, verts=verts, vec=GS(hx, hy, hz))
	# Taper the tail half (raw Blender +Y = Godot +Z, per GV/GS convention)
	# narrower for a teardrop silhouette rather than a plain ellipsoid.
	for v in verts:
		if v.co.y > 0:
			t = v.co.y / hz
			shrink = 1.0 - t * tail_taper
			v.co.x *= shrink
			v.co.z *= shrink
	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# Hard-armor region: the blunt nose - same frontal-arc reasoning as
	# every other vehicle hull, called before the gondola/fins/keel
	# additions so those stay lightweight structural fixtures, not part
	# of the envelope's own armor plating. This shape never gets a
	# bevel_sharp_edges() call (the uvsphere is already smooth), so
	# recalc_face_normals() above is needed first - the taper loop directly
	# mutates vertex coordinates without keeping face normals in sync.
	armor_frac = mark_armor_faces(bm, frontal_armor_predicate(hz, front_frac=armor_front_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Gondola slung underneath on struts, biased toward the nose for balance.
	gon_w, gon_h, gon_l = hx * 0.5, hy * 0.35, hz * 0.6
	add_box(bm, (0, -hy * 0.85, -hz * 0.15), (gon_w, gon_h, gon_l), bevel=gon_bevel)
	for side in (-1, 1):
		for z_frac in (-0.35, 0.25):
			add_cyl_y(bm, (side * gon_w * 0.35, -hy * 0.6, z_frac * hz * 0.3), 0.03, hy * 0.7, segments=6)

	# Tail fin cross near the tail taper.
	fin_z = hz * 0.75
	fin_span = min(hx, hy) * 0.9
	add_box(bm, (0, fin_span * 0.5, fin_z), (0.04, fin_span, hz * 0.18), bevel=fin_bevel)
	add_box(bm, (0, -fin_span * 0.5, fin_z), (0.04, fin_span, hz * 0.18), bevel=fin_bevel)
	add_box(bm, (fin_span * 0.5, 0, fin_z), (fin_span, 0.04, hz * 0.18), bevel=fin_bevel)
	add_box(bm, (-fin_span * 0.5, 0, fin_z), (fin_span, 0.04, hz * 0.18), bevel=fin_bevel)

	# Longitudinal keel girders - 3 thin fused battens (technique #1,
	# fused primitives left interpenetrating the envelope, same as every
	# other hull's non-welded volumes) running most of the length along
	# the belly, above the gondola. Thickness keyed to R, length to hz,
	# per HULL_MASSING_SPEC.md's stretch-safety rules. Together with the
	# existing ring seams (greebles) and the faceted envelope panels,
	# this is the move that reads as a real girder-frame Zeppelin rather
	# than a faceted balloon.
	batten_size = R * 0.035
	for x_off in (-hx * 0.32, 0.0, hx * 0.32):
		add_box(bm, (x_off, -hy * 0.68, 0), (batten_size, batten_size, hz * 1.75), bevel=0.01)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	# Canvas/aluminum-skin envelope reads wrong with the ground vehicles'
	# metallic paint - flatter, less reflective finish instead. (Preview-
	# only, same as every other hull's finalize_dual() color args - the
	# real runtime material is always the shared faction shader regardless
	# of hull type, unaffected by this.)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color),
		structural_metallic=0.1, structural_roughness=0.6, armor_metallic=0.3, armor_roughness=0.45)
	return obj


def build_tower_hull(name, size_x, size_y, size_z, tiers=3, color=(0.5, 0.48, 0.44), greebles=None, armor_base_frac=0.06):
	"""Tall stepped defensive tower: tiers stacked wide-to-narrow."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()
	tier_h = (size_y) / tiers
	all_verts = []
	for t in range(tiers):
		shrink = 1.0 - (t * 0.22)
		y0 = -hy + t * tier_h
		y1 = y0 + tier_h * (1.05 if t < tiers - 1 else 1.0)
		tx, tz = hx * shrink, hz * shrink
		pts = [
			(-tx, y0, -tz), (tx, y0, -tz), (-tx, y0, tz), (tx, y0, tz),
			(-tx, y1, -tz), (tx, y1, -tz), (-tx, y1, tz), (tx, y1, tz),
		]
		verts = [bm.verts.new(GV(*p)) for p in pts]
		bmesh.ops.convex_hull(bm, input=verts)
		all_verts += verts

	# Slight outward-flared base skirt - a shallow wider collar right at
	# the foundation, before any bevel touches the main stepped body.
	skirt_h = tier_h * 0.16
	skirt_verts = [bm.verts.new(GV(*p)) for p in [
		(-hx * 1.1, -hy - skirt_h, -hz * 1.1), (hx * 1.1, -hy - skirt_h, -hz * 1.1),
		(-hx * 1.1, -hy - skirt_h, hz * 1.1), (hx * 1.1, -hy - skirt_h, hz * 1.1),
		(-hx, -hy, -hz), (hx, -hy, -hz), (-hx, -hy, hz), (hx, -hy, hz),
	]]
	bmesh.ops.convex_hull(bm, input=skirt_verts)
	all_verts += skirt_verts

	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# Tier-1 bevel across the stepped body's real structural edges
	# (tier-to-tier shrink steps, skirt flare) - before railings/antenna
	# are fused on so only the primary silhouette is touched.
	bevel_sharp_edges(bm, all_verts, R, tier=1)

	# Hard-armor region: the base/lower tiers, NOT a frontal arc - a tower
	# has no distinct front/back (each tier is roughly rotationally
	# symmetric), so real castle-defense logic applies instead: the
	# ground-level tiers facing direct assault are hardened, upper tiers
	# are lighter structural stonework. Called before the machicolation
	# ring/railings/antenna/spotlights so those stay lightweight rooftop
	# fixtures, not armor plate.
	armor_frac = mark_armor_faces(bm, vertical_armor_predicate(hy, base_frac=armor_base_frac))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	# Bespoke Tier 3 feature: a corbelled machicolation ring - a real
	# castle-defense projecting gallery, supported on angled brackets,
	# sitting at the step between the second-to-last and top tier so the
	# top tier reads as bridging out past its own (narrower) footprint on
	# a shelf, rather than just another plain stepped-pyramid shrink. Sized
	# to the tier BELOW the shelf (wider than the top tier it supports),
	# which is what makes the overhang actually visible from outside.
	if tiers >= 2:
		# Sized to the tier TWO steps below the shelf (clamped to the base
		# tier's own full footprint) - matching the tier directly below it
		# (an earlier version's off-by-one) left zero overhang, since the
		# shelf would then sit exactly flush with the very edge it was
		# meant to project past.
		shelf_shrink = 1.0 - (max(tiers - 3, 0) * 0.22)
		shelf_tx, shelf_tz = hx * shelf_shrink, hz * shelf_shrink
		shelf_y = -hy + (tiers - 1) * tier_h
		shelf_th = tier_h * 0.09
		add_box(bm, (0, shelf_y, -shelf_tz + shelf_th * 0.5), (shelf_tx * 2.0, shelf_th, shelf_th), bevel=0.015)
		add_box(bm, (0, shelf_y, shelf_tz - shelf_th * 0.5), (shelf_tx * 2.0, shelf_th, shelf_th), bevel=0.015)
		add_box(bm, (-shelf_tx + shelf_th * 0.5, shelf_y, 0), (shelf_th, shelf_th, shelf_tz * 2.0), bevel=0.015)
		add_box(bm, (shelf_tx - shelf_th * 0.5, shelf_y, 0), (shelf_th, shelf_th, shelf_tz * 2.0), bevel=0.015)
		for i in range(8):
			angle = i * (math.pi / 4.0)
			cx, cz = math.cos(angle) * shelf_tx * 0.92, math.sin(angle) * shelf_tz * 0.92
			add_box(bm, (cx, shelf_y - shelf_th * 1.6, cz), (0.12, shelf_th * 1.4, 0.12),
				rot_axis='x', rot_angle=0.6)

	# Rooftop platform railing posts
	top_shrink = 1.0 - ((tiers - 1) * 0.22)
	rx, rz = hx * top_shrink * 0.9, hz * top_shrink * 0.9
	for i in range(4):
		angle = i * (math.pi / 2.0) + math.pi / 4.0
		pos = (math.cos(angle) * rx, hy * 0.85, math.sin(angle) * rz)
		add_cyl_y(bm, pos, 0.03, 0.35, segments=6)
	greeble_antenna(bm, (0, hy, 0), height=0.7, radius=0.025)
	for side in (-1, 1):
		greeble_spotlight(bm, (side * rx * 0.7, hy * 0.75, -rz * 0.7), radius=0.09)

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


def build_battery_hull(name, size_x, size_y, size_z, mounts=2, color=(0.4, 0.4, 0.36),
		greebles=None, armor_threshold=0.3, pedestal_amp=0.42):
	"""Open-platform battery: low truncated-pyramid base + N weapon-mount pedestals
	on top. The most mount-friendly foundation: large flat top pad, minimal side
	sponson real-estate. Reads as a static fire-base (coast-artillery casemate,
	missile launch pad, SAM emplacement).

	mounts: number of mount pedestals on top - 2 for the classic twin-gun battery,
	  3 for the more spread-out fire-base. Pedestals are slightly inset from the
	  platform edges so weapons on the rear pedestal don't visually collide with
	  the platform's own rear slope.

	pedestal_amp: 0..0.5, fraction of (hx, hz) the pedestal centers are inset from
	  the platform's own centerline. 0.42 keeps twin pedestals at +/-0.42*hx on
	  the X axis, leaving a clean central sightline down the +Z axis."""
	hx, hy, hz = size_x / 2.0, size_y / 2.0, size_z / 2.0
	R = hull_reference_dim(size_x, size_y)
	bm = bmesh.new()

	# Truncated-pyramid base: wider footprint at the ground, narrower at the
	# platform deck. The deck itself sits at hy * 0.35 - low enough that the
	# pedestals (which extend up to hy) read as the silhouette's tallest
	# element, not the base. This is the "open platform" read: the silhouette
	# is dominated by the mounts, not the housing.
	base_pts = [
		(-hx * 1.15, -hy, -hz * 1.15), (hx * 1.15, -hy, -hz * 1.15),
		(-hx * 1.15, -hy, hz * 1.15), (hx * 1.15, -hy, hz * 1.15),
		(-hx * 0.92, hy * 0.35, -hz * 0.92), (hx * 0.92, hy * 0.35, -hz * 0.92),
		(-hx * 0.92, hy * 0.35, hz * 0.92), (hx * 0.92, hy * 0.35, hz * 0.92),
	]
	verts = [bm.verts.new(GV(*p)) for p in base_pts]
	bmesh.ops.convex_hull(bm, input=verts)

	# Weapon-mount pedestals. Each is its own mini truncated-pyramid sitting
	# on the deck: 0.65 wide at the base (matches the deck inset), 0.45 at
	# the top (the actual mount ring). 0.55 tall - the deck is at hy*0.35,
	# the pedestal top is at hy*0.90, leaving the top 10% as a clear sight
	# zone for the weapon. The pedestal tops are deliberately flat-faced
	# (not bevelled yet) so the post-bevel chamfer doesn't eat the mount
	# surface itself.
	if mounts == 2:
		pedestal_xs = [-hx * pedestal_amp, hx * pedestal_amp]
		pedestal_zs = [0.0, 0.0]
	elif mounts == 3:
		# Triangle: one rear, two forward-fan. Spreads the silhouette
		# without crowding the front sightline.
		pedestal_xs = [-hx * pedestal_amp, hx * pedestal_amp, 0.0]
		pedestal_zs = [-hz * 0.4, -hz * 0.4, hz * 0.35]
	else:
		# 4+: fallback to a 2x2 grid, slightly compressed.
		pedestal_xs = [-hx * 0.3, hx * 0.3, -hx * 0.3, hx * 0.3][:mounts]
		pedestal_zs = [-hz * 0.3, -hz * 0.3, hz * 0.3, hz * 0.3][:mounts]

	ped_w_base = 0.55
	ped_w_top = 0.4
	ped_h = hy * 0.55  # top at hy*0.35 + hy*0.55 = hy*0.90
	ped_y_base = hy * 0.35
	ped_y_top = ped_y_base + ped_h
	for px, pz in zip(pedestal_xs, pedestal_zs):
		# Clamp pedestal into the deck footprint so a high mounts count
		# with full pedal_amp doesn't push a pedestal off the platform.
		px = max(-hx * 0.8, min(hx * 0.8, px))
		pz = max(-hz * 0.7, min(hz * 0.7, pz))
		ped_pts = [
			(px - ped_w_base, ped_y_base, pz - ped_w_base),
			(px + ped_w_base, ped_y_base, pz - ped_w_base),
			(px - ped_w_base, ped_y_base, pz + ped_w_base),
			(px + ped_w_base, ped_y_base, pz + ped_w_base),
			(px - ped_w_top, ped_y_top, pz - ped_w_top),
			(px + ped_w_top, ped_y_top, pz - ped_w_top),
			(px - ped_w_top, ped_y_top, pz + ped_w_top),
			(px + ped_w_top, ped_y_top, pz + ped_w_top),
		]
		pverts = [bm.verts.new(GV(*p)) for p in ped_pts]
		bmesh.ops.convex_hull(bm, input=pverts)

	bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

	# Bevel the base + pedestal silhouette. Tighter pct (0.05) than vehicle
	# hulls so the mount-platform tops stay as wide as possible - the bevel
	# on the pedestal top eats into the mount ring's usable diameter.
	bevel_sharp_edges(bm, list(bm.verts), R, tier=1, pct=0.05, segments=1)

	# Hard-armor region: the BASE slopes (not the deck, not the pedestals).
	# The deck is a mount platform - real battery decks take incidental
	# damage, not direct assault. The base slopes face the enemy.
	# Frontal predicate with a wider threshold (0.3) so all four side slopes
	# get tagged, matching the perimeter-battery concept from HULL_REFRESH_PLAN Â§5.7.
	armor_frac = mark_armor_faces(bm, outward_face_predicate(threshold=armor_threshold))
	print("  [armor split] %s: %.1f%% of surface area tagged hard-armor" % (name, armor_frac * 100.0))

	if greebles:
		greebles(bm, hx, hy, hz)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=tuple(min(1.0, c * 1.15) for c in color))
	return obj


# ---------------------------------------------------------------------------
# Terrain props: boulders and resource-node dressing
# ---------------------------------------------------------------------------
# CORE_DESIGN_LANGUAGE.md's Sec 3.1/3.2 substitution table only holds if a
# "boulder" reads as a boulder at 1:16 scale - terrain_builder.gd's
# _spawn_rock_obstacle() has used raw BoxMesh clusters since obstacles first
# shipped (deliberately, at the time: "avoids the fragile import pipeline
# for pure decoration"), and resource_node.gd's four resource types are
# similarly a bare PrismMesh/CylinderMesh/BoxMesh/SphereMesh per type. Both
# already say in their own comments that this is a placeholder, not final
# art.
#
# Every shape here comes from ONE seeded RNG rather than a hand-placed
# sculpt, so a POOL of several variants per kind (obstacles/nodes pick by a
# deterministic hash of world position - the same convention
# _spawn_rock_obstacle already uses: rng.seed = hash(obstacle.center)) reads
# as real variety instead of one asset stamped everywhere on the map.

def _fracture(bm, cuts, radius, rng, bias_flat=0.0):
	"""Slice the mesh with `cuts` random planes through near-centre points,
	discarding the outboard side each time.

	This is the technique that makes a rock look fractured rather than lumpy.
	Displacement noise - what build_boulder used to rely on entirely - is a
	continuous function over the surface, so it can only ever produce smooth
	bumps; no amount of seed variation will make it yield a sharp broken edge.
	Cutting with planes produces genuinely flat faces meeting at hard angles,
	which is what a fresh fracture surface actually is.

	bias_flat pulls the cutting planes toward horizontal, which produces the
	stacked, shelf-like breaks of bedded rock rather than uniformly random
	angular chunks.
	"""
	from mathutils import Vector as _V
	for _ in range(cuts):
		n = _V((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
		if n.length < 1e-4:
			continue
		n.normalize()
		if bias_flat > 0.0:
			n = n.lerp(_V((0, 0, 1 if n.z >= 0 else -1)), bias_flat)
			n.normalize()
		# Offset from centre controls how much the cut takes off: near the
		# surface it shaves a facet, near the centre it would halve the rock.
		# Kept in the shaving range so a boulder stays a boulder.
		p = n * radius * rng.uniform(0.55, 0.86)
		bmesh.ops.bisect_plane(bm,
			geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
			plane_co=p, plane_no=n, clear_outer=True)
		# The cut leaves an open boundary loop where geometry was removed;
		# without capping it the rock is a hollow shell with a hole in it.
		edges = [e for e in bm.edges if len(e.link_faces) == 1]
		if edges:
			bmesh.ops.holes_fill(bm, edges=edges)
		bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))


def build_boulder(name, radius=1.0, irregularity=0.4, subdivisions=2, flatten=0.75, seed=0,
		color=(0.42, 0.4, 0.37), metallic=0.05, roughness=0.95, style="weathered"):
	"""A fractured rock, in one of three silhouette families.

	Playtest: rocks needed "rugged, organic, actual rocklike shapes." The
	previous version was an icosphere with radial sine noise, which is a
	continuous displacement and therefore can only round the silhouette - it
	read as a lumpy ball. Every style below now gets real planar fracture
	faces via _fracture(), light noise on top for weathering rather than as
	the primary shape, and FLAT shading so those faces actually catch and lose
	light at each angle change instead of being averaged smooth.

	The three families exist because a real boulder field is not one shape
	with randomized parameters:
	  "weathered" - roughly equidimensional, more noise, fewer/softer cuts.
	  "slab"      - a blocky broken chunk, cut from a box, hard and angular.
	  "shelf"     - a low wide ledge, the cliff-base and ravine-wall debris
	                _spawn_slope_rocks() concentrates on steep ground.
	subdivisions=2 still keeps facets large and readable at RTS zoom, per
	CORE_DESIGN_LANGUAGE.md's "a few real facets, not a photoreal sculpt".
	"""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()

	if style == "slab":
		# A box already has nothing but flat faces and hard edges - starting
		# from one and cutting it further gives the most angular family
		# without fighting a sphere's curvature the whole way.
		bmesh.ops.create_cube(bm, size=radius * 1.7)
		bmesh.ops.scale(bm, verts=bm.verts, vec=(1.0, rng.uniform(0.65, 0.95), rng.uniform(0.5, 0.8)))
		# More cuts than the other families: a cube contributes only 6 faces to
		# start with, so at 5 cuts the slab landed at ~10 facets against the
		# icosphere families' ~80 and read as conspicuously simpler rather than
		# as deliberately blocky.
		cuts, noise_amt, bias = 9, irregularity * 0.35, 0.15
	elif style == "shelf":
		bmesh.ops.create_icosphere(bm, subdivisions=subdivisions, radius=radius)
		bmesh.ops.scale(bm, verts=bm.verts, vec=(1.25, 1.0, 0.42))
		cuts, noise_amt, bias = 6, irregularity * 0.45, 0.55
	else:
		bmesh.ops.create_icosphere(bm, subdivisions=subdivisions, radius=radius)
		cuts, noise_amt, bias = 4, irregularity * 0.8, 0.0

	_fracture(bm, cuts, radius, rng, bias_flat=bias)

	# Weathering pass, deliberately AFTER the cuts and deliberately light: it
	# roughens the fracture faces instead of defining the shape. Run the other
	# way round, the cuts would slice cleanly through the noise and erase it.
	for v in bm.verts:
		if v.co.length < 1e-5:
			continue
		n = v.co.normalized()
		lump = 1.0 + noise_amt * (
			0.6 * math.sin(n.x * 2.3 + seed) * math.cos(n.z * 1.7 + seed * 0.5)
			+ 0.4 * (rng.random() - 0.5))
		v.co = v.co * lump

	# Squashes Blender Z, which is Godot Y (up) per this file's own GV()/GS()
	# convention - flattens the boulder's HEIGHT, not its footprint. The shelf
	# family already has its proportions baked in above and would be squashed
	# into a wafer if it took this a second time.
	if style != "shelf":
		bmesh.ops.scale(bm, verts=list(bm.verts), vec=(1.0, 1.0, flatten))
	# Rests ON the ground rather than being buried or floating - every other
	# part in this file is authored in final local space, same contract here.
	min_z = min(v.co.z for v in bm.verts)
	bmesh.ops.translate(bm, verts=list(bm.verts), vec=(0, 0, -min_z))
	obj = make_object_from_bmesh(bm, name)
	# smooth=False is the point of this rework - see finalize()'s own note.
	finalize(obj, name, color=color, metallic=metallic, roughness=roughness, smooth=False)
	return obj


def build_ore_outcrop(name, radius=1.1, seed=0, color=(0.5, 0.42, 0.32)):
	"""A boulder base with a couple of metallic ore veins breaking the
	surface - reads as "worth mining" rather than "generic rock", the same
	distinction the derelict/industrial faction language already draws
	elsewhere in this file between plain and hard-armor material. Two
	material slots, same convention as finalize_dual() (0=rock, 1=ore) -
	built directly here rather than through finalize_dual() itself since
	the rock body and the veins need genuinely different base geometry
	(icosphere vs. boxes), not just a face-predicate split of one shape."""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()
	ret = bmesh.ops.create_icosphere(bm, subdivisions=2, radius=radius)
	verts = ret["verts"]
	for v in verts:
		n = v.co.normalized()
		lump = 1.0 + 0.45 * (
			0.6 * math.sin(n.x * 2.3 + seed) * math.cos(n.z * 1.7 + seed * 0.5)
			+ 0.4 * (rng.random() - 0.5))
		v.co = v.co * lump
	bmesh.ops.scale(bm, verts=verts, vec=(1.0, 1.0, 0.7))
	min_z = min(v.co.z for v in verts)
	bmesh.ops.translate(bm, verts=verts, vec=(0, 0, -min_z))

	for i in range(3):
		angle = rng.uniform(0, math.tau)
		r = radius * rng.uniform(0.55, 0.85)
		pos = (math.cos(angle) * r, radius * rng.uniform(0.35, 0.75), math.sin(angle) * r)
		# bevel=0.0 deliberately - add_box()'s bevel path REPLACES geometry
		# via bmesh.ops.bevel, which invalidates the vert references it
		# returns (a real crash here: ReferenceError, "BMesh data of type
		# BMVert has been removed", the moment .link_faces was read on the
		# stale verts afterward). A vein this small doesn't need the bevel
		# anyway - it reads as a hard mineral edge against the rock's own
		# soft, noisy silhouette either way.
		vein_verts = add_box(bm, pos, (radius * 0.22, radius * 0.35, radius * 0.16),
			rot_axis="y", rot_angle=rng.uniform(0, math.tau), bevel=0.0)
		for f in {f for v in vein_verts for f in v.link_faces}:
			f.material_index = 1

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=color, armor_color=(0.85, 0.65, 0.25),
		structural_metallic=0.1, structural_roughness=0.85, armor_metallic=0.75, armor_roughness=0.3)
	return obj


def build_crystal_cluster(name, count=5, base_radius=0.5, height=2.2, seed=0,
		color=(0.35, 0.55, 0.85)):
	"""Several tapered spikes at varied height/rotation/lean, clustered
	around a shared base - the multi-facet look resource_node.gd's single
	PrismMesh could only gesture at."""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()
	for i in range(count):
		angle = (math.tau / count) * i + rng.uniform(-0.3, 0.3)
		r = base_radius * rng.uniform(0.0, 0.6)
		spike_h = height * rng.uniform(0.5, 1.0)
		spike_r = base_radius * rng.uniform(0.22, 0.34)
		pos = (math.cos(angle) * r, spike_h * 0.5, math.sin(angle) * r)
		verts = add_cyl_y(bm, pos, spike_r, spike_h, segments=6, radius2=spike_r * 0.08)
		lean_axis = "x" if i % 2 == 0 else "z"
		bmesh.ops.rotate(bm, verts=verts, cent=GV(*pos), matrix=rot_matrix(lean_axis, rng.uniform(-0.12, 0.12)))
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.15, roughness=0.12)
	return obj


def build_tree_stand(name, count=3, seed=0, trunk_color=(0.32, 0.24, 0.16), canopy_color=(0.18, 0.32, 0.15)):
	"""A small cluster of conifers at varied height/position - resource_
	node.gd's own comment already frames a lumber field as "really just a
	group of tree seedlings"; this is that idea with a trunk, not a bare
	cone standing in for the whole tree. Two material slots (0=trunk,
	1=canopy), same finalize_dual() convention as build_ore_outcrop()."""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()
	for i in range(count):
		angle = rng.uniform(0, math.tau)
		r = rng.uniform(0.0, 0.9) if i > 0 else 0.0
		tree_h = rng.uniform(2.6, 3.8)
		trunk_h = tree_h * 0.22
		pos = (math.cos(angle) * r, 0, math.sin(angle) * r)
		add_cyl_y(bm, (pos[0], trunk_h * 0.5, pos[2]), 0.09, trunk_h, segments=6)
		canopy_verts = add_cyl_y(bm, (pos[0], trunk_h + (tree_h - trunk_h) * 0.5, pos[2]),
			tree_h * 0.24, tree_h - trunk_h, segments=8, radius2=0.0)
		for f in {f for v in canopy_verts for f in v.link_faces}:
			f.material_index = 1
	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=trunk_color, armor_color=canopy_color,
		structural_metallic=0.0, structural_roughness=0.95, armor_metallic=0.0, armor_roughness=1.0)
	return obj


# Six deliberate silhouettes spread across AMBIENT_TREE_POOL_SIZE (=20):
# the goal is "looks like a real forest" rather than "20 trees that are
# really the same tree mutated slightly" - same lesson the harvestable
# build_tree_stand learned for the field scale, applied at the per-tree
# scale. Each species defines the canopy SHAPE routine; dimensions are
# rolled per-instance from the seed so the same species ships 3-4 visibly
# distinct variants, not 4 identical ones.
#
# 0,1,2  narrow conifer  - spruce-like, 1-2 stacked tight cones
# 3,4,5  fat conifer     - fir-like, single fat low cone
# 6,7,8,9 broadleaf round - tall trunk + a single fat sphere canopy
# 10..13  broadleaf sparse - tall trunk + 2-3 small offset sphere canopies
# 14,15,16 dead snag      - just a bare trunk, no canopy
# 17,18,19 juvenile       - small sapling, single small cone
def _ambient_canopy_narrow_conifer(bm, pos, rng):
	height = rng.uniform(2.4, 4.2)
	radius_base = rng.uniform(0.55, 0.95)
	trunk_h = height * rng.uniform(0.18, 0.28)
	stacks = rng.choice([1, 2, 2, 3])
	canopy_h = height - trunk_h
	for s in range(stacks):
		# Each stacked cone is a fraction of the canopy height, narrower as
		# it goes up. Stacking is what makes a conifer read as a conifer
		# rather than a "very pointy egg" - the silhouette is the layered
		# outline, not a single smooth shape.
		frac = (s + 1) / float(stacks)
		seg_h = canopy_h / stacks
		seg_r = radius_base * (0.4 + 0.6 * (1.0 - (s / float(stacks)) * 0.4))
		cy = trunk_h + seg_h * (s + 0.5)
		verts = add_cyl_y(bm, (pos[0], cy, pos[2]), seg_r, seg_h, segments=8, radius2=0.0)
		for f in {f for v in verts for f in v.link_faces}:
			f.material_index = 1
	return height, trunk_h


def _ambient_canopy_fat_conifer(bm, pos, rng):
	height = rng.uniform(2.6, 4.0)
	radius_base = rng.uniform(1.0, 1.5)
	trunk_h = height * rng.uniform(0.15, 0.22)
	canopy_h = height - trunk_h
	verts = add_cyl_y(bm, (pos[0], trunk_h + canopy_h * 0.5, pos[2]),
		radius_base, canopy_h, segments=10, radius2=radius_base * 0.35)
	for f in {f for v in verts for f in v.link_faces}:
		f.material_index = 1
	return height, trunk_h


def _ambient_canopy_broadleaf_round(bm, pos, rng):
	height = rng.uniform(2.8, 4.5)
	radius_base = rng.uniform(0.7, 1.2)
	trunk_h = height * rng.uniform(0.45, 0.6)
	canopy_h = height - trunk_h
	canopy_r = rng.uniform(0.75, 1.4)
	# A squashed sphere reads as a broadleaf round canopy at RTS distance;
	# a full sphere would look like a balloon, a flat disk would lose the
	# volume. Slight downward bias (1.0x/0.7x) for a "drooping" leaf mass.
	verts = add_sphere(bm, (pos[0], trunk_h + canopy_h * 0.45, pos[2]),
		radius=canopy_r, segments=12, rings=8, scale_y=0.7)
	for f in {f for v in verts for f in v.link_faces}:
		f.material_index = 1
	return height, trunk_h


def _ambient_canopy_broadleaf_sparse(bm, pos, rng):
	height = rng.uniform(3.0, 4.5)
	trunk_h = height * rng.uniform(0.55, 0.7)
	canopy_h = height - trunk_h
	canopy_r = rng.uniform(0.45, 0.7)
	# 2-3 small offset canopies rather than one fat one - the sparse-
	# leaf silhouette is a real broadleaf species, not a rendering bug.
	n_clusters = rng.randint(2, 3)
	for c in range(n_clusters):
		offset = (rng.uniform(-0.6, 0.6), rng.uniform(-0.2, 0.3), rng.uniform(-0.6, 0.6))
		cy = trunk_h + canopy_h * (0.4 + 0.3 * c / max(1, n_clusters - 1))
		cx = pos[0] + offset[0] * canopy_r
		cz = pos[2] + offset[2] * canopy_r
		verts = add_sphere(bm, (cx, cy, cz),
			radius=canopy_r * rng.uniform(0.85, 1.15), segments=10, rings=6, scale_y=0.7)
		for f in {f for v in verts for f in v.link_faces}:
			f.material_index = 1
	return height, trunk_h


def _ambient_canopy_dead_snag(bm, pos, rng):
	# No canopy at all - just a tall thin bare trunk. A "standing dead" snag
	# is a real ecological category and adds a weathered texture to the
	# silhouette mix; 3 variants in the pool is enough to read as a recurring
	# prop without crowding out the living species. Slight per-variant lean
	# so the three dead-snag entries don't look like three identical poles.
	height = rng.uniform(3.2, 4.5)
	trunk_h = height
	trunk_r = rng.uniform(0.12, 0.18)
	add_cyl_y(bm, (pos[0], trunk_h * 0.5, pos[2]), trunk_r, trunk_h, segments=6)
	return height, trunk_h


def _ambient_canopy_juvenile(bm, pos, rng):
	# A short sapling - single tight cone, small trunk, deliberately below
	# the ~2.5m adult-species floor. Adds an age-class mix to the forest
	# rather than a single uniform maturity - real regeneration in a
	# forest looks like a mix, not a single cohort.
	height = rng.uniform(1.2, 2.0)
	trunk_h = height * rng.uniform(0.25, 0.35)
	canopy_r = rng.uniform(0.3, 0.55)
	verts = add_cyl_y(bm, (pos[0], trunk_h + (height - trunk_h) * 0.5, pos[2]),
		canopy_r, height - trunk_h, segments=6, radius2=0.0)
	for f in {f for v in verts for f in v.link_faces}:
		f.material_index = 1
	return height, trunk_h


def build_ambient_tree(name, seed=0):
	"""A SINGLE tree of varied species and proportion - the ambient tree
	pool (resource_node.gd's AMBIENT_TREE_POOL_SIZE = 20) picks from this
	family for the harvestable-but-not-regrowing trees scattered across
	the whole map. Distinct from build_tree_stand(): that one author the
	HARVESTABLE LUMBER COLLECTIBLES (3-variant pool, 3 trees per variant,
	clumped into a "stand" by a field centre); this one author the
	AMBIENT per-tree mesh, with one tree per variant and a deliberate
	species mix (narrow conifer / fat conifer / broadleaf round / sparse
	/ dead snag / juvenile) so 20 variants actually look like 20 trees.

	Two material slots (0=trunk, 1=canopy), finalize_dual() convention
	identical to build_tree_stand() and build_ore_outcrop() - resource_
	node.gd's _try_spawn_ambient_authored() can use the same load path
	without a separate material switch. Trunk/canopy colours are seeded
	too, so two narrow conifers aren't literally the same green."""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()

	# Small XZ jitter for the whole tree so a scatter that draws variant
	# k at integer positions still has slight sub-position randomness for
	# the leaf cluster (no per-tree axis offset yet - that's terrain_
	# greebles.gd's call). Trunk leans a fraction of a degree for the
	# same reason; the lean is tiny because at RTS camera distance a 5
	# degree lean reads as "broken" rather than "natural".
	pos = (rng.uniform(-0.05, 0.05), 0.0, rng.uniform(-0.05, 0.05))
	lean = rng.uniform(-0.04, 0.04)
	lean_axis = rng.choice(['x', 'z'])

	# Species index is the seed mod 6 - the same species ships multiple
	# variants (3-4 of each), and within a species the dimensions/colors
	# roll from the same RNG so the family is self-contained.
	species = seed % 6
	# Pool size 20 -> 0..19; the last 3 (17,18,19) are juvenile so the
	# forest has a small but visible age-class spread. The other 17
	# roughly split across the 5 adult species.
	within_species = seed % 20
	if within_species < 3:
		species = 0  # narrow conifer
	elif within_species < 6:
		species = 1  # fat conifer
	elif within_species < 10:
		species = 2  # broadleaf round
	elif within_species < 14:
		species = 3  # broadleaf sparse
	elif within_species < 17:
		species = 4  # dead snag
	else:
		species = 5  # juvenile

	canopy_fn = (
		_ambient_canopy_narrow_conifer if species == 0
		else _ambient_canopy_fat_conifer if species == 1
		else _ambient_canopy_broadleaf_round if species == 2
		else _ambient_canopy_broadleaf_sparse if species == 3
		else _ambient_canopy_dead_snag if species == 4
		else _ambient_canopy_juvenile
	)
	total_h, trunk_h = canopy_fn(bm, pos, rng)

	# Trunk goes in last so its top sits flush with whatever the canopy
	# routine stacked on top. A trunk that was added FIRST and then a
	# canopy function inserted geometry above it would z-fight at the
	# trunk top.
	trunk_r = rng.uniform(0.08, 0.16) if species != 4 else rng.uniform(0.12, 0.18)
	add_cyl_y(bm, (pos[0], trunk_h * 0.5, pos[2]), trunk_r, trunk_h, segments=6)
	if lean != 0.0:
		bmesh.ops.rotate(bm, verts=bm.verts, cent=(pos[0], 0, pos[2]),
			matrix=rot_matrix(lean_axis, lean))

	# Trunk/canopy colour from a tight, deliberate palette per slot.
	# Seeding the colours (not picking a fixed value) is what makes two
	# "narrow conifer" entries look like two different trees rather than
	# the same tree seen twice.
	trunk_color = (
		rng.uniform(0.30, 0.42),  # brown band
		rng.uniform(0.22, 0.32),
		rng.uniform(0.14, 0.22),
	)
	# A dead snag's canopy is the trunk itself, so re-roll the canopy
	# colour toward a greyed-out trunk palette and let it apply to the
	# whole mesh (no canopy mesh exists to need a different colour).
	if species == 4:
		canopy_color = (
			rng.uniform(0.40, 0.55),  # bleached-grey band
			rng.uniform(0.38, 0.50),
			rng.uniform(0.32, 0.42),
		)
		# Both slots get the snag palette: trunk and "canopy" are the same
		# material in this case. finalize_dual still wants two distinct
		# Blender materials, so reuse the same value.
		trunk_color = canopy_color
	else:
		# Healthy canopy: green band 0.16..0.32, intentionally narrow
		# because two "different green" canopies that are wildly different
		# read as two seasons rather than one forest.
		canopy_color = (
			rng.uniform(0.16, 0.32),
			rng.uniform(0.28, 0.45),
			rng.uniform(0.13, 0.22),
		)

	obj = make_object_from_bmesh(bm, name)
	finalize_dual(obj, name, structural_color=trunk_color, armor_color=canopy_color,
		structural_metallic=0.0, structural_roughness=0.95,
		armor_metallic=0.0, armor_roughness=1.0)
	return obj


def build_oil_derrick(name, seed=0, color=(0.22, 0.22, 0.24)):
	"""A squat pump-jack frame - reads as infrastructure sitting on the
	ground rather than a mineral growing out of it, same intent
	resource_node.gd's existing box "derrick" comment already states."""
	import random
	rng = random.Random(seed)
	bm = bmesh.new()
	add_box(bm, (0, 0.15, 0), (1.6, 0.3, 1.6), bevel=0.03)
	for x_sign in (-1, 1):
		for z_sign in (-1, 1):
			add_cyl_y(bm, (x_sign * 0.6, 1.2, z_sign * 0.6), 0.06, 2.4, segments=6)
	add_box(bm, (0, 2.4, 0), (1.5, 0.15, 0.5), bevel=0.02)
	add_cyl_y(bm, (0, 1.2, 0), 0.08, 2.4, segments=6)
	obj = make_object_from_bmesh(bm, name)
	finalize(obj, name, color=color, metallic=0.65, roughness=0.4)
	return obj


def generate_terrain_props():
	print("--- Building terrain props (boulders, resource-node dressing) ---")
	import os as _os
	terrain_dir = _os.path.join(PROJECT_ROOT, "assets", "models", "terrain")
	_os.makedirs(terrain_dir, exist_ok=True)

	# Six boulders, two of each silhouette family - a real rock field mixes
	# blocky fresh breaks with rounded weathered stone and low cliff-base
	# ledges. Keep in step with BOULDER_POOL_SIZE in terrain_builder.gd, which
	# indexes this pool by name; a pool size larger than what is exported here
	# rolls indices at .glb files that do not exist and falls silently back to
	# the primitive placeholder (exactly the bug AUTHORED_POOL_SIZES in
	# resource_node.gd was added to stop repeating).
	BOULDER_STYLES = ["weathered", "weathered", "slab", "slab", "shelf", "shelf"]
	for i, style in enumerate(BOULDER_STYLES):
		export_and_cleanup(build_boulder("boulder_%d" % i, radius=1.0 + 0.35 * (i % 3),
			seed=100 + i, flatten=0.6 + 0.1 * (i % 2), style=style),
			terrain_dir, "boulder_%d" % i)

	for i in range(3):
		# Named "ore", not "metal" - ResourceCatalog.canonical() resolves the
		# "metal" alias to "ore" (ALIASES = {"metal": "ore"}), and
		# resource_node.gd looks up the authored pool by the CANONICAL id.
		export_and_cleanup(build_ore_outcrop("resource_ore_%d" % i, seed=200 + i),
			terrain_dir, "resource_ore_%d" % i)
	for i in range(3):
		export_and_cleanup(build_crystal_cluster("resource_crystal_%d" % i, seed=300 + i),
			terrain_dir, "resource_crystal_%d" % i)
	for i in range(3):
		export_and_cleanup(build_tree_stand("resource_lumber_%d" % i, seed=400 + i),
			terrain_dir, "resource_lumber_%d" % i)
	for i in range(2):
		export_and_cleanup(build_oil_derrick("resource_oil_%d" % i, seed=500 + i),
			terrain_dir, "resource_oil_%d" % i)

	# AMBIENT_TREE_POOL_SIZE in resource_node.gd MUST match this range - the
	# loader rolls `idx = randi() % AMBIENT_TREE_POOL_SIZE`, so any index
	# with no exported .glb falls through to the procedural cylinder
	# fallback. The same trim-the-pool-to-what-exists guard that
	# AUTHORED_POOL_SIZES exists for at the harvestable-resource scale,
	# applied at the ambient-tree scale.
	for i in range(20):
		export_and_cleanup(build_ambient_tree("ambient_tree_%d" % i, seed=600 + i),
			terrain_dir, "ambient_tree_%d" % i)

	print("--- Terrain props written to %s ---" % terrain_dir)


# ---------------------------------------------------------------------------
# Generate: reusable parts
# ---------------------------------------------------------------------------

def generate_parts():
	print("--- Building parts library ---")

	export_and_cleanup(build_barrel("barrel_thin", length=1.0, radius=0.06, muzzle_radius=0.05), PARTS_DIR, "barrel_thin")
	export_and_cleanup(build_barrel("barrel_standard", length=1.0, radius=0.1, muzzle_radius=0.09), PARTS_DIR, "barrel_standard")
	export_and_cleanup(build_barrel("barrel_heavy", length=1.0, radius=0.16, muzzle_radius=0.22, fins=3), PARTS_DIR, "barrel_heavy")
	export_and_cleanup(build_barrel("barrel_taper_wide", length=1.0, radius=0.08, muzzle_radius=0.1), PARTS_DIR, "barrel_taper_wide")

	export_and_cleanup(build_cylinder_part("turret_base_round", radius=0.4, height=0.35, color=(0.32, 0.32, 0.35)), PARTS_DIR, "turret_base_round")
	export_and_cleanup(build_box_part("turret_base_box", size=(1.0, 0.5, 0.7), color=(0.32, 0.32, 0.35)), PARTS_DIR, "turret_base_box")

	# Housing for a weapon embedded in a near-vertical hull face. Aperture
	# faces -Z (the muzzle axis) - see build_sponson_blister's docstring.
	export_and_cleanup(build_sponson_blister("sponson_blister"), PARTS_DIR, "sponson_blister")

	export_and_cleanup(build_cylinder_part("ammo_drum", radius=0.5, height=0.4, color=(0.22, 0.24, 0.2)), PARTS_DIR, "ammo_drum")
	export_and_cleanup(build_cylinder_part("canister_small", radius=0.4, height=1.0, color=(0.5, 0.15, 0.12)), PARTS_DIR, "canister_small")
	export_and_cleanup(build_cylinder_part("fuel_tank", radius=0.5, height=1.0, color=(0.4, 0.1, 0.1)), PARTS_DIR, "fuel_tank")

	export_and_cleanup(build_dome("sensor_dome", radius=0.5, squash=0.65, color=(0.9, 0.92, 0.95)), PARTS_DIR, "sensor_dome")
	export_and_cleanup(build_dome("focal_lens", radius=0.5, squash=0.8, color=(1.0, 0.3, 0.3)), PARTS_DIR, "focal_lens")

	export_and_cleanup(build_missile_body("missile_body", length=1.0, radius=0.1, color=(0.92, 0.92, 0.9)), PARTS_DIR, "missile_body")
	export_and_cleanup(build_pintle_mount("pintle_mount", color=(0.18, 0.18, 0.2)), PARTS_DIR, "pintle_mount")
	export_and_cleanup(build_cylinder_part("muzzle_brake", radius=0.5, height=0.5, segments=10, color=(0.15, 0.15, 0.16)), PARTS_DIR, "muzzle_brake")

	export_and_cleanup(build_howitzer_breech("howitzer_breech", color=(0.28, 0.28, 0.3)), PARTS_DIR, "howitzer_breech")
	export_and_cleanup(build_basic_cannon_solid("basic_cannon", color=(0.28, 0.28, 0.32)), PARTS_DIR, "basic_cannon")
	export_and_cleanup(build_rotary_jacket("rotary_jacket", color=(0.2, 0.2, 0.21)), PARTS_DIR, "rotary_jacket")
	export_and_cleanup(build_rail_array("rail_array", color=(0.15, 0.15, 0.15)), PARTS_DIR, "rail_array")
	export_and_cleanup(build_flak_breech("flak_breech", color=(0.18, 0.18, 0.18)), PARTS_DIR, "flak_breech")

	export_and_cleanup(build_wheel("wheel_hub", color=(0.08, 0.08, 0.08)), PARTS_DIR, "wheel_hub")
	export_and_cleanup(build_leg_segment("leg_thigh", length=0.55, radius_top=0.13, radius_bottom=0.09, color=(0.3, 0.3, 0.32)), PARTS_DIR, "leg_thigh")
	export_and_cleanup(build_leg_segment("leg_shin", length=0.5, radius_top=0.09, radius_bottom=0.06, color=(0.16, 0.16, 0.17)), PARTS_DIR, "leg_shin")
	export_and_cleanup(build_hover_ring("hover_ring", major_radius=0.5, minor_radius=0.1, color=(0.2, 0.6, 0.9)), PARTS_DIR, "hover_ring")
	export_and_cleanup(build_tread_plate("tread_plate", color=(0.16, 0.16, 0.17)), PARTS_DIR, "tread_plate")
	export_and_cleanup(build_tread_belt_loop("tread_belt_loop", color=(0.14, 0.14, 0.15)), PARTS_DIR, "tread_belt_loop")
	export_and_cleanup(build_screw_drum("screw_drum", color=(0.35, 0.32, 0.28)), PARTS_DIR, "screw_drum")

	# Resource Bay. Two pieces - see the builders' docstrings for why the lid
	# is not fused into the tub.
	export_and_cleanup(build_resource_bay_tub("resource_bay_tub", color=(0.42, 0.36, 0.20)),
		PARTS_DIR, "resource_bay_tub")
	export_and_cleanup(build_resource_bay_lid("resource_bay_lid", color=(0.30, 0.31, 0.33)),
		PARTS_DIR, "resource_bay_lid")

	export_and_cleanup(build_wheel_axle_bar("wheel_axle_bar"), PARTS_DIR, "wheel_axle_bar")
	export_and_cleanup(build_rotor_mast("rotor_mast"), PARTS_DIR, "rotor_mast")
	export_and_cleanup(build_rotor_hub("rotor_hub"), PARTS_DIR, "rotor_hub")
	export_and_cleanup(build_rotor_blade("rotor_blade"), PARTS_DIR, "rotor_blade")
	export_and_cleanup(build_rotor_duct_ring("rotor_duct_ring"), PARTS_DIR, "rotor_duct_ring")
	export_and_cleanup(build_tapered_strut("mount_strut_tapered"), PARTS_DIR, "mount_strut_tapered")
	export_and_cleanup(build_tapered_strut("mount_strut_flat", depth_scale=1.0 / 3.0), PARTS_DIR, "mount_strut_flat")
	export_and_cleanup(build_drive_sprocket("drive_sprocket"), PARTS_DIR, "drive_sprocket")
	export_and_cleanup(build_leg_foot("leg_foot"), PARTS_DIR, "leg_foot")
	export_and_cleanup(build_leg_joint("leg_joint"), PARTS_DIR, "leg_joint")
	export_and_cleanup(build_hover_fan("hover_fan"), PARTS_DIR, "hover_fan")
	export_and_cleanup(build_hover_skirt("hover_skirt"), PARTS_DIR, "hover_skirt")
	export_and_cleanup(build_engine_nacelle("engine_nacelle"), PARTS_DIR, "engine_nacelle")
	export_and_cleanup(build_engine_fan("engine_fan"), PARTS_DIR, "engine_fan")
	export_and_cleanup(build_exhaust_cone("exhaust_cone"), PARTS_DIR, "exhaust_cone")
	export_and_cleanup(build_engine_core("engine_core"), PARTS_DIR, "engine_core")
	export_and_cleanup(build_aerofoil_strut("mount_strut_aerofoil"), PARTS_DIR, "mount_strut_aerofoil")
	export_and_cleanup(build_wing_shoulder("wing_shoulder"), PARTS_DIR, "wing_shoulder")
	export_and_cleanup(build_wing_membrane("wing_membrane"), PARTS_DIR, "wing_membrane")
	export_and_cleanup(build_wing_rib("wing_rib"), PARTS_DIR, "wing_rib")
	export_and_cleanup(build_prop_housing("prop_housing"), PARTS_DIR, "prop_housing")
	export_and_cleanup(build_kort_nozzle("kort_nozzle"), PARTS_DIR, "kort_nozzle")
	export_and_cleanup(build_cruise_nacelle("cruise_nacelle"), PARTS_DIR, "cruise_nacelle")
	export_and_cleanup(build_outrigger_strut("outrigger_strut"), PARTS_DIR, "outrigger_strut")
	export_and_cleanup(build_tail_fin("tail_fin"), PARTS_DIR, "tail_fin")

	export_and_cleanup(build_locomotion_mount_box("rg_mount_box"), PARTS_DIR, "rg_mount_box")
	export_and_cleanup(build_wheel_driveshaft("wheel_driveshaft"), PARTS_DIR, "wheel_driveshaft")
	export_and_cleanup(build_wheel_gearbox("wheel_gearbox"), PARTS_DIR, "wheel_gearbox")

	export_and_cleanup(build_accessory("headlight_cluster", "spotlight", (0.9, 0.9, 0.75), radius=0.07, metallic=0.3, roughness=0.2), PARTS_DIR, "headlight_cluster")
	export_and_cleanup(build_accessory("exhaust_stack", "exhaust", (0.15, 0.15, 0.15), height=0.35, metallic=0.7, roughness=0.5), PARTS_DIR, "exhaust_stack")
	export_and_cleanup(build_accessory("antenna_whip", "antenna", (0.12, 0.12, 0.12), height=0.6, metallic=0.6, roughness=0.4), PARTS_DIR, "antenna_whip")
	export_and_cleanup(build_accessory("vent_grille", "vent", (0.14, 0.14, 0.15), size=(0.4, 0.08, 0.25), metallic=0.55, roughness=0.5), PARTS_DIR, "vent_grille")
	export_and_cleanup(build_accessory("roof_hatch", "hatch", (0.38, 0.38, 0.4), size=(0.6, 0.06, 0.6), metallic=0.6, roughness=0.45), PARTS_DIR, "roof_hatch")
	export_and_cleanup(build_accessory("tool_box", "toolbox", (0.28, 0.32, 0.24), size=(0.5, 0.28, 0.32), metallic=0.3, roughness=0.6), PARTS_DIR, "tool_box")
	export_and_cleanup(build_accessory("sensor_mast", "sensor_mast", (0.15, 0.15, 0.15), height=1.0, metallic=0.6, roughness=0.4), PARTS_DIR, "sensor_mast")

	# --- Propulsion module parts (speed pass, 2026-08-08) ---
	# One piece per tweak, same convention recoilless_rifle established:
	# visual_builder.gd scales each piece independently by the tweak that
	# names it, so "dial up the fuel injection" thickens the feed line and
	# nothing else. Built from the existing generic primitives above rather
	# than new bmesh topology - a turbo housing is a squashed dome, a hub
	# motor can is a drum, a booster tube is a barrel.
	export_and_cleanup(build_dome("turbo_housing", radius=0.18, squash=0.75, color=(0.35, 0.36, 0.4)), PARTS_DIR, "turbo_housing")
	export_and_cleanup(build_cylinder_part("turbo_intake", radius=0.09, height=0.32, bolts=False, color=(0.3, 0.31, 0.34)), PARTS_DIR, "turbo_intake")
	export_and_cleanup(build_cylinder_part("hub_motor_can", radius=0.16, height=0.14, bolts=False, color=(0.25, 0.4, 0.55)), PARTS_DIR, "hub_motor_can")
	export_and_cleanup(build_box_part("hub_stator_segment", size=(0.05, 0.1, 0.03), bolts=False, color=(0.2, 0.35, 0.5)), PARTS_DIR, "hub_stator_segment")
	export_and_cleanup(build_cylinder_part("nitrous_bottle", radius=0.11, height=0.55, bolts=False, color=(0.65, 0.85, 0.95)), PARTS_DIR, "nitrous_bottle")
	export_and_cleanup(build_barrel("nitrous_feed_line", length=0.4, radius=0.025, muzzle_radius=0.025, segments=8, fins=0), PARTS_DIR, "nitrous_feed_line")
	export_and_cleanup(build_barrel("booster_tube", length=0.7, radius=0.09, muzzle_radius=0.09, segments=12, fins=0), PARTS_DIR, "booster_tube")
	export_and_cleanup(build_box_part("booster_rack_frame", size=(0.85, 0.12, 0.5), bolts=True, color=(0.4, 0.15, 0.12)), PARTS_DIR, "booster_rack_frame")

	print("--- Parts library done ---")


# ---------------------------------------------------------------------------
# Generate: hull chassis (size = catalog "size" Vector3, matched exactly)
# ---------------------------------------------------------------------------

def _light_hull_greebles(bm, hx, hy, hz):
	greeble_headlight_pair(bm, hx, -hy * 0.2, -hz * 0.96, radius=0.08)
	greeble_antenna(bm, (hx * 0.5, hy * 1.0, hz * 0.3), height=0.22)
	greeble_vent(bm, (hx * 0.92, hy * 0.1, hz * 0.1), (0.1, 0.3, 0.5), slats=3)
	greeble_vent(bm, (-hx * 0.92, hy * 0.1, hz * 0.1), (0.1, 0.3, 0.5), slats=3)


def _medium_hull_greebles(bm, hx, hy, hz):
	greeble_headlight_pair(bm, hx, -hy * 0.15, -hz * 0.97, radius=0.1)
	greeble_hatch(bm, (0, hy * 1.05, hz * 0.1), (0.7, 0.06, 0.6))
	greeble_toolbox(bm, (hx * 0.7, -hy * 0.55, hz * 0.5))
	greeble_exhaust_stack(bm, (-hx * 0.75, hy * 0.6, hz * 0.85), radius=0.09, height=0.4)
	greeble_exhaust_stack(bm, (-hx * 0.55, hy * 0.6, hz * 0.85), radius=0.09, height=0.32)
	greeble_corner_gusset(bm, -1, hx, hy, -hz * 0.85)
	greeble_corner_gusset(bm, 1, hx, hy, -hz * 0.85)
	greeble_rivet_row(bm, (-hx * 0.9, hy * 0.9, -hz * 0.6), (-hx * 0.9, hy * 0.9, hz * 0.6), 6)
	greeble_rivet_row(bm, (hx * 0.9, hy * 0.9, -hz * 0.6), (hx * 0.9, hy * 0.9, hz * 0.6), 6)


def _heavy_hull_greebles(bm, hx, hy, hz):
	greeble_headlight_pair(bm, hx * 0.8, -hy * 0.1, -hz * 0.97, radius=0.13)
	greeble_hatch(bm, (0, hy * 1.08, 0), (1.0, 0.08, 0.9))
	add_cyl_y(bm, (0, hy * 1.15, 0), 0.45, 0.22, segments=14)  # commander cupola
	for x_sign in (-1, 1):
		for z_frac in (-0.75, 0.6):
			greeble_corner_gusset(bm, x_sign, hx, hy, hz * z_frac, size=(0.5, 0.42, 0.7))
	greeble_exhaust_stack(bm, (-hx * 0.7, hy * 0.65, hz * 0.9), radius=0.12, height=0.5)
	greeble_exhaust_stack(bm, (-hx * 0.45, hy * 0.65, hz * 0.9), radius=0.12, height=0.42)
	greeble_rivet_row(bm, (-hx * 0.95, hy * 0.85, -hz * 0.8), (-hx * 0.95, hy * 0.85, hz * 0.8), 8)
	greeble_rivet_row(bm, (hx * 0.95, hy * 0.85, -hz * 0.8), (hx * 0.95, hy * 0.85, hz * 0.8), 8)
	greeble_toolbox(bm, (hx * 0.75, -hy * 0.6, -hz * 0.3), size=(0.6, 0.32, 0.4))


def _interceptor_hull_greebles(bm, hx, hy, hz):
	# Sleek - fewer greebles, a small faired canopy (a real cockpit
	# volume, technique #1 - see greeble_faired_canopy) + tail fins +
	# intakes. Height clamped to hy, width/length to hx/hz per
	# HULL_MASSING_SPEC.md's interceptor_hull stretch-safety note - keeps
	# the dome from inverting its squash ratio under an extreme
	# independent hull_scale.y stretch. Set slightly forward of centre
	# and low/blended rather than the old proud add_box bump.
	greeble_faired_canopy(bm, (0, hy * 0.78, -hz * 0.1), (hx * 0.32, hy * 0.24, hz * 0.42))
	greeble_vent(bm, (hx * 0.85, 0, hz * 0.3), (0.08, 0.3, 0.6), slats=4)
	greeble_vent(bm, (-hx * 0.85, 0, hz * 0.3), (0.08, 0.3, 0.6), slats=4)
	for side in (-1, 1):
		add_box(bm, (side * hx * 0.5, hy * 0.3, hz * 0.92), (0.04, hy * 0.5, 0.3), rot_axis='x', rot_angle=0.3)
	greeble_antenna(bm, (0, hy * 1.05, -hz * 0.2), height=0.18)


def _assault_hull_greebles(bm, hx, hy, hz):
	greeble_headlight_pair(bm, hx * 0.75, -hy * 0.1, -hz * 0.97, radius=0.11)
	# Applique armor plates - tier-2 bevel (Section 3: "armor plates:
	# beveled/angled edges, tier-2") plus a vertical rivet line near the
	# exposed outward face; the back/mount-contact face against the hull
	# stays flat since the rivets only run along the outward-facing edge.
	plate_bevel, _ = tiered_bevel_width(hull_reference_dim(hx * 2, hy * 2), tier=2)
	for x_sign in (-1, 1):
		for z_frac in (-0.5, 0.0, 0.5):
			plate_x, plate_z = x_sign * hx * 0.98, hz * z_frac
			add_box(bm, (plate_x, hy * 0.1, plate_z), (0.1, hy * 1.1, hz * 0.28), bevel=plate_bevel)
			greeble_rivet_row(bm, (plate_x + x_sign * 0.06, hy * 0.1 - hy * 0.48, plate_z),
				(plate_x + x_sign * 0.06, hy * 0.1 + hy * 0.48, plate_z), 4, radius=0.018, axis='x')
	add_cyl_y(bm, (0, hy * 1.1, hz * 0.1), 0.5, 0.14, segments=16)  # turret ring
	greeble_hatch(bm, (0, hy * 1.15, hz * 0.1), (0.55, 0.05, 0.5))
	# Front dozer-style plate, sized to span the tub's full nose height
	# (assumes tub_frac=0.55, matching the build_afv_hull call below, so
	# tub_top_y = -hy + 2*hy*0.55 = 0.1*hy) so it fuses visually into the
	# tub/glacis seam instead of floating in front of the hull as a
	# separate bump - "one thick layered frontal assembly" per
	# HULL_MASSING_SPEC.md's assault_hull section.
	add_box(bm, (0, -hy * 0.45, -hz * 1.02), (hx * 1.3, hy * 1.05, 0.15), bevel=0.03)
	greeble_exhaust_stack(bm, (-hx * 0.6, hy * 0.55, hz * 0.9), radius=0.1, height=0.4)


# ---------------------------------------------------------------------------
# Manufacturer signature dispatcher
# ---------------------------------------------------------------------------
# Each manufacturer has a distinct visual language that survives at RTS
# zoom. The signature is a small set of greebles (the manufacturer's
# "kit-of-parts" stamp) that goes on top of the family shell. Same
# call site across all six families, so the greeble density is
# parameterised by (family, tonnage) - the scout tonnage gets the
# minimal signature, main gets the standard, heavy gets the full
# signature with extra details.
#
# Conventions, all from the HULL_REFRESH_PLAN Ã‚Â§4 manufacturer profiles:
#   - Meridian   : conservative engineering, lots of bolts, plate
#                  seams, exposed rivets, the "Marine Crocodile"
#                  overhang. A slight upper-superstructure overhang.
#   - Osterholm  : Bauhaus / industrial-design, hard 90 corners, no
#                  rivets on broad faces, thin panel lines on a
#                  1-unit grid, integrated pintle pad, no chamfered
#                  edges. Datums and roundel housings instead of
#                  rivet rows.
#   - Tidemark   : maritime-origin, low freeboard, slight sheer line,
#                  cleats and bollards on the deck, anchor stowed
#                  on the bow, ensign staff on the upper structure.
#                  Anti-fouling teal accent at the waterline.

def _meridian_signature(bm, hx, hy, hz, tonnage):
	"""Conservative engineering: rivet rows, exhaust stacks, turret ring, headlights."""
	rivet_count = {"scout": 4, "main": 6, "heavy": 8}[tonnage]
	exhaust_h = {"scout": 0.32, "main": 0.4, "heavy": 0.5}[tonnage]
	cupola = tonnage == "heavy"
	# Rivet rows along the upper deck (signature of "lots of bolts")
	greeble_rivet_row(bm, (-hx * 0.9, hy * 0.9, -hz * 0.6),
		(-hx * 0.9, hy * 0.9, hz * 0.6), rivet_count)
	greeble_rivet_row(bm, (hx * 0.9, hy * 0.9, -hz * 0.6),
		(hx * 0.9, hy * 0.9, hz * 0.6), rivet_count)
	# Upper-superstructure overhang: a slight Marine-Crocodile-style
	# extension past the lower tub.
	add_box(bm, (0, hy * 0.7, hz * 0.85), (hx * 1.05, hy * 0.18, hz * 0.22), bevel=0.02)
	# Exhaust stacks aft
	greeble_exhaust_stack(bm, (-hx * 0.7, hy * 0.6, hz * 0.92), radius=0.08, height=exhaust_h)
	if tonnage != "scout":
		greeble_exhaust_stack(bm, (-hx * 0.45, hy * 0.6, hz * 0.92), radius=0.07, height=exhaust_h * 0.8)
	# Turret ring on top
	if cupola:
		add_cyl_y(bm, (0, hy * 1.1, 0), 0.5, 0.16, segments=14)
		# Commander cupola (the heavy signature)
		add_cyl_y(bm, (0, hy * 1.3, 0), 0.28, 0.12, segments=12)
	else:
		add_cyl_y(bm, (0, hy * 1.05, 0), 0.4, 0.12, segments=12)
	# Headlight pair
	greeble_headlight_pair(bm, hx * 0.85, -hy * 0.2, -hz * 0.96, radius=0.08)
	# Hatch on the upper deck
	hatch_w = {"scout": 0.5, "main": 0.7, "heavy": 1.0}[tonnage]
	greeble_hatch(bm, (0, hy * 1.07, hz * 0.05), (hatch_w, 0.05, hatch_w * 0.6))
	# Antenna
	greeble_antenna(bm, (hx * 0.55, hy * 1.05, -hz * 0.3), height=0.25)


def _osterholm_signature(bm, hx, hy, hz, tonnage):
	"""Bauhaus / industrial-design: clean lines, integrated pad, no rivets,
	thin panel lines on a 1-unit grid, datum and roundel housings."""
	# No rivet rows. Instead, small roundel housings at the panel grid
	# intersection (4 fixed positions).
	for pos in (
		(-hx * 0.7, hy * 0.85, -hz * 0.5),
		(hx * 0.7, hy * 0.85, -hz * 0.5),
		(-hx * 0.7, hy * 0.85, hz * 0.5),
		(hx * 0.7, hy * 0.85, hz * 0.5),
	):
		add_cyl_y(bm, pos, 0.05, 0.05, segments=10)  # roundel housing
	# Thin panel line: a single shallow horizontal groove at 1/3 height
	# (per HULL_REFRESH_PLAN Ã‚Â§4 "datum-line etchings on the side").
	for x_sign in (-1, 1):
		add_box(bm, (x_sign * hx * 0.99, hy * 0.33, 0), (0.04, 0.01, hz * 0.95))
	# Integrated pintle pad (no turret ring - a clean integrated platform
	# per HULL_REFRESH_PLAN Ã‚Â§4 Osterholm cue).
	if tonnage == "heavy":
		add_cyl_y(bm, (0, hy * 1.05, 0), 0.55, 0.12, segments=14)
	else:
		add_cyl_y(bm, (0, hy * 1.04, 0), 0.4, 0.1, segments=12)
	# No exhaust stacks (cleaner). No toolboxes. No antennae.
	# A single sensor aperture at the bow.
	add_cyl_y(bm, (0, hy * 0.1, -hz * 0.99), 0.06, 0.04, segments=8)


def _tidemark_signature(bm, hx, hy, hz, tonnage):
	"""Maritime-origin: cleats and bollards on the deck, anchor on the bow,
	ensign staff on the upper structure. Anti-fouling teal accent."""
	# Cleats along the deck edge - 3 per side, evenly spaced
	for side in (-1, 1):
		for i in range(3):
			t = (i - 1) * 0.6  # -0.6, 0, 0.6
			pos = (side * hx * 0.99, hy * 0.92, hz * t)
			add_cyl_y(bm, pos, 0.04, 0.08, segments=8)  # bollard
	# Anchor stowed on the bow
	add_box(bm, (0, -hy * 0.4, -hz * 0.96), (hx * 0.4, hy * 0.4, 0.05))
	# Ensign staff on the upper structure
	greeble_antenna(bm, (0, hy * 1.05, hz * 0.4), height=0.45)
	# Teal anti-fouling accent: a thin strip at the waterline (hull
	# base) - drawn as a slightly oversized box that fuses with the
	# base, painted teal (color overridden via the hull color).
	for x_sign in (-1, 1):
		add_box(bm, (x_sign * hx * 0.99, -hy * 0.85, 0), (0.04, hy * 0.18, hz * 1.7))
	# Turret ring (Tidemark turrets are more open than Meridian)
	if tonnage == "heavy":
		add_cyl_y(bm, (0, hy * 1.0, 0), 0.5, 0.14, segments=14)
	else:
		add_cyl_y(bm, (0, hy * 1.0, 0), 0.4, 0.1, segments=12)


def _manufacturer_greebles(bm, hx, hy, hz, family, tonnage, manufacturer):
	"""Dispatcher: add the manufacturer-specific greebles on top of the
	family shell. Same call site across all six families."""
	# Color override for Tidemark (anti-fouling teal accent at the
	# waterline is part of the signature, but the hull is still the
	# family's base color).
	if manufacturer == "meridian":
		_meridian_signature(bm, hx, hy, hz, tonnage)
	elif manufacturer == "osterholm":
		_osterholm_signature(bm, hx, hy, hz, tonnage)
	elif manufacturer == "tidemark":
		_tidemark_signature(bm, hx, hy, hz, tonnage)


def _pillbox_greebles(bm, hx, hy, hz):
	# Backward-compat alias. The "outer-skin" greebles this used to
	# carry (sandbag fillets, antenna, rivet row) are dropped per
	# Chris's 2026-08-11 feedback - "drop the outer-skin treatment of
	# the hulls, shoot for clean geometric shapes." The bunker's
	# identity is now structural (the domed octagonal frustum + the
	# recessed embrasure), not surface treatment.
	pass


def _tower_greebles(bm, hx, hy, hz):
	# Backward-compat alias. The "outer-skin" greebles this used to
	# carry (machicolation ring, railing posts, antenna) are now part
	# of build_tower_hull itself - the stepped tiers ARE the tower's
	# signature, no extra layer is added on top of them. See
	# build_tower_hull for the structural elements.
	pass


# Foundation greebles - all dropped. Per Chris's 2026-08-11 feedback,
# the foundation catalogue is moving away from per-manufacturer surface
# treatment (rivet rows, panel-line grooves, anchor cleats, waterline
# stripes, antennae) and toward clean structural silhouettes - the
# bunker dome, the tower tiers, the rampart merlons, the battery
# pedestals. The "manufacturer" axis on foundations is now COLOR ONLY,
# not greeble pattern. The old _bunker_greebles_meridian/osterholm/
# tidemark/aa and per-tower / per-rampart / per-battery variants are
# removed in the PR-2-redo + PR-6 redo commit.


def _ship_hull_greebles(bm, hx, hy, hz):
	for side in (-1, 1):
		for i in range(4):
			t = (i + 0.5) / 4.0 - 0.5
			pos = (side * hx * 0.98, hy * 0.15, t * hz * 1.3)
			add_cyl_axis(bm, pos, 0.06, 0.05, 'x', segments=10)
	greeble_antenna(bm, (0, hy * 1.65, hz * 0.35), height=0.6)
	greeble_vent(bm, (0, hy * 1.05, -hz * 0.1), (0.3, 0.12, 0.5), slats=3)

	# Bespoke Tier 3 naval identity: naval_hull was the one ship hull with
	# no silhouette feature of its own beyond the shared bridge block -
	# small_boat_hull and heavy_cruiser_hull each already read distinctly
	# via their own greebles. A single raked funnel (just aft of the
	# bridge, slight outward flare at the cap) plus a foremast (just
	# forward of the bridge) is the classic mast-bridge-funnel silhouette
	# real mid-size warships read by, at real "massing" scale rather than
	# small surface detail.
	add_cyl_y(bm, (0, hy * 1.55, hz * 0.55), 0.22, hy * 1.1, segments=12, radius2=0.26)
	add_cyl_y(bm, (0, hy * 1.85, hz * 0.05), 0.045, hy * 1.7, segments=8)


def _small_boat_greebles(bm, hx, hy, hz):
	# Sparse - a fast patrol boat, not a warship draped in gear.
	greeble_antenna(bm, (0, hy * 1.5, hz * 0.4), height=0.4)
	greeble_spotlight(bm, (0, hy * 1.15, -hz * 0.5), radius=0.08)
	for side in (-1, 1):
		add_cyl_axis(bm, (side * hx * 0.97, hy * 0.1, hz * 0.5), 0.05, 0.04, 'x', segments=8)


def _heavy_cruiser_greebles(bm, hx, hy, hz):
	# A real warship silhouette: layered superstructure (now real base
	# massing via build_ship_hull's superstructure_tiers, not a hand-added
	# greeble box - the old "upper bridge deck" add_box here duplicated
	# what the tier stack now produces, so it was removed rather than
	# double-layering the same structure), twin funnels, gun deck
	# greebles, portholes - deliberately busier than naval_hull.
	greeble_exhaust_stack(bm, (-hx * 0.12, hy * 1.35, hz * 0.55), radius=0.18, height=0.7)
	greeble_exhaust_stack(bm, (hx * 0.12, hy * 1.35, hz * 0.55), radius=0.18, height=0.7)
	add_box(bm, (0, hy * 1.02, -hz * 0.55), (hx * 0.35, hy * 0.22, hz * 0.3), bevel=0.03)  # foredeck turret housing
	for side in (-1, 1):
		for i in range(6):
			t = (i + 0.5) / 6.0 - 0.5
			pos = (side * hx * 0.98, hy * 0.3, t * hz * 1.5)
			add_cyl_axis(bm, pos, 0.07, 0.05, 'x', segments=10)
	greeble_antenna(bm, (0, hy * 1.85, hz * 0.15), height=0.7)
	greeble_rivet_row(bm, (-hx * 0.9, hy * 1.0, -hz * 0.9), (-hx * 0.9, hy * 1.0, hz * 0.9), 8)
	greeble_rivet_row(bm, (hx * 0.9, hy * 1.0, -hz * 0.9), (hx * 0.9, hy * 1.0, hz * 0.9), 8)


def _fuselage_hull_greebles(bm, hx, hy, hz):
	# Real cockpit volume (see greeble_faired_canopy, introduced for
	# interceptor_hull's identical need) instead of a proud box bump -
	# height clamped to hy alone per the same extreme-stretch note.
	greeble_faired_canopy(bm, (0, hy * 0.28, -hz * 0.55), (hx * 0.16, hy * 0.14, hz * 0.28))
	greeble_vent(bm, (hx * 0.28, 0, -hz * 0.05), (0.1, 0.22, 0.3), slats=3)
	greeble_vent(bm, (-hx * 0.28, 0, -hz * 0.05), (0.1, 0.22, 0.3), slats=3)
	greeble_antenna(bm, (0, hy * 0.55, hz * 0.5), height=0.2)
	greeble_rivet_row(bm, (0, hy * 0.3, -hz * 0.75), (0, hy * 0.3, hz * 0.55), 8, axis='y')


def _airship_hull_greebles(bm, hx, hy, hz):
	greeble_antenna(bm, (0, hy * 0.3, -hz * 0.85), height=0.35)
	# Riding-off panel seams along the envelope, evenly spaced rings.
	for i in range(4):
		t = (i + 0.5) / 4.0 - 0.5
		add_cyl_axis(bm, (0, 0, t * hz * 1.2), min(hx, hy) * 1.01, 0.02, 'z', segments=18)


def _flying_wing_hull_greebles(bm, hx, hy, hz):
	# Faired canopy blister (greeble_faired_canopy, shared with
	# interceptor_hull/fuselage_hull) blended into the dorsal ridge
	# instead of a proud box bump - low/wide, height clamped to hy alone.
	greeble_faired_canopy(bm, (0, hy * 0.92, -hz * 0.3), (hx * 0.17, hy * 0.1, hz * 0.28))
	for side in (-1, 1):
		greeble_vent(bm, (side * hx * 0.55, hy * 0.5, hz * 0.6), (0.1, 0.25, 0.4), slats=3)
	greeble_antenna(bm, (0, hy * 0.9, hz * 0.6), height=0.16)


def _sponson_hull_greebles(bm, hx, hy, hz):
	greeble_headlight_pair(bm, hx * 0.55, -hy * 0.6, -hz * 0.97, radius=0.1)
	sp_z = hz * 0.4
	for side in (-1, 1):
		greeble_hatch(bm, (side * hx * 0.85, hy * 0.1, sp_z), (0.4, 0.05, 0.35))
	greeble_hatch(bm, (0, hy * 1.02, 0), (0.6, 0.06, 0.55))
	greeble_rivet_row(bm, (-hx * 0.9, -hy * 0.3, -hz * 0.85), (-hx * 0.9, -hy * 0.3, hz * 0.85), 6)
	greeble_rivet_row(bm, (hx * 0.9, -hy * 0.3, -hz * 0.85), (hx * 0.9, -hy * 0.3, hz * 0.85), 6)


def _wall_greebles(bm, hx, hy, hz):
	# Backward-compat alias. The "outer-skin" greebles this used to
	# carry (rivet row, antenna) are dropped per Chris's 2026-08-11
	# feedback. The rampart's identity is now structural (the
	# battered wall face + alternating merlons + recessed arrow
	# slits), not surface treatment.
	pass


def generate_hulls():
	"""RETIRED. The vehicle hull catalogue is built by
	tools/blender/build_vehicle_hulls.py, not by this module.

	This function used to emit the 6-family x 3-tonnage x 3-manufacturer
	matrix through _build_hull(), which authored via GV() (an axis SWAP,
	determinant -1) and then applied _hull_orient_matrix (also determinant
	-1) AFTER recalc_face_normals had already run. Two reflections cancel
	for vertex positions but not for winding, so every hull it produced
	shipped inside out - the near face invisible, the far interior visible.
	Measured in Godot: pod_heavy_osterholm's topmost face pointed DOWN,
	opposite to every asset that renders correctly. See
	scratch/hull_probe/ for the probe and the calibration table.

	Raises rather than no-ops: running --generate-hulls out of habit would
	overwrite 60 good .glb files with 30 broken ones, and a silent return
	would look like success.

	The foundations (bunker/tower/rampart/battery) are NOT affected - they
	come from generate_foundations(), which never used _build_hull.
	"""
	raise SystemExit(
		"generate_hulls() is retired - it produced inside-out meshes.\n"
		"Build the vehicle hull catalogue with:\n"
		"  blender --background --python tools/blender/build_vehicle_hulls.py\n"
		"Foundations and buildings still live here: use --generate-foundations\n"
		"or --generate-buildings."
	)


# ---------------------------------------------------------------------------
# Mark II hull generation - modernized variants with more aerodynamic,
# angled facets and oblique slopes (AFV/IFV/MBT styling)
# ---------------------------------------------------------------------------

def _scout_mk2_greebles(bm, hx, hy, hz):
    """Bare hull with angular boxy cheek armor blocks and driver casemate protrusion."""
    # Angular boxy cheek armor blocks
    for side in (-1, 1):
        add_box(bm, (side * hx * 0.88, 0, -hz * 0.3), (hx * 0.28, hy * 0.5, hz * 0.5), bevel=0.03)
    # Driver casemate protrusion block on upper deck
    add_box(bm, (0, hy * 0.8, -hz * 0.35), (hx * 0.45, hy * 0.22, hz * 0.4), bevel=0.03)


def _light_mk2_greebles(bm, hx, hy, hz):
    """Bare hull with blocky modular armor side cheek boxes and engine deck step."""
    # Blocky side cheek armor boxes
    for side in (-1, 1):
        for z_pos in (-hz * 0.3, hz * 0.1):
            add_box(bm, (side * hx * 0.9, -hy * 0.1, z_pos), (hx * 0.22, hy * 0.6, hz * 0.35), bevel=0.03)
    # Engine deck housing step
    add_box(bm, (0, hy * 0.65, hz * 0.45), (hx * 0.7, hy * 0.25, hz * 0.45), bevel=0.03)


def _medium_mk2_greebles(bm, hx, hy, hz):
    """Bare hull with bold boxy modular armor cheek blocks and side skirt slabs."""
    # Heavy composite armor cheek blocks (Abrams/Challenger wedge cheeks)
    for side in (-1, 1):
        add_box(bm, (side * hx * 0.85, hy * 0.1, -hz * 0.25), (hx * 0.3, hy * 0.7, hz * 0.6), bevel=0.04)
        add_box(bm, (side * hx * 0.92, -hy * 0.4, 0), (hx * 0.18, hy * 0.6, hz * 1.5), bevel=0.03)
    # Rear engine deck blocky step
    add_box(bm, (0, hy * 0.55, hz * 0.55), (hx * 0.75, hy * 0.3, hz * 0.4), bevel=0.03)


def _heavy_mk2_greebles(bm, hx, hy, hz):
    """Bare hull with extra-heavy boxy armor cheek slabs and turbine deck step."""
    # Extra-heavy boxy armor cheek slabs
    for side in (-1, 1):
        add_box(bm, (side * hx * 0.82, hy * 0.15, -hz * 0.2), (hx * 0.35, hy * 0.8, hz * 0.7), bevel=0.05)
        add_box(bm, (side * hx * 0.9, -hy * 0.45, 0), (hx * 0.2, hy * 0.7, hz * 1.7), bevel=0.04)
    # Large boxy turbine deck step
    add_box(bm, (0, hy * 0.5, hz * 0.5), (hx * 0.8, hy * 0.35, hz * 0.5), bevel=0.04)


def _transport_mk2_greebles(bm, hx, hy, hz):
    """Bare hull with modular side armor packs, cab roof riser, and troop ramp frame."""
    # Modular armor side packs
    for side in (-1, 1):
        for z_pos in (-hz * 0.3, hz * 0.1, hz * 0.45):
            add_box(bm, (side * hx * 0.88, 0, z_pos), (hx * 0.25, hy * 0.7, hz * 0.32), bevel=0.03)
    # Boxy roof driver cab riser
    add_box(bm, (0, hy * 0.7, -hz * 0.3), (hx * 0.75, hy * 0.28, hz * 0.5), bevel=0.03)
    # Boxy rear troop ramp frame protrusion
    add_box(bm, (0, -hy * 0.2, hz * 0.92), (hx * 0.75, hy * 0.6, 0.25), bevel=0.03)


def generate_mk2_hulls():
    print("--- Building Mark II hull library ---")

    # Scout Mk2: V-belly, sloped ends, bare hull with boxy protrusions
    export_and_cleanup(build_wedge_hull("scout_hull_mk2", 2.1, 1.1, 3.8,
        nose_frac=0.85, spine_w=0.25, spine_h=1.02, rear_flare=0.8, front_flare=0.35,
        nose_region=0.25, height_taper=0.35, bevel_pct=0.055, bevel_segments=1,
        waist_inset=0.04, waist_height_frac=0.45,
        panel_line_fracs=[0.3, 0.55],
        armor_front_frac=0.5,
        v_belly_depth=0.3, front_belly_slope=0.25, rear_belly_slope=0.22,
        color=(0.45, 0.5, 0.55), greebles=_scout_mk2_greebles), HULLS_DIR, "scout_hull_mk2")

    # Light Mk2: V-belly, sloped ends, bare hull with boxy protrusions
    export_and_cleanup(build_afv_hull("light_hull_mk2", 2.7, 1.6, 4.4,
        nose_frac=0.45, tub_frac=0.5, upper_w=0.75, glacis_len_frac=0.28,
        fender_frac=1.1, fender_height_frac=0.18,
        spine_w=0.45, spine_h=1.1,
        turret_ring=True,
        waist_inset=0.05, deck_line=0.06,
        panel_line_fracs=[0.25, 0.5],
        armor_front_frac=0.52,
        v_belly_depth=0.32, front_belly_slope=0.22, rear_belly_slope=0.22, rear_glacis_slope=0.15, lateral_slope_frac=0.18,
        color=(0.55, 0.58, 0.62), greebles=_light_mk2_greebles), HULLS_DIR, "light_hull_mk2")

    # Medium Mk2: V-belly, sloped ends, bare hull with boxy protrusions
    export_and_cleanup(build_afv_hull("medium_hull_mk2", 3.3, 2.0, 6.0,
        nose_frac=0.35, tub_frac=0.55, upper_w=0.7, glacis_len_frac=0.25,
        fender_frac=1.12, fender_height_frac=0.22,
        spine_w=0.65, spine_h=1.15,
        turret_ring=True,
        waist_inset=0.06, deck_line=0.08,
        panel_line_fracs=[0.22, 0.45, 0.68],
        armor_front_frac=0.55,
        v_belly_depth=0.36, front_belly_slope=0.25, rear_belly_slope=0.25, rear_glacis_slope=0.18, lateral_slope_frac=0.22,
        color=(0.6, 0.63, 0.67), greebles=_medium_mk2_greebles), HULLS_DIR, "medium_hull_mk2")

    # Heavy Mk2: V-belly, sloped ends, bare hull with boxy protrusions
    export_and_cleanup(build_afv_hull("heavy_hull_mk2", 4.4, 2.8, 8.8,
        nose_frac=0.28, tub_frac=0.6, upper_w=0.68, glacis_len_frac=0.2,
        fender_frac=1.15, fender_height_frac=0.28,
        spine_w=0.7, spine_h=1.2,
        turret_ring=True,
        waist_inset=0.07, deck_line=0.1,
        panel_line_fracs=[0.2, 0.42, 0.65, 0.82],
        armor_front_frac=0.58,
        v_belly_depth=0.4, front_belly_slope=0.28, rear_belly_slope=0.28, rear_glacis_slope=0.2, lateral_slope_frac=0.25,
        color=(0.5, 0.52, 0.55), greebles=_heavy_mk2_greebles), HULLS_DIR, "heavy_hull_mk2")

    # Transport Mk2: Deep V-belly, sloped ends, bare hull with boxy protrusions
    export_and_cleanup(build_afv_hull("transport_hull_mk2", 3.5, 2.4, 7.7,
        nose_frac=0.4, tub_frac=0.55, upper_w=0.72, glacis_len_frac=0.32,
        fender_frac=1.08, fender_height_frac=0.2,
        spine_w=0.55, spine_h=1.12,
        turret_ring=False,
        waist_inset=0.05, deck_line=0.06,
        panel_line_fracs=[0.28, 0.55],
        armor_front_frac=0.5,
        v_belly_depth=0.45, front_belly_slope=0.3, rear_belly_slope=0.25, rear_glacis_slope=0.15, lateral_slope_frac=0.2,
        color=(0.52, 0.56, 0.6), greebles=_transport_mk2_greebles), HULLS_DIR, "transport_hull_mk2")

    print("--- Mark II hull library done ---")


def generate_foundations():
	"""Foundation catalogue (HULL_REFRESH_PLAN Â§5.7) - 13 hulls across
	4 families.

	Family:      Manufacturer variants:        Total:
	  Bunker     meridian / osterholm /         4
	             tidemark / reserve (AA)
	  Tower      meridian / osterholm /         3
	             tidemark
	  Rampart    meridian / osterholm /         3
	             tidemark
	  Battery    meridian / osterholm /         3  (NEW family)
	             tidemark

	PR-6 redo (2026-08-11): per Chris's 2026-08-11 feedback ("Extend
	this to the foundation hulls as well"), the per-manufacturer
	greeble layer (rivet rows, panel-line grooves, anchor cleats +
	waterline stripes, antenna, sandbag corner fillets) is DROPPED.
	Foundations are now structurally distinct silhouettes that
	differ ONLY in paint color across manufacturers:

	  bunker  - octagonal frustum + domed cap + recessed embrasure
	  tower   - stepped tier stack + machicolation ring + railings
	  rampart - battered wall face + alternating merlons + arrow slits
	  battery - truncated pyramid base + N weapon-mount pedestals (NEW)

	The structural elements (dome, tiers, merlons, slits, pedestals)
	are built into the family builders themselves (build_bunker_hull,
	build_tower_hull, build_wall_hull, build_battery_hull), not
	added as a separate greeble layer. The tier-1 bevel handles the
	chamfer; no rivet rows, no panel lines, no antenna clutter.
	"""
	print("--- Building foundation library (13 hulls across 4 families) ---")

	# Per-family footprint (size_x, size_y, size_z). Tuned to read
	# distinctly at RTS zoom: bunker is short-and-wide (the tight
	# fighting compartment), tower is tall-and-narrow (over-watch),
	# rampart is long-and-low (tileable wall), battery is wide-and-flat
	# (open platform). The "short" / "tall" / "long" / "flat" axis
	# arrangement is what makes the four families readable as different
	# roles rather than "same thing, different greebles."
	FOUNDATION_SIZES = {
		"bunker":  (3.0, 2.0, 3.0),   # short + wide
		"tower":   (3.0, 5.0, 3.0),   # tall + narrow
		"rampart": (4.0, 3.0, 4.0),   # long + low
		"battery": (4.5, 1.5, 4.5),   # wide + flat (NEW)
	}

	# Per-(family, manufacturer) base color. Each manufacturer gets a
	# subtle hue shift on top of the family's base color (lighter for
	# Osterholm prefab concrete, warmer for Tidemark maritime, etc.).
	# Color is the ONLY manufacturer differentiator on foundations now.
	FOUNDATION_COLORS = {
		"bunker": {
			"meridian":  (0.45, 0.45, 0.4),
			"osterholm": (0.78, 0.78, 0.74),  # prefab concrete grey
			"tidemark":  (0.55, 0.48, 0.38),  # sandstone + maritime
			"aa":        (0.40, 0.40, 0.36),  # reserve / AA bunker
		},
		"tower": {
			"meridian":  (0.5, 0.48, 0.44),
			"osterholm": (0.82, 0.82, 0.78),
			"tidemark":  (0.58, 0.52, 0.42),
		},
		"rampart": {
			"meridian":  (0.42, 0.40, 0.36),
			"osterholm": (0.78, 0.76, 0.72),
			"tidemark":  (0.52, 0.46, 0.38),
		},
		"battery": {
			"meridian":  (0.40, 0.40, 0.36),
			"osterholm": (0.80, 0.80, 0.76),
			"tidemark":  (0.54, 0.48, 0.40),
		},
	}

	# Per-(family, manufacturer) gameplay stats. Tuned against the
	# existing 3 foundation values (pillbox 800/80/0/60/4.8/16,
	# tower 1400/160/20/100/8.0/28, fortress_wall 1100/140/10/70/5.6/14)
	# so the new variants read as natural extensions of the same curve
	# rather than a rebalance. Per-foundation values scaled from these
	# by family role (tower = highest HP+vision, bunker = tightest
	# footprint, rampart = middle, battery = cheapest, most mounts).
	FOUNDATION_STATS = {
		("bunker", "meridian"):  dict(hp=800,  metal=80,  crystal=0,  base_energy=60,  base_power=4.8, base_vision=16),
		("bunker", "osterholm"): dict(hp=900,  metal=100, crystal=0,  base_energy=60,  base_power=4.8, base_vision=14),  # thicker
		("bunker", "tidemark"):  dict(hp=850,  metal=110, crystal=5,  base_energy=55,  base_power=4.5, base_vision=16),  # marine fittings
		("bunker", "aa"):        dict(hp=600,  metal=70,  crystal=20, base_energy=50,  base_power=4.0, base_vision=24),  # AA = highest vision
		("tower",  "meridian"):  dict(hp=1400, metal=160, crystal=20, base_energy=100, base_power=8.0, base_vision=28),
		("tower",  "osterholm"): dict(hp=1500, metal=180, crystal=20, base_energy=100, base_power=8.0, base_vision=30),
		("tower",  "tidemark"):  dict(hp=1450, metal=190, crystal=25, base_energy=95,  base_power=7.5, base_vision=28),
		("rampart", "meridian"): dict(hp=1100, metal=140, crystal=10, base_energy=70,  base_power=5.6, base_vision=14),
		("rampart", "osterholm"):dict(hp=1200, metal=160, crystal=10, base_energy=70,  base_power=5.6, base_vision=12),  # taller merlons
		("rampart", "tidemark"): dict(hp=1150, metal=170, crystal=15, base_energy=65,  base_power=5.4, base_vision=14),
		("battery", "meridian"): dict(hp=700,  metal=120, crystal=10, base_energy=80,  base_power=6.4, base_vision=18),
		("battery", "osterholm"):dict(hp=800,  metal=140, crystal=10, base_energy=80,  base_power=6.4, base_vision=16),
		("battery", "tidemark"): dict(hp=750,  metal=150, crystal=15, base_energy=75,  base_power=6.0, base_vision=18),
	}

	# Manufacturer title-case for the display name field. "aa" -> "Aa"
	# reads fine in the design lab; it's a role-based 4th bunker.
	def mfr_title(mfr):
		return "Aa" if mfr == "aa" else mfr.capitalize()

	foundation_count = 0

	# --- BUNKER (4 variants) ---
	# The bunker is an octagonal frustum + domed cap (built into
	# build_bunker_hull) + optional recessed embrasure on the front
	# wall. The embrasure is structural (it's a real cut in the
	# silhouette, not a proud greeble), so it stays. The 3 manufacturer
	# variants get an embrasure; the AA reserve does NOT (the AA's
	# autocannon pedestal is the firing position, not a slit in the
	# wall - keeping the silhouette clean lets the pedestal read as
	# the silhouette's focal point).
	for mfr in ("meridian", "osterholm", "tidemark", "aa"):
		hull_id = "bunker_main_%s" % mfr
		sx, sy, sz = FOUNDATION_SIZES["bunker"]
		color = FOUNDATION_COLORS["bunker"][mfr] + (1.0,)
		hx, hy, hz = sx / 2.0, sy / 2.0, sz / 2.0
		embrasure = {"center": (0, 0, hz * 0.95), "size": (hx * 0.3, hy * 0.25),
			"depth_frac": 0.08} if mfr != "aa" else None
		# greebles=None: structural shape only, no surface treatment.
		obj = build_bunker_hull(hull_id, sx, sy, sz,
			color=color[:3], greebles=None, embrasure=embrasure)
		stats = FOUNDATION_STATS[("bunker", mfr)]
		export_hull_with_sidecar(obj, HULLS_DIR, hull_id,
			size=(sx, sy, sz), color=color, domain="Static Defense",
			name="Bunker Main %s" % mfr_title(mfr),
			hp=stats["hp"], weight=0.0, metal=stats["metal"], crystal=stats["crystal"],
			base_energy=stats["base_energy"], base_vision=stats["base_vision"],
			base_power=stats["base_power"], is_foundation=True, category="hull")
		foundation_count += 1

	# --- TOWER (3 variants) ---
	# The tower is a stepped tier stack + corbelled machicolation ring
	# + rooftop railings + antenna (all built into build_tower_hull).
	# These are STRUCTURAL elements (a tower without railings reads as
	# a stepped pyramid, not a tower), so they stay. The 3 manufacturer
	# variants use the same builder, differing only in paint color.
	for mfr in ("meridian", "osterholm", "tidemark"):
		hull_id = "tower_main_%s" % mfr
		sx, sy, sz = FOUNDATION_SIZES["tower"]
		color = FOUNDATION_COLORS["tower"][mfr] + (1.0,)
		# greebles=None: structural shape only.
		obj = build_tower_hull(hull_id, sx, sy, sz, color=color[:3], greebles=None)
		stats = FOUNDATION_STATS[("tower", mfr)]
		export_hull_with_sidecar(obj, HULLS_DIR, hull_id,
			size=(sx, sy, sz), color=color, domain="Static Defense",
			name="Tower Main %s" % mfr_title(mfr),
			hp=stats["hp"], weight=0.0, metal=stats["metal"], crystal=stats["crystal"],
			base_energy=stats["base_energy"], base_vision=stats["base_vision"],
			base_power=stats["base_power"], is_foundation=True, category="hull")
		foundation_count += 1

	# --- RAMPART (3 variants) ---
	# The rampart is a battered (wider-at-base) wall face + 5
	# alternating merlons + 3 recessed arrow slits, all built into
	# build_wall_hull. The slits are a real cut in the silhouette,
	# not a proud greeble. 3 manufacturer variants, color only.
	for mfr in ("meridian", "osterholm", "tidemark"):
		hull_id = "rampart_main_%s" % mfr
		sx, sy, sz = FOUNDATION_SIZES["rampart"]
		color = FOUNDATION_COLORS["rampart"][mfr] + (1.0,)
		# greebles=None, arrow_slit_count=3 for the structural slits.
		obj = build_wall_hull(hull_id, sx, sy, sz, merlons=5,
			color=color[:3], greebles=None, arrow_slit_count=3)
		stats = FOUNDATION_STATS[("rampart", mfr)]
		export_hull_with_sidecar(obj, HULLS_DIR, hull_id,
			size=(sx, sy, sz), color=color, domain="Static Defense",
			name="Rampart Main %s" % mfr_title(mfr),
			hp=stats["hp"], weight=0.0, metal=stats["metal"], crystal=stats["crystal"],
			base_energy=stats["base_energy"], base_vision=stats["base_vision"],
			base_power=stats["base_power"], is_foundation=True, category="hull")
		foundation_count += 1

	# --- BATTERY (3 variants) - NEW family ---
	# The battery is a truncated pyramid base + N weapon-mount
	# pedestals on top (built into build_battery_hull). 2 pedestals
	# for the classic twin-gun battery, 3 for the spread-out
	# fire-base. Meridian gets 2 (tight, low, defensive); Osterholm
	# and Tidemark get 3 (open, modular).
	for mfr in ("meridian", "osterholm", "tidemark"):
		hull_id = "battery_main_%s" % mfr
		sx, sy, sz = FOUNDATION_SIZES["battery"]
		color = FOUNDATION_COLORS["battery"][mfr] + (1.0,)
		mounts = 2 if mfr == "meridian" else 3
		# greebles=None: structural shape only.
		obj = build_battery_hull(hull_id, sx, sy, sz, mounts=mounts,
			color=color[:3], greebles=None)
		stats = FOUNDATION_STATS[("battery", mfr)]
		export_hull_with_sidecar(obj, HULLS_DIR, hull_id,
			size=(sx, sy, sz), color=color, domain="Static Defense",
			name="Battery Main %s" % mfr_title(mfr),
			hp=stats["hp"], weight=0.0, metal=stats["metal"], crystal=stats["crystal"],
			base_energy=stats["base_energy"], base_vision=stats["base_vision"],
			base_power=stats["base_power"], is_foundation=True, category="hull")
		foundation_count += 1

	print("--- Generated %d foundation hulls ---" % foundation_count)
	print("--- Foundation library done ---")


def generate_buildings():
	"""Building catalogue (HULL_REFRESH_PLAN Â§7).

	1 base mesh + 9 greeble sets. The base is shared across all 9
	C&C pre-fab buildings (hq, refinery, light/medium/heavy
	manufactory, power_plant, tech/physics/exotics lab). The
	greebles differentiate the function (chimney for the power
	plant, comm dish for the HQ, glass dome for the tech lab, etc.).

	Will be implemented in PR 7. Placeholder for now.
	"""
	print("--- Building library: TBD in PR 7 ---")
	pass


def parse_args():
	import sys
	argv = sys.argv
	if "--" in argv:
		argv = argv[argv.index("--") + 1:]
	else:
		argv = []
	return {
		"generate_hulls": "--generate-hulls" in argv,
		"generate_foundations": "--generate-foundations" in argv,
		"generate_buildings": "--generate-buildings" in argv,
		"generate_mk2": "--generate-mk2" in argv,
	}


if __name__ == "__main__":
    args = parse_args()
    clear_scene()
    generate_parts()
    if args["generate_mk2"]:
        # Legacy: tier 1/2 military-typology hulls (scout_hull_mk2 etc.).
        # Retired in PR 1 of the hull refresh; the flag is kept for
        # one regeneration cycle so the GLBs can be re-baked if
        # someone reverts PR 1. Will be removed in PR 8.
        generate_mk2_hulls()
    if args["generate_hulls"]:
        generate_hulls()
    if args["generate_foundations"]:
        generate_foundations()
    if args["generate_buildings"]:
        generate_buildings()
