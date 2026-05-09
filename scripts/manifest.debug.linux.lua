local SDL3_VERSION = "3.4.8"
local SDL3_SRC     = "vendor/SDL3-" .. SDL3_VERSION
local BUILD        = "build"
local SDL3_OUT     = BUILD .. "/vendor/SDL3"

local CC     = "clang"
local CFLAGS = "-O0 -g --std=c99 -Wall -Wextra"
local AR     = "ar"
local ARFLAGS = "rcs"

---@type Manifest
local manifest     = {
    build_dir   = BUILD,

    --- Default install prefix (relative to project root).
    --- Can be overridden with --prefix on the CLI.
    install_prefix = BUILD .. "/install",

    --- Install rules: each entry maps a source path (relative to build_dir)
    --- to a destination path (relative to install prefix).
    ---@type {src: string, dest: string}[]
    install_rules = {
        { src = "bin/game", dest = "bin/game" },
    },

    --- Project-level system link flags (OS-specific).
    --- These are appended once at the end of every link command.
    system_libs = { "-lm", "-ldl", "-lpthread" },

    ---@param vl VendorLibCmake
    ---@param src string
    ---@param out_dir string
    ---@return string
    cmake_lib_cmd = function(vl, src, out_dir)
        local configure = "cmake -S " .. src .. " -B " .. out_dir
        for _, a in ipairs(vl.cmake_args) do
            configure = configure .. " " .. a
        end

        local build = "cmake --build " .. out_dir .. " --parallel"
        if vl.cmake_build_target then
            build = build .. " --target " .. vl.cmake_build_target
        end

        return configure .. " && " .. build
    end,

    compile_cmd = function(out, src, extra_args)
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

    link_cmd = function(out, ins, extra_args)
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

    archive_cmd = function(out, ins)
        local parts = { AR, ARFLAGS, out }
        for _, i in ipairs(ins) do
            parts[#parts + 1] = i
        end
        return table.concat(parts, " ")
    end,

    ---@type VendorLibCmake[]
    vendor_libs = {
        {
            kind                  = "cmake",
            name                  = "SDL3",
            version               = SDL3_VERSION,
            cmake_minimum_version = "3.16",
            src                   = SDL3_SRC,
            out                   = SDL3_OUT,
            cmake_args            = {
                "-DCMAKE_BUILD_TYPE=Debug",
                "-DSDL_SHARED=OFF",
                "-DSDL_STATIC=ON",
                "-DSDL_TEST_LIBRARY=OFF",
                "-DSDL_TESTS=OFF",
                "-DSDL_EXAMPLES=OFF",
                "-DSDL_INSTALL=OFF",
            },
            sentinel              = SDL3_OUT .. "/libSDL3.a",
            include_dirs          = {
                SDL3_SRC .. "/include",
                SDL3_OUT .. "/include-revision",
            },
            static_libs           = { SDL3_OUT .. "/libSDL3.a" },
        },
    },
}

return manifest
