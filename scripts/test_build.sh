#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LUA="$PROJECT_DIR/vendor/lua-5.5.0/lua"
BUILD="$PROJECT_DIR/scripts/build.lua"
MANIFEST="$PROJECT_DIR/scripts/manifest.linux.lua"
BUILD_DIR="$PROJECT_DIR/build"

PASS=0
FAIL=0
TOTAL=0

run() {
    "$LUA" "$BUILD" "$@" 2>&1
}

assert_exit() {
    local expected="$1"; shift
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    set +e
    output=$("$@" 2>&1)
    actual=$?
    set -e
    if [ "$actual" -eq "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit $expected, got $actual)"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_0() { assert_exit 0 "$@"; }
assert_exit_nonzero() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    set +e
    output=$("$@" 2>&1)
    actual=$?
    set -e
    if [ "$actual" -ne 0 ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected nonzero exit, got 0)"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local desc="$1"
    local pattern="$2"
    local output="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -qE "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local desc="$1"
    local pattern="$2"
    local output="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -qE "$pattern"; then
        echo "  FAIL: $desc (pattern '$pattern' unexpectedly found)"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_file_exists() {
    local desc="$1"
    local path="$2"
    TOTAL=$((TOTAL + 1))
    if [ -f "$path" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($path not found)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_exists() {
    local desc="$1"
    local path="$2"
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$path" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($path still exists)"
        FAIL=$((FAIL + 1))
    fi
}

assert_valid_json() {
    local desc="$1"
    local path="$2"
    TOTAL=$((TOTAL + 1))
    if python3 -c "import json; json.load(open('$path'))" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($path is not valid JSON)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_count() {
    local desc="$1"
    local path="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))
    local actual
    actual=$(python3 -c "import json; print(len(json.load(open('$path'))))" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected $expected entries, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_fields() {
    local desc="$1"
    local path="$2"
    TOTAL=$((TOTAL + 1))
    local ok
    ok=$(python3 -c "
import json, sys
data = json.load(open('$path'))
for entry in data:
    for field in ['directory', 'file', 'arguments', 'output']:
        if field not in entry:
            print(f'missing {field}')
            sys.exit(1)
    if not isinstance(entry['arguments'], list):
        print('arguments not a list')
        sys.exit(1)
    if not entry['arguments'][0]:
        print('arguments[0] empty')
        sys.exit(1)
print('ok')
" 2>&1)
    if [ "$ok" = "ok" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($ok)"
        FAIL=$((FAIL + 1))
    fi
}

clean_all() {
    rm -rf "$BUILD_DIR/objs" "$BUILD_DIR/bin" "$BUILD_DIR/lib"
}

# ── Ensure clean state ─────────────────────────────────────────────────────
clean_all
rm -f "$BUILD_DIR/compile_commands.json"

echo "=== CLI Flag Tests ==="

# --help / -h
output=$(run -h)
assert_output_contains "--help shows usage" "Usage:" "$output"
assert_exit_0 "-h exits 0" run -h

output=$(run --help)
assert_output_contains "--help long form" "Usage:" "$output"

# No manifest
assert_exit_nonzero "no manifest errors" run

# Unknown flag
assert_exit_nonzero "unknown flag errors" run --bogus

# Missing value for -m
assert_exit_nonzero "-m without value errors" run -m

# Missing value for -t
assert_exit_nonzero "-t without value errors" run -m "$MANIFEST" -t

echo ""
echo "=== List Mode ==="

output=$(run -m "$MANIFEST" -l)
assert_output_contains "-l lists cmd:game" "cmd:game" "$output"
assert_output_contains "-l lists lib:game" "lib:game" "$output"
assert_output_contains "-l lists lib:scripting" "lib:scripting" "$output"
assert_output_contains "-l lists test:game" "test:game" "$output"
assert_exit_0 "--list exits 0" run -m "$MANIFEST" --list

# List output is sorted
output=$(run -m "$MANIFEST" -l | grep -v "^wrote:")
TOTAL=$((TOTAL + 1))
sorted_output=$(echo "$output" | sort)
if [ "$output" = "$sorted_output" ]; then
    echo "  PASS: list output is sorted"
    PASS=$((PASS + 1))
else
    echo "  FAIL: list output not sorted"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Compile Commands Mode ==="

# Clean compile_commands.json first
rm -f "$BUILD_DIR/compile_commands.json"

output=$(run -m "$MANIFEST" -cc)
assert_output_contains "-cc writes compile_commands" "wrote:.*compile_commands.json" "$output"
assert_file_exists "compile_commands.json created" "$BUILD_DIR/compile_commands.json"
assert_valid_json "compile_commands.json is valid JSON" "$BUILD_DIR/compile_commands.json"
assert_json_count "compile_commands.json has 4 entries" "$BUILD_DIR/compile_commands.json" 4
assert_json_fields "compile_commands.json entries have required fields" "$BUILD_DIR/compile_commands.json"

# --compile_commands long form
rm -f "$BUILD_DIR/compile_commands.json"
output=$(run -m "$MANIFEST" --compile_commands)
assert_file_exists "--compile_commands long form works" "$BUILD_DIR/compile_commands.json"

# compiledb does NOT build anything
assert_file_not_exists "-cc does not create binaries" "$BUILD_DIR/bin/game"

echo ""
echo "=== Build All (Default) ==="

clean_all
output=$(run -m "$MANIFEST")
assert_output_contains "build compiles game.c" "compile:.*game\.c" "$output"
assert_output_contains "build compiles lua.c" "compile:.*lua\.c" "$output"
assert_output_contains "build compiles main.c" "compile:.*main\.c" "$output"
assert_output_contains "build compiles game_test.c" "compile:.*game_test\.c" "$output"
assert_output_contains "build archives libgame.a" "archive:.*libgame\.a" "$output"
assert_output_contains "build archives libscripting.a" "archive:.*libscripting\.a" "$output"
assert_output_contains "build links game exe" "link_exe:.*bin/game" "$output"
assert_output_contains "build links game_test exe" "link_exe:.*bin/game_test" "$output"

assert_file_exists "game.o exists" "$BUILD_DIR/objs/internal/game/game.o"
assert_file_exists "lua.o exists" "$BUILD_DIR/objs/internal/scripting/lua.o"
assert_file_exists "main.o exists" "$BUILD_DIR/objs/cmd/game/main.o"
assert_file_exists "game_test.o exists" "$BUILD_DIR/objs/internal/game/game_test.o"
assert_file_exists "libgame.a exists" "$BUILD_DIR/lib/libgame.a"
assert_file_exists "libscripting.a exists" "$BUILD_DIR/lib/libscripting.a"
assert_file_exists "game binary exists" "$BUILD_DIR/bin/game"
assert_file_exists "game_test binary exists" "$BUILD_DIR/bin/game_test"

echo ""
echo "=== Incremental Build (no-op) ==="

output=$(run -m "$MANIFEST")
assert_output_not_contains "no-op skips compile" "compile:" "$output"
assert_output_not_contains "no-op skips archive" "archive:" "$output"
assert_output_not_contains "no-op skips link" "link_exe:" "$output"

echo ""
echo "=== Incremental Rebuild (source touched) ==="

sleep 1
touch "$PROJECT_DIR/internal/game/game.c"
output=$(run -m "$MANIFEST")
assert_output_contains "touched game.c triggers recompile" "compile:.*game\.c" "$output"
assert_output_contains "touched game.c triggers re-archive" "archive:.*libgame\.a" "$output"
assert_output_contains "touched game.c triggers re-link" "link_exe:" "$output"

echo ""
echo "=== Build Specific Target ==="

clean_all
output=$(run -m "$MANIFEST" -t lib:game)
assert_output_contains "-t lib:game compiles game.c" "compile:.*game\.c" "$output"
assert_output_contains "-t lib:game archives" "archive:.*libgame\.a" "$output"
assert_output_not_contains "-t lib:game skips lua.c" "compile:.*lua\.c" "$output"
assert_output_not_contains "-t lib:game skips link" "link_exe:" "$output"
assert_file_exists "lib:game creates libgame.a" "$BUILD_DIR/lib/libgame.a"
assert_file_not_exists "lib:game does not create game binary" "$BUILD_DIR/bin/game"

# Build cmd:game (depends on all libs)
clean_all
output=$(run -m "$MANIFEST" -t cmd:game)
assert_output_contains "-t cmd:game compiles main.c" "compile:.*main\.c" "$output"
assert_output_contains "-t cmd:game links game" "link_exe:.*bin/game" "$output"
assert_file_exists "cmd:game creates game binary" "$BUILD_DIR/bin/game"
assert_file_not_exists "cmd:game does not create game_test" "$BUILD_DIR/bin/game_test"

# Unknown target
assert_exit_nonzero "unknown target errors" run -m "$MANIFEST" -t bogus:target

echo ""
echo "=== Clean Specific Target ==="

# Rebuild everything first
clean_all
run -m "$MANIFEST" >/dev/null

output=$(run -m "$MANIFEST" --clean -t lib:scripting)
assert_output_contains "clean lib:scripting removes lua.o" "rm:.*lua\.o" "$output"
assert_output_contains "clean lib:scripting removes libscripting.a" "rm:.*libscripting\.a" "$output"
assert_output_not_contains "clean lib:scripting keeps game.o" "rm:.*game\.o" "$output"
assert_file_not_exists "lua.o removed" "$BUILD_DIR/objs/internal/scripting/lua.o"
assert_file_not_exists "libscripting.a removed" "$BUILD_DIR/lib/libscripting.a"
assert_file_exists "game.o still exists" "$BUILD_DIR/objs/internal/game/game.o"
assert_file_exists "game binary still exists" "$BUILD_DIR/bin/game"

# Clean with short flag
run -m "$MANIFEST" >/dev/null  # rebuild
output=$(run -m "$MANIFEST" -c -t lib:game)
assert_output_contains "-c short flag works" "rm:.*game\.o" "$output"

# Unknown target for clean
assert_exit_nonzero "clean unknown target errors" run -m "$MANIFEST" --clean -t bogus:target

echo ""
echo "=== Clean All ==="

run -m "$MANIFEST" >/dev/null  # rebuild
output=$(run -m "$MANIFEST" --clean)
assert_output_contains "clean all removes game binary" "rm:.*bin/game$" "$output"
assert_output_contains "clean all removes game_test binary" "rm:.*bin/game_test" "$output"
assert_output_contains "clean all removes .o files" "rm:.*\.o" "$output"
assert_file_not_exists "game binary removed" "$BUILD_DIR/bin/game"
assert_file_not_exists "game_test binary removed" "$BUILD_DIR/bin/game_test"
assert_file_not_exists "game.o removed" "$BUILD_DIR/objs/internal/game/game.o"
assert_file_not_exists "main.o removed" "$BUILD_DIR/objs/cmd/game/main.o"
assert_file_exists "compile_commands.json preserved" "$BUILD_DIR/compile_commands.json"

echo ""
echo "=== Clean Idempotent ==="

output=$(run -m "$MANIFEST" --clean)
assert_output_not_contains "second clean has nothing to rm" "rm:" "$output"
assert_exit_0 "double clean exits 0" run -m "$MANIFEST" --clean

echo ""
echo "=== Build After Clean ==="

output=$(run -m "$MANIFEST")
assert_output_contains "rebuild after clean compiles" "compile:" "$output"
assert_output_contains "rebuild after clean links" "link_exe:" "$output"
assert_file_exists "game binary rebuilt" "$BUILD_DIR/bin/game"

echo ""
echo "=== compile_commands.json Always Regenerated ==="

# Modify compile_commands.json, verify it gets overwritten
echo "garbage" > "$BUILD_DIR/compile_commands.json"
run -m "$MANIFEST" -l >/dev/null
assert_valid_json "compile_commands.json regenerated on --list" "$BUILD_DIR/compile_commands.json"

echo "garbage" > "$BUILD_DIR/compile_commands.json"
run -m "$MANIFEST" >/dev/null
assert_valid_json "compile_commands.json regenerated on build" "$BUILD_DIR/compile_commands.json"

echo ""
echo "════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
