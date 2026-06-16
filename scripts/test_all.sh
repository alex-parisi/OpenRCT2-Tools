#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X7_DIR="$ROOT/OpenRCT2-X7-Renderer"
CPP_BUILD_DIR="$X7_DIR/build/cpp-tests"

PROJECTS=(
    "OpenRCT2-X7-Renderer"
    "OpenRCT2-ObjectCommon"
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
    "OpenRCT2-TrackGenerator"
    "OpenRCT2-RideGenerator"
)

FAILED=()

# ── C++ tests (X7-Renderer only) ────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building & running C++ tests: OpenRCT2-X7-Renderer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if cmake \
    -S "$X7_DIR/x7_renderer" \
    -B "$CPP_BUILD_DIR" \
    -DBUILD_TESTING=ON \
    -DBUILD_PYTHON_MODULE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    && cmake --build "$CPP_BUILD_DIR" --parallel \
    && ctest --test-dir "$CPP_BUILD_DIR" --output-on-failure; then
    echo
else
    FAILED+=("OpenRCT2-X7-Renderer (C++)")
    echo
fi

# ── Python tests (all six projects) ─────────────────────────────────────────
for project in "${PROJECTS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running Python tests: $project"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ! uv run --package "$project" pytest "$ROOT/$project" --cov-report=term-missing; then
        FAILED+=("$project (Python)")
    fi
    echo
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "  All tests passed."
else
    echo "  FAILED:"
    for f in "${FAILED[@]}"; do
        echo "    - $f"
    done
    exit 1
fi
