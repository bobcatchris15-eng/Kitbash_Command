"""Every non-music sound, and the manifest the engine loads them by.

THE SINCERE/ABSURD SPLIT IS ENFORCED BY FILE LAYOUT, not by convention.
CORE_DESIGN_LANGUAGE.md 6.2 draws the line between ordnance (vocalised, absurd)
and everything else (real, sincere), and it is easy to let that drift one asset
at a time. So:

    the ordnance banks come from voice.ORDNANCE and nothing else
    every sound authored IN THIS FILE is on the sincere side, without exception

If a sound in this module ever wants to be funny, it is in the wrong module.
That includes the interface: UX_REDESIGN_PLAN.md is explicit - "interface audio
is on the sincere side. No comedy on a button."

VARIANT BANKS. Every key renders 3-8 numbered files (`sfx_cannon_01.wav` ...)
rather than one, because audio_manager.gd now picks round-robin with no
immediate repeat. UI_STYLE_GUIDE.md:359 already required this of pitch
("never let a UI click repeat identically") and pitch variation alone stops
working once you have heard a sound a few hundred times, which for a click is
the first ten minutes.
"""

from __future__ import annotations

import numpy as np

from . import dsp as d
from . import voice as V


# --- Helpers -----------------------------------------------------------------

def _modal(freqs, decays, dur, seed, amps=None, strike=0.35, strike_hz=3000.0,
           detune=0.012, spread=0.0):
    """A struck object: inharmonic partials, each with its own decay rate.

    Every mechanical UI sound here is one of these. A switch, a latch, a dial
    detent and a relay differ in exactly the three things this takes - which
    frequencies ring, how fast each dies, and how hard the contact is.

    `spread` is the whole-bank variety control and matters as much as any of
    those: the first pass detuned each partial by only +/-1.2%, and measured
    pairwise spectral distance inside a bank was ~0.001 - the "variants"
    round-robin picks between were clones, which is exactly the repetition the
    variant banks exist to prevent. A real latch struck twice does not ring at
    the same pitch; `spread` scales the WHOLE partial set once per call
    (plus the per-partial `detune` on top), which keeps the mechanism's
    identity while making successive plays audibly different events.

    Callers author spreads in the 0.05-0.10 range, which measured as still
    too tight for short decays (the ear tracks a struck partial's PITCH, and
    sub-3% moves on a 60 ms ping are marginal). The authored value is
    therefore a floor-scaled request: it is widened here once, centrally,
    rather than hand-retuned at every call site.
    """
    g = d.rng(seed)
    out = d.silence(dur)
    amps = amps or [1.0 / (1.0 + i) for i in range(len(freqs))]
    spread = min(spread * 1.5, 0.14)
    scale = 1.0 + g.uniform(-spread, spread) if spread > 0.0 else 1.0
    for f, rate, a in zip(freqs, decays, amps):
        f = f * scale * (1.0 + g.uniform(-detune, detune))
        out += d.sine(f, dur) * d.decay_env(dur, rate * g.uniform(0.9, 1.12),
                                            0.0003) * a
    if strike > 0.0:
        contact = d.filt(g.uniform(-1.0, 1.0, len(out)), "bp", strike_hz, 0.8)
        out += contact * d.decay_env(dur, 900.0, 0.0001) * strike \
            * g.uniform(0.7, 1.3)
    return d.normalize(d.fade(out, 0.0004, min(0.01, dur * 0.2)), 0.85)


def _seamless(x: np.ndarray, fade: float = 0.35) -> np.ndarray:
    """Make a buffer loop without a seam, by crossfading its tail over its head.

    Returns a buffer SHORTER than the input by `fade` seconds. The result's last
    sample runs continuously into its first, which is the only way a sustained
    engine or wind bed can loop without a click or a swell once a second.
    """
    f = d.n_samples(fade)
    if len(x) <= f * 2:
        return x
    length = len(x) - f
    out = np.array(x[:length])
    ramp = np.linspace(0.0, 1.0, f)
    out[:f] = x[:f] * ramp + x[length:length + f] * (1.0 - ramp)
    return out


def _variants(fn, count: int, *args):
    return [fn(i, *args) for i in range(count)]


# --- Interface (14 roles) ----------------------------------------------------
#
# Named for the MECHANISM, not the widget, which is what ui_feedback.gd's role
# table already assumes. Eight of these keys - toggle_on/off, dial, tick,
# drawer, plate, latch, mode - are referenced by ui_feedback.gd:52-68 and did
# not exist in audio_manager.gd's SFX_PATHS, so every control mapped to them
# has been silently playing nothing.

def ui_hover(i):
    """The lightest sound in the game. A readiness cue, never state."""
    return d.match_loudness(
        _modal([2400, 3900], [180, 260], 0.045, f"hover{i}",
               amps=[1.0, 0.35], strike=0.10, strike_hz=5200.0, spread=0.06),
        -27.0)


def ui_click(i):
    """Detent click - an ordinary press."""
    return d.match_loudness(
        _modal([1250, 2600, 4400], [190, 300, 420], 0.065, f"click{i}",
               amps=[1.0, 0.5, 0.22], strike=0.4, strike_hz=3600.0,
               spread=0.09),
        -21.0)


def ui_select(i):
    """Picking from a set. A tick with a small upward inflection."""
    g = d.rng(f"sel{i}")
    base = _modal([900, 1850, 3100], [130, 200, 300], 0.09, f"sel{i}",
                  amps=[1.0, 0.55, 0.25], strike=0.3, spread=0.08)
    lift = d.sine(d.breakpoints(0.09, [(0.0, 1400.0), (1.0, 2100.0)]), 0.09)
    return d.match_loudness(base + lift * d.decay_env(0.09, 45.0, 0.001) * 0.3
                            * g.uniform(0.6, 1.2), -20.0)


def ui_place(i):
    """Seating something into the world or a slot. Has mass and stops dead."""
    g = d.rng(f"place{i}")
    dur = 0.18
    thud = d.sine(d.breakpoints(dur, [(0.0, 150.0), (0.1, 78.0), (1.0, 62.0)]),
                  dur) * d.decay_env(dur, 30.0, 0.0008)
    body = _modal([420, 780, 1360], [50, 80, 140], dur, f"place_m{i}",
                  amps=[1.0, 0.5, 0.25], strike=0.5, strike_hz=2200.0,
                  spread=0.07)
    # Seating contact is a BROAD event - the modal body and a grit transient
    # carry the "something arrived" read; the thud sine is one voice, not the
    # whole bank (the first pass measured 90% of its energy below 120 Hz).
    grit = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 1500.0, 0.8)
    return d.match_loudness(thud * 0.55 + body * 0.85
                            + grit * d.decay_env(dur, 160.0, 0.0004) * 0.65,
                            -18.0)


