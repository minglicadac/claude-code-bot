# claude-robot

A Dockerized Claude Code that runs headlessly on a cron, pulls the 5 most recently changed bugs from an Azure DevOps project via the official `@azure-devops/mcp` server, and upserts them into a bundled PostgreSQL via `@henkey/postgres-mcp-server`.

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

   Postgres comes up first; `claude-robot` waits for the healthcheck before starting cron.

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
