# Kitbash Command — Faction & Terrain Visual Design Document

## 0. Design Premise
Every hull/module uses one shared mesh per part, faction-agnostic. Faction identity is carried 100% by material parameters: paint color, wear, trim, surface finish — no bespoke geometry, no hand-painted unique textures per faction. Entire faction-identity system lives in a shared shader with a small number of exposed per-faction parameters, plus shared masks (wear masks, panel-line masks, trim masks) every faction's parameters multiply against.

## 1. Tone/Mood Translation
**1.1 Color temperature & saturation:** Base metal = warm-neutral silver (hue 40-55°, luminance 0.55-0.70), never cold blue-steel by default. Faction accents: HSV saturation 55-85%, value 70-95% (diecast-model-paint register, not military-drab, not pastel). Terrain saturation must sit lower than faction saturation — units are the saturated "toy" objects, world is the muted stage. Lifted blacks (shadow floor ~0.08), capped whites (specular cap ~0.92).

**1.2 Where goofy lives:** Detail-scale only, never silhouette/color-blocking. Safe: oversized bolt-heads at module seams, small stenciled serial numbers/nicknames in rounded stencil font, tiny per-faction mascot decal (~5% of hull silhouette max) at fixed anchor points, personality emerging from extreme Design Lab slider combos (systemic, not textural — material system must not fight it), warm cartoon-bright hazard stripes at panel edges. Never: primary silhouette color-blocking staying "toy tractor" not cartoon, no googly-eyes/face-like grilles, weapon barrels/muzzles stay subdued/functional, faction color must never reduce unit-vs-terrain/unit-vs-unit legibility.

**1.3 Brushed anodized aluminum surface language:** Brush direction follows dominant long axis per part-type (nose-to-tail hulls, spanwise wings, radial wheels/turret rings). Anisotropic highlight perpendicular to brush grain — use Godot's `anisotropy_enabled`/`anisotropy`/`anisotropy_flowmap` on StandardMaterial3D/spatial shader; reads as a static bright stripe per unit facing at fixed RTS camera angle. Anodized tint = translucent tint multiplied over brushed-metal albedo+anisotropy (not opaque paint layer) — this is both the correct metaphor and cheapest shader implementation, letting factions share one brush/anisotropy pass and differ only by tint. Edge wear: high-curvature edges (panel corners, bolt heads, tread lugs, wingtips) expose brighter/warmer bare metal as wear_amount rises, driven by baked curvature/AO mask (shared across factions, depends only on mesh). Panel lines/rivets: consistent kit-of-parts grammar across ALL factions regardless of paint — recessed seams w/ darkened AO line, rivet rows, large structural bolts at attachment points — reinforces "same engineering, different livery." Roughness: bake subtle roughness-noise stretched along brush direction into shared base texture even for pristine factions.

**1.4 Shared decal/stencil library:** hazard chevrons, serial stencils, mascot icon, warning glyphs — one decal atlas, re-tinted per faction accent/detail color.

**1.5 Wear as continuous 0-1 dial**, not binary.

**1.6 Team-color problem (important, flag explicitly):** Since faction paint IS the primary identity channel, two players picking the same faction have no material signal left to distinguish "mine" vs "enemy's." Recommend a small, separate, low-saturation team marker independent of faction shader — thin colored piping/edge-light at a fixed decal anchor (corner pennant, cockpit glow, LED strip) driven by its own `team_color` parameter layered ON TOP of faction material, not replacing any faction parameter. Keeps "who owns this" and "what faction" orthogonal.

## 2. Shader Parameter Model
Proposed as a Godot ShaderMaterial, packaged as a custom Resource (e.g. FactionMaterialProfile.tres) so each faction is one data asset:

