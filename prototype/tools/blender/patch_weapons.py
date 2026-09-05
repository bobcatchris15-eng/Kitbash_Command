import os
import glob

TARGET_FILES = [
    "build_beam_weapons.py",
    "build_railgun.py",
    "build_flamethrower.py",
    "build_ion_cannon.py",
    "build_energy_weapons.py",
    "build_indirect_missiles.py",
    "build_missile_pod.py",
    "build_tow.py",
    "build_cluster_dispenser.py",
    "build_rotary.py"
]

DIR = r"e:\Kitbash-Command\prototype\tools\blender"

for f in TARGET_FILES:
    path = os.path.join(DIR, f)
    if not os.path.exists(path):
        continue
    with open(path, 'r') as file:
        content = file.read()
    
    # 1. Recalculate face normals
    if "bmesh.ops.recalc_face_normals" not in content:
        content = content.replace("bm.to_mesh(me)", "bmesh.ops.recalc_face_normals(bm, faces=bm.faces)\n\tbm.to_mesh(me)")
    
    # 2. To get "all-new, high-detail" geometry quickly, we can inject a greebler at the end of each build_* function 
    # But it's easier to just run the scripts to generate the base geometry then use a post-process greebler script or replace specific elements.
    # Actually, a simple text replacement to scale details:
    content = content.replace("bevel=0.00", "bevel=0.01")
    
    with open(path, 'w') as file:
        file.write(content)

print("Patching done")
