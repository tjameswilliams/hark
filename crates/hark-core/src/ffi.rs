//! UniFFI surface consumed by the Swift app. Deliberately coarse-grained:
//! one call per user-visible action, plain records across the boundary.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::db::Db;
use crate::knowledge::{self, Embedder};

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

/// One hybrid-search result, mapped back to its session and timestamp.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub session_id: i64,
    pub chunk_id: i64,
    /// Session kind: "dictation" | "meeting".
    pub kind: String,
    pub title: Option<String>,
    pub started_at: String,
    /// ~240 chars of chunk text around the best keyword match (or the head).
    pub snippet: String,
    /// RRF fusion score (higher is better; FTS-only when embeddings are
    /// unavailable — the call degrades rather than erroring).
    pub score: f64,
    /// Start of the chunk's first segment, for jump-to-timestamp.
    pub t_start_ms: i64,
    /// Display name of the first segment's speaker, when diarized.
    pub speaker: Option<String>,
}

/// One project, with how many sessions it holds.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ProjectRecord {
    pub id: i64,
    pub name: String,
    pub description: Option<String>,
    pub session_count: i64,
}

/// One session row for browsing lists (works for both kinds).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionSummary {
    pub id: i64,
    pub kind: String,
    pub title: Option<String>,
    pub started_at: String,
    pub project_id: Option<i64>,
    pub segment_count: i64,
    pub speaker_count: i64,
    /// First ~120 chars of the session's text.
    pub preview: String,
}

/// Handle to the Hark database; the app opens exactly one and shares it.
#[derive(uniffi::Object)]
pub struct HarkStore {
    db: Mutex<Db>,
    /// Lazily-created embedding model (BGESmallENV15). Kept separate from the
    /// db lock; the two are never held at once (model download is slow).
    embedder: Embedder,
}

/// Rust-only surface (not exported over UniFFI): the read-only store used by
/// hark-mcp, which runs concurrently with the app against the same WAL file.
impl HarkStore {
    /// Opens an existing database strictly read-only — no migrations, no
    /// writes possible. All read APIs (search, list_*, transcripts, counts)
    /// work; write APIs return a clear error instead.
    pub fn open_read_only(path: &str) -> Result<Arc<Self>, HarkError> {
        let db = Db::open_read_only(std::path::Path::new(path))?;
        Ok(Arc::new(Self {
            db: Mutex::new(db),
            embedder: Embedder::new(),
        }))
    }
}

/// Guard for write paths: read-only stores refuse cleanly rather than
/// surfacing a raw SQLITE_READONLY error (or worse, a panic).
fn check_writable(db: &Db) -> Result<(), HarkError> {
    if db.is_read_only() {
        return Err(HarkError::Failure(
            "this Hark database handle is read-only (opened by hark-mcp); \
             writes happen only in the Hark app"
                .into(),
        ));
    }
    Ok(())
}

#[uniffi::export]
impl HarkStore {
    /// Opens (creating and migrating as needed) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, HarkError> {
        let db = Db::open(std::path::Path::new(&path))?;
        Ok(Arc::new(Self {
            db: Mutex::new(db),
            embedder: Embedder::new(),
        }))
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
        check_writable(&db)?;
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
        check_writable(&db)?;
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
    /// "[mm:ss] Speaker: text" lines. Alias of `session_transcript`, kept
    /// because the app already calls `meetingTranscript`.
    pub fn meeting_transcript(&self, id: i64) -> Result<String, HarkError> {
        self.session_transcript(id)
    }

