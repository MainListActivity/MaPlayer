// Axum request handler — translates player HTTP requests into cache/download operations.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use parking_lot::RwLock;
use tokio::net::TcpListener;
use tracing::{debug, error};

use crate::config::MAX_OPEN_ENDED_RESPONSE_BYTES;
use crate::engine::session::ProxySession;

pub type SessionMap = Arc<RwLock<HashMap<String, Arc<ProxySession>>>>;

pub struct ProxyServer {
    port: u16,
    sessions: SessionMap,
    shutdown_tx: Option<tokio::sync::oneshot::Sender<()>>,
}

impl ProxyServer {
    /// Start the proxy server on a random port, returning a handle.
    pub async fn start(sessions: SessionMap) -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

        let app = Router::new()
            .route("/stream/{session_id}", get(stream_handler).head(head_handler))
            .with_state(sessions.clone());

        tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = shutdown_rx.await;
                })
                .await
                .ok();
        });

        Ok(Self {
            port,
            sessions,
            shutdown_tx: Some(shutdown_tx),
        })
    }

    /// Get the port the server is listening on.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Build a URL for streaming a specific session.
    pub fn url_for_session(&self, session_id: &str) -> String {
        format!("http://127.0.0.1:{}/stream/{}", self.port, session_id)
    }

    /// Get a reference to the session map.
    pub fn sessions(&self) -> &SessionMap {
        &self.sessions
    }

    /// Shutdown the server gracefully.
    pub fn shutdown(mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
    }
}

/// Parse a Range header value like "bytes=start-end" or "bytes=start-".
/// Returns (start, Some(end)) or (start, None).
fn parse_range_header(value: &str) -> Option<(u64, Option<u64>)> {
    let value = value.trim();
    let rest = value.strip_prefix("bytes=")?;
    let mut parts = rest.splitn(2, '-');
    let start_str = parts.next()?.trim();
    let end_str = parts.next()?.trim();

    let start: u64 = start_str.parse().ok()?;
    let end = if end_str.is_empty() {
        None
    } else {
        Some(end_str.parse::<u64>().ok()?)
    };
    Some((start, end))
}

/// GET /stream/{session_id} — serve content with Range support.
async fn stream_handler(
    State(sessions): State<SessionMap>,
    Path(session_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let session = {
        let map = sessions.read();
        map.get(&session_id).cloned()
    };

    let session = match session {
        Some(s) => s,
        None => {
            return (StatusCode::NOT_FOUND, "session not found").into_response();
        }
    };

    let total = session.content_length();
    let content_type = session.content_type().to_string();

    // Parse Range header.
    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_header);

    let (start, end, is_partial) = match range {
        Some((start, Some(end))) => {
            // Inclusive end in HTTP Range → exclusive end for serve_range.
            let end = (end + 1).min(total);
            if start >= total {
                return (
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    [(header::CONTENT_RANGE, format!("bytes */{}", total))],
                    "range not satisfiable",
                )
                    .into_response();
            }
            (start, end, true)
        }
        Some((start, None)) => {
            if start >= total {
                return (
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    [(header::CONTENT_RANGE, format!("bytes */{}", total))],
                    "range not satisfiable",
                )
                    .into_response();
            }
            // Open-ended: clamp to MAX_OPEN_ENDED_RESPONSE_BYTES.
            let end = (start + MAX_OPEN_ENDED_RESPONSE_BYTES).min(total);
            (start, end, true)
        }
        None => {
            // No Range header — serve entire file (clamped).
            (0, total, false)
        }
    };

    debug!(
        "stream session={} range=[{}, {}) partial={}",
        session_id, start, end, is_partial
    );

    match session.serve_range(start, end).await {
        Ok(data) => {
            let body_len = data.len();
            let status = if is_partial {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            };

            let mut resp_headers = HeaderMap::new();
            resp_headers.insert(header::CONTENT_TYPE, content_type.parse().unwrap());
            resp_headers.insert(
                header::CONTENT_LENGTH,
                body_len.to_string().parse().unwrap(),
            );
            resp_headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());

            if is_partial {
                // Content-Range: bytes start-end/total (end is inclusive in HTTP).
                let content_range = format!("bytes {}-{}/{}", start, end - 1, total);
                resp_headers.insert(header::CONTENT_RANGE, content_range.parse().unwrap());
            }

            (status, resp_headers, data).into_response()
        }
        Err(e) => {
            error!("serve_range error: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {}", e)).into_response()
        }
    }
}

/// HEAD /stream/{session_id} — return headers only.
async fn head_handler(
    State(sessions): State<SessionMap>,
    Path(session_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let session = {
        let map = sessions.read();
        map.get(&session_id).cloned()
    };

    let session = match session {
        Some(s) => s,
        None => {
            return (StatusCode::NOT_FOUND, "session not found").into_response();
        }
    };

    let total = session.content_length();
    let content_type = session.content_type().to_string();

    let mut resp_headers = HeaderMap::new();
    resp_headers.insert(header::CONTENT_TYPE, content_type.parse().unwrap());
    resp_headers.insert(
        header::CONTENT_LENGTH,
        total.to_string().parse().unwrap(),
    );
    resp_headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());

    // If Range header is present, include Content-Range.
    if let Some(range_val) = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_header)
    {
        let (start, end_opt) = range_val;
        let end = match end_opt {
            Some(e) => (e + 1).min(total),
            None => total,
        };
        let content_range = format!("bytes {}-{}/{}", start, end - 1, total);
        resp_headers.insert(header::CONTENT_RANGE, content_range.parse().unwrap());
    }

    (StatusCode::OK, resp_headers).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_range_header_full() {
        let result = parse_range_header("bytes=0-1023");
        assert_eq!(result, Some((0, Some(1023))));
    }

    #[test]
    fn test_parse_range_header_open_ended() {
        let result = parse_range_header("bytes=500-");
        assert_eq!(result, Some((500, None)));
    }

    #[test]
    fn test_parse_range_header_invalid() {
        assert_eq!(parse_range_header("invalid"), None);
        assert_eq!(parse_range_header("bytes=abc-def"), None);
    }
}
