import sys
import os
import math
import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _greeble import *  # noqa: F401,F403

# Point Defense and Deployables.
#
#   aa_autocannon     - dedicated flak, engages air rather than only munitions
#   sensor_beacon_launcher - lobs a beacon that reveals fog
#
# The rest of the original set (chaff_dispenser, laser_dazzler,
# aps_interceptor, jammer_mast, sentry_deployer, decoy_projector and the three
# bolt-on armor types) was removed from the roster entirely; their builders
# went with them.
#
# See _greeble.py for conventions and the two rules (exterior modules, and
# balance about the trunnion).
#
# ARMOR is different in kind from everything else in this file: it is a
# category-"armor" module that auto-fits the facet it is placed on, so it has
# no trunnion, no mount and no elevation. Those three are authored as flat
# panels whose origin is the mounting face, and visual_builder scales them to
# the facet rather than by a tweak.
#
# THEIR FILENAMES MUST EQUAL THEIR type_id. Unlike every other part in this
# file, armor plates are MONOLITHIC: visual_builder loads them via
# `_part(type_id)` for anything not in MODULAR_ASSEMBLY_TYPES, so the lookup
# key IS the catalog id. These were first exported as armor_slat/armor_spaced/
# armor_ablative against type_ids of slat_armor/spaced_composite/
# ablative_foam, so nothing ever loaded them and all three silently rendered
# as 12-triangle boxes while the authored .glbs sat unused in the repo.
# Aliasing them in mesh_asset_loader would have worked but is explicitly the
# wrong fix - see PART_NAME_ALIASES' own note that an alias shadows a real
# asset and must go the moment a correctly-named file exists.


# ===========================================================================
# POINT DEFENSE
# ===========================================================================

# ---------------------------------------------------------------------------
# CHAFF DISPENSER
# Consumable lock-break. A block of stubby upward-canted cartridge tubes with
# a magazine underneath - closer to the smoke discharger's family than to a
# gun, which is correct: it never points at anything.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
def build_aa_autocannon():
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.020), 0.165, 0.040, segments=22)
	bolt_ring_z(bm, 0.042, 0.144, count=12, bolt_r=0.010, bolt_len=0.016)
	add_cyl_z(bm, (0, 0, 0.076), 0.115, 0.072, segments=20)
	for side in (-1, 1):
		add_box(bm, (side * 0.128, 0.0, 0.190), (0.042, 0.100, 0.190), bevel=0.008)
		add_cyl_x(bm, (side * 0.150, 0.0, 0.268), 0.038, 0.030, segments=14)
		add_cyl_z(bm, (side * 0.096, -0.100, 0.130), 0.026, 0.130, segments=12)
		add_cyl_z(bm, (side * 0.096, -0.100, 0.216), 0.013, 0.070, segments=10)
	add_servo_drive(bm, (0, 0.126, 0.076), axis='Y')
	add_junction_box(bm, (0.132, -0.110, 0.058))
	export_bmesh(bm, "aa_mount", "aa_mount.glb", color=(0.19, 0.20, 0.22, 1.0))

	# Receiver + ammo boxes + tracking radar, all behind the trunnion.
	bm = bmesh.new()
	add_box(bm, (0, -0.060, 0.0), (0.185, 0.230, 0.150), bevel=0.012)
	for side in (-1, 1):                                                    # ammo boxes
		add_box(bm, (side * 0.140, -0.130, -0.010), (0.090, 0.170, 0.140), bevel=0.009)
		for i in range(3):
			add_box(bm, (side * 0.140, -0.190, -0.055 + i * 0.045), (0.096, 0.024, 0.018), bevel=0.003)
	# Tracking radar: a small dish on a short canted mast
	add_cyl_z(bm, (0, -0.180, 0.090), 0.026, 0.090, segments=12)
	add_cyl_y(bm, (0, -0.180, 0.156), 0.078, 0.020, segments=20)
	add_cyl_y(bm, (0, -0.190, 0.156), 0.060, 0.016, segments=18)
	add_cyl_y(bm, (0, -0.158, 0.156), 0.016, 0.045, segments=10)
	add_camera_head(bm, (0.112, 0.010, 0.088), scale=0.8)
	# Spent-case chutes out the bottom
	for side in (-1, 1):
		add_box(bm, (side * 0.058, -0.030, -0.098), (0.052, 0.130, 0.050), bevel=0.005)
	for side in (-1, 1):
		add_box(bm, (side * 0.100, 0.0, 0.0), (0.026, 0.072, 0.072), bevel=0.005)
		add_cyl_x(bm, (side * 0.120, 0.0, 0.0), 0.030, 0.020, segments=14)
	export_bmesh(bm, "aa_receiver", "aa_receiver.glb", color=(0.22, 0.24, 0.22, 1.0))

	# One barrel, mirrored by visual_builder. Origin at the receiver face.
	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.040, 0), 0.044, 0.080, segments=16)
	bolt_ring(bm, 0.040, 0.038, count=8, bolt_r=0.007, bolt_len=0.012)
	add_cyl_y(bm, (0, 0.400, 0), 0.026, 0.640, segments=16)
	for i in range(5):                                                      # cooling jacket rings
		add_cyl_y(bm, (0, 0.140 + i * 0.130, 0), 0.034, 0.020, segments=16)
	# Flash hider: a slotted cone, so a night flak burst does not blind the
	# vehicle's own sensors.
	add_taper_y(bm, (0, 0.745, 0), 0.030, 0.048, 0.060, segments=18)
	for i in range(4):
		a = (i / 4) * math.tau
		add_box(bm, (math.cos(a) * 0.040, 0.755, math.sin(a) * 0.040), (0.012, 0.048, 0.012), bevel=0.002)
	add_cyl_y(bm, (0, 0.782, 0), 0.044, 0.016, segments=18)
	export_bmesh(bm, "aa_barrel", "aa_barrel.glb", color=(0.13, 0.14, 0.15, 1.0))


