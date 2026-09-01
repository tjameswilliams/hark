//! The MCP service: five read-only tools over the Hark knowledge base.
//!
//! All database access goes through `HarkStore::open_read_only` (WAL +
//! busy_timeout, `query_only=ON`), so this server is safe to run while the
//! Hark app holds its own writer connection. The store is opened lazily and
//! cached, so the server starts (and lists tools) even before the app has
//! ever run — tool calls then return an actionable error instead.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rmcp::{
    ErrorData as McpError, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    tool, tool_handler, tool_router,
};

use hark_core::ffi::HarkStore;

/// fastembed/hf-hub cache directory name for the embedding model Hark uses.
/// Present ⇒ the query side of hybrid search works offline.
pub const EMBEDDING_CACHE_DIR: &str = "models--Xenova--bge-small-en-v1.5";

/// Cache-dir sentinel that can never be created (a path under /dev/null), so
/// fastembed fails fast instead of downloading the model — search degrades to
/// keyword-only, which is exactly what we want in an on-demand MCP server.
const NO_MODEL_SENTINEL: &str = "/dev/null/hark-embedding-model-disabled";

const SEARCH_LIMIT_DEFAULT: u32 = 8;
const SEARCH_LIMIT_MAX: u32 = 25;
const SESSIONS_LIMIT_DEFAULT: u32 = 20;
const MEETINGS_LIMIT_DEFAULT: u32 = 5;
const TRANSCRIPT_MAX_CHARS_DEFAULT: usize = 24_000;

// ---------------------------------------------------------------------------
// Tool parameter types (schemas + descriptions render in the client UI)
// ---------------------------------------------------------------------------

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct SearchParams {
    /// What to look for — a topic, phrase, decision, or name. Hybrid search:
    /// keyword (BM25) fused with semantic similarity, so natural-language
    /// questions work as well as exact phrases.
    pub query: String,
    /// Restrict hits to one project, matched case-insensitively against
    /// project names (see list_projects). Omit to search everything.
    pub project: Option<String>,
    /// Restrict to one session kind: "meeting" (recorded, speaker-attributed
    /// meetings) or "dictation" (short voice notes). Omit for both.
    pub kind: Option<String>,
    /// Maximum hits to return (default 8, max 25).
    pub limit: Option<u32>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct ListSessionsParams {
    /// Filter by session kind: "meeting" or "dictation". Omit for both.
    pub kind: Option<String>,
    /// Filter by project name, matched case-insensitively (see list_projects).
    pub project: Option<String>,
    /// Maximum sessions to return (default 20).
    pub limit: Option<u32>,
    /// Number of sessions to skip, for paging through history (default 0).
    pub offset: Option<u32>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct GetTranscriptParams {
    /// The session to read — ids come from search_knowledge, list_sessions,
    /// or recent_meetings results.
    pub session_id: i64,
    /// Maximum characters to return (default 24000). Longer transcripts keep
    /// their head and tail with an omission marker in the middle.
    pub max_chars: Option<u32>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct RecentMeetingsParams {
    /// Maximum meetings to return, newest first (default 5).
    pub limit: Option<u32>,
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

pub struct HarkService {
    db_path: PathBuf,
    /// Cache dir handed to the search embedder: the real models dir when the
    /// embedding model is already cached, otherwise an uncreatable sentinel
    /// so search degrades to keyword-only instead of blocking on a download.
    effective_models_dir: String,
    store: Mutex<Option<Arc<HarkStore>>>,
    tool_router: ToolRouter<Self>,
}

impl HarkService {
    /// Returns the service plus whether hybrid (embedding-backed) search is
    /// available, so the caller can log the mode to stderr.
    pub fn new(db_path: PathBuf, models_dir: PathBuf) -> (Self, bool) {
        let hybrid = models_dir.join(EMBEDDING_CACHE_DIR).is_dir();
        let effective_models_dir = if hybrid {
            models_dir.to_string_lossy().into_owned()
        } else {
            NO_MODEL_SENTINEL.to_string()
        };
        (
            Self {
                db_path,
                effective_models_dir,
                store: Mutex::new(None),
                tool_router: Self::tool_router(),
            },
            hybrid,
        )
    }

    /// Lazily opens (and caches) the read-only store, mapping failures to
    /// actionable tool errors.
    fn store(&self) -> Result<Arc<HarkStore>, McpError> {
        let mut guard = self.store.lock().expect("store lock poisoned");
        if let Some(store) = guard.as_ref() {
            return Ok(store.clone());
        }
        if !self.db_path.exists() {
            return Err(McpError::internal_error(
                format!(
                    "Hark doesn't appear to be set up — is the app installed and has it run \
                     once? (expected database at {})",
                    self.db_path.display()
                ),
                None,
            ));
        }
        let store = HarkStore::open_read_only(&self.db_path.to_string_lossy()).map_err(|e| {
            McpError::internal_error(
                format!(
                    "could not open the Hark database at {}: {e}",
                    self.db_path.display()
                ),
                None,
            )
        })?;
        *guard = Some(store.clone());
        Ok(store)
    }

    /// Resolves an optional project-name filter to its id, case-insensitively.
    /// Unknown names error with the list of real names so the caller can retry.
    fn resolve_project(
        &self,
        store: &HarkStore,
        name: Option<&str>,
    ) -> Result<Option<i64>, CallToolResult> {
        let Some(name) = name else { return Ok(None) };
        let projects = store
            .list_projects()
            .map_err(|e| text_error(format!("could not list projects: {e}")))?;
        match projects
            .iter()
            .find(|p| p.name.eq_ignore_ascii_case(name.trim()))
        {
            Some(p) => Ok(Some(p.id)),
            None => {
                let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
                Err(text_error(if names.is_empty() {
                    format!("no project named \"{name}\" — no projects exist yet")
                } else {
                    format!(
                        "no project named \"{name}\" — available projects: {}",
                        names.join(", ")
                    )
                }))
            }
        }
    }
}

/// Validates an optional kind filter ("meeting" | "dictation").
fn validate_kind(kind: Option<&str>) -> Result<Option<String>, CallToolResult> {
    match kind.map(|k| k.trim().to_ascii_lowercase()) {
        None => Ok(None),
        Some(k) if k.is_empty() => Ok(None),
        Some(k) if k == "meeting" || k == "dictation" => Ok(Some(k)),
        Some(k) => Err(text_error(format!(
            "invalid kind \"{k}\" — use \"meeting\" or \"dictation\" (or omit the filter)"
        ))),
    }
}

/// A tool-level error the model can read and act on (kept out of the protocol
/// error channel so clients render it inline with the conversation).
fn text_error(message: impl Into<String>) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(message.into())])
}

fn text_ok(message: impl Into<String>) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(message.into())])
}

