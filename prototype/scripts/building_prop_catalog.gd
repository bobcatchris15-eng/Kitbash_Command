class_name BuildingPropCatalog
extends RefCounted

# Static catalog and registry for all 60 authored civic/architectural building props.
# Provides category filtering, footprint dimensions, model paths, and mesh caching.

const CATEGORIES: Array[String] = [
	"all",
	"rural",
	"residential",
	"urban",
	"commercial",
	"civic",
	"industrial"
]

const CATEGORY_NAMES: Dictionary = {
	"all": "All Buildings",
	"rural": "🌾 Rural & Farm",
	"residential": "🏡 Residential",
	"urban": "🏢 Urban & Apartments",
	"commercial": "🏪 Commercial & Retail",
	"civic": "🏥 Civic & Institutional",
	"industrial": "🏭 Industrial & Logistics"
}

const BUILDINGS: Array[Dictionary] = [
	# -------------------------------------------------------------------------
	# 1. RURAL & AGRICULTURAL
	# -------------------------------------------------------------------------
	{
		"id": "shed_tool_wood",
		"name": "Tool Shed (Wood)",
		"category": "rural",
		"footprint": Vector2(3.6, 2.8),
		"height": 3.3,
		"model_path": "res://assets/models/buildings/civic/shed_tool_wood.glb"
	},
	{
		"id": "shed_corrugated_metal",
		"name": "Corrugated Metal Shed",
		"category": "rural",
		"footprint": Vector2(4.5, 3.5),
		"height": 3.6,
		"model_path": "res://assets/models/buildings/civic/shed_corrugated_metal.glb"
	},
	{
		"id": "cabin_log_timber",
		"name": "Timber Log Cabin",
		"category": "rural",
		"footprint": Vector2(5.5, 5.5),
		"height": 5.2,
		"model_path": "res://assets/models/buildings/civic/cabin_log_timber.glb"
	},
	{
		"id": "barn_classic_gambrel",
		"name": "Classic Gambrel Barn",
		"category": "rural",
		"footprint": Vector2(10.5, 14.5),
		"height": 10.5,
		"model_path": "res://assets/models/buildings/civic/barn_classic_gambrel.glb"
	},
	{
		"id": "barn_pole_storage",
		"name": "Pole Storage Barn",
		"category": "rural",
		"footprint": Vector2(12.0, 16.0),
		"height": 7.6,
		"model_path": "res://assets/models/buildings/civic/barn_pole_storage.glb"
	},
	{
		"id": "farmhouse_two_story",
		"name": "Two-Story Farmhouse",
		"category": "rural",
		"footprint": Vector2(9.0, 12.0),
		"height": 9.5,
		"model_path": "res://assets/models/buildings/civic/farmhouse_two_story.glb"
	},
	{
		"id": "grain_silo_twin",
		"name": "Twin Grain Silos",
		"category": "rural",
		"footprint": Vector2(7.0, 4.5),
		"height": 13.8,
		"model_path": "res://assets/models/buildings/civic/grain_silo_twin.glb"
	},
	{
		"id": "windmill_aeromotor",
		"name": "Windmill Pump",
		"category": "rural",
		"footprint": Vector2(3.0, 3.0),
		"height": 14.5,
		"model_path": "res://assets/models/buildings/civic/windmill_aeromotor.glb"
	},
	{
		"id": "stable_paddock",
		"name": "Horse Stables",
		"category": "rural",
		"footprint": Vector2(14.0, 8.0),
		"height": 6.2,
		"model_path": "res://assets/models/buildings/civic/stable_paddock.glb"
	},
	{
		"id": "tractor_garage",
		"name": "Tractor Repair Garage",
		"category": "rural",
		"footprint": Vector2(9.0, 8.0),
		"height": 6.5,
		"model_path": "res://assets/models/buildings/civic/tractor_garage.glb"
	},

	# -------------------------------------------------------------------------
	# 2. SUBURBAN & RESIDENTIAL
	# -------------------------------------------------------------------------
	{
		"id": "house_suburban_bungalow",
		"name": "Suburban Bungalow",
		"category": "residential",
		"footprint": Vector2(10.0, 9.0),
		"height": 6.2,
		"model_path": "res://assets/models/buildings/civic/house_suburban_bungalow.glb"
	},
	{
		"id": "house_two_story_colonial",
		"name": "Two-Story Colonial House",
		"category": "residential",
		"footprint": Vector2(11.0, 8.5),
		"height": 9.5,
		"model_path": "res://assets/models/buildings/civic/house_two_story_colonial.glb"
	},
	{
		"id": "house_split_level",
		"name": "Split-Level House",
		"category": "residential",
		"footprint": Vector2(13.0, 8.5),
		"height": 8.0,
		"model_path": "res://assets/models/buildings/civic/house_split_level.glb"
	},
	{
		"id": "house_ranch_brick",
		"name": "Brick Ranch House",
		"category": "residential",
		"footprint": Vector2(15.0, 8.0),
		"height": 5.5,
		"model_path": "res://assets/models/buildings/civic/house_ranch_brick.glb"
	},
	{
		"id": "villa_modern_estate",
		"name": "Modern Estate Villa",
		"category": "residential",
		"footprint": Vector2(16.0, 12.0),
		"height": 6.5,
		"model_path": "res://assets/models/buildings/civic/villa_modern_estate.glb"
	},
	{
		"id": "duplex_residential",
		"name": "Residential Duplex",
		"category": "residential",
		"footprint": Vector2(14.0, 9.0),
		"height": 9.2,
		"model_path": "res://assets/models/buildings/civic/duplex_residential.glb"
	},
	{
		"id": "townhouse_row_unit",
		"name": "Townhouse (Row Mid)",
		"category": "residential",
		"footprint": Vector2(6.5, 11.0),
		"height": 10.8,
		"model_path": "res://assets/models/buildings/civic/townhouse_row_unit.glb"
	},
	{
		"id": "townhouse_row_corner",
		"name": "Townhouse (Row Corner)",
		"category": "residential",
		"footprint": Vector2(8.0, 11.0),
		"height": 11.0,
		"model_path": "res://assets/models/buildings/civic/townhouse_row_corner.glb"
	},
	{
		"id": "modular_pre_fab_home",
		"name": "Modular Pre-Fab Home",
		"category": "residential",
		"footprint": Vector2(14.0, 5.0),
		"height": 4.5,
		"model_path": "res://assets/models/buildings/civic/modular_pre_fab_home.glb"
	},
	{
		"id": "cozy_cottage",
		"name": "Country Cottage",
		"category": "residential",
		"footprint": Vector2(7.0, 6.0),
		"height": 6.2,
		"model_path": "res://assets/models/buildings/civic/cozy_cottage.glb"
	},

	# -------------------------------------------------------------------------
	# 3. URBAN & APARTMENTS
	# -------------------------------------------------------------------------
	{
		"id": "apartment_walkup_3s",
		"name": "3-Story Walkup Apartment",
		"category": "urban",
		"footprint": Vector2(12.0, 14.0),
		"height": 11.0,
		"model_path": "res://assets/models/buildings/civic/apartment_walkup_3s.glb"
	},
	{
		"id": "apartment_block_brick_5s",
		"name": "5-Story Brick Apartment Block",
		"category": "urban",
		"footprint": Vector2(14.0, 18.0),
		"height": 19.5,
		"model_path": "res://assets/models/buildings/civic/apartment_block_brick_5s.glb"
	},
	{
		"id": "apartment_tenement_fireescape",
		"name": "Urban Tenement (Fire Escapes)",
		"category": "urban",
		"footprint": Vector2(10.0, 12.0),
		"height": 14.0,
		"model_path": "res://assets/models/buildings/civic/apartment_tenement_fireescape.glb"
	},
	{
		"id": "apartment_modern_balconies",
		"name": "Modern Balcony Apartments",
		"category": "urban",
		"footprint": Vector2(15.0, 15.0),
		"height": 19.0,
		"model_path": "res://assets/models/buildings/civic/apartment_modern_balconies.glb"
	},
	{
		"id": "apartment_corner_groundstore",
		"name": "Mixed-Use Corner Store / Flats",
		"category": "urban",
		"footprint": Vector2(12.0, 12.0),
		"height": 11.0,
		"model_path": "res://assets/models/buildings/civic/apartment_corner_groundstore.glb"
	},
	{
		"id": "residential_tower_10s",
		"name": "10-Story Residential Tower",
		"category": "urban",
		"footprint": Vector2(16.0, 16.0),
		"height": 33.0,
		"model_path": "res://assets/models/buildings/civic/residential_tower_10s.glb"
	},
	{
		"id": "office_lowrise_concrete",
		"name": "Concrete Low-Rise Office",
		"category": "urban",
		"footprint": Vector2(18.0, 12.0),
		"height": 12.5,
		"model_path": "res://assets/models/buildings/civic/office_lowrise_concrete.glb"
	},
	{
		"id": "office_midrise_glass",
		"name": "Mid-Rise Glass Office Tower",
		"category": "urban",
		"footprint": Vector2(16.0, 16.0),
		"height": 22.0,
		"model_path": "res://assets/models/buildings/civic/office_midrise_glass.glb"
	},
	{
		"id": "hotel_motor_inn",
		"name": "Roadside Motor Inn",
		"category": "urban",
		"footprint": Vector2(22.0, 8.0),
		"height": 9.0,
		"model_path": "res://assets/models/buildings/civic/hotel_motor_inn.glb"
	},
	{
		"id": "motel_strip_l_shape",
		"name": "L-Shaped Motel Strip",
		"category": "urban",
		"footprint": Vector2(18.0, 14.0),
		"height": 5.5,
		"model_path": "res://assets/models/buildings/civic/motel_strip_l_shape.glb"
	},

	# -------------------------------------------------------------------------
	# 4. COMMERCIAL & RETAIL
	# -------------------------------------------------------------------------
	{
		"id": "gas_station_fuel_canopy",
		"name": "Gas Station & Fuel Canopy",
		"category": "commercial",
		"footprint": Vector2(14.5, 14.0),
		"height": 5.4,
		"model_path": "res://assets/models/buildings/civic/gas_station_fuel_canopy.glb"
	},
	{
		"id": "diner_retro_roadside",
		"name": "Retro Diner",
		"category": "commercial",
		"footprint": Vector2(12.0, 6.0),
		"height": 4.5,
		"model_path": "res://assets/models/buildings/civic/diner_retro_roadside.glb"
	},
	{
		"id": "convenience_store_corner",
		"name": "Corner Convenience Mart",
		"category": "commercial",
		"footprint": Vector2(11.0, 9.0),
		"height": 5.4,
		"model_path": "res://assets/models/buildings/civic/convenience_store_corner.glb"
	},
	{
		"id": "strip_mall_retail_row",
		"name": "Strip Mall Retail Row",
		"category": "commercial",
		"footprint": Vector2(26.0, 10.0),
		"height": 6.2,
		"model_path": "res://assets/models/buildings/civic/strip_mall_retail_row.glb"
	},
	{
		"id": "bank_branch_vault",
		"name": "Civic Bank Branch",
		"category": "commercial",
		"footprint": Vector2(14.0, 12.0),
		"height": 6.5,
		"model_path": "res://assets/models/buildings/civic/bank_branch_vault.glb"
	},
	{
		"id": "post_office_civic",
		"name": "Post Office Distribution",
		"category": "commercial",
		"footprint": Vector2(13.0, 11.0),
		"height": 5.5,
		"model_path": "res://assets/models/buildings/civic/post_office_civic.glb"
	},
	{
		"id": "fast_food_burger_drive_thru",
		"name": "Fast Food Drive-Thru",
		"category": "commercial",
		"footprint": Vector2(12.0, 8.5),
		"height": 5.2,
		"model_path": "res://assets/models/buildings/civic/fast_food_burger_drive_thru.glb"
	},
	{
		"id": "auto_body_mechanic_garage",
		"name": "Auto Body Repair Shop",
		"category": "commercial",
		"footprint": Vector2(16.0, 11.0),
		"height": 7.8,
		"model_path": "res://assets/models/buildings/civic/auto_body_mechanic_garage.glb"
	},
	{
		"id": "pharmacy_drive_thru",
		"name": "Pharmacy with Drive-Thru",
		"category": "commercial",
		"footprint": Vector2(14.0, 10.0),
		"height": 5.4,
		"model_path": "res://assets/models/buildings/civic/pharmacy_drive_thru.glb"
	},
	{
		"id": "supermarket_anchor_store",
		"name": "Supermarket Anchor Store",
		"category": "commercial",
		"footprint": Vector2(28.0, 20.0),
		"height": 8.6,
		"model_path": "res://assets/models/buildings/civic/supermarket_anchor_store.glb"
	},

	# -------------------------------------------------------------------------
	# 5. CIVIC & INSTITUTIONAL
	# -------------------------------------------------------------------------
	{
		"id": "hospital_main_complex",
		"name": "General Hospital Complex",
		"category": "civic",
		"footprint": Vector2(28.0, 22.0),
		"height": 20.0,
		"model_path": "res://assets/models/buildings/civic/hospital_main_complex.glb"
	},
	{
		"id": "hospital_emergency_er_wing",
		"name": "Hospital Emergency (ER) Wing",
		"category": "civic",
		"footprint": Vector2(20.0, 14.0),
		"height": 9.0,
		"model_path": "res://assets/models/buildings/civic/hospital_emergency_er_wing.glb"
	},
	{
		"id": "clinic_urgent_care",
		"name": "Urgent Care Medical Clinic",
		"category": "civic",
		"footprint": Vector2(15.0, 10.0),
		"height": 6.2,
		"model_path": "res://assets/models/buildings/civic/clinic_urgent_care.glb"
	},
	{
		"id": "school_brick_elementary",
		"name": "Elementary School (Bell Tower)",
		"category": "civic",
		"footprint": Vector2(26.0, 14.0),
		"height": 14.5,
		"model_path": "res://assets/models/buildings/civic/school_brick_elementary.glb"
	},
	{
		"id": "police_station_lockup",
		"name": "Police Station & Lockup",
		"category": "civic",
		"footprint": Vector2(16.0, 12.0),
		"height": 11.5,
		"model_path": "res://assets/models/buildings/civic/police_station_lockup.glb"
	},
	{
		"id": "fire_station_engine_bays",
		"name": "Fire Station (3 Engine Bays)",
		"category": "civic",
		"footprint": Vector2(18.0, 14.0),
		"height": 15.6,
		"model_path": "res://assets/models/buildings/civic/fire_station_engine_bays.glb"
	},
	{
		"id": "city_hall_colonnade",
		"name": "City Hall (Colonnade & Dome)",
		"category": "civic",
		"footprint": Vector2(22.0, 16.0),
		"height": 14.0,
		"model_path": "res://assets/models/buildings/civic/city_hall_colonnade.glb"
	},
	{
		"id": "church_chapel_bell_tower",
		"name": "Church & Steeple Tower",
		"category": "civic",
		"footprint": Vector2(12.0, 18.0),
		"height": 22.0,
		"model_path": "res://assets/models/buildings/civic/church_chapel_bell_tower.glb"
	},
	{
		"id": "library_municipal",
		"name": "Municipal Public Library",
		"category": "civic",
		"footprint": Vector2(18.0, 14.0),
		"height": 10.0,
		"model_path": "res://assets/models/buildings/civic/library_municipal.glb"
	},
	{
		"id": "courthouse_classical_steps",
		"name": "Courthouse with Grand Steps",
		"category": "civic",
		"footprint": Vector2(24.0, 18.0),
		"height": 13.0,
		"model_path": "res://assets/models/buildings/civic/courthouse_classical_steps.glb"
	},

	# -------------------------------------------------------------------------
	# 6. INDUSTRIAL & LOGISTICS
	# -------------------------------------------------------------------------
	{
		"id": "warehouse_small_quonset",
		"name": "Quonset Hut Warehouse",
		"category": "industrial",
		"footprint": Vector2(10.0, 14.0),
		"height": 5.5,
		"model_path": "res://assets/models/buildings/civic/warehouse_small_quonset.glb"
	},
	{
		"id": "warehouse_distribution_dock",
		"name": "Distribution Warehouse (Docks)",
		"category": "industrial",
		"footprint": Vector2(28.0, 18.0),
		"height": 8.5,
		"model_path": "res://assets/models/buildings/civic/warehouse_distribution_dock.glb"
	},
	{
		"id": "hangar_aircraft_barrel_roof",
		"name": "Aircraft Hangar (Barrel Roof)",
		"category": "industrial",
		"footprint": Vector2(24.0, 20.0),
		"height": 14.5,
		"model_path": "res://assets/models/buildings/civic/hangar_aircraft_barrel_roof.glb"
	},
	{
		"id": "factory_sawtooth_roof",
		"name": "Manufacturing Factory (Sawtooth)",
		"category": "industrial",
		"footprint": Vector2(24.0, 16.0),
		"height": 8.8,
		"model_path": "res://assets/models/buildings/civic/factory_sawtooth_roof.glb"
	},
	{
		"id": "factory_brick_smokestacks",
		"name": "Industrial Plant & Smokestacks",
		"category": "industrial",
		"footprint": Vector2(22.0, 14.0),
		"height": 21.0,
		"model_path": "res://assets/models/buildings/civic/factory_brick_smokestacks.glb"
	},
	{
		"id": "oil_storage_tank_battery",
		"name": "Oil Storage Tank Battery",
		"category": "industrial",
		"footprint": Vector2(22.0, 16.0),
		"height": 9.2,
		"model_path": "res://assets/models/buildings/civic/oil_storage_tank_battery.glb"
	},
	{
		"id": "electrical_substation_switchyard",
		"name": "Electrical Substation & Switchyard",
		"category": "industrial",
		"footprint": Vector2(18.0, 14.0),
		"height": 5.2,
		"model_path": "res://assets/models/buildings/civic/electrical_substation_switchyard.glb"
	},
	{
		"id": "grain_elevator_concrete_tower",
		"name": "Grain Elevator & Terminal Tower",
		"category": "industrial",
		"footprint": Vector2(18.0, 12.0),
		"height": 24.0,
		"model_path": "res://assets/models/buildings/civic/grain_elevator_concrete_tower.glb"
	},
	{
		"id": "cooling_tower_hyperbolic",
		"name": "Hyperbolic Cooling Tower",
		"category": "industrial",
		"footprint": Vector2(18.0, 18.0),
		"height": 23.0,
		"model_path": "res://assets/models/buildings/civic/cooling_tower_hyperbolic.glb"
	},
	{
		"id": "water_tower_lattice_steel",
		"name": "Lattice Steel Water Tower",
		"category": "industrial",
		"footprint": Vector2(8.0, 8.0),
		"height": 24.0,
		"model_path": "res://assets/models/buildings/civic/water_tower_lattice_steel.glb"
	}
]