def ui_error(i):
    """A refused input. Two clipped buzz bursts - the machine saying no, twice.

    The first pass was a single sustained square wall for 160 ms: measured crest
    factor 4 and RMS -7 dB at equal peak normalisation, i.e. by far the loudest
    interface sound in the game AND a featureless drone. Real rejection buzzers
    are gated - two short bursts carry "no-no" without any comedy, and gating
    restores a normal crest.
    """
    dur = 0.34
    g = d.rng(f"err{i}")
    # Per-variant pitch AND a lower second burst: the first rebuild only
    # jittered gate timing by milliseconds, which neither the ear nor any
    # summary statistic could tell apart - the bank measured as one file
    # three times.
    f0 = 136.0 * (1.0 + g.uniform(-0.10, 0.10))
    f2 = f0 * g.uniform(0.74, 0.88)
    buzz = d.saw(f0, dur) * 0.65 + d.square(f0 * 1.5, dur) * 0.35
    low = d.saw(f2, dur) * 0.65 + d.square(f2 * 1.5, dur) * 0.35
    buzz = d.filt(buzz, "lp", 1100.0 * (1.0 + g.uniform(-0.2, 0.2)), 0.9)
    low = d.filt(low, "lp", 1000.0, 0.9)
    # Per-variant gate timing: the two bursts breathe a few ms either side of
    # nominal.
    b1s = g.uniform(0.002, 0.006)
    b2s = g.uniform(0.168, 0.186)
    gate1 = d.breakpoints(dur, [(0.000, 0.0), (b1s, 1.0),
                                (b1s + 0.101, 0.85), (b1s + 0.131, 0.0)])
    gate2 = d.breakpoints(dur, [(b2s - 0.004, 0.0), (b2s, 0.95),
                                (b2s + 0.111, 0.75), (b2s + 0.15, 0.0)])
    grit = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 700.0, 1.2) * 0.12
    out = d.drive(buzz, 1.7) * gate1 + d.drive(low, 1.7) * gate2 \
        + grit * (gate1 + gate2)
    tail = d.filt(d.sine(f2 * 0.82, dur), "lp", 900.0, 0.9)
    return d.match_loudness(out + tail * d.decay_env(
        dur, 9.0, attack=b2s) * 0.25, -16.0)


def ui_toggle_on(i):
    """A switch throwing one way. Harder detent than the return."""
    return d.match_loudness(
        _modal([1600, 3000, 5200], [260, 380, 520], 0.055, f"togon{i}",
               amps=[1.0, 0.55, 0.3], strike=0.65, strike_hz=4200.0,
               spread=0.07),
        -21.0)


def ui_toggle_off(i):
    """The same switch coming back. Lower, softer, unmistakably the other way.

    A real switch does NOT sound the same in both directions, and reversing one
    sample is audibly a reversed sample. Two distinct sounds is the only way the
    player knows which way a toggle went without looking at it.
    """
    return d.match_loudness(
        _modal([1050, 2100, 3600], [300, 420, 600], 0.048, f"togoff{i}",
               amps=[1.0, 0.45, 0.2], strike=0.45, strike_hz=3200.0,
               spread=0.07),
        -22.0)


def ui_dial(i):
    """A rotary selector dropping into its next notch."""
    return d.match_loudness(
        _modal([1900, 3400], [420, 560], 0.038, f"dial{i}",
               amps=[1.0, 0.4], strike=0.7, strike_hz=4800.0, spread=0.08),
        -23.0)


def ui_tick(i):
    """A continuous value passing a step. The quietest sound in the set - it
    fires repeatedly while a slider is dragged."""
    return d.match_loudness(
        _modal([3200], [600], 0.022, f"tick{i}", strike=0.5,
               strike_hz=6000.0, spread=0.05),
        -31.0)


def ui_drawer(i):
    """A dock or toolbox tier sliding open: rail friction, then a soft stop."""
    dur = 0.34
    g = d.rng(f"drawer{i}")
    rail = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 1500.0, 0.5)
    # Friction swells as the drawer accelerates, then stops.
    rail *= d.breakpoints(dur, [(0.0, 0.0), (0.15, 0.9), (0.72, 0.75),
                                (0.85, 0.0), (1.0, 0.0)])
    rail = d.sweep_filter(rail, "bp",
                          d.breakpoints(dur, [(0.0, 900.0), (0.8, 2100.0)]), 0.8)
    stop = _modal([320, 640, 1150], [45, 70, 110], 0.14, f"drawerstop{i}",
                  amps=[1.0, 0.5, 0.25], strike=0.45, strike_hz=2000.0,
                  spread=0.06)
    out = d.silence(dur)
    d.place(out, rail * 0.5, 0.0)
    d.place(out, stop * 0.8, 0.83 * dur)
    return d.match_loudness(out, -20.0)


def ui_plate(i):
    """A panel arriving and seating against its mount. Metal, with mass."""
    return d.match_loudness(
        _modal([260, 520, 980, 1700], [28, 45, 75, 120], 0.42, f"plate{i}",
               amps=[1.0, 0.6, 0.3, 0.15], strike=0.5, strike_hz=2600.0,
               spread=0.07),
        -19.0)


def ui_latch(i):
    """A quarter-turn fastener locking. Two-stage: turn, then seat."""
    dur = 0.22
    turn = _modal([1400, 2500], [340, 460], 0.05, f"latchturn{i}",
                  amps=[1.0, 0.4], strike=0.5, strike_hz=3800.0, spread=0.08)
    seat = _modal([380, 700, 1250], [40, 65, 100], 0.17, f"latchseat{i}",
                  amps=[1.0, 0.55, 0.28], strike=0.75, strike_hz=2400.0,
                  spread=0.05)
    out = d.silence(dur)
    d.place(out, turn * 0.55, 0.0)
    d.place(out, seat * 0.95, 0.048)
    return d.match_loudness(out, -20.0)


def ui_mode(i):
    """A relay throwing. The heaviest non-destructive sound available."""
    dur = 0.30
    coil = d.sine(d.breakpoints(dur, [(0.0, 92.0), (0.25, 74.0), (1.0, 68.0)]),
                  dur) * d.decay_env(dur, 26.0, 0.0009)
    contact = _modal([540, 1020, 1850, 3100], [30, 55, 95, 160], dur,
                     f"mode{i}", amps=[1.0, 0.6, 0.32, 0.15],
                     strike=0.7, strike_hz=2800.0, spread=0.07)
    # The first pass measured 78% of its energy below 120 Hz - the coil sine
    # owned the bank. A relay has a brass bang as well as a coil thump; the
    # thump stays but as one voice among three.
    snap = d.filt(d.rng(f"modesnap{i}").uniform(-1.0, 1.0, d.n_samples(0.03)),
                  "bp", 1900.0, 0.9) * d.decay_env(0.03, 260.0, 0.0002) * 0.5
    out = d.silence(dur)
    d.place(out, snap, 0.0)
    out += d.normalize(coil * 0.45 + contact * 1.0, 1.0)
    return d.match_loudness(out, -19.0)


