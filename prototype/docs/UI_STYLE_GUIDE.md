# Kitbash Command — UI Style Guide
_Distilled from the current ui_tokens.gd, ui_theme.gd, build_ui_theme.gd, ui_anim.gd and ui_feedback.gd implementation._
_Last updated: 2026-08-05_

---

## 1 · Design Philosophy

**The interface is an instrument housing, not a feature.**

The units are cartoonish and loud; the terrain is realistic and grounded. The UI's job is to be a quiet, credible piece of military equipment so the saturated, toy-like vehicles on screen stay the loud thing. If the chrome competes for saturation, both lose.

Three principles follow from that:

1. **Signal colour is for state, not decoration.** Amber is not a design choice for a button you like; it means *attention is required here*. Red means damage or a destructive action. Green means ready. Blue-grey means informational only. These rules must not break.
2. **Material, not colour, conveys surface identity.** Panels don't feel like panels because they're a dark rectangle; they feel like panels because they're finished in powdercoat, moulded, or canvas. Colour follows from the material's light response.
3. **Readability over atmosphere.** The original theme ran a worn typewriter face at 13 px in a 24-row parts list. Beautiful in a screenshot, unreadable in play. The stencil face is now reserved for display headings only.

---

## 1a · The Two Skins

The interface is unified by a shared structural grammar (5-metric spacing grid, 2px corner radii, programmatic node construction, `UIFeedback` audio/motion coupling) split into two context-specific aesthetic skins:

1. **Cold-War Combat Information Center (In-Match Battle HUD)**:
   - Codified in `scripts/hud/hud_style.gd` and `scripts/hud/hud_skin.gd`.
   - Flat, high-contrast dark fills (`#161B22`, `#1E252E`) with 1px border edges (`#2C353F`, `#3E4A57`), cold phosphor accents (`CIC_EDGE`, `SCAN_LINE`, `RETICLE`), and monospaced live telemetry readouts.
   - Zero runtime texture generation overhead for maximum combat frame rates.

2. **Hobbyist Toolkit (Out-of-Match Screens)**:
   - Codified in `scripts/ui_tokens.gd`, `scripts/ui_theme.gd`, and `bomber_theme.tres`.
   - Physical workbench materials: L0 desks (`cutting_mat`, `cardboard`, `kraft`, `cork`, `chipboard`), L1 equipment chrome (`powdercoat`, `steel`, `moulded`, `canvas`, `carbon`, `fiberglass`, `toolbox`, `bakelite`, `wood`), and 3D industrial hardware controls via `UIPropStage`.
   - Used across Main Menu, Design Lab, Armor Station, Modular Hull Builder, Blueprint Library, Roster Picker, Match Setup, Operations, and After-Action Report debrief dossiers.

---

## 2 · Palette

All colours live in `scripts/ui_tokens.gd`. No screen should hardcode a colour literal not from that file.

### 2.1 Base (warm neutral)

The base is a **warm dark**, not the blue-black default sci-fi palette. Warm greys read further from the cool sky and water of the battlefield, so chrome separates from the world instead of blending into it.

| Token | Value (linear) | Use |
|---|---|---|
| `BASE_900` | `#13130F` | deepest recess, modal scrim |
| `BASE_800` | `#1C1B18` | panel body |
| `BASE_700` | `#252420` | raised control body |
| `BASE_600` | `#33312C` | hover fill, raised edge |
| `BASE_500` | `#4A473E` | borders, dividers |
| `BASE_400` | `#676358` | disabled text, hairlines |

### 2.2 Text

Off-white, not pure white. Pure white on warm dark reads as a blown-out highlight and vibrates at small sizes.

| Token | Value | Use |
|---|---|---|
| `TEXT_PRIMARY` | `#EFE9E5` | default body and heading text |
| `TEXT_SECONDARY` | `#ADA899` | labels, hints, metadata |
| `TEXT_DISABLED` | `#6F6B62` | unavailable controls |

### 2.3 Signal colours

**Deliberately few.** Each one means exactly one thing everywhere it appears.

