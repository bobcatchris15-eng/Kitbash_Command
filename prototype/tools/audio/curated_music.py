"""The shipped soundtrack: externally-generated tracks, not the procedural one.

WHY THIS MODULE EXISTS. `tools/audio/tracks/` is a from-scratch synthesis
engine (oscillators, a tracker sequencer, mastering chain) and it still renders
a complete, playable 6-state soundtrack - see `tracks/__init__.py`. But Chris
separately generated a set of finished tracks with an external AI music tool
and asked for those to ship instead. This module is the seam between the two:
it copies the chosen files into `assets/audio/music/` and produces the manifest
shape `audio_manager.gd` expects, so the manager does not need to know or care
which source produced the music. `generate_audio.py --procedural-music` still
renders the from-scratch version if that is ever wanted again; nothing about
it was deleted.

PROVENANCE IS UNCONFIRMED. These are AI-generated-style tracks (Suno/Udio-ish
titles, 192 kbps MP3 masters, no stems) dropped into `Tracks/` at the repo
root. Which tool produced them and what its commercial-use/redistribution
terms are has not been verified here - see the note this module writes into
CREDITS.md's placeholder. Do not treat these as cleared for release until that
is confirmed.

SKIRMISH IS A ROTATION, NOT ONE TRACK. Chris asked for the combat pool to be
"shuffled" rather than assigning a single skirmish track - correctly, since a
skirmish can run 40 minutes and a 2:30 loop repeating that long is exactly the
"one track cannot carry a whole game" problem UX_REDESIGN_PLAN.md already
flags. `manifest()["skirmish"]["stems"]["bed"]` is therefore a LIST of files
rather than a single path, and `audio_manager.gd` auto-advances to a new one
(never repeating consecutively) each time the current one finishes.

THE DESIGN LAB IS A ROTATION TOO (2026-08-30). It started as Chris's single
"concrete_swamp_logic" pick (2026-08-09), but a sustained authoring session
sits on one concentrated task for the same 40-minute horizon skirmish does, so
Chris added "steel_mandate" and "parallel_assembly" to the pool - see
LAB_ROTATION. Everything else (menu/operations/victory/defeat) still gets
exactly one file.
"""

from __future__ import annotations

from pathlib import Path

from . import render as R

TRACKS_DIR = Path(__file__).resolve().parents[3] / "Tracks"

# Single-file states. Matched from the track titles, which carry their intended
# destination directly for four of these ("main_menu", "victory", "defeat",
# "brief" -> operations briefing, confirmed by Chris 2026-08-09). "lab" is
# Chris's explicit correction (2026-08-09) - "logic" fits the
# workshop/parametric-studio register.
STATE_SOURCES = {
    "menu": "saturday_s_prototype_main_menu.mp3",
    "operations": "the_midnight_brief.mp3",
    "victory": "iron_fanfare_victory.mp3",
    "defeat": "concrete_gravity_defeat.mp3",
}

# Skirmish rotation pool, per Chris's explicit list (2026-08-09): the anchor
# track plus the 7 that were sitting unused (the_midnight_brief went to
# operations instead, confirmed separately). Order is the load order, not a
# play order - _load_manifest builds an AudioStream array and audio_manager.gd
# picks from it with no-immediate-repeat, same mechanism as the SFX variant
# banks.
SKIRMISH_ROTATION = [
    "hostile_perimeter_breach.mp3",
    "grinding_steel_mandate.mp3",
    "iron_under_noon.mp3",
    "iron_undergrowth.mp3",
    "midnight_treads.mp3",
    "panic_at_the_perimeter.mp3",
    "silo_protocol.mp3",
    "winter_in_the_bunker.mp3",
]

# Design Lab rotation pool, per Chris's picks (2026-08-30): the original
# concrete_swamp_logic "lab" track (which ships under the name
# music_lab_bed.mp3) plus the two new external tracks. Entries are
# (source, shipped-dest-name); the dest name is explicit because the original
# lab track predates the rotation and is NOT named after its source like the
# skirmish pool is - keeping its shipped name means the .import sidecar and
# manifest entry stay valid across the promotion.
LAB_ROTATION = [
    ("concrete_swamp_logic.mp3", "music_lab_bed.mp3"),
    ("steel_mandate.mp3", "music_lab_steel_mandate.mp3"),
    ("parallel_assembly.mp3", "music_lab_parallel_assembly.mp3"),
]

LOOPING_STATES = {"menu", "operations"}   # single-track states that loop
# Skirmish AND lab are not in LOOPING_STATES: looping is handled by ROTATION
# (advancing to a new track), not by the AudioStream looping itself. See the
# module docstring and audio_manager.gd's _on_music_stem_finished.


def _rel(path: Path) -> str:
    return "res://" + str(path.relative_to(R.AUDIO_DIR.parents[1])).replace("\\", "/")


def build(only=None) -> dict:
    if not TRACKS_DIR.exists():
        raise FileNotFoundError(
            f"curated_music: {TRACKS_DIR} does not exist - the source MP3s are "
            "expected at the repo root's Tracks/ folder, one level above prototype/")

    manifest: dict = {}

    for state, filename in STATE_SOURCES.items():
        if only and state not in only:
            continue
        src = TRACKS_DIR / filename
        if not src.exists():
            raise FileNotFoundError(f"curated_music: missing source file {src}")
        dest = R.copy_file(src, R.MUSIC_DIR / f"music_{state}_bed.mp3")
        manifest[state] = {"loop": state in LOOPING_STATES,
                           "stems": {"bed": _rel(dest)}}
        print(f"  music {state:<11} <- Tracks/{filename}")

    if not only or "skirmish" in only:
        paths = []
        for filename in SKIRMISH_ROTATION:
            src = TRACKS_DIR / filename
            if not src.exists():
                raise FileNotFoundError(f"curated_music: missing source file {src}")
            stem_name = Path(filename).stem
            dest = R.copy_file(src, R.MUSIC_DIR / f"music_skirmish_{stem_name}.mp3")
            paths.append(_rel(dest))
            print(f"  music skirmish    <- Tracks/{filename}  (rotation)")
        manifest["skirmish"] = {"loop": False, "stems": {"bed": paths}}

    if not only or "lab" in only:
        paths = []
        for filename, dest_name in LAB_ROTATION:
            src = TRACKS_DIR / filename
            if not src.exists():
                raise FileNotFoundError(f"curated_music: missing source file {src}")
            dest = R.copy_file(src, R.MUSIC_DIR / dest_name)
            paths.append(_rel(dest))
            print(f"  music lab         <- Tracks/{filename}  (rotation)")
        manifest["lab"] = {"loop": False, "stems": {"bed": paths}}

    return manifest
