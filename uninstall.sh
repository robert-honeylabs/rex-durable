#!/bin/sh
# Remove rex-durable: stop its service and delete its files.
#
#   ./uninstall.sh          keep your saves, in case you install it again
#   ./uninstall.sh --purge  delete the saves too
#
# Your Rex sessions and the programs in them are not touched.
set -eu

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "uninstall.sh: HOME is not set to a folder" >&2
  exit 1
fi

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

os=$(uname -s)
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
if [ "$os" = Darwin ]; then
  data="$HOME/Library/Application Support/rex-durable"
  state="$data"
  label=io.github.fazxes.rex-durable
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
else
  data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-durable"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-durable"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now rex-durable.service 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rex-durable.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

rm -f "$data/durable.lua" "$data/procargs" "$config/rex_durable.lua" "$HOME/.pi/agent/extensions/rex-durable.ts"
rm -rf "$HOME/.pi/agent/rex-durable"
if [ "$purge" = 1 ]; then
  rm -rf "$data" "$state"
  echo "Removed rex-durable and its saves."
else
  echo "Removed rex-durable. Your saves are still in $state (delete them with --purge)."
fi
if [ -f "$config/init.lua" ] && grep -q 'rex_durable' "$config/init.lua"; then
  echo "Remove the require(\"rex_durable\") line from $config/init.lua, then run: rex config reload"
fi