| Token | Value | Meaning — never reuse for decoration |
|---|---|---|
| `SIGNAL_HAZARD` | `#E0AA2E` (amber) | attention, selection, active indicator, warnings |
| `SIGNAL_ALERT` | `#C84432` (red) | damage, failure, destructive actions |
| `SIGNAL_GO` | `#668249` (olive green) | ready, affordable, confirmed |
| `SIGNAL_INFO` | `#607FA8` (steel blue) | informational only — never an action cue |

**Dimmed variants** (for fills that sit under text):

| Token | Use |
|---|---|
| `SIGNAL_HAZARD_DIM` | amber fill behind amber-edged controls |
| `SIGNAL_ALERT_DIM` | red fill behind red-edged controls |
| `SIGNAL_GO_DIM` | green fill for progress and resource bars |

### 2.4 Accent Roles

The semantic system for non-signal colour use. Amber is the ONLY interactive accent.

| Role | Token | Use |
|---|---|---|
| `ACCENT_INTERACTIVE` | `SIGNAL_HAZARD` | selected, active, clickable — the only interactive accent |
| `ACCENT_CATEGORY` | `BASE_500` | category grouping — muted neutral, never a signal colour |
| `ACCENT_HARVESTER` | `SIGNAL_INFO` | harvester bay identity only — the one permitted non-interactive accent |

Do not introduce new accent colours per-screen. If a colour appears in only one place, it has no learnable meaning.

---

## 3 · Material Vocabulary

Named surfaces, each with one job. Callers say what something is **made of**; appearance follows from that without per-call colour choices.

| Material | Texture feel | Where it belongs |
|---|---|---|
| `powdercoat` | Matte aluminium with fine grain | Panel and dock bodies, HUD chrome |
| `steel` | Brushed bare sheet, slightly cooler | Frames, rails, splitters, toolbars, backdrop |
| `moulded` | Heavy injection-moulded ABS / powdercoated aluminium | Buttons, tabs, toggles, radial ring |
| `canvas` | Matte woven cloth | Drawer/flyout backing, tooltips, callouts |
| `carbon` | Dark carbon weave | Primary action only — at most two per screen |
| `fiberglass` | Slightly translucent laminate | Hazard placards, alert states |
| `toolbox` | Faded oxide-red chipped enamel | Design Lab parts dock & Modular Hull Builder palette |
| `wood` | Warm planed timber with horizontal grain | Paint bay dock, armor station workbench surfaces |
| `bakelite` | Warm marbled phenolic resin | Commander's desk surfaces |

Material textures are 9-sliced PNGs in `assets/textures/ui/`. The bevel is in a 12 px margin ring; the centre is flat and tileable. `build_ui_theme.gd` maps these onto StyleBoxTexture entries. **Do not apply material directly to a control's `material` property unless you have a specific runtime reason** (e.g. the backdrop shader).

### 3.1 Material defaults

Each material carries sensible defaults for `wear`, `grime`, `scale`, and `vignette` in `UITheme.MATERIAL_DEFAULTS`. Override only when the specific use-case demands it — the defaults are tuned for consistency across the whole interface.

### 3.2 The backdrop rule

The backdrop is STEEL at 0.42 brightness. Everything laid on top of it must be ABOVE that brightness. A panel at the same luminance as its backdrop has nowhere to sit — it reads as one flat field regardless of the border between them.

---

## 4 · Typography

The type scale is fixed. Do not introduce arbitrary font sizes; choose the nearest step.

| Token | Size | Face | Use |
|---|---|---|---|
| `FONT_DISPLAY` | 40 px | Stencil (Special Elite) | Title screen wordmark only |
| `FONT_TITLE` | 24 px | Stencil | Screen-level titles |
| `FONT_HEADING` | 17 px | Stencil | Panel/section headers |
| `FONT_BODY` | 15 px | UI sans (default) | All normal reading text |
| `FONT_SMALL` | 13 px | UI sans | Secondary/hint text |
| `FONT_MICRO` | 11 px | Monospace | Dense tabular readouts, footnotes |

