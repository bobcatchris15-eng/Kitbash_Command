"""Formant synthesis: a person doing the sound effect with their mouth.

WHY THIS EXISTS AT ALL. CORE_DESIGN_LANGUAGE.md 6.2 requires the ordnance to be
vocalised - "literal human voice recordings ('pew pew', 'kapow') instead of
actual ordnance recordings" - and 7.5 has been carrying that as an open item
because it implied a recording session. It does not have to. A source-filter
model (a glottal pulse train through a bank of moving formant resonators) is how
speech synthesis worked for forty years before sample concatenation took over,
and "pyoo" and "ka-PAOW" are exactly the easy case for it: short, isolated,
heavily prosodic, and nobody has to parse them as language.

THE PERFORMANCE DIRECTION IS PART OF THE SPEC, not decoration. 6.2 says deadpan
and committed, recorded dry and close - "not a comedian doing a bit, a person
doing the sound effect sincerely, the way a child playing with models does."
Concretely that means:

  * NO REVERB, NO SUB LAYER. 6.1 names both as ways the joke dies: a vocalisation
    with weight layered under it stops being a person and becomes a sound effect
    with a voice on it. This module does not import dsp.reverb and must not.
  * Chest register, moderate effort. Shouting reads as zany; 6.2 asks for wry.
  * Pitch and timbre still differentiate weapon class, because the audio has to
    stay INFORMATIVE - the player identifies what is shooting without looking.
    That constraint is why CLASS_VOICES below varies f0 by more than an octave
    across the set rather than just changing the syllables.

ARCHITECTURE. One pass, not per-segment splicing:

  1. A single glottal source across the whole utterance, gated to zero during
     closures and unvoiced stretches.
  2. Formant trajectories F1..F4 built from per-segment targets with ~25 ms
     transitions, so the tract MOVES between phonemes instead of jumping. This
     is most of what separates speech-like output from a robot vowel organ.
  3. Four parallel swept band-passes over that one source, summed.
  4. Consonant bursts and fricatives synthesised separately and added at their
     time positions - they are noise excitation, not glottal.
  5. A final differentiator for lip radiation.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import SAMPLE_RATE
from . import dsp as d

SR = SAMPLE_RATE


# --- Phoneme tables ----------------------------------------------------------
#
# F1/F2/F3/F4 in Hz for an adult male tract, which is the register 6.2's
# "deadpan and committed" asks for. These are the standard Peterson-Barney
# centres; they are not tuned by ear, and that is deliberate - starting from
# measured values and then adjusting prosody gets there far faster than dialling
# in twelve resonators by feel.

VOWELS = {
    "iy": (270, 2290, 3010, 3300),   # ee   - beet
    "ih": (390, 1990, 2550, 3300),   # i    - bit
    "eh": (530, 1840, 2480, 3300),   # e    - bet
    "ae": (660, 1720, 2410, 3300),   # a    - bat
    "aa": (730, 1090, 2440, 3300),   # ah   - father
    "ao": (570, 840, 2410, 3300),    # aw   - bought
    "uh": (640, 1190, 2390, 3300),   # u    - but
    "uw": (300, 870, 2240, 3300),    # oo   - boot
    "er": (490, 1350, 1690, 3300),   # er   - bird
    "ax": (500, 1500, 2500, 3300),   # schwa - unstressed
}

# Formant bandwidths. Narrow enough to read as resonances rather than as a
# general spectral tilt - this was widened from the first attempt, where the
# vowels came out mushy and the identity of each one was hard to hear.
BANDWIDTHS = (55.0, 80.0, 130.0, 220.0)

# Plosive release bursts: (centre Hz, Q, brightness tilt). A burst's spectral
# shape is the ONLY cue distinguishing p from t from k, since the closure before
# it is silence in every case.
BURSTS = {
    "p": (900.0, 0.7, 0.35),     # bilabial - broad and low, the "pow" attack
    "b": (700.0, 0.7, 0.25),     # voiced bilabial - softer
    "t": (4200.0, 1.4, 1.0),     # alveolar - bright and sharp
    "d": (3200.0, 1.3, 0.7),
    "k": (1900.0, 2.6, 0.6),     # velar - compact mid peak, the "ka" attack
    "g": (1500.0, 2.4, 0.5),
}

# Sustained noise. `voiced` fricatives get a glottal component mixed in.
FRICATIVES = {
    "f": (1600.0, 0.55, 0.30, False),
    "v": (1400.0, 0.55, 0.25, True),
    "s": (6200.0, 2.0, 0.85, False),
    "z": (5600.0, 2.0, 0.60, True),
    "sh": (2500.0, 1.3, 0.80, False),
    "h": (1200.0, 0.4, 0.35, False),
}


@dataclass
class Seg:
    """One phonetic segment.

    kind: 'v' vowel/glide | 'p' plosive | 'f' fricative | 'n' nasal | '_' silence
    what: vowel key, or "aa>uw" for a glide, or a plosive/fricative key
    """
    kind: str
    dur: float
    what: str = ""
    amp: float = 1.0


@dataclass
class VoiceSpec:
    """A complete utterance. `f0` is a breakpoint contour over the whole thing."""
    segs: list
    f0: list = field(default_factory=lambda: [(0.0, 130.0), (1.0, 95.0)])
    breath: float = 0.05
    jitter: float = 0.010     # cycle-to-cycle pitch wobble; 0 sounds synthetic
    shimmer: float = 0.045    # cycle-to-cycle amplitude wobble
    effort: float = 1.0       # raises f0 and opens the glottal pulse
    # Peak level of the consonant bursts relative to the RMS of the voiced
    # body, in dB. See the balancing note in `utter`. Around +12 dB puts the
    # attack clearly in front without the burst reading as its own event;
    # percussive sounds ("donk") want more, breathy ones ("fwoosh") less.
    burst_db: float = 12.0
    # Peak level of the post-release aspiration, same reference. Negative: the
    # breath is quieter than the vowel body it leads into.
    aspiration_db: float = -3.0


# --- The glottal source ------------------------------------------------------

def _glottal(f0: np.ndarray, duration: float, seed: str,
             jitter: float, shimmer: float, open_quotient: float) -> np.ndarray:
    """Rosenberg glottal flow pulse train.

    A sawtooth would be the lazy substitute and it is audibly wrong: the real
    pulse has a smooth rising limb and an abrupt closure, which puts the energy
    in the closure instant. That asymmetry is what makes a voice sound like a
    voice rather than like a filtered buzz.
    """
    g = d.rng(seed)
    n = d.n_samples(duration)

    # Jitter is slow drift plus per-sample grain, low-passed so it perturbs
    # pitch over cycles rather than adding hiss.
    if jitter > 0.0:
        wobble = d.filt(g.normal(0.0, 1.0, n), "lp", 22.0, 0.707)
        wobble /= (np.max(np.abs(wobble)) + 1e-12)
        f0 = f0 * (1.0 + wobble * jitter)

    phase = d.phase_of(f0, duration)

    oq = float(np.clip(open_quotient, 0.35, 0.85))
    rise = oq * 0.62          # ratio of the open phase spent opening
    t1, t2 = oq * rise, oq * (1.0 - rise)

    out = np.zeros(n)
    opening = phase < t1
    closing = (phase >= t1) & (phase < oq)

    out[opening] = 0.5 * (1.0 - np.cos(np.pi * phase[opening] / t1))
    out[closing] = np.cos(np.pi * (phase[closing] - t1) / (2.0 * t2))
    # Remaining phase is the closed quotient: flow is zero, which is the point.

    if shimmer > 0.0:
        amp = d.filt(g.normal(0.0, 1.0, n), "lp", 18.0, 0.707)
        amp /= (np.max(np.abs(amp)) + 1e-12)
        out *= 1.0 + amp * shimmer

    return out


def _trajectory(segs, total: float, index: int, transition: float = 0.040) -> np.ndarray:
    """Formant `index` over the whole utterance, with smoothed transitions.

    Segments that are not vowels hold the previous vowel's target rather than
    resetting, because the tract does not spring back to neutral during a 12 ms
    plosive burst - the burst is coloured by where the tongue already is, and
    holding the target is a cheap way to get that coarticulation.
    """
    n = d.n_samples(total)
    traj = np.zeros(n)

    current = VOWELS["ax"][index]
    pos = 0.0
    for seg in segs:
        start, stop = d.n_samples(pos), d.n_samples(pos + seg.dur)
        stop = min(stop, n)
        if seg.kind == "v" and seg.what:
            if ">" in seg.what:
                a, b = seg.what.split(">")
                lo, hi = VOWELS[a][index], VOWELS[b][index]
                # Cosine rather than linear: a glide accelerates out of the
                # first target and decelerates into the second.
                k = np.linspace(0.0, 1.0, max(1, stop - start))
                traj[start:stop] = lo + (hi - lo) * (0.5 - 0.5 * np.cos(np.pi * k))
                current = hi
            else:
                traj[start:stop] = VOWELS[seg.what][index]
                current = VOWELS[seg.what][index]
        elif seg.kind == "n":
            # Nasals pull F1 down hard and damp everything above it.
            traj[start:stop] = (250.0, 1100.0, 2300.0, 3300.0)[index]
        else:
            traj[start:stop] = current
        pos += seg.dur

    if pos < total:
        traj[d.n_samples(pos):] = current

    # One-pole smooth over the whole trajectory removes the step at every
    # boundary. 1/transition Hz gives roughly the intended glide time.
    return d.filt(traj, "lp", 1.0 / max(0.004, transition), 0.707)


def _gate(segs, total: float) -> np.ndarray:
    """Per-sample amplitude of the VOICED source (zero during closures)."""
    n = d.n_samples(total)
    gate = np.zeros(n)
    pos = 0.0
    for seg in segs:
        start, stop = d.n_samples(pos), min(n, d.n_samples(pos + seg.dur))
        if seg.kind in ("v", "n"):
            gate[start:stop] = seg.amp
        elif seg.kind == "f" and FRICATIVES.get(seg.what, (0, 0, 0, False))[3]:
            gate[start:stop] = seg.amp * 0.35
        pos += seg.dur
    # 6 ms smoothing: fast enough to keep plosive closures crisp, slow enough
    # that switching the source on does not itself click.
    return d.filt(gate, "lp", 160.0, 0.707)


def _aspiration_gate(segs, total: float, vot: float = 0.030) -> np.ndarray:
    """Breath window following each plosive release.

    Voiceless stops (p, t, k) aspirate; voiced ones (b, d, g) barely do, which
    is exactly the cue that separates the two sets for a listener.
    """
    n = d.n_samples(total)
    gate = np.zeros(n)
    pos = 0.0
    for seg in segs:
        if seg.kind == "p":
            level = 1.0 if seg.what in ("p", "t", "k") else 0.25
            start = d.n_samples(pos)
            stop = min(n, start + d.n_samples(vot))
            if stop > start:
                # Decays across the window: loudest right at the release.
                gate[start:stop] = level * np.linspace(1.0, 0.0, stop - start) ** 1.5
        pos += seg.dur
    return d.filt(gate, "lp", 300.0, 0.707)


def _noise_events(segs, total: float, seed: str) -> np.ndarray:
    """Plosive bursts and fricatives - the non-glottal excitation."""
    g = d.rng(seed + ":noise")
    out = d.silence(total)
    pos = 0.0

    for seg in segs:
        if seg.kind == "p" and seg.what in BURSTS:
            centre, q, tilt = BURSTS[seg.what]
            # A release burst is 8-15 ms of noise with a very fast decay. Longer
            # than that and it stops being a burst and becomes aspiration.
            dur = min(seg.dur, 0.018)
            src = g.uniform(-1.0, 1.0, d.n_samples(dur))
            burst = d.resonator(src, centre, q)
            burst += d.filt(src, "hp", 2500.0, 0.707) * tilt * 0.5
            burst *= d.decay_env(dur, 320.0, attack=0.0004)
            d.place(out, burst * seg.amp * 1.6, pos)

        elif seg.kind == "f" and seg.what in FRICATIVES:
            centre, q, level, _voiced = FRICATIVES[seg.what]
            src = g.uniform(-1.0, 1.0, d.n_samples(seg.dur))
            fric = d.resonator(src, centre, q)
            # Fricatives fade in and out rather than switching on.
            fric *= d.adsr(seg.dur, attack=seg.dur * 0.25, decay=seg.dur * 0.2,
                           sustain=0.85, release=seg.dur * 0.35)
            d.place(out, fric * level * seg.amp, pos)

        pos += seg.dur
    return out


def utter(spec: VoiceSpec, seed: str) -> np.ndarray:
    """Render a VoiceSpec. Mono, dry, no reverb - see the module docstring."""
    total = sum(s.dur for s in spec.segs)
    n = d.n_samples(total)

    f0 = d.breakpoints(total, spec.f0) * (0.85 + 0.15 * spec.effort)
    source = _glottal(f0, total, seed, spec.jitter, spec.shimmer,
                      open_quotient=0.48 + 0.18 * spec.effort)

    # Breath: aspiration noise riding on the open phase of the glottal cycle,
    # not a constant hiss. Without it a synthetic voice is unnaturally pure.
    if spec.breath > 0.0:
        g = d.rng(seed + ":breath")
        aspiration = d.filt(g.uniform(-1.0, 1.0, n), "hp", 900.0, 0.707)
        source = source + aspiration * np.abs(source) * spec.breath * 4.0

    source *= _gate(spec.segs, total)

    # CASCADE, NOT PARALLEL. The first version summed four independent
    # band-passes, and that is why the result read as "a filtered buzz" rather
    # than as a voice: band-passes have zeros at DC and Nyquist, so summing
    # them scoops out the spectrum BETWEEN the formants and, worse, adjacent
    # peaks partially cancel where their skirts overlap out of phase. The vowel
    # identity - which lives in the RATIO of F1 to F2 - was being smeared away
    # by the synthesis method itself.
    #
    # A series cascade of two-pole resonators is how Klatt's synthesiser drives
    # its voiced branch, and it reproduces a vocal-tract transfer function
    # directly: the relative amplitude of each formant falls out of the physics
    # instead of needing a hand-tuned gain per formant (the FORMANT_GAINS table
    # this replaces was compensating for a problem that should not have existed).
    voiced = source
    for i in range(4):
        centre = _trajectory(spec.segs, total, i)
        # Bandwidth tracks centre frequency a little: higher formants are
        # genuinely broader in a real tract, and holding them all fixed makes
        # the top end ring.
        bw = BANDWIDTHS[i] * (0.75 + 0.25 * centre / max(1.0, VOWELS["ax"][i]))
        voiced = d.sweep_resonator(voiced, centre, bw)

    # ASPIRATION AFTER EACH PLOSIVE RELEASE (voice onset time). A stop consonant
    # is not just a burst - there is 20-40 ms of breath between the release and
    # the onset of voicing, shaped by the tract position the vowel is heading
    # for. It is one of the strongest cues that a mouth made the sound, and
    # leaving it out is much of why the first pass read as "subtle".
    asp_gate = _aspiration_gate(spec.segs, total)
    aspiration = np.zeros(n)
    if np.any(asp_gate > 0.0):
        g = d.rng(seed + ":asp")
        aspiration = g.uniform(-1.0, 1.0, n) * asp_gate
        for i in range(3):
            centre = _trajectory(spec.segs, total, i)
            aspiration = d.sweep_resonator(aspiration, centre,
                                           BANDWIDTHS[i] * 1.8)

    # LIP RADIATION, ON THE VOICED PATH ONLY. Sound leaves the mouth as a
    # pressure wave proportional to the DERIVATIVE of the volume flow, i.e.
    # +6 dB/octave; skipping it is why naive formant synths sound muffled.
    #
    # BUT IT MUST NOT BE APPLIED TO THE NOISE BRANCH. Differentiating broadband
    # burst noise boosts exactly the top octave where all of its energy already
    # is, and measurement showed the result was catastrophic rather than subtle:
    # plosive bursts landed ~24 dB ABOVE the vowel body (crest factor 29 on the
    # cannon, 36 on the explosion, against ~4-8 for real speech). Every one of
    # these sounds was a loud click with an inaudible voice hiding behind it.
    # Klatt-style synthesisers keep the two excitation branches separate for
    # this reason: the noise source carries its own spectral tilt, which BURSTS
    # and FRICATIVES already specify.
    voiced = np.diff(voiced, prepend=voiced[0]) * 40.0

    # BALANCE EVERY BRANCH BY MEASUREMENT, not by guessed constants. Both times
    # a branch was added here with a hand-picked gain it was wrong by more than
    # 20 dB - first the bursts at 1.6x, then the aspiration at 3.0x, which put
    # a spike 22 dB above the vowel body right after every plosive release.
    # Levels that must hold across seven sounds with different durations and
    # segment counts are not guessable; they have to be computed from what the
    # voiced path actually turned out to be.
    v_rms = float(np.sqrt(np.mean(voiced ** 2))) + 1e-12

    def _balanced(branch: np.ndarray, rel_db: float) -> np.ndarray:
        peak = float(np.max(np.abs(branch)))
        if peak < 1e-9:
            return branch
        return branch * (v_rms * d.db(rel_db) / peak)

    noise = _balanced(_noise_events(spec.segs, total, seed), spec.burst_db)
    # Aspiration sits BELOW the vowel it precedes: it is breath escaping past
    # an opening glottis, not an event of its own.
    aspiration = _balanced(aspiration, spec.aspiration_db)

    out = voiced + noise + aspiration

    # Gentle presence lift and a rolloff above the range a close mic would
    # capture. This is the entire "processing chain" - deliberately.
    out = d.filt(out, "hp", 90.0, 0.707)
    out = d.filt(out, "lp", 9000.0, 0.707)

    # FADE BEFORE NORMALISE, AND KEEP THE FADE-IN VERY SHORT. Both orderings
    # matter and the naive one was measurably wrong: a 3 ms fade-in over an
    # 8 ms plosive burst halves the transient, and since that burst IS the peak
    # of a short utterance, normalising first then fading meant "pyew" and
    # "donk" came out at 0.51 peak instead of 0.92 - quieter than the long
    # vowel-dominated sounds, which is backwards. The attack of a plosive is
    # the whole cue; 0.4 ms is enough to stop a click and short enough to leave
    # it intact.
    return d.normalize(d.fade(out, 0.0004, 0.012), 0.92)


# --- The ordnance set --------------------------------------------------------
#
# One entry per sfx key that auto_weapon.gd's weapon switch can select
# (scripts/auto_weapon.gd:1332-1338), plus the two impact keys unit.gd
# plays. f0 ranges are the informative channel: a player hears a 70 Hz "ka-POW"
# and a 380 Hz "pyoo" as different weapons before parsing either as a word.

def cannon(variant: int = 0) -> np.ndarray:
    """Low chest-voice "ka-POW". The heaviest thing in the set."""
    g = d.rng(f"cannon:{variant}")
    # Variant spread is deliberately wide here and in every generator below:
    # these banks fire dozens of times a minute, and the whole point of seven
    # variants is that no two shots in a burst are the same event. The first
    # pass varied pitch by +/-6%, which measured as barely-distinguishable
    # clones; +/-11% keeps the weapon identity while making repetition a non-
    # event.
    stretch = 1.0 + g.uniform(-0.13, 0.13)
    base = 78.0 * (1.0 + g.uniform(-0.11, 0.11))

    spec = VoiceSpec(
        segs=[
            Seg("p", 0.014, "k", 0.75),
            Seg("v", 0.055 * stretch, "aa", 0.45),      # unstressed "ka"
            Seg("_", 0.028),                            # closure before the P
            Seg("p", 0.016, "p", 1.0),
            # WIDER AND SLOWER THAN THE FIRST PASS. The diphthong is the word:
            # if the tract does not travel far enough, or travels too fast for
            # the ear to follow, "POW" collapses into an undifferentiated
            # vowel and the whole thing stops reading as speech. Starting at
            # "ae" rather than "aa" opens F2 much wider at the top of the
            # glide, so the ear hears the movement.
            Seg("v", 0.10 * stretch, "ae", 1.0),
            Seg("v", 0.30 * stretch, "ae>uw", 1.0),     # "POW" = /paʊ/
            Seg("v", 0.11 * stretch, "uw", 0.40),
        ],
        # Falls nearly an octave. The drop IS the weight - it is what the ear
        # reads as size, and it costs nothing in headroom the way a sub layer
        # would (which 6.1 forbids anyway).
        # Exaggerated: rises hard into the stressed syllable then falls well
        # over an octave. Real speech does this; the first pass was too flat
        # for the prosody to carry.
        f0=[(0.0, base * 1.15), (0.20, base * 1.55), (0.42, base * 1.05),
            (1.0, base * 0.48)],
        # Effort and burst level vary per variant as well as pitch - two
        # shots that differ only in f0 still share one spectral envelope, and
        # the pair measured near-identical on a cosine distance of averaged
        # spectra.
        breath=0.045, jitter=0.012, shimmer=0.06,
        effort=g.uniform(1.05, 1.45), burst_db=g.uniform(11.5, 14.5),
    )
    return utter(spec, f"cannon:{variant}")


def machine_gun(variant: int = 0) -> np.ndarray:
    """One clipped "pyew". Fired in bursts, these self-assemble into "pewpewpew"."""
    g = d.rng(f"mg:{variant}")
    base = 240.0 * (1.0 + g.uniform(-0.17, 0.17))
    pace = g.uniform(0.88, 1.14)
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.010 * pace, "p", 0.9),
            Seg("v", 0.032 * pace, "iy", 1.0),
            Seg("v", 0.058 * pace, "iy>uw", 1.0),
        ],
        f0=[(0.0, base * 1.40), (0.28, base * 1.05), (1.0, base * 0.42)],
        breath=0.06, jitter=0.016, shimmer=0.05, effort=0.9, burst_db=14.0,
    )
    return utter(spec, f"mg:{variant}")


def laser(variant: int = 0) -> np.ndarray:
    """High "pyoo" with a whine tail. Energy weapons read as bright and thin."""
    g = d.rng(f"laser:{variant}")
    base = 400.0 * (1.0 + g.uniform(-0.14, 0.14))
    # The trailing "oo" is where the weapon's character lives; its length and
    # the vocal effort behind it vary per variant, which the first pass never
    # touched (distance 0.002 - clones).
    tail = 0.045 * g.uniform(0.8, 1.3)
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.009, "p", 0.85),
            Seg("v", 0.035, "iy", 1.0),
            Seg("v", 0.135, "iy>uw", 1.0),
            Seg("v", tail, "uw", 0.30),
        ],
        f0=[(0.0, base * 1.10), (0.10, base * 1.32), (1.0, base * 0.26)],
        breath=0.04, jitter=0.008, shimmer=0.03,
        effort=g.uniform(0.72, 0.98), burst_db=11.0,
    )
    return utter(spec, f"laser:{variant}")


def missile(variant: int = 0) -> np.ndarray:
    """Breathy "fwooosh". Mostly fricative - a launch is air, not a bang."""
    g = d.rng(f"missile:{variant}")
    base = 150.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.055, "f", 0.9),
            Seg("v", 0.075, "uw", 0.55),
            Seg("v", 0.130, "uw>uh", 0.7),
            Seg("f", 0.230, "sh", 1.0),     # the burn, swelling then dying
        ],
        f0=[(0.0, base * 0.9), (0.35, base * 1.28), (1.0, base * 0.72)],
        breath=0.42, jitter=0.014, shimmer=0.07, effort=0.8, burst_db=6.0,
    )
    return utter(spec, f"missile:{variant}")


def explosion(variant: int = 0) -> np.ndarray:
    """Full "kaBOOOM" with a growl and a hummed nasal tail.

    The growl is raised jitter and shimmer DURING the boom - an irregular,
    rough glottal pulse is what "growl" is, physically - not a distortion stage.
    """
    g = d.rng(f"boom:{variant}")
    stretch = 1.0 + g.uniform(-0.12, 0.12)
    base = 88.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.013, "k", 0.7),
            Seg("v", 0.050 * stretch, "ax", 0.4),
            Seg("_", 0.022),
            Seg("p", 0.016, "b", 1.0),
            Seg("v", 0.115 * stretch, "uw", 1.0),
            Seg("v", 0.240 * stretch, "uw>aa", 0.95),
            Seg("n", 0.260 * stretch, "m", 0.55),       # the hummed tail
        ],
        f0=[(0.0, base * 1.25), (0.14, base * 1.60), (0.38, base * 1.00),
            (0.70, base * 0.66), (1.0, base * 0.40)],
        breath=0.08, jitter=0.042,
        shimmer=g.uniform(0.10, 0.17),
        effort=g.uniform(1.15, 1.55), burst_db=g.uniform(10.5, 13.5),
    )
    return utter(spec, f"boom:{variant}")


def hit(variant: int = 0) -> np.ndarray:
    """Short "donk" - a mouth pop for a round landing on armour."""
    g = d.rng(f"hit:{variant}")
    base = 165.0 * (1.0 + g.uniform(-0.13, 0.13))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.011, "d", 0.95),
            Seg("v", 0.030, "ao", 1.0),
            Seg("n", 0.055, "n", 0.55),
            Seg("p", 0.010, "k", 0.5),
        ],
        f0=[(0.0, base * 1.1), (1.0, base * 0.7)],
        breath=0.05, jitter=0.018, shimmer=0.06, effort=1.0,
        # Was 17 dB, and the d-burst arrived as a bare click in front of the
        # voice; the "d" attack should sit ON the donk, not before it.
        burst_db=13.5,
    )
    return utter(spec, f"hit:{variant}")


def harvest(variant: int = 0) -> np.ndarray:
    """A slurp. The harvester and repair array both route here."""
    g = d.rng(f"harvest:{variant}")
    base = 120.0 * (1.0 + g.uniform(-0.13, 0.13))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.045, "sh", 0.5),
            Seg("v", 0.180, "uw>iy", 0.85),
            Seg("f", 0.070, "s", 0.45),
        ],
        f0=[(0.0, base * 0.75), (1.0, base * 1.45)],   # rises - it's filling up
        breath=g.uniform(0.15, 0.30), jitter=0.020, shimmer=0.08,
        effort=0.7, burst_db=5.0,
    )
    return utter(spec, f"harvest:{variant}")


def autocannon(variant: int = 0) -> np.ndarray:
    """Crisp single "pew". A 20-30mm's report: brighter and tighter than the
    cannon's "ka-POW", with none of the machine-gun's burr."""
    g = d.rng(f"ac:{variant}")
    base = 300.0 * (1.0 + g.uniform(-0.13, 0.13))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.009, "p", 0.9),
            Seg("v", 0.030, "iy", 1.0),
            Seg("v", 0.052, "iy>uw", 1.0),
        ],
        f0=[(0.0, base * 1.35), (0.30, base * 1.02), (1.0, base * 0.40)],
        breath=0.05, jitter=0.014, shimmer=0.05, effort=0.95, burst_db=13.5,
    )
    return utter(spec, f"ac:{variant}")


def rotary(variant: int = 0) -> np.ndarray:
    """Buzzy "brrrt". A rotary cannon's report is a rolling rasp, not a click."""
    g = d.rng(f"rot:{variant}")
    base = 150.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.010, "b", 0.8),
            Seg("v", 0.090, "er", 1.0),     # the rolled "rr"
            Seg("f", 0.060, "sh", 0.8),     # the escaping gas
            Seg("v", 0.040, "er", 0.6),
        ],
        f0=[(0.0, base * 1.20), (0.5, base * 1.05), (1.0, base * 0.7)],
        # High jitter makes the "rr" warble like a real rotary's beat.
        breath=0.10, jitter=0.030, shimmer=0.09,
        effort=1.05, burst_db=12.5,
    )
    return utter(spec, f"rot:{variant}")


