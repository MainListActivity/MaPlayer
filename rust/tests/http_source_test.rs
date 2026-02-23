use std::collections::HashMap;
use std::net::SocketAddr;

use axum::extract::Request;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use tokio::net::TcpListener;

use ma_proxy_engine::source::http_source::HttpSource;
use ma_proxy_engine::source::traits::MediaSource;

const TEST_SIZE: usize = 1024 * 1024; // 1 MB

async fn serve_file(req: Request) -> impl IntoResponse {
    let body: Vec<u8> = (0..TEST_SIZE).map(|i| (i % 256) as u8).collect();
    let total = body.len() as u64;

    if let Some(range_val) = req.headers().get("Range") {
        let range_str = range_val.to_str().unwrap_or("");
        // Parse "bytes=START-END"
        if let Some(rest) = range_str.strip_prefix("bytes=") {
            let parts: Vec<&str> = rest.splitn(2, '-').collect();
            if parts.len() == 2 {
                let start: u64 = parts[0].parse().unwrap_or(0);
                let end: u64 = if parts[1].is_empty() {
                    total - 1
                } else {
                    parts[1].parse().unwrap_or(total - 1)
                };
                let end = end.min(total - 1);
                let slice = &body[start as usize..=end as usize];
                let content_range = format!("bytes {}-{}/{}", start, end, total);
                return (
                    StatusCode::PARTIAL_CONTENT,
                    [
                        (header::CONTENT_TYPE, "video/mp4".to_string()),
                        (header::CONTENT_RANGE, content_range),
                        (header::CONTENT_LENGTH, slice.len().to_string()),
                    ],
                    slice.to_vec(),
                )
                    .into_response();
            }
        }
    }

    // No range — return full body
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "video/mp4".to_string()),
            (header::CONTENT_LENGTH, total.to_string()),
        ],
        body,
    )
        .into_response()
}

async fn start_server() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let app = Router::new().route("/file", get(serve_file));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, handle)
}

#[tokio::test]
async fn test_http_source_probe() {
    let (addr, _handle) = start_server().await;
    let url = format!("http://{}/file", addr);
    let source = HttpSource::new(url, HashMap::new());

    let info = source.probe().await.unwrap();
    assert_eq!(info.content_length, TEST_SIZE as u64);
    assert!(info.supports_range);
    assert_eq!(info.content_type, "video/mp4");
}

#[tokio::test]
async fn test_http_source_fetch_range() {
    let (addr, _handle) = start_server().await;
    let url = format!("http://{}/file", addr);
    let source = HttpSource::new(url, HashMap::new());

    let data = source.fetch_range(0, 99).await.unwrap();
    assert_eq!(data.len(), 100);
    // Verify content matches our pattern
    for i in 0..100u8 {
        assert_eq!(data[i as usize], i);
    }
}
