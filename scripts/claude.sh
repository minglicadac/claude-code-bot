#!/usr/bin/env bash
set -euo pipefail

# Claude Code refuses bypass mode as root. If invoked as root (e.g. plain
# `docker compose exec claude-robot ...`), re-exec self as the robot user.
if [[ "$(id -u)" -eq 0 ]]; then
  exec runuser -u robot -- "$0" "$@"
fi

# Cron strips the environment; sync-bugs.sh and any other cron-driven caller
# needs the entrypoint-generated env file. Sourcing it from interactive
# `docker exec` sessions is harmless (same values).
# shellcheck disable=SC1091
[[ -f /etc/claude-robot.env ]] && source /etc/claude-robot.env

cd /workspace
exec claude "$@"