**Face allocation:**
- **Stencil (Special Elite):** display/title/heading only. Large, short, carrying the aesthetic tone. At body size it becomes unreadable mush.
- **UI sans (Inter or similar):** everything else. Clean, legible, fast to parse.
- **Monospace:** numeric readouts that need tabular alignment (`HUDValueLabel`, `StatLabel`). Prevents a resource counter from changing width as it ticks.

### 4.1 Theme variations (the full registry)

Set `theme_type_variation` — do not override individual font/color properties unless you're adjusting a *specific instance* from its type default.

| Variation | Base class | Notes |
|---|---|---|
| `DisplayLabel` | Label | 40 px stencil, primary text colour |
| `TitleLabel` | Label | 24 px stencil, primary text colour |
| `HeadingLabel` | Label | 17 px stencil, **amber** (`SIGNAL_HAZARD`) |
| `HintLabel` | Label | 13 px sans, secondary text colour |
| `HUDValueLabel` | Label | 17 px monospace, primary text colour |
| `StatLabel` | Label | 13 px monospace, secondary text colour |
| `CardPanel` | PanelContainer | Powdercoat, SPACE_XL/LG padding — for free-floating cards |
| `HeaderPanel` | PanelContainer | BASE_700 fill + 2 px amber bottom rule — for titled bands |
| `HUDPanel` | PanelContainer | Powdercoat pressed — recessed in-match chrome |
| `InsetPanel` | PanelContainer | Canvas pressed — drawer/list wells |
| `DockPanel` | PanelContainer | Powdercoat, SPACE_SM padding — sidebar docks |
| `DockRail` | PanelContainer | Steel, XS padding — thin rail strips |
| `FlyoutPanel` | PanelContainer | Canvas, MD padding — floating overlays |
| `CalloutPanel` | PanelContainer | Canvas, XS padding — annotation callouts |
| `PrimaryButton` | Button | Carbon tinted go-green — one per screen maximum |
| `DangerButton` | Button | Fiberglass tinted alert-red — destructive actions |
| `TabButton` | Button | Moulded — inactive tabs are PRESSED, active tab lifts. Also the header for a `UIToolbox` tier, so a closed tier reads as pressed shut |
| `ListButton` | Button | Flat/borderless at rest, hazard left edge when selected |
| `NavCard` | Button | Main-menu destination cards. The one **flat** stylebox variation: its identity is an asymmetric left gutter (5 px, 6 px on hover) that a 9-sliced plate cannot express, because `StyleBoxTexture` has no border properties |

---

## 5 · Spacing

**4 px base grid.** Every margin and gap must be one of the tokens below.

| Token | Value | Typical use |
|---|---|---|
| `SPACE_XS` | 4 px | tight gutter, icon padding |
| `SPACE_SM` | 8 px | element separation, inner card padding |
| `SPACE_MD` | 12 px | standard padding inside panels |
| `SPACE_LG` | 20 px | section separation |
| `SPACE_XL` | 32 px | screen-level margins, modal card padding |

**Minimum hit target:** `HIT_TARGET_MIN = 32 px`. Nothing interactive should be smaller during real-time play.

**Toolbar height:** `TOOLBAR_HEIGHT = 64 px`. The Design Lab top toolbar owns this slot; no dock or panel should begin above it.

---

## 6 · Geometry

Near-square corners. Stamped and machined panels have a barely-broken edge — 2 px is enough to prevent aliasing without reading as "consumer-software soft".

| Token | Value | Use |
|---|---|---|
| `RADIUS_PANEL` | 2 px | panel and card corners |
| `RADIUS_CONTROL` | 2 px | button and input corners |
| `BORDER_HAIRLINE` | 1 px | standard borders, dividers |
| `BORDER_EMPHASIS` | 2 px | active states, focus rings, accent rules |

---

## 6a · Elevation

Surfaces sit at one of four heights. Before this existed nothing in the interface cast a shadow at all — every panel, dock, flyout and tooltip occupied the same plane, separated only by a 1 px border. That reads as a *diagram* of an interface rather than a stack of hardware, and it was the largest single reason the chrome looked unfinished beside the 3D.

