use rusqlite::Connection;
use std::path::Path;
use std::sync::Once;

use crate::Result;

/// Registers sqlite-vec's `sqlite3_vec_init` as an auto-extension so every
/// connection opened afterwards (including migration runs) has the `vec0`
/// virtual-table module. Statically linked — no dylib loading, which matters
/// for notarization. Process-global and idempotent via `Once`.
fn register_sqlite_vec() {
    static VEC_REGISTERED: Once = Once::new();
    type AutoExtFn = unsafe extern "C" fn(
        *mut rusqlite::ffi::sqlite3,
        *mut *mut std::os::raw::c_char,
        *const rusqlite::ffi::sqlite3_api_routines,
    ) -> std::os::raw::c_int;
    VEC_REGISTERED.call_once(|| unsafe {
        rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute::<*const (), AutoExtFn>(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    });
}

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
    // 2: vector index over chunks (sqlite-vec). rowid == chunks.id.
    // The `+` columns are auxiliary metadata: stored per-row and selectable,
    // but NOT usable as KNN filter constraints in sqlite-vec 0.1.x — KNN
    // queries here run unfiltered with an inflated k and post-filter by
    // joining chunks/sessions (see knowledge.rs).
    "
    CREATE VIRTUAL TABLE chunk_embeddings USING vec0(
        embedding float[384],
        +model_id TEXT,
        +session_id INTEGER,
        +project_id INTEGER
    );
    ",
];

pub struct Db {
    conn: Connection,
    read_only: bool,
}

impl Db {
    pub fn open(path: &Path) -> Result<Self> {
        register_sqlite_vec();
        let conn = Connection::open(path)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        register_sqlite_vec();
        Self::init(Connection::open_in_memory()?)
    }

    /// Opens an existing Hark database strictly read-only (used by hark-mcp,
    /// which may run concurrently with the app). No migrations run — instead
    /// the schema version is verified, so a too-old database errors clearly.
    ///
    /// The WAL journal mode is a property of the database file itself, so a
    /// read-only reader participates in WAL snapshots automatically; combined
    /// with `busy_timeout` this is safe alongside the app's writer connection.
    pub fn open_read_only(path: &Path) -> Result<Self> {
        register_sqlite_vec();
        let conn = Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
                | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        // Belt and braces: even an accidental write statement fails fast.
        conn.pragma_update(None, "query_only", "ON")?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if (version as usize) < MIGRATIONS.len() {
            return Err(crate::Error::SchemaOutOfDate {
                found: version,
                required: MIGRATIONS.len(),
            });
        }
        Ok(Db {
            conn,
            read_only: true,
        })
    }

    /// True when this handle was opened via `open_read_only`.
    pub fn is_read_only(&self) -> bool {
        self.read_only
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        let db = Db {
            conn,
            read_only: false,
        };
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

    pub fn conn_mut(&mut self) -> &mut Connection {
        &mut self.conn
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

    /// vec0 is statically linked and supports what knowledge.rs relies on:
    /// blob insert with rowid + aux columns, `k = ?` KNN, and UPDATE of aux
    /// columns addressed by rowid.
    #[test]
    fn vec0_roundtrip_knn_and_aux_update() {
        let db = Db::open_in_memory().unwrap();
        let conn = db.conn();

        let to_blob = |v: &[f32]| -> Vec<u8> { v.iter().flat_map(|f| f.to_le_bytes()).collect() };
        let a = to_blob(&{
            let mut v = [0.0f32; 384];
            v[0] = 1.0;
            v
        });
        let b = to_blob(&{
            let mut v = [0.0f32; 384];
            v[1] = 1.0;
            v
        });
        conn.execute(
            "INSERT INTO chunk_embeddings (rowid, embedding, model_id, session_id, project_id)
             VALUES (1, ?1, 'test', 1, 0)",
            [&a],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chunk_embeddings (rowid, embedding, model_id, session_id, project_id)
             VALUES (2, ?1, 'test', 2, 0)",
            [&b],
        )
        .unwrap();

        // KNN: nearest to `a` is rowid 1.
        let nearest: i64 = conn
            .query_row(
                "SELECT rowid FROM chunk_embeddings WHERE embedding MATCH ?1 AND k = 1",
                [&a],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(nearest, 1);

        // Aux column UPDATE by rowid.
        conn.execute(
            "UPDATE chunk_embeddings SET project_id = 7 WHERE rowid = 1",
            [],
        )
        .unwrap();
        let pid: i64 = conn
            .query_row(
                "SELECT project_id FROM chunk_embeddings WHERE rowid = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(pid, 7);
    }
}