def artillery(variant: int = 0) -> np.ndarray:
    """Deep, long "ka-BOOM". A howitzer is the cannon turned down an octave and
    stretched out."""
    g = d.rng(f"art:{variant}")
    stretch = 1.0 + g.uniform(-0.12, 0.12)
    base = 54.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.016, "k", 0.7),
            Seg("v", 0.070 * stretch, "aa", 0.4),
            Seg("_", 0.034),
            Seg("p", 0.018, "b", 1.0),
            Seg("v", 0.140 * stretch, "uw", 1.0),
            Seg("v", 0.320 * stretch, "uw>aa", 1.0),
            Seg("n", 0.300 * stretch, "m", 0.5),
        ],
        f0=[(0.0, base * 1.20), (0.15, base * 1.55), (0.40, base * 1.00),
            (0.75, base * 0.62), (1.0, base * 0.36)],
        breath=0.09, jitter=0.030, shimmer=g.uniform(0.09, 0.15),
        effort=g.uniform(1.2, 1.55), burst_db=g.uniform(11.0, 14.0),
    )
    return utter(spec, f"art:{variant}")


def mortar(variant: int = 0) -> np.ndarray:
    """Soft "thoop" launch, then a distant "oom". A lobbed round is air and a
    thump, not a bang."""
    g = d.rng(f"mort:{variant}")
    base = 120.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.060, "f", 0.7),
            Seg("v", 0.110, "uw", 0.7),
            Seg("v", 0.140, "uw>uh", 0.6),
            Seg("p", 0.014, "b", 0.9),
            Seg("v", 0.180, "aa", 0.7),
        ],
        f0=[(0.0, base * 0.9), (0.4, base * 1.2), (1.0, base * 0.6)],
        breath=0.18, jitter=0.016, shimmer=0.06, effort=0.7, burst_db=8.0,
    )
    return utter(spec, f"mort:{variant}")


