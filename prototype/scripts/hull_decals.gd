extends RefCounted
class_name HullDecals
# Shared decal/stencil atlas (VISUAL_ART_DIRECTION.md 1.4): hazard chevrons,
# serial stencils, and a small per-faction mascot/insignia icon, one shared
# library re-tinted per faction's decal_tint (== detail_color) - applies to
# ALL 10 factions uniformly (unlike hull_greebles.gd's 5-faction silhouette-
# extending exception), sized to stay genuinely detail-scale, never
# competing with the silhouette.
#
# Same procedural-at-runtime approach that worked well for the greeble
# cards: every shape (including the stencil serial NUMBER's digits, and
# every mascot icon) is drawn into a small Image via plain pixel math and
# cached, not a hand-painted asset - zero new dependency on this week's
# fragile Blender import pipeline, and it means a "stencil" font that's
# blocky/gapped by construction, which is genuinely what a real cut stencil
# looks like, not just a workaround.
#
# Mascot icons are deliberately simplified to plain geometric crests (gear,
# hexagon, star/sunburst, snowflake, diamond, cross, blade, lens/leaf) -
# NOT detailed illustrated mascot creatures, which would need real
# hand-authored art quality no pixel-math function can reasonably fake.
# Chris's own framing invited exactly this call. See DECISIONS_NEEDED.md.

const LiveryScript = preload("res://scripts/livery.gd")
const HullProjectionScript = preload("res://scripts/hull_projection.gd")

const DECAL_TEXTURE_SIZE: int = 256
static var _texture_cache: Dictionary = {}

static func _get_texture(key: String, draw_fn: Callable) -> ImageTexture:
	if _texture_cache.has(key):
		return _texture_cache[key]
	var img = Image.create(DECAL_TEXTURE_SIZE, DECAL_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	draw_fn.call(img)
	var tex = ImageTexture.create_from_image(img)
	_texture_cache[key] = tex
	return tex

# --- Hazard stripe pattern (diagonal alternating chevrons) ---
static func _draw_hazard(img: Image):
	var n = img.get_width()
	var stripe_freq = 6.0
	for x in range(n):
		for y in range(n):
			var u = float(x) / n
			var v = float(y) / n
			var band = fposmod((u + v) * stripe_freq, 2.0)
			if band < 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# --- Tiny 3x5 stencil pixel-font, digits 0-9 (a real cut stencil is
# blocky/gapped, so a coarse pixel font is thematically correct, not just
# an approximation) ---
const DIGIT_FONT = {
	"0": ["111", "101", "101", "101", "111"],
	"1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"],
	"3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"],
	"5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"],
	"7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"],
	"9": ["111", "101", "111", "001", "111"],
}

static func _draw_serial(img: Image, serial: String):
	var scale = 16
	var digit_w = 3 * scale
	var digit_h = 5 * scale
	var gap = 8
	var total_w = serial.length() * digit_w + (serial.length() - 1) * gap
	var start_x = (img.get_width() - total_w) / 2
	var start_y = (img.get_height() - digit_h) / 2
	for i in range(serial.length()):
		var glyph = DIGIT_FONT.get(serial[i], DIGIT_FONT["0"])
		var ox = start_x + i * (digit_w + gap)
		for row in range(5):
			for col in range(3):
				if glyph[row][col] == "1":
					for py in range(scale):
						for px in range(scale):
							img.set_pixel(ox + col * scale + px, start_y + row * scale + py, Color(1, 1, 1, 1))

static func _get_faction_serial(faction: String) -> String:
	return str(100 + (hash(faction) % 900))

# --- Mascot/insignia icons - plain geometric crests, not illustrated
# mascots (see file header) ---
static func _draw_gear(img: Image):
	var n = img.get_width()
	var teeth = 8
	var base_r = 0.27
	var tooth_r = 0.38
	var hub_r = 0.1
	for x in range(n):
		for y in range(n):
			var dx = float(x) / n - 0.5
			var dy = float(y) / n - 0.5
			var r = sqrt(dx * dx + dy * dy)
			var angle = atan2(dy, dx)
			var r_at_angle = base_r if cos(angle * teeth) < 0.25 else tooth_r
			if r <= r_at_angle and r >= hub_r:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

static func _draw_hex(img: Image):
	var n = img.get_width()
	var radius = 0.36
	var dirs = []
	for i in range(6):
		var a = i * PI / 3.0
		dirs.append(Vector2(cos(a), sin(a)))
	for x in range(n):
		for y in range(n):
			var dx = float(x) / n - 0.5
			var dy = float(y) / n - 0.5
			var p = Vector2(dx, dy)
			var inside = true
			for d in dirs:
				if p.dot(d) > radius:
					inside = false
					break
			if inside:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# Configurable pointed star - reused for Expansionists' compass star,
