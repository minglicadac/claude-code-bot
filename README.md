# claude-robot

A Dockerized Claude Code that runs headlessly on a cron, pulls the 5 most recently changed bugs from an Azure DevOps project via the official `@azure-devops/mcp` server, and upserts them into a bundled PostgreSQL via `@henkey/postgres-mcp-server`.

Also runs a **webhook server** on port 8080 that receives Azure DevOps service hook events (work item comments, PRs, builds) via a **Cloudflare Tunnel** and dispatches them to Claude Code for real-time processing.

Everything Claude needs — auth, MCP servers, ADO PAT, schedule — is configured through environment variables and host-mounted config files.


## Setup

1. Copy the template and fill it in:
   ```sh
   cp .env.example .env
   ```

   Required values:
   ```
   AZURE_DEVOPS_ORG=org-name
   AZURE_DEVOPS_PROJECT=project-name
   AZURE_DEVOPS_USER_EMAIL=you@you.com
   AZURE_DEVOPS_EXT_PAT=<PAT for the above user>

   ANTHROPIC_BASE_URL=https://ollama.com/
   ANTHROPIC_AUTH_TOKEN=<token for the Anthropic-compatible endpoint>
   ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.1:cloud
   ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro:cloud
   ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k2.6:cloud
   ```

   The entrypoint.sh base64-encodes `email:pat` into `PERSONAL_ACCESS_TOKEN` for the Azure DevOps MCP — you don't need to encode it yourself.

2. Build and start:
   ```sh
   docker compose up -d --build
   ```

   Postgres comes up first; `claude-robot` waits for the healthcheck before starting cron + webhook server. `cloudflared` connects to Cloudflare if a tunnel token is provided.

## Smoke test

Verify Claude Code itself works inside the container:

```sh
docker compose exec claude-robot /usr/local/bin/claude.sh -p 'hi'
```

The wrapper transparently re-execs as the `robot` user, so you don't need `-u robot`. You should see a friendly reply from the model.

Verify it can reach Azure DevOps:

```sh
docker compose exec claude-robot /usr/local/bin/claude.sh -p 'can you test if azure-devops MCP works by getting the bug 9504 information?'
```

Verify it can write to Postgres:

```sh
docker compose exec claude-robot /usr/local/bin/claude.sh -p 'insert a test row into the bugs table via the postgres MCP'
docker compose exec postgres psql -U robot -d bugs -c 'SELECT * FROM bugs;'
```

Verify the webhook server is running:

```sh
docker compose exec claude-robot curl -s http://localhost:8080/health
# Expected: {"status":"ok","uptime":...}
```

## Run the sync manually

Without waiting for the top of the hour:

```sh
docker compose exec claude-robot /bin/bash -c '/usr/local/bin/sync-bugs.sh < /dev/null'
```

(The `< /dev/null` silences a benign Claude Code stdin warning.)

Inspect the result:

```sh
docker compose exec postgres psql -U robot -d bugs -c \
  'SELECT id, title, state, changed_date FROM bugs ORDER BY synced_at DESC LIMIT 5;'
```

## Cloudflare Tunnel + Webhook Setup

The robot can receive real-time Azure DevOps events via service hook webhooks. Since ADO requires a public HTTPS URL, we use a **Cloudflare Tunnel** (free, static URL).

### Step 1: Create the tunnel

```sh
# Install cloudflared on your host
winget install Cloudflare.cloudflared    # Windows
# brew install cloudflared               # macOS

# Run the setup script (interactive)
bash scripts/setup-tunnel.sh --tunnel
```

This will:
- Login to Cloudflare (opens browser)
- Create a named tunnel called `claude-robot` (gives you a permanent UUID)
- Route a hostname like `robot.yourdomain.com` to the tunnel
- Write a config file to `~/.cloudflared/config.yml`

### Step 2: Get the tunnel token for Docker

1. Go to https://one.dash.cloudflare.com/
2. **Networks → Tunnels → claude-robot → Configure**
3. Click **Install connector** and copy the token from the docker command
4. Add it to your `.env`:
   ```
   CLOUDFLARE_TUNNEL_TOKEN=<paste-token-here>
   ```

### Step 3: Configure the Cloudflare tunnel public hostname

In the Cloudflare dashboard, under your tunnel settings, add a **public hostname**:

| Field | Value |
|-------|-------|
| Subdomain | `robot` (or whatever you chose) |
| Domain | your domain in Cloudflare |
| Type | HTTP |
| URL | `claude-robot:8080` |

### Step 4: Create ADO service hook subscriptions

```sh
bash scripts/setup-tunnel.sh --webhook
```

This will create webhook subscriptions for these events:
- Work item commented on (@mentions)
- Work item updated
- Work item created
- Pull request created/updated
- Build completed

You'll be prompted for your webhook URL (e.g., `https://robot.yourdomain.com/webhook`).

### Step 5: Rebuild and test

```sh
docker compose up -d --build

# Test the health endpoint
curl https://robot.yourdomain.com/health

# @mention yourself in an ADO work item comment, then check the logs:
docker compose exec claude-robot tail -f /var/log/claude-robot.log
```

## Watching the cron job

```sh
docker compose exec claude-robot tail -f /var/log/claude-robot.log
```

Each run prints `=== <iso-ts> sync start (user=robot) ===`, the JSON result from Claude Code, and `=== <iso-ts> sync end ===`.

## Editing config without rebuilding

Both `config/settings.json` and `config/.mcp.json` are bind-mounted. Edit them on the host, then restart the container so the next `claude` invocation picks them up:

```sh
docker compose restart claude-robot
```

`Dockerfile`, `scripts/`, and `cron/` changes need a rebuild (`docker compose up -d --build`).

## Customization

- **Schedule** — edit `cron/claude-robot` (the cron expression) and rebuild.
- **What gets synced** — edit the prompt in `scripts/sync-bugs.sh` and rebuild.
- **DB schema** — edit `db/init.sql`. Note: it only runs on a fresh Postgres volume. To re-init: `docker compose down -v && docker compose up -d --build`.
- **Allowed tools / permissions** — edit `config/settings.json`, then restart.
- **Webhook event handling** — edit the `buildPrompt()` function in `scripts/webhook-server.js`.