| Parameter | Type | Purpose |
|---|---|---|
| base_color | Color | Primary hull paint (large flat panels) |
| accent_color | Color | Secondary trim/stripe/panel-edge tint |
| detail_color | Color | Tertiary stencil/decal/insignia tint, small-area only |
| metallic | float 0-1 | Base metallic response under paint |
| roughness | float 0-1 | Base roughness of paint layer |
| anisotropy | float 0-1 | Strength of brushed-metal highlight streak |
| brush_scale | float | Tiling frequency of brush-grain detail (see stretch handling below) |
| wear_amount | float 0-1 | Master weathering dial — blends base paint → exposed metal/rust, driven by shared curvature/edge mask |
| wear_color | Color | What gets exposed as wear increases — bare steel most factions, rust-orange Industrialists, grime-black Salvagers, frost-white Glacier Syndicate, brass Aerodrome Cartel, etc. |
| grime_amount | float 0-1 | Separate from edge wear — soot/dirt in RECESSED areas (AO-driven, opposite mask logic from wear_amount) |
| edge_highlight_strength | float 0-1 | How bright/hot exposed-edge highlight reads |
| emissive_color / emissive_strength | Color/float | Optional status lights/cockpit glow/tech accents — zero most factions, nonzero e.g. Technocrats |
| decal_tint | Color | Tint for shared stencil/hazard/mascot decal atlas |

13 exposed values total — small enough to hand-author per faction.

**Shared mask set (baked ONCE per mesh/module, not per faction):** Mask R = base/panel mask (where base_color applies). Mask G = trim mask (accent_color — edge stripes, sponson trim, turret ring). Mask B = curvature/edge-wear mask (baked from mesh curvature or runtime fresnel/curvature approx — drives wear_amount exposure, high on edges/corners/bolts, near-zero on flat panel interiors). Mask A = cavity/AO mask (drives grime_amount, opposite spatial logic from wear mask — grime collects in crevices). Separate greyscale decal-alpha atlas for the shared stencil library, tinted by decal_tint at fixed anchor points.

**Handling continuous stretch/scale (IMPORTANT, game-specific risk):** Since Design Lab lets players continuously stretch/scale hulls, naive per-object UVs will distort/re-tile brush grain and panel lines unpredictably. Fix: drive brush_scale and panel/rivet detail through world-space or object-local triplanar sampling (or UVs normalized to real-world unit length, not 0-1 per mesh) so a stretched hull shows MORE repetitions of the same brush grain, not one smeared stroke — correct real-world behavior too. Rivets/bolts should stay fixed-size in world units, tiling to match part length, rather than scaling with the slider. Solve this ONCE in the shared shader, not per faction — it's a mesh/UV problem, not a faction-identity problem.

## 3. The Ten Factions

1. **Heavy Industrialists** (existing) — Steel-belt magnates, brute-force manufacturing. Gunmetal grey / hazard yellow / rust-orange wear. Lived-in: moderate wear+grime, low-mid roughness ("well-oiled," not derelict). Bonus: armor-weight tolerance.

2. **Technocrats** (existing) — Clean futurists, precision over brute force. Pearlescent white / electric cyan / chrome. Pristine: near-zero wear/grime, high anisotropy, nonzero emissive on sensors/cockpit. Bonus: vision + speed.

3. **Expansionists** (existing) — Colonial frontier land-grabbers. Olive drab / burnt sienna / aged brass. Dusty/weathered: mud-spatter grime concentrated low (terrain-contact), sunbaked mid-high roughness. Bonus: resource-drain exemption for structures/units far from base.

4. **The Salvage Union** — Junkyard mercenaries, nothing original equipment. Primer grey base w/ mismatched randomized-per-unit patch panels (secondary patch mask) + duct-tape/raw-aluminum trim. Scavenged/battle-worn: highest wear+grime in roster, dull edge highlight, patched bullet-hole decals. Bonus: cheaper repair / reduced module costs.

5. **The Crimson Concordat** — Zealous militant order, banners and kill-marks as doctrine. Deep crimson / gold-brass / black. Ceremonial-pristine chassis, heavy decal density (kill-mark stencils, banner motifs) rather than physical wear. Bonus: combat bonus scaling up as unit nears critical health.

