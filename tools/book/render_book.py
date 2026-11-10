"""Renders the Sourcebook book in Blender (Cycles). Run through Blender:

	blender -b -P tools/book/render_book.py -- <mode> [options]

Modes:
	spread               the open book, both pages blank (in-game text goes on top)
	closed               the closed book (front cover up), for the opening animation's first frame
	turn                 the turning sheet with its shadow, frames 0..N-1 (static book hidden)
	open                 the cover swinging open, whole-book frames 0..N-1
	keys                 five low-sample turn frames (0, 25, 50, 75, 100%) for a look test
Options:
	--samples N  --frames N  --scale F (resolution multiplier)  --only K (render one frame)

Units: one page is 1.0 wide and 1.4 tall; the spine runs along y at x = 0; the camera looks
straight down from above the spine, so flat pages project to exact rectangles. Every page
rectangle is written to out/layout.json in image-fraction coordinates for the addon.
"""

import json
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "out", "tex")
OUT = os.path.join(HERE, "out")

PW, PH = 1.0, 1.4          # page
COVER_T = 0.022            # board thickness
COVER_M = 0.06             # board margin beyond the pages
STACK = 0.075              # page block thickness at its outer edge
GUTTER = 0.055             # how far the page dips into the gutter
GUTTER_W = 0.12            # width of that dip
SHEET_T = 0.0018           # turning sheet thickness
CAM_H = 3.7
FOCAL = 50.0
RES_X, RES_Y = 2048, 1408
FRAME_W = 2.62             # scene width visible at z = 0
OVERSCAN = 1.5             # turn frames see this much more, so a rising page stays in frame


def args():
	argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
	opts = {"mode": argv[0] if argv else "spread", "samples": 128, "frames": 36, "scale": 1.0, "only": None, "subs": 3}
	i = 1
	while i < len(argv):
		key = argv[i].lstrip("-")
		opts[key] = type(opts[key])(argv[i + 1]) if opts.get(key) is not None else argv[i + 1]
		i += 2
	if opts["only"] is not None:
		opts["only"] = int(opts["only"])
	return opts


# ---------------------------------------------------------------- shapes

def surface_z(x_from_spine):
	"""Height of a page's top surface at a distance from the spine (pages dip into the gutter)."""
	return COVER_T + STACK - GUTTER * math.exp(-x_from_spine / GUTTER_W * 2.2)


def smooth(t):
	t = min(1.0, max(0.0, t))
	return t * t * (3 - 2 * t)


def ease_turn(t):
	"""Slow lift, fast middle, gentle landing."""
	t = min(1.0, max(0.0, t))
	return 0.5 - 0.5 * math.cos(math.pi * t ** 0.92)


def sheet_points(t, nu=72, nv=36):
	"""Turning sheet vertices at progress t (0 = lying on the right page, 1 = on the left)."""
	rows = []
	hinge_z = surface_z(0.0)
	for j in range(nv + 1):
		v = j / nv                              # 0 bottom edge .. 1 top edge
		y = -PH / 2 + v * PH
		delay = 0.16
		tv = min(1.0, max(0.0, (t - delay * v) / (1 - delay)))  # bottom corner leads
		theta = math.pi * ease_turn(tv)
		swing = math.sin(math.pi * tv)
		lead = math.cos(math.pi * tv)          # + early: free edge leads; - late: it trails
		row = []
		x, z = 0.0, hinge_z
		du = PW / nu
		for i in range(nu + 1):
			u = i / nu
			if i > 0:
				um = (i - 0.5) / nu
				bend = 0.95 * swing * lead * um ** 1.6 + 0.35 * swing * um * (1 - um) * 2.0
				phi = min(math.pi, max(0.0, theta + bend))
				x += du * math.cos(phi)
				z += du * math.sin(phi)
			# Blend into the exact resting surfaces at both ends so the first and last frames
			# match the static pages.
			rest_r = (u * PW, surface_z(u * PW) + SHEET_T)
			rest_l = (-u * PW, surface_z(u * PW) + SHEET_T)
			a = 1 - smooth(tv / 0.12)
			b = smooth((tv - 0.88) / 0.12)
			px = x * (1 - a - b) + rest_r[0] * a + rest_l[0] * b
			pz = z * (1 - a - b) + rest_r[1] * a + rest_l[1] * b
			pz = max(pz, surface_z(abs(px)) + SHEET_T * 0.5)
			row.append((px, y, pz))
		rows.append(row)
	return rows


