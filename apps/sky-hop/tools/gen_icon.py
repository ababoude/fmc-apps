#!/usr/bin/env python3
"""Draws icon.svg from the sprite PNGs: the bird on a round patch of sky.
Usage: gen_icon.py <sprites dir> > icon.svg"""
import sys
sys.argv, d = sys.argv[:1], sys.argv[1]
exec(open(__file__.replace("gen_icon.py", "gen_sprites.py")).read().split("d = sys.argv[1]")[0])

def hexc(c):
    return "#%02X%02X%02X" % (((c >> 11) * 255 + 15) // 31, (((c >> 5) & 63) * 255 + 31) // 63, ((c & 31) * 255 + 15) // 31)

def draw(img, ox, oy, scale=1, rows=None, x0=0, x1=None):
    h = rows if rows is not None else len(img)
    out = []
    for x, y, w, hh, c in rects(img, x0, 0, x1, h):
        out.append(f'<rect x="{ox + x * scale}" y="{oy + y * scale}" width="{w * scale}" height="{hh * scale}" fill="{hexc(c)}"/>')
    return "\n    ".join(out)

_, _, sky_img = png(f"{d}/background-day.png")
sky = hexc(sky_img[0][0])
_, _, bird = png(f"{d}/yellowbird-midflap.png")

print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="96" height="96" shape-rendering="crispEdges">
  <defs><clipPath id="disc"><circle cx="48" cy="48" r="48"/></clipPath></defs>
  <g clip-path="url(#disc)">
    <rect width="96" height="96" fill="{sky}"/>
    {draw(bird, 14, 24, 2)}
  </g>
</svg>''')
