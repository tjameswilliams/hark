//! Knowledge layer: chunking, embeddings, and hybrid (FTS5 + vector) search.
//!
//! Design notes:
//! - Embeddings come from fastembed's BGESmallENV15 (384-dim, CPU/ONNX). The
//!   model downloads to a caller-supplied cache dir on first use and is held
//!   lazily behind a mutex on `HarkStore`.
//! - `chunk_embeddings` is a sqlite-vec vec0 table whose rowid == chunks.id.
//!   Its `+` columns are *auxiliary*: selectable but, in sqlite-vec 0.1.x,
//!   not usable as KNN filter constraints (verified: the engine raises
//!   "illegal WHERE constraint … auxiliary column in a KNN query"). KNN
//!   therefore runs unfiltered with an inflated k and results are
//!   post-filtered by joining chunks → sessions.
//! - Hybrid ranking: FTS5 BM25 list + KNN list fused with Reciprocal Rank
//!   Fusion (k = 60), no score normalization.

use std::path::PathBuf;
use std::sync::Mutex;

use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use rusqlite::Connection;

use crate::ffi::HarkError;

/// Stored per embedding row so a future model migration can re-embed selectively.
pub const EMBEDDING_MODEL_ID: &str = "bge-small-en-v1.5";
pub const EMBEDDING_DIMS: usize = 384;

/// BGE v1.5 retrieval works best when the *query* side carries this
/// instruction prefix; passages are embedded bare.
const QUERY_PREFIX: &str = "Represent this sentence for searching relevant passages: ";

/// Chunking targets, in characters (~4 chars/token → ~250-400 tokens).
const CHUNK_MAX_CHARS: usize = 1600;
/// A speaker change only starts a new chunk once the current one has substance.
const CHUNK_SPEAKER_SPLIT_MIN_CHARS: usize = 400;

pub const RRF_K: f64 = 60.0;
pub const CANDIDATES_PER_LEG: i64 = 40;
const SNIPPET_CHARS: usize = 240;

// ---------------------------------------------------------------------------
// Embedder wrapper
// ---------------------------------------------------------------------------

/// Lazily-created embedding model. Lives on `HarkStore`; never lock this
/// while holding the db lock (model download can take minutes offline-cold).
pub struct Embedder {
    model: Mutex<Option<TextEmbedding>>,
}

impl Embedder {
    pub fn new() -> Self {
        Self {
            model: Mutex::new(None),
        }
    }

    /// Embeds `texts`, creating the model on first use (downloads ~34 MB into
    /// `cache_dir` when absent). Returns Err when the model can't be
    /// created (offline + empty cache, bogus dir) — callers decide whether
    /// that degrades (search) or propagates (indexing).
    pub fn embed(
        &self,
        cache_dir: &str,
        texts: Vec<String>,
    ) -> Result<Vec<Vec<f32>>, HarkError> {
        let mut guard = self.model.lock().expect("embedder lock poisoned");
        if guard.is_none() {
            let options = InitOptions::new(EmbeddingModel::BGESmallENV15)
                .with_cache_dir(PathBuf::from(cache_dir))
                .with_show_download_progress(false);
            let model = TextEmbedding::try_new(options)
                .map_err(|e| HarkError::Failure(format!("embedding model unavailable: {e}")))?;
            *guard = Some(model);
        }
        let model = guard.as_mut().expect("embedder just initialized");
        model
            .embed(texts, None)
            .map_err(|e| HarkError::Failure(format!("embedding failed: {e}")))
    }

    /// Embeds a search query with the BGE retrieval instruction prefix.
    pub fn embed_query(&self, cache_dir: &str, query: &str) -> Result<Vec<f32>, HarkError> {
        let mut out = self.embed(cache_dir, vec![format!("{QUERY_PREFIX}{query}")])?;
        out.pop()
            .ok_or_else(|| HarkError::Failure("embedder returned no vector".into()))
    }
}

impl Default for Embedder {
    fn default() -> Self {
        Self::new()
    }
}

