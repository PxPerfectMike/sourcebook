"""Runs Sourcebook's Lua tests in real Lua 5.1 (lupa).

Usage: PYLIBS=<folder with lupa> python tests/run.py [tests/test_x.lua ...]

Every addon .lua file is compiled with loadstring first, so a syntax error anywhere fails the run.
Each test file gets a fresh Lua state with the pure-logic addon files loaded into `ns`.
"""

import glob
import os
import sys

if os.environ.get("PYLIBS"):
	sys.path.insert(0, os.environ["PYLIBS"])
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".pylibs"))
from lupa import lua51  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(REPO, "Sourcebook")
# Files with no WoW calls at load time, in load order.
PURE = ["Data/Recipes.lua", "Codec.lua", "Craft.lua", "Sources.lua", "Learned.lua", "Format.lua", "Library.lua", "Nav.lua"]


def read(path):
	with open(path, "rb") as f:
		return f.read()


def compile_all():
	L = lua51.LuaRuntime(encoding=None)
	check = L.eval("function(src, name) local f, err = loadstring(src, name) return err end")
	bad = 0
	for path in sorted(glob.glob(os.path.join(ADDON, "**", "*.lua"), recursive=True)):
		err = check(read(path), ("@" + os.path.relpath(path, REPO)).encode())
		if err:
			print("FAIL compile:", err.decode("utf-8", "replace"))
			bad += 1
	return bad


def run_file(path):
	L = lua51.LuaRuntime(encoding=None)
	L.execute(read(os.path.join(REPO, "tests", "lib.lua")))
	L.execute(b"ns = {}")
	# The real generated loot data, as the Sourcebook_Loot addon would leave it (global SourcebookLoot).
	L.execute(read(os.path.join(REPO, "Sourcebook_Loot", "Loot.lua")))
	load = L.eval("function(src, name) local f = assert(loadstring(src, name)); f('Sourcebook', ns) end")
	for name in PURE:
		p = os.path.join(ADDON, name)
		if os.path.exists(p):
			load(read(p), ("@Sourcebook/" + name).encode())
	load_test = L.eval("function(src, name) local f = assert(loadstring(src, name)); f() end")
	load_test(read(path), ("@" + os.path.relpath(path, REPO)).encode())
	passed, failed = L.eval("RunTests()")
	return int(passed), int(failed)


def toc_files():
	with open(os.path.join(ADDON, "Sourcebook.toc"), encoding="utf-8") as f:
		return [line.strip() for line in f if line.strip().endswith(".lua")]


def run_smoke():
	"""Loads the whole addon against stubbed WoW API (tests/smoke.lua). Returns True on success."""
	if not os.path.exists(os.path.join(REPO, "tests", "smoke.lua")):
		return True
	L = lua51.LuaRuntime(encoding=None)
	files = toc_files()
	L.execute(read(os.path.join(REPO, "Sourcebook_Loot", "Loot.lua")))
	L.execute(b"ADDON_FILES, ADDON_SOURCE = {}, {}")
	add = L.eval("function(i, name, src) ADDON_FILES[i] = name; ADDON_SOURCE[name] = src end")
	for i, name in enumerate(files, 1):
		add(i, name.replace("\\", "/").encode(), read(os.path.join(ADDON, name.replace("\\", os.sep))))
	try:
		L.execute(read(os.path.join(REPO, "tests", "smoke.lua")))
	except Exception as e:  # lupa raises LuaError with the Lua message
		print("FAIL smoke:", e)
		return False
	print("PASS smoke")
	return True


def main():
	args = sys.argv[1:]
	files = args or sorted(glob.glob(os.path.join(REPO, "tests", "test_*.lua")))
	failed = compile_all()
	passed = 0
	for f in files:
		p, fl = run_file(f)
		passed += p
		failed += fl
	if not args:
		if run_smoke():
			passed += 1
		else:
			failed += 1
	print(f"{passed} passed, {failed} failed")
	sys.exit(1 if failed else 0)


if __name__ == "__main__":
	main()