| Tier | Blur | Offset | Used by |
|---|---|---|---|
| `workbench` (L0) | 0 | 0 | `cutting_mat`, `cardboard`, `kraft`, `cork`, `chipboard` — backdrop plane |
| `flush` (L1) | 0 | 0 | `HUDPanel`, `InsetPanel` — recessed surfaces |
| `raised` (L2) | 3 px | 1 px | `CardPanel`, `DockPanel`, `HeaderPanel`, `DockRail`, buttons |
| `floating` (L3) | 8 px | 3 px | `FlyoutPanel`, `CalloutPanel`, `TooltipPanel` |
| `modal` (L4) | 18 px | 6 px | dialogs over a scrim |

---

## 6b · Tactile Hardware & Radial Controls

### L0 Workbench Layer
The base layer (L0) establishes the physical desk surface behind schematic viewports and lab staging. Five materials are available: `cutting_mat` (green self-healing vinyl with grid), `cardboard`, `kraft`, `cork`, and `chipboard`. L0 materials are background planes only and must never be applied to a control descended from a panel.

### UIPropStage & 3D Stamped Hardware
Interactive buttons and switches can be physical 3D hardware rendered into a single shared `UIPropStage` SubViewport rather than flat 2D textures:
- **`StampedButton`**: 2D control that binds a 3D prop mesh (e.g. `push_button`, `toggle`, `rotary`, `rocker`, `knurled_dial`, `dzus_fastener`, `latch`) on the screen's `UIPropStage`.
- **Procedural PBR & POM**: Shaders utilize Parallax Occlusion Mapping (POM) raymarching with height maps, ORM channels, and equipment dust accumulation.
- **Single SubViewport invariant**: Screens with multiple stamped controls share one viewport, updating only on dirty state changes.

### Machined Radials & Gestures
- **`RingDraw`**: Shared drawing library for machined dials, tick marks, bezels, and legend plates.
- **`ModuleActionRing`**: Persistent radial ring centered on 3D modules with silhouette-sized inner clearance (`D13`) that never obscures the underlying module mesh.
- **`MarkingMenu`**: Transient stroke-driven marking menu (`D9`, `D14`). Quick strokes (< 200 ms, > 24 px) commit immediately with zero visual pop; slow holds (>= 200 ms) reveal the dial. Releasing outside the outer radius commits the unbounded sector.

Three rules, each of which cost something to learn:

**The shadow is warm near-black, never neutral.** On a warm-neutral ground a cool or grey shadow does not read as shadow — it reads as grime, or as a dark smudge painted on the panel. Matching the base hue keeps it reading as absence of light. Same reasoning as the palette's warm-vs-blue-black note.

**A recessed surface must not cast.** `flush` is 0, not "a small shadow". `HUDPanel` and `InsetPanel` are set *into* their parent; giving them a shadow would claim they float above the very thing they are sunk into.

**The offset is much smaller than the blur, and always straight down.** A large offset with a small blur is the drop-shadow of 2000s web design; hardware resting on a surface has a tight contact shadow directly beneath it. Down rather than diagonal because the plate bevels are lit from the top-left — a shadow that disagrees with the bevel highlight makes both read as texture noise.

Use `Tokens.elevation(tier)` or `Tokens.apply_elevation(box, tier)` rather than hand-picking the three numbers. They only look right in the tuned combinations: a blur of 8 with an offset of 1 gives a floating panel a contact shadow, which reads as a rendering mistake rather than as a different height.

> **Implementation constraint worth knowing before you reach for a shadow.** `StyleBoxFlat` supports shadows; `StyleBoxTexture` does not, and every plate-backed variation is texture-backed. Godot draws exactly one stylebox per control state, so nothing can be stacked behind. Elevation for those variations is therefore **baked into the plate PNG** as a transparent pad, with `expand_margin` letting it draw outside the control rect. See UI_IMPLEMENTATION_PLAN.md Priority 2.

---

## 6b · Motion

All timings live in `ui_tokens.gd`; `ui_anim.gd` re-exports them so motion and appearance cannot drift apart. A hover transition that outlasts the theme's hover plate swap reads as two separate effects.

