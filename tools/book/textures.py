"""Procedural surface textures for the Sourcebook book (input to render_book.py, not shipped).

	python tools/book/textures.py

Writes to tools/book/out/tex/:
	parchment_L.png, parchment_R.png   page paper, gutter on the right / left edge respectively
	ink_R.png, ink_L.png               faux handwriting for the turning sheet (alpha = ink)
	border.png                          the printed page border (alpha = ink), same for both pages
	leather.png, leather_height.png     cover leather albedo and bump
	tooling.png                         gold tooling mask on the front cover (white = gold)
	runes.png                           glowing rune mask on the front cover (white = glow)
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import gaussian_filter, distance_transform_edt

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "tex")
PAGE_W, PAGE_H = 1024, 1434  # 1 : 1.4
COVER_W, COVER_H = 1100, 1500
FONT_TITLE = r"C:\Windows\Fonts\CENTAUR.TTF"
FONT_SCRIPT = r"C:\Windows\Fonts\GARAIT.TTF"


def fbm(h, w, seed, octaves=6, base=0.004, gain=0.55):
	"""Fractal noise in [0, 1]: blurred white noise summed over octaves."""
	rng = np.random.default_rng(seed)
	total = np.zeros((h, w))
	amp, norm = 1.0, 0.0
	for o in range(octaves):
		sigma = 1.0 / (base * (2 ** o)) / 6
		layer = gaussian_filter(rng.standard_normal((h, w)), sigma, mode="wrap")
		layer /= layer.std() + 1e-9
		total += amp * layer
		norm += amp
		amp *= gain
	total /= norm
	return np.clip(total * 0.22 + 0.5, 0, 1)


def save(name, arr, mode=None):
	os.makedirs(OUT, exist_ok=True)
	arr = np.clip(arr, 0, 1)
	img = Image.fromarray((arr * 255 + 0.5).astype(np.uint8), mode)
	img.save(os.path.join(OUT, name))
	return img


def parchment(gutter_left, seed):
	h, w = PAGE_H, PAGE_W
	yy, xx = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
	low = fbm(h, w, seed, octaves=4, base=0.003)
	mid = fbm(h, w, seed + 1, octaves=5, base=0.012)
	fine = fbm(h, w, seed + 2, octaves=3, base=0.12)
	light = np.array([0.955, 0.905, 0.79])
	dark = np.array([0.80, 0.66, 0.45])
	t = np.clip(0.18 + 0.55 * (low - 0.5) + 0.35 * (mid - 0.5), 0, 1)
	col = light * (1 - t[..., None]) + dark * t[..., None]
	col *= (0.97 + 0.06 * fine)[..., None]

	# Fibers: thin stretched streaks.
	rng = np.random.default_rng(seed + 3)
	fib = gaussian_filter(rng.standard_normal((h, w)), (0.6, 7))
	fib = np.clip(fib / fib.std(), -3, 3)
	col *= (1 - 0.018 * fib)[..., None]

	# Tide-mark stains: a few soft blobs with a darker rim.
	for k in range(3):
		cx, cy = rng.uniform(0.1, 0.9), rng.uniform(0.1, 0.9)
		r = rng.uniform(0.08, 0.2)
		wob = 1 + 0.9 * (fbm(h, w, seed + 10 + k, octaves=5, base=0.006) - 0.5)
		d = np.sqrt(((xx - cx) * 1.0) ** 2 + ((yy - cy) * 1.4) ** 2) / (r * wob)
		inside = np.clip(1 - d, 0, 1) ** 0.5
		rim = np.exp(-((d - 1) ** 2) / 0.02) * (0.4 + fbm(h, w, seed + 30 + k, octaves=4, base=0.02))
		amount = rng.uniform(0.015, 0.03)
		col *= (1 - amount * inside - amount * 0.9 * rim)[..., None]

	# Foxing: small brown spots.
	spots = np.zeros((h, w))
	for _ in range(160):
		x, y = rng.integers(0, w), rng.integers(0, h)
		spots[y, x] = rng.uniform(0.4, 1)
	spots = gaussian_filter(spots, 1.6) * 18
	col = col * (1 - np.clip(spots, 0, 0.35)[..., None]) + np.array([0.55, 0.36, 0.18]) * np.clip(spots, 0, 0.35)[..., None]

	# Edge burn: strong at the outer edges, soft at the gutter. Irregular.
	gx = xx if gutter_left else 1 - xx  # distance from the gutter edge
	outer_x = 1 - gx
	edge = np.minimum.reduce([outer_x * 1.0, yy * 1.4, (1 - yy) * 1.4])
	ragged = 0.012 * (fbm(h, w, seed + 20, octaves=4, base=0.02) - 0.5)
	burn = np.clip(1 - (edge + ragged) / 0.06, 0, 1) ** 1.8
	col *= (1 - 0.42 * burn)[..., None]
	col = col * (1 - 0.25 * burn[..., None]) + np.array([0.42, 0.25, 0.10]) * 0.25 * burn[..., None]
	# Gutter: paper curves away from the light, a gentle shade (the render adds real shading too).
	gut = np.clip(1 - gx / 0.10, 0, 1) ** 2
	col *= (1 - 0.18 * gut)[..., None]
	return col


def border_mask():
	"""Printed double-rule frame with corner flourishes, at 2x then downsampled."""
	s = 2
	w, h = PAGE_W * s, PAGE_H * s
	img = Image.new("L", (w, h), 0)
	d = ImageDraw.Draw(img)
	m1, m2 = int(0.055 * w), int(0.068 * w)
	d.rectangle([m1, m1, w - m1, h - m1], outline=255, width=5 * s)
	d.rectangle([m2, m2, w - m2, h - m2], outline=255, width=2 * s)
	# Corner flourishes: interlaced quarter circles and a diamond.
	for cx0, cy0, sx, sy in ((m1, m1, 1, 1), (w - m1, m1, -1, 1), (m1, h - m1, 1, -1), (w - m1, h - m1, -1, -1)):
		cx, cy = cx0 + sx * int(0.035 * w), cy0 + sy * int(0.035 * w)
		for r, wd in ((int(0.026 * w), 3 * s), (int(0.016 * w), 2 * s)):
			box = [cx - r, cy - r, cx + r, cy + r]
			d.arc(box, 0, 360, fill=255, width=wd)
		cx, cy = cx0, cy0
		dx, dy = int(0.07 * w) * sx, int(0.07 * w) * sy
		pts = [(cx + dx, cy), (cx + dx + 14 * s * sx, cy + 10 * s * sy), (cx + dx, cy + 20 * s * sy), (cx + dx - 14 * s * sx, cy + 10 * s * sy)]
		d.polygon(pts, outline=255, width=2 * s)
		pts = [(cx, cy + dy), (cx + 10 * s * sx, cy + dy + 14 * s * sy), (cx + 20 * s * sx, cy + dy), (cx + 10 * s * sx, cy + dy - 14 * s * sy)]
		d.polygon(pts, outline=255, width=2 * s)
	# Head ornament: a small vine with a center diamond under the top rule.
	cx, top = w // 2, m2 + 26 * s
	d.line([cx - 160 * s, top, cx - 26 * s, top], fill=255, width=2 * s)
	d.line([cx + 26 * s, top, cx + 160 * s, top], fill=255, width=2 * s)
	d.polygon([(cx, top - 16 * s), (cx + 16 * s, top), (cx, top + 16 * s), (cx - 16 * s, top)], outline=255, width=3 * s)
	for side in (-1, 1):
		for k in range(3):
			x = cx + side * (52 + 38 * k) * s
			d.arc([x - 12 * s, top - 22 * s, x + 12 * s, top + 2 * s], 200 if side < 0 else -20, 340 if side < 0 else 160, fill=255, width=2 * s)
	img = img.filter(ImageFilter.GaussianBlur(0.8 * s)).resize((PAGE_W, PAGE_H), Image.LANCZOS)
	a = np.asarray(img) / 255.0
	# Ink soaks unevenly.
	a *= 0.75 + 0.25 * fbm(PAGE_H, PAGE_W, 77, octaves=4, base=0.03)
	return a


WORDS = ("ore vein hollow ember fen thistle copper linen silk kobold murloc gnoll ravine moss "
	"tallow leather briar wolf boar spider quarry brook hearth lantern bramble tin silver iron "
	"herb root bloom dust ash cinder mire glade barrow crypt shore tide reed marsh cloth bolt "
	"thread dye flux bar ingot hide scale fang claw venom ichor elixir draught salve tonic").split()


def faux_text(seed, mirror_layout=False):
	"""Handwriting the eye takes for an entry: italic words in brown ink, a heading, paragraphs."""
	s = 2
	w, h = PAGE_W * s, PAGE_H * s
	img = Image.new("L", (w, h), 0)
	d = ImageDraw.Draw(img)
	rng = random.Random(seed)
	head = ImageFont.truetype(FONT_TITLE, 64 * s)
	body = ImageFont.truetype(FONT_SCRIPT, 34 * s)
	left, right = int(0.14 * w), int(0.86 * w)
	title = " ".join(rng.choice(WORDS).capitalize() for _ in range(2))
	tw = d.textlength(title, font=head)
	d.text(((w - tw) / 2, int(0.085 * h)), title, font=head, fill=235)
	y = int(0.16 * h)
	line_gap = 50 * s
	indent = True
	while y < h - int(0.11 * h):
		x = left + (48 * s if indent else 0)
		end = right - (rng.randint(80, 420) * s if rng.random() < 0.16 else 0)
		indent = False
		while True:
			word = rng.choice(WORDS)
			if rng.random() < 0.08:
				word = word.capitalize()
			ww = d.textlength(word, font=body)
			if x + ww > end:
				break
			d.text((x, y + rng.uniform(-1.5, 1.5) * s), word, font=body, fill=rng.randint(190, 245))
			x += ww + d.textlength(" ", font=body) * rng.uniform(0.9, 1.2)
		if end < right:
			y += 18 * s
			indent = True
		y += line_gap
	img = img.filter(ImageFilter.GaussianBlur(0.6 * s)).resize((PAGE_W, PAGE_H), Image.LANCZOS)
	a = np.asarray(img) / 255.0
	a *= 0.7 + 0.3 * fbm(PAGE_H, PAGE_W, seed + 5, octaves=4, base=0.03)
	return a


def Scribble(d, x0, y0, length, amp, rng, width):
	pts = []
	phase = rng.uniform(0, 6.28)
	freq = rng.uniform(0.055, 0.08) / (width / 3)
	for k in range(0, int(length), 2):
		x = x0 + k
		y = y0 + amp * 0.55 * math.sin(phase + k * freq * 3.1) + amp * 0.25 * math.sin(phase * 1.7 + k * freq * 7.3)
		pts.append((x, y))
	if len(pts) > 1:
		d.line(pts, fill=255, width=width, joint="curve")


def leather():
	h, w = COVER_H, COVER_W
	rng = np.random.default_rng(5)
	# Pebble grain: distance to random cell centers.
	pts = np.zeros((h, w), dtype=bool)
	idx = rng.integers(0, h * w, size=int(h * w / 110))
	pts.flat[idx] = True
	dist = distance_transform_edt(~pts)
	grain = np.clip(dist / 6.0, 0, 1)
	height = 1 - grain ** 0.7
	height = gaussian_filter(height, 0.8)
	creases = fbm(h, w, 8, octaves=5, base=0.008)
	height = 0.7 * height + 0.3 * creases
	base = np.array([0.30, 0.085, 0.055])
	hi = np.array([0.46, 0.17, 0.09])
	tone = fbm(h, w, 9, octaves=4, base=0.004)
	col = base * (1 - tone[..., None] * 0.6) + hi * (tone[..., None] * 0.6)
	col *= (0.85 + 0.3 * height)[..., None]
	# Wear at the edges and corners: lighter, browner.
	yy, xx = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
	edge = np.minimum.reduce([xx, 1 - xx, yy * 1.36, (1 - yy) * 1.36])
	wear = np.clip(1 - edge / 0.05, 0, 1) ** 1.5 * (0.6 + 0.8 * fbm(h, w, 10, octaves=4, base=0.02))
	col = col * (1 - 0.5 * wear[..., None]) + np.array([0.55, 0.32, 0.18]) * 0.5 * wear[..., None]
	return col, height


def tooling_and_runes():
	s = 2
	w, h = COVER_W * s, COVER_H * s
	tool = Image.new("L", (w, h), 0)
	run = Image.new("L", (w, h), 0)
	d = ImageDraw.Draw(tool)
	r = ImageDraw.Draw(run)
	# Triple-rule border with an inner dotted line.
	for m, wd in ((0.045, 7), (0.06, 3), (0.095, 3)):
		mm = int(m * w)
		d.rectangle([mm, mm, w - mm, h - mm], outline=255, width=wd * s)
	mm = int(0.0775 * w)
	for x in range(mm, w - mm, 22 * s):
		d.ellipse([x - 3 * s, mm - 3 * s, x + 3 * s, mm + 3 * s], fill=255)
		d.ellipse([x - 3 * s, h - mm - 3 * s, x + 3 * s, h - mm + 3 * s], fill=255)
	for y in range(mm, h - mm, 22 * s):
		d.ellipse([mm - 3 * s, y - 3 * s, mm + 3 * s, y + 3 * s], fill=255)
		d.ellipse([w - mm - 3 * s, y - 3 * s, w - mm + 3 * s, y + 3 * s], fill=255)
	# Central sigil: rings, a compass star, and runes on a ring that glow.
	cx, cy = w // 2, int(h * 0.53)
	R = int(0.30 * w)
	for rr, wd in ((R, 6), (R - 18 * s, 2), (int(R * 0.62), 4), (int(R * 0.56), 2)):
		d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=255, width=wd * s)
	for k in range(8):
		a = k * math.pi / 4
		long = R - 26 * s if k % 2 == 0 else int(R * 0.55)
		tip = (cx + long * math.sin(a), cy - long * math.cos(a))
		side1 = (cx + 26 * s * math.sin(a + math.pi / 2), cy - 26 * s * math.cos(a + math.pi / 2))
		side2 = (cx + 26 * s * math.sin(a - math.pi / 2), cy - 26 * s * math.cos(a - math.pi / 2))
		d.polygon([tip, side1, (cx, cy), side2], outline=255, width=3 * s)
	d.ellipse([cx - 22 * s, cy - 22 * s, cx + 22 * s, cy + 22 * s], fill=255)
	rng = random.Random(3)
	ring_r = (R + int(R * 0.62)) // 2 + 6 * s
	n = 16
	for k in range(n):
		a = (k + 0.5) * 2 * math.pi / n
		px, py = cx + ring_r * math.sin(a), cy - ring_r * math.cos(a)
		Rune(r, px, py, 22 * s, rng, 4 * s)
	# Title in an arc-less banner above, and a line below.
	font = ImageFont.truetype(FONT_TITLE, 118 * s)
	title = "SOURCEBOOK"
	tw = d.textlength(title, font=font)
	ty = int(h * 0.16)
	d.text((cx - tw / 2, ty), title, font=font, fill=255)
	d.line([cx - tw / 2, ty + 140 * s, cx + tw / 2, ty + 140 * s], fill=255, width=3 * s)
	sub = ImageFont.truetype(FONT_SCRIPT, 62 * s)
	st = "of Things & Where They Hide"
	sw = d.textlength(st, font=sub)
	d.text((cx - sw / 2, int(h * 0.865)), st, font=sub, fill=255)
	tool = tool.filter(ImageFilter.GaussianBlur(0.7 * s)).resize((COVER_W, COVER_H), Image.LANCZOS)
	run = run.filter(ImageFilter.GaussianBlur(0.7 * s)).resize((COVER_W, COVER_H), Image.LANCZOS)
	return np.asarray(tool) / 255.0, np.asarray(run) / 255.0


def Rune(d, x, y, size, rng, width):
	"""A random angular glyph: a stave plus two or three branches."""
	top, bot = (x, y - size), (x, y + size)
	d.line([top, bot], fill=255, width=width)
	for _ in range(rng.randint(2, 3)):
		t = rng.uniform(-0.8, 0.8)
		side = rng.choice((-1, 1))
		up = rng.choice((-1, 1))
		start = (x, y + t * size)
		end = (x + side * size * 0.7, y + t * size + up * size * 0.6)
		d.line([start, end], fill=255, width=width)


def main():
	ink = np.array([0.22, 0.12, 0.055])
	border = border_mask()[..., None]
	for side, seed, text_seed in (("R", 100, 11), ("L", 200, 12)):
		paper = parchment(gutter_left=(side == "R"), seed=seed)
		blank = paper * (1 - 0.85 * border) + ink * 0.85 * border
		save(f"page_{side}_blank.png", blank)
		words = faux_text(text_seed)[..., None]
		save(f"page_{side}_ink.png", blank * (1 - 0.82 * words) + ink * 0.82 * words)
	col, height = leather()
	save("leather.png", col)
	save("leather_height.png", height)
	tool, runes = tooling_and_runes()
	save("tooling.png", tool)
	save("runes.png", runes)
	print("textures written to", OUT)


if __name__ == "__main__":
	main()
