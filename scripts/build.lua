local os = require "os"
local io = require "io"

local OS_SEP = package.config:sub(1, 1)

local function path_join(...)
    local args = { ... }
    return (table.concat(args, OS_SEP):gsub(OS_SEP .. OS_SEP .. "+", OS_SEP))
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function get_script_path()
    local is_unix = OS_SEP == "/"
    assert(is_unix, "OS not supported")
    local h = io.popen("pwd")
    assert(h)
    local cwd = h:read("*l")
    h:close()
    local full_path = path_join(cwd, arg[0])
    return full_path:match("(.*[/\\])") or ""
end

local PROJECT_PATH = path_join(get_script_path(), "..")
local LUA_SRC_PATH = path_join(PROJECT_PATH, "vendor", "lua-5.5.0")

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

--- NOTE: splits on whitespace; paths with spaces will break.
function build.cmd_append_arg(cmd, value)
    if type(value) == "string" then
        for part in value:gmatch("%S+") do
            cmd[#cmd + 1] = part
        end
    end
end

function build.is_absolute(path)
    return path:sub(1, 1) == "/"
        or path:match("^%a:[/\\]") ~= nil
        or path:match("^[/\\][/\\]") ~= nil
end

function build.print_usage()
    print([[
Usage: lua scripts/build.lua [flags]

Flags:
  -m, --manifest <path>   Path to manifest file (required unless --help)
  -t, --target <name>     Build single target (e.g. cmd:game, test:game, lib:game)
  -l, --list              List available targets and exit
  -h, --help              Show this help and exit

Examples:
  lua scripts/build.lua -m scripts/manifest.linux.lua
  lua scripts/build.lua -m scripts/manifest.linux.lua -t cmd:game
  lua scripts/build.lua -m scripts/manifest.linux.lua --list
  lua scripts/build.lua --help]])
end

function build.new()
    local self = setmetatable({}, build)
    self.manifest = nil
    self.target = nil
    self.mode = "build"
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
        elseif flag == "--target" or flag == "-t" then
            cur_flag = cur_flag + 1
            assert(cur_flag <= #arg, "Expected value for flag '" .. flag .. "'")
            self.target = arg[cur_flag]
            cur_flag = cur_flag + 1
        elseif flag == "--list" or flag == "-l" then
            self.mode = "list"
            cur_flag = cur_flag + 1
        elseif flag == "--help" or flag == "-h" then
            self.mode = "help"
            cur_flag = cur_flag + 1
        else
            error("Unknown flag '" .. flag .. "'")
        end
    end

    if self.mode == "help" then
        build.print_usage()
        os.exit(0)
    end

    assert(self.manifest, "Manifest nil!!")
end

local target = {}
target.__index = target

function target.new(kind, fields)
    local self = setmetatable({}, target)
    self.kind = kind
    self.name = fields.name
    self.manifest = fields.manifest
    self.build_args = fields.build_args or {}
    self.ins = fields.ins or {}
    self.deps = fields.deps or {}
    return self
end

function target:run()
    if self.kind == "compile" then
        return self:compile()
    elseif self.kind == "link_exe" then
        return self:link_exe()
    elseif self.kind == "archive" then
        return self:archive()
    else
        error("unknown target kind: " .. tostring(self.kind))
    end
end

function target:compile()
    local mn = self.manifest
    local cmd = {}

    cmd[#cmd + 1] = mn.cc

    assert(mn.cflags, "manifest missing 'cflags'")
    build.cmd_append_arg(cmd, mn.cflags)

    for _, v in ipairs(self.build_args) do
        build.cmd_append_arg(cmd, v)
    end

    assert(#self.ins == 1, "compile expects exactly 1 input, got " .. #self.ins)
    cmd[#cmd + 1] = "-c"
    cmd[#cmd + 1] = self.ins[1]

    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = self.name

    build.ensure_parent_dir(self.name)
    local cmd_str = table.concat(cmd, " ")
    print("compile: " .. cmd_str)
    local ok = os.execute(cmd_str)
    return ok ~= nil
end

function target:link_exe()
    local mn = self.manifest
    local cmd = {}

    cmd[#cmd + 1] = mn.cc

    for _, v in ipairs(self.build_args) do
        build.cmd_append_arg(cmd, v)
    end

    for _, the_in in ipairs(self.ins) do
        cmd[#cmd + 1] = the_in
    end

    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = self.name

    build.ensure_parent_dir(self.name)
    local cmd_str = table.concat(cmd, " ")
    print("link_exe: " .. cmd_str)
    local ok = os.execute(cmd_str)
    return ok ~= nil
end

function target:archive()
    local mn = self.manifest
    local ar = mn.ar or "ar"
    local arflags = mn.arflags or "rcs"
    local cmd = {}

    cmd[#cmd + 1] = ar
    cmd[#cmd + 1] = arflags
    cmd[#cmd + 1] = self.name

    for _, the_in in ipairs(self.ins) do
        cmd[#cmd + 1] = the_in
    end

    build.ensure_parent_dir(self.name)
    os.remove(self.name)
    local cmd_str = table.concat(cmd, " ")
    print("archive: " .. cmd_str)
    local ok = os.execute(cmd_str)
    return ok ~= nil
end

local muh_ninja = {}
muh_ninja.__index = muh_ninja

function muh_ninja.new(b)
    local self = setmetatable({}, muh_ninja)
    self.build = b
    return self
end

function muh_ninja.already_built(target)
    local out_attr = lfs.attributes(target.name)
    if not out_attr then return false end
    local out_mtime = out_attr.modification

    for _, src in ipairs(target.ins) do
        local in_attr = lfs.attributes(src)
        if not in_attr then return false end
        if in_attr.modification > out_mtime then return false end
    end

    for _, dep in ipairs(target.deps) do
        local dep_attr = lfs.attributes(dep.name)
        if not dep_attr then return false end
        if dep_attr.modification > out_mtime then return false end
    end

    return true
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
    return target:run()
end

function muh_ninja:target_compile(path, name, build_args, deps)
    return target.new("compile", {
        name = name,
        manifest = self.build.manifest,
        build_args = build_args,
        ins = { path },
        deps = deps,
    })
end

function muh_ninja:target_link(ins, name, build_args, deps)
    return target.new("link_exe", {
        name = name,
        manifest = self.build.manifest,
        build_args = build_args,
        ins = ins,
        deps = deps,
    })
end

function muh_ninja:target_archive(ins, name, deps)
    return target.new("archive", {
        name = name,
        manifest = self.build.manifest,
        build_args = {},
        ins = ins,
        deps = deps,
    })
end

local muh_cmake = {}
muh_cmake.__index = muh_cmake

function muh_cmake.new(b, ninja)
    local self = setmetatable({}, muh_cmake)
    self.build = b
    self.ninja = ninja
    self.packages = {} -- { name = { dir=, srcs={}, tests={} } }
    self.cmds = {}     -- { name = { dir=, src= } }
    return self
end

function muh_cmake:discover_packages()
    local function is_c_file(filename)
        return filename:match("%.c$") ~= nil
    end

    local function is_test_file(filename)
        return filename:match("_test%.c$") ~= nil
    end

    local internal_dir = path_join(PROJECT_PATH, "internal")
    for entry in lfs.dir(internal_dir) do
        if entry == "." or entry == ".." then goto continue_outer end

        local full = path_join(internal_dir, entry)
        local attr = lfs.attributes(full)
        if not attr or attr.mode ~= "directory" then goto continue_outer end

        local pkg = { name = entry, dir = full, srcs = {}, tests = {} }
        for file in lfs.dir(full) do
            if not is_c_file(file) then goto continue_inner end

            local fpath = path_join(full, file)
            if is_test_file(file) then
                pkg.tests[#pkg.tests + 1] = fpath
            else
                pkg.srcs[#pkg.srcs + 1] = fpath
            end

            ::continue_inner::
        end
        table.sort(pkg.srcs)
        table.sort(pkg.tests)
        self.packages[entry] = pkg

        ::continue_outer::
    end
end

function muh_cmake:discover_cmds()
    local cmd_dir = path_join(PROJECT_PATH, "cmd")
    for entry in lfs.dir(cmd_dir) do
        if entry == "." or entry == ".." then goto continue end

        local full = path_join(cmd_dir, entry)
        local attr = lfs.attributes(full)
        if not attr or attr.mode ~= "directory" then goto continue end

        local main_c = path_join(full, "main.c")
        if not lfs.attributes(main_c) then goto continue end

        self.cmds[entry] = { name = entry, dir = full, src = main_c }

        ::continue::
    end
end

function muh_cmake:generate()
    self:discover_packages()
    self:discover_cmds()

    local mn = self.build.manifest
    local raw_build_dir = mn.build_dir or "build"
    local build_dir
    if build.is_absolute(raw_build_dir) then
        build_dir = raw_build_dir
    else
        build_dir = path_join(PROJECT_PATH, raw_build_dir)
    end
    local common_cflags = { "-I" .. PROJECT_PATH }

    local all_lib_targets = {}
    local named = {}
    local default_targets = {}

    local pkg_names = sorted_keys(self.packages)

    for _, name in ipairs(pkg_names) do
        local pkg = self.packages[name]
        local obj_targets = {}
        local obj_paths = {}

        for _, src in ipairs(pkg.srcs) do
            local basename = src:match("([^/\\]+)%.c$")
            local obj_path = path_join(build_dir, "objs", "internal", name, basename .. ".o")
            local t = self.ninja:target_compile(src, obj_path, common_cflags, {})
            obj_targets[#obj_targets + 1] = t
            obj_paths[#obj_paths + 1] = obj_path
        end

        if #obj_paths > 0 then
            local lib_path = path_join(build_dir, "lib", "lib" .. name .. ".a")
            local lib_t = self.ninja:target_archive(obj_paths, lib_path, obj_targets)
            all_lib_targets[#all_lib_targets + 1] = lib_t
            named["lib:" .. name] = { target = lib_t, kind = "lib" }
        end
    end

    local cmd_names = sorted_keys(self.cmds)

    for _, name in ipairs(cmd_names) do
        local cmd_info = self.cmds[name]
        local obj_path = path_join(build_dir, "objs", "cmd", name, "main.o")
        local main_t = self.ninja:target_compile(cmd_info.src, obj_path, common_cflags, {})

        local link_ins = { obj_path }
        local link_deps = { main_t }
        for _, lib_t in ipairs(all_lib_targets) do
            link_ins[#link_ins + 1] = lib_t.name
            link_deps[#link_deps + 1] = lib_t
        end

        local exe_path = path_join(build_dir, "bin", name)
        local exe_t = self.ninja:target_link(link_ins, exe_path, {}, link_deps)
        local tname = "cmd:" .. name
        named[tname] = { target = exe_t, kind = "cmd" }
        default_targets[#default_targets + 1] = { name = tname, target = exe_t }
    end

    for _, name in ipairs(pkg_names) do
        local pkg = self.packages[name]
        for _, test_src in ipairs(pkg.tests) do
            local basename = test_src:match("([^/\\]+)%.c$")
            local obj_path = path_join(build_dir, "objs", "internal", name, basename .. ".o")
            local test_obj_t = self.ninja:target_compile(test_src, obj_path, common_cflags, {})

            local link_ins = { obj_path }
            local link_deps = { test_obj_t }
            for _, lib_t in ipairs(all_lib_targets) do
                link_ins[#link_ins + 1] = lib_t.name
                link_deps[#link_deps + 1] = lib_t
            end

            local test_exe_path = path_join(build_dir, "bin", basename)
            local test_t = self.ninja:target_link(link_ins, test_exe_path, {}, link_deps)
            local test_pkg = basename:match("^(.+)_test$") or basename
            local tname = "test:" .. test_pkg
            named[tname] = { target = test_t, kind = "test" }
            default_targets[#default_targets + 1] = { name = tname, target = test_t }
        end
    end

    return {
        named = named,
        defaults = default_targets,
    }
end

local b = build.new()
b:parse_args()

local ninja = muh_ninja.new(b)
local cmake = muh_cmake.new(b, ninja)
local targets = cmake:generate()

if b.mode == "list" then
    local names = sorted_keys(targets.named)
    for _, name in ipairs(names) do
        print(name)
    end
    os.exit(0)
end

if b.target then
    local entry = targets.named[b.target]
    assert(entry, "Unknown target '" .. b.target .. "'. Use --list to see available targets.")
    if not muh_ninja.run(entry.target) then
        print("FAIL: " .. entry.target.name)
        os.exit(1)
    end
else
    for _, dt in ipairs(targets.defaults) do
        if not muh_ninja.run(dt.target) then
            print("FAIL: " .. dt.target.name)
            os.exit(1)
        end
    end
end
