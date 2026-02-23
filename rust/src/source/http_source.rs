use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use bytes::Bytes;
use parking_lot::RwLock;
use reqwest::{Client, RequestBuilder};
use tracing::{debug, warn};

use super::traits::{MediaSource, SourceInfo};

pub struct HttpSource {
    client: Client,
    url: Arc<RwLock<String>>,
    headers: Arc<RwLock<HashMap<String, String>>>,
}

impl HttpSource {
    pub fn new(url: String, headers: HashMap<String, String>) -> Self {
        Self {
            client: Client::new(),
            url: Arc::new(RwLock::new(url)),
            headers: Arc::new(RwLock::new(headers)),
        }
    }

    /// Update the URL and headers (e.g. after token refresh).
    pub fn update_auth(&self, new_url: String, new_headers: HashMap<String, String>) {
        if !new_url.trim().is_empty() {
            *self.url.write() = new_url;
        }
        if !new_headers.is_empty() {
            *self.headers.write() = new_headers;
        }
    }

    /// Build a GET request with the current URL, custom headers, and an optional Range header.
    fn build_request(&self, range_header: Option<&str>) -> RequestBuilder {
        let url = self.url.read().clone();
        let headers = self.headers.read().clone();

        let mut req = self.client.get(&url);
        for (k, v) in &headers {
            req = req.header(k.as_str(), v.as_str());
        }
        if let Some(range) = range_header {
            req = req.header("Range", range);
        }
        req
    }
}

#[async_trait]
impl MediaSource for HttpSource {
    async fn probe(&self) -> Result<SourceInfo> {
        let resp = self.build_request(Some("bytes=0-0")).send().await?;

        let status = resp.status();
        debug!("http probe status={}", status.as_u16());
        if status.as_u16() == 401 || status.as_u16() == 403 || status.as_u16() == 412 {
            warn!("http probe auth rejected status={}", status.as_u16());
            return Err(anyhow!("auth_rejected: HTTP {}", status.as_u16()));
        }
        if !status.is_success() {
            warn!("http probe failed status={}", status.as_u16());
            return Err(anyhow!("probe failed: HTTP {}", status.as_u16()));
        }

        // Parse Content-Range: bytes 0-0/<total>
        let supports_range = status.as_u16() == 206;
        let content_length = if supports_range {
            resp.headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.rsplit('/').next())
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0)
        } else {
            resp.headers()
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0)
        };

        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();

        Ok(SourceInfo {
            content_length,
            content_type,
            supports_range,
        })
    }

    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes> {
        let range = format!("bytes={}-{}", start, end);
        let resp = self.build_request(Some(&range)).send().await?;

        let status = resp.status();
        if status.as_u16() == 401 || status.as_u16() == 403 || status.as_u16() == 412 {
            warn!(
                "http fetch auth rejected status={} range={}",
                status.as_u16(),
                range
            );
            return Err(anyhow!("auth_rejected: HTTP {}", status.as_u16()));
        }
        if !status.is_success() {
            warn!(
                "http fetch failed status={} range={}",
                status.as_u16(),
                range
            );
            return Err(anyhow!("fetch_range failed: HTTP {}", status.as_u16()));
        }

        let bytes = resp.bytes().await?;
        Ok(bytes)
    }

    async fn refresh_auth(&self) -> Result<()> {
        Ok(())
    }
}
