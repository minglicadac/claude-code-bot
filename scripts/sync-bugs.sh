#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /etc/claude-robot.env

echo "=== $(date -Iseconds) sync start (user=$(id -un)) ==="

/usr/local/bin/claude.sh \
  -p \
  --permission-mode bypassPermissions \
  --output-format json \
  "Use the azure-devops MCP to fetch the 5 most recently changed bugs (work-item type 'Bug') in project '${AZURE_DEVOPS_PROJECT}' under org '${AZURE_DEVOPS_ORG}', ordered by [System.ChangedDate] DESC. For each bug, upsert a row into the 'bugs' table via the postgres MCP, keyed on id. Capture: id, title, state, assigned_to, priority, severity, tags, area_path, iteration_path, created_date, changed_date, and the full work item as 'raw' (jsonb). Set synced_at = now(). Print a one-line summary of how many bugs were inserted/updated."

echo "=== $(date -Iseconds) sync end ==="