def railgun(variant: int = 0) -> np.ndarray:
    """Electric "zzzt-CRACK". A coil/rail report is a sizzle then a slap."""
    g = d.rng(f"rail:{variant}")
    base = 95.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.090, "sh", 0.9),      # the charge sizzle
            Seg("v", 0.050, "ih", 0.6),
            Seg("p", 0.014, "k", 1.0),       # the projectile slam
            Seg("v", 0.120, "ae", 1.0),
            Seg("v", 0.200, "ae>uw", 0.9),
        ],
        f0=[(0.0, base * 1.3), (0.3, base * 1.0), (0.6, base * 0.8),
            (1.0, base * 0.45)],
        breath=0.12, jitter=0.02, shimmer=0.07, effort=1.1, burst_db=13.0,
    )
    return utter(spec, f"rail:{variant}")


def flamethrower(variant: int = 0) -> np.ndarray:
    """Harsh "fwoooosh-roar". A flame projector is all breath and snarl."""
    g = d.rng(f"flame:{variant}")
    base = 110.0 * (1.0 + g.uniform(-0.08, 0.08))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.070, "f", 0.8),
            Seg("v", 0.120, "uw", 0.6),
            Seg("f", 0.360, "sh", 1.0),     # the roar, swelling then dying
            Seg("v", 0.080, "er", 0.4),
        ],
        f0=[(0.0, base * 0.8), (0.35, base * 1.25), (1.0, base * 0.7)],
        breath=0.55, jitter=0.018, shimmer=0.10, effort=0.8, burst_db=5.0,
    )
    return utter(spec, f"flame:{variant}")


