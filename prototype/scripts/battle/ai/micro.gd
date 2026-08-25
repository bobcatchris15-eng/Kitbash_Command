class_name Micro
extends RefCounted
# Per-unit tactical behaviors applied within a squad's ENGAGING state.
#
# WHAT THIS IS. The squad decides WHO to fight and WHEN to retreat. Micro
# decides HOW each individual unit fights, based on its own design's strengths.
# A fast sniper kites. A brawler closes. A flanker circles around directional
# armor. None of this changes the squad's intent — it only adjusts how units
# execute that intent.
#
# WHY DESIGN-DEPENDENT. The game's core promise is that unit design matters.
# If every unit fights identically (stand at 0.85× range, shoot), then the
# Design Lab is cosmetic. Micro makes the player's design choices visible in
# combat: a fast long-range hover plays differently from a slow heavy tank,
# and the AI exploits those differences the same way a human would.
#
# EXPLOITABLE PATTERNS. Each behavior creates a counter the player can learn:
#   - Kiting → close with faster units, or use indirect fire
#   - Flanking → rotate to face the attacker, or use turret weapons
#   - Peeling → bait the peel, then re-engage the now-exposed support
#   - Terrain seeking → indirect fire ignores elevation; flank the hill
#
# WHEN THIS RUNS. Only during Squad.State.ENGAGING. Advancing and retreating
# units follow the squad's orders without micro adjustments, keeping the AI
# readable — a retreating squad is retreating, full stop.

const ThreatAnalyzerScript = preload("res://scripts/battle/ai/threat_analyzer.gd")


# --- Behavior selection --------------------------------------------------------
#
# Given a unit and its current target, returns a micro intent that the squad's
# _act() translates into an order. The intent is a Dictionary:
#   { "type": "kite" | "flank" | "close" | "peel" | "hold",
#     "position": Vector3,     # where to move (kite/flank/peel)
#     "target": unit_or_null } # who to attack (may differ from squad target)

static func evaluate(unit, target, squad_allies: Array, world) -> Dictionary:
	if not is_instance_valid(unit) or not is_instance_valid(target):
		return {"type": "hold"}

	var unit_pos: Vector3 = unit.global_position
	var target_pos: Vector3 = target.global_position
	var distance: float = unit_pos.distance_to(target_pos)

	# Unit properties
	var unit_range: float = _attack_range(unit)
	var unit_speed: float = _move_speed(unit)
	var target_range: float = _attack_range(target)
	var target_speed: float = _move_speed(target)

	# --- Priority 1: Peel for threatened allies ---
	var peel_target = _should_peel(unit, squad_allies, world)
	if peel_target != null:
		return {
			"type": "peel",
			"position": peel_target.global_position,
			"target": peel_target,
		}

	# --- Priority 2: Kite if we outrange AND outspeed ---
	if _should_kite(unit_range, unit_speed, target_range, target_speed, distance):
		var retreat_dir: Vector3 = (unit_pos - target_pos).normalized()
		# Back up to max weapon range, maintaining line of fire
		var kite_pos: Vector3 = target_pos + retreat_dir * (unit_range * 0.9)
		return {
			"type": "kite",
			"position": kite_pos,
			"target": target,
		}

	# --- Priority 3: Flank around directional armor ---
	var flank_result: Dictionary = _should_flank(unit, target, unit_pos, target_pos)
	if not flank_result.is_empty():
		return flank_result

	# --- Priority 4: Seek elevation advantage ---
	var hill_pos: Vector3 = _seek_elevation(unit_pos, target_pos, world)
	if hill_pos != Vector3.ZERO:
		return {
			"type": "hold",
			"position": hill_pos,
			"target": target,
		}

	# --- Default: close to engagement range ---
	return {"type": "close", "target": target}


# --- Kiting -------------------------------------------------------------------
#
# A unit kites when it has both range AND speed advantage over its target.
# Without both, kiting is either impossible (too slow to maintain distance)
# or pointless (can't shoot while backing up because out of range).

const KITE_RANGE_RATIO := 1.4   # Must outrange by 40%
const KITE_SPEED_RATIO := 1.15  # Must outspeed by 15%

static func _should_kite(my_range: float, my_speed: float,
		their_range: float, their_speed: float, distance: float) -> bool:
	if my_range <= 0.0 or their_range <= 0.0:
		return false
	if my_speed <= 0.0:
		return false
	# Must outrange
	if my_range < their_range * KITE_RANGE_RATIO:
		return false
	# Must outspeed
	if my_speed < their_speed * KITE_SPEED_RATIO:
		return false
	# Only kite if the target is getting too close (within our comfort zone)
	# Don't bother if we're already at good range
	return distance < my_range * 0.7


