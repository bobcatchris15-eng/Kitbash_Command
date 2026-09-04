# Task 7 checkpoint — 2026-09-04

Committed at the user's request to begin blocker fixes. This is **not** a fully
passing responsive/rendered acceptance checkpoint. Base: `b2406507`; reviewed
Task 2 `99d09a91`, Task 3 `2327cfe5`, Task 4 `236555e0`, Task 5 `b2406507`,
Task 6 `f94ff44e`, the approved spec, plan and UI_STYLE_GUIDE.

## Changes

Shared readable type (18/16/14/12 px operational scale), sans headings/name
fields, numeric mono readouts, restrained 1.015 hover / 0.97 press, and a real
450 ms total stagger cap. Generated theme rebuilt from its builder.

Menu, Lab and squadron inspection lighting now share warm key/cool fill and
AgX intent. Lab bloom is disabled and the shadowed side gets a fill light.
Battle/VFX are untouched. Match Setup gains vertically scrolling stage content,
narrow roster reflow, sized stage chips, wrapped readiness, directional stage
entrances, initial focus, and a disabled/guarded Deploy when no designs exist.

## Reproduce

From the worktree root:

```powershell
./prototype/tools/run_ui_polish_matrix.ps1
& C:/Misc/Kitbash_Command/Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --editor --quit
& C:/Misc/Kitbash_Command/Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/build_ui_theme.gd --quit-after 2
```

The runner accepts `-Godot`, `-OutputDirectory`, `-TimeoutSeconds`, and optional
`-Capture` for a future renderer-capable session. Each screen runs separately;
capture failures never prevent headless fallback. Reports are written before
each capture attempt. Task 7 used **headless only**, without `-Capture`.
Artifacts/logs: ignored `playtest/task7/`; red baseline: `playtest/task7-baseline/`.

## Executed validation

| Check | Result |
|---|---|
| Theme builder | exit 0; resource saved |
| Headless editor/import | exit 0; no parse/import errors |
| `tests/test_ui_shell_contract.gd` | 86 checks, 0 failures, exit 0 |
| `tests/test_industrial_asset_kit.gd` | 52 checks, 0 failures, exit 0 |
| `tests/test_menu_lab_slice.gd` | 46 checks, 0 failures, exit 0 |
| `tests/test_match_setup_slice.gd` | 10 checks, 0 failures, exit 0 |
| New matrix: Menu | 19 checks, 0 failures, 7 rows, exit 0 |
| New matrix: Lab | 27 checks, 0 failures, 6 rows, exit 0 |
| New matrix: Match Setup | 59 checks, **1 failure**, 13 rows, exit 1 |

Total existing probes: **194/194 pass**. New matrix: **104/105 pass**, 26 rows;
runner exits **1**, deliberately preserving the blocker as a failing check.
`git diff --check` passed (Git reports existing LF/CRLF conversion notices).

The red baseline found display fonts in operational headings, small heading
size, mono name fields, stagger overrun, two setup vertical overflows, narrow
Theatre width overflow, and enabled blocked-launch action. Those checks now
pass. The initial Armor Station assertion called the panel's model-only entry
directly; the harness was corrected to invoke the toolbar's actual workspace
swap, then reverse it. It makes no design saves or Battle launches.

## Matrix coverage

| Surface | States |
|---|---|
| Menu | Default at 1920×1080; 1280×800 and 960×720; actual input hover/pressed, keyboard focus, disabled |
| Lab | Default and all four document pages' bounds at all three sizes; rejected placement; Armor Station at 1280×800 and 960×720, return to assembly |
| Match Setup | Theatre, empty roster, Launch at all three sizes; populated roster, invalid unit-to-defence drop, populated launch, blocked launch and restored readiness |

Every row includes UIAudit offscreen/overflow diagnostics. All rows reported
zero wholly offscreen controls. Overflow diagnostics identify existing scroll
contents (menu destinations, map list, Lab toolbar) and the new stage scrolling;
they are not all layout failures. The bounds assertions are separate gates.

## Remaining blockers and limitations

1. **960×720 Launch width:** rect `(24,138; 961×482)` ends at x=985, **25 px past
   the viewport**, and 49 px past the intended 912 px stage width. Investigate
   combined minimum widths of rules/manifest and squadron header. This matrix
   assertion remains failing for the next blocker-fix task.
2. Prior rendered capture crashed with `-1073740791 / 0xC0000409`. Not retried per
   user instruction. All screenshot rows honestly say `unavailable-headless`.
   No rendered visual/lighting/contrast/performance acceptance is claimed.
3. Invalid roster drop coverage checks the actual acceptance predicate and roster
   preservation; it does not validate a dragged preview/no-drop cursor visually.
   Armor Station uses the real swap but does not test the camera-pan animation.
   Headless Main Menu intentionally omits its 3D showcase construction.
4. The blocked-library branch uses a test-only empty library object; no user files
   are removed. Empty roster and populated examples otherwise use available
   blueprints (including bundled defaults), not a hermetic filesystem fixture.
5. **Pre-existing diagnostics remain:** dummy renderer `Parameter "material" is
   null` at `material_get_instance_shader_parameters`; the menu/Lab regression
   and matrix menu shutdown report 3 ObjectDB instances / 1 resource in use.
   These were already recorded in Task 4. They are not parse failures and were
   not repaired by this scoped presentation pass.
6. This runs the four currently present focused probes, not the historic deleted
   full suite or the expensive full-tree cache-ignoring compilation probe.
   Independent rendered review / Task 8 remains outstanding.

## Exact committed files

- `playtest/.gitignore`
- `prototype/docs/UI_STYLE_GUIDE.md`
- `prototype/docs/RENDER_SETTINGS.md`
- `prototype/docs/TASK7_UI_POLISH_REPORT.md`
- `prototype/resources/bomber_theme.tres`
- `prototype/scenes/MainLab.tscn`
- `prototype/scripts/main_menu.gd`
- `prototype/scripts/match_setup.gd`
- `prototype/scripts/roster_picker.gd`
- `prototype/scripts/ui_anim.gd`
- `prototype/scripts/ui_theme.gd`
- `prototype/scripts/ui_tokens.gd`
- `prototype/tools/build_ui_theme.gd`
- `prototype/tools/run_ui_polish_matrix.ps1`
- `prototype/tests/test_ui_polish_matrix.gd`
- `prototype/tests/test_ui_polish_matrix.gd.uid`

Pre-existing root `.gitignore`, Task 4 playtest artifacts, unrelated SVG imports
and prior test UID files are excluded. No guided-missile VFX file was modified.
