#!/usr/bin/env bash
# Simulate the full CI pipeline locally on macOS.
#
# Covers all jobs that are both meaningful on macOS and feasible without
# cloud infrastructure. Skipped jobs are listed in the summary.
#
# Jobs:
#   lint         ruff · mypy · yamllint · clang-format · clang-tidy
#   cpp-tests    cmake/ctest for OpenRCT2-X7-Renderer
#   pytest       100% coverage gate for OpenRCT2-X7-Renderer
#   ci-mirror    consumer mypy + pytest, py3.11, PyPI siblings (mirrors CI)
#   wheel-build  scikit-build-core wheel for OpenRCT2-X7-Renderer
#                (skipped when Embree is not installed via Homebrew)
#   plugin-build Blender extension zip for VehicleGenerator + SceneryGenerator
#                (skipped when `blender` is not on PATH)
#
# Prerequisites:
#   uv sync --all-groups           (workspace venv must be up to date)
#   brew install llvm              (clang-format, clang-tidy)
#   brew install embree            (wheel-build only)
#   https://www.blender.org        (plugin-build only)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X7_DIR="$ROOT/OpenRCT2-X7-Renderer"
CPP_BUILD_DIR="$X7_DIR/build/cpp-tests"

PYTHON_PROJECTS=(
    "OpenRCT2-X7-Renderer"
    "OpenRCT2-ObjectCommon"
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
    "OpenRCT2-TrackGenerator"
    "OpenRCT2-RideGenerator"
)

# Repos with a Blender extension built via scripts/build_plugin_local.py.
PLUGIN_PROJECTS=(
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
    "OpenRCT2-RideGenerator"
)

# Depend on sibling packages; run standalone vs PyPI (see "CI mirror").
CONSUMER_PROJECTS=(
    "OpenRCT2-ObjectCommon"
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
    "OpenRCT2-TrackGenerator"
    "OpenRCT2-RideGenerator"
)

FAILED=()
SKIPPED=()

# ── Helpers ───────────────────────────────────────────────────────────────────

section() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

run_or_fail() {
    local label="$1"; shift
    if ! "$@"; then
        FAILED+=("$label")
    fi
}

# Run a repo's CI standalone: fresh copy, Python 3.11, siblings from PyPI (not
# the workspace). Surfaces failures the editable workspace hides. mypy + pytest.
mirror_ci_python() {
    local project="$1"
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-mirror-${project}.XXXXXX")"
    # Source-only copy; no workspace pyproject -> uv pulls siblings from PyPI.
    rsync -a \
        --exclude '.git' --exclude '.venv' --exclude 'build' \
        --exclude '__pycache__' --exclude '*.egg-info' \
        --exclude '.mypy_cache' --exclude '.pytest_cache' \
        --exclude 'dist' --exclude '.ext-check' --exclude '.wheel-check' \
        --exclude 'wheels' \
        "$ROOT/$project/" "$tmp/"
    (
        cd "$tmp"
        uv python pin 3.11 >/dev/null 2>&1 || true
        if ! uv sync --group dev >sync.log 2>&1; then
            echo "  uv sync failed (could not resolve deps from PyPI):"
            sed 's/^/    /' sync.log
            exit 1
        fi
        local rc=0
        echo "── mypy ──"
        uv run --no-sync mypy || rc=1
        echo "── pytest ──"
        uv run --no-sync pytest --cov --cov-report=term-missing --cov-fail-under=100 || rc=1
        exit "$rc"
    )
    local rc=$?
    rm -rf "$tmp"
    return "$rc"
}

# ── Lint ─────────────────────────────────────────────────────────────────────
# Delegates to lint_all.sh which covers ruff, mypy, yamllint,
# clang-format, and clang-tidy across all four packages.

section "Lint  ·  all projects"
run_or_fail "lint" bash "$ROOT/scripts/lint_all.sh"

# ── C++ tests ─────────────────────────────────────────────────────────────────
# Mirrors the cpp-tests job in coverage.yml: configure (reusing any existing
# build), build, and run the Embree-backed renderer tests with CTest.

section "C++ tests  ·  OpenRCT2-X7-Renderer"
run_or_fail "OpenRCT2-X7-Renderer (cpp-tests)" bash -c "
    set -e
    cmake -S '$X7_DIR/x7_renderer' -B '$CPP_BUILD_DIR' \
        -DBUILD_TESTING=ON \
        -DBUILD_PYTHON_MODULE=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -Wno-dev
    cmake --build '$CPP_BUILD_DIR' --parallel
    ctest --test-dir '$CPP_BUILD_DIR' --output-on-failure
"

# ── Python tests (100% coverage required) ─────────────────────────────────────
# X7-Renderer only: base package, no sibling deps, so workspace == CI.
# Consumers run standalone in the CI mirror below.

