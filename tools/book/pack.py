"""Packs the rendered book into game textures and writes Sourcebook/BookArt.lua.

	python tools/book/pack.py

Reads tools/book/out/ (spread.png, cover.png, turn/*.png, layout.json and tex/ masks) and
writes Sourcebook/Media/*.png. Every texture is power-of-two. Turn frames are cropped to what is
visible, packed into 2048 atlases with a 2px gutter, and their color is bled into the transparent
pixels around them so bilinear filtering never pulls in black fringes.
"""

import glob
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import gaussian_filter, grey_dilation

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
REPO = os.path.dirname(os.path.dirname(HERE))
MEDIA = os.path.join(REPO, "Sourcebook", "Media")
ATLAS = 2048
PAD = 2


def bleed(img):
	"""Fill transparent pixels' RGB from the nearest opaque neighbors (alpha unchanged)."""
	a = np.asarray(img).astype(np.float32)
	rgb, alpha = a[..., :3], a[..., 3]
	mask = (alpha > 0).astype(np.float32)
	acc = rgb * mask[..., None]
	w = mask.copy()
	for _ in range(6):
		acc_b = np.stack([gaussian_filter(acc[..., c], 2) for c in range(3)], -1)
		w_b = gaussian_filter(w, 2)
		fill = (w == 0) & (w_b > 1e-4)
		acc[fill] = acc_b[fill] / w_b[fill][:, None] * 1.0
		w = np.where(fill, 1.0, w)
	rgb = np.where((alpha > 0)[..., None], rgb, acc)
	return Image.fromarray(np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8), "RGBA")


def pow2_canvas(img, w, h):
	canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	canvas.paste(img, (0, 0))
	return bleed(canvas)


def save(img, name):
	os.makedirs(MEDIA, exist_ok=True)
	img.save(os.path.join(MEDIA, name), optimize=True)
	return os.path.getsize(os.path.join(MEDIA, name))


def average(paths):
	"""Motion blur: the premultiplied average of a frame's sub-frame renders."""
	acc = None
	for p in paths:
		a = np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255
		pm = np.dstack([a[..., :3] * a[..., 3:4], a[..., 3:4]])
		acc = pm if acc is None else acc + pm
	acc /= len(paths)
	alpha = acc[..., 3:4]
	rgb = np.where(alpha > 1e-4, acc[..., :3] / np.maximum(alpha, 1e-4), 0)
	return Image.fromarray((np.dstack([rgb, alpha]) * 255 + 0.5).clip(0, 255).astype(np.uint8), "RGBA")


def clean_alpha(im, floor):
	"""Drop the faint haze (denoise noise, the last tail of a shadow) so crops stay tight."""
	a = np.asarray(im).copy()
	a[..., 3] = np.where(a[..., 3] < floor, 0, a[..., 3])
	return Image.fromarray(a, "RGBA")


def pack_frames(images, floor=10):
	"""Shelf-packs cropped frames. Returns (atlases, entries)."""
	crops = []
	for k, im in enumerate(images):
		im = clean_alpha(im, floor)
		W, H = im.size
		alpha = np.asarray(im)[..., 3]
		ys, xs = np.nonzero(alpha > 2)
		if len(xs) == 0:
			crops.append((k, None, W, H, (0, 0, 1, 1)))
			continue
		x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
		crops.append((k, im.crop((x0, y0, x1, y1)), W, H, (x0, y0, x1, y1)))
	order = sorted([c for c in crops if c[1] is not None], key=lambda c: -c[1].size[1])
	atlases, entries = [], {}
	cur = None
	x = y = shelf = 0
	for k, im, W, H, box in order:
		w, h = im.size
		if cur is None or x + w + PAD > ATLAS:
			x, y, shelf = 0, y + shelf + PAD if cur is not None else 0, 0
		if cur is None or y + h > ATLAS:
			cur = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
			atlases.append(cur)
			x = y = shelf = 0
		cur.paste(im, (x, y))
		entries[k] = {
			"atlas": len(atlases),
			"tc": (x / ATLAS, (x + w) / ATLAS, y / ATLAS, (y + h) / ATLAS),
			"rect": (box[0] / W, box[1] / H, box[2] / W, box[3] / H),
		}
		x += w + PAD
		shelf = max(shelf, h)
	for k, im, W, H, box in crops:
		if im is None:
			entries[k] = {"atlas": 0, "tc": (0, 0, 0, 0), "rect": (0, 0, 0, 0)}
	return [bleed(a) for a in atlases], [entries[k] for k in range(len(images))]


