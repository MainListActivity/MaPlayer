// Public API for the proxy engine — exposed to Dart via Flutter Rust Bridge.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use tokio::runtime::Runtime;
use tracing::{debug, info, warn};

use crate::config::EngineConfig;
use crate::engine::session::ProxySession;
use crate::engine::stats::StatsSnapshot;
use crate::server::handler::{ProxyServer, SessionMap};

// ---------------------------------------------------------------------------
// Public data types
// ---------------------------------------------------------------------------

/// Information about an active proxy session.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub session_id: String,
    pub playback_url: String,
    pub content_length: u64,
    pub content_type: String,
}

/// Live statistics for a proxy session (or aggregated across all sessions).
#[derive(Debug, Clone)]
pub struct ProxyStats {
    pub download_bps: u64,
    pub serve_bps: u64,
    pub buffered_bytes_ahead: u64,
    pub active_workers: u32,
    pub cache_hit_rate: f64,
}

impl From<StatsSnapshot> for ProxyStats {
    fn from(s: StatsSnapshot) -> Self {
        Self {
            download_bps: s.download_bps,
            serve_bps: s.serve_bps,
            buffered_bytes_ahead: s.buffered_bytes_ahead,
            active_workers: s.active_workers,
            cache_hit_rate: s.cache_hit_rate,
        }
    }
}

// ---------------------------------------------------------------------------
// Engine singleton
// ---------------------------------------------------------------------------

static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

struct Engine {
    runtime: Arc<Runtime>,
    server: Option<ProxyServer>,
    sessions: SessionMap,
    config: EngineConfig,
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/// Compute a deterministic session ID from a file key or URL.
fn compute_session_id(url: &str, file_key: &str) -> String {
    let input = if !file_key.is_empty() {
        format!("file:{}", file_key)
    } else {
        format!("url:{}", url)
    };
    let digest = md5::compute(input.as_bytes());
    format!("{:x}", digest)
}

// ---------------------------------------------------------------------------
// Public API functions
// ---------------------------------------------------------------------------

/// Initialize the proxy engine with the given configuration.
///
/// Idempotent — if already initialized, returns `Ok(())`.
#[flutter_rust_bridge::frb(sync)]
pub fn init_engine(config: EngineConfig) -> Result<()> {
    let mut guard = ENGINE.lock();
    if guard.is_some() {
        debug!("init_engine ignored: already initialized");
        return Ok(());
    }

    let runtime = Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| anyhow!("failed to create tokio runtime: {}", e))?,
    );

    let sessions: SessionMap = Arc::new(parking_lot::RwLock::new(HashMap::new()));

    let server = {
        let sessions_clone = sessions.clone();
        runtime.block_on(async { ProxyServer::start(sessions_clone).await })?
    };

    info!("proxy engine initialized on port {}", server.port());

    *guard = Some(Engine {
        runtime,
        server: Some(server),
        sessions,
        config,
    });

    Ok(())
}

/// Create a new proxy session for the given source URL.
///
/// Returns an existing session if one already exists with the same session ID.
/// Otherwise clears previous sessions and creates a new one.
#[flutter_rust_bridge::frb(sync)]
pub fn create_session(
    url: String,
    headers: HashMap<String, String>,
    file_key: String,
) -> Result<SessionInfo> {
    let session_id = compute_session_id(&url, &file_key);
    info!(
        "create_session id={} file_key_present={} headers={}",
        session_id,
        !file_key.is_empty(),
        headers.len()
    );

    // Extract what we need from the engine while holding the lock briefly.
    let (runtime, sessions, config, port) = {
        let guard = ENGINE.lock();
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow!("engine not initialized"))?;
        let port = engine
            .server
            .as_ref()
            .ok_or_else(|| anyhow!("server not running"))?
            .port();
        (
            engine.runtime.clone(),
            engine.sessions.clone(),
            engine.config.clone(),
            port,
        )
    };

    // Check if session already exists.
    {
        let map = sessions.read();
        if let Some(session) = map.get(&session_id) {
            let playback_url = format!("http://127.0.0.1:{}/stream/{}", port, session_id);
            debug!("reuse existing session id={}", session_id);
            return Ok(SessionInfo {
                session_id,
                playback_url,
                content_length: session.content_length(),
                content_type: session.content_type().to_string(),
            });
        }
    }

    // Clear old sessions before creating a new one.
    {
        let mut map = sessions.write();
        if !map.is_empty() {
            warn!(
                "clearing {} previous session(s) before new session",
                map.len()
            );
        }
        map.clear();
    }

    // Create the new session (async, outside any engine lock).
    let session = runtime
        .block_on(async {
            ProxySession::new(
                session_id.clone(),
                url,
                headers,
                &config.cache_dir,
                config.chunk_size,
                config.max_concurrency,
            )
            .await
        })
        .map_err(|e| {
            warn!("create_session failed id={} error={}", session_id, e);
            e
        })?;

    let content_length = session.content_length();
    let content_type = session.content_type().to_string();
    let playback_url = format!("http://127.0.0.1:{}/stream/{}", port, session_id);

    // Insert into the session map.
    {
        let mut map = sessions.write();
        map.insert(session_id.clone(), Arc::new(session));
    }

    Ok(SessionInfo {
        session_id,
        playback_url,
        content_length,
        content_type,
    })
}