def ui_menu_open(i):
    """The system/pause menu arriving. A heavy panel sliding in and seating.

    Distinct from `ui_drawer` on purpose: a drawer is a dock tier moving within
    a screen, this is the whole interface being interrupted, so it is lower,
    slower and has more mass behind it.
    """
    dur = 0.42
    g = d.rng(f"menuopen{i}")
    slide = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 700.0, 0.5)
    slide *= d.breakpoints(dur, [(0.0, 0.0), (0.12, 0.85), (0.62, 0.6),
                                 (0.78, 0.0), (1.0, 0.0)])
    seat = _modal([190, 380, 720, 1300], [26, 42, 72, 120], 0.28,
                  f"menuopenseat{i}", amps=[1.0, 0.6, 0.32, 0.16],
                  strike=0.5, strike_hz=2200.0, spread=0.06)
    out = d.silence(dur)
    d.place(out, slide * 0.45, 0.0)
    d.place(out, seat * 0.9, 0.72 * dur)
    return d.match_loudness(out, -19.0)


def ui_menu_close(i):
    """The same panel leaving. Shorter, and it releases rather than seats."""
    dur = 0.30
    g = d.rng(f"menuclose{i}")
    unlatch = _modal([420, 800, 1500], [90, 130, 200], 0.09, f"menuclosel{i}",
                     amps=[1.0, 0.5, 0.25], strike=0.6, strike_hz=3000.0,
                     spread=0.08)
    slide = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 620.0, 0.5)
    slide *= d.breakpoints(dur, [(0.0, 0.0), (0.2, 0.7), (0.85, 0.0), (1.0, 0.0)])
    out = d.silence(dur)
    d.place(out, unlatch * 0.8, 0.0)
    d.place(out, slide * 0.4, 0.06)
    return d.match_loudness(out, -21.0)


def ui_warning(i):
    """Destructive action, and the alert banner. Mechanical, not musical."""
    dur = 0.5
    g = d.rng(f"warn{i}")
    # Two close tones beating against each other - a real warning horn, not a
    # synth interval. A third partial fills the buzzy gap between them so the
    # beat reads on small speakers too. Beat rates are per-variant: the first
    # pass drew its only per-variant randomness from a +/-0.4 dB trim and the
    # three files were bit-level clones.
    f1 = 196.0 * (1.0 + g.uniform(-0.03, 0.03))
    beat = g.uniform(4.0, 12.0)
    horn = d.saw(f1, dur) + d.saw(f1 + beat, dur) * 0.9 \
        + d.saw(2.0 * f1 + beat, dur) * 0.22
    horn = d.filt(horn, "lp", 1900.0, 0.8)
    horn = d.filt(horn, "hp", 150.0, 0.707)
    horn *= d.adsr(dur, 0.012, 0.06, 0.8,
                   0.16 * g.uniform(0.8, 1.25), curve=1.4)
    grit = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 900.0, 1.0) * 0.1
    return d.match_loudness(d.drive(horn * 0.5 + grit, 1.5),
                            -14.0 + g.uniform(-0.4, 0.4))


# --- Mechanical loops (sincere) ----------------------------------------------

def engine_loop(i, kind="diesel"):
    """A running powerplant. Seamless, pitch-shifted at runtime by unit speed.

    Built from a firing-order pulse train rather than a drone: an engine is a
    series of discrete combustion events, and that periodicity is what the ear
    identifies. Filtered noise alone gives a vacuum cleaner.

    REBUILT FOR LEGIBILITY. The first pass pushed the pulse train through ONE
    resonator at the body frequency and low-passed the result, and measurement
    agreed with the complaint: 77% of the diesel's energy sat below 120 Hz, so
    the engine read as an indistinct rumble that vanished off anything without a
    subwoofer. Three things were missing, and all three are physical: a real
    exhaust note is a HARMONIC STACK at multiples of the firing frequency (the
    pipe rings, not one mode), the valve gear contributes bright mechanical
    CLATTER locked to the firing strokes, and the intake/exhaust ROAR is
    broadband mid, amplitude-gated by the same strokes.
    """
    dur = 2.4
    g = d.rng(f"eng{kind}{i}")

    # Slight wander so the loop does not read as a perfect machine.
    drift = d.filt(g.normal(0, 1, d.n_samples(dur)), "lp", 1.5, 0.707) * 0.012

    if kind in ("diesel", "heavy"):
        fire, body, lp_hz = {
            "diesel": (24.0, 225.0, 4600.0),
            "heavy": (14.5, 145.0, 3300.0),
        }[kind]
        # Per-variant tuning: firing rate AND pipe resonance both vary - two
        # units of the same class should not idle in unison. The first pass
        # only jittered fire by +/-3% and the pair measured as near-clones.
        fire *= 1.0 + g.uniform(-0.08, 0.08)
        body *= 1.0 + g.uniform(-0.07, 0.07)
        wander = 1.0 + drift
        pulses = d.pulse(fire * wander, dur, width=0.16)

        # Exhaust note: resonators at the first three firing harmonics. The
        # slightly non-integer ratios (2.01, 3.02) are what real pipes do -
        # exact integers sound like an organ pipe.
        exh = d.sweep_resonator(pulses, body, body * 0.45)
        exh += d.sweep_resonator(pulses, body * 2.01, body * 0.5) * 0.45
        exh += d.sweep_resonator(pulses, body * 3.02, body * 0.55) * 0.22
        exh = d.drive(exh, 1.9)

        # Valve-gear clatter: sparse bright ticks on alternating firing strokes.
        clatter = d.silence(dur)
        t = 1.5 / fire
        while t < dur - 0.03:
            if g.uniform() < 0.7:
                tick = d.filt(g.uniform(-1.0, 1.0, d.n_samples(0.02)),
                              "bp", g.uniform(1100.0, 2700.0), 1.2)
                tick *= d.decay_env(0.02, 380.0, 0.0002)
                d.place(clatter, tick * g.uniform(0.08, 0.18), t)
            t += 2.0 / fire

        # Intake/exhaust roar: broadband mid, gated by the firing strokes.
        gate = d.filt(np.abs(d.pulse(fire * wander, dur, width=0.35)),
                      "lp", 120.0, 0.707)
        roar = d.filt(d.pink(dur, f"engroar{kind}{i}"), "bp", 430.0, 0.55)

        out = exh * 0.8 + clatter + roar * gate * g.uniform(0.28, 0.38)
        # A Klatt resonator has no zeros - it passes the pulse train's whole low
        # end while boosting the harmonic, which is how the first rebuild still
        # measured 77% of its energy under 120 Hz. Trimming below 80 costs
        # nothing audible (no consumer speaker reproduces it there anyway) and
        # hands the low end back to the harmonics that identify the engine.
        out = d.filt(out, "hp", 80.0, 0.707)

    elif kind == "turbine":
        shaft = 84.0 * (1.0 + g.uniform(-0.06, 0.06))
        # Blade whine: two detuned shaft harmonics through one band - a gas
        # turbine's identity is a smooth high whine over an air roar, not
        # combustion pulses.
        whine = d.saw(shaft * 8.0, dur) * 0.5 + d.saw(shaft * 9.5, dur) * 0.35
        whine = d.filt(whine, "bp", 1750.0, 1.1)
        whine *= 1.0 + drift * 2.0
        gust = 0.78 + 0.22 * d.filt(g.normal(0, 1, d.n_samples(dur)),
                                    "lp", 0.6, 0.707)
        core = d.filt(d.pink(dur, f"engcore{i}"), "hp", 700.0, 0.707)
        core = d.filt(core, "lp", 5200.0, 0.707)
        hum = d.sine(shaft, dur) * 0.14
        out = whine * 0.5 + core * gust * 0.34 + hum
        lp_hz = 8000.0

    else:  # electric
        hum_f = 96.0 * (1.0 + g.uniform(-0.04, 0.04))
        hum = d.saw(hum_f, dur) * 0.3 + d.saw(hum_f * 2.0, dur) * 0.16 \
            + d.sine(hum_f * 3.0, dur) * 0.08
        hum = d.filt(hum, "lp", 900.0, 0.707)
        # Inverter whine: high, thin, slowly wandering.
        inv_f = 4700.0 * (1.0 + drift * 3.0)
        inv = d.sine(inv_f, dur) * 0.06
        # Light load throb.
        gate = d.filt(np.abs(d.pulse(15.5, dur, width=0.3)), "lp", 60.0, 0.707)
        throb = d.filt(d.pink(dur, f"engthrob{i}"), "bp", 1300.0, 0.8) * gate
        out = hum * 0.55 + inv + throb * 0.09
        lp_hz = 9000.0

    out = d.filt(out, "lp", lp_hz, 0.707)
    out = d.filt(out, "hp", 46.0, 0.707)
    return d.match_loudness(_seamless(out, 0.4), -16.0)


