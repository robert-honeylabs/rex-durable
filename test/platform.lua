-- Checks durable.lua's process and file helpers against real processes, with
-- plain Lua 5.1 and no Rex: a stand-in rex.exec runs commands with io.popen.
-- Used on Linux, where Rex itself may not be installed:
--
--   lua5.1 test/platform.lua

local function quote(word) return "'" .. tostring(word):gsub("'", "'\\''") .. "'" end

rex = {
  args = {},
  exec = function(argv)
    local words = {}
    for i, w in ipairs(argv) do words[i] = quote(w) end
    local probe = io.popen("command -v " .. quote(argv[1]) .. " >/dev/null 2>&1; echo $?")
    local found = probe:read("*a"):match("^0")
    probe:close()
    if not found then return nil, "not found" end
    local pipe = io.popen(table.concat(words, " ") .. " 2>/dev/null; echo \"__rc=$?\"")
    local out = pipe:read("*a")
    pipe:close()
    local code = tonumber(out:match("__rc=(%d+)%s*$"))
    return { ok = code == 0, code = code, stdout = out:gsub("__rc=%d+%s*$", ""), stderr = "" }
  end,
  json = { encode = function() return "{}" end, decode = function() return {} end },
}

REX_DURABLE_LIB = true
local here = (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/durable.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1 end
  print((ok and "  ok    " or "  FAIL  ") .. name .. (ok and "" or ("  " .. tostring(detail))))
end

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. quote(dir .. "/a b"))
local file = dir .. "/a b/session.lock"
-- A process that holds a file open, like a running chat.
-- Its output goes to /dev/null, so it doesn't keep io.popen's pipe open.
local start = io.popen("sh -c " .. quote("exec 3>>" .. quote(file) ..
  "; exec sleep 4243 3>&3 >/dev/null 2>&1 </dev/null & echo $!"))
local pid = tonumber(start:read("*a"))
start:close()
os.execute("sleep 1")

print("system: " .. M.OS .. ", lsof " .. (rex.exec({ "lsof", "-v" }) and "installed" or "not installed"))
local ps = M._processes({ pid })[pid]
local argv = ps and ps.argv or {}
check("ps reads the age", ps and ps.age >= 0)
check("exact argv", argv[1] == "sleep" and argv[2] == "4243" and #argv == 2, table.concat(argv, "|"))
local files = M._open_files({ pid })[pid] or {}
local seen = false
for _, f in ipairs(files) do if f == file then seen = true end end
check("open files include the held file", seen, table.concat(files, ", "))
local held = M._held_files({ file, dir .. "/a b/not-open" })
check("held file found", held[file] == true)
check("unheld file not found", held[dir .. "/a b/not-open"] == nil)
local times = M._mtimes({ file })
check("file mtime", times[file] and math.abs(times[file] - os.time()) < 120, times[file])

os.execute("kill " .. pid)
os.execute("rm -rf " .. quote(dir))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