fn mmss(ms: i64) -> String {
    format!("{:02}:{:02}", ms / 60_000, (ms / 1000) % 60)
}

/// Char-boundary-safe middle truncation: keeps the head and tail with an
/// explicit omission marker between them.
fn truncate_middle(s: &str, max_chars: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max_chars {
        return s.to_string();
    }
    let head = max_chars * 3 / 5;
    let tail = max_chars - head;
    let omitted = chars.len() - head - tail;
    format!(
        "{}\n\n[… {omitted} characters omitted from the middle of this transcript — \
         call get_transcript again with a larger max_chars for the full text …]\n\n{}",
        chars[..head].iter().collect::<String>(),
        chars[chars.len() - tail..].iter().collect::<String>()
    )
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

#[tool_router]
impl HarkService {
    #[tool(
        name = "search_knowledge",
        description = "Search the user's local Hark knowledge base of meeting transcripts and \
                       dictated notes. Hybrid keyword + semantic search; returns ranked snippets \
                       with the session id, title, date, timestamp, and speaker so you can follow \
                       up with get_transcript for full context."
    )]
    async fn search_knowledge(
        &self,
        Parameters(params): Parameters<SearchParams>,
    ) -> Result<CallToolResult, McpError> {
        let store = self.store()?;
        let kind = match validate_kind(params.kind.as_deref()) {
            Ok(k) => k,
            Err(e) => return Ok(e),
        };
        let project_id = match self.resolve_project(&store, params.project.as_deref()) {
            Ok(id) => id,
            Err(e) => return Ok(e),
        };
        let limit = params
            .limit
            .unwrap_or(SEARCH_LIMIT_DEFAULT)
            .clamp(1, SEARCH_LIMIT_MAX);
        let query = params.query.trim().to_string();
        if query.is_empty() {
            return Ok(text_error("query must not be empty"));
        }

        // The first search may lazily load the embedding model (~1 s); keep
        // it off the async runtime thread.
        let models_dir = self.effective_models_dir.clone();
        let q = query.clone();
        let hits = tokio::task::spawn_blocking(move || {
            store.search(q, project_id, kind, limit, models_dir)
        })
        .await
        .map_err(|e| McpError::internal_error(format!("search task failed: {e}"), None))?
        .map_err(|e| McpError::internal_error(format!("search failed: {e}"), None))?;

        if hits.is_empty() {
            return Ok(text_ok(format!(
                "No results for \"{query}\". Try broader terms, or browse with \
                 list_sessions / recent_meetings."
            )));
        }
        let mut out = String::new();
        for (i, hit) in hits.iter().enumerate() {
            let title = hit.title.as_deref().unwrap_or("(untitled)");
            let speaker = hit
                .speaker
                .as_deref()
                .map(|s| format!(" {s}:"))
                .unwrap_or_default();
            out.push_str(&format!(
                "[{n}] {title} ({kind}, {date}) — session_id {sid}\n    [{stamp}]{speaker} {snippet}\n",
                n = i + 1,
                kind = hit.kind,
                date = hit.started_at,
                sid = hit.session_id,
                stamp = mmss(hit.t_start_ms),
                snippet = hit.snippet,
            ));
        }
        out.push_str(
            "\nUse get_transcript with a session_id for the full speaker-attributed transcript.",
        );
        Ok(text_ok(out))
    }

    #[tool(
        name = "list_projects",
        description = "List the user's Hark projects (named collections of meetings and \
                       dictations) with their descriptions and session counts. Project names \
                       can be used as the `project` filter in search_knowledge and list_sessions."
    )]
    async fn list_projects(&self) -> Result<CallToolResult, McpError> {
        let store = self.store()?;
        let projects = store
            .list_projects()
            .map_err(|e| McpError::internal_error(format!("could not list projects: {e}"), None))?;
        if projects.is_empty() {
            return Ok(text_ok(
                "No projects yet — sessions exist unassigned; use list_sessions or \
                 search_knowledge without a project filter.",
            ));
        }
        let mut out = format!("{} project(s):\n", projects.len());
        for p in &projects {
            let desc = p
                .description
                .as_deref()
                .map(|d| format!(" — {d}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "- {name}{desc} ({n} session(s), project id {id})\n",
                name = p.name,
                n = p.session_count,
                id = p.id,
            ));
        }
        Ok(text_ok(out))
    }

    #[tool(
        name = "list_sessions",
        description = "Browse the user's Hark sessions (meetings and dictations) newest first, \
                       with titles, dates, ids, and short previews. Supports paging via limit \
                       and offset, and filtering by kind and/or project name."
    )]
    async fn list_sessions(
        &self,
        Parameters(params): Parameters<ListSessionsParams>,
    ) -> Result<CallToolResult, McpError> {
        let store = self.store()?;
        let kind = match validate_kind(params.kind.as_deref()) {
            Ok(k) => k,
            Err(e) => return Ok(e),
        };
        let project_id = match self.resolve_project(&store, params.project.as_deref()) {
            Ok(id) => id,
            Err(e) => return Ok(e),
        };
        let limit = params.limit.unwrap_or(SESSIONS_LIMIT_DEFAULT).clamp(1, 200);
        let offset = params.offset.unwrap_or(0);
        let sessions = store
            .list_sessions(kind, project_id, limit, offset)
            .map_err(|e| McpError::internal_error(format!("could not list sessions: {e}"), None))?;
        if sessions.is_empty() {
            return Ok(text_ok(if offset > 0 {
                format!("No sessions at offset {offset} — the list is exhausted.")
            } else {
                "No sessions match — the Hark database has nothing stored for this filter yet."
                    .to_string()
            }));
        }
        let mut out = format!("{} session(s) (offset {offset}):\n", sessions.len());
        for s in &sessions {
            let title = s.title.as_deref().unwrap_or("(untitled)");
            out.push_str(&format!(
                "- session_id {id} · {kind} · {date} · {title}\n  {segs} segment(s)\
                 {speakers} — \"{preview}\"\n",
                id = s.id,
                kind = s.kind,
                date = s.started_at,
                segs = s.segment_count,
                speakers = if s.kind == "meeting" {
                    format!(", {} speaker(s)", s.speaker_count)
                } else {
                    String::new()
                },
                preview = s.preview,
            ));
        }
        out.push_str("\nUse get_transcript with a session_id to read one in full.");
        Ok(text_ok(out))
    }

    #[tool(
        name = "get_transcript",
        description = "Read the full transcript of one Hark session by session_id. Meetings are \
                       speaker-attributed ('[mm:ss] Speaker: text' per line); dictations are \
                       '[mm:ss] text'. Very long transcripts are middle-truncated at max_chars \
                       with an explicit omission marker."
    )]
    async fn get_transcript(
        &self,
        Parameters(params): Parameters<GetTranscriptParams>,
    ) -> Result<CallToolResult, McpError> {
        let store = self.store()?;
        let transcript = store.session_transcript(params.session_id).map_err(|e| {
            McpError::internal_error(format!("could not load transcript: {e}"), None)
        })?;
        if transcript.is_empty() {
            return Ok(text_error(format!(
                "no transcript for session_id {} — the id may not exist (find valid ids via \
                 list_sessions, recent_meetings, or search_knowledge)",
                params.session_id
            )));
        }
        let max_chars = params
            .max_chars
            .map(|m| (m as usize).max(200))
            .unwrap_or(TRANSCRIPT_MAX_CHARS_DEFAULT);
        Ok(text_ok(truncate_middle(&transcript, max_chars)))
    }

    #[tool(
        name = "recent_meetings",
        description = "List the user's most recent Hark meetings, newest first, with titles, \
                       start/end times, segment and speaker counts, and session ids for use \
                       with get_transcript."
    )]
    async fn recent_meetings(
        &self,
        Parameters(params): Parameters<RecentMeetingsParams>,
    ) -> Result<CallToolResult, McpError> {
        let store = self.store()?;
        let limit = params.limit.unwrap_or(MEETINGS_LIMIT_DEFAULT).clamp(1, 100);
        let meetings = store.recent_meetings(limit).map_err(|e| {
            McpError::internal_error(format!("could not list meetings: {e}"), None)
        })?;
        if meetings.is_empty() {
            return Ok(text_ok(
                "No meetings recorded yet — Hark has only dictations so far (see list_sessions).",
            ));
        }
        let mut out = format!("{} meeting(s), newest first:\n", meetings.len());
        for m in &meetings {
            let title = m.title.as_deref().unwrap_or("(untitled)");
            let ended = m
                .ended_at
                .as_deref()
                .map(|e| format!(", ended {e}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "- session_id {id} · {title} · started {start}{ended} · \
                 {segs} segment(s), {speakers} speaker(s)\n",
                id = m.id,
                start = m.started_at,
                segs = m.segment_count,
                speakers = m.speaker_count,
            ));
        }
        out.push_str("\nUse get_transcript with a session_id to read one in full.");
        Ok(text_ok(out))
    }
}