def beam(variant: int = 0) -> np.ndarray:
    """Sustained electric "zzziip". Energy lances/ion/PDL read as a sizzling
    whine with a bright tail."""
    g = d.rng(f"beam:{variant}")
    base = 360.0 * (1.0 + g.uniform(-0.12, 0.12))
    tail = 0.060 * g.uniform(0.8, 1.3)
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.030, "z", 0.7),       # the crackle at ignition
            Seg("v", 0.040, "iy", 1.0),
            Seg("v", 0.150, "iy>uw", 1.0),
            Seg("v", tail, "uw", 0.30),
        ],
        f0=[(0.0, base * 1.05), (0.12, base * 1.30), (1.0, base * 0.22)],
        breath=0.06, jitter=0.01, shimmer=0.04,
        effort=g.uniform(0.75, 1.0), burst_db=12.0,
    )
    return utter(spec, f"beam:{variant}")


def plasma(variant: int = 0) -> np.ndarray:
    """Gurgly "blorp-BOOM". A plasma bolt is a wet pop then a hollow boom."""
    g = d.rng(f"plasma:{variant}")
    stretch = 1.0 + g.uniform(-0.12, 0.12)
    base = 100.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.012, "b", 0.8),
            Seg("v", 0.060 * stretch, "uh", 0.8),
            Seg("v", 0.120 * stretch, "uw", 1.0),
            Seg("p", 0.014, "b", 0.9),
			Seg("v", 0.160 * stretch, "ao>aa", 0.9),
            Seg("n", 0.200 * stretch, "m", 0.5),
        ],
        f0=[(0.0, base * 1.2), (0.3, base * 1.4), (0.6, base * 1.0),
            (1.0, base * 0.5)],
        breath=0.12, jitter=0.025, shimmer=0.08, effort=1.0, burst_db=11.0,
    )
    return utter(spec, f"plasma:{variant}")