# ---------------------------------------------------------------------------
# JAMMER MAST
# Passive aura. No barrel, no traverse - a mast of crossed dipole antennas
# over a transmitter cabinet. Should read as equipment, not as a weapon.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
def build_sensor_beacon_launcher():
	bm = bmesh.new()
	add_cyl_z(bm, (0, 0, 0.018), 0.145, 0.036, segments=20)
	bolt_ring_z(bm, 0.038, 0.124, count=10, bolt_r=0.009, bolt_len=0.014)
	add_cyl_z(bm, (0, 0, 0.068), 0.098, 0.064, segments=18)
	# Beacon carousel lying behind - the counterweight and the ammo supply
	add_cyl_x(bm, (0, -0.150, 0.110), 0.105, 0.180, segments=20)
	for side in (-1, 1):
		add_cyl_x(bm, (side * 0.092, -0.150, 0.110), 0.088, 0.018, segments=18)
	for i in range(5):
		a = (i / 5) * math.tau
		add_cyl_x(bm, (0, -0.150 + math.cos(a) * 0.068, 0.110 + math.sin(a) * 0.068),
				  0.028, 0.190, segments=10)
	add_servo_drive(bm, (-0.120, -0.150, 0.110), axis='Y')
	# Short fat launch tube, canted well up
	for side in (-1, 1):
		add_box(bm, (side * 0.098, 0.010, 0.150), (0.030, 0.080, 0.110), bevel=0.006)
		add_cyl_x(bm, (side * 0.114, 0.010, 0.196), 0.026, 0.022, segments=12)
	add_camera_head(bm, (0.110, -0.060, 0.150), scale=0.7)
	add_junction_box(bm, (-0.130, -0.070, 0.055))
	export_bmesh(bm, "beacon_body", "beacon_body.glb", color=(0.23, 0.26, 0.24, 1.0))

	bm = bmesh.new()
	add_cyl_y(bm, (0, 0.110, 0), 0.058, 0.220, segments=18)
	add_cyl_y(bm, (0, 0.008, 0), 0.070, 0.024, segments=18)
	bolt_ring(bm, 0.008, 0.060, count=8, bolt_r=0.007, bolt_len=0.012)
	for i in range(3):
		add_cyl_y(bm, (0, 0.060 + i * 0.060, 0), 0.066, 0.014, segments=18)
	add_cyl_y(bm, (0, 0.228, 0), 0.064, 0.018, segments=18)
	add_box(bm, (0.052, 0.090, 0), (0.018, 0.050, 0.018), bevel=0.003)
	export_bmesh(bm, "beacon_tube", "beacon_tube.glb", color=(0.26, 0.29, 0.25, 1.0),
				 metallic=0.45, roughness=0.55)


# ---------------------------------------------------------------------------
# DECOY PROJECTOR
# Deploys an inflatable/holographic false contact that draws fire. Reads as a
# folded canopy pack with an inflation bottle - deliberately NOT a weapon, and
# deliberately a bit shabby, since the joke is that it works.
# ---------------------------------------------------------------------------
if __name__ == "__main__":
	clear_scene()
	build_aa_autocannon()
	build_sensor_beacon_launcher()
	print("PD_DEPLOY_ARMOR_PARTS_DONE")
