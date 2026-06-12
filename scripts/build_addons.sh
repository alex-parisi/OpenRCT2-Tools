#!/usr/bin/env bash
# Build the Blender add-ons into a top-level dist/ folder.
#
# Each add-on repo ships scripts/build_plugin_local.py, which runs the full
# pipeline: build the pure-Python front-end wheel, fetch the renderer +
# numpy/pillow/pyyaml from PyPI for the LOCAL Blender's CPython, stage a
# single-platform add-on, and run `blender --command extension build`. We point
# every repo's output at the shared dist/ here so the zips land side by side.
#
# Prerequisites:
#   uv sync --all-groups           (workspace venv must be up to date)
#   https://www.blender.org        (blender must be on PATH)
#
# Usage:
#   scripts/build_addons.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"

# Repos with a Blender extension built via scripts/build_plugin_local.py.
PLUGIN_PROJECTS=(
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
    "OpenRCT2-TrackGenerator"
    "OpenRCT2-RideGenerator"
)

if ! command -v blender &>/dev/null; then
    echo "error: 'blender' not found on PATH." >&2
    echo "       Install from https://www.blender.org/download/ and retry." >&2
    exit 1
fi

BLENDER_VER="$(blender --version 2>/dev/null | head -1 || true)"
# Detect Blender's bundled CPython (e.g. "3.13"); default to 3.13 (Blender 5.x).
# The dep wheels and front-end wheel must target the interpreter Blender ships.
BLENDER_PY="$(blender --background --python-expr \
    "import sys;print('PYTAG%d.%d' % sys.version_info[:2])" 2>/dev/null \
    | sed -n 's/^PYTAG//p' | head -1)"
BLENDER_PY="${BLENDER_PY:-3.13}"

mkdir -p "$DIST"
echo "$BLENDER_VER  (CPython $BLENDER_PY)"
echo "Output: $DIST"

for project in "${PLUGIN_PROJECTS[@]}"; do
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building  ·  $project"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    (
        cd "$ROOT/$project"
        UV_PYTHON="$BLENDER_PY" uv run --python "$BLENDER_PY" \
            python scripts/build_plugin_local.py --output-dir "$DIST"
    )
done

echo
echo "Done. Built add-ons in $DIST:"
find "$DIST" -name "*.zip" -maxdepth 1 | sed 's|.*/|  |'