def fx_textures():
	sizes = {}
	# Soft round mote.
	n = 64
	yy, xx = np.mgrid[0:n, 0:n] - (n - 1) / 2
	r = np.sqrt(xx ** 2 + yy ** 2) / (n / 2)
	a = np.clip(1 - r, 0, 1) ** 2.2
	sizes["mote.png"] = save(Image.fromarray(np.dstack([np.full((n, n, 3), 255), a * 255]).astype(np.uint8), "RGBA"), "mote.png")
	# Four-point sparkle with a soft core.
	n = 128
	yy, xx = np.mgrid[0:n, 0:n] - (n - 1) / 2
	ax, ay = np.abs(xx) / (n / 2), np.abs(yy) / (n / 2)
	rays = np.clip(1 - ax, 0, 1) ** 6 * np.exp(-(ay * 30) ** 2) + np.clip(1 - ay, 0, 1) ** 6 * np.exp(-(ax * 30) ** 2)
	diag = (np.clip(1 - np.sqrt(ax ** 2 + ay ** 2) * 1.6, 0, 1) ** 4) * np.exp(-((ax - ay) * 22) ** 2) * 0.5
	core = np.exp(-(ax ** 2 + ay ** 2) * 60)
	a = np.clip(rays + diag + core, 0, 1)
	sizes["sparkle.png"] = save(Image.fromarray(np.dstack([np.full((n, n, 3), 255), a * 255]).astype(np.uint8), "RGBA"), "sparkle.png")
	# Warm radial glow (used ADD) and a dark vignette backdrop.
	n = 256
	yy, xx = np.mgrid[0:n, 0:n] - (n - 1) / 2
	r = np.sqrt(xx ** 2 + yy ** 2) / (n / 2)
	glow = np.clip(1 - r, 0, 1) ** 2.5
	sizes["glow.png"] = save(Image.fromarray(np.dstack([np.full((n, n, 3), 255), glow * 255]).astype(np.uint8), "RGBA"), "glow.png")
	vig = np.clip(r * 0.85, 0, 1) ** 1.6 * 0.55 + 0.38
	sizes["vignette.png"] = save(Image.fromarray(np.dstack([np.zeros((n, n, 3)), np.clip(vig, 0, 1) * 255]).astype(np.uint8), "RGBA"), "vignette.png")
	# Ink-wash highlight for hovered rows: a soft horizontal smear.
	w, h = 256, 64
	yy, xx = np.mgrid[0:h, 0:w]
	fx = np.clip(np.minimum(xx, w - 1 - xx) / 40, 0, 1)
	fy = np.exp(-((yy - h / 2) / (h / 3.2)) ** 2)
	noise = gaussian_filter(np.random.default_rng(4).standard_normal((h, w)), 3)
	a = np.clip(fx * fy * (0.8 + 0.6 * noise / noise.std() * 0.25), 0, 1)
	sizes["wash.png"] = save(Image.fromarray(np.dstack([np.full((h, w, 3), [120, 70, 25]), a * 255]).astype(np.uint8), "RGBA"), "wash.png")
	# A vertical light band for sweeps (alpha only, ADD).
	w, h = 256, 32
	xx = np.mgrid[0:h, 0:w][1]
	band = np.exp(-((xx - w / 2) / (w / 7)) ** 2)
	sizes["sweep.png"] = save(Image.fromarray(np.dstack([np.full((h, w, 3), 255), band * 255]).astype(np.uint8), "RGBA"), "sweep.png")
	# Ink rule (a hand-drawn line) for the search box and dividers.
	w, h = 512, 16
	img = Image.new("L", (w * 2, h * 2), 0)
	d = ImageDraw.Draw(img)
	pts = [(x, h + 2.2 * math.sin(x / 70.0) + 1.2 * math.sin(x / 23.0)) for x in range(0, w * 2, 4)]
	d.line(pts, fill=255, width=3)
	img = img.filter(ImageFilter.GaussianBlur(1)).resize((w, h), Image.LANCZOS)
	a = np.asarray(img).astype(np.float32)
	ends = np.clip(np.minimum(np.arange(w), w - 1 - np.arange(w)) / 30, 0, 1)
	a = a * ends[None, :]
	sizes["rule.png"] = save(Image.fromarray(np.dstack([np.full((h, w, 3), [60, 33, 14]), a]).astype(np.uint8), "RGBA"), "rule.png")
	return sizes


