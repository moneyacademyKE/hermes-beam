import gleam/dynamic/decode
import gleam/result
import sqlight

pub const schema_sql = "
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    user_id TEXT,
    model TEXT,
    model_config TEXT,
    system_prompt TEXT,
    parent_session_id TEXT,
    started_at REAL NOT NULL,
    ended_at REAL,
    end_reason TEXT,
    message_count INTEGER DEFAULT 0,
    tool_call_count INTEGER DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_write_tokens INTEGER DEFAULT 0,
    reasoning_tokens INTEGER DEFAULT 0,
    cwd TEXT,
    billing_provider TEXT,
    billing_base_url TEXT,
    billing_mode TEXT,
    estimated_cost_usd REAL,
    actual_cost_usd REAL,
    cost_status TEXT,
    cost_source TEXT,
    pricing_version TEXT,
    title TEXT,
    api_call_count INTEGER DEFAULT 0,
    handoff_state TEXT,
    handoff_platform TEXT,
    handoff_error TEXT,
    rewind_count INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (parent_session_id) REFERENCES sessions(id)
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    role TEXT NOT NULL,
    content TEXT,
    tool_call_id TEXT,
    tool_calls TEXT,
    tool_name TEXT,
    timestamp REAL NOT NULL,
    token_count INTEGER,
    finish_reason TEXT,
    reasoning TEXT,
    reasoning_content TEXT,
    reasoning_details TEXT,
    codex_reasoning_items TEXT,
    codex_message_items TEXT,
    platform_message_id TEXT,
    observed INTEGER DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS state_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS compression_locks (
    session_id TEXT PRIMARY KEY,
    holder TEXT NOT NULL,
    acquired_at REAL NOT NULL,
    expires_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_compression_locks_expires ON compression_locks(expires_at);
"

pub const deferred_index_sql = "
CREATE INDEX IF NOT EXISTS idx_messages_session_active
    ON messages(session_id, active, timestamp);
"

pub const fts_sql = "
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content
);

CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.id;
    INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;
"

pub const fts_trigram_sql = "
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_trigram USING fts5(
    content,
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_delete AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts_trigram WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_update AFTER UPDATE ON messages BEGIN
    DELETE FROM messages_fts_trigram WHERE rowid = old.id;
    INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;
"

// Connect to the SQLite session database
pub fn connect(db_path: String) -> Result(sqlight.Connection, sqlight.Error) {
  sqlight.open(db_path)
}

// Reconcile and run database schema migrations (including FTS5 trigger creation)
pub fn init_schema(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  let _ = sqlight.exec("PRAGMA foreign_keys=ON;", conn)
  let _ = sqlight.exec("PRAGMA journal_mode=WAL;", conn)
  
  let _ = sqlight.exec(schema_sql, conn)
  let _ = sqlight.exec(deferred_index_sql, conn)
  let _ = sqlight.exec(fts_sql, conn)
  let _ = sqlight.exec(fts_trigram_sql, conn)
  
  Ok(Nil)
}

// Create a new session record in the DB
pub fn create_session(
  conn: sqlight.Connection,
  id: String,
  source: String,
  model: String,
  system_prompt: String,
  started_at: Float,
) -> Result(Nil, sqlight.Error) {
  let query = "
    INSERT OR IGNORE INTO sessions (id, source, model, system_prompt, started_at)
    VALUES (?, ?, ?, ?, ?);
  "
  sqlight.query(
    query,
    on: conn,
    with: [
      sqlight.text(id),
      sqlight.text(source),
      sqlight.text(model),
      sqlight.text(system_prompt),
      sqlight.float(started_at),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

// Mark session as ended with a specific reason
pub fn end_session(
  conn: sqlight.Connection,
  id: String,
  end_reason: String,
  ended_at: Float,
) -> Result(Nil, sqlight.Error) {
  let query = "
    UPDATE sessions SET ended_at = ?, end_reason = ?
    WHERE id = ? AND ended_at IS NULL;
  "
  sqlight.query(
    query,
    on: conn,
    with: [
      sqlight.float(ended_at),
      sqlight.text(end_reason),
      sqlight.text(id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

// Update the working directory of a session
pub fn update_session_cwd(
  conn: sqlight.Connection,
  id: String,
  cwd: String,
) -> Result(Nil, sqlight.Error) {
  let query = "
    UPDATE sessions SET cwd = ? WHERE id = ?;
  "
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(cwd), sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

// Reopen a ended session
pub fn reopen_session(
  conn: sqlight.Connection,
  id: String,
) -> Result(Nil, sqlight.Error) {
  let query = "
    UPDATE sessions SET ended_at = NULL, end_reason = NULL WHERE id = ?;
  "
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

// Insert message log (which automatically updates the FTS index tables)
pub fn insert_message(
  conn: sqlight.Connection,
  session_id: String,
  role: String,
  content: String,
  timestamp: Float,
) -> Result(Nil, sqlight.Error) {
  let query = "
    INSERT INTO messages (session_id, role, content, timestamp)
    VALUES (?, ?, ?, ?);
  "
  sqlight.query(
    query,
    on: conn,
    with: [
      sqlight.text(session_id),
      sqlight.text(role),
      sqlight.text(content),
      sqlight.float(timestamp),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub type SearchMatch {
  SearchMatch(session_id: String, role: String, content: String)
}

// Query the virtual FTS index using SQLite MATCH ranking
pub fn search_messages(
  conn: sqlight.Connection,
  search_term: String,
) -> Result(List(SearchMatch), sqlight.Error) {
  let query = "
    SELECT m.session_id, m.role, m.content
    FROM messages m
    JOIN messages_fts f ON m.id = f.rowid
    WHERE messages_fts MATCH ?
    ORDER BY rank;
  "
  
  let match_decoder = {
    use session_id <- decode.field(0, decode.string)
    use role <- decode.field(1, decode.string)
    use content <- decode.field(2, decode.string)
    decode.success(SearchMatch(session_id: session_id, role: role, content: content))
  }
  
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(search_term)],
    expecting: match_decoder,
  )
}
