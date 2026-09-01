extends RefCounted
class_name NavCoverage
# EXACT "is this world point on the nav surface" for probes.
#
# The obvious cheap version - bucket the vertices and ask whether any landed
# near the sample point - is WRONG in a way that silently inverts results, and
# it did on 2026-09-01. A coarse 5.8 m nav quad contributes 4 vertices; the
# same area subdivided to 1 m contributes ~50. Bucket-by-vertex therefore
# reports subdivided regions as far better covered than coarse ones regardless
# of where the polygons actually are, so a change that carved a river out of
# the navmesh read as a change that added ground to it. Three maps appeared to
# regress purely from this.
#
# So: real point-in-triangle in XZ, over the triangle soup TerrainBuilder's
# _build_*_faces() return (_add_nav_quad appends two triangles, 3 verts each),
# with the triangles bucketed by their XZ bounding box so a lookup touches a
# handful rather than ~100k.

const BUCKET := 8.0

var _buckets: Dictionary = {}
var _tris: PackedVector3Array


func _init(verts: PackedVector3Array) -> void:
	_tris = verts
	var n: int = verts.size() / 3
	for t in range(n):
		var a := verts[t * 3]
		var b := verts[t * 3 + 1]
		var c := verts[t * 3 + 2]
		var x0: int = int(floor(minf(a.x, minf(b.x, c.x)) / BUCKET))
		var x1: int = int(floor(maxf(a.x, maxf(b.x, c.x)) / BUCKET))
		var z0: int = int(floor(minf(a.z, minf(b.z, c.z)) / BUCKET))
		var z1: int = int(floor(maxf(a.z, maxf(b.z, c.z)) / BUCKET))
		for bx in range(x0, x1 + 1):
			for bz in range(z0, z1 + 1):
				var k := Vector2i(bx, bz)
				if not _buckets.has(k):
					_buckets[k] = PackedInt32Array()
				_buckets[k].append(t)


func triangle_count() -> int:
	return _tris.size() / 3


func covers(x: float, z: float) -> bool:
	var k := Vector2i(int(floor(x / BUCKET)), int(floor(z / BUCKET)))
	if not _buckets.has(k):
		return false
	var p := Vector2(x, z)
	for t in _buckets[k]:
		var a := _tris[t * 3]
		var b := _tris[t * 3 + 1]
		var c := _tris[t * 3 + 2]
		if _inside(p, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
			return true
	return false


# Sign-of-cross-product test. Tolerant of either winding, because the two
# _build_*_faces() paths do not agree on it and a probe is not the place to
# care.
static func _inside(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (p - a).cross(b - a)
	var d2 := (p - b).cross(c - b)
	var d3 := (p - c).cross(a - c)
	var has_neg: bool = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos: bool = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)
