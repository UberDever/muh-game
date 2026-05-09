#!/usr/bin/env lua
-- build_test.lua — Build system test runner (Lua port of test_build.sh)
--
-- Usage:  lua scripts/build_test.lua
--         (or via the thin shell wrapper: bash scripts/test_build.sh)

local os = require "os"
local io = require "io"

-- Add the script's own directory to package.path so require("build_impl") works
-- regardless of the working directory.
local _script_dir = (arg[0]:match("(.*[/\\])") or "./")
package.path = _script_dir .. "?.lua;" .. package.path

local impl = require "build_impl"

local path_join    = impl.path_join
local lfs          = impl.lfs
local PROJECT_DIR  = impl.PROJECT_PATH
local BUILD_DIR    = path_join(PROJECT_DIR, "build")
local LUA_BIN      = path_join(PROJECT_DIR, "vendor", "lua-5.5.0", "lua")
local BUILD_SCRIPT = path_join(PROJECT_DIR, "scripts", "build.lua")
local MANIFEST     = path_join(PROJECT_DIR, "scripts", "manifest.debug.linux.lua")

-- ── Test framework ─────────────────────────────────────────────────────────

local PASS, FAIL, TOTAL = 0, 0, 0

local function record_pass(desc)
    TOTAL = TOTAL + 1; PASS = PASS + 1
    print("  PASS: " .. desc)
end

local function record_fail(desc, detail)
    TOTAL = TOTAL + 1; FAIL = FAIL + 1
    print("  FAIL: " .. desc)
    if detail then print("    " .. detail) end
end

local function run_build(...)
    local args = { ... }
    local cmd = LUA_BIN .. " " .. BUILD_SCRIPT
    for _, a in ipairs(args) do cmd = cmd .. " " .. a end
    cmd = cmd .. " 2>&1"
    local h = io.popen(cmd)
    assert(h, "popen failed: " .. cmd)
    local output = h:read("*a")
    local ok, _, code = h:close()
    local exit_code = ok and 0 or (code or 1)
    return exit_code, output or ""
end

local function assert_exit(expected, desc, ...)
    local code, output = run_build(...)
    if code == expected then record_pass(desc)
    else record_fail(desc, string.format("(expected exit %d, got %d)\n    output: %s", expected, code, output)) end
end

local function assert_exit_0(desc, ...) assert_exit(0, desc, ...) end

local function assert_exit_nonzero(desc, ...)
    local code, output = run_build(...)
    if code ~= 0 then record_pass(desc)
    else record_fail(desc, "(expected nonzero exit, got 0)\n    output: " .. output) end
end

local function assert_output_contains(desc, pattern, output)
    if output:find(pattern) then record_pass(desc)
    else record_fail(desc, "(pattern '" .. pattern .. "' not found)\n    output: " .. output) end
end

local function assert_output_not_contains(desc, pattern, output)
    if output:find(pattern) then record_fail(desc, "(pattern '" .. pattern .. "' unexpectedly found)\n    output: " .. output)
    else record_pass(desc) end
end

local function assert_file_exists(desc, path)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then record_pass(desc)
    else record_fail(desc, "(" .. path .. " not found)") end
end

