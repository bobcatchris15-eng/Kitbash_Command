# Skirmish / Battle Performance — Troubleshooting Plan

**Written:** 2026-08-19
**Supersedes:** the Stage 1–5 program in [`PERF_TESTING_RIG.md`](PERF_TESTING_RIG.md).
That document is still accurate about *what the probes are*, but its diagnosis
("unit physics is the entire budget", "the renderer isn't the primary problem")
was measured **before** Fix A, before the DOF removal, and before munitions were
instrumented. Today's log contradicts both conclusions. Read this first.

---

## 1. What the rig already has (do not rebuild any of it)

| Surface | Where | How you use it |
|---|---|---|
| Live overlay | `scripts/perf_hud.gd` | **F3** in a match. Frame mean/p95/worst, hitch counts, draws, munitions, MSAA/vsync/scale |
| In-the-moment dump | `match_director._dump_perf_now()` | **F4** in a match → `user://logs/dump_manual_*.log` |
| Section timing | `scripts/battle/battle_profiler.gd` | 21 named sections, per-frame totals, percentiles, `hitch_blame()` |
| Structured log | `scripts/battle/battle_logger.gd` | On by default. Opt out with `KITBASH_LOG_PROFILING=0` or `MatchRuleSet.log_profiling = false` |
| Log reader | `tools/analyze_perf_log.gd` | `--headless --script tools/analyze_perf_log.gd -- <log_path>` |
| A/B harness | `tools/profile_battle_run.gd` | Same match twice, profiler on then off, differences the distributions |
| Ablation | `tools/probe_perf_attribution.gd` | Disables a script's `_physics_process` by path and re-times |
| ~25 more probes | `tools/probe_*.gd` | scaling, drift, tick variance, gdkernel overhead, vision cost, render cost, per-hitch probes |

Logs land in `%APPDATA%\Godot\app_userdata\Kitbash Command Prototype\logs\`.

**Stage 3 of the old plan is done.** `unit.gd`'s tick is fully wired:
`unit.tick_power`, `unit.terrain_speed`, `unit.advance_orders`,
`unit.tick_economy`, `unit.steer_nav`, `unit.separation`,
`unit.move_and_slide`, all under the `units` parent bucket. Munitions
(`missiles`, `mines`, `sentries`, `decoys`, `drones`) and `resource_node` are
instrumented too. Don't re-wire these.

**Fix A landed, partially.** `MatchRuleSet.skirmish()` and `.operations()` set
`physics_ticks_per_second = 30` (`match_rule_set.gd:246,280`).
`test_range()` does not, so **Test Range runs at 60 Hz and is not a valid perf
proxy for Skirmish** in either direction.

---

## 2. The evidence we already have: 2026-08-19 skirmish log

`logs/battle_2026-08-19T14-13-08_skirmish.log` — `lake_crossing`,
industrialists vs technocrats, 133 s, 1947 frames, 1920×1080, msaa_3d = 4x,
vsync on.

### Frame distribution

```
frames 1858   mean 55.14   p50 1.86   p95 60.95   p99 421.14   worst 35601 ms
over 33ms: 859      over 100ms: 69
```

### Hitch blame (`hitch_blame(100)`)

| Section | Hitches >100 ms | Worst frame |
|---|---|---|
| `<untimed>` | 36 | 35601 ms |
| `commander` | 32 | 352 ms |
| `production` | 1 | 266 ms |

### Section totals

| Section | Total ms | Mean ms | Worst ms | Frames |
|---|---|---|---|---|
| `commander` | 8048.2 | 4.332 | 446.4 | 1858 |
| `place_structure` | 1557.0 | 44.487 | 179.4 | 35 |
| `hud_minimap` | 625.8 | 3.038 | 6.9 | 206 |
| `units` | 546.7 | 0.294 | 2.1 | 1857 |
| `vision` | 345.2 | 1.675 | 40.2 | 206 |
| `production` | 344.7 | 0.186 | 211.3 | 1858 |
| `resource_field` | 172.0 | 0.093 | 0.4 | 1857 |
| everything else (14 sections) | ~462 | — | — | — |
| **sum instrumented** | **12102.6** | | | |

**Instrumented share: 9.1 % of a 133-second match.** 91 % of wall clock falls
outside every section.

### The three multi-second stalls

| Wall time | Frame | Duration |
|---|---|---|
| t = 0.6 s | 1 | 18391 ms |
| t = 27.8 s | 44 | 23151 ms |
| t = 65.7 s | 90 | 35601 ms |

77 seconds of stall inside the first 66 seconds — the first 90 physics frames
span 65.7 s. Steady state only begins around t ≈ 70 s, after which ~1857 frames
run in ~67 s (≈ 28 ticks/s, i.e. 30 Hz holding).

### Steady state (t > 70 s)

66 hitches over 100 ms, **median 301 ms, worst 896 ms**. `commander` is the
largest named contributor.

### What this log cannot tell us

`units_spawned: 2`, `unit_deaths: 0`, `structures_built: 36`. This was a
**base-building session with essentially no combat.** The `units` and `weapons`
numbers here say nothing about the original "under 10 FPS at 6–8 engaged units"
report. Track D exists for exactly that reason.

---

## 3. Three traps in reading these numbers

**3.1 `mean` and `p50` disagree by 30× because these are physics-tick
intervals, not render-frame times.** `Profiler.end_frame()` is called from the
director's `_physics_process`, so the interval it records is tick-to-tick wall
time. p50 = 1.86 ms with mean = 55 ms is the signature of the engine running
**catch-up bursts**: several physics steps back-to-back (~1.9 ms each, because
the sim genuinely is cheap), then one long interval that swallows the render.
Read `worst`, `p99` and `over_100ms`. Ignore `mean`.

**3.2 The 33 ms threshold is meaningless at 30 Hz.** A healthy 30 Hz tick *is*
33.3 ms. `over_33ms: 859` conflates normal ticks with real stalls. Use the
100 ms counters, or make the threshold derive from
`Engine.physics_ticks_per_second`.

**3.3 The `dominant` field on per-hitch log lines is unreliable.**
`BattleProfiler.hitch_blame()` applies `DOMINANCE_SHARE = 0.5` before naming a
culprit; `match_director.gd:3293`'s `log_hitch()` call passes
`Profiler.last_dominant` raw, with no share test. In this log that named
`production` (0.0 ms) as dominant on the 35601 ms frame, and `units` (0.2 ms)
as dominant on a 458 ms frame. **Per-hitch `dominant` values in existing logs
should be discarded**; only the `profiler_summary` blame table is trustworthy.

---

## 4. Defects found while reading the code — fix these before measuring again

Each one either corrupts a measurement or hides one. All are small.

1. **`log_hitch`'s dominant has no dominance test** (§3.3).
   `match_director.gd:3292-3294`. Apply the same `DOMINANCE_SHARE` gate
   `hitch_blame()` uses, or log the share alongside the name.

2. **`engine_ticks_per_second` is snapshotted before it is set.**
   `_evaluate_logging_flags()` → `BattleLogger.begin_match()` runs at
   `match_director.gd:361`; the tick rate is assigned at `:394`. So
   `MATCH_BEGIN` records **60 even when the match runs at 30**, and today's log
   showing 60 is *not* evidence that Fix A failed. Move the snapshot after the
   assignment, or re-log the resolved rate. Until then, confirm the rate from
   the `[match_director] physics_ticks_per_second = 30` stdout line instead.

3. **`project.godot`'s MSAA block is malformed.** Commit `f998adc7` wrote `#`
   comment lines into a Godot ConfigFile; the editor re-saved them collapsed
   into a single quoted key:

   ```
   "2D MSAA is enabled while there is no 2D contentwarningatboot.#Cheapfix,freeperfheadroom.anti_aliasing/quality/msaa_2d"=0
   ```

   The intended `anti_aliasing/quality/msaa_2d=0` no longer exists, so the value
   falls back to the engine default — which happens to be 0, so the intent
   survives by luck. Delete the junk key and set it plainly. Use `;` for
   comments in `project.godot`, not `#`.