def grenade(variant: int = 0) -> np.ndarray:
    """Dry "pop-thunk". A grenade launcher's report is a cough, not a roar."""
    g = d.rng(f"nade:{variant}")
    base = 175.0 * (1.0 + g.uniform(-0.12, 0.12))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.011, "p", 1.0),
			Seg("v", 0.040, "aa", 0.9),
            Seg("p", 0.010, "k", 0.6),
            Seg("v", 0.050, "uh", 0.5),
        ],
        f0=[(0.0, base * 1.1), (1.0, base * 0.7)],
        breath=0.05, jitter=0.016, shimmer=0.05, effort=0.9, burst_db=13.0,
    )
    return utter(spec, f"nade:{variant}")


def gauss(variant: int = 0) -> np.ndarray:
    """Magnetic "thunk-zing". A coilgun's report is a low thud under a hum."""
    g = d.rng(f"gauss:{variant}")
    base = 130.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("p", 0.012, "d", 0.9),
            Seg("v", 0.060, "uw", 1.0),
            Seg("v", 0.080, "uw>ih", 0.7),
            Seg("f", 0.070, "z", 0.5),     # the coil whine
        ],
        f0=[(0.0, base * 1.1), (0.4, base * 1.3), (1.0, base * 0.6)],
        breath=0.08, jitter=0.02, shimmer=0.07, effort=1.0, burst_db=12.0,
    )
    return utter(spec, f"gauss:{variant}")


