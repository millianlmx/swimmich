#!/usr/bin/env python3
"""Generates the Swimmich logo: a camera lens whose ring carries the five Immich colours.

Usage: python3 generate.py [output_dir]   (writes swimmich-{light,dark,tinted}.svg)
"""
import math, sys

C = 512
MODES = {
    # ring = Immich palette (red, yellow, green, blue, pink); glass = centre -> edge
    "light":  dict(ring=["#FA2921", "#FFB400", "#18C249", "#1E83F7", "#ED79B5"], bg=("#FFFFFF", "#E9EDF8"),
                   glass=("#05060C", "#141A3A", "#2B3577", "#10142E"), glint="#8FA0FF", shadow=0.30, rim=0.16),
    "dark":   dict(ring=["#FA2921", "#FFB400", "#18C249", "#1E83F7", "#ED79B5"], bg=("#1F2026", "#050506"),
                   glass=("#05060C", "#141A3A", "#2B3577", "#10142E"), glint="#8FA0FF", shadow=0.60, rim=0.30),
    "tinted": dict(ring=["#FFFFFF", "#E2E2E2", "#C4C4C4", "#A6A6A6", "#D2D2D2"], bg=("#1C1C1E", "#000000"),
                   glass=("#060606", "#1C1C1C", "#3A3A3A", "#151515"), glint="#FFFFFF", shadow=0.60, rim=0.30),
}

def pol(r, deg):
    return f"{C + r * math.cos(math.radians(deg)):.1f},{C + r * math.sin(math.radians(deg)):.1f}"

def build(mode, R=416, ring_r=372, ring_w=38, gap=11, glass_r=300):
    m = MODES[mode]
    g = m["glass"]
    defs = f'''
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{m["bg"][0]}"/><stop offset="1" stop-color="{m["bg"][1]}"/></linearGradient>
  <linearGradient id="barrel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4A4E5C"/><stop offset="0.5" stop-color="#22242C"/><stop offset="1" stop-color="#0B0C10"/></linearGradient>
  <linearGradient id="bevel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#000" stop-opacity="0.9"/><stop offset="1" stop-color="#6B7080" stop-opacity="0.9"/></linearGradient>
  <radialGradient id="glass"><stop offset="0" stop-color="{g[0]}"/><stop offset="0.55" stop-color="{g[1]}"/><stop offset="0.85" stop-color="{g[2]}"/><stop offset="1" stop-color="{g[3]}"/></radialGradient>
  <linearGradient id="sheen" x1="0.2" y1="0" x2="0.7" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.50"/><stop offset="0.45" stop-color="#fff" stop-opacity="0.06"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="ground" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#0B1030" flood-opacity="{m["shadow"]}"/></filter>
  <filter id="soft"><feGaussianBlur stdDeviation="3"/></filter>
  <clipPath id="front"><circle cx="{C}" cy="{C}" r="{glass_r}"/></clipPath>'''

    # Barrel
    s = f'  <circle cx="{C}" cy="{C}" r="{R}" fill="url(#barrel)" filter="url(#ground)"/>\n'
    s += f'  <circle cx="{C}" cy="{C}" r="{R - 3}" fill="none" stroke="#fff" stroke-opacity="{m["rim"]}" stroke-width="3"/>\n'
    # Colour ring, set in a recessed channel
    s += f'  <circle cx="{C}" cy="{C}" r="{ring_r}" fill="none" stroke="#000" stroke-opacity="0.35" stroke-width="{ring_w + 14}"/>\n'
    for i, c in enumerate(m["ring"]):
        a0, a1 = -90 + 72 * i + gap, -90 + 72 * (i + 1) - gap
        s += f'  <path d="M{pol(ring_r, a0)} A{ring_r},{ring_r} 0 0 1 {pol(ring_r, a1)}" fill="none" stroke="{c}" stroke-width="{ring_w}" stroke-linecap="round"/>\n'
    # Glass and inner elements
    s += f'  <circle cx="{C}" cy="{C}" r="{glass_r + 6}" fill="#07080B"/><circle cx="{C}" cy="{C}" r="{glass_r + 6}" fill="none" stroke="url(#bevel)" stroke-width="7"/>\n'
    s += f'  <circle cx="{C}" cy="{C}" r="{glass_r}" fill="url(#glass)"/>\n'
    for k in (0.80, 0.60, 0.40):
        s += f'  <circle cx="{C}" cy="{C}" r="{glass_r * k:.0f}" fill="none" stroke="#000" stroke-opacity="0.55" stroke-width="10"/><circle cx="{C}" cy="{C}" r="{glass_r * k - 7:.0f}" fill="none" stroke="{m["glint"]}" stroke-opacity="0.14" stroke-width="3"/>\n'
    s += f'  <circle cx="{C}" cy="{C}" r="{glass_r * 0.26:.0f}" fill="#020204"/>\n'
    # Reflections on the front element
    r = glass_r
    s += f'  <g clip-path="url(#front)"><path d="M{C - r},{C} A{r},{r} 0 0 1 {C + r},{C} A{r * 1.25:.0f},{r * 0.95:.0f} 0 0 0 {C - r},{C} Z" fill="url(#sheen)" transform="rotate(-28 {C} {C})"/></g>\n'
    ax, ay = C + r * 0.60 * math.cos(math.radians(-128)), C + r * 0.60 * math.sin(math.radians(-128))
    bx, by = C + r * 0.42 * math.cos(math.radians(52)), C + r * 0.42 * math.sin(math.radians(52))
    s += f'  <ellipse cx="{ax:.0f}" cy="{ay:.0f}" rx="{r * 0.12:.0f}" ry="{r * 0.07:.0f}" fill="#fff" opacity="0.75" filter="url(#soft)" transform="rotate(-38 {ax:.0f} {ay:.0f})"/>\n'
    s += f'  <circle cx="{bx:.0f}" cy="{by:.0f}" r="{r * 0.035:.0f}" fill="#fff" opacity="0.35" filter="url(#soft)"/>\n'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<title>Swimmich</title>
<defs>{defs}
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
{s}</svg>
'''

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    for mode in MODES:
        open(f"{out}/swimmich-{mode}.svg", "w").write(build(mode))
