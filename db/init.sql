CREATE TABLE IF NOT EXISTS bugs (
  id             INTEGER PRIMARY KEY,
  title          TEXT NOT NULL,
  state          TEXT,
  assigned_to    TEXT,
  priority       INTEGER,
  severity       TEXT,
  tags           TEXT,
  area_path      TEXT,
  iteration_path TEXT,
  created_date   TIMESTAMPTZ,
  changed_date   TIMESTAMPTZ,
  raw            JSONB,
  synced_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS bugs_state_idx        ON bugs (state);
CREATE INDEX IF NOT EXISTS bugs_changed_date_idx ON bugs (changed_date DESC);

-- Webhook events log — every incoming ADO service hook gets recorded here.
CREATE TABLE IF NOT EXISTS webhook_events (
  id            SERIAL PRIMARY KEY,
  event_type    TEXT NOT NULL,
  resource_id   INTEGER,
  raw           JSONB,
  action_taken  TEXT,
  processed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS webhook_events_type_idx ON webhook_events (event_type);
CREATE INDEX IF NOT EXISTS webhook_events_time_idx ON webhook_events (processed_at DESC);

-- @Mentions tracking — when someone @mentions the robot in a work item comment.
CREATE TABLE IF NOT EXISTS mentions (
  id            SERIAL PRIMARY KEY,
  work_item_id  INTEGER NOT NULL,
  comment_id    TEXT,
  mentioned_by  TEXT,
  comment_text  TEXT,
  action_taken  TEXT,
  responded     BOOLEAN DEFAULT FALSE,
  received_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS mentions_work_item_idx  ON mentions (work_item_id);
CREATE INDEX IF NOT EXISTS mentions_responded_idx  ON mentions (responded) WHERE NOT responded;
CREATE INDEX IF NOT EXISTS mentions_received_idx    ON mentions (received_at DESC);