    /// Transcript for any session. Meetings render "[mm:ss] Speaker: text"
    /// (unknown speakers as "Unknown"); dictations render "[mm:ss] text".
    /// Unknown ids yield an empty string.
    pub fn session_transcript(&self, id: i64) -> Result<String, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        transcript_for(db.conn(), id)
    }

    /// Permanently deletes one dictation (cascades to segments/notes).
    pub fn delete_dictation(&self, id: i64) -> Result<(), HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        check_writable(&db)?;
        db.conn().execute(
            "DELETE FROM sessions WHERE id = ?1 AND kind = 'dictation'",
            [id],
        )?;
        Ok(())
    }

    // -- Knowledge layer -----------------------------------------------------

    /// Chunks and embeds everything not yet indexed. Idempotent and cheap
    /// when there is nothing to do; safe to call after every save. Returns
    /// the number of sessions that had work done. Errors if the embedding
    /// model is unavailable (offline, first run) — chunks/FTS still land, and
    /// the next call picks the embeddings back up.
    ///
    /// `model_cache_dir`: where fastembed stores/downloads the ONNX model
    /// (the app passes ~/Library/Application Support/Hark/models).
    pub fn index_pending(&self, model_cache_dir: String) -> Result<u32, HarkError> {
        let mut touched: HashSet<i64> = HashSet::new();

        // Pass A: chunk sessions that have segments but no chunks yet.
        // Also purge embeddings orphaned by session deletes.
        {
            let mut db = self.db.lock().expect("hark db lock poisoned");
            check_writable(&db)?;
            let tx = db.conn_mut().transaction()?;
            let pending: Vec<i64> = {
                let mut stmt = tx.prepare(
                    "SELECT s.id FROM sessions s
                     WHERE EXISTS (SELECT 1 FROM segments WHERE session_id = s.id)
                       AND NOT EXISTS (SELECT 1 FROM chunks WHERE session_id = s.id)
                     ORDER BY s.id",
                )?;
                let rows = stmt.query_map([], |row| row.get(0))?;
                rows.collect::<Result<Vec<i64>, _>>()?
            };
            for session_id in pending {
                let segments = knowledge::segments_for_session(&tx, session_id)?;
                for (pos, chunk) in knowledge::build_chunks(&segments).iter().enumerate() {
                    tx.execute(
                        "INSERT INTO chunks
                             (session_id, seg_start_id, seg_end_id, text, token_count, pos)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        rusqlite::params![
                            session_id,
                            chunk.seg_start_id,
                            chunk.seg_end_id,
                            chunk.text,
                            (chunk.text.chars().count() / 4) as i64,
                            pos as i64
                        ],
                    )?;
                }
                touched.insert(session_id);
            }
            tx.execute(
                "DELETE FROM chunk_embeddings
                 WHERE rowid NOT IN (SELECT id FROM chunks)",
                [],
            )?;
            tx.commit()?;
        }

        // Pass B: embed chunks that have no embedding row yet. Texts are
        // gathered under the db lock, embedding runs without it (model init
        // may download ~34 MB), then rows are written back.
        struct PendingEmbed {
            chunk_id: i64,
            session_id: i64,
            project_id: i64,
            embed_text: String,
        }
        let pending: Vec<PendingEmbed> = {
            let db = self.db.lock().expect("hark db lock poisoned");
            let conn = db.conn();
            let plan: Vec<(i64, i64, i64, i64, i64)> = {
                let mut stmt = conn.prepare(
                    "SELECT c.id, c.session_id, coalesce(s.project_id, 0),
                            c.seg_start_id, c.seg_end_id
                     FROM chunks c
                     JOIN sessions s ON s.id = c.session_id
                     WHERE c.id NOT IN (SELECT rowid FROM chunk_embeddings)
                     ORDER BY c.id",
                )?;
                let rows = stmt.query_map([], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
                })?;
                rows.collect::<Result<Vec<_>, _>>()?
            };
            let mut seg_stmt = conn.prepare(
                "SELECT seg.id, seg.speaker_id, sp.display_name, seg.text
                 FROM segments seg
                 LEFT JOIN speakers sp ON sp.id = seg.speaker_id
                 WHERE seg.session_id = ?1 AND seg.id BETWEEN ?2 AND ?3
                 ORDER BY seg.t_start_ms, seg.id",
            )?;
            let mut out = Vec::with_capacity(plan.len());
            for (chunk_id, session_id, project_id, seg_start, seg_end) in plan {
                let segments = seg_stmt
                    .query_map(rusqlite::params![session_id, seg_start, seg_end], |row| {
                        Ok(knowledge::SegmentForChunking {
                            id: row.get(0)?,
                            speaker_id: row.get(1)?,
                            speaker_name: row.get(2)?,
                            text: row.get(3)?,
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                out.push(PendingEmbed {
                    chunk_id,
                    session_id,
                    project_id,
                    embed_text: knowledge::speaker_prefixed_text(&segments),
                });
            }
            out
        };

        if !pending.is_empty() {
            let texts: Vec<String> = pending.iter().map(|p| p.embed_text.clone()).collect();
            let vectors = self.embedder.embed(&model_cache_dir, texts)?;
            if vectors.len() != pending.len() {
                return Err(HarkError::Failure(format!(
                    "embedder returned {} vectors for {} chunks",
                    vectors.len(),
                    pending.len()
                )));
            }
            let mut db = self.db.lock().expect("hark db lock poisoned");
            let tx = db.conn_mut().transaction()?;
            for (p, vector) in pending.iter().zip(&vectors) {
                tx.execute(
                    "INSERT OR REPLACE INTO chunk_embeddings
                         (rowid, embedding, model_id, session_id, project_id)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    rusqlite::params![
                        p.chunk_id,
                        knowledge::embedding_to_blob(vector),
                        knowledge::EMBEDDING_MODEL_ID,
                        p.session_id,
                        p.project_id
                    ],
                )?;
                touched.insert(p.session_id);
            }
            tx.commit()?;
        }

        Ok(touched.len() as u32)
    }

    /// Hybrid search: FTS5 BM25 + vec0 KNN fused with RRF (k = 60), joined
    /// back to sessions and filtered by project/kind. When the embedding
    /// model is unavailable (offline first run, bad cache dir) the call
    /// degrades to keyword-only results instead of erroring; a malformed
    /// query likewise falls back to LIKE matching.
    pub fn search(
        &self,
        query: String,
        project_id: Option<i64>,
        kind: Option<String>,
        limit: u32,
        model_cache_dir: String,
    ) -> Result<Vec<SearchHit>, HarkError> {
        let trimmed = query.trim();
        if trimmed.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }

        // Embed the query first, without holding the db lock. Degrade to
        // FTS-only when the model can't be created (e.g. offline).
        let query_vec = self.embedder.embed_query(&model_cache_dir, trimmed).ok();

        let db = self.db.lock().expect("hark db lock poisoned");
        let conn = db.conn();

        // Aux columns can't constrain vec0 KNN queries (sqlite-vec 0.1.x),
        // so both legs over-fetch when filters apply and we post-filter below.
        let filtered = project_id.is_some() || kind.is_some();
        let candidates = if filtered {
            knowledge::CANDIDATES_PER_LEG * 4
        } else {
            knowledge::CANDIDATES_PER_LEG
        };

        // Keyword leg: escaped MATCH, LIKE as a belt-and-braces fallback.
        let escaped = knowledge::escape_fts_query(trimmed);
        let fts_ids: Vec<i64> = {
            let matched: Result<Vec<i64>, rusqlite::Error> = conn
                .prepare(
                    "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?1
                     ORDER BY rank LIMIT ?2",
                )
                .and_then(|mut stmt| {
                    let rows =
                        stmt.query_map(rusqlite::params![escaped, candidates], |row| row.get(0))?;
                    rows.collect()
                });
            match matched {
                Ok(ids) => ids,
                Err(_) => {
                    let mut stmt = conn.prepare(
                        "SELECT id FROM chunks WHERE text LIKE '%' || ?1 || '%'
                         ORDER BY id DESC LIMIT ?2",
                    )?;
                    let rows =
                        stmt.query_map(rusqlite::params![trimmed, candidates], |row| row.get(0))?;
                    rows.collect::<Result<Vec<i64>, _>>()?
                }
            }
        };

        // Vector leg (skipped in degraded mode).
        let vec_ids: Vec<i64> = match &query_vec {
            Some(v) => {
                let mut stmt = conn.prepare(
                    "SELECT rowid FROM chunk_embeddings
                     WHERE embedding MATCH ?1 AND k = ?2
                     ORDER BY distance",
                )?;
                let rows = stmt.query_map(
                    rusqlite::params![knowledge::embedding_to_blob(v), candidates],
                    |row| row.get(0),
                )?;
                rows.collect::<Result<Vec<i64>, _>>()?
            }
            None => Vec::new(),
        };

        let fused = knowledge::rrf_fuse(&[fts_ids, vec_ids], knowledge::RRF_K);

        let mut hit_stmt = conn.prepare(
            "SELECT c.session_id, c.text, s.kind, s.title, s.started_at, s.project_id,
                    seg.t_start_ms, sp.display_name
             FROM chunks c
             JOIN sessions s ON s.id = c.session_id
             JOIN segments seg ON seg.id = c.seg_start_id
             LEFT JOIN speakers sp ON sp.id = seg.speaker_id
             WHERE c.id = ?1",
        )?;
        let mut hits = Vec::new();
        for (chunk_id, score) in fused {
            if hits.len() >= limit as usize {
                break;
            }
            let row = hit_stmt
                .query_row([chunk_id], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, Option<String>>(7)?,
                    ))
                })
                .map(Some)
                .or_else(|e| match e {
                    rusqlite::Error::QueryReturnedNoRows => Ok(None), // orphaned vec row
                    other => Err(other),
                })?;
            let Some((session_id, text, s_kind, title, started_at, s_project, t_start_ms, speaker)) =
                row
            else {
                continue;
            };
            if let Some(p) = project_id {
                if s_project != Some(p) {
                    continue;
                }
            }
            if let Some(k) = &kind {
                if &s_kind != k {
                    continue;
                }
            }
            hits.push(SearchHit {
                session_id,
                chunk_id,
                kind: s_kind,
                title,
                started_at,
                snippet: knowledge::make_snippet(&text, trimmed),
                score,
                t_start_ms,
                speaker,
            });
        }
        Ok(hits)
    }

    // -- Projects ------------------------------------------------------------

    /// Creates a project; names are unique. Returns the new project id.
    pub fn create_project(
        &self,
        name: String,
        description: Option<String>,
    ) -> Result<i64, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        check_writable(&db)?;
        db.conn().execute(
            "INSERT INTO projects (name, description) VALUES (?1, ?2)",
            rusqlite::params![name, description],
        )?;
        Ok(db.conn().last_insert_rowid())
    }

    /// All projects with their session counts, alphabetical.
    pub fn list_projects(&self) -> Result<Vec<ProjectRecord>, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let mut stmt = db.conn().prepare(
            "SELECT p.id, p.name, p.description,
                    (SELECT count(*) FROM sessions WHERE project_id = p.id)
             FROM projects p
             ORDER BY p.name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(ProjectRecord {
                id: row.get(0)?,
                name: row.get(1)?,
                description: row.get(2)?,
                session_count: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Deletes a project. Sessions survive with project_id → NULL (schema is
    /// ON DELETE SET NULL); embedding metadata is synced to unassigned (0).
    pub fn delete_project(&self, id: i64) -> Result<(), HarkError> {
        let mut db = self.db.lock().expect("hark db lock poisoned");
        check_writable(&db)?;
        let tx = db.conn_mut().transaction()?;
        let chunk_ids: Vec<i64> = {
            let mut stmt = tx.prepare(
                "SELECT c.id FROM chunks c
                 JOIN sessions s ON s.id = c.session_id
                 WHERE s.project_id = ?1",
            )?;
            let rows = stmt.query_map([id], |row| row.get(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        tx.execute("DELETE FROM projects WHERE id = ?1", [id])?;
        for chunk_id in chunk_ids {
            tx.execute(
                "UPDATE chunk_embeddings SET project_id = 0 WHERE rowid = ?1",
                [chunk_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Moves a session into a project (or out, with None), keeping the
    /// vec-table aux project_id in sync so future filterable-KNN upgrades
    /// stay correct.
    pub fn assign_session(
        &self,
        session_id: i64,
        project_id: Option<i64>,
    ) -> Result<(), HarkError> {
        let mut db = self.db.lock().expect("hark db lock poisoned");
        check_writable(&db)?;
        let tx = db.conn_mut().transaction()?;
        tx.execute(
            "UPDATE sessions SET project_id = ?1 WHERE id = ?2",
            rusqlite::params![project_id, session_id],
        )?;
        let chunk_ids: Vec<i64> = {
            let mut stmt = tx.prepare("SELECT id FROM chunks WHERE session_id = ?1")?;
            let rows = stmt.query_map([session_id], |row| row.get(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        // vec0 supports aux-column UPDATE addressed by rowid (verified in
        // db.rs tests); 0 means unassigned.
        for chunk_id in chunk_ids {
            tx.execute(
                "UPDATE chunk_embeddings SET project_id = ?1 WHERE rowid = ?2",
                rusqlite::params![project_id.unwrap_or(0), chunk_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    // -- Session browsing ----------------------------------------------------

    /// Pageable session list, newest first, optionally filtered by kind
    /// and/or project.
    pub fn list_sessions(
        &self,
        kind: Option<String>,
        project_id: Option<i64>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<SessionSummary>, HarkError> {
        let db = self.db.lock().expect("hark db lock poisoned");
        let mut stmt = db.conn().prepare(
            "SELECT s.id, s.kind, s.title, s.started_at, s.project_id,
                    (SELECT count(*) FROM segments WHERE session_id = s.id),
                    (SELECT count(*) FROM session_speakers WHERE session_id = s.id),
                    coalesce((SELECT group_concat(text, ' ') FROM (
                        SELECT text FROM segments
                        WHERE session_id = s.id
                        ORDER BY t_start_ms, id LIMIT 3)), '')
             FROM sessions s
             WHERE (?1 IS NULL OR s.kind = ?1)
               AND (?2 IS NULL OR s.project_id = ?2)
             ORDER BY s.id DESC
             LIMIT ?3 OFFSET ?4",
        )?;
        let rows = stmt.query_map(
            rusqlite::params![kind, project_id, limit, offset],
            |row| {
                let preview: String = row.get(7)?;
                Ok(SessionSummary {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    title: row.get(2)?,
                    started_at: row.get(3)?,
                    project_id: row.get(4)?,
                    segment_count: row.get(5)?,
                    speaker_count: row.get(6)?,
                    preview: truncate_chars(&preview, 120),
                })
            },
        )?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }
}

/// Char-boundary-safe prefix truncation with an ellipsis when cut.
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

/// Shared transcript renderer: meetings get "[mm:ss] Speaker: text" lines
/// ("Unknown" when a segment has no speaker), dictations "[mm:ss] text".
fn transcript_for(conn: &rusqlite::Connection, id: i64) -> Result<String, HarkError> {
    let kind: Option<String> = conn
        .query_row("SELECT kind FROM sessions WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })?;
    let Some(kind) = kind else {
        return Ok(String::new());
    };
    let is_meeting = kind == "meeting";

    let mut stmt = conn.prepare(
        "SELECT seg.t_start_ms, sp.display_name, seg.text
         FROM segments seg
         LEFT JOIN speakers sp ON sp.id = seg.speaker_id
         WHERE seg.session_id = ?1
         ORDER BY seg.t_start_ms",
    )?;
    let rows = stmt.query_map([id], |row| {
        let start_ms: i64 = row.get(0)?;
        let speaker: Option<String> = row.get(1)?;
        let text: String = row.get(2)?;
        let stamp = format!("[{:02}:{:02}]", start_ms / 60_000, (start_ms / 1000) % 60);
        Ok(match (is_meeting, speaker) {
            (_, Some(name)) => format!("{stamp} {name}: {text}"),
            (true, None) => format!("{stamp} Unknown: {text}"),
            (false, None) => format!("{stamp} {text}"),
        })
    })?;
    let lines = rows.collect::<Result<Vec<_>, _>>()?;
    Ok(lines.join("\n"))
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

    /// Two connections on one WAL file: the app's writer store and hark-mcp's
    /// read-only store, held open simultaneously. The reader must see rows the
    /// writer commits (each fresh read statement takes a new WAL snapshot),
    /// and every write path on the reader must fail cleanly.
    #[test]
    fn read_only_store_sees_concurrent_writes_and_refuses_writes() {
        let dir = std::env::temp_dir().join(format!("hark-ffi-ro-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.sqlite");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(dir.join("test.sqlite-wal"));
        let _ = std::fs::remove_file(dir.join("test.sqlite-shm"));
        let path_str = path.to_string_lossy().into_owned();

        let writer = HarkStore::open(path_str.clone()).unwrap();
        writer
            .record_dictation(
                "first note".into(),
                None,
                None,
                "2026-09-01T08:00:00Z".into(),
                "2026-09-01T08:00:02Z".into(),
                2000,
            )
            .unwrap();

        // Open read-only while the writer connection is still open.
        let reader = HarkStore::open_read_only(&path_str).unwrap();
        assert_eq!(reader.dictation_count().unwrap(), 1);

        // A commit made *after* the reader opened must be visible too.
        writer
            .record_dictation(
                "second note".into(),
                None,
                None,
                "2026-09-01T08:01:00Z".into(),
                "2026-09-01T08:01:02Z".into(),
                2000,
            )
            .unwrap();
        assert_eq!(reader.dictation_count().unwrap(), 2);
        let recent = reader.recent_dictations(10).unwrap();
        assert_eq!(recent[0].raw_text, "second note");

        // Read APIs work; write APIs refuse with a clear error, no panic.
        assert!(reader.list_projects().unwrap().is_empty());
        let err = reader
            .record_dictation(
                "nope".into(),
                None,
                None,
                "2026-09-01T08:02:00Z".into(),
                "2026-09-01T08:02:01Z".into(),
                1000,
            )
            .unwrap_err();
        assert!(err.to_string().contains("read-only"), "got: {err}");
        assert!(reader
            .index_pending("/tmp/unused".into())
            .unwrap_err()
            .to_string()
            .contains("read-only"));
        assert!(reader.delete_dictation(1).unwrap_err().to_string().contains("read-only"));
        assert!(reader
            .create_project("p".into(), None)
            .unwrap_err()
            .to_string()
            .contains("read-only"));
    }

    /// A database from an older app build (fewer migrations applied) must be
    /// rejected with the "open the Hark app once" message, not half-work.
    #[test]
    fn read_only_rejects_out_of_date_schema() {
        let dir = std::env::temp_dir().join(format!("hark-ffi-old-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("old.sqlite");
        let _ = std::fs::remove_file(&path);
        {
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.pragma_update(None, "user_version", 1).unwrap();
        }
        let err = match HarkStore::open_read_only(&path.to_string_lossy()) {
            Err(e) => e,
            Ok(_) => panic!("out-of-date schema must be rejected"),
        };
        assert!(
            err.to_string().contains("open the Hark app once"),
            "got: {err}"
        );
    }
}