6. **The Glacier Syndicate** — Cold-climate industrial cartel, methodical. Arctic white / ice-blue / gunmetal. Pristine-but-frosted: unique wear_color (pale frost-crystal white, not rust), low-mid roughness. Bonus: reduced terrain-speed penalty across the board.

7. **The Dune Runners** — Desert nomad convoy, economy first. Sandstone tan / faded turquoise / worn-leather-brown. Sun-bleached/sandblasted: matte, LOW-anisotropy finish (sand scours off the mirror-brush highlight rather than exposing bright metal), wear_color desaturates rather than brightens. Bonus: harvesting/economy bonus (faster gathering / higher harvester capacity).

8. **The Ledger Combine** — Corporate-military conglomerate, war-as-product-line. Corporate blue / white / neon-green logo detail. Showroom-pristine, notably higher gloss than any other faction, branded decal (wordmark/logo) at mascot anchor rather than sensor-tech emissive. Bonus: cheaper unit/production costs.

9. **The Bayou Irregulars** — Swamp guerrilla insurgency, hit-and-fade. Swamp green / mud brown / faded olive, MOTTLED camo-pattern mask blending base/accent (two greens mottled, not flat color) — trim mask reads as camo netting, not a racing stripe. Scavenged, moss/algae-tinted grime (wear_color shifted green-black, not rust) concentrated low on hull. Bonus: reduced detection range against this faction (camouflage).

10. **The Aerodrome Cartel** — Barnstorming aviation enthusiasts turned arms dealers, art-deco glamour over serious airframes. Cream/ivory / polished brass-copper / deep aviation-blue stripe. Polished-brass-pristine trim (wear_color is brass, not raw aluminum), lived-in leather-toned grime around cockpits/nacelles only. Bonus: air-unit (flying-wing/fuselage/airship) cost or speed specialization.

Note: wear-level spans full spectrum (2 showroom-pristine, 2 pristine-with-a-twist, 2 lived-in/weathered, 2 scavenged/battle-worn, 2 with genuinely unique wear chromatics — frost-white and brass-gold, not just "more rust") so the roster doesn't converge on "everyone just gets rustier." Bonus-flavor spans economy/combat/utility-vision/unit-class-specialization so no two factions reward the same playstyle.

## 4. Map/Terrain Texture Direction
Governing rule: terrain saturation/brightness sits below unit paint; instant tactical legibility beats prettiness. Keep natural terrain roughness high/matte (glossy dirt reads as plastic/toy — the wrong kind of goofy). Reserve the brushed-metal anisotropic language for MAN-MADE terrain only (bridges, urban structures, resource-node machinery) — organic terrain = matte painterly, manufactured terrain = brushed metal family, doubling as a passive "capturable/interactable" cue. Maintain strong value (not just hue) separation between adjacent terrain types for readability at fast pan/small-icon scale. Avoid pure saturated primaries anywhere in terrain.