/// float32 slice → little-endian blob, the format vec0 stores natively.
pub fn embedding_to_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

// ---------------------------------------------------------------------------
// Chunking
// ---------------------------------------------------------------------------

/// The slice of a segment row that chunking needs.
#[derive(Debug, Clone)]
pub struct SegmentForChunking {
    pub id: i64,
    pub speaker_id: Option<i64>,
    pub speaker_name: Option<String>,
    pub text: String,
}

/// One planned chunk: contiguous segment range plus both text forms.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannedChunk {
    pub seg_start_id: i64,
    pub seg_end_id: i64,
    /// Plain text, stored in chunks.text (FTS indexes this via triggers).
    pub text: String,
    /// Speaker-prefixed text ("SPEAKER_00: …"), used only for embedding.
    pub embed_text: String,
}

/// Speaker-prefixed rendering used for the *embedded* text only: one
/// "NAME: …" run per consecutive-speaker run, newline separated. Segments
/// without a speaker are rendered bare.
pub fn speaker_prefixed_text<'a>(
    segments: impl IntoIterator<Item = &'a SegmentForChunking>,
) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut run_speaker: Option<Option<i64>> = None;
    for s in segments {
        let t = s.text.trim();
        if t.is_empty() {
            continue;
        }
        let same_run = run_speaker
            .as_ref()
            .map(|sp| sp == &s.speaker_id && s.speaker_id.is_some())
            .unwrap_or(false);
        if same_run {
            let last = parts.last_mut().expect("run exists");
            last.push(' ');
            last.push_str(t);
        } else {
            match &s.speaker_name {
                Some(name) => parts.push(format!("{name}: {t}")),
                None => parts.push(t.to_string()),
            }
            run_speaker = Some(s.speaker_id);
        }
    }
    parts.join("\n")
}

/// Groups consecutive segments into retrieval chunks. Never splits a segment.
/// A new chunk starts when adding a segment would exceed ~1600 chars, or when
/// the speaker changes and the current chunk already has > 400 chars.
pub fn build_chunks(segments: &[SegmentForChunking]) -> Vec<PlannedChunk> {
    let mut chunks: Vec<PlannedChunk> = Vec::new();
    let mut cur: Vec<&SegmentForChunking> = Vec::new();
    let mut cur_len = 0usize;

    let flush = |cur: &mut Vec<&SegmentForChunking>, chunks: &mut Vec<PlannedChunk>| {
        if cur.is_empty() {
            return;
        }
        let text = cur
            .iter()
            .map(|s| s.text.trim())
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        chunks.push(PlannedChunk {
            seg_start_id: cur.first().expect("non-empty").id,
            seg_end_id: cur.last().expect("non-empty").id,
            text,
            embed_text: speaker_prefixed_text(cur.iter().copied()),
        });
        cur.clear();
    };

    let mut prev_speaker: Option<Option<i64>> = None;
    for seg in segments {
        let seg_len = seg.text.trim().len();
        let speaker_changed = prev_speaker
            .as_ref()
            .map(|p| p != &seg.speaker_id)
            .unwrap_or(false);
        if !cur.is_empty()
            && ((speaker_changed && cur_len > CHUNK_SPEAKER_SPLIT_MIN_CHARS)
                || cur_len + seg_len > CHUNK_MAX_CHARS)
        {
            flush(&mut cur, &mut chunks);
            cur_len = 0;
        }
        cur.push(seg);
        cur_len += seg_len + 1;
        prev_speaker = Some(seg.speaker_id);
    }
    flush(&mut cur, &mut chunks);
    chunks
}