def smoke(variant: int = 0) -> np.ndarray:
    """Soft "pfut". A deployable going off is a puff, not a bang."""
    g = d.rng(f"smoke:{variant}")
    base = 140.0 * (1.0 + g.uniform(-0.12, 0.12))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.040, "f", 0.6),
            Seg("v", 0.070, "uh", 0.6),
            Seg("f", 0.050, "sh", 0.4),
        ],
        f0=[(0.0, base * 0.9), (1.0, base * 1.2)],
        breath=0.30, jitter=0.014, shimmer=0.05, effort=0.6, burst_db=6.0,
    )
    return utter(spec, f"smoke:{variant}")


def rocket(variant: int = 0) -> np.ndarray:
    """Sharp "fshh-EW". A rocket's launch is a bright streak, not a soft whoosh."""
    g = d.rng(f"rocket:{variant}")
    base = 200.0 * (1.0 + g.uniform(-0.10, 0.10))
    spec = VoiceSpec(
        segs=[
            Seg("f", 0.050, "f", 0.8),
            Seg("v", 0.090, "uw", 0.6),
            Seg("f", 0.200, "sh", 1.0),
            Seg("v", 0.090, "uw>ih", 0.7),
        ],
        f0=[(0.0, base * 0.9), (0.4, base * 1.25), (1.0, base * 0.8)],
        breath=0.45, jitter=0.016, shimmer=0.08, effort=0.8, burst_db=7.0,
    )
    return utter(spec, f"rocket:{variant}")


