local os           = require "os"
local io           = require "io"

-- Add the script's own directory to package.path so require("build_impl") works
-- regardless of the working directory.
local _script_dir  = (arg[0]:match("(.*[/\\])") or "./")
package.path       = _script_dir .. "?.lua;" .. package.path

local impl         = require "build_impl"

local path_join    = impl.path_join
local sorted_keys  = impl.sorted_keys
local PROJECT_PATH = impl.PROJECT_PATH
local lfs          = impl.lfs
local json_escape  = impl.json_escape
local resolve_path = impl.resolve_path

---@class VendorLibCmake
---@field kind "cmake"
---@field name string
---@field version string
---@field cmake_minimum_version string
---@field src string
---@field out string
---@field cmake_args string[]
---@field cmake_build_target string?
---@field sentinel string
---@field include_dirs string[]
---@field static_libs string[]

---@class InstallRule
---@field src string   Path relative to build_dir
---@field dest string  Path relative to install prefix

-- NOTE: see manifests in the adjacent folder for examples
---@class Manifest
---@field build_dir string
---@field system_libs string[]?
---@field install_prefix string?
---@field install_rules InstallRule[]?
---@field compile_cmd fun(out: string, src: string, extra_args: string[]): string
---@field link_cmd fun(out: string, ins: string[], extra_args: string[]): string
---@field archive_cmd fun(out: string, ins: string[]): string
---@field cmake_lib_cmd fun(vl: VendorLibCmake, src: string, out_dir: string): string
---@field vendor_libs VendorLibCmake[]?

---@alias Subcommand "build"|"list"|"clean"|"compiledb"|"install"|"help"

---@class Infra
---@field manifest Manifest?
---@field target string?
---@field subcommand Subcommand
---@field prefix string?
local Infra        = {}
Infra.__index      = Infra
Infra.path_join    = path_join
Infra.PROJECT_PATH = PROJECT_PATH

local SUBCOMMANDS  = {
    build = true,
    list = true,
    clean = true,
    compiledb = true,
    install = true,
    help = true,
}

function Infra.print_usage()
    print([[
Usage: lua scripts/build.lua <command> [options]

Commands:
  build      Build targets (default if no command given)
  list       List available targets and exit
  clean      Remove build artifacts (all or specific -t target)
  compiledb  Regenerate compile_commands.json and exit
  install    Build default targets and install per manifest rules
  help       Show this help and exit

Options:
  -m, --manifest <path>   Path to manifest file (required for all commands except help)
  -t, --target <name>     Build/clean a single target (e.g. cmd:game, lib:game, vendor:SDL3)
  -p, --prefix <path>     Override path prefix (build_dir for build/clean, install_prefix for install)]])
end

---@return Infra
function Infra.new()
    local self = setmetatable({}, Infra)
    self.manifest = nil
    self.target = nil
    self.subcommand = "build"
    self.prefix = nil
    return self
end

