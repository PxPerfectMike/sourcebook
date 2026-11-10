"""World position -> AreaTable ID, read from the terrain of the local game install.

Each terrain tile (ADT) is 16 x 16 chunks of 33.3 yards, and every chunk carries the area ID the
client uses for the zone name. The grid for a map is cached in tools/.cache/areas/<map>.bin
(1024 x 1024 little-endian uint32, row = from world X, column = from world Y).
"""

import array
import os
import struct
import sys

from casc import CascError, CascStore, iter_chunks

TILE = 533.33333
CHUNK = TILE / 16
SIZE = 64 * 16
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache", "areas")


def build_grid(store, wdt_fdid):
	wdt = dict(iter_chunks(store.read_fdid(wdt_fdid)))
	maid = wdt.get("MAID")
	grid = array.array("I", bytes(4 * SIZE * SIZE))
	if not maid:
		return grid
	for row in range(64):
		for col in range(64):
			root_fdid = struct.unpack("<I", maid[(row * 64 + col) * 32:(row * 64 + col) * 32 + 4])[0]
			if not root_fdid:
				continue
			try:
				root = store.read_fdid(root_fdid)
			except CascError as err:
				print(f"  tile {col},{row}: skipped ({err})", file=sys.stderr)
				continue
			for magic, payload in iter_chunks(root):
				if magic != "MCNK":
					continue
				ix, iy = struct.unpack("<II", payload[4:12])
				area = struct.unpack("<I", payload[52:56])[0]
				grid[(row * 16 + iy) * SIZE + col * 16 + ix] = area
	return grid


class Areas:
	def __init__(self, wow_root, wdt_by_map):
		self.wow_root = wow_root
		self.wdt_by_map = wdt_by_map
		self.grids = {}
		self.store = None

	def grid(self, map_id):
		if map_id in self.grids:
			return self.grids[map_id]
		path = os.path.join(CACHE, f"{map_id}.bin")
		grid = array.array("I")
		if os.path.exists(path):
			with open(path, "rb") as f:
				grid.frombytes(f.read())
		else:
			wdt = self.wdt_by_map.get(map_id)
			if not wdt:
				self.grids[map_id] = None
				return None
			if self.store is None:
				print("reading the game's terrain (first run only)...", file=sys.stderr)
				self.store = CascStore(self.wow_root, "wowf")
			grid = build_grid(self.store, wdt)
			os.makedirs(CACHE, exist_ok=True)
			with open(path, "wb") as f:
				f.write(grid.tobytes())
		self.grids[map_id] = grid
		return grid

	def area(self, map_id, x, y):
		grid = self.grid(map_id)
		if not grid:
			return 0
		r = int((32 * TILE - x) // CHUNK)
		c = int((32 * TILE - y) // CHUNK)
		if not (0 <= r < SIZE and 0 <= c < SIZE):
			return 0
		return grid[r * SIZE + c]
