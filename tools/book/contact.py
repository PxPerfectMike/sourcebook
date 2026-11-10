"""Contact sheet of turn frames over the static spread: contact.py <framesdir> <out.png> [cols]."""
import glob, json, os, sys
from PIL import Image
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
lay = json.load(open(os.path.join(OUT, "layout.json")))
os_ = lay["overscan"]
spread = Image.open(os.path.join(OUT, "spread.png")).convert("RGBA")
frames = sorted(glob.glob(os.path.join(sys.argv[1], "*.png")))
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 3
w, h = Image.open(frames[0]).size
sw, sh = round(w / os_), round(h / os_)
base = Image.new("RGBA", (w, h), (34, 27, 21, 255))
base.alpha_composite(spread.resize((sw, sh), Image.LANCZOS), ((w - sw) // 2, (h - sh) // 2))
crop = ((w - sw) // 2 - sw // 8, (h - sh) // 2 - sh // 3, (w + sw) // 2 + sw // 8, (h + sh) // 2 + sh // 8)
cw, ch = crop[2] - crop[0], crop[3] - crop[1]
rows = (len(frames) + cols - 1) // cols
sheet = Image.new("RGB", (cw * cols, ch * rows))
for k, f in enumerate(frames):
	im = Image.alpha_composite(base, Image.open(f).convert("RGBA")).crop(crop)
	sheet.paste(im.convert("RGB"), ((k % cols) * cw, (k // cols) * ch))
scale = min(1.0, 2400 / sheet.width)
sheet.resize((int(sheet.width * scale), int(sheet.height * scale)), Image.LANCZOS).save(sys.argv[2])