# ---------------------------------------------------------------- scene helpers

def reset():
	bpy.ops.wm.read_factory_settings(use_empty=True)
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	prefs = bpy.context.preferences.addons["cycles"].preferences
	for kind in ("OPTIX", "CUDA"):
		try:
			prefs.compute_device_type = kind
			prefs.get_devices()
			if any(d.type == kind for d in prefs.devices):
				break
		except TypeError:
			continue
	for d in prefs.devices:
		d.use = d.type != "CPU"
	scene.cycles.device = "GPU"
	scene.cycles.use_denoising = True
	scene.render.film_transparent = True
	scene.view_settings.view_transform = "Standard"
	scene.view_settings.look = "None"
	scene.render.image_settings.file_format = "PNG"
	scene.render.image_settings.color_mode = "RGBA"
	scene.render.image_settings.color_depth = "8"
	scene.cycles.max_bounces = 6
	return scene


def image(name, non_color=False):
	img = bpy.data.images.load(os.path.join(TEX, name), check_existing=True)
	if non_color:
		img.colorspace_settings.name = "Non-Color"
	return img


def node_mat(name):
	mat = bpy.data.materials.new(name)
	try:
		mat.use_nodes = True
	except AttributeError:
		pass
	nt = mat.node_tree
	nt.nodes.clear()
	out = nt.nodes.new("ShaderNodeOutputMaterial")
	return mat, nt, out


def paper_material(name, front_img, back_img=None):
	mat, nt, out = node_mat(name)
	n = nt.nodes
	l = nt.links
	uv = n.new("ShaderNodeTexCoord")
	front = n.new("ShaderNodeTexImage")
	front.image = image(front_img)
	front.interpolation = "Cubic"
	l.new(uv.outputs["UV"], front.inputs["Vector"])
	color = front.outputs["Color"]
	if back_img:
		back = n.new("ShaderNodeTexImage")
		back.image = image(back_img)
		back.interpolation = "Cubic"
		flip = n.new("ShaderNodeMapping")
		flip.inputs["Location"].default_value = (1.0, 0.0, 0.0)
		flip.inputs["Scale"].default_value = (-1.0, 1.0, 1.0)
		l.new(uv.outputs["UV"], flip.inputs["Vector"])
		l.new(flip.outputs["Vector"], back.inputs["Vector"])
		geo = n.new("ShaderNodeNewGeometry")
		mix = n.new("ShaderNodeMix")
		mix.data_type = "RGBA"
		l.new(geo.outputs["Backfacing"], mix.inputs["Factor"])
		l.new(front.outputs["Color"], mix.inputs[6])
		l.new(back.outputs["Color"], mix.inputs[7])
		color = mix.outputs[2]
	bsdf = n.new("ShaderNodeBsdfPrincipled")
	l.new(color, bsdf.inputs["Base Color"])
	bsdf.inputs["Roughness"].default_value = 0.78
	# Paper lets a little light through: thin sheets glow at the edges when lifted.
	if "Subsurface Weight" in bsdf.inputs:
		bsdf.inputs["Subsurface Weight"].default_value = 0.08
		bsdf.inputs["Subsurface Radius"].default_value = (0.02, 0.015, 0.01)
	noise = n.new("ShaderNodeTexNoise")
	noise.inputs["Scale"].default_value = 260.0
	noise.inputs["Detail"].default_value = 6.0
	bump = n.new("ShaderNodeBump")
	bump.inputs["Strength"].default_value = 0.06
	bump.inputs["Distance"].default_value = 0.002
	l.new(noise.outputs["Fac"], bump.inputs["Height"])
	l.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
	# Light through the sheet: a warm translucent share, so a lifted page glows.
	trans = n.new("ShaderNodeBsdfTranslucent")
	tint = n.new("ShaderNodeMix")
	tint.data_type = "RGBA"
	tint.inputs["Factor"].default_value = 0.5
	l.new(color, tint.inputs[6])
	tint.inputs[7].default_value = (1.0, 0.8, 0.5, 1)
	l.new(tint.outputs[2], trans.inputs["Color"])
	mixs = n.new("ShaderNodeMixShader")
	mixs.inputs["Fac"].default_value = 0.22 if back_img else 0.0
	l.new(bsdf.outputs["BSDF"], mixs.inputs[1])
	l.new(trans.outputs["BSDF"], mixs.inputs[2])
	l.new(mixs.outputs["Shader"], out.inputs["Surface"])
	return mat


