//! Hark spike #4: Rust engine exposed to Swift via UniFFI (proc-macro mode).
//!
//! Swift pushes PCM buffers across the FFI boundary; every time >= 0.5 s of
//! audio has accumulated, a fake "transcript event" is delivered back to Swift
//! through a foreign-implemented callback trait.

use std::sync::{Arc, Mutex};
use std::time::Instant;

uniffi::setup_scaffolding!();

/// A fake transcript event (stands in for a real ASR hypothesis).
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptEvent {
    pub text: String,
    pub t_start_ms: i64,
    pub t_end_ms: i64,
}

/// Totals observed from the Rust side of the boundary.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineStats {
    pub total_buffers: u64,
    pub total_samples: u64,
    /// Total time spent inside `push_buffer` (Rust side), in nanoseconds.
    pub total_push_nanos: u64,
}

/// Implemented in Swift; Rust calls back across the boundary.
#[uniffi::export(with_foreign)]
pub trait TranscriptListener: Send + Sync {
    fn on_event(&self, event: TranscriptEvent);
}

struct SessionState {
    listener: Option<Arc<dyn TranscriptListener>>,
    pending: Vec<i16>,
    total_buffers: u64,
    total_samples: u64,
    total_push_nanos: u64,
    emitted_end_ms: i64,
    event_count: u64,
}

#[derive(uniffi::Object)]
pub struct EngineSession {
    sample_rate: u32,
    state: Mutex<SessionState>,
}

#[uniffi::export]
impl EngineSession {
    #[uniffi::constructor]
    pub fn new(sample_rate: u32) -> Arc<Self> {
        Arc::new(Self {
            sample_rate,
            state: Mutex::new(SessionState {
                listener: None,
                pending: Vec::new(),
                total_buffers: 0,
                total_samples: 0,
                total_push_nanos: 0,
                emitted_end_ms: 0,
                event_count: 0,
            }),
        })
    }

    pub fn set_listener(&self, listener: Arc<dyn TranscriptListener>) {
        self.state.lock().unwrap().listener = Some(listener);
    }

    /// Push one PCM buffer. Emits a fake transcript event per 0.5 s of audio.
    pub fn push_buffer(&self, samples: Vec<i16>) {
        let start = Instant::now();
        let chunk = (self.sample_rate / 2).max(1) as usize; // 0.5 s of samples

        let mut events: Vec<TranscriptEvent> = Vec::new();
        let listener = {
            let mut st = self.state.lock().unwrap();
            st.total_buffers += 1;
            st.total_samples += samples.len() as u64;
            st.pending.extend_from_slice(&samples);

            while st.pending.len() >= chunk {
                let seg: Vec<i16> = st.pending.drain(..chunk).collect();
                let sum_sq: f64 = seg.iter().map(|&s| (s as f64) * (s as f64)).sum();
                let rms = (sum_sq / chunk as f64).sqrt();
                let t_start = st.emitted_end_ms;
                let t_end = t_start + 500;
                st.emitted_end_ms = t_end;
                st.event_count += 1;
                events.push(TranscriptEvent {
                    text: format!(
                        "[fake transcript #{}] rms={:.1} total_samples={}",
                        st.event_count, rms, st.total_samples
                    ),
                    t_start_ms: t_start,
                    t_end_ms: t_end,
                });
            }
            st.listener.clone()
        }; // drop the lock before calling back into Swift

        if let Some(listener) = listener.as_ref() {
            for event in events {
                listener.on_event(event);
            }
        }

        // Record time spent (including callback delivery) as seen from Rust.
        let elapsed = start.elapsed().as_nanos() as u64;
        self.state.lock().unwrap().total_push_nanos += elapsed;
    }

    pub fn finish(&self) -> EngineStats {
        let st = self.state.lock().unwrap();
        EngineStats {
            total_buffers: st.total_buffers,
            total_samples: st.total_samples,
            total_push_nanos: st.total_push_nanos,
        }
    }
}