/// Loads a session's segments in transcript order, ready for chunking.
pub fn segments_for_session(
    conn: &Connection,
    session_id: i64,
) -> Result<Vec<SegmentForChunking>, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT seg.id, seg.speaker_id, sp.display_name, seg.text
         FROM segments seg
         LEFT JOIN speakers sp ON sp.id = seg.speaker_id
         WHERE seg.session_id = ?1
         ORDER BY seg.t_start_ms, seg.id",
    )?;
    let rows = stmt.query_map([session_id], |row| {
        Ok(SegmentForChunking {
            id: row.get(0)?,
            speaker_id: row.get(1)?,
            speaker_name: row.get(2)?,
            text: row.get(3)?,
        })
    })?;
    rows.collect()
}

// ---------------------------------------------------------------------------
// FTS query handling
// ---------------------------------------------------------------------------

/// Escapes a user query for FTS5 MATCH: each whitespace token becomes a
/// double-quoted string (internal quotes doubled), joined with implicit AND.
/// Never produces FTS5 operators, so arbitrary user input stays a valid query.
pub fn escape_fts_query(query: &str) -> String {
    query
        .split_whitespace()
        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------
// Reciprocal Rank Fusion
// ---------------------------------------------------------------------------

/// Fuses ranked id lists with RRF: score(id) = Σ 1 / (k + rank), rank 1-based.
/// Returns (id, score) sorted by descending score (ties: ascending id, so
/// fusion is deterministic).
pub fn rrf_fuse(lists: &[Vec<i64>], k: f64) -> Vec<(i64, f64)> {
    use std::collections::HashMap;
    let mut scores: HashMap<i64, f64> = HashMap::new();
    for list in lists {
        for (i, id) in list.iter().enumerate() {
            *scores.entry(*id).or_insert(0.0) += 1.0 / (k + (i + 1) as f64);
        }
    }
    let mut out: Vec<(i64, f64)> = scores.into_iter().collect();
    out.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    out
}

// ---------------------------------------------------------------------------
// Snippets
// ---------------------------------------------------------------------------

/// ~240 chars of `text` centered on the first case-insensitive occurrence of
/// any query term, else the head. Char-boundary safe; ellipses mark cuts.
pub fn make_snippet(text: &str, query: &str) -> String {
    let lower = text.to_lowercase();
    let best = query
        .split_whitespace()
        .filter_map(|t| lower.find(&t.to_lowercase()))
        .min();

    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= SNIPPET_CHARS {
        return text.to_string();
    }
    // Byte offset of the match → char index (lowercasing can shift byte
    // offsets in non-ASCII text; clamp keeps this safe regardless).
    let match_char_idx = best
        .map(|byte_off| {
            let byte_off = byte_off.min(lower.len());
            lower[..byte_off].chars().count().min(chars.len())
        })
        .unwrap_or(0);

    let start = match_char_idx.saturating_sub(SNIPPET_CHARS / 3);
    let start = start.min(chars.len().saturating_sub(SNIPPET_CHARS));
    let end = (start + SNIPPET_CHARS).min(chars.len());
    let mut snippet: String = chars[start..end].iter().collect();
    if start > 0 {
        snippet = format!("…{snippet}");
    }
    if end < chars.len() {
        snippet.push('…');
    }
    snippet
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: i64, speaker: Option<i64>, text: &str) -> SegmentForChunking {
        SegmentForChunking {
            id,
            speaker_id: speaker,
            speaker_name: speaker.map(|s| format!("SPEAKER_{s:02}")),
            text: text.to_string(),
        }
    }

    #[test]
    fn chunking_groups_speaker_turns() {
        let long_a = "alpha ".repeat(100); // 600 chars, speaker 0
        let long_b = "bravo ".repeat(100); // 600 chars, speaker 1
        let segments = vec![
            seg(1, Some(0), "short intro"),
            seg(2, Some(0), &long_a),
            // Speaker change with >400 chars accumulated → new chunk here.
            seg(3, Some(1), &long_b),
            seg(4, Some(1), "closing words"),
        ];
        let chunks = build_chunks(&segments);
        assert_eq!(chunks.len(), 2, "speaker change should split: {chunks:#?}");
        assert_eq!((chunks[0].seg_start_id, chunks[0].seg_end_id), (1, 2));
        assert_eq!((chunks[1].seg_start_id, chunks[1].seg_end_id), (3, 4));
        // Plain text carries no speaker prefix; embed text does.
        assert!(chunks[0].text.starts_with("short intro"));
        assert!(chunks[0].embed_text.starts_with("SPEAKER_00: short intro"));
        assert!(chunks[1].embed_text.starts_with("SPEAKER_01: bravo"));
    }

    #[test]
    fn chunking_ignores_speaker_change_below_min_chars() {
        let segments = vec![
            seg(1, Some(0), "hi"),
            seg(2, Some(1), "hello"),
            seg(3, Some(0), "quick exchange"),
        ];
        let chunks = build_chunks(&segments);
        assert_eq!(chunks.len(), 1, "tiny turns must coalesce");
        assert_eq!((chunks[0].seg_start_id, chunks[0].seg_end_id), (1, 3));
        assert_eq!(
            chunks[0].embed_text,
            "SPEAKER_00: hi\nSPEAKER_01: hello\nSPEAKER_00: quick exchange"
        );
    }

    #[test]
    fn chunking_respects_max_size_without_splitting_segments() {
        let big = "word ".repeat(200); // ~1000 chars each
        let segments = vec![
            seg(1, Some(0), &big),
            seg(2, Some(0), &big),
            seg(3, Some(0), &big),
        ];
        let chunks = build_chunks(&segments);
        assert_eq!(chunks.len(), 3, "1000+1000 > 1600 → one segment per chunk");
        for (i, c) in chunks.iter().enumerate() {
            assert_eq!(c.seg_start_id, i as i64 + 1);
            assert_eq!(c.seg_end_id, i as i64 + 1);
        }
    }

    #[test]
    fn dictation_single_segment_is_one_chunk() {
        let segments = vec![SegmentForChunking {
            id: 42,
            speaker_id: None,
            speaker_name: None,
            text: "note to self".into(),
        }];
        let chunks = build_chunks(&segments);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].text, "note to self");
        assert_eq!(chunks[0].embed_text, "note to self"); // no speaker → no prefix
    }

    #[test]
    fn rrf_fusion_synthetic_ranks() {
        // id 3 is rank 2 in both lists; id 1 and 5 are rank 1 in one list only.
        let fts = vec![1, 3, 4];
        let vec_ = vec![5, 3, 6];
        let fused = rrf_fuse(&[fts, vec_], 60.0);
        assert_eq!(fused[0].0, 3, "doc in both lists must win: {fused:?}");
        let expected_top = 2.0 / 62.0;
        assert!((fused[0].1 - expected_top).abs() < 1e-12);
        // Rank-1 singles tie exactly; deterministic ascending-id order.
        assert_eq!(fused[1].0, 1);
        assert_eq!(fused[2].0, 5);
        assert!((fused[1].1 - 1.0 / 61.0).abs() < 1e-12);
        // Absent doc contributes nothing.
        assert!(fused.iter().all(|(id, _)| *id != 99));
    }

    #[test]
    fn fts_escaping_neutralizes_operators() {
        assert_eq!(escape_fts_query("hello world"), "\"hello\" \"world\"");
        assert_eq!(escape_fts_query("a AND b OR c*"), "\"a\" \"AND\" \"b\" \"OR\" \"c*\"");
        assert_eq!(escape_fts_query("say \"hi\""), "\"say\" \"\"\"hi\"\"\"");
        assert_eq!(escape_fts_query("   "), "");
    }

    #[test]
    fn snippet_centers_on_match() {
        let text = format!("{} hawk {}", "x".repeat(500), "y".repeat(500));
        let snip = make_snippet(&text, "hawk");
        assert!(snip.contains("hawk"));
        assert!(snip.chars().count() <= SNIPPET_CHARS + 2);
        assert!(snip.starts_with('…') && snip.ends_with('…'));
        // No match → head of text.
        let head = make_snippet(&text, "zebra");
        assert!(head.starts_with("xxx"));
    }
}
