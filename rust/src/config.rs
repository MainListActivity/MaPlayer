use serde::Deserialize;

/// Number of seconds of content to keep buffered ahead of playback.
pub const PRIORITY_BUFFER_SECONDS: u64 = 120;

/// Maximum bytes allowed for an open-ended HTTP response (64 MB).
pub const MAX_OPEN_ENDED_RESPONSE_BYTES: u64 = 64 * 1024 * 1024;

/// Clamp size for the initial startup probe request (512 KB).
pub const STARTUP_PROBE_CLAMP_BYTES: u64 = 512 * 1024;

/// Minimum byte distance to treat a new request as a seek (4 MB).
pub const SEEK_THRESHOLD_BYTES: u64 = 4 * 1024 * 1024;

/// Warm-up period in seconds after a seek before applying optimizations.
pub const SEEK_WARMUP_SECONDS: u64 = 3;

/// Number of requests during warm-up before switching strategy.
pub const SEEK_WARMUP_REQUESTS: u32 = 3;

/// Number of sequential cache hits required to consider playback stable after a seek.
pub const SEEK_STABLE_SEQUENTIAL_HITS: u32 = 2;

/// Top-level configuration for the proxy engine.
#[derive(Debug, Clone, Deserialize)]
pub struct EngineConfig {
    /// Size of each download chunk in bytes.
    pub chunk_size: u64,
    /// Maximum number of concurrent download tasks.
    pub max_concurrency: u32,
    /// Directory used for on-disk cache files.
    pub cache_dir: String,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            chunk_size: 2 * 1024 * 1024, // 2 MB
            max_concurrency: 6,
            cache_dir: String::new(),
        }
    }
}
