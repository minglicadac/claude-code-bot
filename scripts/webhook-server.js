// webhook-server.js — lightweight HTTP listener for Azure DevOps service hook webhooks.
// Receives POST payloads from ADO, routes by eventType, and spawns Claude Code
// to handle each event asynchronously.

const http = require('http');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');

const PORT = parseInt(process.env.WEBHOOK_PORT || '8080', 10);

// ── In-memory queue to prevent duplicate processing ────────────────────────
const processed = new Map(); // eventId → timestamp
const DEDUP_TTL_MS = 5 * 60 * 1000; // 5 minutes

function isDuplicate(eventId) {
  if (!eventId) return false;
  if (processed.has(eventId)) return true;
  processed.set(eventId, Date.now());
  // Prune old entries
  for (const [id, ts] of processed) {
    if (Date.now() - ts > DEDUP_TTL_MS) processed.delete(id);
  }
  return false;
}

// ── Prompt builder — routes by ADO event type ─────────────────────────────
function buildPrompt(eventType, payload) {
  const org   = process.env.AZURE_DEVOPS_ORG    || '';
  const proj  = process.env.AZURE_DEVOPS_PROJECT || '';
  const email = process.env.AZURE_DEVOPS_USER_EMAIL || '';

  const base = `You are a Cadac Connect robot. Your ADO email is ${email}. Org: ${org}, Project: ${proj}.`;

  const routes = {
    'workitem.commented':
      `${base} Someone commented on a work item.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. Read the work item and comment in full.
      2. If someone @mentioned you (${email}), determine what they're asking.
      3. If they assigned you work, triage it and update the work item state.
      4. Upsert the mention into the 'mentions' table via the postgres MCP (columns: work_item_id, comment_id, mentioned_by, comment_text, action_taken, responded).
      5. Reply to the comment acknowledging you received it and summarizing what you'll do.
      6. Also insert a row into 'webhook_events' (columns: event_type, resource_id, raw, action_taken).
      Print a one-line summary.`,

    'workitem.updated':
      `${base} A work item was updated.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. Read the work item and its history.
      2. If a bug was assigned to you (${email}), triage it: set priority/severity if missing, move to Active.
      3. If the state changed to Resolved, verify the fix and move to Closed if appropriate.
      4. Insert into 'webhook_events' via the postgres MCP.
      Print a one-line summary.`,

    'workitem.created':
      `${base} A new work item was created.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. Read the work item.
      2. If it's a Bug assigned to you (${email}), triage it.
      3. Insert into 'webhook_events' via the postgres MCP.
      Print a one-line summary.`,

    'git.pullrequest.created':
      `${base} A new pull request was created.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. Read the PR details and description.
      2. If you are listed as a reviewer, review the changed files and add initial comments.
      3. Insert into 'webhook_events' via the postgres MCP.
      Print a one-line summary.`,

    'git.pullrequest.updated':
      `${base} A pull request was updated.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. Check what changed (reviewers added, status change, etc.).
      2. If you were added as a reviewer, review and vote.
      3. Insert into 'webhook_events' via the postgres MCP.
      Print a one-line summary.`,

    'build.complete':
      `${base} A build completed.
      Payload: ${JSON.stringify(payload)}
      Using the azure-devops MCP:
      1. If the build failed, read the build log and create a Bug with the failure details.
      2. If the build succeeded, note it in webhook_events.
      3. Insert into 'webhook_events' via the postgres MCP.
      Print a one-line summary.`,
  };

  return routes[eventType] ||
    `${base} An Azure DevOps event occurred: ${eventType}.
     Payload: ${JSON.stringify(payload)}
     Using the azure-devops MCP, investigate and take appropriate action.
     Insert into 'webhook_events' via the postgres MCP.
     Print a one-line summary.`;
}

// ── Spawn Claude Code asynchronously (fire-and-forget for ADO) ────────────
function handleEvent(eventType, payload) {
  const eventId = payload.id || randomUUID();

  if (isDuplicate(eventId)) {
    console.log(`[${ts()}] Duplicate event ${eventId}, skipping`);
    return;
  }

  const prompt = buildPrompt(eventType, payload);

  console.log(`[${ts()}] Spawning Claude for event: ${eventType} (id=${eventId})`);

  const child = spawn(
    '/usr/local/bin/claude.sh',
    ['-p', '--permission-mode', 'bypassPermissions', '--output-format', 'json', prompt],
    {
      env: { ...process.env },
      cwd: '/workspace',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 180000, // 3 min hard timeout
    }
  );

  let stdout = '';
  let stderr = '';

  child.stdout.on('data', (d) => { stdout += d; });
  child.stderr.on('data', (d) => { stderr += d; });

  child.on('close', (code) => {
    const summary = stdout.slice(-300);
    console.log(`[${ts()}] Claude finished (${eventType}) exit=${code}: ${summary}`);
    if (stderr) console.log(`[${ts()}]   stderr: ${stderr.slice(-200)}`);
  });

  child.on('error', (err) => {
    console.error(`[${ts()}] Claude spawn error: ${err.message}`);
  });
}

// ── HTTP server ────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // Health check
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
  }

  // ADO webhook endpoint
  if (req.method === 'POST' && req.url === '/webhook') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const eventType = payload.eventType || 'unknown';
        console.log(`[${ts()}] Webhook received: ${eventType}`);

        // Respond immediately — ADO expects a quick 200
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'accepted', eventType }));

        // Handle async (don't block the response)
        setImmediate(() => handleEvent(eventType, payload));

      } catch (err) {
        console.error(`[${ts()}] Parse error: ${err.message}`);
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'error', message: 'Invalid JSON' }));
      }
    });
    return;
  }

  // Everything else
  res.writeHead(404);
  res.end('not found');
});

server.listen(PORT, () => {
  console.log(`[${ts()}] Webhook server listening on :${PORT}`);
  console.log(`[${ts()}]   GET  /health  — health check`);
  console.log(`[${ts()}]   POST /webhook — ADO service hook endpoint`);
});

// ── Helpers ────────────────────────────────────────────────────────────────
function ts() {
  return new Date().toISOString();
}
