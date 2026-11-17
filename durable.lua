--[[
rex-durable: keep the programs in your Rex tabs across server restarts and
reboots.

Rex saves your sessions, tabs, and splits when its server stops, and brings
them back when it starts again. The programs that were running in them don't
come back: every tab returns as an empty shell. rex-durable remembers what was
running in each tab and puts it back after a restart:

  * fx, Claude Code, Codex, pi, and omp chats reopen on their own conversation.
  * Any other program is typed at the prompt but not run. You press Enter.
  * Plain shells are left alone.

Run it as a service with install.sh, or by hand:

  rex do durable.lua --all                        watch, save, and restore
  rex do durable.lua mode=status                  what is saved
  rex do durable.lua mode=save                    save now
  rex do durable.lua mode=reopen [dry_run=true]   reopen programs in their tabs
  rex do durable.lua mode=checkpoint [name=NAME]  pin a copy of the latest save
  rex do durable.lua mode=rebuild [from=NAME]     rebuild saved sessions
  rex do durable.lua mode=version

https://github.com/fazxes/rex-durable (MIT License)
]]

local M = {}
M.VERSION = "0.1.0"

local TERMINAL = "com.superlogical.terminal"
local SHELL_FLAVOR = "com.superlogical.terminal.shell"
local SAVE_EVERY = 30         -- seconds between saves while watching
local SAVE_AFTER_CHANGE = 5   -- seconds to wait after a change before saving
local KEEP_SNAPSHOTS = 10     -- saves kept, one per server instance
local MAX_AGE_DAYS = 30       -- older saves are never restored on their own
local TYPE_DELAY = 0.4        -- seconds between reopened programs
local SETTLE_TRIES = 10       -- tries while restored tabs finish starting their shells
local SETTLE_WAIT = 3         -- seconds between those tries

local SHELLS = {
  bash = true, csh = true, dash = true, elvish = true, fish = true, ksh = true,
  nu = true, sh = true, tcsh = true, xonsh = true, zsh = true,
}

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local args = rex.args or {}
local HOME = os.getenv("HOME") or ""
local SCRIPT = args.script or (debug and debug.getinfo and debug.getinfo(1, "S").source:match("^@?(/.+)$"))
-- Built by install.sh; see procargs.c.
local PROCARGS = (SCRIPT and SCRIPT:match("^(.*)/") or ".") .. "/procargs"

---------------------------------------------------------------------------
-- Small helpers

local function stamp() return os.date("%Y-%m-%d %H:%M:%S") end
local function now_iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local function log(message) print(stamp() .. " " .. message) end

local function basename(path)
  return tostring(path or ""):match("([^/]+)/*$") or ""
end

local function list(t) return type(t) == "table" and t or {} end

function M.quote(word)
  word = tostring(word)
  if word ~= "" and word:match("^[%w@%%+=:,%./_%-]+$") then return word end
  local escaped = word:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

function M.join(argv)
  local out = {}
  for i, word in ipairs(argv) do out[i] = M.quote(word) end
  return table.concat(out, " ")
end

local function run(argv, opts)
  return rex.exec(argv, opts)  -- nil only when the program could not start
end

local function stdout_of(argv, opts)
  local r = run(argv, opts)
  return r and r.stdout or ""
end

local function lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

local function read_json(path)
  local text = read_file(path)
  if not text then return nil end
  return rex.json.decode(text)
end

-- A file a chat writes about its own process, such as ~/.claude/sessions/<pid>.json.
-- It can be half-written or left behind by an earlier process with this pid.
local function read_pid_record(path, pid)
  local ok, record = pcall(read_json, path)
  if ok and type(record) == "table" and tonumber(record.pid) == pid
    and type(record.sessionId) == "string" then
    return record
  end
end

local function write_json(path, value)
  return write_file(path, rex.json.encode(value, { indent = true }) .. "\n")
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function dir_exists(path)
  local r = run({ "test", "-d", path })
  return r ~= nil and r.ok
end