# sfx key -> generator. sfx.py iterates this to build the variant banks, so
# adding a weapon voice means adding one line here and nothing else.
ORDNANCE = {
    "cannon": cannon,
    "machine_gun": machine_gun,
    "laser": laser,
    "missile": missile,
    "explosion": explosion,
    "hit": hit,
    "harvest": harvest,
    "autocannon": autocannon,
    "rotary": rotary,
    "artillery": artillery,
    "mortar": mortar,
    "railgun": railgun,
    "flamethrower": flamethrower,
    "beam": beam,
    "plasma": plasma,
    "grenade": grenade,
    "gauss": gauss,
    "smoke": smoke,
    "rocket": rocket,
}


# --- Comms (SINCERE - this half does not get to be funny) --------------------

# Radio traffic is on the other side of the split. 6.2: "a calm, clipped,
# professional voice reporting an engagement, over which the actual weapons go
# 'pew pew', is the whole thesis in one moment."
#
# THESE ARE DELIBERATELY NOT INTELLIGIBLE WORDS. Getting synthetic formant
# speech to parse as English needs a pronunciation lexicon and coarticulation
# rules, and the payoff would be a stock phrase the player hears a thousand
# times. Speech-SHAPED prosody through a 300-3400 Hz radio band reads as "a
# calm professional said something" without ever inviting the player to
# transcribe it - the same trick distant PA announcements use. The prosody is
# where the acting is, so that is what these vary.

def _radio_band(x: np.ndarray, seed: str) -> np.ndarray:
    """300-3400 Hz carbon-mic band, companding, and a little carrier grit."""
    g = d.rng(seed + ":band")
    out = d.filt(x, "hp", 300.0, 0.9, poles=4)
    out = d.filt(out, "lp", 3400.0, 0.9, poles=4)
    # Heavy compression: radio comms are levelled hard, and that flatness is a
    # big part of what identifies the channel.
    out = d.compress(out, threshold_db=-24.0, ratio=8.0, attack=0.002, release=0.08)
    out = d.drive(out, 1.8)
    hiss = d.filt(g.uniform(-1.0, 1.0, len(out)), "bp", 1800.0, 0.6) * 0.035
    return out + hiss * (0.4 + 0.6 * np.abs(out) / (np.max(np.abs(out)) + 1e-9))


def _squelch(open_: bool, seed: str) -> np.ndarray:
    """The click-and-hiss of a carrier keying up or dropping."""
    g = d.rng(seed)
    dur = 0.035
    n = d.n_samples(dur)
    noise = d.filt(g.uniform(-1.0, 1.0, n), "bp", 2600.0, 0.8)
    env = d.decay_env(dur, 90.0, 0.0006) if open_ else d.decay_env(dur, 150.0, 0.0004)
    if not open_:
        env = env[::-1] * 0.7
    return noise * env * 0.55


