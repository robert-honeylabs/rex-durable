-- Unit tests for durable.lua. They run in Rex's own Lua and only read:
--
--   rex do test/unit.lua            (from the repository root)

REX_DURABLE_LIB = true
local here = (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/durable.lua")
local HOME = os.getenv("HOME")

local passed, failed = 0, 0

local function show(v)
  if type(v) == "table" then return rex.json.encode(v) end
  return tostring(v)
end

local function check(name, got, want)
  if show(got) == show(want) then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
  end
end

-- No --sessions-v2 in this fx's help, like fx 0.0.16 and later.
local function new_fx(_, option) return option ~= "--sessions-v2" end
local function old_fx() return true end

-- ps and lsof output
check("etime seconds", M.parse_etime("05:07"), 307)
check("etime hours", M.parse_etime("1:02:03"), 3723)
check("etime days", M.parse_etime("2-01:00:00"), 2 * 86400 + 3600)
local ps = M.parse_ps("  101 01:00 /usr/bin/fx --resume abc\n  202 2-00:00:01 zsh\n")
check("ps args", ps[101].args, "/usr/bin/fx --resume abc")
check("ps age", ps[202].age, 2 * 86400 + 1)
local files = M.parse_lsof("p101\nfcwd\nn/tmp\np202\nn/a b/c.jsonl\n")
check("lsof files", files, { [101] = { "/tmp" }, [202] = { "/a b/c.jsonl" } })
local exact = M.parse_procargs([[{"pid":101,"argv":["claude","--system-prompt","Keep replies \"brief\".\n"],]] ..
  [["env":["MAX_THINKING_TOKENS=0","A=b c"]}
not json
{"pid":202,"argv":["sleep",""],"env":[]}
]])
check("procargs keeps words with spaces, quotes, and empty words", exact, {
  [101] = { argv = { "claude", "--system-prompt", "Keep replies \"brief\".\n" }, env = { "MAX_THINKING_TOKENS=0", "A=b c" } },
  [202] = { argv = { "sleep", "" }, env = {} } })

-- Which conversation a chat is on
check("fx v2 lock", { M.fx_session({ "/x", HOME .. "/.fx/sessions/v2/Xy7_q-Z/lock" }) }, { "Xy7_q-Z", "v2" })
check("fx v1 lock", { M.fx_session({ HOME .. "/.fx/sessions/AbC123/session.lock" }) }, { "AbC123", "v1" })
check("fx other profile", M.fx_session({ "/tmp/aig-fx-home/.fx/sessions/v2/X/lock" }), nil)
local rollout = HOME .. "/.codex/sessions/2026/11/13/rollout-2026-11-13T10-00-00-aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.jsonl"
check("codex rollout", (M.codex_session({ rollout })), "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")
check("claude slug", M.claude_slug("/Users/me/my.proj"), "-Users-me-my-proj")
local claude_file = HOME .. "/.claude/projects/-Users-me/cccccccc-4444-4555-8666-dddddddddddd.jsonl"
check("claude file", (M.claude_session({ claude_file })), "cccccccc-4444-4555-8666-dddddddddddd")
local uuid = "cccccccc-4444-4555-8666-dddddddddddd"
check("claude --resume", M.argv_session("claude", { "claude", "--resume", uuid }), uuid)
check("claude --resume=", M.argv_session("claude", { "claude", "--resume=" .. uuid }), uuid)
check("codex resume", M.argv_session("codex", { "codex", "resume", uuid }), uuid)
check("codex --last", M.argv_session("codex", { "codex", "resume", "--last" }), nil)
check("claude via node", M.is_app("claude", "node", { "node", "/usr/local/bin/claude" }), true)
check("codex binary", M.is_app("codex", "codex", { "/opt/homebrew/bin/codex" }), true)
check("pi by its process title", M.is_app("pi", "pi", { "pi" }), true)
check("pi via node", M.is_app("pi", "node",
  { "node", "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" }), true)
check("pi --session", M.argv_session("pi", { "pi", "--session", "01a1e57d" }), "01a1e57d")
check("pi --session-id=", M.argv_session("pi", { "pi", "--session-id=abc" }), "abc")
check("not claude", M.is_app("claude", "node", { "node", "server.js" }), false)

-- Commands that reopen a chat
local function cmd(pane, accepts) return M.join(M.resume_argv(pane, accepts or new_fx)) end
check("fx keeps real options, drops relaunch internals",
  cmd({ app = "fx", id = "ID1", store = "v2",
        argv = { "fx", "resume", "OLD", "--upgrade-relaunch", "abc123", "--model", "m1", "--fast" } }),
  "fx --model m1 --fast --resume ID1")
check("fx drops --sessions-v2 when unsupported",
  cmd({ app = "fx", id = "ID2", store = "v2", argv = { "fx", "--sessions-v2", "--resume", "ID2" } }),
  "fx --resume ID2")
check("older fx keeps --sessions-v2",
  cmd({ app = "fx", id = "ID3", store = "v2", argv = { "fx" } }, old_fx),
  "fx --sessions-v2 --resume ID3")
check("fx missing dev build falls back to fx",
  cmd({ app = "fx", id = "ID4", argv = { "/nonexistent/zig-out/bin/fx" } }), "fx --resume ID4")
check("fx option=value",
  cmd({ app = "fx", id = "ID5", argv = { "fx", "--effort=high", "-r", "OLD" } }), "fx --effort=high --resume ID5")
check("claude keeps permission mode",
  cmd({ app = "claude", id = uuid,
        argv = { "node", "/usr/local/bin/claude", "--permission-mode", "plan", "--verbose" } }),
  "claude --permission-mode plan --resume " .. uuid)
check("codex resume with model",
  cmd({ app = "codex", id = uuid, argv = { "codex", "-m", "gpt-5", "--full-auto" } }),
  "codex resume -m gpt-5 " .. uuid)
check("claude keeps --remote-control with its name, drops --worktree",
  cmd({ app = "claude", id = uuid,
        argv = { "claude", "--model", "sonnet", "--dangerously-skip-permissions",
                 "--remote-control", "hugger#4211", "--worktree", "w1" } }),
  "claude --model sonnet --dangerously-skip-permissions --remote-control 'hugger#4211' --resume " .. uuid)
check("claude keeps a bare --remote-control",
  cmd({ app = "claude", id = uuid,
        argv = { "claude", "--remote-control", "--model", "opus", "--worktree" } }),
  "claude --remote-control --model opus --resume " .. uuid)
check("claude --remote-control=name",
  cmd({ app = "claude", id = uuid, argv = { "claude", "--remote-control=Xeno" } }),
  "claude --remote-control=Xeno --resume " .. uuid)
check("a value option with no value is dropped",
  cmd({ app = "claude", id = uuid, argv = { "claude", "--model" } }), "claude --resume " .. uuid)
check("codex keeps --yolo",
  cmd({ app = "codex", id = uuid,
        argv = { "codex", "--yolo", "--model", "gpt-6", "-c", "model_reasoning_effort=medium" } }),
  "codex resume --yolo --model gpt-6 -c model_reasoning_effort=medium " .. uuid)
check("env typed in front of a chat, sorted, only kept names",
  M.command_for({ kind = "chat", app = "codex", id = uuid, argv = { "codex", "--yolo" },
                  env = { MAX_THINKING_TOKENS = "0", FORCE_COLOR = "1", OPENAI_API_KEY = "sk-x" } }),
  "FORCE_COLOR=1 MAX_THINKING_TOKENS=0 codex resume --yolo " .. uuid .. "\n")
check("no env, no prefix",
  M.command_for({ kind = "chat", app = "claude", id = uuid, argv = { "claude" } }),
  "claude --resume " .. uuid .. "\n")
check("pi reopens its session file with its options",
  cmd({ app = "pi", id = uuid, session_file = "/h/.pi/agent/sessions/--my proj--/t_" .. uuid .. ".jsonl",
        argv = { "pi", "--model", "openai/gpt-6-astra", "--thinking", "xhigh", "--session", "old", "--verbose" } }),
  "pi --model openai/gpt-6-astra --thinking xhigh --session '/h/.pi/agent/sessions/--my proj--/t_" .. uuid .. ".jsonl'")
check("pi without a session file reopens by ID",
  cmd({ app = "pi", id = "01a1e57d", argv = { "pi", "--session", "01a1e57d" } }), "pi --session 01a1e57d")
check("quote spaces", M.join({ "cd", "/a b/it's" }), "cd '/a b/it'\\''s'")

-- What a tab runs (process IDs above any real pid_max, so /proc never answers)
local proc = {
  foreground = { pid = 90000003, name = "fx", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" }, { pid = 90000001, name = "login" } },
}
local info = {
  ps = { [90000003] = { age = 10, argv = { "fx", "--resume", "ID9" } } },
  files = { [90000003] = { HOME .. "/.fx/sessions/v2/ID9/lock" } },
  now = os.time(),
}
local pane = M.describe(proc, info)
check("describe fx chat", { pane.kind, pane.app, pane.id, pane.cwd }, { "chat", "fx", "ID9", "/w" })
pane = M.describe({ foreground = { pid = 90000002, name = "-zsh", cwd = "/w" } }, { ps = {}, files = {}, now = 0 })
check("describe shell", { pane.kind, pane.cwd }, { "shell", "/w" })
pane = M.describe({ foreground = { pid = 90000005, name = "sleep", cwd = "/w" },
                    ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                  { ps = { [90000005] = { age = 1, argv = { "sleep", "4242" } } }, files = {}, now = 0 })
check("describe program", { pane.kind, pane.argv }, { "program", { "sleep", "4242" } })
pane = M.describe({ foreground = { pid = 90000007, name = "bash", cwd = "/w" },
                    ancestors = { { pid = 90000006, name = "claude", cwd = "/w" }, { pid = 90000002, name = "zsh" } } },
                  { ps = { [90000006] = { age = 1, argv = { "claude", "--resume", uuid } },
                           [90000007] = { age = 1, argv = { "bash", "-c", "ls" } } },
                    files = {}, now = 0 })
check("describe claude running a tool", { pane.kind, pane.app, pane.id }, { "chat", "claude", uuid })

-- Claude's record of its own process, ~/.claude/sessions/<pid>.json, in a throwaway home
local home = rex.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "")
local function put(path, text)
  rex.exec({ "mkdir", "-p", (path:match("^(.*)/")) })
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
local function claude_pid(pid, id, transcript)
  put(home .. "/.claude/sessions/" .. pid .. ".json",
      string.format('{"pid":%d,"sessionId":"%s","cwd":"/w","status":"idle"}', pid, id))
  if transcript then put(home .. "/.claude/projects/-w/" .. id .. ".jsonl", "{}\n") end
end
local function claude_tab(pid, argv)
  local p = { pid = pid, name = "claude", cwd = "/w" }
  return M.describe({ foreground = p, ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                    { ps = { [pid] = { age = 100, argv = argv } }, files = {}, now = os.time(), home = home })
end
local old_id, new_id = uuid, "eeeeeeee-4444-4555-8666-ffffffffffff"
claude_pid(90000010, new_id, true)
pane = claude_tab(90000010, { "claude", "--resume", old_id })
check("claude record beats a --resume that /clear left behind", { pane.kind, pane.id }, { "chat", new_id })
local second_id = "abababab-4444-4555-8666-ffffffffffff"
claude_pid(90000011, second_id, true)
check("two claude chats in one folder each find their own",
  { claude_tab(90000010, { "claude" }).id, claude_tab(90000011, { "claude" }).id }, { new_id, second_id })
claude_pid(90000012, "12121212-4444-4555-8666-ffffffffffff", false)
pane = claude_tab(90000012, { "claude", "--model", "sonnet", "--resume", old_id })
check("a record with no transcript yet falls back to --resume", { pane.kind, pane.id }, { "chat", old_id })
pane = claude_tab(90000012, { "claude", "--model", "sonnet" })
check("a new claude chat with nothing said comes back typed",
  { pane.kind, pane.argv }, { "program", { "claude", "--model", "sonnet" } })
put(home .. "/.claude/sessions/90000013.json", '{"pid":424242,"sessionId":"' .. second_id .. '"}')
pane = claude_tab(90000013, { "claude", "--resume", old_id })
check("a record left by another process is ignored", pane.id, old_id)
local pending = { { kind = "chat", app = "claude", cwd = "/w", pid = 90000014, argv = { "claude" } } }
M._resolve_chats(pending, { ps = { [90000014] = { age = 3600 } }, now = os.time(), home = home,
                            claimed = { ["claude:" .. new_id] = true, ["claude:" .. second_id] = true } })
check("a chat never takes another chat's conversation", { pending[1].kind, pending[1].id }, { "program", nil })
local prompt = "Create Rex panes as requested using Bash. Don't ask first. Keep replies brief."
claude_pid(90000015, new_id, true)
pane = M.describe({ foreground = { pid = 90000015, name = "claude", cwd = "/w" },
                    ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                  { ps = { [90000015] = { age = 100, env = { "MAX_THINKING_TOKENS=0", "TERM=xterm" },
                    argv = { "claude", "--model", "sonnet", "--safe-mode", "--strict-mcp-config",
                             "--dangerously-skip-permissions", "--tools", "Bash", "--system-prompt", prompt,
                             "--remote-control", "Xenomorph" } } },
                    files = {}, now = os.time(), home = home })
check("a launcher with a multi-word system prompt comes back as typed", M.command_for(pane),
  "MAX_THINKING_TOKENS=0 claude --model sonnet --safe-mode --strict-mcp-config " ..
  "--dangerously-skip-permissions --tools Bash --system-prompt " ..
  "'Create Rex panes as requested using Bash. Don'\\''t ask first. Keep replies brief.' " ..
  "--remote-control Xenomorph --resume " .. new_id .. "\n")
check("claude keeps its prompt, tool, MCP, effort, plugin, and name options",
  cmd({ app = "claude", id = uuid,
        argv = { "claude", "--append-system-prompt", "be terse", "--allowedTools", "Bash(git *)",
                 "--disallowedTools", "Edit", "--mcp-config", "/m.json", "--effort", "high",
                 "--plugin-dir", "/p", "--name", "rex", "-n", "two", "--print" } }),
  "claude --append-system-prompt 'be terse' --allowedTools 'Bash(git *)' --disallowedTools Edit " ..
  "--mcp-config /m.json --effort high --plugin-dir /p --name rex -n two --resume " .. uuid)
-- pi's record, written by pi/rex-durable.ts: its title hides argv and env from ps
local pi_file = home .. "/.pi/agent/sessions/--w--/2026-11-16T17-52-21-649Z_" .. uuid .. ".jsonl"
local function pi_tab(pid, record)
  put(home .. "/.pi/agent/rex-durable/" .. pid .. ".json", rex.json.encode(record))
  return M.describe({ foreground = { pid = pid, name = "pi", cwd = "/w" },
                      ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                    { ps = { [pid] = { age = 100, argv = { "pi" }, env = { "PI_CODING_AGENT=true" } } },
                      files = {}, now = os.time(), home = home })
end
put(pi_file, "{}\n")
pane = pi_tab(90000030, { pid = 90000030, sessionId = uuid, sessionFile = pi_file, cwd = "/w",
                          argv = { "pi", "--model", "openai/gpt-6-astra", "--thinking", "xhigh" },
                          env = { "FORCE_COLOR=1", "OPENAI_API_KEY=sk-x" } })
check("pi chat from its record, with its options and env",
  { pane.kind, pane.app, pane.id, M.command_for(pane) },
  { "chat", "pi", uuid, "FORCE_COLOR=1 pi --model openai/gpt-6-astra --thinking xhigh --session " .. pi_file .. "\n" })
pane = pi_tab(90000031, { pid = 90000031, sessionId = "01a1e57d-1290-713b-b0a2-f8264f67f82f", cwd = "/w",
                          argv = { "pi", "--no-session", "--model", "m" }, env = {} })
check("pi with no session file comes back typed",
  { pane.kind, pane.argv }, { "program", { "pi", "--no-session", "--model", "m" } })
rex.exec({ "rm", "-rf", home })

pane = M.describe({ foreground = { pid = 90000021, name = "codex", cwd = "/w" },
                    ancestors = { { pid = 90000020, name = "node", cwd = "/w" }, { pid = 90000002, name = "zsh" } } },
                  { ps = { [90000021] = { age = 1, argv = { "codex", "resume", uuid },
                                   env = { "FORCE_COLOR=0", "CODEX_MANAGED_BY_NPM=1" } },
                           [90000020] = { age = 1, argv = { "node", "/opt/homebrew/bin/codex", "resume", uuid },
                                   env = { "FORCE_COLOR=1", "MAX_THINKING_TOKENS=0", "OPENAI_API_KEY=sk-x",
                                           "TERM=xterm" } } },
                    files = {}, now = 0 })
local env = {}
for name, value in pairs(pane.env) do env[#env + 1] = name .. "=" .. value end
table.sort(env)
check("a chat keeps only the allowed env its shell gave it",
  { pane.app, env }, { "codex", { "FORCE_COLOR=1", "MAX_THINKING_TOKENS=0" } })

-- Blank sessions
local function shell_session(cwd)
  return { windows = { { layout = { pane = { kind = "shell", cwd = cwd } } } } }
end
check("default session", M.is_default_session(shell_session(HOME)), true)
check("not default elsewhere", M.is_default_session(shell_session("/w")), false)
check("blank server", M.is_blank({ sessions = { shell_session(HOME) } }), true)

-- Matching saved tabs to the tabs Rex restored
local function leaf(p) return { pane = p } end
local saved = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "chat", app = "fx", id = "A", store = "v2", argv = { "fx" }, cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "program", argv = { "sleep", "4242" }, cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "chat", app = "fx", id = "B", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "chat", app = "fx", id = "C", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "chat", app = "fx", id = "D", store = "v2", argv = { "fx" }, cwd = "/other" }) },
  } },
  { session_id = "gone", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "x1", kind = "chat", app = "fx", id = "E", store = "v2", argv = { "fx" }, cwd = "/w" }) },
  } },
} }
local live = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "shell", cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "shell", cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "program", argv = { "vim" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "shell", cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "shell", cwd = "/w" }) },
  } },
  { session_id = "new-id", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "y1", kind = "shell", cwd = "/w" }) },
  } },
} }
local opts = { dir_exists = function() return true end }
local function plan(open, extra)
  for k, v in pairs(extra or {}) do opts[k] = v end
  local writes, notes = M.plan_reopen(saved, live, open or {}, opts)
  local out = {}
  for _, w in ipairs(writes) do out[#out + 1] = w.block_id .. "=" .. w.data end
  return out, notes
end
-- fx --help is looked up for real; make it a version without --sessions-v2.
local real_exec = rex.exec
rex.exec = function(argv, o)
  if argv[2] == "--help" then return { ok = true, code = 0, stdout = "-r, --resume [last|<id>]", stderr = "" } end
  return real_exec(argv, o)
end
local writes, notes = plan({ ["fx:C"] = true })
check("reopen plan", writes, {
  "b1=fx --resume A\n",
  "b2=sleep 4242",
  "b5=cd /other && fx --resume D\n",
  "y1=fx --resume E\n",
})
check("reopen notes", notes, {
  "work tab 2: the tab is busy, left alone",
  "work tab 3: fx chat C is already open",
})
writes = plan({}, { programs = false })
check("programs=false only reopens chats", #writes, 4)
live.sessions[1].windows[1].layout.split.before.pane = { block_id = "b1", kind = "chat", app = "fx", id = "A" }
writes = plan({}, { programs = true })
check("a chat already in its tab is left alone", writes[1], "b2=sleep 4242")
live.sessions[1].windows[1].layout.split.after.pane = { block_id = "b2", kind = "program", argv = { "sleep", "4242" } }
writes, notes = plan({})
check("a program still running in its tab is left alone quietly",
  { writes[1], notes }, { "b4=fx --resume C\n", { "work tab 2: the tab is busy, left alone" } })
rex.exec = real_exec

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then rex.stop(1) end