# --- Flanking ------------------------------------------------------------------
#
# Flanking exploits directional armor: if the target's front armor is strong,
# circle to hit the rear or side where it's weaker. Only worth it for kinetic
# weapons against well-armored targets, since thermal/energy/explosive damage
# cares less about angle.
#
# THE PLAYER COUNTER: rotate to face the flanker, use turret-mounted weapons
# that cover all arcs, or bring escorts that protect flanks.

const FLANK_ARMOR_THRESHOLD := 1.2  # Only flank targets with armor >= this
const FLANK_CIRCLE_RADIUS := 1.3    # Multiplier on engagement range for the circle path

static func _should_flank(unit, target, unit_pos: Vector3,
		target_pos: Vector3) -> Dictionary:
	# Only flank if the target has meaningful armor
	var target_thickness: float = 0.0
	if "armor_thickness" in target:
		target_thickness = float(target.armor_thickness)
	elif target.has_meta("armor_thickness"):
		target_thickness = float(target.get_meta("armor_thickness"))
	if target_thickness < FLANK_ARMOR_THRESHOLD:
		return {}

	# Only flank with kinetic weapons (they benefit most from hitting weak facets)
	var dominant_class: String = _unit_dominant_damage(unit)
	if dominant_class != "kinetic":
		return {}

	# Don't flank if we're already behind the target
	var target_forward: Vector3 = -target.global_transform.basis.z.normalized()
	var to_us: Vector3 = (unit_pos - target_pos).normalized()
	var dot: float = target_forward.dot(to_us)
	# dot > 0 = we're in front; dot < 0 = we're behind
	if dot < -0.3:
		# Already flanking — just hold and shoot
		return {}

	# Calculate a flanking position — 90 degrees from the target's facing
	var right: Vector3 = target_forward.cross(Vector3.UP).normalized()
	# Pick the side we're closer to
	var side_dot: float = right.dot(to_us)
	var flank_dir: Vector3 = right if side_dot >= 0.0 else -right
	var attack_range: float = _attack_range(unit)
	var flank_pos: Vector3 = target_pos + flank_dir * attack_range * 0.8 \
		- target_forward * attack_range * 0.5  # Slightly behind

	return {
		"type": "flank",
		"position": flank_pos,
		"target": target,
	}


# --- Peel for allies -----------------------------------------------------------
#
# If a friendly support unit (artillery, repair array, sensor suite) is being
# attacked at close range, a nearby short-range unit breaks off to intercept.
# Only fires for units with short-range weapons (brawlers), since a sniper
# peeling wastes its range advantage.

const PEEL_RANGE_THRESHOLD := 20.0  # Only peel if our weapons are short-range
const PEEL_SUPPORT_DIST := 25.0     # How close the support unit must be

static func _should_peel(unit, allies: Array, world) -> Variant:
	var unit_range: float = _attack_range(unit)
	# Only brawlers peel — snipers keep shooting
	if unit_range > PEEL_RANGE_THRESHOLD:
		return null

	var unit_pos: Vector3 = unit.global_position
	for ally in allies:
		if not is_instance_valid(ally) or ally.is_dead:
			continue
		if ally == unit:
			continue
		# Is this ally a high-value support unit?
		if not _is_support_unit(ally):
			continue
		# Is it under attack? (check if it has taken damage recently or is low HP)
		var health_frac: float = ally.hp / ally.max_hp if ally.max_hp > 0.0 else 1.0
		if health_frac >= 0.9:
			continue  # Not under real pressure
		# Is it close enough for us to help?
		if unit_pos.distance_to(ally.global_position) > PEEL_SUPPORT_DIST:
			continue
		# Find who's attacking it — return the nearest enemy near the ally
		var threat: Node3D = _nearest_threat_to(ally, unit, world)
		if threat == null:
			continue
		return threat
	return null


# --- Elevation seeking ---------------------------------------------------------
#
# Units prefer to fight from high ground when advancing. The elevation combat
# bonus (threshold × 0.85 from above) is a real combat advantage.
# Only applies when the unit is not already on high ground relative to its target.

const ELEVATION_SEARCH_RADIUS := 15.0  # How far to look for a hill
const ELEVATION_MIN_GAIN := 2.5        # Minimum height gain worth pursuing

