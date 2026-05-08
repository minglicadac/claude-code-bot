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
