#!/bin/bash
# End-to-end test of rex-durable on a throwaway Rex server.
#
#   test/e2e.sh                 (needs Rex installed and a C compiler)
#   test/e2e.sh --unit          only the unit tests
#   REX=/path/to/rex test/e2e.sh
#
# It runs its own Rex server on its own socket and state folder, with fake
# fx, Claude Code, Codex, and pi chats that keep their files in a throwaway home
# folder. It never connects to your own Rex server or touches your real chats,
# and it stops only the server it started, by its process ID.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
os=$(uname -s)
if [ -z "${REX:-}" ]; then
  current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ "$os" = Darwin ] && [ -x "$current" ]; then REX=$current; else REX=$(command -v rex); fi
fi

T=$(cd "$(mktemp -d /tmp/rex-durable-e2e.XXXXXX)" && pwd -P)
H=$T/home
mkdir -p "$H" "$T/bin" "$T/state" "$T/durable" "$T/my proj" "$T/two"
: >"$T/init.lua"
SOCK="unix://$T/rex.sock"
passed=0
failed=0

clean_env() { env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG "$@"; }
R() { clean_env "$REX" --autostart=false -S "$SOCK" "$@"; }
D() { HOME="$H" R do "$here/durable.lua" "state_dir=$T/durable" notify=false "$@"; }
show() { HOME="$H" R do "$here/test/e2e_show.lua" "state_dir=$T/durable"; }

