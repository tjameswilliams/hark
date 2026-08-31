use rusqlite::Connection;
use std::path::Path;

use crate::Result;

/// Schema migrations, applied in order; `user_version` tracks the last one run.
/// Vector search (sqlite-vec) and embeddings arrive with the knowledge-layer
/// phase — the chunk tables here already carry the segment-range refs they need.
const MIGRATIONS: &[&str] = &[
    // 1: core entities
    "
    CREATE TABLE projects (
        id          INTEGER PRIMARY KEY,
        name        TEXT NOT NULL UNIQUE,
        description TEXT,
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

    CREATE TABLE sessions (
        id          INTEGER PRIMARY KEY,
        project_id  INTEGER REFERENCES projects(id) ON DELETE SET NULL,
        kind        TEXT NOT NULL CHECK (kind IN ('dictation','meeting')),
        title       TEXT,
        started_at  TEXT NOT NULL,
        ended_at    TEXT,
        audio_path  TEXT,
        app_context TEXT
    );
    CREATE INDEX idx_sessions_project ON sessions(project_id);
    CREATE INDEX idx_sessions_started ON sessions(started_at);

    CREATE TABLE speakers (
        id             INTEGER PRIMARY KEY,
        display_name   TEXT,
        voiceprint     BLOB,
        embedding_dims INTEGER
    );

    CREATE TABLE session_speakers (
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        speaker_id INTEGER NOT NULL REFERENCES speakers(id) ON DELETE CASCADE,
        label      TEXT NOT NULL,
        PRIMARY KEY (session_id, label)
    );

    CREATE TABLE segments (
        id         INTEGER PRIMARY KEY,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        speaker_id INTEGER REFERENCES speakers(id) ON DELETE SET NULL,
        t_start_ms INTEGER NOT NULL,
        t_end_ms   INTEGER NOT NULL,
        text       TEXT NOT NULL,
        confidence REAL
    );
    CREATE INDEX idx_segments_session ON segments(session_id, t_start_ms);

    -- Retrieval units: speaker-turn/sentence aligned, ~200-400 tokens,
    -- mapped back to a segment range so hits can cite timestamps/speakers.
    CREATE TABLE chunks (
        id           INTEGER PRIMARY KEY,
        session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        seg_start_id INTEGER NOT NULL REFERENCES segments(id),
        seg_end_id   INTEGER NOT NULL REFERENCES segments(id),
        text         TEXT NOT NULL,
        token_count  INTEGER,
        pos          INTEGER NOT NULL
    );
    CREATE INDEX idx_chunks_session ON chunks(session_id, pos);

    -- Summaries and other AI output, separate from the verbatim transcript.
    CREATE TABLE notes (
        id         INTEGER PRIMARY KEY,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        kind       TEXT NOT NULL,
        content    TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

    CREATE VIRTUAL TABLE chunks_fts USING fts5(
        text, content='chunks', content_rowid='id'
    );
    CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER chunks_au AFTER UPDATE OF text ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
    END;
    ",
];

pub struct Db {
    conn: Connection,
}

impl Db {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        let db = Db { conn };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<()> {
        let version: i64 =
            self.conn
                .query_row("PRAGMA user_version", [], |row| row.get(0))?;
        for (i, migration) in MIGRATIONS.iter().enumerate().skip(version as usize) {
            self.conn.execute_batch(migration)?;
            self.conn
                .pragma_update(None, "user_version", (i + 1) as i64)?;
        }
        Ok(())
    }

    pub fn conn(&self) -> &Connection {
        &self.conn
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_apply_cleanly() {
        let db = Db::open_in_memory().unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[test]
    fn fts_triggers_index_chunks() {
        let db = Db::open_in_memory().unwrap();
        let conn = db.conn();
        conn.execute(
            "INSERT INTO sessions (kind, started_at) VALUES ('meeting', '2026-08-31T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO segments (session_id, t_start_ms, t_end_ms, text)
             VALUES (1, 0, 1000, 'the hawk stooped on the lure')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chunks (session_id, seg_start_id, seg_end_id, text, pos)
             VALUES (1, 1, 1, 'the hawk stooped on the lure', 0)",
            [],
        )
        .unwrap();
        let hits: i64 = conn
            .query_row(
                "SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'hawk'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1);
    }
}