def cover_fx(cover_size):
	"""Glow for the cover's runes and a glint mask for its gold, aligned with cover.png.
	Both are soft overlays, so they ship at half the cover's size."""
	tex = os.path.join(OUT, "tex")
	w, h = cover_size[0] // 2, cover_size[1] // 2
	runes = Image.open(os.path.join(tex, "runes.png")).convert("L").resize((w, h), Image.LANCZOS)
	r = np.asarray(runes).astype(np.float32) / 255
	glow = np.clip(gaussian_filter(r, 3) * 2.6 + gaussian_filter(r, 1) * 1.2 + r, 0, 1)
	img = Image.fromarray(np.dstack([np.full((h, w, 3), [110, 225, 255]), glow * 255]).astype(np.uint8), "RGBA")
	save(pow2_canvas(img, 512, 1024), "cover_runes.png")
	tool = Image.open(os.path.join(tex, "tooling.png")).convert("L").resize((w, h), Image.LANCZOS)
	t = np.asarray(tool).astype(np.float32) / 255
	img = Image.fromarray(np.dstack([np.full((h, w, 3), [255, 236, 170]), np.clip(t * 1.2, 0, 1) * 255]).astype(np.uint8), "RGBA")
	save(pow2_canvas(img, 512, 1024), "cover_glint.png")


def lua_num(v):
	return f"{v:.6f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def main():
	layout = json.load(open(os.path.join(OUT, "layout.json")))
	spread = Image.open(os.path.join(OUT, "spread.png")).convert("RGBA")
	sw, sh = spread.size
	save(pow2_canvas(spread, 2048, 2048), "spread.png")
	cover = Image.open(os.path.join(OUT, "cover.png")).convert("RGBA")
	cw, ch = cover.size
	save(pow2_canvas(cover, 1024, 2048) if ch > 1024 else pow2_canvas(cover, 1024, 1024), "cover.png")
	cover_fx(cover.size)
	keys = sorted({os.path.basename(p).split("_")[0] for p in glob.glob(os.path.join(OUT, "turn", "*_*.png"))})
	keys = [k for k in keys if os.path.exists(os.path.join(OUT, "shadow", f"{k}.png"))]  # skip a frame mid-render
	frames = [average(sorted(glob.glob(os.path.join(OUT, "turn", f"{k}_*.png")))) for k in keys]
	atlases, entries = pack_frames(frames)
	for old in glob.glob(os.path.join(MEDIA, "turn*.png")) + glob.glob(os.path.join(MEDIA, "shadow*.png")):
		os.remove(old)
	for k, a in enumerate(atlases, 1):
		save(a, f"turn{k}.png")
	shadows = [Image.open(os.path.join(OUT, "shadow", f"{k}.png")).convert("RGBA") for k in keys]
	satlases, sentries = pack_frames(shadows, floor=6)
	for k, a in enumerate(satlases, 1):
		save(a, f"shadow{k}.png")
	fx_textures()

	lines = [
		"-- GENERATED by tools/book/pack.py from the Blender renders. Do not edit.",
		"-- Rects are fractions of their image (0,0 = top left). Turn frames are placed in a box",
		"-- OVERSCAN times the spread's size, centered on it.",
		"",
		"local _, ns = ...",
		"",
		"ns.BookArt = {",
		f"\tspread = {{ w = {sw}, h = {sh}, tw = 2048, th = 2048 }},",
		f"\tcover = {{ w = {cw}, h = {ch}, tw = 1024, th = {2048 if ch > 1024 else 1024} }},",
		f"\tglow = {{ w = {cw // 2}, h = {ch // 2}, tw = 512, th = 1024 }},",
		f"\toverscan = {lua_num(float(layout['overscan']))},",
	]
	for key in ("left", "right", "book"):
		r = layout[key]
		lines.append(f"\t{key} = {{ {lua_num(r['x0'])}, {lua_num(r['y0'])}, {lua_num(r['x1'])}, {lua_num(r['y1'])} }},")
	lines.append(f"\tatlases = {len(atlases)},")
	lines.append(f"\tshadowAtlases = {len(satlases)},")
	for key, ents in (("frames", entries), ("shadows", sentries)):
		lines.append(f"\t{key} = {{")
		for e in ents:
			tc = ", ".join(lua_num(v) for v in e["tc"])
			rc = ", ".join(lua_num(v) for v in e["rect"])
			lines.append(f"\t\t{{ {e['atlas']}, {tc}, {rc} }},")
		lines.append("\t},")
	lines += ["}", ""]
	with open(os.path.join(REPO, "Sourcebook", "BookArt.lua"), "w", encoding="utf-8", newline="\n") as f:
		f.write("\n".join(lines))
	total = sum(os.path.getsize(p) for p in glob.glob(os.path.join(MEDIA, "*.png")))
	print(f"spread {sw}x{sh}, cover {cw}x{ch}, {len(frames)} turn frames in {len(atlases)} atlases, "
		f"shadows in {len(satlases)}, media {total / 1e6:.1f} MB")


if __name__ == "__main__":
	main()
