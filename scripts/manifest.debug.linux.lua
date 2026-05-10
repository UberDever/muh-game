local SDL3_VERSION  = "3.4.8"
local SDL3_SRC      = "vendor/SDL3-" .. SDL3_VERSION
local LUA_VERSION   = "5.5.0"
local LUA_SRC       = "vendor/lua-" .. LUA_VERSION
local BUILD         = "build"
local LUA_OUT       = BUILD .. "/vendor/lua"
local SDL3_OUT      = BUILD .. "/vendor/SDL3"

local CC            = "clang"
local CFLAGS        = "-O0 -g --std=c99 -Wall -Wextra"
local AR            = "ar"
local ARFLAGS       = "rcs"

--- Build a cmake configure+build command string.
---@param cmake_args string[]
---@param build_target string?
---@param src string
---@param out_dir string
---@return string
local function cmake_lib_cmd(cmake_args, build_target, src, out_dir)
    local configure = "cmake -S " .. src .. " -B " .. out_dir
    for _, a in ipairs(cmake_args) do
        configure = configure .. " " .. a
    end

    local build = "cmake --build " .. out_dir .. " --parallel"
    if build_target then
        build = build .. " --target " .. build_target
    end

    return configure .. " && " .. build
end

---@type Manifest
local manifest      = {
    build_dir      = BUILD,

    --- Default install prefix (relative to project root).
    --- Can be overridden with --prefix on the CLI.
    install_prefix = BUILD .. "/install",

    --- Install rules: each entry maps a source path (relative to build_dir)
    --- to a destination path (relative to install prefix).
    ---@type {src: string, dest: string}[]
    install_rules  = {
        { src = "bin/game", dest = "bin/game" },
    },

    ---@param infra Infra
    preconfigure   = function(infra)
        -- NOTE: this check is excessive, of course, but it proves the architecture of build/manifest system
        local CMAKE_MIN_VERSION = "3.16" -- required by SDL3 CMakeLists.txt
        local installed = infra.get_tool_version("cmake")
        assert(installed, "cmake not found; required to build vendor libs")
        local cmp = infra.compare_versions(
            infra.parse_version(installed),
            infra.parse_version(CMAKE_MIN_VERSION))
        assert(cmp >= 0,
            "cmake " .. installed .. " too old; need >= " .. CMAKE_MIN_VERSION)
    end,

    ---@param infra Infra
    postconfigure  = function(infra)
        -- NOTE: placeholder for symmetry
    end,

    compile_cmd    = function(out, src, extra_args)
        local parts = { CC, CFLAGS }
        for _, a in ipairs(extra_args or {}) do
            parts[#parts + 1] = a
        end
        parts[#parts + 1] = "-c"
        parts[#parts + 1] = src
        parts[#parts + 1] = "-o"
        parts[#parts + 1] = out
        return table.concat(parts, " ")
    end,

    link_cmd       = function(out, ins, extra_args)
        local parts = { CC }
        for _, i in ipairs(ins) do
            parts[#parts + 1] = i
        end
        parts[#parts + 1] = "-o"
        parts[#parts + 1] = out
        for _, a in ipairs(extra_args or {}) do
            parts[#parts + 1] = a
        end
        return table.concat(parts, " ")
    end,

    archive_cmd    = function(out, ins)
        local parts = { AR, ARFLAGS, out }
        for _, i in ipairs(ins) do
            parts[#parts + 1] = i
        end
        return table.concat(parts, " ")
    end,

    ---@type VendorLib[]
    vendor_libs    = {
        {
            name         = "lua",
            version      = LUA_VERSION,
            src          = LUA_SRC,
            out          = LUA_OUT,
            ---@param src string
            ---@param out_dir string
            ---@param args any[]
            ---@return string
            build_cmd    = function(src, out_dir, args)
                return "make -B -C " .. src .. " all"
                    .. " && cp " .. src .. "/liblua.a " .. out_dir .. "/liblua.a"
            end,
            ---@param src string
            ---@return string
            clean_cmd    = function(src)
                return "make -C " .. src .. " clean"
            end,
            sentinel     = LUA_OUT .. "/liblua.a",
            include_dirs = { LUA_SRC },
            static_libs  = { LUA_OUT .. "/liblua.a" },
        },
        {
            name         = "SDL3",
            version      = SDL3_VERSION,
            src          = SDL3_SRC,
            out          = SDL3_OUT,
            ---@param src string
            ---@param out_dir string
            ---@param args any[]
            ---@return string
            build_cmd    = function(src, out_dir, args)
                return cmake_lib_cmd({
                    "-DCMAKE_BUILD_TYPE=Debug",
                    "-DSDL_SHARED=OFF",
                    "-DSDL_STATIC=ON",
                    "-DSDL_TEST_LIBRARY=OFF",
                    "-DSDL_TESTS=OFF",
                    "-DSDL_EXAMPLES=OFF",
                    "-DSDL_INSTALL=OFF",
                }, nil, src, out_dir)
            end,
            sentinel     = SDL3_OUT .. "/libSDL3.a",
            include_dirs = {
                SDL3_SRC .. "/include",
                SDL3_OUT .. "/include-revision",
            },
            static_libs  = { SDL3_OUT .. "/libSDL3.a" },
        },
    },

    --- Project-level system link flags (OS-specific).
    --- These are appended once at the end of every link command.
    system_libs    = { "-lm", "-ldl", "-lpthread" },
}

return manifest