def gilt_edge_material():
	mat, nt, out = node_mat("GiltEdge")
	n, l = nt.nodes, nt.links
	bsdf = n.new("ShaderNodeBsdfPrincipled")
	wave = n.new("ShaderNodeTexWave")
	wave.wave_type = "BANDS"
	wave.bands_direction = "Z"
	wave.inputs["Scale"].default_value = 90.0
	wave.inputs["Distortion"].default_value = 2.0
	ramp = n.new("ShaderNodeValToRGB")
	ramp.color_ramp.elements[0].color = (0.55, 0.36, 0.12, 1)
	ramp.color_ramp.elements[1].color = (0.98, 0.78, 0.38, 1)
	l.new(wave.outputs["Fac"], ramp.inputs["Fac"])
	l.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
	bsdf.inputs["Metallic"].default_value = 0.85
	bsdf.inputs["Roughness"].default_value = 0.32
	l.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
	return mat


def leaf_material():
	mat, nt, out = node_mat("Leaf")
	n, l = nt.nodes, nt.links
	bsdf = n.new("ShaderNodeBsdfPrincipled")
	bsdf.inputs["Base Color"].default_value = (0.55, 0.42, 0.25, 1)
	bsdf.inputs["Roughness"].default_value = 0.8
	l.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
	return mat


def leather_material(name, with_tooling):
	mat, nt, out = node_mat(name)
	n, l = nt.nodes, nt.links
	uv = n.new("ShaderNodeTexCoord")
	alb = n.new("ShaderNodeTexImage")
	alb.image = image("leather.png")
	hgt = n.new("ShaderNodeTexImage")
	hgt.image = image("leather_height.png", non_color=True)
	for t in (alb, hgt):
		l.new(uv.outputs["UV"], t.inputs["Vector"])
	leather = n.new("ShaderNodeBsdfPrincipled")
	l.new(alb.outputs["Color"], leather.inputs["Base Color"])
	leather.inputs["Roughness"].default_value = 0.55
	if "Coat Weight" in leather.inputs:
		leather.inputs["Coat Weight"].default_value = 0.25
		leather.inputs["Coat Roughness"].default_value = 0.35
	bump = n.new("ShaderNodeBump")
	bump.inputs["Strength"].default_value = 0.35
	bump.inputs["Distance"].default_value = 0.004
	height_out = hgt.outputs["Color"]
	if with_tooling:
		tool = n.new("ShaderNodeTexImage")
		tool.image = image("tooling.png", non_color=True)
		runes = n.new("ShaderNodeTexImage")
		runes.image = image("runes.png", non_color=True)
		for t in (tool, runes):
			l.new(uv.outputs["UV"], t.inputs["Vector"])
		# Tooling is pressed in: subtract it from the height.
		sub = n.new("ShaderNodeMath")
		sub.operation = "SUBTRACT"
		l.new(hgt.outputs["Color"], sub.inputs[0])
		mul = n.new("ShaderNodeMath")
		mul.operation = "MULTIPLY"
		mul.inputs[1].default_value = 0.8
		l.new(tool.outputs["Color"], mul.inputs[0])
		l.new(mul.outputs[0], sub.inputs[1])
		height_out = sub.outputs[0]
		gold = n.new("ShaderNodeBsdfPrincipled")
		gold.inputs["Base Color"].default_value = (1.0, 0.74, 0.32, 1)
		gold.inputs["Metallic"].default_value = 1.0
		gold.inputs["Roughness"].default_value = 0.28
		glow = n.new("ShaderNodeEmission")
		glow.inputs["Color"].default_value = (0.35, 0.85, 1.0, 1)
		glow.inputs["Strength"].default_value = 6.0
		m1 = n.new("ShaderNodeMixShader")
		l.new(tool.outputs["Color"], m1.inputs["Fac"])
		l.new(leather.outputs["BSDF"], m1.inputs[1])
		l.new(gold.outputs["BSDF"], m1.inputs[2])
		m2 = n.new("ShaderNodeMixShader")
		l.new(runes.outputs["Color"], m2.inputs["Fac"])
		l.new(m1.outputs["Shader"], m2.inputs[1])
		l.new(glow.outputs["Emission"], m2.inputs[2])
		l.new(height_out, bump.inputs["Height"])
		l.new(bump.outputs["Normal"], leather.inputs["Normal"])
		l.new(bump.outputs["Normal"], gold.inputs["Normal"])
		l.new(m2.outputs["Shader"], out.inputs["Surface"])
	else:
		l.new(height_out, bump.inputs["Height"])
		l.new(bump.outputs["Normal"], leather.inputs["Normal"])
		l.new(leather.outputs["BSDF"], out.inputs["Surface"])
	return mat