4. **`navmesh_dispatch` and `navmesh_callback` recorded zero frames** across a
   match that built 36 structures, and `navmesh` totalled 2.9 ms. Either the
   urgent-rebake path from `38fd3f61` never fires on structure placement, or it
   runs somewhere those tokens don't cover. Answer this before drawing any
   conclusion about navmesh cost — right now we have no measurement at all.

5. **`build_phase` log spam.** 308 events, with `"Surveying terrain"` repeated
   ~20× at an identical timestamp. Harmless to perf, but it pads a 2.5 MB log
   and makes the build timeline unreadable. Dedupe on (label, fraction).

---

## 5. The plan

Five tracks. **A and B are where the time actually is; do them first.** Tracks
are independent — nothing below blocks anything else.

### Track A — the 77 seconds of `<untimed>` stall (highest value)

**Question.** What runs during the 18.4 s / 23.2 s / 35.6 s stalls, all of which
land in `<untimed>` with the sim idle?

Because they occur at t = 0.6 s, 27.8 s and 65.7 s — not just at load — this is
not simply world-build cost. Leading candidates, in order of prior plausibility
for this codebase:

- **Shader / pipeline compilation on first use.** Forward+ compiles on demand.
  A 35 s stall mid-match is the classic shape.
  `tools/probe_shroud_shader_compiles.gd` already exists for one instance of this.
- **Synchronous resource load** — a hull `.glb`, a `_collision.res`, or a
  texture set pulled in the first time a design or structure kind appears.
- **Navmesh bake on the main thread** (see defect 4 — currently unmeasured).
- **Terrain prop / ambient scatter instantiation** on first reveal.

**How to measure.**

1. Re-run with `--verbose` and correlate engine stdout timestamps against the
   three stall frames. Godot logs shader compiles and resource loads there; the
   BattleLogger sees neither.
2. Decompose `<untimed>`: wrap the director's own `_process` (not just
   `_physics_process`), and add explicit sections around `ResourceLoader.load`
   call sites in the battle path and around the navmesh bake dispatch.
3. Check whether the stalls correlate with the *first* instance of a given
   structure or unit kind — `structure_built` events are already in the log and
   can be joined on frame number.

**What the answers mean.**

- *Correlates with first-instance-of-a-kind* → precompile / prewarm. A shader
  warmup pass during the deploy gate plus a preload of the roster's meshes kills
  it outright.
- *Correlates with navmesh* → move the bake off-thread or coarsen it.
- *No correlation, cost spread across the frame* → suspect the renderer and go
  to Track E.

### Track B — the `commander` re-decide spike

**Question.** Why does one AI decision cost up to 446 ms?

`Commander.tick()` is gated (`DECISION_INTERVAL = 2.0`,
`MIN_DECISION_INTERVAL = 0.5`), so the 8048 ms total is concentrated in roughly
66–266 re-decides across the match — **about 30–120 ms per decision, worst
446 ms, every 0.5–2 s.** That cadence matches a "hitchy every second or so" feel
exactly, and `hitch_blame` credits it with 32 of the 69 frames over 100 ms.

`tick()` splits cleanly into `read_state()` → `decide()` → `_execute()`, and
`_execute()` reaches `_world.ai_build_structure()` →
`match_director._ai_placement_site()`, the 192-candidate placement loop that
commit `1e6d1d4e` already had to hoist lookups out of. `read_state()` walks every
unit on both teams and calls `is_visible_to_team()` per enemy unit.

**How to measure.** Add three sections — `commander.read_state`,
`commander.decide`, `commander.execute` — plus a fourth inside
`_ai_placement_site()`. This is a ten-line change and it converts the single
largest named cost from a bucket into an answer. **Do this before optimising
anything in the commander.**

**Fix candidates, once attributed.**

- Placement search dominates → cache the candidate grid; invalidate on
  structure/terrain change rather than rebuilding per decision.
- `read_state()` dominates → it recomputes derived counts the director could
  maintain incrementally (the economy already does this for income).
- Neither dominates and cost is spread → amortise the decision across frames
  (score N candidates per tick, commit when the pass completes). A 2 s decision
  cadence has ample budget to spend 60 frames deciding.

### Track C — `place_structure` at 44 ms mean

**Question.** 35 invocations, mean 44.5 ms, worst 179 ms — every structure
placement is a visible hitch, and a base-building match does 36 of them.

This has history: `tools/probe_building_construction_hitch.gd` exists and was
updated twice. Re-run it, then bisect `place_structure` internally (footprint
legality → terrain prop displacement → mesh build → collider → navmesh hole →
visibility range). `_displace_terrain_props()` and
`_apply_structure_visibility_range()` both walk nodes and are prime suspects.

Note the interaction with Track B: the AI commander triggers placements, so a
commander decision and a structure placement can land on the same frame,
compounding into the 300 ms+ range.

### Track D — the case this log never exercised: actual combat

**Question.** Is the original "under 10 FPS at 6–8 engaged units" report still
reproducible after Fix A, the DOF removal, and the munition instrumentation?

The old 2.4 ms-per-unit figure came from a headless 16-unit measurement at 60 Hz
with the pre-Fix-A tick. Today's `units` bucket is 0.294 ms mean — but with
**two** units and no combat. Neither number describes the case Chris originally
reported. **Do not act on either until this is re-measured.**

**How to measure.** Existing tools, in this order:

1. `tools/profile_battle_run.gd` — 300 s scripted run with harvesters, squads and
   waves; run it twice (profiler on / off) as designed.
2. `tools/probe_perf_scaling.gd` — re-run the 1→48 sweep at 30 Hz and compare
   against the archived 60 Hz curve. Confirms whether the per-unit coefficient
   actually halved.
3. `tools/probe_tick_variance.gd` — steady-state vs combat variance, the specific
   gap the old plan named as most valuable and which today's log still leaves open.

Then reproduce by hand: a real Skirmish, F3 on, drive to 8+ engaged units, F4 at
the moment it feels bad. **Turn vsync off for this** — it pins the readout to
60.0 and hides everything under 16.7 ms.

### Track E — the presentation baseline (upgraded from the old plan's Stage 4)

The old plan deprioritised the renderer on the grounds that headless was already
over budget. **Today's log inverts that argument:** physics ticks complete in
~1.9 ms median and the entire instrumented sim is 9.1 % of wall clock, yet frames
still take hundreds of ms. Whatever owns the remainder is mostly not GDScript.

**Measure, in this order (each is one setting and a re-run):**

1. `msaa_3d` 4x → 2x → off. `perf_hud.gd`'s header documents MSAA at ~31 % of
   frame time on an *empty* map; nothing since should have changed that.
2. vsync off, to see the true frame time rather than the 60 Hz cap.
3. `scaling_3d_scale` at 0.75, to separate fill cost from geometry cost.
4. `hud_minimap` at 3.04 ms mean over 206 frames — it runs about 1 frame in 9 and
   costs 3 ms when it does. That is a large slice of a 30 Hz budget for a
   minimap; check whether the shroud image rebuild is gated on
   `VisionService.shroud_version` (the field exists precisely so it can be).
5. `vision` worst 40.2 ms on a 3.3 Hz tick — one bad vision tick alone blows a
   30 Hz frame. Bisect `tick()` vs `_update_shroud()`.

---

## 6. Instrumentation to add before the next capture

Ordered by measurement value per line changed:

1. `commander.read_state` / `commander.decide` / `commander.execute` sections (Track B).
2. A section inside `_ai_placement_site()` (Tracks B + C).
3. Sections around battle-path `ResourceLoader.load` calls and the navmesh bake
   dispatch (Track A, defect 4).
4. The director's `_process` as well as `_physics_process`, so per-frame
   non-physics work stops landing in `<untimed>`.
5. Fix `log_hitch`'s dominant (defect 1) and the `engine_ticks_per_second`
   snapshot (defect 2).
6. Derive the hitch threshold from the tick rate instead of the 33 ms / 100 ms
   constants (§3.2).

---

## 7. Regression guard

`tests/battle/test_battle_perf.gd` currently holds two collision-mask tests and
**no frame-budget assertion at all**, so nothing in the suite would catch a perf
regression.

Add one headless suite that spawns a fixed unit count on a fixed map, runs a fixed
number of ticks, and asserts a **generous** ceiling on the instrumented sim total
— not on wall-clock frame time, which is machine-dependent and would flake.
Assert on `BattleProfiler.sections()` sums, which are deterministic in shape if
not in exact value. A guard that only catches a 3× blowup is still worth having;
a tight one will flake and get deleted.

---

## 8. Suggested run order

```
Day 1   Fix defects 1-3 and 5 (§4). Add instrumentation items 1-2, 5 (§6).
        Re-run the same Skirmish and capture a clean log.
        -> Track B is answered or narrowed in one capture.

Day 2   --verbose run correlated against stall frames (Track A).
        Add instrumentation item 3, re-capture.
        -> the 77 seconds is named.

Day 3   Track E's five sweeps. Cheap, mechanical, and one of them probably
        moves steady state on its own.

Day 4   Track D: profile_battle_run.gd x2, probe_perf_scaling.gd,
        probe_tick_variance.gd. Establishes whether the combat case is still
        a problem after Fix A.

Day 5   Track C, then the regression guard (§7).
```

---

## 9. Open questions

1. **Was the 2026-08-19 session the one that felt bad?** 36 structures, 2 units,
   no deaths reads as a base-building test rather than a fight. If the bad feel
   was during combat, that session is unlogged and Track D moves to the front.
2. **Did the multi-second stalls present as freezes?** A 35 s stall is not
   something you'd miss — if it was a freeze, Track A is the whole story and
   everything else is secondary. If the session looked normal, the stall
   measurement itself is suspect and should be re-validated first.
3. **Is 30 Hz visibly acceptable?** Fix A is live in Skirmish and Operations. If
   unit motion looks steppy, that constrains every fix below it.
4. **What is the target?** "60 fps at 16 engaged units on this machine" and
   "30 fps with no hitch over 100 ms" imply very different work. The plan above
   is written for the second.

---

# 10. Log review — 2026-08-19 playtest set

625 battle logs were written today. Nearly all are harness runs; **7 are real
playtests**. The §6 instrumentation landed between captures, so the later logs
are far more informative than the 14-13-08 one §2 is based on. Instrumented
share went **9.1 % → 78 %**.

**The reference capture is `battle_2026-08-19T19-57-23_skirmish.log`** —
lake_crossing, 258.8 s, 30 Hz, 15 units, 59 structures, 1920×1080, msaa 4x,
vsync on. It is the only log today with a realistic unit count. Everything
below comes from it unless stated.

## 10.1 Headline: the real frame rate

Derived from `render_frame` (the director's `_process`, which is an empty
timing probe) and the physics section counts:

```
rendered frames  1172 over 258.8 s  =   4.53 fps
physics ticks    3768 over 258.8 s  =  14.56 Hz   (target 30)
```

The sim is running at **half real-time** and the screen at **4.5 fps**. Since
`_process` itself measures 0.001 ms mean, the gap between instrumented physics
work and wall clock is the renderer. Track E is confirmed, not speculative.

## 10.2 Headline: `unit.move_and_slide` scales superlinearly

Per-30-second buckets, cost per physics frame:

| Units alive | `units` ms/frame | `move_and_slide` ms/frame | per unit (`units`) |
|---|---|---|---|
| 2 | 0.36 | 0.02 | 0.18 ms |
| 7 | 5.21 | 3.55 | 0.74 ms |
| 15 | 124.40 | 61.27 | **8.29 ms** |

**Per-unit cost rises ~46× between 2 and 15 units.** That is not linear, and it
contradicts `probe_perf_scaling.gd`'s archived "linear, no O(n²)" finding. The
likely reason the probe missed it: it spawns units on a ring at spread
positions, while real play clusters them into squads — and `move_and_slide`
cost is a function of how many *other* bodies each sweep touches.

`move_and_slide` alone is 44.0 s of the 258.8 s match (17 %), 68 % of the
`units` bucket. Everything else inside the unit tick is noise by comparison
(`terrain_speed` 0.14 ms, `tick_economy` 0.10 ms, `separation` 0.06 ms,
`advance_orders` 0.02 ms).

**This is the original "under 10 FPS at 6–8 engaged units" report, reproduced
and localised.** It is collision geometry, not GDScript.

## 10.3 `navmesh_sync_rebake` — 29 s of a 259 s match

`TerrainBuilder.rebake_ground_amphibious_tiles_sync()`, called 107 times for
59 structures, **mean 272 ms, worst 626 ms**, all synchronous on the main
thread. 11 % of the match, and the dominant section on the worst steady-state
hitches (880 ms, 871 ms, 761 ms). Roughly two rebakes per structure placed.

## 10.4 `commander.execute` — 250 ms per call, mostly unattributed

Track B's prediction was half right. The cost is entirely in `_execute`
(17 746 ms) — `read_state` is 26.7 ms total and `decide` is 4.1 ms total, so
those are solved and need no further work. But the placement search is *not*
the culprit either: `ai_placement_site` is only 180.7 ms total (3.3 ms mean).

Of `commander.execute`'s 250 ms mean, nested `place_structure` (47.9 ms) and
`ai_placement_site` (3.3 ms) account for ~51 ms. **~200 ms per call is still
unnamed**, inside `ai_build_structure` / `ai_build_unit` / `ai_build_defence`.

Note these sections **nest** — `commander.execute` contains `place_structure`
which contains `battle_resource_load` — so the 78 % instrumented figure
double-counts. Top-level-only, it is ~54 %.

## 10.5 Correction to §2 and §5 Track A: the early "stalls" are probably idle gaps

§2 read three multi-second `<untimed>` stalls as compute. That looks wrong.
In the reference log the equivalents land on **frames 1, 44 and 86** — and the
14-13-08 log has the same shape at **frames 1, 44 and 90**. Identical frame
indices across two independent sessions, with `units_alive: 0` and no section
time recorded, is the signature of *wall clock passing while the director is
not ticking* (deploy gate, HQ placement, camera intro) — not of a stall.

The frame-1 value is definitely an artifact: it reads 189 003 ms in a
258.8 s match, i.e. the profiler's `_frame_start` baseline predates the match.

**Discard frame-1 hitch values, and treat frames 44/86 as idle gaps until
proven otherwise.** Confirm cheaply by watching whether the deploy gate is on
screen at those moments. This demotes Track A from "highest value" to a
30-minute confirmation.

## 10.6 Load time: terrain mesh is the whole of it

Across all 631 runs with build phases:

```
time-to-Ready   p50 15.7 s   p95 44.9 s   max 83.6 s
```

Essentially all of it is one phase, **"Sculpting terrain mesh"** — mean 21.2 s,
max 81.9 s. Every other phase is under 0.4 s. By map (median):