def tread_loop(i):
    """Track clatter: irregular metallic impacts over a low roll."""
    dur = 2.0
    g = d.rng(f"tread{i}")
    out = d.silence(dur)
    t = 0.0
    while t < dur - 0.12:
        hit = _modal([380, 720, 1400, 2600], [90, 130, 190, 280], 0.09,
                     f"tread{i}:{t:.3f}", amps=[1.0, 0.6, 0.42, 0.26],
                     strike=0.6, strike_hz=3100.0, spread=0.10)
        amp = g.uniform(0.5, 1.0) * 0.5
        d.place(out, hit * amp, t)
        # A pad sometimes slaps twice - shoe then guide horn.
        if g.uniform() < 0.35:
            d.place(out, hit * amp * 0.55, t + 0.028)
        t += g.uniform(0.055, 0.095)
    roll = d.filt(d.brown(dur, f"treadroll{i}"), "lp", 400.0, 0.707) * 0.35
    return d.match_loudness(_seamless(out + roll, 0.35), -16.0)


def wheel_loop(i):
    """Tyre roll. Broadband, smoother than treads, no discrete impacts."""
    dur = 2.0
    g = d.rng(f"wheel{i}")
    base = d.filt(d.pink(dur, f"wheel{i}"), "bp", 560.0, 0.75)
    # Contact-patch tread pattern: irregular amplitude movement is what stops a
    # tyre bed reading as a steady organ note. The hum sines stay quiet - at
    # the old level they owned the bank's energy and the tyre vanished.
    pattern = 0.75 + 0.25 * np.abs(
        d.filt(g.normal(0, 1, d.n_samples(dur)), "lp", 9.0, 0.707))
    hum = d.sine(82.0, dur) * 0.06 + d.sine(123.0, dur) * 0.03
    return d.match_loudness(_seamless(base * 0.85 * pattern + hum, 0.35), -17.0)


def servo_loop(i):
    """Turret/joint servo whine. A pitched electric motor."""
    dur = 1.6
    g = d.rng(f"servo{i}")
    # Motor speed is per-variant: the first pass used fixed partials and the
    # two files measured as clones (cosine distance 0.0000).
    scale = 1.0 + g.uniform(-0.06, 0.06)
    whine = (d.saw(385.0 * scale, dur) * 0.6 + d.saw(592.0 * scale, dur) * 0.35)
    whine = d.filt(whine, "bp", 1150.0, 1.25)
    whine += d.filt(d.saw(770.0 * scale, dur), "bp", 2300.0, 1.4) * 0.18
    whine *= 1.0 + d.filt(g.normal(0, 1, d.n_samples(dur)), "lp", 6.0, 0.707) * 0.06
    brush = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                   "bp", 2600.0 * (2.0 - scale), 0.8) * g.uniform(0.05, 0.09)
    out = d.filt(whine * 0.5 + brush, "lp", 9500.0, 0.707)
    return d.match_loudness(_seamless(out, 0.3), -19.0)


def hydraulic_loop(i):
    """Hydraulic hiss under load."""
    dur = 1.6
    g = d.rng(f"hyd{i}")
    pump_f = 46.0 * (1.0 + g.uniform(-0.08, 0.08))
    hiss = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                  "bp", 2800.0 * (1.0 + g.uniform(-0.15, 0.15)), 0.65)
    hiss *= 0.78 + 0.22 * d.sine(g.uniform(2.4, 3.6), dur)
    # Pump: a soft geared throb rather than a bare sine - odd harmonics only,
    # kept quiet so the bed stays a hiss.
    pump = (d.triangle(pump_f, dur) * 0.10
            + d.triangle(pump_f * 2.0, dur) * 0.05)
    out = d.silence(dur)
    d.place(out, hiss * g.uniform(0.55, 0.68), 0.0)
    d.place(out, pump, 0.0)
    return d.match_loudness(_seamless(out, 0.3), -19.0)


def rotor_loop(i):
    """Rotor wash: blade-passing tone plus downwash."""
    dur = 2.0
    g = d.rng(f"rotor{i}")
    rate = 21.5 * (1.0 + g.uniform(-0.07, 0.07))
    chop = d.pulse(rate, dur, width=0.14)
    blade = d.sweep_resonator(chop, 300.0, 150.0)
    # The mid-band wash chopped BY the blades is the part a player actually
    # hears on ordinary speakers; the first pass put 81% of its energy below
    # 120 Hz and the rotor was effectively silent until it was on top of you.
    # The gate is smoothed and biased above zero - gating mid noise with the
    # raw 14%-duty square leaves it inaudible on average.
    env = d.filt(np.abs(chop), "lp", 90.0, 0.707)
    wash = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                  "bp", 780.0 * (1.0 + g.uniform(-0.12, 0.12)), 0.7)
    wash *= 0.3 + 0.7 * env
    bed = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "lp", 1500.0, 0.707)
    bed *= 0.45 + 0.55 * env
    out = blade * 0.55 + wash * 0.75 + bed * 0.6
    return d.match_loudness(_seamless(d.filt(out, "hp", 95.0, 0.707), 0.35),
                            -14.0)


