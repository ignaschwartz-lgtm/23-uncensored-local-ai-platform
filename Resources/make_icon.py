"""Draws 23's app icon: two drops of smoked glass joining, sized 2 to 3, on a neutral tile.

Usage: python3 make_icon.py <out.png>   (1024 x 1024; build.sh / iconutil turn it into AppIcon.icns)
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 2                      # supersampling
N = S * SS
out = sys.argv[1]


def blur(a, r):
    return np.asarray(Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r * SS)), dtype=np.float32) / 255


def over(dst, rgb, alpha):
    """Composite a flat colour with per-pixel alpha over an RGBA float image."""
    a = alpha[..., None]
    dst[..., :3] = dst[..., :3] * (1 - a) + np.array(rgb, dtype=np.float32) * a
    dst[..., 3:] = dst[..., 3:] + (1 - dst[..., 3:]) * a
    return dst


# --- Tile: the macOS icon grid (824 px rounded square centred in 1024) -----------------------
tile = Image.new("L", (N, N), 0)
ImageDraw.Draw(tile).rounded_rectangle([100 * SS, 100 * SS, (S - 100) * SS, (S - 100) * SS], radius=186 * SS, fill=255)
tile = np.asarray(tile, dtype=np.float32) / 255

img = np.zeros((N, N, 4), dtype=np.float32)
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / SS

over(img, (0, 0, 0), np.roll(blur(tile, 16), 10 * SS, axis=0) * 0.30)          # soft shadow under the tile
shade = np.clip((y - 100) / 824, 0, 1)[..., None]
face = np.array([247, 247, 248], dtype=np.float32) * (1 - shade) + np.array([224, 224, 229], dtype=np.float32) * shade
a = tile[..., None]
img[..., :3] = img[..., :3] * (1 - a) + face / 255 * a
img[..., 3:] = img[..., 3:] + (1 - img[..., 3:]) * a
top_edge = np.clip(tile - np.roll(tile, 2 * SS, axis=0), 0, 1)                   # a hairline of light along the top edge
over(img, (1, 1, 1), top_edge * 0.7)

# --- The drops: one implicit surface, so they join the way liquid does ------------------------
c1, r1 = (432.0, 584.0), 165.0          # 3
c2, r2 = (640.0, 406.0), 110.0          # 2
s1 = np.sqrt((x - c1[0]) ** 2 + (y - c1[1]) ** 2) - r1
s2 = np.sqrt((x - c2[0]) ** 2 + (y - c2[1]) ** 2) - r2
k = 74.0                                                   # how generously the two join
h = np.clip(0.5 + 0.5 * (s2 - s1) / k, 0, 1)
sdf = s2 * (1 - h) + s1 * h - k * h * (1 - h)              # smooth union: a true distance, so edges stay even
gy, gx = np.gradient(sdf)
g = np.sqrt(gx * gx + gy * gy) + 1e-6
nx, ny = gx / g, gy / g                                    # outward normal
nx, ny = blur((nx + 1) / 2, 5) * 2 - 1, blur((ny + 1) / 2, 5) * 2 - 1   # soften the normal so the join has no crease
dist = np.clip(-sdf, 0, None)                              # px inside the surface
inside = np.clip(-sdf + 0.5, 0, 1)
facing = nx * 0.55 + ny * 0.835                            # +1 on the lower right (away from the light), -1 towards it

# shadow the drops cast on the tile
sh = np.roll(np.roll(blur(inside, 22), 26 * SS, axis=0), 10 * SS, axis=1) * tile
over(img, (0, 0, 0), sh * 0.24)

# Every edge effect fades out well before the middle, so nothing crosses the centre line of the join.
near = lambda width: np.exp(-(dist / width) ** 2)
lit = np.clip(-facing, 0, 1)            # edge facing the light (upper left)
far = np.clip(facing, 0, 1)             # edge away from it (lower right)

# body: smoked glass you can see the tile through
over(img, (0.15, 0.15, 0.175), inside * 0.60)
# light gathers along the far edge, as it does in a real bead
over(img, (1, 1, 1), inside * far ** 1.2 * near(22) * (1 - near(2.5)) * 0.30)
# and the near edge is a little denser just inside the rim
over(img, (0, 0, 0), inside * lit * near(26) * (1 - near(5)) * 0.16)
# a broad, very soft sheen on the upper left of each drop
for (cx, cy), r in ((c1, r1), (c2, r2)):
    sheen = np.exp(-(((x - (cx - r * 0.30)) / (r * 0.62)) ** 2 + ((y - (cy - r * 0.34)) / (r * 0.50)) ** 2))
    over(img, (1, 1, 1), inside * sheen * 0.11)

# rim: a crisp line of light towards the light, a fainter one all the way round, a hair of definition outside
over(img, (1, 1, 1), inside * near(3.0) * (0.26 + 0.74 * lit ** 1.2))
over(img, (1, 1, 1), inside * near(9.0) * lit ** 2 * 0.30)
over(img, (0, 0, 0), np.clip(1 - np.abs(sdf + 0.6) / 1.4, 0, 1) * 0.22)

res = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA").resize((S, S), Image.LANCZOS)
res.save(out)