static func _seek_elevation(unit_pos: Vector3, target_pos: Vector3,
		world) -> Vector3:
	# Already on high ground: nothing to seek.
	if unit_pos.y >= target_pos.y + ELEVATION_MIN_GAIN:
		return Vector3.ZERO

	# Without terrain sampling we cannot evaluate hills in detail. The
	# TerrainBuilder's _terrain_height_at() (duck-typed through the world)
	# is the supported hook; if it isn't there we have no opinion.
	if world == null or not world.has_method("terrain_height_at"):
		return Vector3.ZERO

	# Look at the terrain between us and the target. A high spot along
	# that arc we can reach before the target is a candidate firing
	# position; the closest one wins.
	var dx: float = target_pos.x - unit_pos.x
	var dz: float = target_pos.z - unit_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.01:
		return Vector3.ZERO

	var step_count: int = 5
	var best_pos := Vector3.ZERO
	var best_score := unit_pos.y  # baseline: my current terrain height
	for i in range(1, step_count):
		var t: float = float(i) / float(step_count)
		var probe := Vector3(unit_pos.x + dx * t, 0.0, unit_pos.z + dz * t)
		var probe_y: float = float(world.terrain_height_at(probe))
		if probe_y <= best_score:
			continue
		# Must be reachable in this fight (closer to the target than to us)
		var to_target := Vector3(target_pos.x - probe.x, 0.0, target_pos.z - probe.z).length()
		if to_target >= dist:
			continue
		best_score = probe_y
		best_pos = Vector3(probe.x, probe_y, probe.z)

	# Only return a hill worth the move.
	if best_pos == Vector3.ZERO:
		return Vector3.ZERO
	if best_pos.y - unit_pos.y < ELEVATION_MIN_GAIN:
		return Vector3.ZERO
	return best_pos


# --- Helpers -------------------------------------------------------------------

static func _attack_range(unit) -> float:
	if "attack_range" in unit:
		return float(unit.attack_range)
	if "main_weapon_range" in unit:
		return float(unit.main_weapon_range)
	return 30.0  # reasonable default


static func _move_speed(unit) -> float:
	if "move_speed" in unit:
		return float(unit.move_speed)
	if "top_speed" in unit:
		return float(unit.top_speed)
	return 8.0


static func _unit_dominant_damage(unit) -> String:
	# Try to read from the unit's cached profile, fall back to kinetic
	if unit.has_meta("dominant_damage"):
		return str(unit.get_meta("dominant_damage"))
	# If the unit has a blueprint, analyze it
	if "blueprint" in unit and unit.blueprint is Dictionary:
		var p: Dictionary = ThreatAnalyzerScript.profile(unit.blueprint)
		return p.get("dominant_damage", "kinetic")
	return "kinetic"


static func _is_support_unit(unit) -> bool:
	# Support = has repair array, artillery, sensor suite, or indirect-fire weapon
	if "blueprint" in unit and unit.blueprint is Dictionary:
		for m in unit.blueprint.get("modules", []):
			var tid: String = str(m.get("type_id", ""))
			if tid in ["repair_array", "artillery", "mortar_array", "rocket_artillery",
					"sensor_suite", "heavy_sensor_suite", "directional_radar"]:
				return true
	return false


# Find the nearest enemy threat to the ally within PEEL_SUPPORT_DIST. The ally's
# own team is read off the `team` meta so this works for both AI and player
# units. Returns null when the world doesn't expose a damageable lookup
# (synthetic tests, headless probes) — peel then degrades to a no-op, which is
# strictly safer than a false friend picking the wrong target.
static func _nearest_threat_to(ally, _protector, world) -> Node3D:
	if ally == null or not is_instance_valid(ally):
		return null
	if world == null or not world.has_method("get_nearby_damageable"):
		return null
	var ally_pos: Vector3 = ally.global_position
	var ally_team: int = int(ally.get_meta("team")) if ally.has_meta("team") else -1
	if ally_team < 0:
		return null
	var best: Node3D = null
	var best_dist: float = PEEL_SUPPORT_DIST
	for c in world.get_nearby_damageable(ally_pos, PEEL_SUPPORT_DIST):
		if c == null or not is_instance_valid(c):
			continue
		if c.has_meta("is_dead") and bool(c.get_meta("is_dead")):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var other_team: int = int(c.get_meta("team")) if c.has_meta("team") else -1
		if other_team == ally_team or other_team < 0:
			continue
		# Fog-gate: the squad layer does this elsewhere; doing it here keeps
		# peel from acting on intel the player hasn't earned.
		if world.has_method("is_visible_to_team") and not world.is_visible_to_team(c, ally_team):
			continue
		var d: float = ally_pos.distance_to(c.global_position)
		if d < best_dist:
			best_dist = d
			best = c
	return best