def screw_loop(i):
    """Screw-drive churn: auger in mud. Wet, low, irregular."""
    dur = 2.2
    g = d.rng(f"screw{i}")
    churn = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                   "lp", 1100.0 * (1.0 + g.uniform(-0.20, 0.20)), 0.707)
    churn *= 0.5 + 0.5 * np.abs(d.sine(8.6, dur))
    grit = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                  "bp", 1450.0 * (1.0 + g.uniform(-0.15, 0.15)), 0.9)
    grit *= 0.3 + 0.7 * np.abs(d.sine(8.6, dur))
    thump = d.sine(64.0, dur) * (0.5 + 0.5 * d.sine(4.4, dur)) * 0.22
    return d.match_loudness(_seamless(d.filt(churn * 0.7 + grit * 0.34 + thump,
                                             "hp", 70.0, 0.707), 0.35), -16.0)


def turret_start(i):
    return d.match_loudness(
        _modal([180, 340, 700], [40, 60, 95], 0.13, f"trvstart{i}",
               amps=[1.0, 0.5, 0.25], strike=0.5, strike_hz=1800.0,
               spread=0.08), -20.0)


def turret_stop(i):
    return d.match_loudness(
        _modal([220, 430, 820], [55, 80, 120], 0.16, f"trvstop{i}",
               amps=[1.0, 0.45, 0.2], strike=0.6, strike_hz=2100.0,
               spread=0.08), -19.0)


# --- Impacts: readable by outcome --------------------------------------------
#
# damage_resolver.gd already distinguishes chip damage, a normal reduced hit, a
# brute-force hit and a module strip. Those branches are invisible to the player
# right now because every one of them plays the same "hit". These give each a
# distinct sound, so a player can hear that their shots are BOUNCING - which is
# the single most useful piece of combat feedback an armour system can give.

def impact_chip(i):
    """Below threshold: a bounce. Bright, short, no low end - nothing got in."""
    return d.match_loudness(
        _modal([2100, 3800, 6200], [130, 190, 280], 0.13, f"chip{i}",
               amps=[1.0, 0.55, 0.28], strike=0.75, strike_hz=5200.0,
               spread=0.10), -20.0)


def impact_penetrate(i):
    """Armour defeated. A bright CRACK (the perforation itself), then tearing
    metal over a settling thud.

    The first pass was all thud and tear - measured at 56% energy below 120 Hz -
    and a penetration is identified by its crack: the sharp broadband snap of
    plate giving way is what separates "through" from "bounced" at a glance.
    """
    dur = 0.34
    g = d.rng(f"pen{i}")
    out = d.silence(dur)
    # Every layer gets its own per-variant tuning - the first pass only
    # jittered a +/-0.5 dB trim and the five files measured as clones.
    crack = d.filt(g.uniform(-1.0, 1.0, d.n_samples(0.02)),
                   "bp", 2100.0 * (1.0 + g.uniform(-0.25, 0.25)), 1.1)
    crack *= d.decay_env(0.02, 300.0, 0.0002)
    tear = d.sweep_filter(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp",
                          d.breakpoints(dur,
                                        [(0.0, 950.0 * (1.0 + g.uniform(-0.2, 0.2))),
                                         (1.0, 480.0 * (1.0 + g.uniform(-0.25, 0.25)))]),
                          0.55)
    tear *= d.decay_env(dur, 20.0, 0.0004)
    thud_end = 68.0 * (1.0 + g.uniform(-0.15, 0.15))
    thud = d.sine(d.breakpoints(dur, [(0.0, 200.0),
                                      (0.15, thud_end / 0.79), (1.0, thud_end)]),
                  dur) * d.decay_env(dur, g.uniform(13.0, 19.0), 0.0006)
    ring = _modal([1250, 2400], [90, 140], 0.12, f"penr{i}", amps=[1.0, 0.4],
                  strike=0.3, strike_hz=3000.0, spread=0.10)
    d.place(out, crack * 0.85, 0.0)
    out += tear * 0.8 + thud * 0.6
    d.place(out, ring * 0.22, 0.006)
    return d.match_loudness(d.drive(out, 1.6),
                            -13.0 + g.uniform(-0.5, 0.5))


def impact_module_lost(i):
    """A subsystem stripped. Something structural came off."""
    dur = 0.45
    g = d.rng(f"mod{i}")
    snap = _modal([520, 980, 1900, 3400], [35, 60, 100, 170], dur, f"modm{i}",
                  amps=[1.0, 0.6, 0.35, 0.18], strike=0.8, strike_hz=3000.0,
                  spread=0.08)
    # The part coming AWAY: a heavy low clunk under the snap.
    clunk = d.sine(d.breakpoints(dur, [(0.0, 185.0), (0.2, 66.0), (1.0, 54.0)]),
                   dur) * d.decay_env(dur, 14.0, 0.0008) * 0.5
    debris = d.silence(dur)
    for k in range(5):
        t = g.uniform(0.08, 0.40)
        d.place(debris, _modal([900 + k * 450], [220], 0.08, f"deb{i}{k}",
                               strike=0.6, spread=0.15) * g.uniform(0.25, 0.55), t)
    return d.match_loudness(snap * 0.9 + clunk + debris * 0.6,
                            -15.0 + g.uniform(-0.5, 0.5))


def impact_immobilised(i):
    """All locomotion gone. A grinding halt - the machine stops moving."""
    dur = 0.6
    g = d.rng(f"immob{i}")
    # Both grind bands and the screech sweep are per-variant tuned: a seizing
    # drivetrain is never the same pitch twice.
    grind = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                   "bp", 640.0 * (1.0 + g.uniform(-0.18, 0.18)), 0.6)
    grind += d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)),
                    "bp", 1350.0 * (1.0 + g.uniform(-0.18, 0.18)), 1.0) * 0.45
    grind *= d.breakpoints(dur, [(0.0, 1.0), (0.5, 0.6), (1.0, 0.0)])
    # Metal screech rising as the last drive seizes.
    screech_lo = 900.0 * (1.0 + g.uniform(-0.12, 0.12))
    screech_hi = screech_lo * g.uniform(1.55, 1.85)
    screech = d.sweep_resonator(
        d.pink(dur, f"immobs{i}"),
        d.breakpoints(dur, [(0.0, screech_lo), (0.7, screech_hi),
                            (1.0, screech_hi * 0.9)]), 95.0)
    screech *= d.breakpoints(dur, [(0.0, 0.0), (0.3, 0.5), (0.8, 0.9), (1.0, 0.0)]) * 0.22
    drop_end = 44.0 * (1.0 + g.uniform(-0.10, 0.10))
    drop = d.sine(d.breakpoints(dur, [(0.0, 120.0), (1.0, drop_end)]), dur)
    drop *= d.decay_env(dur, g.uniform(5.5, 7.5), 0.001)
    return d.match_loudness(d.drive(grind * 0.8 + screech + drop * 0.55, 1.5),
                            -14.0)