| Map | Median | Map | Median |
|---|---|---|---|
| scattered_peaks | 55.8 s | coastal_strand | 19.4 s |
| lake_crossing | 27.8 s | twin_summits | 12.3 s |
| ore_basin | 20.2 s | highland_chokepoint | 11.1 s |
| twin_bridges | 20.0 s | urban_sprawl | 10.9 s |
| open_plains | 19.8 s | close_quarters | 9.8 s |

**But 7 runs built lake_crossing in ~3 s** — the same map that medians 27.8 s.
Checked and ruled out as explanations: concurrent processes, viewport size,
time of day, warming over the day (it gets *slower* late: 36.1 s, 34.4 s).
All 7 fast runs are real playtests. **Finding out what makes those 3 s is the
highest-value load-time question** — a 9× speedup already exists in the code
path and something is failing to take it.

## 10.7 Log hygiene

- 625 logs in one day, ~600 of them harness runs on `scattered_peaks`
  (identical 3 units / 2 structures / ~70 frames). They swamp the directory and
  the real playtests are hard to find. Give suite runs
  `log_profiling = false`, or a distinct filename prefix.
- The `build_phase` duplicate spam (§4.5) is still present — 308 events per
  run, with one label repeated ~20× at an identical timestamp.
- `render_frame` is deliberately an empty section. Worth a comment in the log
  reader so a future reader doesn't mistake 0.001 ms for a broken measurement.

## 10.8 Revised priority order

Superseding §8. Ranked by measured cost, cheapest decisive experiment first.

1. **`unit.move_and_slide` collider cost** (§10.2) — 17 % of the match and the
   cause of the original report. Experiment: force every battle unit to a
   single capsule/box collider, re-run the same playtest, compare the
   `units` bucket at 15 units. One afternoon, and it either confirms collision
   geometry or eliminates it. Suspects, in order: the multi-piece convex hull
   decomposition (`<id>_collision.res`, 2–5 shapes on 34 hulls), the per-module
   `Area3D` hit volumes on `UNIT_MODULES`, and unit-vs-unit sweep pairs.
2. **`navmesh_sync_rebake`** (§10.3) — 11 % of the match, trivially reducible.
   Coalesce the ~2-per-structure rebakes into one, debounce across a build
   burst, or move it off the main thread.
3. **The renderer** (§10.1) — 4.5 fps rendered while the sim runs at 14.5 Hz.
   Run §5 Track E's five sweeps; they are mechanical and one of them likely
   moves this a lot (msaa 4x at 1920×1080 is the leading suspect).
4. **`commander.execute`'s missing 200 ms** (§10.4) — one more instrumentation
   pass inside the three `ai_build_*` functions.
5. **Terrain build fast path** (§10.6) — find why 7 runs did in 3 s what
   normally takes 28 s.
6. **`production` at 4.27 ms every frame** (worst 429 ms) — high for a
   bookkeeping tick; it reached 9.2 s per 30 s window late in the match.
7. **Confirm the idle-gap reading** (§10.5) before spending anything on Track A.
8. Log hygiene (§10.7), then the regression guard (§7) — now writable against
   real numbers: assert the `units` bucket stays under ~2 ms/unit/frame at 16
   units.

---

# 11. Results — `battle_2026-08-19T21-41-57_skirmish.log`

First capture with the §10 instrumentation in place. lake_crossing, 221.7 s,
30 Hz, **21 units**, 51 structures, 1920×1080, msaa 4x, vsync on. Four of the
five open questions are answered outright.

## 11.1 ANSWERED — load time is ambient scatter, not the navmesh

```
terrain.ground_visual_mesh    2 728.8 ms
terrain.ground_material         148.1 ms
terrain.building_holes            0.0 ms   (1 hole)
terrain.navmesh_dispatch        139.8 ms   (289 tiles)
terrain.navmesh_wait             91.2 ms   (289 tiles)
terrain.spawn_visuals        24 458.2 ms   (255 resource nodes)
```

**`TerrainBuilder.spawn_visuals` is 24.5 s of a ~27.5 s build — 89 % of the load
screen.** The navmesh, which the archived plan and §10.6 both assumed was the
cost, is **231 ms total across 289 tiles**.

This also explains the §10.6 spread: the fast ~3 s runs are the ones that skip
or shorten scatter, not ones with a faster navmesh. `map_catalog.gd` already has
a `disable_ambient_scatter` flag (added for `test_range`), which is why Test
Range never showed this.

255 resource nodes for 24.5 s is ~96 ms per node — that is the number to chase,
not the node count.

## 11.2 ANSWERED — `commander.execute`'s missing 200 ms is the navmesh rebake

The chain, all nested:

```
commander.execute        192.5 ms mean  (72 calls)
└ ai.build_production    294.8 ms mean  (47 calls)
  └ ai.build_structure   294.7 ms mean  (47 calls)
    ├ place_structure     47.7 ms mean  (48 calls)
    │ └ place.displace_props  40.4 ms   ← 85 % of place_structure
    └ navmesh_sync_rebake 239.5 ms mean ← 81 % of ai.build_structure
```

`_mark_navmesh_dirty(urgent = true)` performs the Recast rebake **inline and
synchronously** in the same call, so every AI building placement blocks the main
thread for ~240 ms. That is the entire unexplained cost from §10.4, and it makes
§10.8 items 2 and 4 the same fix rather than two.

## 11.3 ANSWERED — the rebakes are not duplicated; the per-tile cost is the problem

55 rebakes for 51 structures — **1:1, not the 2:1 §10.3 suspected.**

```
ms     total 13 171.7   mean 239.5   p50 225.2   max 411.2
tiles  mean 3.84 (47 of 55 rebakes touch exactly 4)
cost   62.4 ms per tile
```

So de-duplication is off the table. The fix is either making the bake
asynchronous (it already has a lazy path — `_mark_navmesh_dirty(false)`) or
reducing the 62 ms per-tile cost. Debouncing a build burst would help the AI
case, where 47 placements arrive over a few minutes.

## 11.4 ANSWERED — the sim is healthy; rendering is the visible problem

The new `perf_sample` event states it directly:

```
physics_hz   min 29.03   p50 29.96   mean 30.01   (target 30)
render_fps   min  3.66   p50 10.60   mean 10.09   max 17.72
draw_calls   p50 867     render_objects p50 1708
```

**Correction to §10.1:** I reported the sim running at 14.56 Hz, half its target.
That was wrong — it came from counting `section` log entries per time bucket,
which undercounts because a section only appears on frames where it recorded
time. The direct counter shows physics holding **30.0 Hz throughout**. The
rendered frame rate is the real problem, and it degrades from ~17 fps early to
**3.7 fps at 21 units / 51 structures**.

867 draw calls and 1708 objects are not high. This is not a draw-call-count
problem, which points Track E at fill rate and shading — msaa 4x at 1920×1080
first — rather than at batching.

Note the main thread is also over half consumed by sim work: top-level sections
sum to ~122 s of the 221.7 s match (55 %), so the renderer is competing for what
is left.

## 11.5 PARTLY ANSWERED — `move_and_slide` improved 5×, still the largest cost

```
units                75 285.2 ms   mean 18.04 ms/frame   (34 % of the match)
└ unit.move_and_slide 67 441.4 ms   mean 16.16 ms/frame   (30 % of the match)
```

At 21 units that is **0.77 ms per unit per frame, down from 4.08 ms at 15 units**
in the 19-57-23 capture — a ~5× per-unit improvement from the switch to a single
convex hull fit (`unit_assembly._add_hull_collider`). That change worked.

The collider census confirms the hull side is now minimal, and locates what is
left:

| Design | Body shapes | Module areas | Module shapes | Total | Count |
|---|---|---|---|---|---|
| Breaker TD | 1 | 5 | 11 | 12 | ×11 |
| GravelGulper No. 7 | 1 | 14 | 47 | 48 | ×7 |
| Magpie Ore Hauler | 1 | 14 | 47 | 48 | ×3 |

