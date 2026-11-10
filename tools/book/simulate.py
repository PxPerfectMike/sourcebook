"""Offline preview of the book as the game draws it, for checking the art and the Lua math.

	python tools/book/simulate.py open  out.png     cover swing (Book.lua SetCover, ported)
	python tools/book/simulate.py turn  out.gif     a page turn with stand-in text (frames + shadows)

The cover math mirrors Book.lua's SetCover: 16 strips, each projected with the render camera.
"""

import json
import math
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MEDIA = os.path.join(REPO, "Sourcebook", "Media")
BG = (34, 27, 21, 255)
CAM_H, FRAME_W, HINGE_Z = 3.6391, 2.62, 0.097


def art():
	src = open(os.path.join(REPO, "Sourcebook", "BookArt.lua"), encoding="utf-8").read()
	def rect(key):
		m = re.search(r"\t" + key + r" = \{ ([^}]*) \}", src)
		return [float(v) for v in m.group(1).split(",")]
	def table(key):
		block = src[src.index("\t" + key + " = {"):]
		block = block[:block.index("\n\t},")]
		return [[float(v) for v in m.split(",")] for m in re.findall(r"\{ ([^}]*) \}", block)]
	spread = {k: int(v) for k, v in re.findall(r"spread = \{ w = (\d+), h = (\d+)", src) and zip(("w", "h"), re.findall(r"spread = \{ w = (\d+), h = (\d+)", src)[0])}
	cover = dict(zip(("w", "h"), map(int, re.findall(r"cover = \{ w = (\d+), h = (\d+)", src)[0])))
	return {
		"left": rect("left"), "right": rect("right"), "book": rect("book"),
		"spread": spread, "cover": cover,
		"overscan": float(re.search(r"overscan = ([\d.]+)", src).group(1)),
		"frames": table("frames"), "shadows": table("shadows"),
	}


def homography(src_pts, dst_pts):
	"""Coefficients for PIL's PERSPECTIVE transform: output (dst) pixel -> input (src) pixel."""
	A, b = [], []
	for (x, y), (u, v) in zip(dst_pts, src_pts):
		A.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
		A.append([0, 0, 0, x, y, 1, -v * x, -v * y])
		b += [u, v]
	return np.linalg.solve(np.array(A, float), np.array(b, float)).tolist()