def gold_material():
	mat, nt, out = node_mat("Gold")
	n, l = nt.nodes, nt.links
	bsdf = n.new("ShaderNodeBsdfPrincipled")
	bsdf.inputs["Base Color"].default_value = (0.80, 0.52, 0.18, 1)
	bsdf.inputs["Metallic"].default_value = 1.0
	bsdf.inputs["Roughness"].default_value = 0.55
	noise = n.new("ShaderNodeTexNoise")
	noise.inputs["Scale"].default_value = 40.0
	bump = n.new("ShaderNodeBump")
	bump.inputs["Strength"].default_value = 0.15
	l.new(noise.outputs["Fac"], bump.inputs["Height"])
	l.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
	l.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
	return mat


def ribbon_material(color):
	mat, nt, out = node_mat("Ribbon")
	n, l = nt.nodes, nt.links
	bsdf = n.new("ShaderNodeBsdfPrincipled")
	bsdf.inputs["Base Color"].default_value = color
	bsdf.inputs["Roughness"].default_value = 0.35
	if "Sheen Weight" in bsdf.inputs:
		bsdf.inputs["Sheen Weight"].default_value = 0.6
	if "Anisotropic" in bsdf.inputs:
		bsdf.inputs["Anisotropic"].default_value = 0.6
	l.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
	return mat


def make_object(name, verts, faces, uvs=None, mats=None, face_mats=None, smooth_shade=True):
	mesh = bpy.data.meshes.new(name)
	mesh.from_pydata(verts, [], faces)
	if uvs is not None:
		layer = mesh.uv_layers.new(name="UVMap")
		for poly in mesh.polygons:
			for li in poly.loop_indices:
				vi = mesh.loops[li].vertex_index
				layer.data[li].uv = uvs[vi]
	for m in mats or []:
		mesh.materials.append(m)
	if face_mats:
		for poly, mi in zip(mesh.polygons, face_mats):
			poly.material_index = mi
	if smooth_shade:
		for poly in mesh.polygons:
			poly.use_smooth = True
	mesh.update()
	obj = bpy.data.objects.new(name, mesh)
	bpy.context.scene.collection.objects.link(obj)
	return obj


def grid(rows, uv_fn):
	"""rows: list of rows of (x, y, z). Returns verts, faces, uvs."""
	verts, uvs = [], []
	nv, nu = len(rows), len(rows[0])
	for j, row in enumerate(rows):
		for i, p in enumerate(row):
			verts.append(p)
			uvs.append(uv_fn(i / (nu - 1), j / (nv - 1)))
	faces = []
	for j in range(nv - 1):
		for i in range(nu - 1):
			a = j * nu + i
			faces.append((a, a + 1, a + nu + 1, a + nu))
	return verts, faces, uvs


