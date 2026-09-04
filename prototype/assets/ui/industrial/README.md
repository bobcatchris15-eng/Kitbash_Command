# Industrial UI asset kit

This is the production asset contract for the industrial design simulator UI. The vectors use a shared 64-unit drafting grid, open technical contours, and semantic accent colors only where state must be communicated.

- `vectors/` contains the authored navigation, module-slot, state, drag/drop, map, and blueprint marks. Each manifest entry declares its path, dimensions, and `viewBox`.
- `manifest.json` owns the semantic vector keys, material roles, tileable 512×512 workbench/material fields, four-state 128×128 plates, 28 px 9-slice frame, 16 px shadow expansion, and controlled wear parameters.
- Raster sources remain in the approved project material library under `res://assets/textures/ui/`; the manifest is their single production registry rather than a duplicate texture set.
- `scripts/ui_theme.gd` resolves the manifest at runtime. `tools/build_ui_theme.gd` publishes vectors as `IndustrialIcons`, fields as `IndustrialFields`, and every four-state plate as a reusable `IndustrialPlate*` theme type in `bomber_theme.tres`.

The large-surface shader consumes the authored field/detail texture plus bounded wear, grime, scale, vignette, and brightness controls. Separate normal maps are intentionally absent: the current CanvasItem material path has no normal input or matching 2D lighting, so adding unused normals would not affect the rendered interface.

SVG fills and strokes are explicit for predictable import, but callers may still tint monochrome marks with `modulate` when a screen needs semantic state color.