section "pytest  ·  OpenRCT2-X7-Renderer"
run_or_fail "OpenRCT2-X7-Renderer (pytest)" bash -c "
    cd '$ROOT/OpenRCT2-X7-Renderer' &&
    uv run --no-sync pytest --cov-report=term-missing --cov-fail-under=100
"

# ── CI mirror: consumers (standalone, py3.11, PyPI siblings) ───────────────────
# Fails until the local-ahead siblings are released to PyPI.

for project in "${CONSUMER_PROJECTS[@]}"; do
    section "CI mirror  ·  $project  (py3.11 · PyPI siblings)"
    run_or_fail "$project (CI mirror: mypy + pytest)" mirror_ci_python "$project"
done

# ── Wheel build (X7-Renderer) ─────────────────────────────────────────────────
# Mirrors the macos-arm64 job in build-check.yml: compiles the pybind11/Embree
# extension via scikit-build-core and produces a distributable wheel.
# The CMakeLists.txt auto-discovers Embree from Homebrew on macOS, so no extra
# environment variables are needed when Embree is installed via `brew install embree`.
#
# This is the slowest step (~C++ compile time). The output wheel is discarded
# after the check; the purpose is to confirm the full build pipeline works.

section "Wheel build  ·  OpenRCT2-X7-Renderer"
WHEEL_OUT="$X7_DIR/.wheel-check"
EMBREE_PREFIX="$(brew --prefix embree 2>/dev/null || true)"

if [[ -d "$EMBREE_PREFIX" ]]; then
    rm -rf "$WHEEL_OUT"
    run_or_fail "OpenRCT2-X7-Renderer (wheel build)" bash -c "
        cd '$X7_DIR' && uv build --wheel --out-dir '$WHEEL_OUT'
    "
    if [[ -d "$WHEEL_OUT" ]]; then
        find "$WHEEL_OUT" -name "*.whl" -printf "  Built: %f\n" 2>/dev/null \
            || find "$WHEEL_OUT" -name "*.whl" | sed 's|.*/|  Built: |'
        rm -rf "$WHEEL_OUT"
    fi
else
    echo "  Embree not found — skipping"
    echo "  Install with: brew install embree"
    SKIPPED+=("OpenRCT2-X7-Renderer (wheel build — Embree not installed)")
fi

# ── Blender extension build (optional) ────────────────────────────────────────
# Mirrors the package-extension job in each build-plugin.yml.
#
# Each repo's scripts/build_plugin_local.py performs the full local pipeline:
# build the pure-Python front-end wheel, download the renderer + numpy/pillow/
# pyyaml from PyPI for the LOCAL Blender's CPython, stage a temp single-platform
# add-on (the committed wheels/ + manifest are untouched), and run
# `blender --command extension build`. The output zip is discarded after the
# check. This needs network access (PyPI) the first time wheels are fetched.
#
# The dep versions are pinned to whatever is resolved in the uv env, so that env
# must use the SAME CPython Blender ships (e.g. numpy 1.26.x has no cp313 wheel,
# but Blender 5.x runs CPython 3.13). UV_PYTHON is set to Blender's version below
# so the front-end wheel build and dep resolution target the right interpreter.

if command -v blender &>/dev/null; then
    BLENDER_VER="$(blender --version 2>/dev/null | head -1 || true)"
    # Detect Blender's bundled CPython (e.g. "3.13"); default to 3.13 (Blender 5.x).
    BLENDER_PY="$(blender --background --python-expr \
        "import sys;print('PYTAG%d.%d' % sys.version_info[:2])" 2>/dev/null \
        | sed -n 's/^PYTAG//p' | head -1)"
    BLENDER_PY="${BLENDER_PY:-3.13}"
    for entry in "${PLUGIN_PROJECTS[@]}"; do
        project="${entry%%:*}"
        section "Blender extension build  ·  $project"
        echo "  $BLENDER_VER  (CPython $BLENDER_PY)"
        OUT_DIR="$ROOT/$project/.ext-check"
        rm -rf "$OUT_DIR"
        run_or_fail "$project (blender extension)" bash -c "
            cd '$ROOT/$project' &&
            UV_PYTHON='$BLENDER_PY' uv run --python '$BLENDER_PY' \
                python scripts/build_plugin_local.py --output-dir '$OUT_DIR'
        "
        find "$OUT_DIR" -name "*.zip" | sed 's|.*/|  Built: |' || true
        rm -rf "$OUT_DIR"
    done
else
    section "Blender extension build"
    echo "  blender not found — skipping"
    echo "  Install from: https://www.blender.org/download/"
    for entry in "${PLUGIN_PROJECTS[@]}"; do
        SKIPPED+=("${entry%%:*} (blender extension — blender not installed)")
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "  Skipped:"
    for s in "${SKIPPED[@]}"; do echo "    - $s"; done
fi
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "  All CI checks passed."
else
    echo "  Failed:"
    for f in "${FAILED[@]}"; do echo "    - $f"; done
    exit 1
fi