def page_block(side, mats):
	"""side: +1 right, -1 left. Top surface follows surface_z; the outer edge is rounded down
	to the board so the gilt page edges catch the light."""
	nu, nv = 60, 2
	rows = []
	edge_r = 0.022
	for j in range(nv + 1):
		y = -PH / 2 + j / nv * PH
		row = []
		for i in range(nu + 1):
			u = i / nu
			x = u * PW
			row.append((side * x, y, surface_z(x)))
		rows.append(row)
	verts, faces, uvs = grid(rows, lambda u, v: ((u if side > 0 else 1 - u), v))
	top_count = len(faces)
	# Walls: outer edge, head and tail, as a rounded quarter round + vertical.
	base = len(verts)
	ring = []
	for i in range(nu + 1):
		x = i / nu * PW
		ring.append((side * x, -PH / 2))
	ring += [(side * PW, -PH / 2 + k / 40 * PH) for k in range(1, 40)]
	for i in range(nu, -1, -1):
		x = i / nu * PW
		ring.append((side * x, PH / 2))
	# Each ring point gets a profile from the top surface down to the board.
	steps = 6
	prof = []
	for k in range(steps + 1):
		a = k / steps * math.pi / 2
		prof.append((edge_r * (1 - math.cos(a)), edge_r * math.sin(a)))  # inward offset, drop
	prof.append((edge_r, surface_z(PW) - COVER_T))
	wall_verts = []
	for (x, y) in ring:
		ztop = surface_z(abs(x))
		# Inward direction for the rounding: toward the page center.
		cx, cy = side * PW / 2, 0.0
		dx, dy = cx - x, cy - y
		dl = math.hypot(dx, dy) or 1
		dx, dy = dx / dl, dy / dl
		col = []
		for off, drop in prof:
			col.append((x - dx * (edge_r - off) * 0 , y - dy * 0, ztop - drop))
		wall_verts.append(col)
	nring = len(ring)
	for r in range(nring):
		for k in range(len(prof)):
			verts.append(wall_verts[r][k])
			uvs.append((0, 0))
	for r in range(nring - 1):
		for k in range(len(prof) - 1):
			a = base + r * len(prof) + k
			b = base + (r + 1) * len(prof) + k
			faces.append((a, b, b + 1, a + 1) if side > 0 else (a, a + 1, b + 1, b))
	face_mats = [0] * top_count + [1] * (len(faces) - top_count)
	obj = make_object("PagesR" if side > 0 else "PagesL", verts, faces, uvs, mats, face_mats)
	# Leaves under the top page, each a hair bigger, so the page edges show as fine lines.
	for k in range(1, 7):
		grow = k * 0.0016
		drop = k * 0.0075
		lv = []
		for (x, y) in ((0.4, -PH / 2 - grow), (PW + grow, -PH / 2 - grow), (PW + grow, PH / 2 + grow), (0.4, PH / 2 + grow)):
			lv.append((side * x, y, surface_z(PW) - drop))
		f = [(0, 1, 2, 3)] if side > 0 else [(3, 2, 1, 0)]
		make_object("Leaf", lv, f, None, [mats[2] if len(mats) > 2 else mats[1]], smooth_shade=False)
	return obj


def board(side, mat, z0=0.0):
	"""A cover board under one page block, with rounded edges (Bevel modifier)."""
	x0, x1 = (0.0, PW + COVER_M) if side > 0 else (-(PW + COVER_M), 0.0)
	y0, y1 = -PH / 2 - COVER_M, PH / 2 + COVER_M
	v = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
		(x0, y0, z0 + COVER_T), (x1, y0, z0 + COVER_T), (x1, y1, z0 + COVER_T), (x0, y1, z0 + COVER_T)]
	f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
	sx = 1.0 / (x1 - x0)
	sy = 1.0 / (y1 - y0)
	uvs = [((p[0] - x0) * sx, (p[1] - y0) * sy) for p in v]
	obj = make_object("Board" + ("R" if side > 0 else "L"), v, f, uvs, [mat], smooth_shade=False)
	bev = obj.modifiers.new("Bevel", "BEVEL")
	bev.width = 0.008
	bev.segments = 4
	return obj


def corner_guards(side, mat):
	objs = []
	s = 0.13
	x_out = side * (PW + COVER_M)
	for ysign in (-1, 1):
		y_out = ysign * (PH / 2 + COVER_M)
		z = COVER_T + 0.0006
		pts = [(x_out, y_out), (x_out - side * s, y_out), (x_out, y_out - ysign * s)]
		v = [(p[0], p[1], z) for p in pts] + [(p[0], p[1], z + 0.004) for p in pts]
		f = [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)]
		obj = make_object("Guard", v, f, None, [mat], smooth_shade=False)
		bev = obj.modifiers.new("Bevel", "BEVEL")
		bev.width = 0.0025
		bev.segments = 3
		objs.append(obj)
	return objs