**612 collision shapes across 21 units, mean 29.1 per unit** — and only 21 of
those are on the bodies that move. The rest are module hit volumes on
`UNIT_MODULES`, which weapons query and `move_and_slide` does not.

So 16 ms per frame is being spent sweeping **21 single-shape bodies**. That is
too much for body-vs-body, which makes the **ground collider** the leading
suspect: every unit sweeps its hull against the terrain's concave trimesh every
tick. Next experiment: swap the ground `CollisionShape3D` for a primitive plane
on a flat test map and re-measure. If it collapses, terrain collision is the
answer and a heightmap collider or per-unit ground raycast replaces it.

## 11.6 CONFIRMED — the frame-1 artifact was an artifact

`first_frame_ms: 4131.7` is now reported separately, and the worst in-match frame
is **823 ms**, down from 28 133 ms. The multi-second "stalls" of §2 and §10.5 do
not appear anywhere in this capture. The distribution is also no longer bimodal
(p50 38.7 ms against a 33.3 ms tick period, mean 44.9) — the p50 1.86 ms
catch-up signature is gone. §10.5's reading was correct.

## 11.7 New, smaller findings

- **`place.displace_props` is 85 % of `place_structure`** (40.4 ms of 47.7 ms).
  `place.setup` — mesh, collider, the whole structure build — is 6.9 ms. Track C
  is answered: it is the terrain-prop walk, and it is almost certainly the same
  root cause as §11.1, since scatter density is what it walks.
- **`production`'s spikes are structure completion.** `production.complete_structure`
  is 243.4 ms mean over 6 calls (worst 314.5 ms); the section's own mean is
  0.79 ms. `production.complete_unit` (76.1 ms × 19) is just `spawn_unit` nested
  inside it.
- **`vision` doubled to 15.0 ms mean** (from 8.2 ms), worst 44.1 ms, on 463
  ticks. At 30 Hz one vision tick is now half a frame budget.
- **`unit.steer_nav` collapsed** from 5.41 ms to 0.24 ms mean.
- **`spawn.assemble` improved** from 119.6 ms to 72.3 ms.

## 11.8 Bug found and fixed while instrumenting

`production_service.gd`'s unit-completion block was **duplicated verbatim with
no `return` between the copies** (present in `HEAD` at `9474128c`). Every
completed unit ran it twice: a second `q.pop_front()` discarded the next queued
job without building it, and a second `unit_completed.emit()` spawned a phantom
second vehicle from the same blueprint — at `spawn_unit`'s ~76 ms each.

Removed. This is a behaviour change, not instrumentation, and it was not
optional: timing one copy while the other ran unwrapped would have reported half
the real cost.

## 11.9 Revised priorities

1. **`terrain.spawn_visuals`** (§11.1) — 24.5 s of a 27.5 s load, ~96 ms per
   resource node. Biggest single number anywhere in these logs and it is paid on
   every single match start.
2. **Make the urgent navmesh rebake async or debounced** (§11.2, §11.3) — one
   fix that removes ~13 s of main-thread blocking and 81 % of the AI's decision
   cost.
3. **Track E's render sweeps** (§11.4) — 3.7 fps at 867 draw calls is a fill /
   shading problem; msaa 4x first.
4. **Terrain-collider experiment for `move_and_slide`** (§11.5) — 16 ms/frame
   for 21 single-shape bodies points at the ground trimesh.
5. `place.displace_props` (§11.7) — likely falls out of fix 1.
6. `vision` at 15 ms mean (§11.7).

---

# 12. Results — `battle_2026-08-20T15-38-42_skirmish.log` + four-fix bundle

**Captured:** 2026-08-20, 30.6 min, lake_crossing, industrialists vs
technocrats, msaa 2x, vsync on, 39 units, 116 structures, real combat
(13 unit deaths, 67 structure deaths).

## 12.1 Headline: Day 1-3 stuck; new bottleneck is render + collision in dense scenes

Frame distribution: mean 74.3 ms, p50 41.3 ms, p95 90.0 ms, p99 132.4 ms,
worst 729,660 ms (frame-1 artifact; first_frame_ms is 88,260 ms, separately
reportable now). Hitches over 100 ms: 895.

Hitch blame (hitch_blame_100):
- `<untimed>`: 591 hitches, worst 729,660 ms
- `units`: 171 hitches, worst 481 ms
- `vision`: 127 hitches, worst 141 ms
- `production`: 6 hitches, worst 140 ms

§11's three multi-second `<untimed>` stalls are gone. `navmesh_dispatch`
is now 24 ms total over 141 calls (mean 0.17 ms) — was 13,172 ms over 55
calls (mean 239 ms). `commander.execute` is 1,342 ms / mean 6.0 ms — was
17,746 ms / mean 250 ms. The fix bundle delivered.

What is new: the per-sample `render_fps` distribution. Bucketed by
`units_alive`:

```
units_alive   n    mean   median  min    max    mean_objects  mean_draws
 0-4        397   20.52   23.44   6.94  27.24   1820        1012
 5-9         16   19.67   19.79  18.41  20.28   1963        1178
10-14        23   11.99   12.84   3.64  20.00   1780        1048
15-19        85    3.75    3.75   3.64   3.87   1691         953      <-- floor
20-24         4    3.77    3.78   3.67   3.87   2168        1290
25-29        41    7.24    3.78   3.65  18.32   3443        2028
30-34        47   10.94    3.82   3.65  36.58   3799        2078
35-39       140    4.30    3.76   3.64  16.60   3898        2303
```

`render_fps` hard-caps at **3.75 fps = 266 ms per frame** the moment
`units_alive ≥ 15`. It is not a vsync cap (vsync on, max_fps=0, cap
should be 16.7 ms — we are 16× over that). It is the render pipeline
taking a quarter second per frame.

Correlations with `render_fps` (negative = more cost):
- vs `structures_alive`: r = −0.81
- vs `units_alive`: r = −0.75
- vs `draw_calls`: r = −0.61
- vs `render_objects`: r = −0.57

Strong, near-linear cost in scene density. Not a per-call cost (1700 vs
3900 draw calls hit the same floor) — it is per-visible-object work, so
fillrate / per-light / per-mesh, not draw-call-count work.

The user's "right up until I start exploring" maps to a specific event
in the data: a 24-hitch cluster at **frame 8000-9000** while
`units_alive` is still 3-4 and `structures_alive` is 36. The hitches
are all `<untimed>` (render-only). At that point the player has moved
the camera off the home base and the engine is compiling shaders /
uploading textures for the newly-visible geometry. That is a
first-time-per-area cost. The longer collapse at frame 15000+ is the
steady-state, driven by unit count.

## 12.2 Section totals vs §11.6

```
                              then (21 u/51 s)  now (39 u/116 s)
unit.move_and_slide                67,441 ms         389,874 ms    (5.8×, match is 5.8× longer)
unit.steer_nav                      5,553 ms          15,910 ms
vision                             53,706 ms          53,706 ms    (same: same fleet of vision ticks)
weapons                             4,983 ms          16,596 ms
navmesh_dispatch                    13,172 ms             24 ms    (−99.8 %)
commander.execute                   17,746 ms          1,342 ms    (−92 %)
ai.build_structure                 13,860 ms          1,332 ms    (−90 %)
production.complete_structure      11,302 ms             81 ms    (−99 %)
place.displace_props                 353 ms              9 ms    (−97 %)
hud_minimap                         5,553 ms        not present (the new HUD minimap doesn't bucket here)
```

The `units` bucket grew linearly with match length; per-unit cost at 39
units is roughly 0.77 ms/unit/frame, same shape as §11.5's 21-unit
figure. The collision cost has not changed; the *number* of units
has. The way to reduce per-frame `units` cost is to simulate fewer
units per frame, which is what fix A below does.

