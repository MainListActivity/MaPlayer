use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use bytes::Bytes;
use parking_lot::RwLock;
use reqwest::{Client, RequestBuilder, Url};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

use super::traits::{MediaSource, SourceInfo};

pub struct HttpSource {
    client: Client,
    url: Arc<RwLock<String>>,
    headers: Arc<RwLock<HashMap<String, String>>>,
    route_clients: Arc<RwLock<Vec<RouteClient>>>,
    route_init_lock: Arc<Mutex<()>>,
    next_route: AtomicUsize,
}

#[derive(Clone)]
struct RouteClient {
    ip: IpAddr,
    client: Client,
}

impl HttpSource {
    pub fn new(url: String, headers: HashMap<String, String>) -> Self {
        Self {
            client: Client::new(),
            url: Arc::new(RwLock::new(url)),
            headers: Arc::new(RwLock::new(headers)),
            route_clients: Arc::new(RwLock::new(Vec::new())),
            route_init_lock: Arc::new(Mutex::new(())),
            next_route: AtomicUsize::new(0),
        }
    }

    /// Update the URL and headers (e.g. after token refresh).
    pub fn update_auth(&self, new_url: String, new_headers: HashMap<String, String>) {
        if !new_url.trim().is_empty() {
            *self.url.write() = new_url;
            self.route_clients.write().clear();
            self.next_route.store(0, Ordering::Relaxed);
        }
        if !new_headers.is_empty() {
            *self.headers.write() = new_headers;
        }
    }

    /// Build a GET request with the current URL, custom headers, and an optional Range header.
    fn build_request_with_client(
        &self,
        client: &Client,
        range_header: Option<&str>,
    ) -> RequestBuilder {
        let url = self.url.read().clone();
        let headers = self.headers.read().clone();

        let mut req = client.get(&url);
        for (k, v) in &headers {
            req = req.header(k.as_str(), v.as_str());
        }
        if let Some(range) = range_header {
            req = req.header("Range", range);
        }
        req
    }

    fn route_count(&self) -> usize {
        let routes = self.route_clients.read();
        if routes.is_empty() {
            1
        } else {
            routes.len()
        }
    }

    pub async fn effective_concurrency(&self, configured: u32) -> u32 {
        if let Err(e) = self.ensure_route_clients().await {
            warn!("init route clients failed: {}", e);
        }
        let by_ip = self.route_count() as u32;
        let effective = configured.min(8).min(by_ip.max(1));
        if effective != configured {
            info!(
                "downloader concurrency adjusted by ip pool: configured={} effective={} ips={}",
                configured, effective, by_ip
            );
        }
        effective
    }

    fn pick_client(&self) -> (Client, Option<IpAddr>) {
        let routes = self.route_clients.read();
        if routes.is_empty() {
            return (self.client.clone(), None);
        }
        let idx = self.next_route.fetch_add(1, Ordering::Relaxed) % routes.len();
        let route = routes[idx].clone();
        (route.client, Some(route.ip))
    }

    async fn ensure_route_clients(&self) -> Result<()> {
        if !self.route_clients.read().is_empty() {
            return Ok(());
        }

        let _guard = self.route_init_lock.lock().await;
        if !self.route_clients.read().is_empty() {
            return Ok(());
        }

        let url = self.url.read().clone();
        let parsed = Url::parse(&url).map_err(|e| anyhow!("invalid source url: {}", e))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| anyhow!("source url has no host"))?
            .to_string();
        let port = parsed
            .port_or_known_default()
            .ok_or_else(|| anyhow!("cannot determine source port"))?;

        let mut ips: Vec<IpAddr> = Vec::new();
        for addr in tokio::net::lookup_host((host.as_str(), port)).await? {
            if !ips.contains(&addr.ip()) {
                ips.push(addr.ip());
            }
        }
        if ips.is_empty() {
            return Ok(());
        }
        if ips.len() > 8 {
            ips.truncate(8);
        }

        let mut routes = Vec::with_capacity(ips.len());
        for ip in &ips {
            let client = Client::builder()
                .resolve(host.as_str(), SocketAddr::new(*ip, port))
                .build()?;
            routes.push(RouteClient { ip: *ip, client });
        }

        let ip_list = ips
            .iter()
            .map(std::string::ToString::to_string)
            .collect::<Vec<_>>()
            .join(",");
        info!(
            "http source route pool host={} port={} ips={} [{}]",
            host,
            port,
            routes.len(),
            ip_list
        );

        *self.route_clients.write() = routes;
        Ok(())
    }
}

#[async_trait]
impl MediaSource for HttpSource {
    async fn probe(&self) -> Result<SourceInfo> {
        let resp = self
            .build_request_with_client(&self.client, Some("bytes=0-0"))
            .send()
            .await?;

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

        if let Err(e) = self.ensure_route_clients().await {
            warn!("prepare route clients failed: {}", e);
        }

        Ok(SourceInfo {
            content_length,
            content_type,
            supports_range,
        })
    }

    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes> {
        let range = format!("bytes={}-{}", start, end);
        if self.route_clients.read().is_empty() {
            let _ = self.ensure_route_clients().await;
        }
        let (client, route_ip) = self.pick_client();
        if let Some(ip) = route_ip {
            debug!("http fetch via ip={} range={}", ip, range);
        }
        let resp = self
            .build_request_with_client(&client, Some(&range))
            .send()
            .await?;

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
