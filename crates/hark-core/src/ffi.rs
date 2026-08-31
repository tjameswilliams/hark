//! UniFFI surface consumed by the Swift app. Deliberately coarse-grained:
//! one call per user-visible action, plain records across the boundary.

use std::sync::{Arc, Mutex};

use crate::db::Db;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum HarkError {
    #[error("{0}")]
    Failure(String),
}

impl From<crate::Error> for HarkError {
    fn from(err: crate::Error) -> Self {
        HarkError::Failure(err.to_string())
    }
}

impl From<rusqlite::Error> for HarkError {
    fn from(err: rusqlite::Error) -> Self {
        HarkError::Failure(err.to_string())
    }
}

/// One finished dictation, as shown in history UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DictationRecord {
    pub id: i64,
    /// What Parakeet heard, verbatim.
    pub raw_text: String,
    /// LLM-cleaned text, when a cleanup pass ran and changed something.
    pub cleaned_text: Option<String>,
    /// Frontmost app bundle id at dictation time.
    pub app_context: Option<String>,
    pub started_at: String,
    pub duration_ms: i64,
}

/// Handle to the Hark database; the app opens exactly one and shares it.
#[derive(uniffi::Object)]
pub struct HarkStore {
    db: Mutex<Db>,
}

#[uniffi::export]
impl HarkStore {
    /// Opens (creating and migrating as needed) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, HarkError> {
        let db = Db::open(std::path::Path::new(&path))?;
        Ok(Arc::new(Self { db: Mutex::new(db) }))
    }

    /// Records a finished dictation. Timestamps are ISO-8601 UTC strings
    /// (the Swift side owns the clock). Returns the new session id.
    pub fn record_dictation(
        &self,
        raw_text: String,
        cleaned_text: Option<String>,
        app_context: Option<String>,
        started_at: String,
        ended_at: String,
        duration_ms: i64,
    ) -> Result<i64, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let conn = db.conn();
        // Title: first line of the best text, truncated on a char boundary.
        let best = cleaned_text.as_deref().unwrap_or(&raw_text);
        let title: String = best.lines().next().unwrap_or("").chars().take(60).collect();

        conn.execute(
            "INSERT INTO sessions (kind, title, started_at, ended_at, app_context)
             VALUES ('dictation', ?1, ?2, ?3, ?4)",
            rusqlite::params![title, started_at, ended_at, app_context],
        )?;
        let session_id = conn.last_insert_rowid();
        conn.execute(
            "INSERT INTO segments (session_id, t_start_ms, t_end_ms, text)
             VALUES (?1, 0, ?2, ?3)",
            rusqlite::params![session_id, duration_ms.max(0), raw_text],
        )?;
        if let Some(cleaned) = &cleaned_text {
            if cleaned != &raw_text {
                conn.execute(
                    "INSERT INTO notes (session_id, kind, content) VALUES (?1, 'cleaned', ?2)",
                    rusqlite::params![session_id, cleaned],
                )?;
            }
        }
        Ok(session_id)
    }

    /// Most recent dictations, newest first.
    pub fn recent_dictations(&self, limit: u32) -> Result<Vec<DictationRecord>, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let conn = db.conn();
        let mut stmt = conn.prepare(
            "SELECT s.id, seg.text, n.content, s.app_context, s.started_at, seg.t_end_ms
             FROM sessions s
             JOIN segments seg ON seg.session_id = s.id
             LEFT JOIN notes n ON n.session_id = s.id AND n.kind = 'cleaned'
             WHERE s.kind = 'dictation'
             ORDER BY s.id DESC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit], |row| {
            Ok(DictationRecord {
                id: row.get(0)?,
                raw_text: row.get(1)?,
                cleaned_text: row.get(2)?,
                app_context: row.get(3)?,
                started_at: row.get(4)?,
                duration_ms: row.get(5)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Total number of stored dictations (for the menu status line).
    pub fn dictation_count(&self) -> Result<i64, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        Ok(db.conn().query_row(
            "SELECT count(*) FROM sessions WHERE kind = 'dictation'",
            [],
            |row| row.get(0),
        )?)
    }

    /// Permanently deletes one dictation (cascades to segments/notes).
    pub fn delete_dictation(&self, id: i64) -> Result<(), HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        db.conn().execute(
            "DELETE FROM sessions WHERE id = ?1 AND kind = 'dictation'",
            [id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_list_roundtrip() {
        let dir = std::env::temp_dir().join(format!("hark-ffi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.sqlite");
        let _ = std::fs::remove_file(&path);

        let store = HarkStore::open(path.to_string_lossy().into_owned()).unwrap();
        let id = store
            .record_dictation(
                "so um heres the thing".into(),
                Some("Here's the thing.".into()),
                Some("com.apple.Terminal".into()),
                "2026-08-31T12:00:00Z".into(),
                "2026-08-31T12:00:03Z".into(),
                3000,
            )
            .unwrap();
        assert!(id > 0);
        assert_eq!(store.dictation_count().unwrap(), 1);

        let recent = store.recent_dictations(10).unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].raw_text, "so um heres the thing");
        assert_eq!(recent[0].cleaned_text.as_deref(), Some("Here's the thing."));
        assert_eq!(recent[0].duration_ms, 3000);

        store.delete_dictation(id).unwrap();
        assert_eq!(store.dictation_count().unwrap(), 0);
    }
}
