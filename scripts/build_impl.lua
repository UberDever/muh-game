-- build_impl.lua — Shared infrastructure for the build system and its tests.
--
-- Returns a table with path utilities, lfs bootstrap, filesystem helpers,
-- and resolved project paths.  Both build.lua and build_test.lua require
-- this module to avoid duplicating bootstrap and utility code.

local os = require "os"
local io = require "io"

---@class BuildImpl
local M = {}

-- ── Platform detection ─────────────────────────────────────────────────────

M.OS_SEP  = package.config:sub(1, 1)
M.IS_UNIX = M.OS_SEP == "/"

-- ── Path utilities ─────────────────────────────────────────────────────────

---@param ... string
---@return string
function M.path_join(...)
    local args = { ... }
    local sep = M.OS_SEP
    return (table.concat(args, sep):gsub(sep .. sep .. "+", sep))
end

---@param p string
---@return string
function M.path_normalize(p)
    local parts = {}
    for seg in p:gmatch("[^/\\]+") do
        if seg == ".." and #parts > 0 and parts[#parts] ~= ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    local result = table.concat(parts, M.OS_SEP)
    if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then
        result = M.OS_SEP .. result
    end
    return result
end

---@param t table
---@return string[]
function M.sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

---@param path string
---@return boolean
function M.is_absolute(path)
    return path:sub(1, 1) == "/"
        or path:match("^%a:[/\\]") ~= nil
        or path:match("^[/\\][/\\]") ~= nil
end

---@param base string
---@param p string
---@return string
function M.resolve_path(base, p)
    if M.is_absolute(p) then return p end
    return M.path_join(base, p)
end

---@param path string
---@return string?
function M.parent_dir(path)
    return path:match("(.*)[/\\][^/\\]+$")
end

-- ── CWD / script path resolution ──────────────────────────────────────────

local function get_cwd_portable()
    local cmd = M.IS_UNIX and "pwd" or "cd"
    local h = io.popen(cmd)
    if not h then return nil end
    local cwd = h:read("*l")
    h:close()
    return cwd
end

local function get_script_dir()
    local script = arg[0]
    if not M.is_absolute(script) then
        local cwd = get_cwd_portable()
        assert(cwd, "Cannot determine working directory")
        script = M.path_join(cwd, script)
    end
    return script:match("(.*[/\\])") or ""
end

M.SCRIPT_DIR   = get_script_dir()
M.PROJECT_PATH = M.path_normalize(M.path_join(M.SCRIPT_DIR, ".."))

-- ── lfs bootstrap ──────────────────────────────────────────────────────────

local LFS_EXT = M.IS_UNIX and "so" or "dll"

do
    local lfs_dir = M.path_join(M.PROJECT_PATH, "vendor", "lfs")
    local lfs_lib = M.path_join(lfs_dir, "lfs." .. LFS_EXT)
    local lfs_src = M.path_join(lfs_dir, "lfs.c")
    local lua_inc = M.path_join(M.PROJECT_PATH, "vendor", "lua-5.5.0")

    local f = io.open(lfs_lib, "r")
    if not f then
        local cmd
        if M.IS_UNIX then
            cmd = string.format("cc -shared -fPIC -O2 -o %s %s -I%s -I%s",
                lfs_lib, lfs_src, lfs_dir, lua_inc)
        else
            cmd = string.format("cl /LD /O2 /I%s /I%s %s /Fe:%s",
                lfs_dir, lua_inc, lfs_src, lfs_lib)
        end
        print("bootstrap lfs: " .. cmd)
        local ok, _, code = os.execute(cmd)
        assert(ok, "Failed to compile lfs (exit " .. tostring(code) .. ")")
    else
        f:close()
    end
    package.cpath = M.path_join(lfs_dir, "?." .. LFS_EXT) .. ";" .. package.cpath
end

M.lfs = require "lfs"

-- ── Filesystem helpers (use lfs, no shell commands) ────────────────────────

---@param path string?
function M.mkdir_p(path)
    if not path or path == "" then return end
    local attr = M.lfs.attributes(path)
    if attr and attr.mode == "directory" then return end
    M.mkdir_p(M.parent_dir(path))
    M.lfs.mkdir(path)
end

--- Recursively remove a file or directory tree. Returns true if something existed.
---@param path string
---@return boolean
function M.rmdir_rf(path)
    local attr = M.lfs.attributes(path)
    if not attr then return false end
    if attr.mode == "directory" then
        for entry in M.lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                M.rmdir_rf(M.path_join(path, entry))
            end
        end
        M.lfs.rmdir(path)
    else
        os.remove(path)
    end
    return true
end

---@param filepath string
function M.ensure_parent_dir(filepath)
    local dir = M.parent_dir(filepath)
    if dir then M.mkdir_p(dir) end
end

--- Copy a file from src to dest (binary-safe).
--- Creates parent directories for dest as needed.
---@param src string
---@param dest string
---@return boolean ok
---@return string? err
function M.copy_file(src, dest)
    local fin, err_in = io.open(src, "rb")
    if not fin then return false, "cannot open source: " .. (err_in or src) end
    M.ensure_parent_dir(dest)
    local fout, err_out = io.open(dest, "wb")
    if not fout then fin:close(); return false, "cannot open dest: " .. (err_out or dest) end
    local chunk_size = 64 * 1024
    while true do
        local chunk = fin:read(chunk_size)
        if not chunk then break end
        fout:write(chunk)
    end
    fin:close()
    fout:close()
    return true, nil
end

--- Touch a file: update its modification time without altering content.
---@param path string
function M.touch_file(path)
    if M.lfs.touch then
        M.lfs.touch(path)
    else
        local fh = io.open(path, "a")
        if fh then fh:close() end
    end
end

--- Sleep for approximately `seconds` seconds.
---@param seconds number
function M.sleep(seconds)
    if M.IS_UNIX then
        os.execute("sleep " .. seconds)
    else
        os.execute("ping -n " .. (seconds + 1) .. " 127.0.0.1 >nul 2>&1")
    end
end

---@param s string
---@return string
function M.json_escape(s)
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

return M