## 12.3 The four fixes shipped 2026-08-20

User asked for everything in §11.9 except the structural unit cap. The
implemented fixes:

### Fix A — Distant physics cull (`scripts/battle/units/unit.gd`)

A unit that is more than 90 m from the active camera and is not a
harvester has its whole `_physics_process` skipped. Order state is
preserved (`current_order` / `order_queue`); the unit "wakes up" one
frame after the camera comes back in range.

Why 90 m, not the 110 m `visibility_range_end`: a unit the player can
still see on screen has stopped moving is the failure case to avoid.
90 m is just outside the typical base-to-base distance on lake_crossing
(240 half-extent, bases at z=±102). Why not gated on `fog_hidden`:
`fog_hidden` is the LOCAL team view of visibility, not a function of
camera motion; a unit the player has just spotted but not yet moved
the camera to is the EXACT unit we want to keep simulating because
the AI is about to issue a counter-order.

Expected payoff (linear in units past the cull distance): at 30 units
on a typical map, 10-15 of them are usually outside the camera's
immediate area, and each cull saves the full 17 ms of
`unit.move_and_slide` + 0.75 ms of `unit.steer_nav` + everything else
in the tick. With the camera on the home base, every enemy unit is
past 90 m, so 80-100% of the per-frame physics cost should drop
in the early game.

### Fix B — Dynamic light cap (`scripts/light_cap.gd` + `scenes/Battle.tscn`)

A scene-local `Node` (named `LightCap`) under the Battle root runs a
5 Hz scene-tree scan, finds every `OmniLight3D` and `SpotLight3D`
(excluding the `DirectionalLight3D` sun, which is one node, already
paid for by Forward+, and zeroing it turns the scene unlit), sorts
by `distance_squared + 625` (so a 30 m combat light beats a 5 m idle
light), and zeroes `light_energy` on the lights past `max_lights=16`.
The first time the cap touches a light it captures the original
energy so a later in-budget frame can restore it.

A scene-local node, not an autoload, because the cap is a match-only
concern: the Design Lab has its own (different) lighting model, the
Blueprint Library uses three static rig lights, the loading preview
is its own pre-lit scene. A child of the Battle scene is active iff
the Battle is mounted, which is the condition we want.

Tunable in the inspector: `max_lights` (default 16) and `bypass`
(default false). Setting `max_lights=0` is the lights-off test
called out in §5 Track E.

### Fix C — Track E probe (`tools/probe_track_e.gd`)

A read-only probe that reports the current msaa, vsync, scaling and
light-cap values, plus the per-knob Track E recommendation. No
auto-tuning: the user still has to flip the knobs in the editor
between captures. Run with:

```
./Godot_v4.7.1-stable_win64_console.exe --headless --path . --script tools/probe_track_e.gd
```

### Fix D — Terrain-collider experiment (`scripts/battle/match_director.gd` + `data/maps/test_range.json`)

The §11.5 hypothesis (heightmap is the cost of `unit.move_and_slide`)
gets a per-map `flat_ground_collider` flag. When set, the ground
`CollisionShape3D` becomes a single `BoxShape3D` (2*half × 1 × 2*half,
centered on y=-0.5). The visual mesh is unchanged. Set on
`test_range.json` (the canonical experiment map; it has no hills,
so the visual stays correct). The diff in the `units` section
between a real run on the same map and a flagged run is the
ground-heightmap contribution.

`open_plains.json` deliberately does NOT get the flag — it has
±10 m hills, so a flat collider would create a visual mismatch
(units walking through hills). The flag is the right shape for any
map that is genuinely flat or for synthetic test maps.

### Fix E — Per-map scatter density (`scripts/terrain_builder.gd` + `data/maps/lake_crossing.json`)

Adds `ambient_scatter_density` to the map_def `FIELD_SPEC`. The value
(default 1.0) multiplies both the cluster count and the per-cluster
item cap for `_spawn_ambient_trees` and `_spawn_ambient_ores`, so the
prop total scales as `density^2`. 0.5 yields ~25% of the original
prop count (half the clusters, half the per-cluster ceiling).
`lake_crossing.json` ships at 0.5 to cut the 23 s scatter cost on a
populated map; the scattered-trees reads as "lightly wooded" rather
than "dense forest", which matches the Verdant Estuary description
better than the previous blanket coverage.

The field is clamped to `[0.1, 2.0]`. Under 0.3 the result reads as
"the forest died"; use `disable_ambient_scatter: true` for
"off entirely".

## 12.4 What the four fixes do not answer

Three things, in order of importance:

1. **Whether the renderer's 266 ms cost is a real GPU cost or a
   Godot-side bookkeeping cost.** Track E sweeps (msaa 2x → off,
   vsync on → off, scaling 1.0 → 0.75) are the only direct probe.
   The user can run them today; the probe at `tools/probe_track_e.gd`
   reports the current settings and the per-knob recommendations. If
   rendering is genuinely 250 ms per frame at 39 units, no amount of
   culling will get the user to 30 fps; the structural unit cap from
   the previous response is then the right call. If the renderer
   recovers to 100 ms with msaa off or scaling 0.75, this is a
   settings problem and the cull + cap combo is enough.

2. **Whether the §11.5 heightmap hypothesis is real.** Fix D above
   provides the test; we just need one run on `test_range` with the
   flag on, one without, and a comparison of the `units` section.
   This should take 5 minutes.

3. **Whether the per-unit collision cost is fundamentally convex-hull
   × heightmap, or whether there is a sub-linear path
   (heightmap-cube broadphase) that would scale better.** The current
   0.77 ms/unit/frame number is empirical. If the heightmap test in
   (2) shows heightmap is the cost, the next experiment is to swap
   from `HeightMapShape3D` to a tile-based grid of `BoxShape3D`
   shapes that the unit's broadphase query touches O(area-under-body)
   cells rather than O(heightmap) cells. That is a real engineering
   change (2-3 days), and is the only way to reduce the per-unit
   coefficient, which is the only way to keep scaling up to the
   30+ unit army the user is now running.

## 12.5 Verification plan

1. Play one match on lake_crossing with the four fixes live. Check
   `perf_sample` events around `units_alive` = 15-25: render_fps
   should rise from 3.75 toward 15-20.
2. Run the Track E sweeps (msaa off, vsync off, scaling 0.75)
   individually with one playtest each. Re-run the probe and read
   the `units` section.
3. Play one Test Range session (a single unit), flip
   `flat_ground_collider` on `test_range.json`, play one more. Diff
   the `unit.move_and_slide` section. The expected reading: 0.4 ms
   with the flag (flat plane), 0.7 ms without (heightmap) at
   1 unit.
4. If the renderer is still the bottleneck after (1)+(2), commit to
   the structural unit cap from the previous response — there is no
   remaining low-cost fix.

## 12.6 Updated priority order

1. Run (1), (2), (3) from §12.5. One afternoon. Confirms or kills
   each of the three open questions.
2. If (3) shows heightmap is the cost: implement the per-tile
   heightmap-cell broadphase. Two days of work, removes the per-unit
   coefficient from the dominant cost.
3. If (1)+(2) show render is the dominant cost: implement the
   structural unit cap (12-16 units per side). One day of work, the
   game becomes more readable as a side effect.
4. If both: do (2) first, then (3) — the physics cull already
   halves the per-frame physics cost, so the cap is the cleanest
   way to address the rest.
5. The §11.5 reading is wrong (the ground is already a
   `HeightMapShape3D`, not a trimesh); the new reading is the
   per-unit cost of a convex-hull × heightmap query. The fix shape
   is the same — a per-tile broadphase — so the work that would
   have addressed the §11.5 reading is the right work to do anyway.

