-- End-to-end test setup: three sessions with fake chats, a program, and a
-- shell. Run by test/e2e.sh as: rex do test/e2e_setup.lua bin=DIR dir=DIR dir2=DIR

local bin, dir, dir2 = rex.args.bin, rex.args.dir, rex.args.dir2
local SHELL = "com.superlogical.terminal.shell"

local function q(word) return "'" .. word:gsub("'", "'\\''") .. "'" end
local function tab(command, cwd)
  local options = { cwd = cwd or dir }
  if command then options.initial_input = command .. "\n" end
  return { block = { flavor = SHELL, options = options } }
end

assert(rex.call("session.create", { label = "work", initial_windows = {
  { layout = { split = { direction = "horizontal", ratio = 0.5,
    before = tab(q(bin .. "/fx") .. " --resume FXA"),
    after = tab(q(bin .. "/codex") .. " resume 11111111-2222-4333-8444-555555555555") } } },
  -- A new conversation without a record of its process, found by its file.
  { layout = tab("FAKE_NO_RECORD=1 " .. q(bin .. "/claude")) },
  { layout = tab("sleep 4242") },          -- another program
  { layout = tab(nil) },                   -- a plain shell
  { layout = tab(q(bin .. "/fx") .. " --resume FXC") },
} }))
assert(rex.call("session.create", { label = "side", initial_windows = {
  { layout = tab(q(bin .. "/fx") .. " --resume FXB") },
} }))
-- Two Claude Code chats in one folder, told apart by their process records.
assert(rex.call("session.create", { label = "agents", initial_windows = {
  { layout = tab(q(bin .. "/claude") .. " --model sonnet --dangerously-skip-permissions" ..
                 " --remote-control 'hugger#4211' --worktree w1", dir2) },
  { layout = tab(q(bin .. "/claude") .. " --remote-control --model opus", dir2) },
} }))
return "ok"