local function list_dir(dir, suffix)
  local out = {}
  local r = run({ "ls", "-1", dir })
  if not (r and r.ok) then return out end
  for _, name in ipairs(lines(r.stdout)) do
    if not suffix or name:sub(-#suffix) == suffix then out[#out + 1] = dir .. "/" .. name end
  end
  return out
end

local OS = stdout_of({ "uname", "-s" }):gsub("%s+$", "")
local IS_MAC = OS == "Darwin"
M.OS = OS

local STATE_DIR = args.state_dir
  or (IS_MAC and (HOME .. "/Library/Application Support/rex-durable"))
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-durable")
local SNAP_DIR = STATE_DIR .. "/snapshots"
local CHECKPOINT_DIR = STATE_DIR .. "/checkpoints"
local STATE_FILE = STATE_DIR .. "/state.json"
M.STATE_DIR = STATE_DIR

local function notify(message)
  if args.notify == false then return end
  if IS_MAC then
    run({ "osascript", "-e", "on run argv",
          "-e", "display notification (item 1 of argv) with title \"Rex\"",
          "-e", "end run", message })
  else
    run({ "notify-send", "Rex", message })
  end
end

---------------------------------------------------------------------------
-- Processes: what is running in a tab, its command line, and its open files

-- ps prints elapsed time as [[dd-]hh:]mm:ss.
function M.parse_etime(text)
  text = text or ""
  local days, rest = text:match("^(%d+)%-(.+)$")
  if not days then days, rest = "0", text end
  local seconds = 0
  for n in rest:gmatch("%d+") do seconds = seconds * 60 + tonumber(n) end
  return tonumber(days) * 86400 + seconds
end

function M.parse_ps(text)
  local out = {}
  for _, line in ipairs(lines(text)) do
    local pid, etime, command = line:match("^%s*(%d+)%s+(%S+)%s*(.*)$")
    if pid then out[tonumber(pid)] = { age = M.parse_etime(etime), args = command } end
  end
  return out
end

-- lsof -F output: "p<pid>" starts a process, "n<path>" names one of its files.
function M.parse_lsof(text)
  local out, pid = {}, nil
  for _, line in ipairs(lines(text)) do
    local kind, rest = line:sub(1, 1), line:sub(2)
    if kind == "p" then
      pid = tonumber(rest)
      out[pid] = out[pid] or {}
    elseif kind == "n" and pid then
      table.insert(out[pid], rest)
    end
  end
  return out
end

local function open_files(pids)
  if #pids == 0 then return {} end
  local r = run({ "lsof", "-nP", "-w", "-Fpn", "-p", table.concat(pids, ",") })
  if r then return M.parse_lsof(r.stdout) end
  -- No lsof (common on minimal Linux): read /proc/<pid>/fd instead.
  local argv = { "sh", "-c",
    'for p in "$@"; do for f in /proc/$p/fd/*; do ' ..
    'l=$(readlink "$f" 2>/dev/null) && printf "p%s\\nn%s\\n" "$p" "$l"; done; done', "sh" }
  for _, pid in ipairs(pids) do argv[#argv + 1] = tostring(pid) end
  return M.parse_lsof(stdout_of(argv))
end

-- Which of these paths some process has open right now.
local function held_files(paths)
  local held = {}
  if #paths == 0 then return held end
  local argv = { "lsof", "-nP", "-w", "-Fn", "--" }
  for _, p in ipairs(paths) do argv[#argv + 1] = p end
  local r = run(argv)
  if r then
    for _, line in ipairs(lines(r.stdout)) do
      if line:sub(1, 1) == "n" then held[line:sub(2)] = true end
    end
    return held
  end
  if IS_MAC then return held end
  argv = { "find", "/proc", "-mindepth", "3", "-maxdepth", "3", "-path", "/proc/[0-9]*/fd/*",
           "-type", "l", "(" }
  for i, p in ipairs(paths) do
    if i > 1 then argv[#argv + 1] = "-o" end
    argv[#argv + 1] = "-lname"
    argv[#argv + 1] = p
  end
  for _, word in ipairs({ ")", "-printf", "%l\\n" }) do argv[#argv + 1] = word end
  for _, line in ipairs(lines(stdout_of(argv))) do held[line] = true end
  return held
end

local function mtimes(paths)
  local out = {}
  if #paths == 0 then return out end
  local argv = IS_MAC and { "stat", "-f", "%m %N" } or { "stat", "-c", "%Y %n" }
  for _, p in ipairs(paths) do argv[#argv + 1] = p end
  for _, line in ipairs(lines(stdout_of(argv))) do
    local t, path = line:match("^(%d+) (.+)$")
    if t then out[path] = tonumber(t) end
  end
  return out
end

local function split_words(text)
  local out = {}
  for word in (text or ""):gmatch("%S+") do out[#out + 1] = word end
  return out
end

-- /proc/<pid>/cmdline and environ: words ended by NULs. Empty words are real arguments.
local function nul_words(raw)
  local out = {}
  raw = raw or ""
  if raw ~= "" and raw:sub(-1) ~= "\0" then raw = raw .. "\0" end
  for word in raw:gmatch("([^%z]*)%z") do out[#out + 1] = word end
  return out
end

-- procargs output: one {"pid":N,"argv":[...],"env":[...]} per line.
function M.parse_procargs(text)
  local out = {}
  for _, line in ipairs(lines(text)) do
    local ok, p = pcall(rex.json.decode, line)
    if ok and type(p) == "table" and tonumber(p.pid) and type(p.argv) == "table" then
      out[tonumber(p.pid)] = { argv = p.argv, env = list(p.env) }
    end
  end
  return out
end

-- Each process's exact command line and environment: from /proc on Linux, and
-- from procargs (built by install.sh next to durable.lua) on macOS. Without
-- procargs, ps's words, so an option value with spaces comes back split.
local function commands(pids, ps)
  local out = {}
  if not IS_MAC then
    for _, pid in ipairs(pids) do
      local argv = nul_words(read_file("/proc/" .. pid .. "/cmdline"))
      if #argv > 0 then
        out[pid] = { argv = argv, env = nul_words(read_file("/proc/" .. pid .. "/environ")) }
      end
    end
    return out
  end
  local argv = { PROCARGS }
  for _, pid in ipairs(pids) do argv[#argv + 1] = tostring(pid) end
  local r = file_exists(PROCARGS) and run(argv)
  if r and r.ok then return M.parse_procargs(r.stdout) end
  for _, line in ipairs(lines(stdout_of({ "ps", "-wwE", "-o", "pid=,args=", "-p",
                                          table.concat(pids, ",") }))) do
    local pid, text = line:match("^%s*(%d+)%s+(.*)$")
    local args = pid and ps[tonumber(pid)] and ps[tonumber(pid)].args
    if args and text:sub(1, #args) == args then
      out[tonumber(pid)] = { argv = split_words(args), env = split_words(text:sub(#args + 1)) }
    end
  end
  return out
end

-- What each process is: its age, command line, and environment as NAME=value words.
local function processes(pids)
  if #pids == 0 then return {} end
  local ps = M.parse_ps(stdout_of({ "ps", "-o", "pid=,etime=,args=", "-p", table.concat(pids, ",") }))
  local exact = commands(pids, ps)
  for pid, p in pairs(ps) do
    local c = exact[pid]
    p.argv, p.env = c and c.argv or split_words(p.args), c and c.env
    p.args = nil
  end
  return ps
end

-- The tab's process chain, closest to the screen first, without login.
function M.chain_of(proc)
  local out, seen, candidates = {}, {}, {}
  if type(proc) ~= "table" then return out end
  if proc.foreground then candidates[#candidates + 1] = proc.foreground end
  for _, p in ipairs(list(proc.ancestors)) do candidates[#candidates + 1] = p end
  for _, p in ipairs(candidates) do
    if p.pid and not seen[p.pid] and p.name ~= "login" then
      seen[p.pid] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function is_shell(p)
  return SHELLS[basename((p.name or ""):gsub("^%-", ""))] == true
end

---------------------------------------------------------------------------
-- Chats: which conversation a running fx, Claude Code, Codex, pi, or omp is on

local function under(path, dir)
  return path:sub(1, #dir) == dir and path:sub(#dir + 1) or nil
end

-- fx holds ~/.fx/sessions/v2/<id>/lock (older: ~/.fx/sessions/<id>/session.lock).
function M.fx_session(files, home)
  for _, f in ipairs(list(files)) do
    local rest = under(f, (home or HOME) .. "/.fx/sessions/")
    if rest then
      local id = rest:match("^v2/([%w_%-]+)/lock$")
      if id then return id, "v2" end
      id = rest:match("^([%w_%-]+)/session%.lock$")
      if id then return id, "v1" end
    end
  end
end

-- Codex writes ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl.
function M.codex_session(files, home)
  for _, f in ipairs(list(files)) do
    if under(f, (home or HOME) .. "/.codex/sessions/") then
      local id = f:match("rollout%-.*%-(" .. UUID .. ")%.jsonl$")
      if id then return id, f end
    end
  end
end

-- Claude Code writes ~/.claude/projects/<folder with non-alphanumerics as ->/<id>.jsonl.
function M.claude_slug(cwd) return (tostring(cwd or ""):gsub("[^%w]", "-")) end

function M.claude_session(files, home)
  for _, f in ipairs(list(files)) do
    if under(f, (home or HOME) .. "/.claude/projects/") then
      local id = f:match("/(" .. UUID .. ")%.jsonl$")
      if id then return id, f end
    end
  end
end

local function codex_cwd(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local first = f:read("*l")
  f:close()
  local meta = first and rex.json.decode(first)
  local payload = type(meta) == "table" and (meta.payload or meta) or {}
  return payload.cwd
end

-- Environment variables a chat keeps when it reopens, such as FORCE_COLOR=1
-- typed in front of it. No other variable is ever saved.
M.ENV = { "FORCE_COLOR", "MAX_THINKING_TOKENS" }

local function kept_env(words)
  local wanted, out = {}, nil
  for _, name in ipairs(M.ENV) do wanted[name] = true end
  for _, word in ipairs(list(words)) do
    local name, value = word:match("^([%w_]+)=(.*)$")
    if name and wanted[name] then
      out = out or {}
      out[name] = value
    end
  end
  return out
end

-- Written by extension/rex-durable.ts into ~/.pi/agent or ~/.omp/agent. pi's
-- process title hides its command line and environment from ps, so the
-- record carries them.
local function extension_record(agent)
  return function(pid, home)
    local r = read_pid_record(home .. "/" .. agent .. "/rex-durable/" .. pid .. ".json", pid)
    return r and { id = r.sessionId, file = r.sessionFile, argv = r.argv, env = r.env }
  end
end

local function relative_to(dir, path)
  dir = dir:gsub("/+$", "")
  if path == dir then return "" end
  if dir ~= "" and path:sub(1, #dir + 1) == dir .. "/" then return path:sub(#dir + 2) end
end

-- omp keeps a folder's sessions in ~/.omp/agent/sessions/<folder>, named
-- -tmp-<path> under the temporary directory, -<path> under home, and
-- --<path>-- elsewhere, with / and : as -.
function M.omp_folder(cwd, home, tmp)
  cwd = tostring(cwd or "")
  local function dashed(s) return (s:gsub("[/\\:]", "-")) end
  local rel = tmp and relative_to(tmp, cwd)
  if rel then return rel == "" and "-tmp" or "-tmp-" .. dashed(rel) end
  rel = relative_to(home, cwd)
  if rel then return "-" .. dashed(rel) end
  return "--" .. dashed((cwd:gsub("^/", ""))) .. "--"
end

-- omp compares real paths, and macOS's TMPDIR is a symlink under /var.
local tmpdir
local function real_tmpdir()
  if tmpdir == nil then
    local dir = os.getenv("TMPDIR") or "/tmp"
    local r = run({ "realpath", dir })
    local real = r and r.ok and r.stdout:gsub("%s+$", "")
    tmpdir = (real and real ~= "") and real or dir
  end
  return tmpdir
end

-- Each chat program: the options it keeps when it reopens, how to tell which
-- conversation a running one is on, and how to reopen it. Anything else on the
-- original command line, such as an internal relaunch flag or Claude Code's
-- --worktree (the chat already reopens inside its worktree), is dropped.
-- `optional` options take a value only when the next word isn't an option.
M.CHATS = {
  fx = {
    values = { ["--model"] = true, ["--effort"] = true, ["--provider"] = true,
               ["--add-dir"] = true, ["--context-limit"] = true },
    switches = { ["--fast"] = true, ["--no-fast"] = true, ["--ultrafast"] = true,
                 ["--no-ultrafast"] = true, ["--no-additional-dirs"] = true,
                 ["--sessions-v2"] = true },
    holds_session = true,
    resume_flag = "--resume",
  },
  claude = {
    values = { ["--model"] = true, ["--permission-mode"] = true, ["--add-dir"] = true,
               ["--settings"] = true, ["--agent"] = true, ["--system-prompt"] = true,
               ["--append-system-prompt"] = true, ["--tools"] = true, ["--allowedTools"] = true,
               ["--disallowedTools"] = true, ["--mcp-config"] = true, ["--effort"] = true,
               ["--plugin-dir"] = true, ["--name"] = true, ["-n"] = true },
    switches = { ["--dangerously-skip-permissions"] = true, ["--strict-mcp-config"] = true,
                 ["--safe-mode"] = true },
    optional = { ["--remote-control"] = true },
    package = "claude-code",
    record = function(pid, home)
      local r = read_pid_record(home .. "/.claude/sessions/" .. pid .. ".json", pid)
      return r and { id = r.sessionId, file = home .. "/.claude/projects/" ..
                     M.claude_slug(r.cwd) .. "/" .. r.sessionId .. ".jsonl" }
    end,
    session_flags = { ["--resume"] = true, ["-r"] = true, ["--session-id"] = true },
    open_session = M.claude_session,
    recent = function(pane, home)
      return list_dir(home .. "/.claude/projects/" .. M.claude_slug(pane.cwd), ".jsonl")
    end,
    id_in_file = "/(" .. UUID .. ")%.jsonl$",
    resume_flag = "--resume",
  },
  codex = {
    values = { ["-m"] = true, ["--model"] = true, ["-p"] = true, ["--profile"] = true,
               ["-s"] = true, ["--sandbox"] = true, ["-a"] = true,
               ["--ask-for-approval"] = true, ["--add-dir"] = true, ["-c"] = true,
               ["--config"] = true },
    switches = { ["--dangerously-bypass-approvals-and-sandbox"] = true, ["--yolo"] = true,
                 ["--search"] = true, ["--oss"] = true },
    session_flags = { resume = true },
    open_session = M.codex_session,
    holds_session = true,
    recent = function(pane, home, age)
      local out = {}
      local minutes = tostring(math.floor(age / 60) + 2)
      for _, path in ipairs(lines(stdout_of({ "find", home .. "/.codex/sessions", "-name",
                                              "rollout-*.jsonl", "-mmin", "-" .. minutes }))) do
        if codex_cwd(path) == pane.cwd then out[#out + 1] = path end
      end
      return out
    end,
    id_in_file = "%-(" .. UUID .. ")%.jsonl$",
    subcommand = "resume",
  },
  pi = {
    values = { ["--provider"] = true, ["--model"] = true, ["--thinking"] = true,
               ["--models"] = true, ["--tools"] = true, ["-t"] = true,
               ["--exclude-tools"] = true, ["-xt"] = true, ["--extension"] = true,
               ["-e"] = true, ["--skill"] = true, ["--session-dir"] = true },
    switches = { ["--approve"] = true, ["-a"] = true, ["--offline"] = true,
                 ["--no-tools"] = true, ["-nt"] = true, ["--no-builtin-tools"] = true,
                 ["-nbt"] = true, ["--no-extensions"] = true, ["-ne"] = true,
                 ["--no-mcp"] = true, ["--no-skills"] = true, ["-ns"] = true,
                 ["--no-context-files"] = true, ["-nc"] = true },
    package = "pi-coding-agent",
    record = extension_record(".pi/agent"),
    session_flags = { ["--session"] = true, ["--session-id"] = true },
    session_value = "^[^%-]",
    open_session = function() end,
    recent = function(pane, home)
      local folder = tostring(pane.cwd):gsub("^/", ""):gsub("[/\\:]", "-")
      return list_dir(home .. "/.pi/agent/sessions/--" .. folder .. "--", ".jsonl")
    end,
    id_in_file = "_(" .. UUID .. ")%.jsonl$",
    resume_flag = "--session",
    resume_by_file = true,
  },
  omp = {
    values = { ["--model"] = true, ["--smol"] = true, ["--slow"] = true, ["--plan"] = true,
               ["--provider"] = true, ["--system-prompt"] = true,
               ["--system-prompt-template"] = true, ["--append-system-prompt"] = true,
               ["--profile"] = true, ["--config"] = true, ["--add-dir"] = true,
               ["--session-dir"] = true, ["--models"] = true, ["--tools"] = true,
               ["--thinking"] = true, ["--service-tier"] = true, ["--hook"] = true,
               ["-e"] = true, ["--extension"] = true, ["--skills"] = true,
               ["--approval-mode"] = true, ["--prewalk-into"] = true },
    switches = { ["--allow-home"] = true, ["--no-tools"] = true, ["--no-judge"] = true,
                 ["--no-spotlight"] = true, ["--offline"] = true, ["--no-lsp"] = true,
                 ["--no-pty"] = true, ["--hide-thinking"] = true, ["--advisor"] = true,
                 ["--external-thinking"] = true, ["--no-extensions"] = true,
                 ["--no-skills"] = true, ["--no-rules"] = true, ["--no-context-files"] = true,
                 ["--no-title"] = true, ["--auto-approve"] = true, ["--prewalk"] = true,
                 ["--no-prewalk"] = true },
    record = extension_record(".omp/agent"),
    session_flags = { ["--resume"] = true, ["-r"] = true },
    session_value = "^[^%-]",
    open_session = function() end,
    recent = function(pane, home)
      return list_dir(home .. "/.omp/agent/sessions/" .. M.omp_folder(pane.cwd, home,
                                                                       real_tmpdir()), ".jsonl")
    end,
    id_in_file = "_(" .. UUID .. ")%.jsonl$",
    resume_flag = "--resume",
    resume_by_file = true,
  },
}

-- Chat programs in the order they're looked for and listed.
M.APPS = { "fx", "claude", "codex", "pi", "omp" }

-- A session ID given on the command line: `codex resume <id>`,
-- `claude --resume <id>` or `claude --session-id <id>`.
function M.argv_session(app, argv)
  local chat = M.CHATS[app]
  local flags, wanted = chat.session_flags or {}, chat.session_value or ("^" .. UUID .. "$")
  argv = list(argv)
  for i, a in ipairs(argv) do
    local flag, value = a:match("^(%-%-[%w%-]+)=(.*)$")
    if not flag then flag, value = a, argv[i + 1] end
    if flags[flag] and value and value:match(wanted) then return value end
  end
end

-- Whether a process is the given app, including Node launchers such as
-- `node /usr/local/bin/claude`.
function M.is_app(app, name, argv)
  argv = list(argv)
  if basename(name) == app or basename(argv[1]) == app then return true end
  if basename(argv[1]):match("^node") then
    for i = 2, math.min(#argv, 3) do
      local a = argv[i] or ""
      local package = M.CHATS[app].package
      if basename(a) == app or a:find("/" .. app .. "/", 1, true)
        or (package and a:find(package, 1, true)) then
        return true
      end
    end
  end
  return false
end

-- Which conversation a chat process is on, most certain first: the record the
-- chat keeps for its process (it follows /clear, unlike --resume), the session
-- file it holds open, then a session named on its command line.
local function chat_in(p, info)
  local home = info.home or HOME
  local files = info.files[p.pid]
  local argv = (info.ps[p.pid] or {}).argv or {}
  local name = p.name or argv[1]
  local id, store = M.fx_session(files, home)
  if id then return { kind = "chat", app = "fx", id = id, store = store, argv = argv } end
  for _, app in ipairs(M.APPS) do
    if M.CHATS[app].open_session and M.is_app(app, name, argv) then
      local chat = M.CHATS[app]
      local record = chat.record and chat.record(p.pid, home)
      local file
      if record and record.argv then argv = list(record.argv) end
      if record and record.file and file_exists(record.file) then
        id, file = record.id, record.file
      else
        id, file = chat.open_session(files, home)
        id = id or M.argv_session(app, argv)
      end
      if not id and record then
        return { kind = "program", argv = argv, note = "nothing said yet" }
      end
      return { kind = "chat", app = app, id = id, session_file = file, argv = argv, pid = p.pid,
               env = record and record.env }
    end
  end
end

-- What a tab is running: a chat, another program, or just its shell.
function M.describe(proc, info)
  local home = HOME
  local chain = M.chain_of(proc)
  if #chain == 0 then return { kind = "shell", cwd = home } end
  local outer = chain[#chain]
  local inner = {}
  for i = 1, is_shell(outer) and #chain - 1 or #chain do inner[i] = chain[i] end
  for _, p in ipairs(inner) do
    local chat = chat_in(p, info)
    if chat then
      chat.cwd = p.cwd or outer.cwd or home
      -- The environment the shell gave the program, not what a launcher such
      -- as Codex's node wrapper passed on.
      if chat.kind == "chat" then
        chat.env = kept_env(chat.env or (info.ps[inner[#inner].pid] or {}).env)
      end
      return chat
    end
  end
  if #inner == 0 then return { kind = "shell", cwd = outer.cwd or home } end
  local top = inner[#inner]
  return { kind = "program", cwd = top.cwd or outer.cwd or home,
           argv = (info.ps[top.pid] or {}).argv or {} }
end

-- A chat that keeps no session file open and named none on its command line:
-- use the newest session file for its folder written since it started, and
-- not another chat's. Only when it is the only such chat in that folder;
-- otherwise it isn't certain.
local function newest_session_file(pane, info)
  local chat = M.CHATS[pane.app]
  local age = (info.ps[pane.pid] or {}).age or 0
  local since = info.now - age - 5
  local best, best_id, best_time
  for path, t in pairs(mtimes(chat.recent(pane, info.home or HOME, age))) do
    local id = path:match(chat.id_in_file)
    if id and not info.claimed[pane.app .. ":" .. id] and t >= since
      and (not best_time or t > best_time) then
      best, best_id, best_time = path, id, t
    end
  end
  return best_id, best
end

local function resolve_chats(pending, info)
  local groups = {}
  for _, pane in ipairs(pending) do
    local key = pane.app .. "\0" .. tostring(pane.cwd)
    groups[key] = groups[key] or {}
    table.insert(groups[key], pane)
  end
  for _, group in pairs(groups) do
    for _, pane in ipairs(group) do
      if #group == 1 then pane.id, pane.session_file = newest_session_file(pane, info) end
      if not pane.id then
        -- Not sure which conversation it is: bring it back typed, not run.
        pane.kind, pane.app, pane.session_file = "program", nil, nil
        pane.note = "conversation unknown"
      end
    end
  end
end

---------------------------------------------------------------------------
-- Reading Rex: every session, window, split, and what each tab runs

function M.panes(node, out)
  out = out or {}
  if type(node) ~= "table" then return out end
  if node.split then
    M.panes(node.split.before, out)
    M.panes(node.split.after, out)
  elseif node.pane then
    out[#out + 1] = node.pane
  end
  return out
end

local function convert(node, procs, info, pending)
  if type(node) ~= "table" then return nil end
  if node.split then
    local before = convert(node.split.before, procs, info, pending)
    local after = convert(node.split.after, procs, info, pending)
    if not before or not after then return before or after end
    return { split = { direction = node.split.direction, ratio = node.split.ratio or 0.5,
                       before = before, after = after } }
  end
  local proc = node.block_id and procs[node.block_id]
  if not proc then return nil end
  local pane = M.describe(proc, info)
  pane.block_id = node.block_id
  pane.focused = node.focused and true or false
  if pane.kind == "chat" then
    if pane.id then info.claimed[pane.app .. ":" .. pane.id] = true else pending[#pending + 1] = pane end
  end
  return { pane = pane }
end

local function collect()
  local status = assert(rex.call("server.status"))
  local listing = rex.call("session.list") or {}
  local raw, pids = {}, {}
  for _, s in ipairs(list(listing.sessions)) do
    rex.session.attach{ session_id = s.session_id }
    local view, err = rex.session.view{ session_id = s.session_id }
    local entry = { id = s.session_id, label = s.label, view = view, procs = {} }
    if not view then log("couldn't read session " .. tostring(s.label) .. ": " .. tostring(err)) end
    for _, w in ipairs(list(view and view.windows)) do
      for _, layer in ipairs(list(w.layers)) do
        for _, b in ipairs(list(layer.blocks)) do
          if b.creator_name == TERMINAL then
            local proc = rex.block.call(TERMINAL, "process",
              { session_id = s.session_id, block_id = b.block_id }) or {}
            entry.procs[b.block_id] = proc
            for _, p in ipairs(M.chain_of(proc)) do pids[#pids + 1] = p.pid end
          end
        end
      end
    end
    raw[#raw + 1] = entry
  end

  local ps = processes(pids)
  local info = { ps = ps, files = open_files(pids), now = os.time(), claimed = {} }
  local sessions, pending = {}, {}
  for _, entry in ipairs(raw) do
    if entry.view then
      local windows = {}
      for _, w in ipairs(list(entry.view.windows)) do
        local tiled
        for _, layer in ipairs(list(w.layers)) do
          if layer.kind == "tiled" then tiled = layer break end
        end
        local layout = tiled and convert(tiled.layout, entry.procs, info, pending)
        if layout then
          local label = w.label
          local short = label and label:match("^Window (%x%x%x%x%x%x%x%x)$")
          if short and tostring(w.window_id):sub(-8) == short then label = nil end
          windows[#windows + 1] = { window_id = w.window_id, label = label,
                                    active = w.window_id == entry.view.active_window_id,
                                    layout = layout }
        end
      end
      sessions[#sessions + 1] = { session_id = entry.id, label = entry.label, windows = windows }
    end
  end
  resolve_chats(pending, info)
  for _, s in ipairs(sessions) do
    for _, w in ipairs(s.windows) do
      for _, pane in ipairs(M.panes(w.layout)) do pane.pid = nil end
    end
  end
  return {
    tool = "rex-durable", version = M.VERSION, saved_at = now_iso(),
    server = { instance_id = status.instance_id, started_at = status.started_at },
    sessions = sessions,
  }
end
M.collect = collect

---------------------------------------------------------------------------
-- Saves

local function ensure_dirs() run({ "mkdir", "-p", SNAP_DIR, CHECKPOINT_DIR }) end

local function snapshot_path(instance) return SNAP_DIR .. "/" .. instance .. ".json" end

local function load_snapshots()
  local out = {}
  for _, path in ipairs(list_dir(SNAP_DIR, ".json")) do
    local snap = read_json(path)
    if type(snap) == "table" and type(snap.server) == "table" and snap.saved_at then
      snap.path = path
      out[#out + 1] = snap
    end
  end
  table.sort(out, function(a, b) return a.saved_at > b.saved_at end)
  return out
end

local function save()
  ensure_dirs()
  local snap = collect()
  write_json(snapshot_path(snap.server.instance_id), snap)
  local all = load_snapshots()
  for i = KEEP_SNAPSHOTS + 1, #all do os.remove(all[i].path) end
  return snap
end

local function checkpoint_path(name)
  return CHECKPOINT_DIR .. "/" .. tostring(name):gsub("[^%w%._%-]", "-") .. ".json"
end

local function previous_snapshot(instance)
  for _, snap in ipairs(load_snapshots()) do
    if snap.server.instance_id ~= instance then return snap end
  end
end

local function load_source(name)
  if name then
    local snap = read_json(checkpoint_path(name))
    if not snap then error("no checkpoint named " .. name .. " in " .. CHECKPOINT_DIR, 0) end
    return snap
  end
  return load_snapshots()[1]
end

-- One idle shell in the home folder: what Rex opens by default.
function M.is_default_session(s)
  local windows = list(s.windows)
  if #windows ~= 1 then return false end
  local panes = M.panes(windows[1].layout)
  return #panes == 1 and panes[1].kind == "shell"
    and (panes[1].cwd == HOME or panes[1].cwd == HOME .. "/")
end

function M.is_blank(snap)
  for _, s in ipairs(list(snap and snap.sessions)) do
    if not M.is_default_session(s) then return false end
  end
  return true
end

function M.summary(snap)
  local sessions, tabs, chats, programs = 0, 0, 0, 0
  local apps = {}
  for _, s in ipairs(list(snap and snap.sessions)) do
    if not M.is_default_session(s) then
      sessions = sessions + 1
      for _, w in ipairs(list(s.windows)) do
        tabs = tabs + 1
        for _, p in ipairs(M.panes(w.layout)) do
          if p.kind == "chat" then
            chats = chats + 1
            apps[p.app] = (apps[p.app] or 0) + 1
          elseif p.kind == "program" then
            programs = programs + 1
          end
        end
      end
    end
  end
  local parts = {}
  for _, app in ipairs(M.APPS) do
    if apps[app] then parts[#parts + 1] = apps[app] .. " " .. app end
  end
  local text = string.format("%d sessions, %d tabs, %d chats", sessions, tabs, chats)
  if #parts > 0 then text = text .. " (" .. table.concat(parts, ", ") .. ")" end
  return text .. string.format(", %d other programs", programs), chats, programs
end

---------------------------------------------------------------------------
-- Commands that reopen a chat

local fx_help = {}
local function fx_accepts(exe, option)
  if fx_help[exe] == nil then
    local r = run({ exe, "--help" }, { timeout = 10 })
    fx_help[exe] = r and ((r.stdout or "") .. (r.stderr or "")) or false
  end
  if not fx_help[exe] then return option ~= "--sessions-v2" end
  return fx_help[exe]:find(option, 1, true) ~= nil
end
M.fx_accepts = fx_accepts

function M.kept_options(argv, spec)
  local out, i = {}, 2
  argv = list(argv)
  while i <= #argv do
    local a = argv[i]
    i = i + 1
    local name = a:match("^(%-%-?[%w%-]+)=") or a
    local optional = spec.optional and spec.optional[name]
    if spec.switches[a] or (a ~= name and (spec.values[name] or optional)) then
      out[#out + 1] = a
    elseif optional then
      out[#out + 1] = a
      if argv[i] and not argv[i]:match("^%-") then
        out[#out + 1] = argv[i]
        i = i + 1
      end
    elseif spec.values[name] and i <= #argv then
      out[#out + 1] = a
      out[#out + 1] = argv[i]
      i = i + 1
    end
  end
  return out
end

local function chat_executable(pane)
  local exe = list(pane.argv)[1]
  if not exe or basename(exe) ~= pane.app then exe = pane.app end
  if exe:find("/", 1, true) and not file_exists(exe) then exe = pane.app end
  return exe
end

function M.resume_argv(pane, accepts)
  accepts = accepts or fx_accepts
  local chat = M.CHATS[pane.app]
  local exe = chat_executable(pane)
  local argv = { exe, chat.subcommand }
  local has_v2 = false
  for _, option in ipairs(M.kept_options(pane.argv, chat)) do
    if option == "--sessions-v2" then
      if accepts(exe, "--sessions-v2") and not has_v2 then
        has_v2 = true
        argv[#argv + 1] = option
      end
    else
      argv[#argv + 1] = option
    end
  end
  if pane.app == "fx" and pane.store == "v2" and not has_v2 and accepts(exe, "--sessions-v2") then
    argv[#argv + 1] = "--sessions-v2"
  end
  argv[#argv + 1] = chat.resume_flag
  argv[#argv + 1] = chat.resume_by_file and pane.session_file or pane.id
  return argv
end

local function command_for(pane)
  if pane.kind == "chat" then
    local words = {}
    for _, name in ipairs(M.ENV) do
      local value = type(pane.env) == "table" and pane.env[name]
      if value then words[#words + 1] = name .. "=" .. M.quote(value) end
    end
    table.sort(words)
    for _, word in ipairs(M.resume_argv(pane)) do words[#words + 1] = M.quote(word) end
    return table.concat(words, " ") .. "\n"
  end
  if pane.kind == "program" and #list(pane.argv) > 0 then return M.join(pane.argv) end
end
M.command_for = command_for

-- Chats already running, in Rex or anywhere else, so none is opened twice.
local function open_chats(saved, live)
  local open = {}
  for _, s in ipairs(list(live and live.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" then open[p.app .. ":" .. p.id] = true end
      end
    end
  end
  local paths, owner = {}, {}
  for _, s in ipairs(list(saved.sessions)) do
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do
        if p.kind == "chat" then
          local path = p.session_file
          if p.app == "fx" then
            path = HOME .. "/.fx/sessions/" ..
              (p.store == "v2" and ("v2/" .. p.id .. "/lock") or (p.id .. "/session.lock"))
          end
          if path and M.CHATS[p.app].holds_session then
            paths[#paths + 1] = path
            owner[path] = p.app .. ":" .. p.id
          end
        end
      end
    end
  end
  for path in pairs(held_files(paths)) do
    if owner[path] then open[owner[path]] = true end
  end
  return open
end

---------------------------------------------------------------------------
-- Reopening programs in the tabs Rex restored

-- Rex keeps session and block IDs when it restores its own sessions, so a
-- saved tab is found by its block ID first, then by session and position.
function M.plan_reopen(saved, live, open, opts)
  opts = opts or {}
  local writes, notes, busy = {}, {}, 0
  local skip = opts.skip_blocks or {}
  local by_id, by_label, by_block = {}, {}, {}
  for _, s in ipairs(list(live.sessions)) do
    by_id[s.session_id] = s
    by_label[s.label or ""] = by_label[s.label or ""] or {}
    table.insert(by_label[s.label or ""], s)
    for _, w in ipairs(list(s.windows)) do
      for _, p in ipairs(M.panes(w.layout)) do by_block[p.block_id] = { pane = p, session = s } end
    end
  end
  local used, claimed = {}, {}
  for _, s in ipairs(list(saved.sessions)) do
    local target = by_id[s.session_id]
    if not target then
      for _, candidate in ipairs(by_label[s.label or ""] or {}) do
        if not used[candidate.session_id] then target = candidate break end
      end
    end
    if target then used[target.session_id] = true end
    for wi, w in ipairs(list(s.windows)) do
      local want = M.panes(w.layout)
      local have_list
      local tw = target and list(target.windows)[wi]
      if tw and #list(target.windows) == #list(s.windows) then
        have_list = M.panes(tw.layout)
        if #have_list ~= #want then have_list = nil end
      end
      for pi, p in ipairs(want) do
        local where = string.format("%s tab %d", s.label or "session", wi)
        if #want > 1 then where = where .. string.format(" pane %d", pi) end
        local command = command_for(p)
        if command and (p.kind == "chat" or opts.programs ~= false) then
          local hit = by_block[p.block_id]
          local have, session_id = hit and hit.pane, hit and hit.session.session_id
          if not have and have_list then have, session_id = have_list[pi], target.session_id end
          local key = p.kind == "chat" and (p.app .. ":" .. p.id)
          if not have then
            notes[#notes + 1] = where .. ": no matching tab"
          elseif skip[have.block_id] then
            -- Typed into on an earlier try.
          elseif (have.kind == "chat" and key == (have.app .. ":" .. tostring(have.id)))
            or (have.kind == "program" and p.kind == "program"
                and M.join(list(have.argv)) == M.join(list(p.argv))) then
            -- Already running in its own tab.
          elseif have.kind ~= "shell" or claimed[have.block_id] then
            notes[#notes + 1] = where .. ": the tab is busy, left alone"
            busy = busy + 1
          elseif key and open[key] then
            notes[#notes + 1] = where .. ": " .. p.app .. " chat " .. p.id .. " is already open"
          else
            if p.cwd and have.cwd and p.cwd ~= have.cwd and (opts.dir_exists or dir_exists)(p.cwd) then
              command = "cd " .. M.quote(p.cwd) .. " && " .. command
            end
            claimed[have.block_id] = true
            if key then open[key] = true end
            writes[#writes + 1] = { session_id = session_id, block_id = have.block_id,
                                    data = command, where = where, kind = p.kind, key = key or nil }
          end
        end
      end
    end
  end
  return writes, notes, busy
end

local function perform(writes)
  local done = 0
  for _, w in ipairs(writes) do
    rex.session.attach{ session_id = w.session_id }
    local ok, err = rex.block.call(TERMINAL, "write",
      { session_id = w.session_id, block_id = w.block_id, data = w.data })
    if ok then done = done + 1 else log(w.where .. ": couldn't type into the tab: " .. tostring(err)) end
    rex.sleep(TYPE_DELAY)
  end
  return done
end

local function count_kind(writes, kind)
  local n = 0
  for _, w in ipairs(writes) do if w.kind == kind then n = n + 1 end end
  return n
end

-- Tabs Rex has just restored are still starting their shells, and a shell's
-- startup can run commands that make the tab look busy. Try again for a while;
-- a tab is typed into at most once.
local function reopen(saved, live, dry_run)
  local written, typed = {}, {}
  local chats, programs = 0, 0
  local tries = dry_run and 1 or SETTLE_TRIES
  for try = 1, tries do
    if try > 1 then
      rex.sleep(SETTLE_WAIT)
      live = collect()
    end
    local open = open_chats(saved, live)
    for key in pairs(typed) do open[key] = true end
    local writes, notes, busy = M.plan_reopen(saved, live, open,
      { programs = args.programs, skip_blocks = written })
    for _, w in ipairs(writes) do
      log(string.format("  %s %s: %s", dry_run and "would type" or "type", w.where,
                        (w.data:gsub("\n$", w.kind == "chat" and " (run)" or ""))))
    end
    if not dry_run then
      perform(writes)
      for _, w in ipairs(writes) do
        written[w.block_id] = true
        if w.key then typed[w.key] = true end
      end
      chats = chats + count_kind(writes, "chat")
      programs = programs + count_kind(writes, "program")
    end
    if busy == 0 or try == tries then
      for _, note in ipairs(notes) do log("  skip " .. note) end
      break
    end
    log(string.format("  %d tabs are busy, maybe still starting; trying again in %d seconds",
                      busy, SETTLE_WAIT))
  end
  return chats, programs
end

---------------------------------------------------------------------------
-- Rebuilding sessions on a server that has none

local function create_layout(node, open, leaves)
  if node.split then
    return { split = { direction = node.split.direction, ratio = node.split.ratio,
                       before = create_layout(node.split.before, open, leaves),
                       after = create_layout(node.split.after, open, leaves) } }
  end
  local p = node.pane
  leaves[#leaves + 1] = p
  local options = {}
  if p.cwd and dir_exists(p.cwd) then options.cwd = p.cwd end
  local key = p.kind == "chat" and (p.app .. ":" .. p.id)
  if not (key and open[key]) then
    local command = command_for(p)
    if command and (p.kind == "chat" or args.programs ~= false) then options.initial_input = command end
    if key then open[key] = true end
  end
  local block = { flavor = SHELL_FLAVOR }
  if next(options) then block.options = options end
  return { block = block }
end

local function rebuild(saved, live)
  local open = open_chats(saved, live)
  local made = 0
  for _, s in ipairs(list(saved.sessions)) do
    if not M.is_default_session(s) and #list(s.windows) > 0 then
      local windows, leaves_by_window = {}, {}
      for i, w in ipairs(s.windows) do
        local leaves = {}
        local window = { layout = create_layout(w.layout, open, leaves) }
        if w.label then window.label = w.label end
        windows[i], leaves_by_window[i] = window, leaves
      end
      local request = { initial_windows = windows }
      if s.label then request.label = s.label end
      local result, err = rex.call("session.create", request)
      if not result and request.label then
        -- The name may be taken; keep the session under a new one.
        request.label = request.label .. " (restored)"
        result, err = rex.call("session.create", request)
      end
      if result then
        made = made + 1
        log("  rebuilt session " .. tostring(s.label))
        rex.session.attach{ session_id = result.session_id }
        -- Focus each window's focused pane, then the window that was active.
        local active_block
        for i, made_window in ipairs(list(result.initial_windows)) do
          local focused = 1
          for j, p in ipairs(leaves_by_window[i] or {}) do if p.focused then focused = j end end
          local block_id = list(made_window.block_ids)[focused]
          if block_id then
            rex.session.focus_block{ session_id = result.session_id, block_id = block_id }
            if s.windows[i].active then active_block = block_id end
          end
        end
        if active_block then
          rex.session.focus_block{ session_id = result.session_id, block_id = active_block }
        end
        rex.sleep(TYPE_DELAY)
      else
        log("  couldn't rebuild session " .. tostring(s.label) .. ": " .. tostring(err))
      end
    end
  end
  return made
end

---------------------------------------------------------------------------
-- Modes

local function read_state() return read_json(STATE_FILE) or {} end

-- Print a result; actions from the command palette also show it as a notification.
local function tell(message)
  print(message)
  if args.palette == true then notify(message) end
end

local function startup()
  ensure_dirs()
  local status = assert(rex.call("server.status"))
  local state = read_state()
  if state.instance == status.instance_id then return save() end
  -- A server rex-durable hasn't seen: record it first, so it is handled once.
  state.instance = status.instance_id
  write_json(STATE_FILE, state)
  local saved = previous_snapshot(status.instance_id)
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - MAX_AGE_DAYS * 86400)
  if not saved or M.is_blank(saved) or saved.saved_at < cutoff then
    log("new Rex server; nothing to bring back")
    return save()
  end
  log("new Rex server; bringing back the save from " .. saved.saved_at)
  local live = collect()
  if M.is_blank(live) then
    local made = rebuild(saved, live)
    log(string.format("rebuilt %d sessions", made))
    if made > 0 then notify(string.format("Brought back %d sessions.", made)) end
  else
    local chats, programs = reopen(saved, live, false)
    log(string.format("reopened %d chats; typed %d other programs", chats, programs))
    if chats + programs > 0 then
      local text = string.format("Reopened %d chats", chats)
      if programs > 0 then text = text .. string.format(" and typed %d other programs", programs) end
      notify(text .. ".")
    end
  end
  state.last_restore = { at = now_iso(), from = saved.saved_at, instance = status.instance_id }
  write_json(STATE_FILE, state)
  return save()
end

local function status_mode()
  local status = rex.call("server.status") or {}
  print("rex-durable " .. M.VERSION .. " (" .. STATE_DIR .. ")")
  print("Rex server: " .. tostring(status.instance_id) .. ", started " .. tostring(status.started_at))
  local snaps = load_snapshots()
  if #snaps == 0 then print("No saves yet.") end
  for i, snap in ipairs(snaps) do
    if i > 3 then break end
    local which = snap.server.instance_id == status.instance_id and "this server" or "an earlier server"
    print(string.format("Save from %s (%s): %s", snap.saved_at, which, (M.summary(snap))))
  end
  for _, path in ipairs(list_dir(CHECKPOINT_DIR, ".json")) do
    local snap = read_json(path) or {}
    print(string.format("Checkpoint %s, from %s: %s", basename(path):gsub("%.json$", ""),
                        tostring(snap.saved_at), (M.summary(snap))))
  end
  local state = read_state()
  if state.last_restore then
    print(string.format("Last brought back at %s, from the save of %s", state.last_restore.at,
                        state.last_restore.from))
  end
end

local function script_path()
  if SCRIPT then return SCRIPT end
  error("can't tell where durable.lua is; pass script=/path/to/durable.lua", 0)
end

-- The watcher only schedules. Each save or restore runs as its own short
-- `rex do`, so reading every session never touches the watcher's own events.
local function watch()
  local rex_bin = args.rex or "rex"
  local script = script_path()
  local function child(mode)
    local argv = { rex_bin, "--autostart=false" }
    if args.server then argv[#argv + 1] = "--server"; argv[#argv + 1] = args.server end
    for _, word in ipairs({ "do", script, "mode=" .. mode }) do argv[#argv + 1] = word end
    for _, key in ipairs({ "state_dir", "programs", "notify" }) do
      if args[key] ~= nil then argv[#argv + 1] = key .. "=" .. tostring(args[key]) end
    end
    local r, err = rex.exec(argv, { timeout = 300 })
    if not r then log("couldn't run rex: " .. tostring(err)) return end
    io.write(r.stdout or "")
    if not r.ok then io.write(r.stderr or "") end
    io.flush()
  end

  local instance
  local function tick()
    local status = rex.call("server.status")
    if not status then return end
    if status.instance_id ~= instance then
      instance = status.instance_id
      child("startup")
    else
      child("save")
    end
  end

  local pending
  local function soon()
    if pending then return end
    pending = rex.after(SAVE_AFTER_CHANGE, function() pending = nil; child("save") end)
  end
  for _, event in ipairs({ "session_created", "session_destroyed", "session_view_changed",
                           "block_created", "block_closed", "terminal.child_exited",
                           "terminal.pwd_changed", "terminal.program_status_changed" }) do
    rex.on(event, soon)
  end
  log("rex-durable " .. M.VERSION .. " watching; saves in " .. STATE_DIR)
  tick()
  rex.every(SAVE_EVERY, tick)
end

local function main()
  local mode = args.mode or "watch"
  if mode == "watch" then return watch() end
  if mode == "version" then print("rex-durable " .. M.VERSION) return end
  if mode == "status" then return status_mode() end
  if mode == "startup" then startup() return end
  if mode == "save" then
    local snap = save()
    if args.verbose == true or args.palette == true then tell("Saved " .. (M.summary(snap)) .. ".") end
    return
  end
  if mode == "checkpoint" then
    ensure_dirs()
    local snap = save()
    local name = args.name or os.date("%Y%m%d-%H%M%S")
    write_json(checkpoint_path(name), snap)
    tell("Pinned checkpoint " .. name .. ": " .. (M.summary(snap)))
    return
  end
  if mode == "reopen" then
    local saved = load_source(args.from)
    local live = collect()
    if not args.from then
      -- The latest save of an earlier server, else the latest save at all.
      saved = previous_snapshot(live.server.instance_id) or saved
    end
    if not saved then print("No save to reopen from.") return end
    print("Reopening programs from the save of " .. saved.saved_at)
    local chats, programs = reopen(saved, live, args.dry_run == true)
    if args.dry_run ~= true then
      tell(string.format("Reopened %d chats; typed %d other programs.", chats, programs))
    end
    return
  end
  if mode == "rebuild" then
    local live = collect()
    local saved = args.from and load_source(args.from) or previous_snapshot(live.server.instance_id)
    if not saved then print("No save to rebuild from.") return end
    if not M.is_blank(live) and args.yes ~= true then
      print("This Rex server already has sessions. Use mode=reopen to put programs back in " ..
            "them, or add yes=true to add the saved sessions next to them.")
      return
    end
    print(string.format("Rebuilt %d sessions.", rebuild(saved, live)))
    return
  end
  error("unknown mode " .. tostring(mode) ..
        "; use watch, status, save, reopen, checkpoint, rebuild, or version", 0)
end

-- For the tests: the helpers that read processes and files.
M._processes, M._open_files, M._held_files = processes, open_files, held_files
M._mtimes, M._resolve_chats = mtimes, resolve_chats

if rawget(_G, "REX_DURABLE_LIB") then return M end
main()