# Dune Runners' thin sunburst, and Aerodrome Cartel's thick propeller.
static func _draw_star(img: Image, points: int, outer_r: float, inner_ratio: float):
	var n = img.get_width()
	var seg = TAU / points
	for x in range(n):
		for y in range(n):
			var dx = float(x) / n - 0.5
			var dy = float(y) / n - 0.5
			var r = sqrt(dx * dx + dy * dy)
			var angle = atan2(dy, dx)
			if angle < 0.0: angle += TAU
			var local_angle = fmod(angle, seg) - seg / 2.0
			var t = abs(local_angle) / (seg / 2.0)
			var r_at_angle = lerp(outer_r, outer_r * inner_ratio, t)
			if r <= r_at_angle:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

static func _draw_diamond(img: Image):
	var n = img.get_width()
	var radius = 0.38
	for x in range(n):
		for y in range(n):
			var dx = abs(float(x) / n - 0.5)
			var dy = abs(float(y) / n - 0.5)
			if dx + dy <= radius:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

static func _draw_cross(img: Image):
	var n = img.get_width()
	var half_thick = 0.09
	var radius = 0.38
	for x in range(n):
		for y in range(n):
			var dx = float(x) / n - 0.5
			var dy = float(y) / n - 0.5
			var r = sqrt(dx * dx + dy * dy)
			if r <= radius and (abs(dx) <= half_thick or abs(dy) <= half_thick):
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# A blade with a crossguard - Crimson Concordat's trophy-spike motif.
static func _draw_blade(img: Image):
	var n = img.get_width()
	for x in range(n):
		for y in range(n):
			var u = float(x) / n
			var v = float(y) / n
			var filled = false
			if v <= 0.65:
				var half_width = 0.05 + (0.65 - v) * 0.12
				filled = abs(u - 0.5) <= half_width
			elif v <= 0.78:
				filled = abs(u - 0.5) <= 0.3
			else:
				filled = abs(u - 0.5) <= 0.05
			if filled:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# A lens/leaf shape (vesica piscis - two overlapping circles) - Bayou
# Irregulars' insignia.
static func _draw_leaf(img: Image):
	var n = img.get_width()
	var r = 0.32
	var offset = 0.22
	var a = Vector2(0.5 - offset, 0.5)
	var b = Vector2(0.5 + offset, 0.5)
	for x in range(n):
		for y in range(n):
			var p = Vector2(float(x) / n, float(y) / n)
			if p.distance_to(a) <= r and p.distance_to(b) <= r:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# Solid filled disc - the dark badge backing plate behind the mascot icon
# (Chris's reference sprites: "a star icon in a dark circle," a bold
# graphic badge, not a bare colored silhouette floating on nothing).
static func _draw_circle_badge(img: Image):
	var n = img.get_width()
	var radius = 0.46
	for x in range(n):
		for y in range(n):
			var dx = float(x) / n - 0.5
			var dy = float(y) / n - 0.5
			if sqrt(dx * dx + dy * dy) <= radius:
				img.set_pixel(x, y, Color(1, 1, 1, 1))

# The ten shapes were keyed by faction id. With the factions gone (see
# livery.gd) that dictionary would have matched nothing and every construct in
# the game would have worn the "gear" default - the same insignia for the
# player and every AI team, which is the one thing an insignia must not do.
#
# Picked by hash of the livery id instead, so the whole library stays in use,
# a given id always gets the same badge (an enemy team's marking is stable for
# the match, exactly like its colours), and two different ids reliably differ.
const MASCOT_SHAPES: Array = [
	"gear", "hex", "star_compass", "cross", "blade",
	"star_snowflake", "star_sunburst", "diamond", "leaf", "star_propeller",
]

static func _get_mascot_texture(faction: String) -> ImageTexture:
	var shape: String = ""
	if faction != "":
		shape = LiveryScript.decal_icon(faction)
	if shape == "" or not MASCOT_SHAPES.has(shape):
		shape = MASCOT_SHAPES[abs(hash(faction)) % MASCOT_SHAPES.size()]
	match shape:
		"gear": return _get_texture("mascot_gear", _draw_gear)
		"hex": return _get_texture("mascot_hex", _draw_hex)
		"diamond": return _get_texture("mascot_diamond", _draw_diamond)
		"cross": return _get_texture("mascot_cross", _draw_cross)
		"blade": return _get_texture("mascot_blade", _draw_blade)
		"leaf": return _get_texture("mascot_leaf", _draw_leaf)
		"star_compass": return _get_texture("mascot_star_compass", func(img): _draw_star(img, 5, 0.4, 0.4))
		"star_snowflake": return _get_texture("mascot_star_snowflake", func(img): _draw_star(img, 6, 0.42, 0.18))
		"star_sunburst": return _get_texture("mascot_star_sunburst", func(img): _draw_star(img, 8, 0.42, 0.15))
		"star_propeller": return _get_texture("mascot_star_propeller", func(img): _draw_star(img, 3, 0.4, 0.55))
		_: return _get_texture("mascot_gear", _draw_gear)