def impact_catastrophic(i):
    """A kill. The one impact allowed to be big - it is the end of a unit.

    REBALANCED FOR LEGIBILITY. The first pass measured 96% of its energy below
    120 Hz with a spectral centroid of 132 Hz - technically enormous, and
    practically a muffled thump that hid the event it was announcing. A real
    catastrophic kill has an attack CRACK, a mid-heavy blast, then debris; the
    sub drop stays but demoted to one layer of four.
    """
    dur = 0.95
    g = d.rng(f"cat{i}")
    out = d.silence(dur)

    # Attack crack: the initial armour/structure failure, top-heavy.
    crack = d.filt(g.uniform(-1.0, 1.0, d.n_samples(0.03)), "hp", 850.0, 0.707)
    crack *= d.decay_env(0.03, 220.0, 0.0002)
    d.place(out, crack * 1.1, 0.0)

    # Blast body: pink-based rather than brown - brown's -6 dB/octave tilt was
    # what buried this sound in the sub - and opened up to 3.2 kHz so the mid
    # actually arrives.
    blast = d.filt(d.pink(dur, f"catb{i}"), "lp", 3200.0, 0.707)
    blast *= d.decay_env(dur, 5.5, 0.0006)
    out += blast * 0.9

    # Sub drop: kept, quietly - weight without ownership.
    sub = d.sine(d.breakpoints(dur, [(0.0, 88.0), (0.3, 44.0), (1.0, 33.0)]), dur)
    sub *= d.decay_env(dur, 4.5, 0.001)
    out += sub * 0.4

    # Debris shower: more pieces, brighter, longer scatter than before.
    debris = d.silence(dur)
    for k in range(14):
        d.place(debris, _modal([800 + k * 260], [170], 0.09, f"catd{i}{k}",
                               strike=0.75, spread=0.18)
                * g.uniform(0.35, 0.75), g.uniform(0.06, 0.80))
    out += debris * 0.8

    # Smoulder: a low breath of fire dying down over the tail.
    smoulder = d.filt(d.pink(dur, f"cats{i}"), "bp", 600.0, 0.6)
    smoulder *= d.decay_env(dur, 3.2, attack=0.08)
    out += smoulder * 0.14
    return d.match_loudness(d.drive(out, 1.4), -11.0 + g.uniform(-0.4, 0.4))


# --- Construction and economy ------------------------------------------------

def construct_start(i):
    """A foundation being set."""
    return d.match_loudness(
        _modal([180, 350, 700, 1300], [22, 38, 65, 110], 0.55,
               f"found{i}", amps=[1.0, 0.6, 0.32, 0.16],
               strike=0.6, strike_hz=1900.0, spread=0.07), -17.0)


def construct_loop(i):
    """Building in progress. Rhythmic, machine-like, seamless."""
    dur = 1.8
    g = d.rng(f"cons{i}")
    out = d.silence(dur)
    t = 0.0
    while t < dur - 0.12:
        d.place(out, _modal([420, 810, 1500], [95, 140, 210], 0.11,
                            f"cons{i}:{t:.2f}", amps=[1.0, 0.5, 0.25],
                            strike=0.5, strike_hz=2400.0,
                            spread=0.10) * g.uniform(0.45, 0.65), t)
        t += g.uniform(0.27, 0.33)
    motor = d.filt(d.pink(dur, f"consm{i}"),
                   "bp", 430.0 * (1.0 + g.uniform(-0.15, 0.15)), 0.8) * 0.3
    return d.match_loudness(_seamless(out + motor, 0.3), -18.0)


def construct_done(i):
    """Complete. A latch plus a short rising confirmation - mechanical."""
    dur = 0.4
    g = d.rng(f"done{i}")
    seat = _modal([300, 590, 1100], [30, 50, 85], dur, f"done{i}",
                  amps=[1.0, 0.55, 0.28], strike=0.7, strike_hz=2200.0,
                  spread=0.06)
    conf = d.sine(d.breakpoints(dur, [(0.0, 620.0 * (1 + g.uniform(-0.03, 0.03))),
                                      (0.35, 930.0), (1.0, 930.0)]),
                  dur) * d.decay_env(dur, 9.0, 0.004) * 0.28
    return d.match_loudness(seat * 0.9 + conf, -16.0)


def unit_rollout(i):
    """A finished unit leaving the factory: door, then drive-away."""
    dur = 0.7
    g = d.rng(f"roll{i}")
    door = d.filt(g.uniform(-1.0, 1.0, d.n_samples(dur)), "bp", 900.0, 0.6)
    door *= d.breakpoints(dur, [(0.0, 0.9), (0.35, 0.4), (0.5, 0.0), (1.0, 0.0)])
    clunk = _modal([260, 500, 950], [35, 55, 90], 0.3, f"rolld{i}",
                   amps=[1.0, 0.5, 0.25], strike=0.6, strike_hz=2000.0,
                   spread=0.08)
    out = d.silence(dur)
    d.place(out, door * 0.4, 0.0)
    d.place(out, clunk * 0.85, 0.36)
    return d.match_loudness(out, -17.0)


def harvester_dock(i):
    return d.match_loudness(
        _modal([210, 400, 760, 1400], [28, 45, 78, 130], 0.5,
               f"dock{i}", amps=[1.0, 0.6, 0.3, 0.15],
               strike=0.55, strike_hz=2100.0, spread=0.07), -17.0)


def harvester_full(i):
    """Load complete. Two rising mechanical notes - a signal, not a jingle."""
    dur = 0.36
    g = d.rng(f"hfull{i}")
    detune = 1.0 + g.uniform(-0.04, 0.04)
    a = _modal([880 * detune], [30], dur, f"hfa{i}", strike=0.3,
               strike_hz=3000.0, spread=0.05)
    b = _modal([1320 * detune], [30], dur, f"hfb{i}", strike=0.3,
               strike_hz=3400.0, spread=0.05)
    out = d.silence(dur)
    d.place(out, a * 0.7, 0.0)
    d.place(out, b * 0.8, 0.12)
    return d.match_loudness(out, -17.0)