| Token | Duration | Interaction |
|---|---|---|
| `DURATION_INSTANT` | 60 ms | hover acknowledgement |
| `DURATION_FAST` | 120 ms | press feedback, ring pop |
| `DURATION_NORMAL` | 220 ms | panel/card entrance, toast, fade-in |
| `DURATION_SLOW` | 400 ms | scene fade-out, full-screen overlay |
| `STAGGER_STEP` | 35 ms | per-child delay in a list entrance |

Standard easing is `EASE_OUT` with `TRANS_CUBIC`. **Everything is short.** Gritty means mechanical, not showy: a mechanism responds immediately or it feels broken, and anything above `DURATION_SLOW` on an *interaction* reads as the game hesitating.

**The named primitives, and when each is right:**

| Primitive | Use |
|---|---|
| `hover_lift` / `hover_settle` | 1.03 scale. The theme already swaps the plate, so this only adds physicality — a larger scale makes a button in a dense row overlap its neighbours |
| `button_press_feedback` | Squash-release on press |
| `slide_in` | A panel or card entering, from the edge it belongs to |
| `stagger_in` | A list or grid. Total capped at 0.45 s — at 35 ms per child a 40-row list takes 1.4 s and reads as a loading bug rather than polish |
| `ring_pop` | The radial menu only. The **one** sanctioned overshoot (`TRANS_BACK`), because a ring springing open is a mechanism |
| `value_flash` | A number that changed meaningfully. Tweens `font_color`, not `modulate`, so it tints the text rather than the subtree |
| `shake` | Rejected input. Small and fast — a big shake is comedy, and the chrome is on the sincere side of the tone split |
| `fade` | Scene transitions and dimming overlays |

**Asymmetry is deliberate.** Leaving a screen takes `DURATION_SLOW`; arriving takes `DURATION_NORMAL`. The player is already waiting to act on the new screen, and a symmetric slow fade-in is what makes a game feel sluggish rather than expensive.

**Nothing bounces except the radial ring.** If a new animation wants an overshoot, that is a signal the interaction is being dramatised.

---

## 7 · Layout Structure — Main Menu

The current main menu establishes a pattern the other out-of-match screens should follow.

```
┌─────────────────────────────────────────────────────────┐
│  CONSOLE BAR  (HeaderPanel, full-width, SPACE_LG gap)   │
│  "DESIGN BUREAU / CONSOLE 04"   STATUS   CYCLE INFO     │
├──────────────────┬──────────────┬───────────────────────┤
│  LEFT COLUMN     │  3D VIEWPORT │  STATUS COLUMN        │
│  520 px fixed    │  (flexible)  │  460 px fixed         │
│                  │              │                        │
│  KITBASH COMMAND │  SubViewport │  SPECIFICATION PLACARD│
│  tagline         │  background  │  (CardPanel)           │
│                  │  TURNTABLE   │                        │
│  ┌ Destination ┐ │              │  stat_row × N         │
│  │ Card × 6   │ │              │  (HintLabel / StatLabel│
│  └────────────┘ │              │   pairs)               │
│                  │              │                        │
│  EXIT BUREAU btn │              │                        │
└──────────────────┴──────────────┴───────────────────────┘
```

**Destination card anatomy:**

```
[ 5px amber gutter | TITLE (HeadingLabel) / desc (HintLabel) | BADGE (HintLabel, dark plate) ]
```

- Normal state: dark fill (`BASE 12–15%`) + subtle border (`BASE_400`, ~95% alpha)
- Hover state: slightly lifted fill + amber border (left edge 6 px, others 2 px)
- Pressed state: warm amber-tinted fill + amber border
- The `indicator` (amber 5 px vertical bar at left) shows/hides on hover — not a full border change, just the strip going from `alpha 0 → 1`

**3D showcase:**
- Full-bleed SubViewport behind all 2D chrome. ACES filmic tonemapping, SSAO, bloom.
- Studio grey background (`#626669`), warm key light (`#FFF5E0` at 1.35 energy), cool rim (`#A5BFDA` at 0.85 energy).
- Models rendered in scale-model plastic: `Color(0.38, 0.44, 0.37)`, metallic 0, roughness 0.8.
- Auto-cycles every 30 seconds through saved blueprints then hull chassis fallbacks.

