#!/usr/bin/env bash
# Run every lint check used in CI across all four projects.
#
# Prerequisites: the workspace .venv must be up to date (`uv sync --all-groups`).
# clang-format and clang-tidy are optional (Homebrew LLVM or system install);
# if they are absent the C++ checks are skipped, not failed.
# clang-tidy also requires a CMake compile_commands.json under
# OpenRCT2-X7-Renderer/build/; if none exists it is skipped with a hint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X7_DIR="$ROOT/OpenRCT2-X7-Renderer"
X7_SRC="$X7_DIR/x7_renderer"

PYTHON_PROJECTS=(
    "OpenRCT2-X7-Renderer"
    "OpenRCT2-ObjectCommon"
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
)
YAMLLINT_PROJECTS=(
    "OpenRCT2-VehicleGenerator"
    "OpenRCT2-SceneryGenerator"
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

# Run $@ and append $label to FAILED on non-zero exit.
run_or_fail() {
    local label="$1"; shift
    if ! "$@"; then
        FAILED+=("$label")
    fi
}

# ── C++: clang-format ─────────────────────────────────────────────────────────

section "clang-format  ·  OpenRCT2-X7-Renderer"

if command -v clang-format &>/dev/null; then
    echo "  $(clang-format --version)"
    run_or_fail "OpenRCT2-X7-Renderer (clang-format)" \
        clang-format --dry-run --Werror \
            "$X7_SRC/bindings.cpp" \
            "$X7_SRC/src/"*.hpp \
            "$X7_SRC/src/"*.cpp \
            "$X7_SRC/tests/"*.cpp
else
    echo "  clang-format not found — skipping (install via Homebrew: brew install llvm)"
    SKIPPED+=("OpenRCT2-X7-Renderer (clang-format)")
fi

# ── C++: clang-tidy ───────────────────────────────────────────────────────────

section "clang-tidy  ·  OpenRCT2-X7-Renderer"

if command -v clang-tidy &>/dev/null; then
    echo "  $(clang-tidy --version | head -1)"

    # Prefer Python-module builds (they include bindings.cpp) over the cpp-tests
    # build. Fall back to cpp-tests if that's all that exists.
    COMPILE_DB=""
    for candidate in "$X7_DIR/build/"*/; do
        [[ -f "${candidate}compile_commands.json" ]] || continue
        [[ "$candidate" == *"cpp-tests"* ]] && continue
        COMPILE_DB="${candidate%/}"
        break
    done
    if [[ -z "$COMPILE_DB" && -f "$X7_DIR/build/cpp-tests/compile_commands.json" ]]; then
        COMPILE_DB="$X7_DIR/build/cpp-tests"
    fi

    if [[ -n "$COMPILE_DB" ]]; then
        echo "  Using compile DB: $COMPILE_DB"

        # On macOS the Homebrew LLVM clang-tidy needs the SDK root so it can
        # find standard library headers (<array>, <algorithm>, etc.).
        TIDY_EXTRA_ARGS=()
        if [[ "$(uname)" == "Darwin" ]]; then
            SDKROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
            [[ -n "$SDKROOT" ]] && TIDY_EXTRA_ARGS+=(--extra-arg="-isysroot$SDKROOT")
        fi

        run_or_fail "OpenRCT2-X7-Renderer (clang-tidy)" \
            clang-tidy "${TIDY_EXTRA_ARGS[@]}" -p "$COMPILE_DB" --warnings-as-errors='*' \
                "$X7_SRC/src/Mesh.cpp" \
                "$X7_SRC/src/Palette.cpp" \
                "$X7_SRC/src/RayTrace.cpp" \
                "$X7_SRC/src/Renderer.cpp"
    else
        echo "  No compile_commands.json found — skipping."
        echo "  To generate one:"
        echo "    cmake -S $X7_SRC -B $X7_DIR/build/lint \\"
        echo "          -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \\"
        echo "          -DBUILD_PYTHON_MODULE=ON \\"
        echo "          -DBUILD_TESTING=OFF"
        SKIPPED+=("OpenRCT2-X7-Renderer (clang-tidy — no compile DB)")
    fi
else
    echo "  clang-tidy not found — skipping (install via Homebrew: brew install llvm)"
    SKIPPED+=("OpenRCT2-X7-Renderer (clang-tidy)")
fi

# ── Python: ruff ──────────────────────────────────────────────────────────────

for project in "${PYTHON_PROJECTS[@]}"; do
    section "ruff  ·  $project"
    run_or_fail "$project (ruff)" \
        bash -c "cd '$ROOT/$project' && uv run --no-sync ruff check ."
done

# ── Python: mypy ──────────────────────────────────────────────────────────────
# X7-Renderer only. Consumer mypy depends on installed sibling versions, so it's
# run standalone (py3.11, PyPI) by ci_macos.sh; the workspace would pass falsely.

section "mypy  ·  OpenRCT2-X7-Renderer"
run_or_fail "OpenRCT2-X7-Renderer (mypy)" \
    bash -c "cd '$ROOT/OpenRCT2-X7-Renderer' && uv run --no-sync mypy"

# ── Python: yamllint ──────────────────────────────────────────────────────────

for project in "${YAMLLINT_PROJECTS[@]}"; do
    section "yamllint  ·  $project"
    run_or_fail "$project (yamllint)" \
        bash -c "cd '$ROOT/$project' && uv run --no-sync yamllint examples"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "  Skipped:"
    for s in "${SKIPPED[@]}"; do
        echo "    - $s"
    done
fi

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "  All lint checks passed."
else
    echo "  Failed:"
    for f in "${FAILED[@]}"; do
        echo "    - $f"
    done
    exit 1
fi