def repair_loop(i):
    """Repair arm working. A welder: arc crackle over a transformer buzz.

    REBUILT. The first pass gated white noise with a square LFO - it read as a
    faulty fluorescent tube. What says "arc welder" is dense random micro-
    grains (the arc striking and re-striking hundreds of times a second) plus
    spatter: occasional bigger sparks thrown clear.
    """
    dur = 1.5
    g = d.rng(f"rep{i}")
    crackle = d.silence(dur)
    t = 0.0
    while t < dur - 0.01:
        ln = g.uniform(0.001, 0.004)
        grain = d.filt(g.uniform(-1.0, 1.0, d.n_samples(ln)),
                       "bp", g.uniform(1800.0, 3400.0), 0.9)
        grain *= d.decay_env(ln, 600.0, 0.0001)
        d.place(crackle, grain * g.uniform(0.12, 0.55), t)
        t += g.uniform(0.004, 0.028)
    # Spatter: a few sparks land noticeably further away than the rest.
    for k in range(5):
        ln = g.uniform(0.006, 0.014)
        spark = d.filt(g.uniform(-1.0, 1.0, d.n_samples(ln)), "hp", 2600.0, 0.8)
        spark *= d.decay_env(ln, 300.0, 0.0002)
        d.place(crackle, spark * g.uniform(0.2, 0.45), g.uniform(0.05, dur - 0.05))
    buzz = d.filt(d.saw(118.0, dur) + d.saw(236.0, dur) * 0.4, "bp", 1500.0, 0.8)
    out = d.filt(crackle + buzz * 0.13, "lp", 6500.0, 0.707)
    return d.match_loudness(_seamless(out, 0.3), -18.0)


# --- Ambience ----------------------------------------------------------------
#
# One bed per surface type in terrain_builder.gd's SURFACE_PALETTE (line 415),
# plus wind and a Lab room tone. All long and seamless: these play continuously
# under everything else, so a seam would be heard every few seconds.

def _wind(dur, intensity, seed):
    g = d.rng(seed)
    base = d.pink(dur, seed + ":p")
    # Gusts: slow amplitude and cutoff movement together. Constant-level wind
    # reads as noise; wind is identified by its MOVEMENT.
    gust = d.filt(g.normal(0, 1, d.n_samples(dur)), "lp", 0.28, 0.707)
    gust = 0.55 + 0.45 * (gust / (np.max(np.abs(gust)) + 1e-9))
    cutoff = 380.0 + 1500.0 * intensity * gust
    out = d.sweep_filter(base, "lp", cutoff, q=0.7)
    return out * gust * (0.35 + 0.65 * intensity)


def ambience(i, surface="rocky"):
    """A surface's bed. 8 seconds, seamless."""
    dur = 8.0
    g = d.rng(f"amb{surface}{i}")
    wind_level = {
        "marsh": 0.30, "rocky": 0.55, "snow_mud": 0.45, "sand": 0.70,
        "gravel": 0.50, "forest": 0.40, "ice": 0.65,
    }.get(surface, 0.5)
    out = _wind(dur, wind_level, f"amb{surface}{i}")

    if surface == "marsh":
        # Water movement and the odd bubble.
        out += d.filt(d.pink(dur, f"marshw{i}"), "bp", 700.0, 0.6) * 0.18
        for k in range(14):
            t = g.uniform(0, dur - 0.3)
            blip = d.sine(d.breakpoints(0.12, [(0.0, 380.0), (1.0, 820.0)]), 0.12)
            d.place(out, blip * d.decay_env(0.12, 26.0, 0.002) * g.uniform(0.03, 0.10), t)
    elif surface == "forest":
        # Leaf rustle and distant birds.
        out += d.filt(d.pink(dur, f"leaf{i}"), "hp", 2600.0, 0.707) * 0.12
        for k in range(7):
            t = g.uniform(0, dur - 0.5)
            f0 = g.uniform(1900, 3400)
            call = d.sine(d.breakpoints(0.16, [(0.0, f0), (0.5, f0 * 1.25),
                                               (1.0, f0 * 0.95)]), 0.16)
            d.place(out, call * d.decay_env(0.16, 14.0, 0.01) * g.uniform(0.02, 0.06), t)
    elif surface == "ice":
        # Creaks and the occasional deep crack.
        for k in range(6):
            t = g.uniform(0, dur - 0.8)
            creak = d.sweep_filter(d.pink(0.6, f"ice{i}{k}"), "bp",
                                   d.breakpoints(0.6, [(0.0, 320.0), (1.0, 190.0)]), 3.0)
            d.place(out, creak * d.adsr(0.6, 0.1, 0.2, 0.5, 0.3) * g.uniform(0.05, 0.14), t)
    elif surface == "sand":
        out += d.filt(d.pink(dur, f"grit{i}"), "hp", 3800.0, 0.707) * 0.14
    elif surface in ("gravel", "rocky"):
        out += d.filt(d.brown(dur, f"rock{i}"), "lp", 180.0, 0.707) * 0.22
    elif surface == "snow_mud":
        out = d.filt(out, "lp", 2200.0, 0.707)   # snow deadens the top end

    return d.match_loudness(_seamless(out, 1.0), -24.0)


def ambience_lab(i):
    """Design Lab room tone. A workshop with the machines idling."""
    dur = 8.0
    g = d.rng(f"lab{i}")
    room = d.filt(d.brown(dur, f"labroom{i}"), "lp", 240.0, 0.707) * 0.22
    # Fluorescent ballast: 100 Hz and its odd harmonics - a pure 100 Hz sine on
    # its own reads as a hum test tone.
    fluoro = (d.saw(100.0, dur) * 0.030 + d.sine(150.0, dur) * 0.010)
    vent = d.filt(d.pink(dur, f"labvent{i}"), "bp", 680.0, 0.55)
    vent *= 0.85 + 0.15 * d.sine(0.9, dur)
    out = room + fluoro + vent * 0.30
    for k in range(5):
        d.place(out, _modal([1400, 2600], [200, 300], 0.07, f"labtick{i}{k}",
                            strike=0.4, spread=0.12) * g.uniform(0.03, 0.07),
                g.uniform(0, dur - 0.2))
    return d.match_loudness(_seamless(out, 1.0), -26.0)


def distant_artillery(i):
    """A war happening somewhere else. Sincere, and the strongest single cue
    that the environment takes the conflict seriously.

    Distance is carried by the ROLLOFF and the ECHO, not by removing everything
    above the sub: the first pass low-passed each boom to 90-190 Hz and measured
    87% of total energy below 120 Hz - a bump felt rather than heard. These
    booms keep a mid shoulder plus a delayed ground reflection, which is what
    actually makes a far-off explosion parse as one.
    """
    dur = 8.0
    g = d.rng(f"arty{i}")
    out = d.silence(dur)
    for k in range(5):
        t = g.uniform(0, dur - 1.6)
        boom_dur = 1.2
        boom = d.filt(d.brown(boom_dur, f"arty{i}{k}"),
                      "lp", g.uniform(180.0, 340.0), 0.707)
        boom *= d.decay_env(boom_dur, g.uniform(2.5, 5.0), 0.02)
        # Mid shoulder: the part small speakers reproduce.
        thump = d.filt(d.pink(boom_dur, f"artym{i}{k}"), "bp", 190.0, 0.8)
        thump *= d.decay_env(boom_dur, 7.0, 0.01)
        amp = g.uniform(0.25, 0.65)
        d.place(out, (boom + thump * 0.55) * amp, t)
        # Ground reflection arriving late and duller.
        echo = d.filt(boom, "lp", 260.0, 0.707)
        d.place(out, echo * amp * g.uniform(0.25, 0.4), t + g.uniform(0.3, 0.5))
    return d.match_loudness(_seamless(out, 1.0), -27.0)