- **Open ground:** warm desaturated ochre-green, matte, two-scale noise (large mottling + fine grain for tread-track readability). The neutral baseline.
- **Marsh/swamp:** darker/cooler/murkier green-brown, sheen ONLY in standing-water pockets not the mud itself. Bayou Irregulars' camo palette intentionally sits close to this hue family (their camo bonus made visible) but terrain should stay a notch darker/duller than even their paint so non-Irregular units don't also vanish.
- **Rocky terrain:** cooler grey-brown, higher-frequency chunky normal/roughness detail, harder value-contrast between faces and crevices — reads "hard and blocky" at a glance.
- **Snow vs. mud (split, not one look):** Snow = bright warm-white (not blue-white, ties to warm-aluminum temperature target), blue-shadow only in recesses/tracks. Mud = dark saturated brown, GLOSSY — the one deliberate exception to matte-terrain rule, since wet mud is genuinely reflective and the gloss itself is the "this will slow you down" readability cue.
- **Soft sand:** warm light tan, matte, soft low-frequency dune-shaped normal (not chunky like rock) — silhouette alone should read "soft and slow."
- **Shallow/deep water:** shallow = lighter, more saturated teal-blue, visible terrain-bed detail underneath (communicates crossable/amphibious-passable); deep = darker, desaturated, opaque (naval-only, ground units stop here). Treat the shallow/deep boundary as a soft-edged but clearly-valued transition line, not an ambiguous gradient — it's a hard gameplay boundary.
- **Elevated plateaus:** same base terrain coloring as what's below (open ground on a plateau still reads as open ground) but warm rim-light/cliff-face treatment on vertical faces w/ slightly metallic/brushed rock-strata normal (restrained nod to brushed language, still mostly natural) so elevation reads as silhouette break even before shadow sells it.
- **Urban/city structures:** brushed-metal-family shader (rusted/worn concrete-and-metal, panel lines, rivets) but STRICTLY NEUTRAL, no-faction-tint palette (weathered concrete grey, oxidized rebar-rust, faded neutral signage) — reads as "the world," not belonging to any faction.
- **Bridges:** full brushed-aluminum treatment, unambiguously manufactured — hazard-stripe edge markings from the shared decal library, NEUTRAL-tinted (not faction-tinted), since bridges are a chokepoint/hazard players need to spot instantly.
- **Resource nodes:** recommend their own fixed neutral high-saturation industrial yellow/orange (hazard-adjacent, not faction-adjacent, not terrain-adjacent) purely for at-a-glance economy-target legibility, like traffic-cone orange.

## 4.1 Brightness Tier Hierarchy (Visual Readability Budget)

Every pixel on screen competes for attention. The brightness tier system ensures gameplay-critical elements (units) always win over decorative elements (terrain, foliage). These are hard caps, not targets — decorative elements should sit at the floor of their tier, not the ceiling.

| Tier | Element | Max Luminance | Notes |
|---|---|---|---|
| **1 — Units** | Hull albedo, livery, outline, rim-light | Unrestricted | Units are the loudest thing on screen. Livery picker may produce any color. Outline (enemy) and rim-light (friendly) operate here. |
| **2 — Buildings** | Refineries, manufactories, HQ | 0.75 | Man-made structures need to be readable as faction assets but must not outshine units fighting around them. |
| **3 — Decorative foliage** | Trees, bushes, rocks | 0.45 | Foliage is a backdrop. Tree transmission/backlight is capped at 0.12 (see tree_foliage.gdshader). Grass base→tip spread is compressed to 0.06 luminance. |
| **4 — Terrain** | Ground textures, cliffs | 0.38 | Terrain desaturated (0.25) and slightly lifted (0.04 exposure). Mip bias 0.5 suppresses micro-detail at distance. |
| **5 — Sky/fog** | Procedural sky, volumetric fog | N/A | Sky and fog set the ambient light floor, not the ceiling. They should never be the brightest element in frame. |

**Why these numbers:** A unit at full brightness (tier 1) against terrain at tier 4 gives a contrast ratio of ~2.6:1 — enough for silhouette detection at RTS zoom. If a decorative element exceeds its tier, it steals attention from units and degrades the "units are the loud thing" principle (CORE_DESIGN_LANGUAGE §1).

**Enforcement:** The tree and grass shaders have hard caps in code (BACKLIGHT capped at 0.18, grass backlight removed entirely). Terrain has built-in desaturation and mip bias. Future decorative assets (new tree species, bush meshes, rock props) must be authored within their tier's luminance cap. When in doubt, go darker — a dim decorative element is invisible, but a bright one is a distraction.

## 4.2 Team-Color Mask Workflow (Future Implementation)

The current livery system tints the entire hull uniformly per zone. A mask-channel approach would restrict team-color to specific regions (trim, chevrons, turret bands) while keeping the base hull at a controlled neutral value. This section documents the intended workflow for when the mask channel is implemented.

### Shader Side (hull_faction_material.gdshader)

Add a `uniform sampler2D team_color_mask` that uses the **alpha channel** as the mask:
- Alpha = 1.0 → full team-color tint (livery zone color applied)
- Alpha = 0.0 → no tint (base hull albedo preserved)
- Alpha 0.0–1.0 → partial tint (blend between base and team-color)

