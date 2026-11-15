"""Draws the one layer of 23's layered icon: the two joined drops (sized 2 to 3) as a flat shape.

Icon Composer / the system add the glass, the light and the shadow, and re-tint it for dark, clear and tinted modes.
Usage: python3 make_icon_layers.py <out.png>   (1024 x 1024, transparent; the canvas is the whole icon tile)
"""
import sys
import numpy as np
from PIL import Image

S, SS = 1024, 3
N = S * SS
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / SS
c1, r1 = (413.0, 601.0), 205.0          # 3
c2, r2 = (671.0, 380.0), 137.0          # 2
s1 = np.sqrt((x - c1[0]) ** 2 + (y - c1[1]) ** 2) - r1
s2 = np.sqrt((x - c2[0]) ** 2 + (y - c2[1]) ** 2) - r2
k = 92.0                                 # how generously the two join
h = np.clip(0.5 + 0.5 * (s2 - s1) / k, 0, 1)
sdf = s2 * (1 - h) + s1 * h - k * h * (1 - h)
alpha = np.clip(-sdf * SS + 0.5, 0, 1)
img = np.zeros((N, N, 4), dtype=np.float32)
img[..., :3] = np.array([0.16, 0.16, 0.185])
img[..., 3] = alpha
Image.fromarray((img * 255).astype(np.uint8), "RGBA").resize((S, S), Image.LANCZOS).save(sys.argv[1])