local function assert_file_not_exists(desc, path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then record_pass(desc)
    else record_fail(desc, "(" .. path .. " still exists)") end
end

local function assert_dir_exists(desc, path)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then record_pass(desc)
    else record_fail(desc, "(" .. path .. " not found or not a directory)") end
end

local function assert_dir_not_exists(desc, path)
    local attr = lfs.attributes(path)
    if not attr then record_pass(desc)
    else record_fail(desc, "(" .. path .. " still exists)") end
end

-- ── Minimal JSON parser (pure Lua, no external deps) ───────────────────────

local json_parse

local function skip_ws(s, pos) return s:match("^%s*()", pos) end

local function parse_string(s, pos)
    if s:sub(pos, pos) ~= '"' then return nil, "expected '\"'" end
    local i = pos + 1
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1; local esc = s:sub(i, i)
            local map = { ['"']='"', ['\\']='\\', ['/']='/', n='\n', r='\r', t='\t', b='\b', f='\f' }
            if map[esc] then parts[#parts+1] = map[esc]
            elseif esc == 'u' then parts[#parts+1] = s:sub(i, i+4); i = i + 4
            else return nil, "bad escape \\" .. esc end
            i = i + 1
        else parts[#parts+1] = c; i = i + 1 end
    end
    return nil, "unterminated string"
end

local function parse_number(s, pos)
    local ns = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not ns or #ns == 0 then return nil, "expected number" end
    return tonumber(ns), pos + #ns
end

local function parse_array(s, pos)
    pos = skip_ws(s, pos + 1)
    local arr = {}
    if s:sub(pos, pos) == ']' then return arr, pos + 1 end
    while true do
        local val, npos = json_parse(s, pos)
        if val == nil and type(npos) == "string" then return nil, npos end
        arr[#arr+1] = val; pos = skip_ws(s, npos)
        local c = s:sub(pos, pos)
        if c == ']' then return arr, pos + 1 end
        if c ~= ',' then return nil, "expected ',' or ']'" end
        pos = skip_ws(s, pos + 1)
    end
end

local function parse_object(s, pos)
    pos = skip_ws(s, pos + 1)
    local obj = {}
    if s:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
        local key, kpos = parse_string(s, pos)
        if not key then return nil, kpos end
        pos = skip_ws(s, kpos)
        if s:sub(pos, pos) ~= ':' then return nil, "expected ':'" end
        pos = skip_ws(s, pos + 1)
        local val, vpos = json_parse(s, pos)
        if val == nil and type(vpos) == "string" then return nil, vpos end
        obj[key] = val; pos = skip_ws(s, vpos)
        local c = s:sub(pos, pos)
        if c == '}' then return obj, pos + 1 end
        if c ~= ',' then return nil, "expected ',' or '}'" end
        pos = skip_ws(s, pos + 1)
    end
end

json_parse = function(s, pos)
    pos = skip_ws(s, pos or 1)
    local c = s:sub(pos, pos)
    if c == '"' then return parse_string(s, pos) end
    if c == '{' then return parse_object(s, pos) end
    if c == '[' then return parse_array(s, pos) end
    if c == 't' and s:sub(pos, pos+3) == "true"  then return true, pos + 4 end
    if c == 'f' and s:sub(pos, pos+4) == "false" then return false, pos + 5 end
    if c == 'n' and s:sub(pos, pos+3) == "null"  then return setmetatable({}, {}), pos + 4 end
    if c == '-' or c:match("%d") then return parse_number(s, pos) end
    return nil, "unexpected char '" .. c .. "' at pos " .. pos
end

---@param path string
---@return table?, string?
local function read_json(path)
    local fh = io.open(path, "r")
    if not fh then return nil, "cannot open " .. path end
    local text = fh:read("*a"); fh:close()
    local val, err = json_parse(text, 1)
    if val == nil and type(err) == "string" then return nil, err end
    assert(type(val) == "table" or val == nil)
    return val, nil
end

local function assert_valid_json(desc, path)
    local val, err = read_json(path)
    if val ~= nil then record_pass(desc)
    else record_fail(desc, "(" .. path .. " is not valid JSON: " .. tostring(err) .. ")") end
end

local function assert_json_count(desc, path, expected)
    local val, err = read_json(path)
    if not val then record_fail(desc, "(cannot parse JSON: " .. tostring(err) .. ")"); return end
    if #val == expected then record_pass(desc)
    else record_fail(desc, string.format("(expected %d entries, got %d)", expected, #val)) end
end

local function assert_json_fields(desc, path)
    local val, err = read_json(path)
    if not val then record_fail(desc, "(cannot parse JSON: " .. tostring(err) .. ")"); return end
    for _, entry in ipairs(val) do
        for _, field in ipairs({ "directory", "file", "arguments", "output" }) do
            if entry[field] == nil then record_fail(desc, "(missing '" .. field .. "')"); return end
        end
        if type(entry["arguments"]) ~= "table" then record_fail(desc, "(arguments not a list)"); return end
        if not entry["arguments"][1] or entry["arguments"][1] == "" then record_fail(desc, "(arguments[1] empty)"); return end
    end
    record_pass(desc)
end

-- ── Utility ────────────────────────────────────────────────────────────────

local function clean_all()
    impl.rmdir_rf(path_join(BUILD_DIR, "objs"))
    impl.rmdir_rf(path_join(BUILD_DIR, "bin"))
    impl.rmdir_rf(path_join(BUILD_DIR, "lib"))
end

local function count_plain(s, sub)
    local count, start = 0, 1
    while true do
        local i = s:find(sub, start, true)
        if not i then break end
        count = count + 1; start = i + #sub
    end
    return count
end

local function grep_lines(text, pattern)
    local r = {}
    for line in text:gmatch("[^\n]+") do
        if line:find(pattern) then r[#r+1] = line end
    end
    return r
end

local function write_file(path, content)
    local fh = io.open(path, "w")
    if fh then fh:write(content); fh:close() end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TESTS
-- ════════════════════════════════════════════════════════════════════════════

clean_all()
os.remove(path_join(BUILD_DIR, "compile_commands.json"))

print("=== Subcommand & CLI Tests ===")
do
    local _, out = run_build("help")
    assert_output_contains("help shows usage", "Usage:", out)
    assert_exit_0("help exits 0", "help")
    assert_exit_nonzero("no manifest errors", "build")
    assert_exit_nonzero("unknown command errors", "bogus")
    assert_exit_nonzero("unknown flag errors", "build", "--bogus")
    assert_exit_nonzero("-m without value errors", "build", "-m")
    assert_exit_nonzero("-t without value errors", "build", "-m", MANIFEST, "-t")
    -- Default subcommand (no command word) still requires manifest
    assert_exit_nonzero("bare invocation without manifest errors")
end

print("\n=== List Subcommand ===")
do
    local _, out = run_build("list", "-m", MANIFEST)
    assert_output_contains("list shows cmd:game",      "cmd:game",      out)
    assert_output_contains("list shows lib:game",      "lib:game",      out)
    assert_output_contains("list shows lib:scripting", "lib:scripting", out)
    assert_output_contains("list shows test:game",     "test:game",     out)
    assert_output_contains("list shows vendor:SDL3",   "vendor:SDL3",   out)
    assert_exit_0("list exits 0", "list", "-m", MANIFEST)
    local names = {}
    for line in out:gmatch("[^\n]+") do
        if not line:find("^wrote:") and not line:find("^bootstrap") then names[#names+1] = line end
    end
    local sorted = {}
    for i, v in ipairs(names) do sorted[i] = v end
    table.sort(sorted)
    local ok = true
    for i = 1, #names do if names[i] ~= sorted[i] then ok = false; break end end
    if ok then record_pass("list target names are sorted")
    else record_fail("list target names not sorted") end
end

print("\n=== List Does Not Write compile_commands.json ===")
do
    local cc = path_join(BUILD_DIR, "compile_commands.json")
    os.remove(cc)
    run_build("list", "-m", MANIFEST)
    assert_file_not_exists("list does not create compile_commands.json", cc)
end

print("\n=== Compiledb Subcommand ===")
do
    local cc = path_join(BUILD_DIR, "compile_commands.json")
    os.remove(cc)
    local _, out = run_build("compiledb", "-m", MANIFEST)
    assert_output_contains("compiledb writes compile_commands", "wrote:.*compile_commands%.json", out)
    assert_file_exists("compile_commands.json created", cc)
    assert_valid_json("compile_commands.json is valid JSON", cc)
    assert_json_count("compile_commands.json has 4 entries", cc, 4)
    assert_json_fields("compile_commands.json entries have required fields", cc)
    assert_file_not_exists("compiledb does not create binaries", path_join(BUILD_DIR, "bin", "game"))
end

print("\n=== Build All (Default) ===")
clean_all()
local build_out
do
    local _, out = run_build("build", "-m", MANIFEST)
    build_out = out
    assert_output_contains("build compiles game.c",         "compile:.*game%.c",         out)
    assert_output_contains("build compiles lua.c",          "compile:.*lua%.c",          out)
    assert_output_contains("build compiles main.c",         "compile:.*main%.c",         out)
    assert_output_contains("build compiles game_test.c",    "compile:.*game_test%.c",    out)
    assert_output_contains("build archives libgame.a",      "archive:.*libgame%.a",      out)
    assert_output_contains("build archives libscripting.a", "archive:.*libscripting%.a", out)
    assert_output_contains("build links game exe",          "link_exe:.*bin/game",       out)
    assert_output_contains("build links game_test exe",     "link_exe:.*bin/game_test",  out)
    assert_file_exists("game.o exists",           path_join(BUILD_DIR, "objs", "internal", "game", "game.o"))
    assert_file_exists("lua.o exists",            path_join(BUILD_DIR, "objs", "internal", "scripting", "lua.o"))
    assert_file_exists("main.o exists",           path_join(BUILD_DIR, "objs", "cmd", "game", "main.o"))
    assert_file_exists("game_test.o exists",      path_join(BUILD_DIR, "objs", "internal", "game", "game_test.o"))
    assert_file_exists("libgame.a exists",        path_join(BUILD_DIR, "lib", "libgame.a"))
    assert_file_exists("libscripting.a exists",   path_join(BUILD_DIR, "lib", "libscripting.a"))
    assert_file_exists("game binary exists",      path_join(BUILD_DIR, "bin", "game"))
    assert_file_exists("game_test binary exists", path_join(BUILD_DIR, "bin", "game_test"))
end

print("\n=== Implicit Build (no subcommand word) ===")
do
    clean_all()
    local _, out = run_build("-m", MANIFEST)
    assert_output_contains("implicit build compiles", "compile:", out)
    assert_output_contains("implicit build links",    "link_exe:", out)
    assert_file_exists("implicit build creates game binary", path_join(BUILD_DIR, "bin", "game"))
end

print("\n=== System Link Flags ===")
do
    local lines = grep_lines(build_out, "^link_exe:")
    local ltxt = table.concat(lines, "\n")
    assert_output_contains("link has -lm",       "%-lm",       ltxt)
    assert_output_contains("link has -ldl",      "%-ldl",      ltxt)
    assert_output_contains("link has -lpthread", "%-lpthread", ltxt)
    if #lines > 0 then
        local sample = lines[1]
        for _, flag in ipairs({ "-lm", "-ldl", "-lpthread" }) do
            local cnt = count_plain(sample, flag)
            if cnt == 1 then record_pass(flag .. " appears exactly once in link command")
            else record_fail(flag .. " appears " .. cnt .. " times in link command", "line: " .. sample) end
        end
    end
end

print("\n=== Incremental Build (no-op) ===")
do
    local _, out = run_build("build", "-m", MANIFEST)
    assert_output_not_contains("no-op skips compile", "compile:", out)
    assert_output_not_contains("no-op skips archive", "archive:", out)
    assert_output_not_contains("no-op skips link",    "link_exe:", out)
end

print("\n=== Incremental Rebuild (source touched) ===")
do
    impl.sleep(1)
    impl.touch_file(path_join(PROJECT_DIR, "internal", "game", "game.c"))
    local _, out = run_build("build", "-m", MANIFEST)
    assert_output_contains("touched game.c triggers recompile",  "compile:.*game%.c",    out)
    assert_output_contains("touched game.c triggers re-archive", "archive:.*libgame%.a", out)
    assert_output_contains("touched game.c triggers re-link",    "link_exe:",            out)
end

print("\n=== Build Specific Target ===")
do
    clean_all()
    local _, out = run_build("build", "-m", MANIFEST, "-t", "lib:game")
    assert_output_contains("-t lib:game compiles game.c", "compile:.*game%.c",    out)
    assert_output_contains("-t lib:game archives",        "archive:.*libgame%.a", out)
    assert_output_not_contains("-t lib:game skips lua.c", "compile:.*lua%.c",     out)
    assert_output_not_contains("-t lib:game skips link",  "link_exe:",            out)
    assert_file_exists("lib:game creates libgame.a", path_join(BUILD_DIR, "lib", "libgame.a"))
    assert_file_not_exists("lib:game does not create game binary", path_join(BUILD_DIR, "bin", "game"))
    clean_all()
    _, out = run_build("build", "-m", MANIFEST, "-t", "cmd:game")
    assert_output_contains("-t cmd:game compiles main.c", "compile:.*main%.c",   out)
    assert_output_contains("-t cmd:game links game",      "link_exe:.*bin/game", out)
    assert_file_exists("cmd:game creates game binary", path_join(BUILD_DIR, "bin", "game"))
    assert_file_not_exists("cmd:game does not create game_test", path_join(BUILD_DIR, "bin", "game_test"))
    assert_exit_nonzero("unknown target errors", "build", "-m", MANIFEST, "-t", "bogus:target")
end

print("\n=== Vendor Target Build/Clean ===")
do
    assert_exit_0("vendor:SDL3 build exits 0", "build", "-m", MANIFEST, "-t", "vendor:SDL3")
    local _, out = run_build("clean", "-m", MANIFEST, "-t", "vendor:SDL3")
    assert_output_contains("vendor:SDL3 clean runs", "rmdir:.*SDL3", out)
end

print("\n=== Clean Specific Target ===")
do
    clean_all(); run_build("build", "-m", MANIFEST)
    local _, out = run_build("clean", "-m", MANIFEST, "-t", "lib:scripting")
    assert_output_contains("clean lib:scripting removes lua.o",          "rm:.*lua%.o",          out)
    assert_output_contains("clean lib:scripting removes libscripting.a", "rm:.*libscripting%.a", out)
    assert_output_not_contains("clean lib:scripting keeps game.o",       "rm:.*game%.o",         out)
    assert_file_not_exists("lua.o removed",          path_join(BUILD_DIR, "objs", "internal", "scripting", "lua.o"))
    assert_file_not_exists("libscripting.a removed", path_join(BUILD_DIR, "lib", "libscripting.a"))
    assert_file_exists("game.o still exists",        path_join(BUILD_DIR, "objs", "internal", "game", "game.o"))
    assert_file_exists("game binary still exists",   path_join(BUILD_DIR, "bin", "game"))
    run_build("build", "-m", MANIFEST)
    _, out = run_build("clean", "-m", MANIFEST, "-t", "lib:game")
    assert_output_contains("clean -t lib:game works", "rm:.*game%.o", out)
    assert_exit_nonzero("clean unknown target errors", "clean", "-m", MANIFEST, "-t", "bogus:target")
end

print("\n=== Clean All ===")
do
    run_build("build", "-m", MANIFEST)
    local _, out = run_build("clean", "-m", MANIFEST)
    assert_output_contains("clean all removes game binary",      "rm:.*bin/game\n",    out)
    assert_output_contains("clean all removes game_test binary", "rm:.*bin/game_test", out)
    assert_output_contains("clean all removes .o files",         "rm:.*%.o",           out)
    assert_file_not_exists("game binary removed",     path_join(BUILD_DIR, "bin", "game"))
    assert_file_not_exists("game_test binary removed", path_join(BUILD_DIR, "bin", "game_test"))
    assert_file_not_exists("game.o removed",          path_join(BUILD_DIR, "objs", "internal", "game", "game.o"))
    assert_file_not_exists("main.o removed",          path_join(BUILD_DIR, "objs", "cmd", "game", "main.o"))
    assert_file_exists("compile_commands.json preserved", path_join(BUILD_DIR, "compile_commands.json"))
end

print("\n=== Clean Does Not Write compile_commands.json ===")
do
    local cc = path_join(BUILD_DIR, "compile_commands.json")
    os.remove(cc)
    run_build("clean", "-m", MANIFEST)
    assert_file_not_exists("clean does not create compile_commands.json", cc)
end

print("\n=== Clean Idempotent ===")
do
    -- Ensure compile_commands exists for subsequent tests
    run_build("compiledb", "-m", MANIFEST)
    local _, out = run_build("clean", "-m", MANIFEST)
    assert_output_not_contains("second clean has nothing to rm", "rm:", out)
    assert_exit_0("double clean exits 0", "clean", "-m", MANIFEST)
end

print("\n=== Build After Clean ===")
do
    local _, out = run_build("build", "-m", MANIFEST)
    assert_output_contains("rebuild after clean compiles", "compile:", out)
    assert_output_contains("rebuild after clean links",    "link_exe:", out)
    assert_file_exists("game binary rebuilt", path_join(BUILD_DIR, "bin", "game"))
end

print("\n=== compile_commands.json Regenerated on Build ===")
do
    local cc = path_join(BUILD_DIR, "compile_commands.json")
    write_file(cc, "garbage")
    run_build("build", "-m", MANIFEST)
    assert_valid_json("compile_commands.json regenerated on build", cc)
end

print("\n=== Directory Target (kind=dir) ===")
do
    local dir_test     = path_join(BUILD_DIR, "_dir_test")
    local dir_test_sub = path_join(dir_test, "sub")
    impl.mkdir_p(dir_test_sub)
    write_file(path_join(dir_test_sub, "file.txt"), "test")
    assert_dir_exists("dir test setup: dir exists", dir_test)
    assert_file_exists("dir test setup: nested file exists", path_join(dir_test_sub, "file.txt"))
    impl.rmdir_rf(dir_test)
end


print("\n=== Install Subcommand ===")
do
    local install_dir = path_join(BUILD_DIR, "_test_install")
    impl.rmdir_rf(install_dir)

    -- Ensure targets are built first
    clean_all()

    -- Install with explicit --prefix
    local _, out = run_build("install", "-m", MANIFEST, "--prefix", install_dir)
    assert_output_contains("install builds before copying", "compile:", out)
    assert_output_contains("install copies game binary", "install:.*bin/game.*->.*bin/game", out)
    assert_file_exists("installed game binary exists", path_join(install_dir, "bin", "game"))
    assert_exit_0("install exits 0", "install", "-m", MANIFEST, "-p", install_dir)

    -- Install is idempotent (rerun copies again without error)
    local code2, out2 = run_build("install", "-m", MANIFEST, "-p", install_dir)
    if code2 == 0 then record_pass("install idempotent (rerun exits 0)")
    else record_fail("install idempotent (rerun exits 0)", "exit code: " .. code2 .. "\n    output: " .. out2) end
    assert_file_exists("installed game binary still exists after rerun", path_join(install_dir, "bin", "game"))

    -- Install with short flags
    impl.rmdir_rf(install_dir)
    assert_exit_0("install short flags -p", "install", "-m", MANIFEST, "-p", install_dir)
    assert_file_exists("short-flag install creates game binary", path_join(install_dir, "bin", "game"))

    -- Install uses manifest default prefix when --prefix not given
    local default_install = path_join(PROJECT_DIR, "build", "install")
    impl.rmdir_rf(default_install)
    assert_exit_0("install with default prefix", "install", "-m", MANIFEST)
    assert_file_exists("default prefix installs game binary", path_join(default_install, "bin", "game"))
    impl.rmdir_rf(default_install)

    -- Clean does not affect installed files
    impl.rmdir_rf(install_dir)
    run_build("install", "-m", MANIFEST, "-p", install_dir)
    run_build("clean", "-m", MANIFEST)
    assert_file_exists("clean does not remove installed files", path_join(install_dir, "bin", "game"))

    -- --prefix overrides build_dir in non-install modes
    local alt_build = path_join(BUILD_DIR, "_alt_build")
    impl.rmdir_rf(alt_build)
    assert_exit_0("--prefix overrides build_dir", "compiledb", "-m", MANIFEST, "-p", alt_build)
    assert_file_exists("compile_commands in alt build dir",
        path_join(alt_build, "compile_commands.json"))
    impl.rmdir_rf(alt_build)

    -- Cleanup
    impl.rmdir_rf(install_dir)
end

-- ── Results ────────────────────────────────────────────────────────────────

print("")
print(string.rep("=", 40))
print(string.format("  Results: %d passed, %d failed, %d total", PASS, FAIL, TOTAL))
print(string.rep("=", 40))

if FAIL > 0 then os.exit(1) end
