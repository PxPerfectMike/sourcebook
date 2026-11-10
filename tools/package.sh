#!/usr/bin/env bash
# Packages a release: runs the tests (real Lua 5.1 and the smoke test), checks the CHANGELOG has
# an entry for the version, and zips Sourcebook/ and Sourcebook_Loot/ into dist/Sourcebook-<version>.zip.
#   tools/package.sh
set -euo pipefail

PY=${PY:-"/c/Program Files/Python313/python.exe"}
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

version=$(sed -n 's/^## Version: *\([^ \r]*\).*/\1/p' Sourcebook/Sourcebook.toc)
[ -n "$version" ] || { echo "no ## Version in Sourcebook.toc"; exit 1; }
grep -q "^## $version\b" CHANGELOG.md || { echo "CHANGELOG.md has no entry for $version"; exit 1; }
loot_version=$(sed -n 's/^## Version: *\([^ \r]*\).*/\1/p' Sourcebook_Loot/Sourcebook_Loot.toc)
[ "$version" = "$loot_version" ] || { echo "Sourcebook_Loot.toc is $loot_version, Sourcebook.toc is $version"; exit 1; }

"$PY" tests/run.py > /dev/null 2>&1 || { "$PY" tests/run.py 2>&1 | grep -a -E "^FAIL|passed,"; exit 1; }

"$PY" - "$REPO" "$version" <<'PYEOF'
import os, sys, zipfile
repo, version = sys.argv[1], sys.argv[2]
out = os.path.join(repo, "dist", f"Sourcebook-{version}.zip")
os.makedirs(os.path.dirname(out), exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
	for folder in ("Sourcebook", "Sourcebook_Loot"):
		for root, _, files in os.walk(os.path.join(repo, folder)):
			for f in sorted(files):
				full = os.path.join(root, f)
				z.write(full, os.path.relpath(full, repo).replace(os.sep, "/"))
print(f"wrote {out}: {os.path.getsize(out) / 1e3:.0f} KB")
PYEOF
