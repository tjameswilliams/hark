use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionKind {
    Dictation,
    Meeting,
}

impl SessionKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            SessionKind::Dictation => "dictation",
            SessionKind::Meeting => "meeting",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: i64,
    pub name: String,
    pub description: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: i64,
    pub project_id: Option<i64>,
    pub kind: SessionKind,
    pub title: Option<String>,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub audio_path: Option<String>,
    /// Frontmost app bundle id at dictation time, for context-aware cleanup.
    pub app_context: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Segment {
    pub id: i64,
    pub session_id: i64,
    pub speaker_id: Option<i64>,
    pub t_start_ms: i64,
    pub t_end_ms: i64,
    pub text: String,
    pub confidence: Option<f64>,
}
