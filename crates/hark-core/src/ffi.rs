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

/// One diarized utterance handed over when a processed meeting is saved.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MeetingSegmentInput {
    /// Diarizer label ("SPEAKER_00", …) — mapped to a speaker row per meeting.
    pub speaker_label: String,
    pub t_start_ms: i64,
    pub t_end_ms: i64,
    pub text: String,
    pub confidence: Option<f64>,
}

/// One stored meeting, as listed in the menu / UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MeetingRecord {
    pub id: i64,
    pub title: Option<String>,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub audio_path: Option<String>,
    pub segment_count: i64,
    pub speaker_count: i64,
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

    /// Saves a fully processed (transcribed + diarized) meeting in one
    /// transaction: the session, one speaker row per distinct label, the
    /// label mapping, and every segment. Returns the meeting session id.
    pub fn record_meeting(
        &self,
        title: Option<String>,
        started_at: String,
        ended_at: String,
        audio_path: Option<String>,
        segments: Vec<MeetingSegmentInput>,
    ) -> Result<i64, HarkError> {
        let mut db = self.db.lock().expect("hark db lock poisoned");
        let tx = db.conn_mut().transaction()?;

        tx.execute(
            "INSERT INTO sessions (kind, title, started_at, ended_at, audio_path)
             VALUES ('meeting', ?1, ?2, ?3, ?4)",
            rusqlite::params![title, started_at, ended_at, audio_path],
        )?;
        let session_id = tx.last_insert_rowid();

        // One speaker row per distinct diarizer label, in first-seen order.
        // Cross-meeting speaker identity (voiceprints) comes later; for now
        // every meeting gets its own speaker rows.
        let mut speaker_ids: Vec<(String, i64)> = Vec::new();
        for segment in &segments {
            if !speaker_ids.iter().any(|(label, _)| label == &segment.speaker_label) {
                tx.execute(
                    "INSERT INTO speakers (display_name) VALUES (?1)",
                    [&segment.speaker_label],
                )?;
                let speaker_id = tx.last_insert_rowid();
                tx.execute(
                    "INSERT INTO session_speakers (session_id, speaker_id, label)
                     VALUES (?1, ?2, ?3)",
                    rusqlite::params![session_id, speaker_id, segment.speaker_label],
                )?;
                speaker_ids.push((segment.speaker_label.clone(), speaker_id));
            }
        }

        for segment in &segments {
            let speaker_id = speaker_ids
                .iter()
                .find(|(label, _)| label == &segment.speaker_label)
                .map(|(_, id)| *id);
            tx.execute(
                "INSERT INTO segments
                     (session_id, speaker_id, t_start_ms, t_end_ms, text, confidence)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![
                    session_id,
                    speaker_id,
                    segment.t_start_ms,
                    segment.t_end_ms,
                    segment.text,
                    segment.confidence
                ],
            )?;
        }

        tx.commit()?;
        Ok(session_id)
    }

    /// Most recent meetings, newest first.
    pub fn recent_meetings(&self, limit: u32) -> Result<Vec<MeetingRecord>, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let conn = db.conn();
        let mut stmt = conn.prepare(
            "SELECT s.id, s.title, s.started_at, s.ended_at, s.audio_path,
                    (SELECT count(*) FROM segments WHERE session_id = s.id),
                    (SELECT count(*) FROM session_speakers WHERE session_id = s.id)
             FROM sessions s
             WHERE s.kind = 'meeting'
             ORDER BY s.id DESC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit], |row| {
            Ok(MeetingRecord {
                id: row.get(0)?,
                title: row.get(1)?,
                started_at: row.get(2)?,
                ended_at: row.get(3)?,
                audio_path: row.get(4)?,
                segment_count: row.get(5)?,
                speaker_count: row.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Speaker-attributed transcript, formatted for copying/export:
    /// "[mm:ss] Speaker: text" lines.
    pub fn meeting_transcript(&self, id: i64) -> Result<String, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let conn = db.conn();
        let mut stmt = conn.prepare(
            "SELECT seg.t_start_ms, coalesce(sp.display_name, 'Unknown'), seg.text
             FROM segments seg
             LEFT JOIN speakers sp ON sp.id = seg.speaker_id
             WHERE seg.session_id = ?1
             ORDER BY seg.t_start_ms",
        )?;
        let rows = stmt.query_map([id], |row| {
            let start_ms: i64 = row.get(0)?;
            let speaker: String = row.get(1)?;
            let text: String = row.get(2)?;
            Ok(format!(
                "[{:02}:{:02}] {}: {}",
                start_ms / 60_000,
                (start_ms / 1000) % 60,
                speaker,
                text
            ))
        })?;
        let lines = rows.collect::<Result<Vec<_>, _>>()?;
        Ok(lines.join("\n"))
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

    #[test]
    fn meeting_roundtrip() {
        let dir = std::env::temp_dir().join(format!("hark-ffi-mtg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.sqlite");
        let _ = std::fs::remove_file(&path);

        let store = HarkStore::open(path.to_string_lossy().into_owned()).unwrap();
        let segments = vec![
            MeetingSegmentInput {
                speaker_label: "SPEAKER_00".into(),
                t_start_ms: 0,
                t_end_ms: 4000,
                text: "Let's talk about the hawk logo.".into(),
                confidence: Some(0.95),
            },
            MeetingSegmentInput {
                speaker_label: "SPEAKER_01".into(),
                t_start_ms: 4200,
                t_end_ms: 66_500,
                text: "Agreed, ship it.".into(),
                confidence: None,
            },
            MeetingSegmentInput {
                speaker_label: "SPEAKER_00".into(),
                t_start_ms: 67_000,
                t_end_ms: 70_000,
                text: "Done then.".into(),
                confidence: None,
            },
        ];
        let id = store
            .record_meeting(
                Some("Logo sync".into()),
                "2026-08-31T15:00:00Z".into(),
                "2026-08-31T15:30:00Z".into(),
                Some("/tmp/mtg.wav".into()),
                segments,
            )
            .unwrap();

        let meetings = store.recent_meetings(10).unwrap();
        assert_eq!(meetings.len(), 1);
        assert_eq!(meetings[0].segment_count, 3);
        assert_eq!(meetings[0].speaker_count, 2);

        let transcript = store.meeting_transcript(id).unwrap();
        assert!(transcript.starts_with("[00:00] SPEAKER_00: Let's talk"));
        assert!(transcript.contains("[00:04] SPEAKER_01: Agreed"));
        assert!(transcript.contains("[01:07] SPEAKER_00: Done then."));
    }
}