---

# 13. Results — 2026-08-20T17-16-25 playtest + vision fixes + A/B probe

## 13.1 The four-fix bundle held up under combat

The 17-16-25 playtest was the first capture with all of §12.3's four
fixes live, run end-to-end against the AI for 6.8 minutes. Headlines:

- `units` total 52,392 ms (was 441,662 in the 15-38-42 capture pre-fix);
  -88%. `unit.move_and_slide` mean 3.05 ms/frame (was 17.0); -82%.
- `vision` is now the dominant cost: 56.1 ms / call mean, 191.3 ms worst.
  1,168 calls over 410 s, 16 % of wall clock.
- render_fps at 35-39 units alive: 13.45 mean (was 4.30). The 3.75 fps
  floor is gone.
- Hitches over 100 ms: 469 (was 895); -48 %.

The user's playtest read: "Nothing EGREGIOUS as far as UX. It did get
pretty choppy at the end though." Matches the data: the cull killed
the catastrophic stalls, and the remaining choppiness is the vision
spikes (150-191 ms every 0.3 s) stacked on the 110 ms render frames.

## 13.2 Three vision-service fixes shipped

In `scripts/battle/vision/vision_service.gd`:

### Fix V1 — `TICK_INTERVAL` 0.3 s → 0.6 s

`vision_service.gd:42`. Halves the per-second cost of the vision tick
directly. The LOS cache TTL (`_LOS_CACHE_TTL_MS` = 750 ms) was sized
2.5x against the old 0.3 s TICK_INTERVAL; against the new 0.6 s it is
1.25x, which is still warm across one tick and the cache hit rate
improves rather than degrades.

### Fix V2 — `GRID_CELL` 4.0 m → 6.0 m

`vision_service.gd:124`. The 4 m resolution was a screen-space-fog
convention from the era when the shroud was a flat plane; the §11
shroud rewrite made it a fullscreen depth-buffer pass, so the per-cell
resolution no longer drives edge appearance. Coarsening drops per-viewer
cell count from 729 to 441 (50 m vision), saving ~40 % of the
`_update_shroud` scan. Shroud image on lake_crossing goes 120x120 to
80x80; the minimap re-samples it (its own texture) so the player does
not see the change.

### Fix V3 — `_update_shroud` fast path

`vision_service.gd:540-560` (early-exit at top of the function),
`vision_service.gd:613-618` (fingerprint save at the bottom),
`vision_service.gd:640-662` (`_inputs_unchanged` helper).

The existing `changed` flag only guarded the `set_pixel` writes AFTER
the cell-visiting scan; the scan itself was still running on every tick.
The new path fingerprints the input (per-viewer position quantised to
0.5 m, beacon count) and bails before the scan starts if the input
matches last tick. Position quantisation is well under the new
`GRID_CELL` (0.5 vs 6.0), so a viewer that moved inside its own cell
still passes; a viewer that crossed a cell boundary fails, which is
the right answer because the cell set WILL differ.

The cache invalidates in `invalidate_los_cache` parallel to the LOS
cache (a new structure can change which cells are visible even with no
viewer moving). A round-trip check in the flat-collider probe
(pass A → pass B → pass C, restoring the heightmap) confirms the swap
is clean — the diff between A and C is 0.001 ms/frame on a 16.66
ms/frame wall, well inside noise.

## 13.3 The flat_ground_collider A/B probe REJECTS the §11.5 hypothesis

`tools/probe_flat_collider.gd` (new) — boots the Battle scene, waits
for `world_is_ready`, spawns 16 units of a real roster design, then
runs three passes of 600 physics frames each:

- **A**: heightmap collider (the shipped default)
- **B**: same scene, but the ground `CollisionShape3D.shape` swapped
  for a `BoxShape3D(2*half x 1 x 2*half)` — the same swap
  `match_director.gd`'s `flat_ground_collider` flag performs.
- **C**: heightmap restored (round-trip sanity check).

It reads the `unit.move_and_slide` section out of `BattleProfiler.sections()`
each pass and reports the per-frame mean, the per-unit mean, and the
diffs.

### Result (run on 2026-08-20T17-50-44)

```
=== FLAT GROUND COLLIDER A/B ===
  units = 16   settle = 120   measure = 600 frames
  ground original shape = HeightMapShape3D

  A) heightmap collider
     wall      = 16.68 ms/step
     unit.move_and_slide = 0.03 ms/frame (30.4 us/frame)
     per unit  = 0.002 ms/unit/frame
  B) flat box collider
     wall      = 16.66 ms/step
     unit.move_and_slide = 0.03 ms/frame (29.1 us/frame)
     per unit  = 0.002 ms/unit/frame
  C) heightmap restored (round-trip check)
     wall      = 16.66 ms/step
     unit.move_and_slide = 0.03 ms/frame

  A - B (heightmap - flat) = 0.001 ms/frame (+4.4% of A)
  A - C (round-trip)       = 0.001 ms/frame

  VERDICT: heightmap is NOT the cost. The §11.5 hypothesis is wrong;
           the per-unit collision cost is body-vs-body or body-vs-structure.
```

### What this means

The §11.5 reading was "16 ms/frame for 21 single-shape bodies points
at the ground trimesh." That was a guess. The §12.6 reading
acknowledged the ground is a `HeightMapShape3D`, not a trimesh, and
the fix shape was "per-tile heightmap broadphase — replaces the
heightmap collider with a heightmap collider". The A/B probe shows
the heightmap is not the cost: the diff between heightmap and flat
box is 0.001 ms/frame, which is the same as the round-trip noise
(0.001 ms/frame A-vs-C). The heightmap is *not* contributing to
`unit.move_and_slide`.

**The cost of `unit.move_and_slide` is body-vs-body and body-vs-structure,
not body-vs-ground.** Two implications:

1. The per-tile broadphase idea is still right, but not for the
   heightmap — for the *body-vs-body* sweep. A unit's broadphase
   queries the other units' convex hulls and the many structure
   colliders, and that scales superlinearly with active units in
   a region. A spatial hash keyed on the units' positions would
   reduce that to O(N * k) where k is the average neighbourhood
   count.
2. The previous fix at §11.5 (single convex hull per unit instead
   of a convex decomposition) was already shipping; that took the
   per-unit move_and_slide from 4.08 ms to 0.77 ms. The remaining
   0.77 ms is the body-vs-body + body-vs-structure sweep, not the
   body-vs-ground.

### Caveats

The headless probe measures stationary units (no orders, no velocity).
The 17 ms/frame cost in the real match is on MOVING units, where the
kinematic sweep is the expensive part. The A-B-C test compares three
states under the same motion profile, so the relative cost is the
right answer; the absolute cost of 0.03 ms/frame is a lower bound
that the real match exceeds by ~500x because the real match has
moving units.

A second probe with MOVE orders on the units (e.g. `unit.current_order =
Order.new(...)` and `unit.set_internal_destination(...)`) would measure
the moving-sweep cost directly. That is a one-day patch to
`tools/probe_flat_collider.gd` and would let the same A/B question
be re-asked with the units in motion. If the moving-sweep probe also
finds A == B, the heightmap is conclusively exonerated and the
investigation moves to body-vs-body and body-vs-structure broadphase
work.

## 13.4 Track E playtest order

The §5 Track E render sweeps are the next user-driven probe. The
mechanical recipe, in priority order, with one playtest each:

1. **msaa 3d 2x → off** (`project.godot` `[rendering] anti_aliasing/quality/msaa_3d=0`).
   Already shipped the 4x → 2x half. The 2x → off step is the next
   expected large win. If render_fps at 35 units recovers from 13 to
   18+, this is the dominant cost.