def ribbon(x, mat, length, sway, width=0.045):
	"""A silk ribbon from the gutter's bottom edge lying out onto the table."""
	pts = []
	n = 30
	for k in range(n + 1):
		t = k / n
		y = -PH / 2 - t * length
		xx = x + sway * t
		z = max(surface_z(abs(xx)) * (1 - smooth(t * 4)), 0) + 0.002
		pts.append((xx, y, z))
	verts, faces, uvs = [], [], []
	for k, (px, py, pz) in enumerate(pts):
		verts += [(px - width / 2, py, pz), (px + width / 2, py, pz)]
		uvs += [(0, k / n), (1, k / n)]
	for k in range(n):
		a = 2 * k
		faces.append((a, a + 1, a + 3, a + 2))
	# Swallow-tail end.
	tail = pts[-1]
	verts.append((tail[0], tail[1] + 0.03, tail[2]))
	uvs.append((0.5, 1))
	return make_object("Ribbon", verts, faces, uvs, [mat])


def lights():
	key = bpy.data.lights.new("Key", "AREA")
	key.shape = "DISK"
	key.size = 2.4
	key.energy = 260
	key.color = (1.0, 0.86, 0.66)
	o = bpy.data.objects.new("Key", key)
	o.location = (-2.2, 1.9, 4.2)
	o.rotation_euler = Vector((0, 0, 0)).to_track_quat("Z", "Y").to_euler()
	bpy.context.scene.collection.objects.link(o)
	look_at(o, Vector((0.2, -0.2, 0)))
	fill = bpy.data.lights.new("Fill", "AREA")
	fill.size = 4
	fill.energy = 70
	fill.color = (0.75, 0.82, 1.0)
	o2 = bpy.data.objects.new("Fill", fill)
	o2.location = (2.8, -2.2, 3.0)
	bpy.context.scene.collection.objects.link(o2)
	look_at(o2, Vector((0, 0, 0)))
	world = bpy.data.worlds.new("World")
	bpy.context.scene.world = world
	try:
		world.use_nodes = True
	except AttributeError:
		pass
	bg = world.node_tree.nodes.get("Background") or world.node_tree.nodes.new("ShaderNodeBackground")
	bg.inputs["Color"].default_value = (0.12, 0.10, 0.08, 1)
	bg.inputs["Strength"].default_value = 0.25
	if not world.node_tree.nodes.get("World Output"):
		wo = world.node_tree.nodes.new("ShaderNodeOutputWorld")
		world.node_tree.links.new(bg.outputs["Background"], wo.inputs["Surface"])


def look_at(obj, target):
	direction = target - obj.location
	obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def camera(scale):
	scene = bpy.context.scene
	cam = bpy.data.cameras.new("Cam")
	cam.lens = FOCAL
	cam.sensor_fit = "HORIZONTAL"
	cam.sensor_width = 36.0
	o = bpy.data.objects.new("Cam", cam)
	scene.collection.objects.link(o)
	scene.camera = o
	# Height so that FRAME_W fits at z = 0.
	h = (FRAME_W / 2) / math.tan(math.atan(cam.sensor_width / 2 / cam.lens))
	o.location = (0, 0, h)
	o.rotation_euler = (0, 0, 0)
	scene.render.resolution_x = int(RES_X * scale)
	scene.render.resolution_y = int(RES_Y * scale)
	scene.render.resolution_percentage = 100
	return o


def ground():
	v = [(-4, -4, -0.0005), (4, -4, -0.0005), (4, 4, -0.0005), (-4, 4, -0.0005)]
	obj = make_object("Ground", v, [(0, 1, 2, 3)], None, [], smooth_shade=False)
	obj.is_shadow_catcher = True
	return obj


# ---------------------------------------------------------------- the book

