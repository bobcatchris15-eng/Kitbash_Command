# Industrial UI asset kit

This is the authored mark set for the industrial design simulator UI. The marks use a shared 64-unit drafting grid, open technical contours, and semantic accent colors only where a state needs to be communicated.

- `vectors/` contains crisp, monochrome-ready SVG marks for navigation, module slots, state, drag/drop, map, and blueprint surfaces.
- `manifest.json` is the stable handoff contract for UI/theme integration tasks.
- Raster plates and fields intentionally reuse the existing approved material library under `res://assets/textures/ui/`; the manifest records those paths so consumers do not duplicate textures.

SVG fills and strokes are explicit for predictable import, but callers may still tint monochrome marks with `modulate` when a screen needs semantic state color.