function Infra:parse_args()
    ---@param cur_arg integer
    ---@param flag string
    ---@return string value, integer next_arg
    local function consume_flag_value(cur_arg, flag)
        cur_arg = cur_arg + 1
        assert(cur_arg <= #arg, "Expected value for flag '" .. flag .. "'")
        return arg[cur_arg], cur_arg + 1
    end

    local cur_arg = 1

    -- First positional argument is the subcommand (if it doesn't start with '-')
    if arg[cur_arg] and not arg[cur_arg]:match("^%-") then
        local subcmd = arg[cur_arg]
        if not SUBCOMMANDS[subcmd] then
            local names = sorted_keys(SUBCOMMANDS)
            error("Unknown command '" .. subcmd
                .. "'. Available: " .. table.concat(names, ", "))
        end
        self.subcommand = subcmd
        cur_arg = cur_arg + 1
    end

    -- Parse remaining flags
    while arg[cur_arg] do
        local flag = arg[cur_arg]

        if flag == "--manifest" or flag == "-m" then
            local val; val, cur_arg = consume_flag_value(cur_arg, flag)
            if not impl.is_absolute(val) then
                val = lfs.currentdir() .. impl.OS_SEP .. val
            end
            self.manifest = dofile(val)
        elseif flag == "--target" or flag == "-t" then
            self.target, cur_arg = consume_flag_value(cur_arg, flag)
        elseif flag == "--prefix" or flag == "-p" then
            self.prefix, cur_arg = consume_flag_value(cur_arg, flag)
        else
            error("Unknown flag '" .. flag .. "'")
        end
    end

    if self.subcommand == "help" then
        Infra.print_usage()
        os.exit(0)
    end

    assert(self.manifest, "Manifest is required. Use -m <path> to specify a manifest file.")

    -- In non-install modes, --prefix overrides manifest build_dir
    if self.prefix and self.subcommand ~= "install" then
        self.manifest.build_dir = self.prefix
    end
end

-- ── Target ─────────────────────────────────────────────────────────────────

---@class Target
---@field name string           Output path (file or sentinel)
---@field ins string[]          Input paths (source files, object files, etc.)
---@field deps Target[]         Targets that must be built first
---@field command fun(name: string, ins: string[]): string   Returns shell command string
---@field clean_fn (fun(name: string))?  Non-standard cleanup (e.g. rmdir)
---@field tag string            Label for printing ("compile", "archive", etc.)
local Target = {}
Target.__index = Target

function Target.new(fields)
    local self = setmetatable({}, Target)
    self.name = assert(fields.name, "target missing 'name'")
    self.ins = fields.ins or {}
    self.deps = fields.deps or {}
    self.command = assert(fields.command, "target missing 'command'")
    self.clean_fn = fields.clean
    self.tag = fields.tag or "build"
    return self
end

---@return boolean
function Target:run()
    impl.ensure_parent_dir(self.name)
    local cmd_str = self.command(self.name, self.ins)
    print(self.tag .. ": " .. cmd_str)
    local ok = os.execute(cmd_str)
    return ok ~= nil
end

-- ── MuhNinja ───────────────────────────────────────────────────────────────

---@class MuhNinja
---@field manifest Manifest
local MuhNinja = {}
MuhNinja.__index = MuhNinja

---@param mn Manifest
---@return MuhNinja
function MuhNinja.new(mn)
    local self = setmetatable({}, MuhNinja)
    self.manifest = mn
    return self
end

---@param tgt Target
---@return boolean
function MuhNinja.already_built(tgt)
    local out_attr = lfs.attributes(tgt.name)
    if not out_attr then return false end

    -- No inputs → existence-only check
    if #tgt.ins == 0 then return true end

    local out_mtime = out_attr.modification

    for _, src in ipairs(tgt.ins) do
        local in_attr = lfs.attributes(src)
        if not in_attr then return false end
        if in_attr.modification > out_mtime then return false end
    end

    for _, dep in ipairs(tgt.deps) do
        local dep_attr = lfs.attributes(dep.name)
        if not dep_attr then return false end
        if dep_attr.modification > out_mtime then return false end
    end

    return true
end

---@param root Target
---@return Target[]
function MuhNinja.topo_sort(root)
    local order = {}
    local visited = {}
    local function visit(node)
        if visited[node] then return end
        visited[node] = true
        for i = 1, #node.deps do
            visit(node.deps[i])
        end
        order[#order + 1] = node
    end
    visit(root)
    return order
end

---@param root Target
---@return boolean
function MuhNinja.run(root)
    local order = MuhNinja.topo_sort(root)
    for i = 1, #order do
        local node = order[i]
        if not MuhNinja.already_built(node) then
            if not node:run() then return false end
        end
    end
    return true
end

---@param root Target
function MuhNinja.clean(root)
    local order = MuhNinja.topo_sort(root)
    for i = #order, 1, -1 do
        local node = order[i]
        if node.clean_fn then
            node.clean_fn(node.name)
        else
            if os.remove(node.name) then
                print("rm: " .. node.name)
            end
        end
    end
end

-- ── Target constructors ────────────────────────────────────────────────────

---@param src string
---@param out string
---@param extra_args string[]
---@param deps Target[]
---@return Target
function MuhNinja:target_compile(src, out, extra_args, deps)
    local mn = self.manifest
    return Target.new({
        name = out,
        ins = { src },
        deps = deps,
        tag = "compile",
        command = function(name, ins)
            return mn.compile_cmd(name, ins[1], extra_args)
        end,
    })
end

---@param ins string[]
---@param out string
---@param extra_args string[]
---@param deps Target[]
---@return Target
function MuhNinja:target_link(ins, out, extra_args, deps)
    local mn = self.manifest
    return Target.new({
        name = out,
        ins = ins,
        deps = deps,
        tag = "link_exe",
        command = function(name, the_ins)
            return mn.link_cmd(name, the_ins, extra_args)
        end,
    })
end

---@param ins string[]
---@param out string
---@param deps Target[]
---@return Target
function MuhNinja:target_archive(ins, out, deps)
    local mn = self.manifest
    return Target.new({
        name = out,
        ins = ins,
        deps = deps,
        tag = "archive",
        command = function(name, the_ins)
            os.remove(name)
            return mn.archive_cmd(name, the_ins)
        end,
    })
end

---@param vl VendorLibCmake
---@return Target
function MuhNinja:target_cmake_lib(vl)
    local mn = self.manifest

    ---@param s string
    ---@return integer[]
    local function parse_version(s)
        local parts = {}
        for n in s:gmatch("(%d+)") do
            parts[#parts + 1] = tonumber(n)
        end
        return parts
    end

    ---@param a integer[]
    ---@param b integer[]
    ---@return -1|0|1
    local function compare_versions(a, b)
        local len = math.max(#a, #b)
        for i = 1, len do
            local va = a[i] or 0
            local vb = b[i] or 0
            if va < vb then return -1 end
            if va > vb then return 1 end
        end
        return 0
    end

    ---@param tool_cmd string
    ---@return string?
    local function get_tool_version(tool_cmd)
        local h = io.popen(tool_cmd .. " --version 2>/dev/null")
        if not h then return nil end
        local line = h:read("*l")
        h:close()
        if not line then return nil end
        return line:match("(%d+%.%d+[%.%d]*)")
    end

    --- Convenience wrapper: get the installed cmake version string.
    ---@return string?
    local function get_cmake_version()
        return get_tool_version("cmake")
    end

    ---@param vl2 VendorLibCmake
    local function check_cmake_version(vl2)
        if not vl2.cmake_minimum_version then return end
        local installed = get_cmake_version()
        assert(installed,
            "cmake not found. Vendor lib '" .. vl2.name .. "' requires cmake >= " .. vl2.cmake_minimum_version)
        local inst_parts = parse_version(installed)
        local req_parts = parse_version(vl2.cmake_minimum_version)
        assert(compare_versions(inst_parts, req_parts) >= 0,
            "cmake version " .. installed .. " is too old for vendor lib '" .. vl2.name
            .. "'. Required >= " .. vl2.cmake_minimum_version)
    end

    local sentinel = path_join(PROJECT_PATH, vl.sentinel)
    local out_dir = path_join(PROJECT_PATH, vl.out)
    return Target.new({
        name = sentinel,
        ins = {},
        deps = {},
        tag = "cmake_lib",
        command = function(_, _)
            check_cmake_version(vl)
            local src = path_join(PROJECT_PATH, vl.src)
            impl.mkdir_p(out_dir)
            return mn.cmake_lib_cmd(vl, src, out_dir)
        end,
        clean = function(_)
            if impl.rmdir_rf(out_dir) then
                print("rmdir: " .. out_dir)
            end
        end,
    })
end

-- ── MuhCmake (project graph builder) ───────────────────────────────────────

---@class NamedEntry
---@field target Target
---@field kind string
---@field vendor_lib VendorLibCmake?

---@class TargetsResult
---@field named table<string, NamedEntry>
---@field defaults {name: string, target: Target}[]
---@field compile_targets Target[]
---@field build_dir string

---@class MuhCmake
---@field manifest Manifest
---@field ninja MuhNinja
---@field packages table<string, {name: string, dir: string, srcs: string[], tests: string[]}>
---@field cmds table<string, {name: string, dir: string, src: string}>
local MuhCmake = {}
MuhCmake.__index = MuhCmake

---@param mn Manifest
---@param ninja MuhNinja
---@return MuhCmake
function MuhCmake.new(mn, ninja)
    local self = setmetatable({}, MuhCmake)
    self.manifest = mn
    self.ninja = ninja
    self.packages = {}
    self.cmds = {}
    return self
end

---@param mn Manifest
---@return string[] vendor_cflags
---@return string[] vendor_static_libs
---@return string[] link_flags
function MuhCmake.resolve_vendor_flags(mn)
    local vendor_cflags = {}
    local vendor_static_libs = {}
    local link_flags = {}
    local seen_flags = {}
    if mn.vendor_libs then
        for _, vl in ipairs(mn.vendor_libs) do
            if vl.include_dirs then
                for _, d in ipairs(vl.include_dirs) do
                    vendor_cflags[#vendor_cflags + 1] = "-I" .. path_join(PROJECT_PATH, d)
                end
            end
            if vl.static_libs then
                for _, lib in ipairs(vl.static_libs) do
                    vendor_static_libs[#vendor_static_libs + 1] = path_join(PROJECT_PATH, lib)
                end
            end
        end
    end
    if mn.system_libs then
        for _, flag in ipairs(mn.system_libs) do
            if not seen_flags[flag] then
                seen_flags[flag] = true
                link_flags[#link_flags + 1] = flag
            end
        end
    end
    return vendor_cflags, vendor_static_libs, link_flags
end

---@param mn Manifest
---@return table<string, NamedEntry> vendor_named
---@return Target[] cmake_targets
function MuhCmake:resolve_vendor_targets(mn)
    local vendor_named = {}
    local vendor_targets = {}
    if not mn.vendor_libs then return vendor_named, vendor_targets end
    for _, vl in ipairs(mn.vendor_libs) do
        if vl.kind == "cmake" then
            local tname = "vendor:" .. vl.name
            local tgt = self.ninja:target_cmake_lib(vl)
            vendor_named[tname] = {
                target = tgt,
                kind = "vendor",
                vendor_lib = vl,
            }
            vendor_targets[#vendor_targets + 1] = tgt
        else
            error("Not implemented " .. vl.kind)
        end
    end
    return vendor_named, vendor_targets
end

function MuhCmake:discover_packages()
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

function MuhCmake:discover_cmds()
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

---@param obj_path string
---@param obj_target Target
---@param all_lib_targets Target[]
---@param cmake_targets Target[]
---@param vendor_static_libs string[]
---@return string[] link_ins
---@return Target[] link_deps
local function assemble_link_deps(obj_path, obj_target, all_lib_targets, cmake_targets, vendor_static_libs)
    local link_ins = { obj_path }
    local link_deps = { obj_target }
    for _, lib_t in ipairs(all_lib_targets) do
        link_ins[#link_ins + 1] = lib_t.name
        link_deps[#link_deps + 1] = lib_t
    end
    for _, cmake_t in ipairs(cmake_targets) do
        link_deps[#link_deps + 1] = cmake_t
    end
    for _, vsl in ipairs(vendor_static_libs) do
        link_ins[#link_ins + 1] = vsl
    end
    return link_ins, link_deps
end

---@return TargetsResult
function MuhCmake:generate()
    self:discover_packages()
    self:discover_cmds()

    local mn = self.manifest
    local build_dir = resolve_path(PROJECT_PATH, mn.build_dir or "build")

    local vendor_cflags, vendor_static_libs, vendor_link_flags = MuhCmake.resolve_vendor_flags(mn)

    local common_cflags = { "-I" .. PROJECT_PATH }
    for _, vf in ipairs(vendor_cflags) do
        common_cflags[#common_cflags + 1] = vf
    end

    local all_lib_targets = {}
    local named = {}
    local default_targets = {}
    local compile_targets = {}

    local vendor_named, vendor_targets = self:resolve_vendor_targets(mn)
    for k, v in pairs(vendor_named) do
        named[k] = v
    end

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
            compile_targets[#compile_targets + 1] = t
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
        compile_targets[#compile_targets + 1] = main_t

        local link_ins, link_deps = assemble_link_deps(
            obj_path, main_t, all_lib_targets, vendor_targets, vendor_static_libs)

        local exe_path = path_join(build_dir, "bin", name)
        local exe_t = self.ninja:target_link(link_ins, exe_path, vendor_link_flags, link_deps)
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
            compile_targets[#compile_targets + 1] = test_obj_t

            local link_ins, link_deps = assemble_link_deps(
                obj_path, test_obj_t, all_lib_targets, vendor_targets, vendor_static_libs)

            local test_exe_path = path_join(build_dir, "bin", basename)
            local test_t = self.ninja:target_link(link_ins, test_exe_path, vendor_link_flags, link_deps)
            local test_pkg = basename:match("^(.+)_test$") or basename
            local tname = "test:" .. test_pkg
            named[tname] = { target = test_t, kind = "test" }
            default_targets[#default_targets + 1] = { name = tname, target = test_t }
        end
    end

    return {
        named = named,
        defaults = default_targets,
        compile_targets = compile_targets,
        build_dir = build_dir,
    }
end

---@param targets_result TargetsResult
function MuhCmake.write_compile_commands(targets_result)
    local compile_targets = targets_result.compile_targets
    local build_dir = targets_result.build_dir

    local entries = {}
    for _, t in ipairs(compile_targets) do
        local cmd_str = t.command(t.name, t.ins) --[[@as string]]

        local args = {}
        for word in cmd_str:gmatch("%S+") do
            args[#args + 1] = word
        end

        local args_json = {}
        for _, a in ipairs(args) do
            args_json[#args_json + 1] = '"' .. json_escape(a) .. '"'
        end

        entries[#entries + 1] = string.format(
            '  {\n    "directory": "%s",\n    "file": "%s",\n    "arguments": [%s],\n    "output": "%s"\n  }',
            json_escape(PROJECT_PATH),
            json_escape(t.ins[1]),
            table.concat(args_json, ", "),
            json_escape(t.name)
        )
    end

    local json = "[\n" .. table.concat(entries, ",\n") .. "\n]\n"
    local out_path = path_join(build_dir, "compile_commands.json")
    impl.mkdir_p(build_dir)
    local fh = io.open(out_path, "w")
    assert(fh, "Cannot open " .. out_path)
    fh:write(json)
    fh:close()
    print("wrote: " .. out_path)
end

---@param defaults {name: string, target: Target}[]
---@return boolean
local function run_defaults(defaults)
    for _, dt in ipairs(defaults) do
        if not MuhNinja.run(dt.target) then
            print("FAIL: " .. dt.target.name)
            os.exit(1)
        end
    end
    return true
end

--- Install built artifacts according to manifest install_rules.
--- Builds all default targets first, then copies files.
---@param targets TargetsResult
---@param mn Manifest
---@param prefix string?  Override install prefix (nil = use manifest default)
function MuhCmake.install(targets, mn, prefix)
    run_defaults(targets.defaults)

    local rules = mn.install_rules
    assert(rules and #rules > 0, "No install_rules defined in manifest")

    -- Resolve install prefix: explicit > manifest install_prefix > build_dir/install
    prefix = prefix
        or mn.install_prefix
        or (mn.build_dir or "build") .. "/install"
    prefix = resolve_path(PROJECT_PATH, prefix)

    for _, rule in ipairs(rules) do
        local src_path = path_join(targets.build_dir, rule.src)
        local dest_path = path_join(prefix, rule.dest)
        local ok, err = impl.copy_file(src_path, dest_path)
        if ok then
            print("install: " .. src_path .. " -> " .. dest_path)
        else
            error("install failed: " .. (err or "unknown error"))
        end
    end
end

-- ── Main ───────────────────────────────────────────────────────────────────

local b = Infra.new()
b:parse_args()

local ninja = MuhNinja.new(b.manifest)
local cmake = MuhCmake.new(b.manifest, ninja)
local targets = cmake:generate()

if b.subcommand == "build" or b.subcommand == "compiledb" or b.subcommand == "install" then
    MuhCmake.write_compile_commands(targets)
end

if b.subcommand == "list" then
    local names = sorted_keys(targets.named)
    for _, name in ipairs(names) do
        print(name)
    end
    os.exit(0)
elseif b.subcommand == "compiledb" then
    os.exit(0)
elseif b.subcommand == "clean" then
    if b.target then
        local entry = targets.named[b.target]
        assert(entry, "Unknown target '" .. b.target .. "'. Use 'list' command to see available targets.")
        MuhNinja.clean(entry.target)
    else
        for _, dt in ipairs(targets.defaults) do
            MuhNinja.clean(dt.target)
        end
    end
    os.exit(0)
elseif b.subcommand == "install" then
    MuhCmake.install(targets, b.manifest, b.prefix)
    os.exit(0)
elseif b.target then
    local entry = targets.named[b.target]
    assert(entry, "Unknown target '" .. b.target .. "'. Use 'list' command to see available targets.")
    if not MuhNinja.run(entry.target) then
        print("FAIL: " .. entry.target.name)
        os.exit(1)
    end
else
    run_defaults(targets.defaults)
end