---

## 8 · Interaction & State

**Focus:** A flat `SIGNAL_HAZARD` hairline (2 px) overlay — no fill change. Focus is interface state, not a change of the control's material.

**Hover:** Lift the fill one step (BASE_700 → BASE_600) or switch to the material's "hover" plate. Do not change the signal colour or introduce a new colour; hover is not meaningful state — it is a readiness cue.

**Pressed/Selected:** Invert the bevel (switch to the "pressed" plate) so the control reads as physically moving down. Tabs invert the direction — inactive tabs are PRESSED (sunk), the active tab LIFTS.

**Disabled:** The material's "disabled" plate (held darker, muted bevel) plus `TEXT_DISABLED` font colour. Icons dim alongside the control.

### 8.1 Audio feedback

Sound and motion are attached by the **same call** — `UIFeedback.wire(ctrl, role)` — and that is a rule, not a convenience. They have to fire within a few milliseconds of each other or they read as two separate effects. Wiring them separately is how they drift, and they already had: `main_menu.gd` was once the only screen in the game with any UI audio at all, hand-rolled at three sites, with no motion attached and every other screen silent.

Hover is the same sound everywhere — it is a readiness cue, not meaningful state, so it does not vary by what the control does. **Press varies, because that is the moment the control's meaning lands:**

| Role | Sound | For |
|---|---|---|
| `default` | click | ordinary navigation and toggles |
| `confirm` | `radio_ack` | committing — starting a match, queueing a unit |
| `select` | select | picking from a set — a part, a design, a tab |
| `place` | place | putting something into the world or a slot |
| `reject` | error | a refused interaction; pair with `shake` |
| `danger` | `warning_banner` | destructive. Deleting a design must not sound like changing a dropdown |

Two constraints:

**Never let a UI click repeat identically.** `AudioManager.play_sfx()` varies pitch per play; flat repetition is a distinctly cheap-sounding tell.

**Interface audio is on the SINCERE side of the tone split.** `CORE_DESIGN_LANGUAGE.md` §6 puts the absurdity in the *ordnance* — the weapons go "pew pew". Chrome, comms and alerts stay straight. Radio chatter over vocalised weapons is the whole thesis in one moment; a comedy sound on a button would spend the joke in the wrong place.

### 8.2 Locked / Unavailable State

The canonical pattern for locked or unavailable content:

```gdscript
card.disabled = true
card.modulate = Color(1, 1, 1, 0.55)  # dim to 55% opacity
# Red "LOCKED" label using HintLabel with SIGNAL_ALERT color
var lock_label = Style.label("LOCKED", Style.SZ_MICRO, Style.BAD)
card.add_child(lock_label)
card.tooltip_text = "Requires: %s" % ", ".join(missing_names)
```

- `disabled = true` prevents interaction
- `modulate` provides the visual dim (the disabled StyleBox differs from normal by only ~3% luminance, making it nearly invisible on its own)
- Red `LOCKED` label communicates WHY it is unavailable
- `tooltip_text` provides the specific requirement

This pattern is established in `hud_production_deck.gd` and should be reused for any locked/unavailable content (parts exceeding weight capacity, designs that cannot be loaded, etc).

---

## 9 · What This Guide Does Not Cover

- **Whole-game art direction** — philosophy, camera optics, environment, unit finish, the FX/audio split: see `CORE_DESIGN_LANGUAGE.md`, which is the umbrella document
- **3D art direction** (hull materials, faction colours, terrain shaders) — see `VISUAL_ART_DIRECTION.md`
- **HUD layout during battle** — the HUD has its own geometry constraints, so this guide is advisory on its *layout*. Its materials, type and elevation are governed here, and its chrome has been swept onto them
- **What is implemented versus outstanding** — see `UI_IMPLEMENTATION_PLAN.md`

Motion (§6b) and audio feedback (§8.1) **are** specified here now; they were previously deferred to `ui_anim.gd` and `audio_manager.gd`, which meant no one had written down what the interaction was supposed to feel like.
