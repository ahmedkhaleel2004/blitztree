"""Generate assets/AppIcon.icon, an Icon Composer document (macOS 26+).

A squarified treemap of rounded tiles inset on a dark plate. The margin keeps
the tiles clear of the system's rounded-square mask, and the tiles share one
glass group so they stay crisp at Dock size. `actool` compiles it to
Assets.car (Liquid Glass on macOS 26+) and a flat AppIcon.icns fallback for
older systems; see build.sh.
"""
import colorsys
import json
import pathlib

OUT = pathlib.Path(__file__).parent / "AppIcon.icon"
S = 1024
MARGIN = 124  # plate visible between the tiles and the icon edge
GAP = 28  # plate visible between tiles
RADIUS = 42


def hsb(h, s, b):
    return colorsys.hsv_to_rgb(h, s, b)


def mix(c, other, t):
    return tuple(a + (b - a) * t for a, b in zip(c, other))


def color(rgb):
    return "srgb:" + ",".join(f"{v:.5f}" for v in (*rgb, 1.0))


def gradient(top, bottom, start, stop):
    return {
        "linear-gradient": [color(top), color(bottom)],
        "orientation": {"start": start, "stop": stop},
    }


# name, unit rect (x, y, w, h; top-left origin), base colour
TILES = [
    ("orange", (0.00, 0.00, 0.58, 0.58), hsb(0.055, 0.78, 0.98)),
    ("purple", (0.58, 0.00, 0.42, 0.58), hsb(0.80, 0.55, 0.92)),
    ("blue", (0.00, 0.58, 0.36, 0.42), hsb(0.60, 0.62, 0.92)),
    ("green", (0.36, 0.58, 0.34, 0.42), hsb(0.34, 0.63, 0.85)),
    ("amber", (0.70, 0.58, 0.30, 0.21), hsb(0.125, 0.72, 0.95)),
    ("teal", (0.70, 0.79, 0.30, 0.21), hsb(0.47, 0.60, 0.84)),
]

assets = OUT / "Assets"
assets.mkdir(parents=True, exist_ok=True)
for old in assets.glob("*.svg"):
    old.unlink()

span = S - 2 * MARGIN + GAP  # tiles tile this box; each tile insets half a gap
origin = MARGIN - GAP / 2
layers = []
for name, (x, y, w, h), base in TILES:
    px, py = origin + x * span + GAP / 2, origin + y * span + GAP / 2
    pw, ph = w * span - GAP, h * span - GAP
    (assets / f"{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}">'
        f'<rect x="{px:.1f}" y="{py:.1f}" width="{pw:.1f}" height="{ph:.1f}" '
        f'rx="{RADIUS}" fill="#fff"/></svg>\n'
    )
    layers.append({
        "name": name,
        "image-name": f"{name}.svg",
        "glass": False,
        "fill": gradient(mix(base, (1, 1, 1), 0.25), mix(base, (0, 0, 0), 0.08),
                         {"x": 0.1, "y": 0.0}, {"x": 0.9, "y": 1.0}),
    })

icon = {
    "fill": gradient((0.16, 0.17, 0.20), (0.08, 0.08, 0.10),
                     {"x": 0.5, "y": 0.0}, {"x": 0.5, "y": 1.0}),
    "groups": [{
        "layers": layers,
        "lighting": "combined",
        "specular": True,
        "shadow": {"kind": "neutral", "opacity": 0.35},
        "translucency": {"enabled": False, "value": 0.3},
    }],
    "supported-platforms": {"squares": ["macOS"]},
}
(OUT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