/// Close an existing proxy session and remove it from the map.
#[flutter_rust_bridge::frb(sync)]
pub fn close_session(session_id: String) -> Result<()> {
    let sessions = {
        let guard = ENGINE.lock();
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow!("engine not initialized"))?;
        engine.sessions.clone()
    };

    let mut map = sessions.write();
    map.remove(&session_id);
    debug!("close_session id={}", session_id);
    Ok(())
}

/// Return a snapshot of current session statistics.
///
/// If `session_id` is provided, returns stats for that session only.
/// If `None`, aggregates stats across all active sessions.
#[flutter_rust_bridge::frb(sync)]
pub fn get_stats(session_id: Option<String>) -> Result<ProxyStats> {
    let sessions = {
        let guard = ENGINE.lock();
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow!("engine not initialized"))?;
        engine.sessions.clone()
    };

    let map = sessions.read();

    if let Some(id) = session_id {
        let session = map
            .get(&id)
            .ok_or_else(|| anyhow!("session not found: {}", id))?;
        Ok(session.snapshot().into())
    } else {
        // Aggregate across all sessions.
        let mut total = ProxyStats {
            download_bps: 0,
            serve_bps: 0,
            buffered_bytes_ahead: 0,
            active_workers: 0,
            cache_hit_rate: 0.0,
        };
        let count = map.len();
        for session in map.values() {
            let snap: ProxyStats = session.snapshot().into();
            total.download_bps += snap.download_bps;
            total.serve_bps += snap.serve_bps;
            total.buffered_bytes_ahead += snap.buffered_bytes_ahead;
            total.active_workers += snap.active_workers;
            total.cache_hit_rate += snap.cache_hit_rate;
        }
        if count > 0 {
            total.cache_hit_rate /= count as f64;
        }
        Ok(total)
    }
}

/// Update authentication credentials for an active session.
#[flutter_rust_bridge::frb(sync)]
pub fn update_session_auth(
    session_id: String,
    new_url: String,
    new_headers: HashMap<String, String>,
) -> Result<()> {
    let sessions = {
        let guard = ENGINE.lock();
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow!("engine not initialized"))?;
        engine.sessions.clone()
    };

    let map = sessions.read();
    let session = map
        .get(&session_id)
        .ok_or_else(|| anyhow!("session not found: {}", session_id))?;

    info!(
        "update_session_auth id={} new_url_supplied={} new_headers={}",
        session_id,
        !new_url.trim().is_empty(),
        new_headers.len()
    );
    session.update_auth(new_url, new_headers);
    Ok(())
}

/// Shut down the proxy engine and release all resources.
#[flutter_rust_bridge::frb(sync)]
pub fn dispose() -> Result<()> {
    let mut guard = ENGINE.lock();
    if let Some(mut engine) = guard.take() {
        // Clear all sessions.
        {
            let mut map = engine.sessions.write();
            map.clear();
        }

        // Shutdown the server.
        if let Some(server) = engine.server.take() {
            server.shutdown();
        }

        // The runtime will be dropped when all Arc references are gone.
        info!("proxy engine disposed");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_session_id_with_file_key() {
        let id1 = compute_session_id("https://example.com/file.mp4", "abc123");
        let id2 = compute_session_id("https://different.com/other.mp4", "abc123");
        // Same file_key should produce the same session ID regardless of URL.
        assert_eq!(id1, id2);
        assert_eq!(id1.len(), 32); // md5 hex is 32 chars
    }

    #[test]
    fn test_compute_session_id_with_url() {
        let id1 = compute_session_id("https://example.com/file.mp4", "");
        let id2 = compute_session_id("https://example.com/file.mp4", "");
        assert_eq!(id1, id2);

        let id3 = compute_session_id("https://example.com/other.mp4", "");
        assert_ne!(id1, id3);
    }

    #[test]
    fn test_session_info_fields() {
        let info = SessionInfo {
            session_id: "test".to_string(),
            playback_url: "http://127.0.0.1:8080/stream/test".to_string(),
            content_length: 1024,
            content_type: "video/mp4".to_string(),
        };
        assert_eq!(info.session_id, "test");
        assert_eq!(info.content_length, 1024);
    }

    #[test]
    fn test_proxy_stats_from_snapshot() {
        let snap = StatsSnapshot {
            download_bps: 100,
            serve_bps: 200,
            buffered_bytes_ahead: 300,
            active_workers: 4,
            cache_hit_rate: 0.75,
        };
        let stats: ProxyStats = snap.into();
        assert_eq!(stats.download_bps, 100);
        assert_eq!(stats.serve_bps, 200);
        assert_eq!(stats.buffered_bytes_ahead, 300);
        assert_eq!(stats.active_workers, 4);
        assert!((stats.cache_hit_rate - 0.75).abs() < f64::EPSILON);
    }
}
