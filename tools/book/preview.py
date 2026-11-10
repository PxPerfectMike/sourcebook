"""Composites rendered RGBA frames over a dark backdrop for viewing: preview.py in.png out.png [scale]."""
import sys
from PIL import Image
src = Image.open(sys.argv[1]).convert("RGBA")
bg = Image.new("RGBA", src.size, (34, 27, 21, 255))
out = Image.alpha_composite(bg, src).convert("RGB")
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
if scale != 1.0:
	out = out.resize((int(out.width * scale), int(out.height * scale)), Image.LANCZOS)
out.save(sys.argv[2])
