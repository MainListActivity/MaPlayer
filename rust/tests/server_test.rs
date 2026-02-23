// Integration test for the ProxyServer.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    extract::Request,
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use parking_lot::RwLock;
use tokio::net::TcpListener;

use ma_proxy_engine::engine::session::ProxySession;
use ma_proxy_engine::server::handler::{ProxyServer, SessionMap};

const CONTENT_SIZE: usize = 10 * 1024 * 1024; // 10 MB

/// Generate deterministic test content.
fn generate_content() -> Vec<u8> {
    (0..CONTENT_SIZE).map(|i| (i % 256) as u8).collect()
}

/// Fake upstream server that supports Range requests.
async fn fake_upstream_handler(req: Request) -> impl IntoResponse {
    let content = generate_content();
    let total = content.len() as u64;

    let range_header = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    if let Some(range_val) = range_header {
        // Parse "bytes=start-end"
        if let Some(rest) = range_val.strip_prefix("bytes=") {
            let mut parts = rest.splitn(2, '-');
            let start: u64 = parts
                .next()
                .unwrap_or("0")
                .parse()
                .unwrap_or(0);
            let end_str = parts.next().unwrap_or("");
            let end: u64 = if end_str.is_empty() {
                total - 1
            } else {
                end_str.parse().unwrap_or(total - 1)
            };
            let end = end.min(total - 1);

            let slice = &content[start as usize..=(end as usize).min(content.len() - 1)];
            let content_range = format!("bytes {}-{}/{}", start, end, total);

            (
                StatusCode::PARTIAL_CONTENT,
                [
                    (header::CONTENT_TYPE, "audio/mpeg".to_string()),
                    (header::CONTENT_RANGE, content_range),
                    (header::CONTENT_LENGTH, slice.len().to_string()),
                    (header::ACCEPT_RANGES, "bytes".to_string()),
                ],
                slice.to_vec(),
            )
                .into_response()
        } else {
            (StatusCode::BAD_REQUEST, "bad range").into_response()
        }
    } else {
        // No range — return full content.
        (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "audio/mpeg".to_string()),
                (header::CONTENT_LENGTH, total.to_string()),
                (header::ACCEPT_RANGES, "bytes".to_string()),
            ],
            content,
        )
            .into_response()
    }
}

#[tokio::test]
async fn test_proxy_server() {
    // 1. Start fake upstream server.
    let upstream_app = Router::new().route("/file", get(fake_upstream_handler));
    let upstream_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_port = upstream_listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        axum::serve(upstream_listener, upstream_app).await.ok();
    });

    let upstream_url = format!("http://127.0.0.1:{}/file", upstream_port);

    // 2. Create a ProxySession pointing at the upstream.
    let tmp_dir = tempfile::tempdir().unwrap();
    let session = ProxySession::new(
        "test-session".to_string(),
        upstream_url,
        HashMap::new(),
        tmp_dir.path().to_str().unwrap(),
        2 * 1024 * 1024, // 2 MB chunks
        4,
    )
    .await
    .unwrap();

    let session = Arc::new(session);

    // 3. Start ProxyServer with the session.
    let sessions: SessionMap = Arc::new(RwLock::new(HashMap::new()));
    sessions
        .write()
        .insert("test-session".to_string(), session.clone());

    let server = ProxyServer::start(sessions).await.unwrap();
    let stream_url = server.url_for_session("test-session");

    // 4. Request Range: bytes=0-1023 from the proxy.
    let client = reqwest::Client::new();
    let resp = client
        .get(&stream_url)
        .header("Range", "bytes=0-1023")
        .send()
        .await
        .unwrap();

    // 5. Assert: status 206, body length 1024, content matches.
    assert_eq!(resp.status(), 206);

    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len(), 1024);

    let expected = generate_content();
    assert_eq!(&body[..], &expected[0..1024]);

    // Test HEAD request.
    let head_resp = client
        .head(&stream_url)
        .send()
        .await
        .unwrap();
    assert_eq!(head_resp.status(), 200);
    assert!(head_resp.headers().contains_key("accept-ranges"));

    // Test 404 for unknown session.
    let unknown_url = server.url_for_session("nonexistent");
    let resp_404 = client.get(&unknown_url).send().await.unwrap();
    assert_eq!(resp_404.status(), 404);

    // Cleanup.
    server.shutdown();
}