def comms(phrase: str, variant: int = 0, tone: str = "calm") -> np.ndarray:
    """A short radio transmission: squelch, speech-shaped murmur, squelch.

    `phrase` selects the syllable pattern and prosody. `tone` shifts delivery
    without ever making it dramatic - even the alert reads are clipped, because
    a panicking radio operator would put the sincere channel on the wrong side
    of the split.

    STILL NOT WORDS, AND DELIBERATELY SO (confirmed with Chris 2026-08): these
    are speech-shaped murmurs, not transcribed callouts. But "not words" is not
    the same as "shapeless". What makes a murmur read as A PERSON TALKING rather
    than as vowel soup is everything around the vowels, so this pass upgrades
    exactly those: each phrase has its own melodic contour (the informative
    channel - you learn what kind of report it is before parsing anything),
    syllables are separated by a mixed consonant inventory instead of four
    plosives in rotation, the last syllable is lengthened the way every real
    utterance's final syllable is, an intake of breath precedes the speech, and
    the whole transmission drifts on the carrier the way a real receiver does.
    """
    g = d.rng(f"comms:{phrase}:{variant}")

    patterns = {
        "ack": ["ao", "er"],                       # two beats, falling: "roger"
        "affirm": ["ae", "er", "ax", "ih"],        # four beats
        "negative": ["eh", "ax", "ih"],
        "engaging": ["ih", "eh", "ax", "ih"],
        "structure_lost": ["ax", "eh", "ao"],
        "low_power": ["ao", "ax", "er"],
        "ready": ["eh", "ih"],
        "unit_lost": ["uh", "ih", "ao"],
    }
    # Each phrase's own melody, as (fraction, f0 multiplier) pairs. Two beats
    # falling reads as an acknowledgement; a stepped rise reads as a report
    # being begun; a hard early drop with a low tail reads as bad news. This is
    # the part a player parses without ever transcribing a syllable.
    contours = {
        "ack": [(0.0, 1.05), (0.50, 1.00), (1.0, 0.80)],
        "affirm": [(0.0, 0.98), (0.35, 1.10), (0.75, 1.02), (1.0, 0.86)],
        "negative": [(0.0, 1.12), (0.30, 0.94), (1.0, 0.82)],
        "engaging": [(0.0, 0.96), (0.40, 1.06), (0.70, 1.12), (1.0, 0.88)],
        "structure_lost": [(0.0, 1.18), (0.35, 1.06), (0.70, 0.92), (1.0, 0.76)],
        "low_power": [(0.0, 1.02), (0.50, 0.92), (1.0, 0.85)],
        "ready": [(0.0, 0.96), (0.40, 1.12), (1.0, 0.94)],
        "unit_lost": [(0.0, 1.06), (0.40, 0.98), (1.0, 0.72)],
    }
    vowels = patterns.get(phrase, ["ax", "ax"])
    contour = contours.get(phrase, [(0.0, 1.05), (0.5, 1.0), (1.0, 0.86)])

    # Professional radio prosody: flat, slightly falling, no terminal rise. The
    # alert tones sit a little higher and tighter, not louder.
    base = {"calm": 112.0, "alert": 132.0, "grim": 96.0}.get(tone, 112.0)
    base *= 1.0 + g.uniform(-0.04, 0.04)
    pace = {"calm": 1.0, "alert": 0.82, "grim": 1.12}.get(tone, 1.0)
    # Per-variant tempo and contour tilt: the same phrase from the same unit
    # should not play identically every time. Tilt pivots on the middle of the
    # phrase so the terminal direction is preserved.
    pace *= g.uniform(0.90, 1.12)
    tilt = g.uniform(-0.05, 0.05)

    def _tilted(f: float, m: float) -> float:
        return m * (1.0 + tilt * (2.0 * f - 1.0))

    segs = []
    n_syl = len(vowels)
    for i, v in enumerate(vowels):
        if i:
            # A consonant between syllables so it reads as speech, not a chant.
            # Real inter-syllabic consonants are mostly nasals and fricatives;
            # the first pass drew from plosives only, which gave every phrase
            # the same staccato attack.
            medial = g.choice(["t", "d", "k", "g", "m", "n", "s", "m", "n"])
            if medial in ("m", "n"):
                segs.append(Seg("n", 0.026 * pace, "", 0.5))
            elif medial == "s":
                segs.append(Seg("f", 0.034 * pace, "s", 0.35))
            else:
                segs.append(Seg("p", 0.012 * pace, medial, 0.5))
        dur = g.uniform(0.075, 0.105) * pace
        if i == 0:
            dur *= 0.85          # clipped first beat: radio shorthand
        if i == n_syl - 1:
            dur *= 1.30          # phrase-final lengthening - universal in speech
        segs.append(Seg("v", dur, v,
                        1.0 if i == 0 else g.uniform(0.72, 0.95)))
    segs.append(Seg("f", 0.045, "s", 0.30))

    spec = VoiceSpec(
        segs=segs,
        f0=[(f, base * _tilted(f, m)) for f, m in contour],
        breath=0.05, jitter=0.011, shimmer=0.04, effort=0.75,
    )
    speech = utter(spec, f"comms:{phrase}:{variant}")

    # Carrier drift: a slow ramp of resampling delay, up to about a quarter
    # percent. Every real receiver's oscillator wanders; its absence is one of
    # the tells that a voice is synthetic.
    drift = g.uniform(-1.0, 1.0) * SR * 0.0013
    speech = d._fractional_delay(speech, np.linspace(0.0, drift, len(speech)))

    # Intake of breath as the carrier keys up, under the squelch tail.
    inhale = d.filt(g.uniform(-1.0, 1.0, d.n_samples(0.07)), "bp", 1400.0, 0.7)
    inhale *= d.breakpoints(0.07, [(0.0, 0.0), (0.6, 1.0), (1.0, 0.0)]) * 0.05

    speech = _radio_band(speech, f"comms:{phrase}")

    total = 0.035 + len(speech) / SR + 0.09
    out = d.silence(total)
    d.place(out, _squelch(True, f"sq:{phrase}:{variant}:o"), 0.0)
    d.place(out, inhale * 0.8, 0.010)
    d.place(out, speech * 0.9, 0.030)
    d.place(out, _squelch(False, f"sq:{phrase}:{variant}:c"), 0.035 + len(speech) / SR)
    return d.normalize(d.fade(out, 0.0006, 0.012), 0.9)