static var _decal_material_cache: Dictionary = {}

static func _make_decal_material(texture: Texture2D, color: Color) -> StandardMaterial3D:
	var key := "%d_%d" % [texture.get_instance_id() if texture else 0, color.to_rgba32()]
	if _decal_material_cache.has(key):
		return _decal_material_cache[key]
	var mat = StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.6
	# Nearest-neighbor, not the default linear filter - these decals are
	# small on-screen and linear filtering was blurring the alpha-cutout
	# edge into a soft blob (especially the stencil serial digits and the
	# smaller mascot icons), the opposite of the crisp, blocky "real cut
	# stencil" look this whole system is going for.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_decal_material_cache[key] = mat
	return mat

# Surface-projected placement (hull_projection.gd): the caller says roughly
# where on the hull it wants the decal, in normalized AABB coordinates, plus
# which face to approach from - and the decal lands on the hull's ACTUAL skin,
# rotated to match that skin's normal. Replaces the previous hardcoded
# "fraction of the declared catalog box" positions, which floated off every
# hull that is not a literal box (and, because the roof sits at 0.5 * size.y
# while the code used 0.62, off the boxes too).
static func _project_decal(container: Node3D, surface: Dictionary, texture: Texture2D,
		color: Color, size: Vector2, anchor: Vector3, axis: Vector3, lift: float = 0.0):
	var hit = HullProjectionScript.project(surface, anchor, axis)
	var card = MeshInstance3D.new()
	var quad = QuadMesh.new()
	quad.size = size
	card.mesh = quad
	card.material_override = _make_decal_material(texture, color)
	container.add_child(card)
	var normal: Vector3 = hit["normal"]
	var pos: Vector3 = hit["position"] + normal * lift
	card.position = pos * surface.get("position_scale", Vector3.ONE)
	card.basis = hit["basis"]
	return card

# Removes any previously-attached decals (so faction changes in the Design
# Lab don't accumulate duplicates) and rebuilds - every faction gets
# decals (universal library), unlike hull_greebles.gd's 5-faction
# exclusivity.
static func apply_decals(hull: Node3D, faction: String, hull_size: Vector3):
	var old = hull.get_node_or_null("HullDecals")
	if old:
		hull.remove_child(old)
		old.queue_free()
	var container = Node3D.new()
	container.name = "HullDecals"
	hull.add_child(container)

	# Real mesh extents, not the declared catalog box. Sizing off the actual
	# skin matters as much as positioning does: a CSG-baked hull is often
	# noticeably narrower than its catalog size, so a stripe sized to the box
	# overhung the panel it was supposed to be stencilled on.
	var surface = HullProjectionScript.build_surface(hull)
	var comp = HullProjectionScript.attach_compensation(hull)
	container.scale = comp["container_scale"]
	surface["position_scale"] = comp["position_scale"]
	var extents: Vector3 = hull_size
	if surface["tris"].size() >= 3:
		extents = (surface["aabb"] as AABB).size
	else:
		surface["aabb"] = AABB(-hull_size * 0.5, hull_size)

	var tint = LiveryScript.zone_color(faction, "hull_stripe")
	var hazard_tex = _get_texture("hazard", _draw_hazard)

	# 2 hazard-stripe strips near the top edge of the tail panel
	if LiveryScript.decal_show_hazard(faction):
		var stripe_size = Vector2(extents.x * 0.18, extents.y * 0.16)
		for side in [-1.0, 1.0]:
			_project_decal(container, surface, hazard_tex, tint, stripe_size,
				Vector3(0.5 + side * 0.18, 0.78, 1.0), Vector3.BACK)

	# 1 stencil serial number on the starboard flank
	var serial = LiveryScript.decal_serial(faction)
	if serial == "":
		serial = _get_faction_serial(faction)
	var serial_tex = _get_texture("serial_%s" % serial, func(img): _draw_serial(img, serial))
	_project_decal(container, surface, serial_tex, tint,
		Vector2(extents.z * 0.32, extents.y * 0.14),
		Vector3(1.0, 0.6, 0.6), Vector3.RIGHT)

	# 1 mascot/insignia icon on roof
	var mascot_tex = _get_mascot_texture(faction)
	var mascot_span: float = min(extents.x, extents.z) * 0.22
	var mascot_size = Vector2(mascot_span, mascot_span)
	var mascot_anchor := Vector3(0.5, 1.0, 0.58)

	var badge_style = LiveryScript.decal_badge(faction)
	if badge_style != "none":
		var badge_tex = _get_texture("circle_badge", _draw_circle_badge)
		var badge_size = mascot_size * 1.4
		_project_decal(container, surface, badge_tex, Color(0.07, 0.07, 0.08), badge_size,
			mascot_anchor, Vector3.UP)

	_project_decal(container, surface, mascot_tex, tint, mascot_size,
		mascot_anchor, Vector3.UP, mascot_span * 0.02)