// `router = self.tool_router` reuses the router built once in `new` (the
// macro's default re-derives it on every call).
#[tool_handler(router = self.tool_router)]
impl ServerHandler for HarkService {
    fn get_info(&self) -> ServerInfo {
        let mut implementation = Implementation::from_build_env();
        implementation.name = "hark".into();
        implementation.version = env!("CARGO_PKG_VERSION").into();
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(implementation)
            .with_instructions(
                "Search and read the user's local Hark meeting transcripts and dictations. \
                 Everything is on-device and read-only. Start with search_knowledge for topical \
                 questions; every hit carries a session_id you can pass to get_transcript for \
                 the full speaker-attributed transcript. Browse with list_projects, \
                 list_sessions (pageable, filterable by kind/project), and recent_meetings."
                    .to_string(),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_middle_keeps_head_tail_and_marks_omission() {
        let s = "a".repeat(400) + &"z".repeat(400);
        let t = truncate_middle(&s, 200);
        assert!(t.starts_with("aaa"));
        assert!(t.ends_with("zzz"));
        assert!(t.contains("characters omitted"));
        // Short text passes through untouched.
        assert_eq!(truncate_middle("short", 200), "short");
    }

    #[test]
    fn kind_validation() {
        assert_eq!(validate_kind(None).unwrap(), None);
        assert_eq!(
            validate_kind(Some("Meeting")).unwrap(),
            Some("meeting".to_string())
        );
        assert!(validate_kind(Some("email")).is_err());
    }

    #[test]
    fn mmss_formats() {
        assert_eq!(mmss(0), "00:00");
        assert_eq!(mmss(67_000), "01:07");
        assert_eq!(mmss(3_600_000), "60:00");
    }
}