server_pid=""
watch_pid=""
start_server() {
  # Not through a shell function: $! must be the server itself, so stopping
  # it really stops the server, the way a restart does.
  env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG \
    -u FORCE_COLOR -u MAX_THINKING_TOKENS \
    "$REX" server run --listen "$SOCK" --state-dir "$T/state" --config "$T/init.lua" "$@" \
    >>"$T/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    if R ls >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "the test server didn't start:"; cat "$T/server.log"; exit 1
}
stop_server() {
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      echo "the test server didn't stop; killing it"
      kill -KILL "$server_pid" 2>/dev/null || true
      failed=$((failed + 1))
    fi
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  sleep 1
}
cleanup() {
  rm -f "$T/supervise"
  [ -n "$watch_pid" ] && kill "$watch_pid" 2>/dev/null || true
  pkill -f "state_dir=$T/durable" 2>/dev/null || true
  stop_server
  pkill -f "$T/bin/" 2>/dev/null || true
  if [ "$failed" -gt 0 ] || [ "${KEEP:-0}" = 1 ]; then
    echo "Kept the test folder for a look: $T"
  else
    rm -rf "$T"
  fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
expect() { # description, command...
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
running() { pgrep -f -x "$1" | wc -l | tr -d ' '; }
one_running() { [ "$(running "$1")" = 1 ]; }
has_words() { # text, words...
  local text=$1; shift
  for w in "$@"; do printf '%s\n' "$text" | tr ' ' '\n' | grep -qx -- "$w" || return 1; done
}
has_line() { printf '%s\n' "$listing" | grep -E -q -- "$1"; }
# The block ID of a tab in a listing: block LISTING SESSION WINDOW.PANE
block() { printf '%s\n' "$1" | awk -v s="$2" -v tab="$3" '$1 == s && $2 == tab { print $NF }'; }

for app in fx claude codex pi; do
  cc -O0 -o "$T/bin/$app" -DAPP="\"$app\"" -DFAKE_HOME="\"$H\"" "$here/test/fake.c"
done
CODEX_ID=11111111-2222-4333-8444-555555555555

echo "0. Unit tests"
start_server
if R do "$here/test/unit.lua" >"$T/unit.log" 2>&1; then ok "$(tail -1 "$T/unit.log")"; else cat "$T/unit.log"; bad "unit tests"; fi
if [ "${1:-}" = "--unit" ]; then echo; echo "$passed passed, $failed failed"; [ "$failed" = 0 ]; exit; fi

echo "1. Save what runs in each tab"
R do "$here/test/e2e_setup.lua" "bin=$T/bin" "dir=$T/my proj" "dir2=$T/two" >/dev/null
sleep 3
D mode=save
listing=$(show)
expect "fx chat and its conversation" has_line '^work 1\.1 chat fx FXA '
expect "codex chat from its open rollout file" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "new claude chat from its newest session file" has_line '^work 2\.1 chat claude 00000000-0000-4000-8000-'
expect "another program and its command" has_line '^work 3\.1 program - sleep 4242 '
expect "a plain shell" has_line '^work 4\.1 shell '
expect "a second session" has_line '^side 1\.1 chat fx FXB '
before=$listing
CLAUDE_ID=$(printf '%s\n' "$listing" | awk '$1 == "work" && $2 == "2.1" { print $5 }')
AGENT1=$(printf '%s\n' "$listing" | awk '$1 == "agents" && $2 == "1.1" && $3 == "chat" { print $5 }')
AGENT2=$(printf '%s\n' "$listing" | awk '$1 == "agents" && $2 == "2.1" && $3 == "chat" { print $5 }')
expect "two claude chats in one folder, each on its own conversation" \
  test -n "$AGENT1" -a -n "$AGENT2" -a "$AGENT1" != "$AGENT2"
expect "pi chat from the record its extension writes" has_line '^agents 3\.1 chat pi 00000000-0000-7000-8000-'
PI_ID=$(printf '%s\n' "$listing" | awk '$1 == "agents" && $2 == "3.1" { print $5 }')
pi_folder="${T#/}/my proj"
PI_FILE="$H/.pi/agent/sessions/--${pi_folder//\//-}--/2026-11-13T10-00-00-000Z_$PI_ID.jsonl"

echo "2. Restart: Rex brings back the tabs, rex-durable the programs"
stop_server
expect "the fake chats stopped with the server" test "$(running "$T/bin/fx --resume FXA")" = 0
start_server
# A chat already open outside Rex must not be opened a second time.
(cd "$T" && exec "$T/bin/fx" --resume FXC >/dev/null) &
outside_pid=$!
sleep 1
# A restored tab that is busy for a few seconds, as when a shell's startup runs
# commands: rex-durable must wait for it, then reopen its chat.
R do -s side -e "rex.block.call('com.superlogical.terminal', 'write', \
  { block_id = '$(block "$before" side 1.1)', data = 'sleep 8\\n' }) return 'ok'" >/dev/null
# Wait until it really runs: a shell that is still starting runs it later.
for _ in $(seq 1 40); do
  [ "$(running "sleep 8")" = 1 ] && break
  sleep 0.25
done
D mode=startup >"$T/startup.log"
sleep 3
D mode=save
listing=$(show)
expect "fx chat reopened in the same tab" has_line "^work 1\.1 chat fx FXA $(block "$before" work 1.1)\$"
expect "codex chat reopened on its conversation" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "claude chat reopened on its conversation" has_line "^work 2\.1 chat claude $CLAUDE_ID "
expect "first claude chat in a shared folder reopened with its options" \
  one_running "$T/bin/claude --model sonnet --dangerously-skip-permissions --remote-control hugger#4211 --resume $AGENT1"
expect "second claude chat in that folder reopened with its options" \
  one_running "$T/bin/claude --remote-control --model opus --resume $AGENT2"
agent_env=$(ps -wwE -o command= -p "$(pgrep -f -x "$T/bin/claude --model sonnet .* --resume $AGENT1")")
expect "its env came back" has_words "$agent_env" FORCE_COLOR=3 MAX_THINKING_TOKENS=0
expect "and no env it doesn't keep" sh -c 'case "$1" in *SECRET_TOKEN*) exit 1 ;; esac' sh "$agent_env"
expect "pi chat reopened on its session file with its options" \
  one_running "$T/bin/pi --model openai/gpt-6-astra --thinking xhigh --session $PI_FILE"
pi_env=$(ps -wwE -o command= -p "$(pgrep -f -x "$T/bin/pi .* --session $PI_FILE")")
expect "pi's env came back" has_words "$pi_env" FORCE_COLOR=2
expect "no unkept env in any save" sh -c "! grep -rq hush '$T/durable'"
expect "a busy tab was waited for" grep -q 'trying again' "$T/startup.log"
expect "second session's chat reopened once its tab was free" has_line '^side 1\.1 chat fx FXB '
expect "program typed, not run" test "$(running "sleep 4242")" = 0
expect "program's command is waiting at the prompt" \
  sh -c "'$REX' --autostart=false -S '$SOCK' capture --trim -s work -b '$(block "$before" work 3.1)' | tail -1 | grep -q 'sleep 4242'"
expect "chat already open elsewhere left alone" grep -q 'fx chat FXC is already open' "$T/startup.log"
expect "one copy of each chat" test "$(running "$T/bin/fx --resume FXA")" = 1
expect "the outside copy is the only FXC" test "$(running "$T/bin/fx --resume FXC")" = 1

echo "3. Run again on the same server: nothing is opened twice"
D mode=startup >"$T/startup2.log"
sleep 2
expect "no second copy of a chat" test "$(running "$T/bin/fx --resume FXA")" = 1
expect "no second claude" test "$(running "$T/bin/claude --resume $CLAUDE_ID")" = 1
expect "nothing typed the second time" sh -c "! grep -q ' type ' '$T/startup2.log'"

echo "4. A server that starts empty: rex-durable rebuilds the sessions"
stop_server
start_server --restore=false
expect "the new server starts with no sessions" \
  test "$(R do -e 'return #((rex.call("session.list") or {}).sessions or {})')" = 0
D mode=startup >"$T/startup3.log"
sleep 3
D mode=save
listing=$(show)
expect "work session rebuilt with its chats" has_line '^work 1\.1 chat fx FXA '
expect "split rebuilt" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "side session rebuilt" has_line '^side 1\.1 chat fx FXB '
expect "still only the outside FXC" test "$(running "$T/bin/fx --resume FXC")" = 1
kill "$outside_pid" 2>/dev/null || true

echo "5. The watcher, kept running like a login service, brings programs back by itself"
# launchd and systemd start the watcher again whenever it exits; so does this loop.
touch "$T/supervise"
(
  while [ -e "$T/supervise" ]; do
    HOME="$H" R do "$here/durable.lua" --all mode=watch "rex=$REX" "script=$here/durable.lua" \
      "server=$SOCK" "state_dir=$T/durable" notify=false >>"$T/watch.log" 2>&1 || true
    sleep 1
  done
) &
watch_pid=$!
sleep 4
expect "watcher started" grep -q 'watching' "$T/watch.log"
# The tabs rebuilt in step 4 got new block IDs, so this restart also checks
# finding tabs by session and position.
stop_server
start_server
for _ in $(seq 1 40); do
  grep -q 'reopened [1-9]' "$T/watch.log" && break
  sleep 0.5
done
expect "watcher reopened the chats after the restart" grep -q 'reopened [1-9]' "$T/watch.log"
sleep 2
D mode=save
listing=$(show)
expect "fx chat back in its tab" has_line '^work 1\.1 chat fx FXA '
expect "codex chat back in its split" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "claude chat back" has_line "^work 2\.1 chat claude $CLAUDE_ID "
expect "first claude chat in a shared folder back" has_line "^agents 1\.1 chat claude $AGENT1 "
expect "second claude chat in a shared folder back" has_line "^agents 2\.1 chat claude $AGENT2 "
expect "pi chat back" has_line "^agents 3\.1 chat pi $PI_ID "
expect "side session's chat back" has_line '^side 1\.1 chat fx FXB '
expect "one copy of each chat" test "$(running "$T/bin/fx --resume FXA")" = 1
rm -f "$T/supervise"
pkill -f "state_dir=$T/durable" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=""

echo "6. The command palette actions load"
sed -e "s|@REX@|$REX|" -e "s|@SCRIPT@|$here/durable.lua|" "$here/rex_durable.lua" >"$T/rex_durable.lua"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("rex_durable")\n' "$T" >"$T/check.lua"
expect "rex config check passes" sh -c "'$REX' config check '$T/check.lua' >'$T/check.log' 2>&1"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
