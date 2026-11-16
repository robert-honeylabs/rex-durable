#!/bin/sh
# Install rex-durable: copy durable.lua and run it as a login service, so the
# programs in your Rex tabs come back after a restart.
#
#   ./install.sh                  install, or update an existing install
#   ./install.sh --add-to-config  also load the command palette actions from init.lua
#   ./install.sh --no-service     copy the files only; run durable.lua yourself
#   REX=/path/to/rex ./install.sh use this rex command
#
# Remove it with ./uninstall.sh.
set -eu

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "install.sh: HOME is not set to a folder" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
os=$(uname -s)
add_to_config=0
service=1
for arg in "$@"; do
  case "$arg" in
    --add-to-config) add_to_config=1 ;;
    --no-service) service=0 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

case "$os" in
  Darwin)
    data="$HOME/Library/Application Support/rex-durable"
    log="$HOME/Library/Logs/rex-durable.log"
    ;;
  Linux|FreeBSD)
    data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-durable"
    log=""
    ;;
  *) fail "unsupported system $os (rex-durable runs on macOS and Linux)" ;;
esac
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
script="$data/durable.lua"

# The rex command. On macOS, prefer the server's "Current" copy: it is the
# path Rex itself puts on PATH, and it stays the same across Rex updates.
find_rex() {
  if [ -n "${REX:-}" ]; then printf '%s\n' "$REX"; return 0; fi
  if [ "$os" = Darwin ]; then
    current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    if [ -x "$current" ]; then printf '%s\n' "$current"; return 0; fi
  fi
  if command -v rex >/dev/null 2>&1; then command -v rex; return 0; fi
  if [ "$os" = Darwin ]; then
    for candidate in /Applications/Rex*.app/Contents/Helpers/*/Contents/MacOS/rex \
                     "$HOME"/Applications/Rex*.app/Contents/Helpers/*/Contents/MacOS/rex \
                     /Applications/Rex*.app/Contents/Helpers/rex; do
      if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
  fi
  return 1
}
rex=$(find_rex) || fail "can't find the rex command. Open Rex once, or run REX=/path/to/rex ./install.sh"
say "Using rex: $rex"

# Check that this Rex has the Lua API rex-durable needs, if a server is up.
check=$("$rex" --autostart=false do -e 'return (rex.exec and rex.every and rex.json and rex.on) and "ok" or "old"' 2>/dev/null || true)
case "$check" in
  *ok*) ;;
  *old*) fail "this Rex is too old for rex-durable; update Rex and try again" ;;
  *) say "Note: no Rex server is running, so the Rex version wasn't checked." ;;
esac

mkdir -p "$data"
cp "$here/durable.lua" "$script.new" && mv "$script.new" "$script"
say "Installed $script"

# ps loses option values with spaces on macOS; procargs reads the exact command line.
if [ "$os" = Darwin ]; then
  if command -v cc >/dev/null 2>&1 && cc -O2 -o "$data/procargs.new" "$here/procargs.c"; then
    mv "$data/procargs.new" "$data/procargs"
    say "Built $data/procargs"
  else
    rm -f "$data/procargs.new"
    say "Warning: couldn't build procargs (install the Xcode command line tools: xcode-select --install)."
    say "  Chats still reopen, but option values with spaces come back split into words."
  fi
fi

# pi hides which conversation it's on; this extension tells rex-durable.
pi_agent="$HOME/.pi/agent"
if [ -d "$pi_agent" ]; then
  mkdir -p "$pi_agent/extensions"
  cp "$here/pi/rex-durable.ts" "$pi_agent/extensions/rex-durable.ts.new" &&
    mv "$pi_agent/extensions/rex-durable.ts.new" "$pi_agent/extensions/rex-durable.ts"
  say "Installed the pi extension $pi_agent/extensions/rex-durable.ts"
fi

# A PATH for the service, so it finds lsof, fx, claude, and codex.
service_path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for tool in fx claude codex; do
  where=$(command -v "$tool" 2>/dev/null || true)
  case "$where" in
    /*)
      dir=$(dirname "$where")
      case ":$service_path:" in
        *":$dir:"*) ;;
        *) service_path="$dir:$service_path" ;;
      esac
      ;;
  esac
done

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$service" = 1 ]; then
  if [ "$os" = Darwin ]; then
    label=io.github.fazxes.rex-durable
    plist="$HOME/Library/LaunchAgents/$label.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$log")"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$rex")</string>
    <string>--autostart=false</string>
    <string>do</string>
    <string>$(xml "$script")</string>
    <string>--all</string>
    <string>mode=watch</string>
    <string>$(xml "rex=$rex")</string>
    <string>$(xml "script=$script")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(xml "$service_path")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$log")</string>
  <key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    say "Started the login service $label (log: $log)"
  elif command -v systemctl >/dev/null 2>&1; then
    units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$units"
    cat >"$units/rex-durable.service" <<EOF
[Unit]
Description=rex-durable: bring back the programs in your Rex tabs after a restart

[Service]
ExecStart="$rex" --autostart=false do "$script" --all mode=watch "rex=$rex" "script=$script"
Restart=always
RestartSec=10
Environment="PATH=$service_path"

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now rex-durable.service
    systemctl --user restart rex-durable.service
    say "Started the systemd user service rex-durable (log: journalctl --user -u rex-durable)"
  else
    say "No launchd or systemd here. Keep this running yourself, for example from your shell profile:"
    say "  \"$rex\" --autostart=false do \"$script\" --all mode=watch \"rex=$rex\" \"script=$script\" &"
  fi
fi

# Command palette actions, loaded from init.lua with require("rex_durable").
lua_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
sed_text() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
mkdir -p "$config"
sed -e "s|@REX@|$(sed_text "$(lua_string "$rex")")|" \
    -e "s|@SCRIPT@|$(sed_text "$(lua_string "$script")")|" \
    "$here/rex_durable.lua" >"$config/rex_durable.lua"
say "Installed command palette actions in $config/rex_durable.lua"

init="$config/init.lua"
if [ -f "$init" ] && grep -q 'rex_durable' "$init"; then
  "$rex" --autostart=false config reload >/dev/null 2>&1 || true
elif [ "$add_to_config" = 1 ]; then
  printf '\n-- rex-durable: command palette actions\nrequire("rex_durable")\n' >>"$init"
  "$rex" --autostart=false config reload >/dev/null 2>&1 || true
  say "Added require(\"rex_durable\") to $init"
else
  say "To add its actions to the command palette, add this line to $init:"
  say "  require(\"rex_durable\")"
  say "(or run ./install.sh --add-to-config)"
fi

say ""
say "Done. rex-durable now saves what runs in your tabs and brings it back after a restart."
say "Check on it any time with:"
say "  \"$rex\" do \"$script\" mode=status"