class Book:
	def __init__(self):
		self.mats = {
			"pageR": paper_material("PageR", "page_R_blank.png"),
			"pageL": paper_material("PageL", "page_L_blank.png"),
			"sheet": paper_material("Sheet", "page_R_ink.png", "page_L_ink.png"),
			"gilt": gilt_edge_material(),
			"leather": leather_material("Leather", False),
			"cover": leather_material("Cover", True),
			"gold": gold_material(),
			"ribbonRed": ribbon_material((0.45, 0.03, 0.04, 1)),
			"ribbonGold": ribbon_material((0.85, 0.6, 0.18, 1)),
		}
		self.mats["leaf"] = leaf_material()
		self.right = [page_block(1, [self.mats["pageR"], self.mats["gilt"], self.mats["leaf"]]), board(1, self.mats["leather"])]
		self.right += corner_guards(1, self.mats["gold"])
		self.left = [page_block(-1, [self.mats["pageL"], self.mats["gilt"], self.mats["leaf"]]), board(-1, self.mats["leather"])]
		self.left += corner_guards(-1, self.mats["gold"])
		self.spine = self.make_spine()
		self.ribbons = [ribbon(0.012, self.mats["ribbonRed"], 0.16, 0.05), ribbon(-0.02, self.mats["ribbonGold"], 0.12, -0.04, 0.035)]
		self.front_cover = None

	def make_spine(self):
		n = 16
		r = 0.06
		verts, faces = [], []
		for j in (0, 1):
			y = -PH / 2 - COVER_M + j * (PH + 2 * COVER_M)
			for k in range(n + 1):
				a = math.pi * k / n
				verts.append((r * math.cos(a) * -1, y, -r * math.sin(a) * 0.5 + 0.004))
		for k in range(n):
			faces.append((k, k + 1, k + n + 2, k + n + 1))
		return make_object("Spine", verts, faces, [(0, 0)] * len(verts), [self.mats["leather"]])

	def all(self):
		return self.right + self.left + [self.spine] + self.ribbons


def page_rects(scene, cam):
	"""Flat-page rectangles in image fractions (0,0 = top left), for laying out in-game text."""
	out = {}
	for name, x0, x1 in (("left", -PW, 0.0), ("right", 0.0, PW)):
		corners = []
		for x, y in ((x0, PH / 2), (x1, -PH / 2)):
			z = surface_z(abs(x)) if abs(x) > GUTTER_W * 2 else surface_z(GUTTER_W * 2)
			co = world_to_camera_view(scene, cam, Vector((x, y, z)))
			corners.append((co.x, 1 - co.y))
		out[name] = {"x0": corners[0][0], "y0": corners[0][1], "x1": corners[1][0], "y1": corners[1][1]}
	book = []
	for x, y in ((-(PW + COVER_M), PH / 2 + COVER_M), (PW + COVER_M, -(PH / 2 + COVER_M))):
		co = world_to_camera_view(scene, cam, Vector((x, y, 0)))
		book.append((co.x, 1 - co.y))
	out["book"] = {"x0": book[0][0], "y0": book[0][1], "x1": book[1][0], "y1": book[1][1]}
	return out


def render(path):
	scene = bpy.context.scene
	scene.render.filepath = path
	bpy.ops.render.render(write_still=True)


def make_sheet(t, mat):
	rows = sheet_points(t)
	verts, faces, uvs = grid(rows, lambda u, v: (u, v))
	# One-sided on purpose: the material picks the page's back image by "Backfacing".
	return make_object("Sheet", verts, faces, uvs, [mat])