# --- The manifest ------------------------------------------------------------
#
# key -> (generator, variant count, subdirectory). audio_manager.gd's SFX_PATHS
# is generated FROM this by the CLI, so the two cannot drift: a key added here
# appears in the engine, and a key removed here disappears from it.

SURFACES = ["marsh", "rocky", "snow_mud", "sand", "gravel", "forest", "ice"]
ENGINE_KINDS = ["diesel", "turbine", "electric", "heavy"]
COMMS_PHRASES = ["ack", "affirm", "negative", "engaging", "structure_lost",
                 "low_power", "ready", "unit_lost"]


# --- Build-complete chimes, one distinct motif per roster slot -----------------
#
# A vehicle rolling out of the factory is a notification the player should learn
# to read by ear: slot N has its own two-note rising motif on a fixed root, so a
# regular roster means "that chime = my third design". Sincere (bell partials),
# never vocalised - this is an interface cue, on the wrong side of the split for
# comedy. 12 slots span just over two octaves on a mostly-diatonic ladder, so no
# two adjacent slots are confusable.

_UNIT_READY_ROOTS = [196.0, 220.0, 246.94, 261.63, 293.66, 329.63, 349.23,
                     392.0, 440.0, 493.88, 523.25, 587.33]  # G3..D#5


def unit_ready(slot: int, variant: int = 0) -> np.ndarray:
    """A build-complete chime for roster slot `slot` (1..12)."""
    g = d.rng(f"ready:{slot}:{variant}")
    root = _UNIT_READY_ROOTS[(slot - 1) % 12] * (1.0 + g.uniform(-0.008, 0.008))
    dur = 0.46
    out = d.silence(dur)
    # Rising motif: root -> major third, bell-like (fundamental + octave + fifth)
    # with a quick attack and a long decay so it reads as "done" and rings off.
    for semi, amp, t0 in ((0.0, 1.0, 0.0), (4.0, 0.66, 0.13)):
        f = root * (2.0 ** (semi / 12.0))
        for mult, a in ((1.0, 1.0), (2.0, 0.45), (3.0, 0.22)):
            tone = d.sine(f * mult, dur - t0) * d.decay_env(
                dur - t0, 240.0 / mult, 0.004) * a * amp
            d.place(out, tone, t0)
    # A soft contact tick at the onset so the event reads as a thing arriving.
    tick = d.filt(g.uniform(-1.0, 1.0, d.n_samples(0.02)), "bp", 2600.0, 0.8)
    d.place(out, tick * d.decay_env(0.02, 600.0, 0.0002) * 0.35, 0.0)
    return d.match_loudness(out, -16.0)


def manifest() -> dict:
    """Every sound the game can play, as {key: [(name, callable), ...]}."""
    out: dict = {}

    def add(key, fn, count, folder="sfx"):
        out[key] = {"folder": folder,
                    "variants": [(f"{key}_{n + 1:02d}", lambda i=n: fn(i))
                                 for n in range(count)]}

    # Interface - the fourteen roles ui_feedback.gd expects.
    add("hover", ui_hover, 3)
    add("click", ui_click, 5)
    add("select", ui_select, 4)
    add("place", ui_place, 4)
    add("error", ui_error, 3)
    add("ui_toggle_on", ui_toggle_on, 3)
    add("ui_toggle_off", ui_toggle_off, 3)
    add("ui_dial", ui_dial, 4)
    add("ui_tick", ui_tick, 4)
    add("ui_drawer", ui_drawer, 3)
    add("ui_plate", ui_plate, 3)
    add("ui_latch", ui_latch, 3)
    add("ui_mode", ui_mode, 3)
    # Used by ui/system_layer.gd for the pause/system menu.
    add("ui_menu_open", ui_menu_open, 2)
    add("ui_menu_close", ui_menu_close, 2)
    add("warning_banner", ui_warning, 3)

    # Ordnance - VOCALISED. The only absurd entries in this table.
    for key, fn in V.ORDNANCE.items():
        add(key, fn, 7)

    # Comms - sincere, and the only thing on the Voice bus.
    for phrase in COMMS_PHRASES:
        tone = "alert" if phrase in ("structure_lost", "low_power", "unit_lost") \
            else "calm"
        add(f"radio_{phrase}",
            lambda i, p=phrase, t=tone: V.comms(p, i, t), 4, folder="voice")
    add("radio_static", lambda i: V.comms("ack", i + 40, "calm"), 2, folder="voice")
    # order_ping stays a tone rather than speech: it acknowledges the PLAYER's
    # click, so it belongs with the interface, not with the unit talking back.
    add("order_ping", ui_dial, 3)

    # Mechanical loops.
    for kind in ENGINE_KINDS:
        add(f"engine_{kind}", lambda i, k=kind: engine_loop(i, k), 2)
    add("tread_loop", tread_loop, 2)
    add("wheel_loop", wheel_loop, 2)
    add("servo_loop", servo_loop, 2)
    add("hydraulic_loop", hydraulic_loop, 2)
    add("rotor_loop", rotor_loop, 2)
    add("screw_loop", screw_loop, 2)
    add("turret_start", turret_start, 3)
    add("turret_stop", turret_stop, 3)

    # Impacts, by outcome.
    add("impact_chip", impact_chip, 5)
    add("impact_penetrate", impact_penetrate, 5)
    add("impact_module_lost", impact_module_lost, 4)
    add("impact_immobilised", impact_immobilised, 3)
    add("impact_catastrophic", impact_catastrophic, 4)

    # Construction and economy.
    for _slot in range(1, 13):
        add(f"unit_ready_{_slot}",
            lambda i, s=_slot: unit_ready(s, i), 3)
    add("construct", construct_start, 3)
    add("construct_loop", construct_loop, 2)
    add("construct_done", construct_done, 3)
    add("unit_rollout", unit_rollout, 3)
    add("harvester_dock", harvester_dock, 3)
    add("harvester_full", harvester_full, 3)
    add("repair_loop", repair_loop, 2)

    # Ambience.
    for surface in SURFACES:
        add(f"ambience_{surface}", lambda i, s=surface: ambience(i, s), 1,
            folder="ambience")
    add("ambience_lab", ambience_lab, 1, folder="ambience")
    add("ambience_artillery", distant_artillery, 1, folder="ambience")

    return out