2. **vsync on → off** (`project.godot` `[display] window/vsync/vsync_mode=0`).
   The 13 fps reading is the *engine-reported* rate, which vsync caps
   at the divisor of the monitor's refresh. With vsync off the
   "true" rate shows; if it is 30+ the cost is below the 30 Hz physics
   rate and the choppiness is purely visual. If it stays at 13, the
   GPU is genuinely 75 ms/frame and we have a real budget problem.
3. **scaling 3d 1.0 → 0.75** (`project.godot` `[rendering] rendering/scaling_3d/scale=0.75`).
   Separates fillrate from geometry. If 0.75 doubles render_fps, the
   cost is fragment-shading-bound (terrain at 1080p with msaa is the
   most likely candidate).
4. **vision 1.67 Hz → 0.83 Hz** (TICK_INTERVAL 0.6 → 1.2). If the
   three vision fixes already shipped cut the cost, this is the
   next 50% reduction. Apply by editing `vision_service.gd:42`
   directly; no project.godot toggle.
5. **Combined** (1)+(2)+(3) at once. If this is a settings problem,
   one playtest confirms it; if it isn't, the cost is in the Forward+
   cluster (per-light, per-cluster) and a different probe is needed
   (most likely the renderer in the Godot profiler at F8 in-match,
   or `tools/probe_unit_render_cost.gd` extended to test the cap).

A real playtest with all three flips and a real Skirmish is the
single next experiment the user can run to clear most of the
remaining questions in one capture.

## 13.5 Where the perf plan stands as of 2026-08-20

- [x] **Day 1-3** defects + instrumentation (§4 + §6).
- [x] **§12.3 four-fix bundle** (distant physics cull, dynamic
  light cap, Track E probe, per-map density multiplier, flat
  ground collider flag).
- [x] **§13.2 three vision fixes** (TICK_INTERVAL, GRID_CELL, fast
  path).
- [x] **§13.3 flat-ground A/B probe** — §11.5 hypothesis REJECTED;
  the cost is body-vs-body, not body-vs-ground.
- [ ] **Track E sweeps** (mechanical, user-driven, one playtest
  each).
- [ ] **Body-vs-body / body-vs-structure broadphase** (the
  investigation the §11.5 work was supposed to be). This is the
  real next engineering change, ~3 days of work.
- [ ] **§11.7's `place.displace_props`** (already low at 8.9 ms
  total, no longer a priority).
- [ ] **§11.7's `vision` 56 ms mean** — partly addressed by the
  three vision fixes; Track E item 4 is the next 50 % reduction.
- [ ] **Update §10.5 / §11.5** to reflect the rejection of the
  heightmap hypothesis. The mechanical work is to edit those
  sections; it is a doc patch, not a code patch.

The three remaining open questions, all addressable by one playtest
each, are: is the renderer's 110 ms/frame a real GPU cost, a
forward+ lighting cost, or a fillrate cost? The Track E order above
is ordered to answer them cheapest first.

## 14. RESOLVED (2026-09-01): terrain textures were importing uncompressed and unmipmapped

§13.5 left three open questions, all variants of "is the renderer's 110 ms/frame
a real GPU cost, a Forward+ lighting cost, or a fillrate cost?" It was a
fillrate cost, and the cause was not in any shader or scene - it was in the
texture import settings.

### The measurement

`tools/probe_terrain_fillrate.gd` (new) builds the ground mesh, its material and
the grass carpet under a Battle-like environment, parks a camera at
`RTSCamera.height`'s real 26 m default, and times four configurations. It reports
viewport GPU time, not wall-clock - see "the two false trails" below for why that
matters. delta_blues, 1080p:

```
  phase          BEFORE                      AFTER
  control          2.98 ms  (sky only)        2.71 ms
  plain            8.81 ms  (+ ground mesh)  10.08 ms
  shaded         259.02 ms  (+ real mat)     16.45 ms
  full           259.19 ms  (+ grass)        19.88 ms

  ground mesh    :   +5.83 ms  ->   +7.37 ms
  terrain shader : +250.21 ms  ->   +6.36 ms      39x
  grass carpet   :   +0.17 ms  ->   +3.44 ms
```

Confirmed on the_great_valley (33.79 ms full), sentinel_divide (30.20 ms) and
the_reef (27.80 ms).

### The cause

All 220 PNGs under `assets/textures/terrain/` imported with `compress/mode=0`
(Lossless) and `mipmaps/generate=false`. That puts 2048x2048 RGBA8 plates in
VRAM with no mip chain. `terrain_ground_v2.gdshader` takes ~30 taps per fragment
across four of those layers, so every pixel of ground at a grazing angle was
sampling full-resolution 2K textures with no mip selection - the textbook worst
case for texture cache, on an integrated GPU sharing system memory.

`assets/textures/factions` (30 files, 120 MB of uncompressed VRAM, on the hulls
themselves) and `assets/textures/hull` (3 files) had the same settings and were
fixed in the same pass. `assets/textures/ui`, `assets/textures/ui/props` and
`assets/cursors` are 2D and correctly stay uncompressed.

**Why it happened, which is the part worth remembering.** These `.import` files
all carry `detect_3d/compress_to=1` - Godot's mechanism for re-importing a
texture as VRAM compressed the first time it sees it used on 3D geometry. That
detection runs in the *editor*, over materials it can find in a *scene*. None of
these textures is ever in a scene: `terrain_builder.gd` and
`hull_material_builder.gd` `load()` them and push them into `ShaderMaterial`
parameters at runtime. The editor never witnessed the 3D use, so the safety net
never fired. **Any texture assigned to a shader parameter from code needs its
import settings set by hand.**

### The two false trails, both worth knowing about

1. **`7.5 fps` in a `_match.log` is probably not your game.** Every log with
   `"via":"env"` in `MATCH_BEGIN` is an automated run whose window sits in the
   background, and Windows throttles an unfocused window's swapchain present.
   The result is a dead-flat 133.33 ms/frame - exactly 60/8 - that does not
   move when draw calls change by 11x. Real playtests are `"via":"rule_set"`.
   The first version of the probe above measured wall-clock time and reported
   133.34 ms for *every* configuration it was given, including an empty scene.
   This is why the probe now measures viewport GPU time and why it has a
   `control` phase: if the empty scene is not near zero, the instrument is
   measuring the throttle and every other row is noise.

2. **The grass carpet is not the cost, and looks like it is.** It is chunked,
   range-culled, 8 shells deep with `cull_disabled` and per-fragment `discard`,
   and `terrain_grass_shells.gdshader`'s header claims it costs nothing at
   battle altitude because "the camera is ~150 m up". That claim is false -
   `RTSCamera.height` defaults to 26 m, so the carpet does draw at the default
   zoom. It is simply cheap when it does: 0.17 ms. Tuning it down was tried and
   reverted; it bought a few milliseconds and visibly shortened the grass.

### What is still open

The terrain is now 20-34 ms of GPU per frame depending on map, which is a
different order of problem but not yet a solved one - units, structures, effects
and the HUD all go on top of it. `the_great_valley` is the heaviest measured.
The `+7-9 ms` for the bare ground mesh with a flat material is also worth a look;
that is geometry and overdraw, not shading.

Track E items 1-3 (§13.4) are now moot - the question they were ordered to answer
has been answered. Item 4 (vision tick rate) and the body-vs-body broadphase work
from §13.3 are unaffected and still stand.

Note for anyone re-running the vsync experiment: `project.godot` has
`window/vsync/vsync_mode=0`, but `scripts/core/settings_service.gd` defaults
`vsync` to `true` and re-applies `VSYNC_ENABLED` at boot. Every log ever captured
reports `"vsync":true`. Flipping the project setting does nothing; it has to come
out of the settings service.
