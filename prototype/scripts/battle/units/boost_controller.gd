class_name BoostController
extends RefCounted
# Burst speed boost controller. One per unit, same shape as HarvesterFSM - the
# reason it is not inlined into unit.gd is that file's own header gives:
# movement, power, fog, target selection, assembly and harvesting are already
# split out; boost is another orthogonal behaviour that deserves its own file
# so unit.gd does not become the monolith it replaced.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const PowerBudget = preload("res://scripts/power_budget.gd")

# Minimum distance remaining to destination before a boost can engage.
# Prevents lighting a booster for a 5 m reposition.
const MIN_RUN_DISTANCE := 25.0

# Throttle threshold for engagement - do not light a booster mid-turn.
# heading_throttle returns 0..1 based on alignment to target yaw.
const ENGAGE_THROTTLE_THRESHOLD := 0.75

# Brownout threshold: energy buffer must be above this fraction of max
# for energy-fed boosts to engage/stay lit.
const BROWNOUT_BUFFER_FRACTION := 0.15

enum State {
	IDLE,          # no boost fitted, or waiting for conditions
	CHARGING,      # energy-fed boost warming up (if we ever add warmup)
	ACTIVE,        # boost lit, draining energy/charges
	COOLDOWN,      # boost spent, waiting for cooldown
	EXHAUSTED,     # finite-charge boost depleted
}

var state: State = State.IDLE

# Current boost config from the catalog (set once at setup)
var _boost_config: Dictionary = {}
var _charges_remaining: int = 0
var _cooldown_remaining: float = 0.0
var _active_remaining: float = 0.0
var _energy_per_sec: float = 0.0

# References set by unit.gd on setup
var _unit: Node = null
var _drivetrain: Dictionary = {}

func setup(unit_node: Node, drivetrain_analysis: Dictionary) -> void:
	_unit = unit_node
	_drivetrain = drivetrain_analysis

	var boost_dict: Dictionary = drivetrain_analysis.get("boost", {})
	if boost_dict.is_empty():
		return

	_boost_config = boost_dict
	_charges_remaining = int(boost_dict.get("charges", 0))
	_cooldown_remaining = 0.0
	_active_remaining = 0.0
	_energy_per_sec = float(boost_dict.get("energy_per_sec", 0.0))

	# Infinite charges if charges == 0
	if _charges_remaining == 0:
		_charges_remaining = -1

	state = State.IDLE

func tick(delta: float) -> float:
	# Returns the active speed multiplier (1.0 when no boost)
	if state == State.IDLE:
		# Check if we can engage
		if _can_engage():
			_engage()

		if state != State.ACTIVE:
			return 1.0

	if state == State.ACTIVE:
		_active_remaining -= delta

		# Drain energy for energy-fed boosts
		if _energy_per_sec > 0.0 and _unit != null and _unit.has_method("get_energy_fraction"):
			var energy_frac: float = _unit.get_energy_fraction()
			if energy_frac <= BROWNOUT_BUFFER_FRACTION:
				_disengage_brownout()
				return 1.0

		# Check for disengage conditions
		if _should_disengage():
			_disengage_normal()
			return 1.0

		# Boost expired naturally
		if _active_remaining <= 0.0:
			_disengage_normal()
			return 1.0

		return float(_boost_config.get("speed_mult", 1.0))

	if state == State.COOLDOWN:
		_cooldown_remaining -= delta
		if _cooldown_remaining <= 0.0:
			state = State.IDLE
		return 1.0

	if state == State.EXHAUSTED:
		return 1.0

	return 1.0

func get_state() -> State:
	return state

func get_boost_summary() -> Dictionary:
	if _boost_config.is_empty():
		return {}
	var mult: float = float(_boost_config.get("speed_mult", 1.0))
	var dur: float = float(_boost_config.get("duration", 0.0))
	var cd: float = float(_boost_config.get("cooldown", 0.0))
	var charges: int = int(_boost_config.get("charges", 0))
	return {
		"speed_mult": mult,
		"duration": dur,
		"cooldown": cd,
		"charges_total": charges,
		"charges_remaining": _charges_remaining if _charges_remaining > 0 else 0,
		"state": state,
		"cooldown_remaining": maxf(0.0, _cooldown_remaining),
		"active_remaining": maxf(0.0, _active_remaining),
	}

func can_activate() -> bool:
	if _boost_config.is_empty():
		return false
	if state != State.IDLE:
		return false
	if _cooldown_remaining > 0.0:
		return false
	return true

func activate() -> bool:
	if not can_activate():
		return false
	_engage()
	return true

func _can_engage() -> bool:
	if _boost_config.is_empty():
		return false
	if state != State.IDLE:
		return false

	# Check charges
	if _charges_remaining == 0:
		return false

	# Check cooldown
	if _cooldown_remaining > 0.0:
		return false

	# Must have a destination and be far enough out
	if _unit == null or not _unit.has_method("get_remaining_distance"):
		return false
	var remaining_dist: float = _unit.get_remaining_distance()
	if remaining_dist <= MIN_RUN_DISTANCE:
		return false

	# Heading throttle must be high (not mid-turn)
	if _unit.has_method("get_heading_throttle"):
		var throttle: float = _unit.get_heading_throttle()
		if throttle < ENGAGE_THROTTLE_THRESHOLD:
			return false

	# No live enemy in attack range
	if _unit.has_method("has_hostile_in_range"):
		if _unit.has_hostile_in_range():
			return false

	# Energy check for energy-fed boosts
	if _energy_per_sec > 0.0 and _unit != null and _unit.has_method("get_energy_fraction"):
		var energy_frac: float = _unit.get_energy_fraction()
		if energy_frac <= BROWNOUT_BUFFER_FRACTION:
			return false

	return true

func _engage() -> void:
	state = State.ACTIVE
	_active_remaining = float(_boost_config.get("duration", 0.0))
	if _charges_remaining > 0:
		_charges_remaining -= 1

func _disengage_normal() -> void:
	var cd: float = float(_boost_config.get("cooldown", 0.0))
	if cd > 0.0:
		state = State.COOLDOWN
		_cooldown_remaining = cd
	else:
		# No cooldown - check if we have charges left
		if _charges_remaining == 0:
			state = State.EXHAUSTED
		elif _charges_remaining < 0:
			# Infinite charges, no cooldown - can re-engage immediately
			state = State.IDLE
		else:
			state = State.IDLE

func _disengage_brownout() -> void:
	# Brownout puts us in cooldown even if the boost has no cooldown normally
	var cd: float = float(_boost_config.get("cooldown", 0.0))
	if cd > 0.0:
		state = State.COOLDOWN
		_cooldown_remaining = cd
	else:
		state = State.COOLDOWN
		_cooldown_remaining = 5.0  # Minimum brownout recovery

	# Don't consume a charge on brownout - it was interrupted
	if _charges_remaining > 0:
		_charges_remaining += 1

func _should_disengage() -> bool:
	# Arrived at destination
	if _unit != null and _unit.has_method("get_remaining_distance"):
		if _unit.get_remaining_distance() <= 2.0:
			return true

	# Hostile entered range
	if _unit != null and _unit.has_method("has_hostile_in_range"):
		if _unit.has_hostile_in_range():
			return true

	return false

func force_disengage() -> void:
	# Called when unit takes damage, is stunned, etc.
	if state == State.ACTIVE:
		_disengage_normal()