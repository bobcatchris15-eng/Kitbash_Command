extends RefCounted
# Procedural architectural sets for building mesh generation.

const SETS := {
    " standard_industrial\: {\name\: \Standard Industrial\, \desc\: \Cylindrical silos steel trusses exposed conduits heavy gantry\},
 \brutalist_bunker\: {\name\: \Brutalist Bunker\, \desc\: \Angled heavy slab concrete walls slit viewports heavy buttresses\},
 \orbital_modular\: {\name\: \Orbital Modular\, \desc\: \Clean prefabricated hexagonal/cylindrical modules pressurized airlocks\},
 \scrap_rig\: {\name\: \Scrap Rig\, \desc\: \Kitbashed welded plates exposed girders corrugated tin angled smokestacks\},
 \gothic_citadel\: {\name\: \Gothic Citadel\, \desc\: \Arched buttresses cathedral ventilation spires crenellated parapets\},
 \desert_adobe\: {\name\: \Desert Adobe\, \desc\: \Terraced stepped flat-roof compounds cooling windcatchers thick mud-brick bevels\},
 \arctic_subsurface\: {\name\: \Arctic Subsurface\, \desc\: \Domed igloo geodesic shelters snow baffles heated vents buried silos\},
 \cyber_grid\: {\name\: \Cyber Grid\, \desc\: \Angular faceted low-poly stealth geometry neon glowing heatsink fins\},
 \subterranean_forge\: {\name\: \Subterranean Forge\, \desc\: \Heavy blast vaults dual exhaust cooling towers glowing lava grates\},
 \bio_domes\: {\name\: \Bio Domes\, \desc\: \Geodesic glass bubbles organic curved struts hydroponic silos\},
 \solar_relay\: {\name\: \Solar Relay\, \desc\: \Tilted photovoltaic arrays dish clusters delicate lattice pylons\},
 \nautilus_aquatic\: {\name\: \Nautilus Aquatic\, \desc\: \Streamlined submarine pressurized hulls conning towers ballast tanks\}
}

static func get_set_list() -> Array[Dictionary]:
 var out: Array[Dictionary] = []
 for id in SETS:
 var d := SETS[id].duplicate()
 d[\id\] = id
 out.append(d)
 return out

static func get_building_mesh(set_id: String, kind: String, footprint: Vector3) -> Node3D:
 # Factory method that generates/constructs a Node3D styled according to set_id
 var root := Node3D.new()
 root.name = \StyledBuilding_\ + set_id
 
 # Placeholder: construct a simple representation based on set_id.
 var mesh_instance := MeshInstance3D.new()
 var box_mesh := BoxMesh.new()
 box_mesh.size = footprint
 mesh_instance.mesh = box_mesh
 root.add_child(mesh_instance)
 
 # Add a marker based on the set_id to signify the style
 var marker := MeshInstance3D.new()
 marker.mesh = SphereMesh.new()
 marker.mesh.radius = footprint.x * 0.2
 marker.mesh.height = footprint.y * 0.2
 marker.position = Vector3(0, footprint.y * 0.5, 0)
 root.add_child(marker)
 
 return root
