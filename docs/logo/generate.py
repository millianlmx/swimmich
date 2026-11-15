#!/usr/bin/env python3
"""Generates the Swimmich logo: five continuous-corner cards interlaced in a ring."""
import math, sys

PALETTES = {  # Immich palette: red, yellow, green, blue, pink
    "light":  ["#FA2921", "#FFB400", "#18C249", "#1E83F7", "#ED79B5"],
    "dark":   ["#FA2921", "#FFB400", "#18C249", "#1E83F7", "#ED79B5"],
    "tinted": ["#FFFFFF", "#DCDCDC", "#B4B4B4", "#8E8E8E", "#C8C8C8"],
}
BG = {"light": ("#FFFFFF", "#EEF1FA"), "dark": ("#1F2026", "#050506"), "tinted": ("#1C1C1E", "#000000")}
C = 512

def squircle(cx, cy, r, rot, n=5.0, steps=120):
    a, pts = math.radians(rot), []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = r * math.copysign(abs(c) ** (2 / n), c)
        y = r * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{cx + x * math.cos(a) - y * math.sin(a):.1f} {cy + x * math.sin(a) + y * math.cos(a):.1f}")
    return "M" + "L".join(pts) + "Z"

def build(mode, R=210, r=170, skew=18):
    cols, (top, bot) = PALETTES[mode], BG[mode]
    sheen = 0.0 if mode == "tinted" else 0.20
    defs = f'''
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bot}"/></linearGradient>
  <linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="0" y1="90" x2="0" y2="934"><stop offset="0" stop-color="#fff" stop-opacity="{sheen}"/><stop offset="0.55" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="{sheen / 2:.2f}"/></linearGradient>
  <filter id="ground" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="14" flood-color="#0B1030" flood-opacity="0.25"/></filter>
  <filter id="blur" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="12"/></filter>'''
    defs += '\n  <mask id="not4" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/><use href="#card4" fill="#000"/></mask>'
    for i in range(5):
        ang = -90 + 72 * i
        d = squircle(C + R * math.cos(math.radians(ang)), C + R * math.sin(math.radians(ang)), r, ang + 90 + skew)
        defs += f'\n  <path id="card{i}" d="{d}"/>\n  <clipPath id="clip{i}"><use href="#card{i}"/></clipPath>'

    def card(i):  # card i, carrying the shadow of the card lying on it (i+1)
        j = (i + 1) % 5
        return (f'<g clip-path="url(#clip{i})"><use href="#card{i}" fill="{cols[i]}"/><use href="#card{i}" fill="url(#sheen)"/>'
                f'<use href="#card{j}" fill="#000" opacity="0.38" filter="url(#blur)" transform="translate(0 6)"/></g>')

    body = '  <g filter="url(#ground)">' + "".join(f'<use href="#card{i}" fill="{cols[i]}"/>' for i in range(5)) + "</g>\n"
    for i in (4, 0, 1, 2):
        body += f"  {card(i)}\n"
    body += f'  <g mask="url(#not4)">{card(3)}</g>\n'  # close the ring: the fourth card slips under the last
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<title>Swimmich</title>
<defs>{defs}
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
{body}</svg>
'''

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    for mode in PALETTES:
        open(f"{out}/swimmich-{mode}.svg", "w").write(build(mode))