static var _lookup: Dictionary = {}
static var _mesh_cache: Dictionary = {}

static func _ensure_lookup() -> void:
	if not _lookup.is_empty():
		return
	for b in BUILDINGS:
		_lookup[str(b["id"])] = b


static func get_building(id: String) -> Dictionary:
	_ensure_lookup()
	return _lookup.get(id, {})


static func get_all_buildings() -> Array[Dictionary]:
	return BUILDINGS


static func get_buildings_in_category(cat: String) -> Array[Dictionary]:
	if cat == "" or cat == "all":
		return BUILDINGS
	var out: Array[Dictionary] = []
	for b in BUILDINGS:
		if str(b.get("category", "")) == cat:
			out.append(b)
	return out


static func get_categories() -> Array[String]:
	return CATEGORIES


static func get_category_name(cat: String) -> String:
	return CATEGORY_NAMES.get(cat, cat.capitalize())


static func load_mesh(id: String) -> Mesh:
	if _mesh_cache.has(id):
		return _mesh_cache[id]
	var info := get_building(id)
	if info.is_empty():
		return null
	var path: String = str(info.get("model_path", ""))
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		if scene != null:
			var node := scene.instantiate()
			var found_mesh: Mesh = null
			var stack: Array = [node]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D and n.mesh != null:
					found_mesh = n.mesh
					break
				for c in n.get_children():
					stack.append(c)
			node.queue_free()
			if found_mesh != null:
				_mesh_cache[id] = found_mesh
				return found_mesh
	return null