def main():
	o = args()
	scene = reset()
	scene.cycles.samples = int(o["samples"])
	lights()
	cam = camera(float(o["scale"]))
	book = Book()
	ground()
	mode = o["mode"]
	os.makedirs(OUT, exist_ok=True)
	# The camera's matrix only updates on a depsgraph pass; project after one.
	bpy.context.view_layer.update()
	with open(os.path.join(OUT, "layout.json"), "w") as f:
		json.dump({"res": [RES_X, RES_Y], "overscan": OVERSCAN, **page_rects(scene, cam)}, f, indent=1)

	if mode in ("turn", "keys"):
		cam.data.sensor_width *= OVERSCAN
		scene.render.resolution_x = int(RES_X * float(o["scale"]) * OVERSCAN)
		scene.render.resolution_y = int(RES_Y * float(o["scale"]) * OVERSCAN)
	if mode == "layout":
		return
	if mode == "spread":
		render(os.path.join(OUT, "spread.png"))
	elif mode == "keys":
		# Look test: sheet and shadow together, five poses.
		for obj in bpy.data.objects:
			if obj.type == "MESH" and obj.name != "Ground":
				obj.hide_render = True
		for obj in (book.right[0], book.left[0]):
			obj.hide_render = False
			obj.is_shadow_catcher = True
		for k, t in enumerate([0, 0.25, 0.5, 0.75, 1.0]):
			sheet = make_sheet(t, book.mats["sheet"])
			render(os.path.join(OUT, "keys", f"{k:03d}.png"))
			bpy.data.objects.remove(sheet, do_unlink=True)
	elif mode == "turn":
		# Two passes per frame, both on transparent film:
		#   turn/<k>_<s>.png   the sheet alone, at several moments around frame k (pack.py
		#                      averages them: motion blur, so neighboring frames blend cleanly)
		#   shadow/<k>.png     the sheet's shadow on the pages, a third of the resolution
		# The book itself is drawn underneath in game; its page tops still shade and bounce
		# light onto the sheet without being seen.
		for obj in bpy.data.objects:
			if obj.type == "MESH" and obj.name != "Ground":
				obj.hide_render = True
		pages = (book.right[0], book.left[0])
		ground_obj = bpy.data.objects["Ground"]
		n = int(o["frames"])
		subs = int(o.get("subs", 3))
		shutter = 0.35
		res_x, res_y = scene.render.resolution_x, scene.render.resolution_y
		for k in range(n):
			if o["only"] is not None and k != o["only"]:
				continue
			t = k / (n - 1)
			# Sheet pass.
			for obj in pages:
				obj.hide_render = False
				obj.is_shadow_catcher = False
				obj.visible_camera = False
			ground_obj.hide_render = True
			scene.render.resolution_x, scene.render.resolution_y = res_x, res_y
			for j in range(subs):
				dt = (j / (subs - 1) - 0.5) * shutter / (n - 1) if subs > 1 else 0
				ts = min(1.0, max(0.0, t + dt))
				sheet = make_sheet(ts, book.mats["sheet"])
				render(os.path.join(OUT, "turn", f"{k:03d}_{j}.png"))
				bpy.data.objects.remove(sheet, do_unlink=True)
			# Shadow pass: the sheet casts but isn't seen; the page tops catch.
			for obj in pages:
				obj.visible_camera = True
				obj.is_shadow_catcher = True
			ground_obj.hide_render = False
			sheet = make_sheet(t, book.mats["sheet"])
			sheet.visible_camera = False
			scene.render.resolution_x, scene.render.resolution_y = res_x // 3, res_y // 3
			render(os.path.join(OUT, "shadow", f"{k:03d}.png"))
			bpy.data.objects.remove(sheet, do_unlink=True)
	elif mode == "cover":
		# The front cover alone, flat, seen straight on (orthographic): the game swings it open
		# in perspective as a rigid quad, so it needs the board face with nothing around it.
		for obj in bpy.data.objects:
			if obj.type == "MESH":
				obj.hide_render = True
		bw, bh = PW + COVER_M, PH + 2 * COVER_M
		v = [(0, -bh / 2, 0.05), (bw, -bh / 2, 0.05), (bw, bh / 2, 0.05), (0, bh / 2, 0.05)]
		face = make_object("CoverFace", v, [(0, 1, 2, 3)], [(0, 0), (1, 0), (1, 1), (0, 1)], [book.mats["cover"]], smooth_shade=False)
		# The spine side of the cover rolls over the spine: a darker band shows the hinge.
		cam.data.type = "ORTHO"
		cam.data.ortho_scale = bh
		cam.data.sensor_fit = "VERTICAL"
		cam.location = (bw / 2, 0, 2.0)
		scene.render.resolution_x = int(1024 * float(o["scale"]))
		scene.render.resolution_y = int(round(1024 * bh / bw * float(o["scale"])))
		render(os.path.join(OUT, "cover.png"))
	else:
		raise SystemExit("unknown mode " + mode)


main()
