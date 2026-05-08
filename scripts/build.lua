os = require "os"
io = require "io"

OS_SEP = package.config:sub(1, 1)

local function path_join(...)
    local args = { ... }
    return (table.concat(args, OS_SEP):gsub(OS_SEP .. OS_SEP .. "+", OS_SEP))
end

local function get_script_path()
    local is_unix = OS_SEP == "/"
    local cwd
    if is_unix then
        cwd = io.popen("pwd"):read("*l")
        local full_path = path_join(cwd, arg[0])
        return full_path:match("(.*[/\\])") or ""
    end
    assert(cwd, "OS not supported")
end

PROJECT_PATH = path_join(get_script_path(), "..")
LUA_SRC_PATH = path_join(PROJECT_PATH, "vendor", "lua-5.5.0")

-- lfs bootstrap: compile C module if needed, then load
local lfs_dir = path_join(PROJECT_PATH, "vendor", "lfs")
local lfs_so = path_join(lfs_dir, "lfs.so")
local lfs_src = path_join(lfs_dir, "lfs.c")

local f = io.open(lfs_so, "r")
if not f then
    local cmd = string.format(
        "cc -shared -fPIC -O2 -o %s %s -I%s -I%s",
        lfs_so, lfs_src, lfs_dir, LUA_SRC_PATH
    )
    print("bootstrap: " .. cmd)
    local ok, _, code = os.execute(cmd)
    assert(ok, "Failed to compile lfs (exit " .. tostring(code) .. ")")
else
    f:close()
end

package.cpath = path_join(lfs_dir, "?.so") .. ";" .. package.cpath
local lfs = require "lfs"

-- build: infrastructure / utilities

---@class build
local build = {}
build.__index = build

build.path_join = path_join

function build.parent_dir(path)
    return path:match("(.*)[/\\][^/\\]+$")
end

function build.mkdir_p(path)
    if not path or path == "" then return end
    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then return end
    build.mkdir_p(build.parent_dir(path))
    lfs.mkdir(path)
end

function build.ensure_parent_dir(filepath)
    local dir = build.parent_dir(filepath)
    if dir then build.mkdir_p(dir) end
end

function build.cmd_append_arg(cmd, value)
    if type(value) == "string" then
        for part in value:gmatch("%S+") do
            cmd[#cmd + 1] = part
        end
    end
end

function build.is_absolute(path)
    if path:sub(1, 1) == "/" then
        return true
    end
    if path:match("^%a:[/\\]") or path:match("^[/\\][/\\]") then
        return true
    end
    return false
end

function build.new()
    local self = setmetatable({}, build)
    self.manifest = nil
    return self
end

function build:parse_args()
    local cur_flag = 1
    while arg[cur_flag] do
        local flag = arg[cur_flag]
        if flag == "--manifest" or flag == "-m" then
            cur_flag = cur_flag + 1
            assert(cur_flag <= #arg, "Expected value for flag '" .. flag .. "'")
            local flag_value = arg[cur_flag]
            cur_flag = cur_flag + 1
            if not build.is_absolute(flag_value) then
                flag_value = lfs.currentdir() .. OS_SEP .. flag_value
            end
            self.manifest = dofile(flag_value)
            goto continue
        end

        assert(false, "Unknown flag '" .. flag .. "'")
        ::continue::
    end
    assert(self.manifest, "Manifest nil!!")
end

-- muh_ninja: build runner, rules, target constructors

local muh_ninja = {}
muh_ninja.__index = muh_ninja

function muh_ninja.new(b)
    local self = setmetatable({}, muh_ninja)
    self.build = b
    return self
end

function muh_ninja.already_built(target)
    return false
end

function muh_ninja.run(target)
    if muh_ninja.already_built(target) then
        return true
    end
    for i = 1, #target.deps do
        if not muh_ninja.run(target.deps[i]) then
            return false
        end
    end
    return target:rule()
end

-- Rules

function muh_ninja.rule_compile(target)
    local mn = target.manifest
    local cmd = {}

    cmd[#cmd + 1] = mn.cc

    assert(mn.cflags, "manifest missing 'cflags'")
    build.cmd_append_arg(cmd, mn.cflags)

    for _, v in ipairs(target.build_args) do
        build.cmd_append_arg(cmd, v)
    end

    assert(#target.ins == 1, "rule_compile expects exactly 1 input, got " .. #target.ins)
    cmd[#cmd + 1] = "-c"
    cmd[#cmd + 1] = target.ins[1]

    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = target.name

    build.ensure_parent_dir(target.name)
    local cmd_str = table.concat(cmd, " ")
    print("compile: " .. cmd_str)
    local ok, _, code = os.execute(cmd_str)
    return ok ~= nil
end

function muh_ninja.rule_link_exe(target)
    local mn = target.manifest
    local cmd = {}

    cmd[#cmd + 1] = mn.cc

    for _, v in ipairs(target.build_args) do
        build.cmd_append_arg(cmd, v)
    end

    for _, the_in in ipairs(target.ins) do
        cmd[#cmd + 1] = the_in
    end

    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = target.name

    build.ensure_parent_dir(target.name)
    local cmd_str = table.concat(cmd, " ")
    print("link_exe: " .. cmd_str)
    local ok, _, code = os.execute(cmd_str)
    return ok ~= nil
end

-- Target constructors

function muh_ninja:target_compile(path, name, build_args, deps)
    return {
        name = name,
        manifest = self.build.manifest,
        build_args = build_args,
        ins = { path },
        deps = deps,
        rule = muh_ninja.rule_compile,
    }
end

function muh_ninja:target_link(ins, name, build_args, deps)
    return {
        name = name,
        manifest = self.build.manifest,
        build_args = build_args,
        ins = ins,
        deps = deps,
        rule = muh_ninja.rule_link_exe,
    }
end

-- Main

local b = build.new()
b:parse_args()

local ninja = muh_ninja.new(b)

local main_target = ninja:target_compile(
    path_join(PROJECT_PATH, "tmp", "main.c"),
    path_join(PROJECT_PATH, "tmp", "objs", "main.o"),
    { "-I" .. path_join(PROJECT_PATH, "tmp"), }, {}
)
local lib_target = ninja:target_compile(
    path_join(PROJECT_PATH, "tmp", "lib.c"),
    path_join(PROJECT_PATH, "tmp", "objs", "lib.o"),
    {}, {}
)
local exe_target = ninja:target_link(
    {
        path_join(PROJECT_PATH, "tmp", "objs", "main.o"),
        path_join(PROJECT_PATH, "tmp", "objs", "lib.o"),
    },
    path_join(PROJECT_PATH, "tmp", "bin", "a.out"),
    {}, { main_target, lib_target }
)

ninja.run(exe_target)
