import pathlib
out = pathlib.Path("prototype/assets/hud/icons")
out.mkdir(parents=True, exist_ok=True)
header = '<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">\n'
footer = '</svg>\n'
s = 'fill="none" stroke="#ffffff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"'
sf = 'fill="#ffffff" stroke="none"'

icons = {
    "smoke": f'  <path {s} d="M20 44 C14 44 10 39 10 33 C10 27 15 23 20 23 C22 17 28 13 35 13 C44 13 50 19 51 27 C57 28 60 32 60 37 C60 42 56 46 51 46 Z"/>\n  <path {s} d="M24 53 C26 51 28 51 30 53 C32 55 34 55 36 53"/>\n',
    "barrage": f'  <circle cx="32" cy="32" r="20" {s}/>\n  <circle cx="32" cy="32" r="10" {s}/>\n  <circle cx="32" cy="32" r="3" {sf}/>\n  <path {s} d="M32 4 L32 10 M32 54 L32 60 M4 32 L10 32 M54 32 L60 32"/>\n',
    "beacon": f'  <circle cx="32" cy="32" r="5" {sf}/>\n  <path {s} d="M32 48 L32 60 M22 60 L42 60"/>\n  <path {s} d="M20 20 A17 17 0 0 1 44 20"/>\n  <path {s} d="M13 13 A27 27 0 0 1 51 13"/>\n',
    "mine": f'  <circle cx="32" cy="34" r="16" {sf}/>\n  <path {s} d="M32 10 L32 18 M16 20 L22 25 M48 20 L42 25 M10 34 L18 34 M46 34 L54 34"/>\n  <circle cx="32" cy="34" r="6" fill="#0E1116" stroke="none"/>\n',
    "boost": f'  <path {sf} d="M32 6 L38 20 L54 24 L42 36 L45 52 L32 44 L19 52 L22 36 L10 24 L26 20 Z"/>\n  <path {s} d="M26 48 L22 58 M32 48 L32 60 M38 48 L42 58"/>\n'
}

for name, body in icons.items():
    p = out / f"{name}.svg"
    p.write_text(header + body + footer, encoding="utf-8")
    print(f"Wrote {p}")
