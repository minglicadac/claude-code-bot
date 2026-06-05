#!/usr/bin/env bash
set -euo pipefail

# Cron strips the environment, so serialize what we need into a sourceable file.
# %q quotes safely (handles spaces, $, !, etc. in PATs and passwords).
{
  for v in AZURE_DEVOPS_ORG AZURE_DEVOPS_PROJECT AZURE_DEVOPS_USER_EMAIL AZURE_DEVOPS_EXT_PAT \
           ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
           ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
           DATABASE_URL WEBHOOK_PORT; do
    printf 'export %s=%q\n' "$v" "${!v-}"
  done

  # @azure-devops/mcp PAT auth wants base64('email:pat') in PERSONAL_ACCESS_TOKEN.
  pat_b64=$(printf '%s:%s' "${AZURE_DEVOPS_USER_EMAIL-}" "${AZURE_DEVOPS_EXT_PAT-}" | base64 -w 0)
  printf 'export %s=%q\n' PERSONAL_ACCESS_TOKEN "$pat_b64"
} > /etc/claude-robot.env
chmod 0644 /etc/claude-robot.env

# Start the webhook server in the background.
# Runs as root; the Node process spawns `claude.sh` which re-execs as the robot user.
node /usr/local/bin/webhook-server.js >> /var/log/claude-robot.log 2>&1 &
echo "=== $(date -Iseconds) webhook server started (pid=$!) ==="

# Start cron in the foreground (the main process).
exec cron -f