The mask replaces the current geometric `_zone_mask()` function, which uses hull height/Y position as a proxy. A texture mask is authorable and precise.

### GIMP Workflow for Mask Authoring

1. **Export the hull's albedo texture** from Blender as a PNG (the base color map already exists at `assets/models/hulls/<id>.png` or similar).

2. **Open in GIMP** and add a new layer named `team_color_mask` above the albedo.

3. **Paint the mask in grayscale:**
   - White (255) = team-color region (trim, chevrons, turret band)
   - Black (0) = base hull (rivets, panels, mechanical detail)
   - Gray (128) = partial blend (transition zones, weathering edges)

4. **Typical mask regions for a hull:**
   - Hull lower (floor): black — base hull, never team-tinted
   - Hull upper (walls): white — primary team-color area
   - Hull stripe (accent bands): white — team-color chevron/racing stripe
   - Weapon action: black — mechanical, never team-tinted
   - Weapon barrel: gray-to-white — subtle team tint on barrel shroud

5. **Save the mask as the alpha channel** of the albedo texture (GIMP: Colors > Components > Decompose → edit alpha → Recompose), or as a separate grayscale PNG named `<hull_id>_team_mask.png`.

6. **Import into Godot** alongside the hull mesh. The shader samples it via `hint_default_white` (defaults to all-white = full team-color everywhere, matching current behavior).

### Migration Path

The existing5-zone geometric system continues to work as the fallback. The mask texture is optional — hulls without a mask get the current behavior. Hulls with a mask get the precise per-region tinting. This means no existing assets break, and new hulls can be authored with masks incrementally.

## 5. Suggested Implementation Priority
1. Build shared shader + mask-bake pipeline against ONE hull and ONE module first, validate the stretch/scale handling (section 2.4) before touching faction data at all — this is the one piece of real technical risk in the whole system.
2. Author the 3 existing factions as data rows against that shader to prove the parameter set covers the intended range.
3. Add remaining 7 factions purely as data once the shader is proven — should require zero new shader logic.
4. Terrain shader work can proceed in parallel, reconnecting only at the urban/bridges brushed-metal touchpoint.

---

## Weapons Are Exterior Modules, Not Crew-Served Guns

Every weapon in this game is a module bolted to the **outside** of a vehicle and aimed from somewhere else. Nothing has a person standing behind it. That has a hard consequence for what may appear on a model, and the roster originally violated it almost everywhere because the reference photographs are all of crew-served weapons.

**Never model:** spade grips, D-handles, butterfly triggers, trigger grips, shoulder stocks, hand charging handles, carry handles, hand cranks, eyepieced telescopic sights, foot pedals, or seats. Each of these is a direct statement that a human's hands or face go there.

**Model instead**, doing the same mechanical job:
| Instead of | Use |
| --- | --- |
| Spade grips / handwheels | Servo can + gearbox + cable gland |
| Butterfly trigger / trigger grip | Firing solenoid and conduit |
| Hand charging handle | Pneumatic cocking cylinder |
| Breech operating lever | Electric breech actuator with a linkage arm |
| Carry handle | Bolted hoist lugs, or a clipped cable conduit |
| Hand crank / windlass handle | Geared motor drive on the same shaft |
| Eyepieced scope on a riser | Boxed camera with the lens on the FRONT, or a LIDAR drum |

The optics rule is worth stating separately, because it is the easiest one to get wrong: a long tube on a riser reads as a telescope no matter what you call it. An unmanned sensor head needs its glass on the **outside**, where a lens is, rather than recessed where an eyepiece would be — plus at least one cue no telescope has, such as a rotating LIDAR drum, heat-sink fins, or a data conduit.

**Mass belongs behind the trunnions.** A gun with everything in front of its trunnion line reads as a barrel stuck on a post. Real guns of any calibre carry recuperator cylinders, a breech ring, a case deflector and a loader aft of the pivot, and that blocky counterweight mass is a large part of what makes a weapon look like it can absorb its own recoil.