def warp_onto(canvas, src, src_quad, dst_quad, shade=1.0):
	"""Draws the src_quad region of src onto canvas at dst_quad (both 4 points: UL, UR, LR, LL)."""
	xs = [p[0] for p in dst_quad]
	ys = [p[1] for p in dst_quad]
	x0, y0 = int(math.floor(min(xs))), int(math.floor(min(ys)))
	x1, y1 = int(math.ceil(max(xs))), int(math.ceil(max(ys)))
	if x1 - x0 < 1 or y1 - y0 < 1:
		return
	local = [(p[0] - x0, p[1] - y0) for p in dst_quad]
	coeffs = homography(src_quad, local)
	patch = src.transform((x1 - x0, y1 - y0), Image.PERSPECTIVE, coeffs, Image.BILINEAR)
	mask = Image.new("L", patch.size, 0)
	ImageDraw.Draw(mask).polygon(local, fill=255)
	a = np.asarray(patch).astype(np.float32)
	a[..., :3] *= shade
	a[..., 3] *= np.asarray(mask) / 255
	canvas.alpha_composite(Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA"), (x0, y0))


def simulate_open(out_path, W=1100):
	A = art()
	s, c = A["spread"], A["cover"]
	H = int(W * s["h"] / s["w"])
	spread_img = Image.open(os.path.join(MEDIA, "spread.png")).convert("RGBA").crop((0, 0, s["w"], s["h"]))
	cover_img = Image.open(os.path.join(MEDIA, "cover.png")).convert("RGBA").crop((0, 0, c["w"], c["h"]))
	spread_small = spread_img.resize((W, H), Image.LANCZOS)
	L, R, B = A["left"], A["right"], A["book"]
	px = W / FRAME_W
	gx = (L[2] + R[0]) / 2
	board_w = (B[2] - gx) * W / px
	cy = (R[1] + R[3]) / 2 * H / px
	y_top, y_bot = cy - B[1] * H / px, -(B[3] * H / px - cy)

	def project(xw, yw, zw):
		k = CAM_H / (CAM_H - zw) / (CAM_H / (CAM_H - HINGE_Z))
		return gx * W + xw * k * px, (R[1] + R[3]) / 2 * H - yw * k * px  # image coords (y down)

	gammas = [0, 0.5, 1.0, 1.4, 1.75, 2.2, 2.7, math.pi]
	tiles = []
	for g in gammas:
		canvas = Image.new("RGBA", (W, H), BG)
		half = spread_small.crop((int(gx * W), 0, W, H))
		if g < math.pi - 1e-6:
			canvas.alpha_composite(half, (int(gx * W), 0))
		else:
			canvas.alpha_composite(spread_small)
		front = g < math.pi / 2
		light = (1 - 0.28 * math.sin(g)) if front else (0.78 + 0.22 * -math.cos(g))
		n = 16
		for i in range(n):
			u0, u1 = i / n, (i + 1) / n
			def corner(u, yw):
				d = u * board_w
				return project(d * math.cos(g), yw, HINGE_Z + d * math.sin(g))
			p00, p01 = corner(u0, y_top), corner(u0, y_bot)
			p10, p11 = corner(u1, y_top), corner(u1, y_bot)
			if front:
				src = cover_img
				sq = [(u0 * c["w"], 0), (u1 * c["w"], 0), (u1 * c["w"], c["h"]), (u0 * c["w"], c["h"])]
				dq = [p00, p10, p11, p01]
			else:
				# Back: the left half of the spread; outer edge at the left.
				src = spread_img
				bx0 = B[0] * s["w"]
				gu = gx * s["w"]
				a, b = gu - (gu - bx0) * u1, gu - (gu - bx0) * u0
				sq = [(a, B[1] * s["h"]), (b, B[1] * s["h"]), (b, B[3] * s["h"]), (a, B[3] * s["h"])]
				dq = [p10, p00, p01, p11]
			warp_onto(canvas, src, sq, dq, light)
		tiles.append(canvas)
	cols = 4
	sheet = Image.new("RGB", (W * cols // 2, H * 2 // 2))
	for k, t in enumerate(tiles):
		t = t.resize((W // 2, H // 2), Image.LANCZOS)
		sheet.paste(t.convert("RGB"), ((k % cols) * (W // 2), (k // cols) * (H // 2)))
	sheet.save(out_path)


def simulate_turn(out_path, W=900):
	A = art()
	s = A["spread"]
	H = int(W * s["h"] / s["w"])
	spread_img = Image.open(os.path.join(MEDIA, "spread.png")).convert("RGBA").crop((0, 0, s["w"], s["h"])).resize((W, H), Image.LANCZOS)
	OW, OH = W * A["overscan"], H * A["overscan"]
	ox, oy = (W - OW) / 2, (H - OH) / 2
	atlases = {}

	def frame_img(entry, prefix):
		k = int(entry[0])
		if k == 0:
			return None, None
		key = prefix + str(k)
		if key not in atlases:
			atlases[key] = Image.open(os.path.join(MEDIA, f"{prefix}{k}.png")).convert("RGBA")
		at = atlases[key]
		tc = entry[1:5]
		crop = at.crop((int(tc[0] * at.width), int(tc[2] * at.height), int(tc[1] * at.width), int(tc[3] * at.height)))
		r = entry[5:9]
		x0, y0 = ox + r[0] * OW, oy + r[1] * OH
		w, h = (r[2] - r[0]) * OW, (r[3] - r[1]) * OH
		return crop.resize((max(1, int(round(w))), max(1, int(round(h)))), Image.BILINEAR), (int(round(x0)), int(round(y0)))

	font = ImageFont.truetype(r"C:\Windows\Fonts\GARA.TTF", 15)
	L, R = A["left"], A["right"]

	def text_layer(side, label):
		layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
		d = ImageDraw.Draw(layer)
		r = L if side == "left" else R
		x = r[0] * W + (r[2] - r[0]) * W * 0.12
		y = r[1] * H + (r[3] - r[1]) * H * 0.09
		d.text((x, y), label, font=ImageFont.truetype(r"C:\Windows\Fonts\GARABD.TTF", 22), fill=(52, 28, 12, 255))
		for i in range(18):
			d.text((x, y + 40 + i * 21), f"{label} entry {i + 1}", font=font, fill=(52, 28, 12, 255))
		return layer

	old_l, old_r = text_layer("left", "Index I"), text_layer("right", "Index II")
	new_l, new_r = text_layer("left", "Index III"), text_layer("right", "Index IV")
	n = len(A["frames"])
	out = []
	steps = 30
	for step in range(steps + 1):
		p = step / steps
		pos = p * (n - 1)
		i = int(pos)
		frac = pos - i
		canvas = Image.new("RGBA", (W, H), BG)
		canvas.alpha_composite(spread_img)
		# Old left text until the sheet lands; new right text once uncovered.
		if p < 1:
			canvas.alpha_composite(old_l)
		else:
			canvas.alpha_composite(new_l)
		if p > 0.14:
			canvas.alpha_composite(Image.blend(Image.new("RGBA", (W, H), (0, 0, 0, 0)), new_r, min(1, (p - 0.14) / 0.3)))
		for idx, weight, prefix in ((i, 1 - frac, "shadow"), (i + 1, frac, "shadow")):
			if idx < n and weight > 0.001:
				im, at = frame_img(A["shadows"][idx], prefix)
				if im:
					a = np.asarray(im).astype(np.float32)
					a[..., 3] *= weight
					canvas.alpha_composite(Image.fromarray(a.astype(np.uint8), "RGBA"), at)
		im, at = frame_img(A["frames"][i], "turn")
		if im:
			canvas.alpha_composite(im, at)
		if frac > 0.001 and i + 1 < n:
			im, at = frame_img(A["frames"][i + 1], "turn")
			if im:
				a = np.asarray(im).astype(np.float32)
				a[..., 3] *= frac
				canvas.alpha_composite(Image.fromarray(a.astype(np.uint8), "RGBA"), at)
		out.append(canvas.convert("RGB"))
	out[0].save(out_path, save_all=True, append_images=out[1:] + [out[-1]] * 10, duration=33, loop=0)
	# Also a contact sheet of every third step, for reading without a GIF viewer.
	pick = out[::3]
	cols = 4
	tw, th = W // 2, H // 2
	sheet = Image.new("RGB", (tw * cols, th * ((len(pick) + cols - 1) // cols)))
	for k, im in enumerate(pick):
		sheet.paste(im.resize((tw, th), Image.LANCZOS), ((k % cols) * tw, (k // cols) * th))
	sheet.save(os.path.splitext(out_path)[0] + "_sheet.png")


if __name__ == "__main__":
	mode, path = sys.argv[1], sys.argv[2]
	{"open": simulate_open, "turn": simulate_turn}[mode](path)
