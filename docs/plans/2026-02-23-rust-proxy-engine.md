# Rust Proxy Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the 1682-line Dart `proxy_controller.dart` with a Rust crate (`ma_proxy_engine`) using Flutter Rust Bridge, providing mmap disk cache, axum HTTP server, parallel chunk downloads, container auto-detection, and extensible MediaSource trait for future BT support.

**Architecture:** Rust crate handles all proxy logic (HTTP server, download engine, disk cache, stats). Dart side becomes a thin ~50-line FRB wrapper. Communication: FRB for init/create/close/stats/dispose; media_kit talks directly to Rust's axum HTTP server.

**Tech Stack:** Rust (axum, reqwest, tokio, memmap2, bitvec, flutter_rust_bridge), Dart/Flutter (flutter_rust_bridge, media_kit)

---

## Task 1: Scaffold Rust Crate with FRB Integration

**Files:**
- Create: `rust/Cargo.toml`
- Create: `rust/src/lib.rs`
- Create: `rust/src/api/mod.rs`
- Create: `rust/src/api/proxy_api.rs`
- Create: `rust/src/config.rs`
- Modify: `pubspec.yaml` (add flutter_rust_bridge dependency)

**Step 1: Create Rust crate directory structure**

```bash
mkdir -p rust/src/api rust/src/engine rust/src/server rust/src/source rust/src/detect
```

**Step 2: Write Cargo.toml**

Create `rust/Cargo.toml`:
```toml
[package]
name = "ma_proxy_engine"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
flutter_rust_bridge = "=2.9.0"
tokio = { version = "1", features = ["full"] }
axum = "0.8"
reqwest = { version = "0.12", features = ["stream"] }
memmap2 = "0.9"
bitvec = "1"
bytes = "1"
async-trait = "0.1"
serde = { version = "1", features = ["derive"] }
md5 = "0.7"
tracing = "0.1"
parking_lot = "0.12"
tokio-util = { version = "0.7", features = ["io"] }
http-range-header = "0.4"
tower-http = { version = "0.6", features = ["cors"] }
anyhow = "1"
```

**Step 3: Write lib.rs**

Create `rust/src/lib.rs`:
```rust
pub mod api;
pub mod config;
pub mod engine;
pub mod server;
pub mod source;
pub mod detect;
```

**Step 4: Write config.rs**

Create `rust/src/config.rs`:
```rust
use flutter_rust_bridge::frb;

#[frb(dart_metadata=("freezed"))]
pub struct EngineConfig {
    /// Chunk size in bytes (default 2MB)
    pub chunk_size: u64,
    /// Max concurrent downloads per session (default 8)
    pub max_concurrency: u32,
    /// Directory for temporary cache files
    pub cache_dir: String,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            chunk_size: 2 * 1024 * 1024,
            max_concurrency: 8,
            cache_dir: String::new(),
        }
    }
}

/// Priority buffer: prefetch ~2 minutes ahead based on playback rate.
pub const PRIORITY_BUFFER_SECONDS: u64 = 120;

/// Maximum response for open-ended Range requests.
pub const MAX_OPEN_ENDED_RESPONSE_BYTES: u64 = 64 * 1024 * 1024;

/// Startup probe clamp size.
pub const STARTUP_PROBE_CLAMP_BYTES: u64 = 2 * 1024 * 1024;

/// Seek detection threshold.
pub const SEEK_THRESHOLD_BYTES: u64 = 4 * 1024 * 1024;

/// Seek detection warmup duration in seconds.
pub const SEEK_WARMUP_SECONDS: u64 = 3;

/// Minimum sequential requests before enabling seek detection.
pub const SEEK_WARMUP_REQUESTS: u32 = 3;

/// Sequential hits required for stable playback classification.
pub const SEEK_STABLE_SEQUENTIAL_HITS: u32 = 2;
```

**Step 5: Write stub API module**

Create `rust/src/api/mod.rs`:
```rust
pub mod proxy_api;
```

Create `rust/src/api/proxy_api.rs`:
```rust
use std::collections::HashMap;
use flutter_rust_bridge::frb;

use crate::config::EngineConfig;

#[frb(dart_metadata=("freezed"))]
pub struct SessionInfo {
    pub session_id: String,
    pub playback_url: String,
}

#[frb(dart_metadata=("freezed"))]
pub struct ProxyStats {
    pub download_bps: u64,
    pub serve_bps: u64,
    pub buffered_bytes_ahead: u64,
    pub active_workers: u32,
    pub cache_hit_rate: f64,
}

/// Initialize the proxy engine. Must be called once before any other API.
#[frb]
pub fn init_engine(config: EngineConfig) -> anyhow::Result<()> {
    todo!("Task 6: wire up engine singleton")
}

/// Create a proxy session for the given URL.
#[frb]
pub async fn create_session(
    url: String,
    headers: HashMap<String, String>,
    file_key: String,
) -> anyhow::Result<SessionInfo> {
    todo!("Task 6: wire up session creation")
}

/// Close a session and clean up its cache files.
#[frb]
pub fn close_session(session_id: String) -> anyhow::Result<()> {
    todo!("Task 6: wire up session close")
}

/// Stream real-time statistics. Pass None for aggregate stats across all sessions.
#[frb]
pub fn watch_stats(session_id: Option<String>) -> anyhow::Result<Vec<ProxyStats>> {
    todo!("Task 6: wire up stats stream")
}

/// Shut down the engine and clean up all resources.
#[frb]
pub fn dispose() -> anyhow::Result<()> {
    todo!("Task 6: wire up dispose")
}
```

**Step 6: Write stub modules for engine, server, source, detect**

Create `rust/src/engine/mod.rs`:
```rust
pub mod session;
pub mod downloader;
pub mod cache;
pub mod warmup;
pub mod stats;
```

Create each sub-module as empty stubs:

`rust/src/engine/session.rs`:
```rust
// ProxySession: manages a single media file download lifecycle
```

`rust/src/engine/downloader.rs`:
```rust
// Parallel chunk downloader with tokio::Semaphore
```

`rust/src/engine/cache.rs`:
```rust
// Disk cache with mmap + BitVec chunk bitmap
```

`rust/src/engine/warmup.rs`:
```rust
// Container-aware startup prefetch (MP4 moov, MKV EBML, etc.)
```

`rust/src/engine/stats.rs`:
```rust
// Real-time download/serve statistics collector
```

Create `rust/src/server/mod.rs`:
```rust
pub mod handler;
```

`rust/src/server/handler.rs`:
```rust
// axum HTTP server with Range request handling
```

Create `rust/src/source/mod.rs`:
```rust
pub mod traits;
pub mod http_source;
pub mod iso_source;
```

`rust/src/source/traits.rs`:
```rust
// trait MediaSource definition
```

`rust/src/source/http_source.rs`:
```rust
// HttpSource: cloud storage HTTP Range download
```

`rust/src/source/iso_source.rs`:
```rust
// IsoMediaSource: decorator for UDF offset mapping (future)
```

Create `rust/src/detect/mod.rs`:
```rust
pub mod container;
```

`rust/src/detect/container.rs`:
```rust
// Container format auto-detection (ISO, MP4, MKV, TS)
```

**Step 7: Add flutter_rust_bridge to pubspec.yaml**

Add to `pubspec.yaml` dependencies:
```yaml
  flutter_rust_bridge: ^2.9.0
  rust_lib_ma_proxy_engine:
    path: rust_builder
```

Add to dev_dependencies:
```yaml
  build_runner: ^2.4.0
  flutter_rust_bridge_codegen: ^2.9.0
```

**Step 8: Run FRB codegen to verify scaffold compiles**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter_rust_bridge_codegen generate
```

Expected: Codegen runs successfully, generates Dart bindings in `lib/src/rust/`

**Step 9: Verify Rust compiles**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo check
```

Expected: Compiles with warnings about unused/todo but no errors.

**Step 10: Commit**

```bash
git add rust/ pubspec.yaml
git commit -m "feat: scaffold Rust proxy engine crate with FRB integration"
```

---

## Task 2: Implement MediaSource Trait and HttpSource

**Files:**
- Create: `rust/src/source/traits.rs`
- Create: `rust/src/source/http_source.rs`

**Step 1: Write the MediaSource trait**

Replace `rust/src/source/traits.rs`:
```rust
use anyhow::Result;
use async_trait::async_trait;
use bytes::Bytes;

/// Metadata returned by probing a media source.
pub struct SourceInfo {
    pub content_length: u64,
    pub content_type: String,
    pub supports_range: bool,
}

/// Abstract data source for streaming media.
/// Cloud storage and future BT sources each implement this trait.
#[async_trait]
pub trait MediaSource: Send + Sync {
    /// Probe the source: determine total size, content type, range support.
    async fn probe(&self) -> Result<SourceInfo>;

    /// Fetch a byte range [start, end] inclusive. Returns the raw bytes.
    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes>;

    /// Refresh authentication credentials (cloud storage scenario).
    /// Default: no-op. Override for sources that need auth refresh.
    async fn refresh_auth(&self) -> Result<()> {
        Ok(())
    }
}
```

**Step 2: Implement HttpSource**

Replace `rust/src/source/http_source.rs`:
```rust
use std::collections::HashMap;
use std::sync::Arc;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use bytes::Bytes;
use parking_lot::RwLock;
use reqwest::Client;

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

    pub fn update_auth(&self, new_url: String, new_headers: HashMap<String, String>) {
        *self.url.write() = new_url;
        *self.headers.write() = new_headers;
    }

    fn build_request(&self, range_header: Option<&str>) -> reqwest::RequestBuilder {
        let url = self.url.read().clone();
        let headers = self.headers.read().clone();
        let mut req = self.client.get(&url);
        for (k, v) in &headers {
            req = req.header(k, v);
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
        let status = resp.status().as_u16();

        if status == 206 {
            // Parse Content-Range: bytes 0-0/TOTAL
            let content_range = resp
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            let total = parse_content_range_total(content_range);
            let content_type = resp
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("video/mp4")
                .to_string();
            Ok(SourceInfo {
                content_length: total.unwrap_or(0),
                content_type,
                supports_range: true,
            })
        } else if status == 200 {
            let content_length = resp.content_length().unwrap_or(0);
            let content_type = resp
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("video/mp4")
                .to_string();
            Ok(SourceInfo {
                content_length,
                content_type,
                supports_range: false,
            })
        } else {
            Err(anyhow!("probe failed with status {}", status))
        }
    }

    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes> {
        let range = format!("bytes={}-{}", start, end);
        let resp = self.build_request(Some(&range)).send().await?;
        let status = resp.status().as_u16();

        if status == 206 || status == 200 {
            Ok(resp.bytes().await?)
        } else if status == 401 || status == 403 || status == 412 {
            Err(anyhow!("auth_rejected:{}", status))
        } else {
            Err(anyhow!("fetch_range failed with status {}", status))
        }
    }
}

fn parse_content_range_total(header: &str) -> Option<u64> {
    // "bytes 0-0/12345678"
    let slash_pos = header.rfind('/')?;
    let total_str = &header[slash_pos + 1..];
    total_str.trim().parse::<u64>().ok()
}
```

**Step 3: Write tests for HttpSource**

Create `rust/tests/http_source_test.rs`:
```rust
use std::collections::HashMap;
use axum::{Router, routing::get, extract::Query, http::{StatusCode, HeaderMap, header}};
use tokio::net::TcpListener;

// Integration test: start a fake upstream server, test HttpSource probe + fetch_range
#[tokio::test]
async fn test_http_source_probe_and_fetch() {
    // Start fake server that supports Range requests
    let content = vec![0u8; 1024 * 1024]; // 1MB test content
    let content_clone = content.clone();

    let app = Router::new().route("/video.mp4", get(move |headers: HeaderMap| {
        let content = content_clone.clone();
        async move {
            let range = headers.get("range").and_then(|v| v.to_str().ok()).unwrap_or("");
            if range.starts_with("bytes=") {
                let range_str = &range[6..];
                let parts: Vec<&str> = range_str.split('-').collect();
                let start: usize = parts[0].parse().unwrap_or(0);
                let end: usize = parts.get(1)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(content.len() - 1);
                let end = end.min(content.len() - 1);
                let slice = &content[start..=end];
                (
                    StatusCode::PARTIAL_CONTENT,
                    [
                        (header::CONTENT_RANGE, format!("bytes {}-{}/{}", start, end, content.len())),
                        (header::CONTENT_TYPE, "video/mp4".to_string()),
                    ],
                    slice.to_vec(),
                )
            } else {
                (
                    StatusCode::OK,
                    [
                        (header::CONTENT_RANGE, String::new()),
                        (header::CONTENT_TYPE, "video/mp4".to_string()),
                    ],
                    content.to_vec(),
                )
            }
        }
    }));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let source = ma_proxy_engine::source::http_source::HttpSource::new(
        format!("http://{}/video.mp4", addr),
        HashMap::new(),
    );

    // Test probe
    let info = source.probe().await.unwrap();
    assert_eq!(info.content_length, 1024 * 1024);
    assert!(info.supports_range);
    assert_eq!(info.content_type, "video/mp4");

    // Test fetch_range
    let data = source.fetch_range(0, 99).await.unwrap();
    assert_eq!(data.len(), 100);
}
```

**Step 4: Run tests**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo test test_http_source_probe_and_fetch -- --nocapture
```

Expected: PASS

**Step 5: Commit**

```bash
git add rust/src/source/ rust/tests/
git commit -m "feat: implement MediaSource trait and HttpSource"
```

---

## Task 3: Implement Disk Cache (mmap + BitVec)

**Files:**
- Modify: `rust/src/engine/cache.rs`

**Step 1: Write the DiskCache implementation**

Replace `rust/src/engine/cache.rs`:
```rust
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{anyhow, Result};
use bitvec::prelude::*;
use memmap2::MmapMut;
use parking_lot::RwLock;

pub struct DiskCache {
    mmap: RwLock<MmapMut>,
    bitmap: RwLock<BitVec>,
    chunk_size: u64,
    content_length: u64,
    total_chunks: usize,
    path: PathBuf,
    cached_bytes: AtomicU64,
}

impl DiskCache {
    /// Create a new disk cache backed by a temporary file.
    pub fn new(cache_dir: &Path, session_id: &str, content_length: u64, chunk_size: u64) -> Result<Self> {
        fs::create_dir_all(cache_dir)?;
        let path = cache_dir.join(format!("proxy_cache_{}.tmp", session_id));

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;

        file.set_len(content_length)?;

        let mmap = unsafe { MmapMut::map_mut(&file)? };
        let total_chunks = ((content_length + chunk_size - 1) / chunk_size) as usize;
        let bitmap = bitvec![0; total_chunks];

        Ok(Self {
            mmap: RwLock::new(mmap),
            bitmap: RwLock::new(bitmap),
            chunk_size,
            content_length,
            total_chunks,
            path,
            cached_bytes: AtomicU64::new(0),
        })
    }

    /// Write chunk data at the given chunk index.
    pub fn put_chunk(&self, chunk_index: usize, data: &[u8]) -> Result<()> {
        if chunk_index >= self.total_chunks {
            return Err(anyhow!("chunk index {} out of range (total {})", chunk_index, self.total_chunks));
        }

        let offset = chunk_index as u64 * self.chunk_size;
        let expected_len = self.chunk_len(chunk_index);
        if data.len() != expected_len {
            return Err(anyhow!(
                "chunk {} data len {} != expected {}",
                chunk_index, data.len(), expected_len
            ));
        }

        let mut mmap = self.mmap.write();
        let start = offset as usize;
        let end = start + data.len();
        mmap[start..end].copy_from_slice(data);

        let mut bitmap = self.bitmap.write();
        if !bitmap[chunk_index] {
            bitmap.set(chunk_index, true);
            self.cached_bytes.fetch_add(data.len() as u64, Ordering::Relaxed);
        }

        Ok(())
    }

    /// Read chunk data from the cache. Returns None if chunk is not cached.
    pub fn read_chunk(&self, chunk_index: usize) -> Option<Vec<u8>> {
        if chunk_index >= self.total_chunks {
            return None;
        }

        let bitmap = self.bitmap.read();
        if !bitmap[chunk_index] {
            return None;
        }

        let offset = (chunk_index as u64 * self.chunk_size) as usize;
        let len = self.chunk_len(chunk_index);
        let mmap = self.mmap.read();
        Some(mmap[offset..offset + len].to_vec())
    }

    /// Read a specific byte range from the cache. Only reads from cached chunks.
    /// Returns None if any required chunk is not cached.
    pub fn read_range(&self, start: u64, end: u64) -> Option<Vec<u8>> {
        let first_chunk = (start / self.chunk_size) as usize;
        let last_chunk = (end / self.chunk_size) as usize;

        let bitmap = self.bitmap.read();
        for i in first_chunk..=last_chunk {
            if i >= self.total_chunks || !bitmap[i] {
                return None;
            }
        }
        drop(bitmap);

        let mmap = self.mmap.read();
        let start_idx = start as usize;
        let end_idx = (end as usize).min(self.content_length as usize - 1);
        Some(mmap[start_idx..=end_idx].to_vec())
    }

    /// Check if a chunk is cached.
    pub fn has_chunk(&self, chunk_index: usize) -> bool {
        if chunk_index >= self.total_chunks {
            return false;
        }
        self.bitmap.read()[chunk_index]
    }

    /// Calculate contiguous buffered bytes ahead of the given playback offset.
    pub fn buffered_bytes_ahead(&self, playback_offset: u64) -> u64 {
        if self.content_length == 0 {
            return 0;
        }
        let start_chunk = (playback_offset / self.chunk_size) as usize;
        let bitmap = self.bitmap.read();
        let mut total: u64 = 0;
        let mut idx = start_chunk;

        while idx < self.total_chunks && bitmap[idx] {
            let chunk_start = idx as u64 * self.chunk_size;
            let chunk_end = (chunk_start + self.chunk_len(idx) as u64 - 1).min(self.content_length - 1);

            if idx == start_chunk {
                // Partial first chunk
                total += chunk_end - playback_offset.max(chunk_start) + 1;
            } else {
                total += chunk_end - chunk_start + 1;
            }
            idx += 1;
        }

        total
    }

    /// The byte length of a given chunk (last chunk may be shorter).
    pub fn chunk_len(&self, chunk_index: usize) -> usize {
        let start = chunk_index as u64 * self.chunk_size;
        let end = (start + self.chunk_size).min(self.content_length);
        (end - start) as usize
    }

    pub fn total_chunks(&self) -> usize {
        self.total_chunks
    }

    pub fn cached_bytes(&self) -> u64 {
        self.cached_bytes.load(Ordering::Relaxed)
    }

    pub fn content_length(&self) -> u64 {
        self.content_length
    }

    pub fn chunk_size(&self) -> u64 {
        self.chunk_size
    }
}

impl Drop for DiskCache {
    fn drop(&mut self) {
        // Clean up temporary cache file
        let _ = fs::remove_file(&self.path);
    }
}
```

**Step 2: Write tests**

Create `rust/tests/cache_test.rs`:
```rust
use std::path::Path;
use tempfile::TempDir;

#[test]
fn test_disk_cache_put_and_read() {
    let tmp = TempDir::new().unwrap();
    let cache = ma_proxy_engine::engine::cache::DiskCache::new(
        tmp.path(), "test_session", 10 * 1024 * 1024, 2 * 1024 * 1024,
    ).unwrap();

    assert_eq!(cache.total_chunks(), 5);
    assert!(!cache.has_chunk(0));

    // Write chunk 0
    let data = vec![42u8; 2 * 1024 * 1024];
    cache.put_chunk(0, &data).unwrap();
    assert!(cache.has_chunk(0));

    // Read it back
    let read = cache.read_chunk(0).unwrap();
    assert_eq!(read.len(), 2 * 1024 * 1024);
    assert!(read.iter().all(|&b| b == 42));
}

#[test]
fn test_disk_cache_buffered_bytes_ahead() {
    let tmp = TempDir::new().unwrap();
    let cache = ma_proxy_engine::engine::cache::DiskCache::new(
        tmp.path(), "test_buf", 10 * 1024 * 1024, 2 * 1024 * 1024,
    ).unwrap();

    // No chunks cached
    assert_eq!(cache.buffered_bytes_ahead(0), 0);

    // Cache chunks 0, 1, 2
    for i in 0..3 {
        let data = vec![0u8; 2 * 1024 * 1024];
        cache.put_chunk(i, &data).unwrap();
    }

    // From offset 0: should be 6MB
    assert_eq!(cache.buffered_bytes_ahead(0), 6 * 1024 * 1024);

    // From offset 1MB: should be 5MB
    assert_eq!(cache.buffered_bytes_ahead(1024 * 1024), 5 * 1024 * 1024);
}

#[test]
fn test_disk_cache_last_chunk_shorter() {
    let tmp = TempDir::new().unwrap();
    // 5MB file with 2MB chunks = 3 chunks (2MB + 2MB + 1MB)
    let cache = ma_proxy_engine::engine::cache::DiskCache::new(
        tmp.path(), "test_last", 5 * 1024 * 1024, 2 * 1024 * 1024,
    ).unwrap();

    assert_eq!(cache.total_chunks(), 3);
    assert_eq!(cache.chunk_len(0), 2 * 1024 * 1024);
    assert_eq!(cache.chunk_len(1), 2 * 1024 * 1024);
    assert_eq!(cache.chunk_len(2), 1 * 1024 * 1024);

    // Write last chunk (1MB)
    let data = vec![99u8; 1 * 1024 * 1024];
    cache.put_chunk(2, &data).unwrap();
    assert!(cache.has_chunk(2));
}
```

Add `tempfile` to Cargo.toml dev-dependencies:
```toml
[dev-dependencies]
tempfile = "3"
tokio = { version = "1", features = ["full", "test-util"] }
```

**Step 3: Run tests**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo test cache_test -- --nocapture
```

Expected: All 3 tests PASS

**Step 4: Commit**

```bash
git add rust/src/engine/cache.rs rust/tests/cache_test.rs rust/Cargo.toml
git commit -m "feat: implement DiskCache with mmap and BitVec bitmap"
```

---

## Task 4: Implement Container Detection and Warmup Prefetch

**Files:**
- Modify: `rust/src/detect/container.rs`
- Modify: `rust/src/engine/warmup.rs`

**Step 1: Write container detection**

Replace `rust/src/detect/container.rs`:
```rust
use anyhow::Result;
use crate::source::traits::MediaSource;

#[derive(Debug, PartialEq)]
pub enum ContainerFormat {
    Mp4,
    Matroska,  // MKV/WebM
    TransportStream,
    Iso9660,
    Udf,
    Unknown,
}

/// Detect container format from file header bytes.
pub fn detect_container(header: &[u8]) -> ContainerFormat {
    if header.len() < 12 {
        return ContainerFormat::Unknown;
    }

    // MP4/MOV: ftyp box at offset 4
    if header.len() >= 8 && &header[4..8] == b"ftyp" {
        return ContainerFormat::Mp4;
    }

    // MKV/WebM: EBML magic 0x1A45DFA3
    if header.len() >= 4 && header[0..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        return ContainerFormat::Matroska;
    }

    // MPEG-TS: sync byte 0x47 at start, and repeated at 188-byte intervals
    if header[0] == 0x47 && header.len() >= 376 && header[188] == 0x47 {
        return ContainerFormat::TransportStream;
    }

    ContainerFormat::Unknown
}

/// Detect ISO/UDF by checking bytes at offset 32768.
/// Requires fetching from source since headers at offset 0 won't contain this.
pub async fn detect_iso(source: &dyn MediaSource) -> Result<ContainerFormat> {
    // ISO 9660 / UDF: magic at offset 32768
    let header = source.fetch_range(32768, 32768 + 5).await?;
    if header.len() >= 5 {
        if &header[0..5] == b"CD001" {
            return Ok(ContainerFormat::Iso9660);
        }
        if &header[0..5] == b"BEA01" || &header[0..5] == b"NSR02" || &header[0..5] == b"NSR03" {
            return Ok(ContainerFormat::Udf);
        }
    }
    Ok(ContainerFormat::Unknown)
}

/// For MP4 files, locate the moov box by scanning top-level atoms.
/// Returns (offset, size) of moov box if found.
pub fn find_moov_box(header: &[u8]) -> Option<(u64, u64)> {
    let mut offset: u64 = 0;
    let len = header.len() as u64;

    while offset + 8 <= len {
        let start = offset as usize;
        let size = u32::from_be_bytes([
            header[start],
            header[start + 1],
            header[start + 2],
            header[start + 3],
        ]) as u64;
        let box_type = &header[start + 4..start + 8];

        let actual_size = if size == 1 && offset + 16 <= len {
            // 64-bit extended size
            u64::from_be_bytes([
                header[start + 8],
                header[start + 9],
                header[start + 10],
                header[start + 11],
                header[start + 12],
                header[start + 13],
                header[start + 14],
                header[start + 15],
            ])
        } else if size == 0 {
            len - offset // extends to end of file
        } else {
            size
        };

        if box_type == b"moov" {
            return Some((offset, actual_size));
        }

        if actual_size == 0 {
            break;
        }
        offset += actual_size;
    }

    None
}
```

**Step 2: Write warmup prefetch**

Replace `rust/src/engine/warmup.rs`:
```rust
use anyhow::Result;
use crate::detect::container::{detect_container, find_moov_box, ContainerFormat};
use crate::source::traits::MediaSource;

/// Determines which byte ranges need to be prefetched for fast playback start.
/// Returns a list of (start, end) inclusive ranges to download.
pub async fn compute_warmup_ranges(
    source: &dyn MediaSource,
    content_length: u64,
    chunk_size: u64,
) -> Result<Vec<(u64, u64)>> {
    if content_length == 0 {
        return Ok(vec![]);
    }

    let mut ranges = Vec::new();

    // Always fetch first chunk for format detection
    let header_end = chunk_size.min(content_length) - 1;
    let header = source.fetch_range(0, header_end.min(32767)).await?;
    let format = detect_container(&header);

    match format {
        ContainerFormat::Mp4 => {
            // Fetch enough header to scan for moov box
            let scan_size = (256 * 1024).min(content_length);
            let scan_data = if header.len() as u64 >= scan_size {
                header.to_vec()
            } else {
                source.fetch_range(0, scan_size - 1).await?.to_vec()
            };

            if let Some((moov_offset, moov_size)) = find_moov_box(&scan_data) {
                // moov found in header area
                let moov_end = (moov_offset + moov_size - 1).min(content_length - 1);
                ranges.push((0, moov_end));
            } else {
                // moov likely at end of file — fetch head + tail
                ranges.push((0, header_end));
                if content_length > chunk_size {
                    let tail_start = content_length.saturating_sub(chunk_size);
                    ranges.push((tail_start, content_length - 1));
                }
            }
        }
        ContainerFormat::Matroska | ContainerFormat::TransportStream => {
            // Header-only: EBML/SeekHead or PAT/PMT at beginning
            ranges.push((0, header_end));
        }
        _ => {
            // Generic: head + tail
            ranges.push((0, header_end));
            if content_length > chunk_size {
                let tail_start = content_length.saturating_sub(chunk_size);
                ranges.push((tail_start, content_length - 1));
            }
        }
    }

    Ok(ranges)
}
```

**Step 3: Write tests**

Create `rust/tests/detect_test.rs`:
```rust
use ma_proxy_engine::detect::container::*;

#[test]
fn test_detect_mp4() {
    let mut header = vec![0u8; 12];
    // ftyp at offset 4
    header[4..8].copy_from_slice(b"ftyp");
    assert_eq!(detect_container(&header), ContainerFormat::Mp4);
}

#[test]
fn test_detect_mkv() {
    let mut header = vec![0u8; 12];
    header[0..4].copy_from_slice(&[0x1A, 0x45, 0xDF, 0xA3]);
    assert_eq!(detect_container(&header), ContainerFormat::Matroska);
}

#[test]
fn test_detect_ts() {
    let mut header = vec![0u8; 376];
    header[0] = 0x47;
    header[188] = 0x47;
    assert_eq!(detect_container(&header), ContainerFormat::TransportStream);
}

#[test]
fn test_find_moov_at_start() {
    // ftyp(8 bytes) + moov(100 bytes)
    let mut data = vec![0u8; 200];
    // ftyp box: size=8, type=ftyp
    data[0..4].copy_from_slice(&8u32.to_be_bytes());
    data[4..8].copy_from_slice(b"ftyp");
    // moov box: size=100, type=moov
    data[8..12].copy_from_slice(&100u32.to_be_bytes());
    data[12..16].copy_from_slice(b"moov");

    let result = find_moov_box(&data);
    assert_eq!(result, Some((8, 100)));
}

#[test]
fn test_find_moov_not_present() {
    let mut data = vec![0u8; 200];
    data[0..4].copy_from_slice(&8u32.to_be_bytes());
    data[4..8].copy_from_slice(b"ftyp");
    data[8..12].copy_from_slice(&192u32.to_be_bytes());
    data[12..16].copy_from_slice(b"mdat");

    let result = find_moov_box(&data);
    assert_eq!(result, None);
}
```

**Step 4: Run tests**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo test detect_test -- --nocapture
```

Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add rust/src/detect/ rust/src/engine/warmup.rs rust/tests/detect_test.rs
git commit -m "feat: implement container detection and warmup prefetch"
```

---

## Task 5: Implement Download Engine (Parallel Downloader + Stats)

**Files:**
- Modify: `rust/src/engine/downloader.rs`
- Modify: `rust/src/engine/stats.rs`
- Modify: `rust/src/engine/session.rs`

**Step 1: Write the stats collector**

Replace `rust/src/engine/stats.rs`:
```rust
use std::sync::atomic::{AtomicU64, AtomicU32, Ordering};
use std::time::Instant;
use parking_lot::Mutex;

pub struct StatsCollector {
    download_bytes_total: AtomicU64,
    serve_bytes_total: AtomicU64,
    active_workers: AtomicU32,
    requested_bytes: AtomicU64,
    cache_hit_bytes: AtomicU64,
    last_sample: Mutex<StatsSample>,
}

struct StatsSample {
    at: Instant,
    download_bytes: u64,
    serve_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct StatsSnapshot {
    pub download_bps: u64,
    pub serve_bps: u64,
    pub buffered_bytes_ahead: u64,
    pub active_workers: u32,
    pub cache_hit_rate: f64,
}

impl StatsCollector {
    pub fn new() -> Self {
        Self {
            download_bytes_total: AtomicU64::new(0),
            serve_bytes_total: AtomicU64::new(0),
            active_workers: AtomicU32::new(0),
            requested_bytes: AtomicU64::new(0),
            cache_hit_bytes: AtomicU64::new(0),
            last_sample: Mutex::new(StatsSample {
                at: Instant::now(),
                download_bytes: 0,
                serve_bytes: 0,
            }),
        }
    }

    pub fn record_downloaded(&self, bytes: u64) {
        self.download_bytes_total.fetch_add(bytes, Ordering::Relaxed);
    }

    pub fn record_served(&self, bytes: u64) {
        self.serve_bytes_total.fetch_add(bytes, Ordering::Relaxed);
    }

    pub fn record_request(&self, total_bytes: u64, cached_bytes: u64) {
        self.requested_bytes.fetch_add(total_bytes, Ordering::Relaxed);
        self.cache_hit_bytes.fetch_add(cached_bytes, Ordering::Relaxed);
    }

    pub fn increment_workers(&self) {
        self.active_workers.fetch_add(1, Ordering::Relaxed);
    }

    pub fn decrement_workers(&self) {
        self.active_workers.fetch_sub(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self, buffered_bytes_ahead: u64) -> StatsSnapshot {
        let now = Instant::now();
        let mut sample = self.last_sample.lock();
        let elapsed_ms = now.duration_since(sample.at).as_millis().max(1) as u64;

        let dl_total = self.download_bytes_total.load(Ordering::Relaxed);
        let sv_total = self.serve_bytes_total.load(Ordering::Relaxed);
        let dl_delta = dl_total.saturating_sub(sample.download_bytes);
        let sv_delta = sv_total.saturating_sub(sample.serve_bytes);

        let download_bps = dl_delta * 8000 / elapsed_ms;
        let serve_bps = sv_delta * 8000 / elapsed_ms;

        let requested = self.requested_bytes.load(Ordering::Relaxed);
        let cache_hit = self.cache_hit_bytes.load(Ordering::Relaxed);
        let cache_hit_rate = if requested > 0 {
            cache_hit as f64 / requested as f64
        } else {
            0.0
        };

        sample.at = now;
        sample.download_bytes = dl_total;
        sample.serve_bytes = sv_total;

        StatsSnapshot {
            download_bps,
            serve_bps,
            buffered_bytes_ahead,
            active_workers: self.active_workers.load(Ordering::Relaxed),
            cache_hit_rate,
        }
    }

    pub fn total_downloaded(&self) -> u64 {
        self.download_bytes_total.load(Ordering::Relaxed)
    }
}
```

**Step 2: Write the parallel downloader**

Replace `rust/src/engine/downloader.rs`:
```rust
use std::sync::Arc;
use anyhow::{anyhow, Result};
use tokio::sync::{Notify, Semaphore};
use tokio_util::sync::CancellationToken;
use parking_lot::Mutex;

use crate::engine::cache::DiskCache;
use crate::engine::stats::StatsCollector;
use crate::source::traits::MediaSource;

pub struct Downloader {
    source: Arc<dyn MediaSource>,
    cache: Arc<DiskCache>,
    semaphore: Arc<Semaphore>,
    stats: Arc<StatsCollector>,
    /// Per-chunk notify: waiters are woken when a chunk completes.
    chunk_notifiers: Mutex<Vec<Option<Arc<Notify>>>>,
    /// Per-chunk cancellation tokens for aborting out-of-window downloads.
    cancel_tokens: Mutex<Vec<Option<CancellationToken>>>,
    max_retries: u32,
}

impl Downloader {
    pub fn new(
        source: Arc<dyn MediaSource>,
        cache: Arc<DiskCache>,
        max_concurrency: u32,
        stats: Arc<StatsCollector>,
    ) -> Self {
        let total_chunks = cache.total_chunks();
        Self {
            source,
            cache,
            semaphore: Arc::new(Semaphore::new(max_concurrency as usize)),
            stats,
            chunk_notifiers: Mutex::new(vec![None; total_chunks]),
            cancel_tokens: Mutex::new(vec![None; total_chunks]),
            max_retries: 3,
        }
    }

    /// Start downloading a chunk in the background. Idempotent.
    pub fn start_prefetch(&self, chunk_index: usize) {
        if self.cache.has_chunk(chunk_index) {
            return;
        }

        // Check if already in-flight
        {
            let tokens = self.cancel_tokens.lock();
            if tokens.get(chunk_index).and_then(|t| t.as_ref()).is_some() {
                return; // Already in-flight
            }
        }

        let cancel = CancellationToken::new();
        let notify = Arc::new(Notify::new());

        {
            let mut tokens = self.cancel_tokens.lock();
            if chunk_index < tokens.len() {
                tokens[chunk_index] = Some(cancel.clone());
            }
        }
        {
            let mut notifiers = self.chunk_notifiers.lock();
            if chunk_index < notifiers.len() {
                notifiers[chunk_index] = Some(notify.clone());
            }
        }

        let source = self.source.clone();
        let cache = self.cache.clone();
        let semaphore = self.semaphore.clone();
        let stats = self.stats.clone();
        let cancel_tokens = &self.cancel_tokens as *const Mutex<Vec<Option<CancellationToken>>>;
        let max_retries = self.max_retries;
        let chunk_size = cache.chunk_size();

        // Safety: Downloader lives as long as sessions; cancel tokens are cleaned up.
        let cancel_tokens_ptr = cancel_tokens as usize;

        tokio::spawn(async move {
            let _permit = semaphore.acquire().await.unwrap();
            stats.increment_workers();

            let result = async {
                // Checkpoint 1: already cancelled?
                if cancel.is_cancelled() {
                    return Ok(false);
                }

                if cache.has_chunk(chunk_index) {
                    return Ok(true);
                }

                let start = chunk_index as u64 * chunk_size;
                let end = (start + cache.chunk_len(chunk_index) as u64 - 1)
                    .min(cache.content_length() - 1);

                for retry in 0..max_retries {
                    if cancel.is_cancelled() {
                        return Ok(false);
                    }

                    match source.fetch_range(start, end).await {
                        Ok(data) => {
                            stats.record_downloaded(data.len() as u64);

                            // Checkpoint 2: cancelled during download?
                            if cancel.is_cancelled() {
                                return Ok(false);
                            }

                            cache.put_chunk(chunk_index, &data)?;
                            return Ok(true);
                        }
                        Err(e) => {
                            let err_str = e.to_string();
                            if err_str.starts_with("auth_rejected") {
                                // Try auth refresh
                                let _ = source.refresh_auth().await;
                            }
                            if retry + 1 < max_retries {
                                tokio::time::sleep(
                                    std::time::Duration::from_millis(200 * (retry as u64 + 1))
                                ).await;
                            }
                        }
                    }
                }
                Err(anyhow!("chunk {} download failed after {} retries", chunk_index, max_retries))
            }.await;

            stats.decrement_workers();
            notify.notify_waiters();

            // Clean up cancel token
            // Safety: Downloader outlives spawned tasks
            unsafe {
                let tokens = &*(cancel_tokens_ptr as *const Mutex<Vec<Option<CancellationToken>>>);
                let mut guard = tokens.lock();
                if chunk_index < guard.len() {
                    guard[chunk_index] = None;
                }
            }

            result
        });
    }

    /// Wait for a specific chunk to be ready. Returns true if available.
    pub async fn wait_for_chunk(&self, chunk_index: usize) -> bool {
        if self.cache.has_chunk(chunk_index) {
            return true;
        }

        self.start_prefetch(chunk_index);

        let notify = {
            let notifiers = self.chunk_notifiers.lock();
            notifiers.get(chunk_index).and_then(|n| n.clone())
        };

        if let Some(notify) = notify {
            notify.notified().await;
        }

        self.cache.has_chunk(chunk_index)
    }

    /// Abort all in-flight downloads for chunks outside the given window.
    pub fn abort_outside_window(&self, window_start_chunk: usize, window_end_chunk: usize) {
        let tokens = self.cancel_tokens.lock();
        for (i, token) in tokens.iter().enumerate() {
            if let Some(t) = token {
                if i < window_start_chunk || i > window_end_chunk {
                    t.cancel();
                }
            }
        }
    }

    /// Prefetch a range of chunks without waiting.
    pub fn prefetch_range(&self, start_chunk: usize, end_chunk: usize) {
        let end = end_chunk.min(self.cache.total_chunks().saturating_sub(1));
        for i in start_chunk..=end {
            self.start_prefetch(i);
        }
    }
}
```

**Step 3: Write the ProxySession**

Replace `rust/src/engine/session.rs`:
```rust
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use anyhow::Result;
use parking_lot::Mutex;

use crate::config;
use crate::detect::container::{detect_container, ContainerFormat};
use crate::engine::cache::DiskCache;
use crate::engine::downloader::Downloader;
use crate::engine::stats::{StatsCollector, StatsSnapshot};
use crate::engine::warmup;
use crate::source::http_source::HttpSource;
use crate::source::traits::{MediaSource, SourceInfo};

pub struct ProxySession {
    pub session_id: String,
    source: Arc<HttpSource>,
    cache: Arc<DiskCache>,
    downloader: Arc<Downloader>,
    stats: Arc<StatsCollector>,
    info: SourceInfo,
    playback_offset: AtomicU64,
    playback_bps: Mutex<f64>,
    seek_state: Mutex<SeekState>,
    chunk_size: u64,
}

struct SeekState {
    detection_enabled: bool,
    first_request_at: Option<std::time::Instant>,
    request_count: u32,
    last_request_start: Option<u64>,
    last_request_end: Option<u64>,
    stable_sequential_hits: u32,
}

impl SeekState {
    fn new() -> Self {
        Self {
            detection_enabled: false,
            first_request_at: None,
            request_count: 0,
            last_request_start: None,
            last_request_end: None,
            stable_sequential_hits: 0,
        }
    }
}

impl ProxySession {
    pub async fn new(
        session_id: String,
        url: String,
        headers: HashMap<String, String>,
        cache_dir: &Path,
        chunk_size: u64,
        max_concurrency: u32,
    ) -> Result<Self> {
        let source = Arc::new(HttpSource::new(url, headers));
        let info = source.probe().await?;

        if info.content_length == 0 || !info.supports_range {
            return Err(anyhow::anyhow!(
                "source does not support range requests or has zero length"
            ));
        }

        let cache = Arc::new(DiskCache::new(
            cache_dir,
            &session_id,
            info.content_length,
            chunk_size,
        )?);

        let stats = Arc::new(StatsCollector::new());
        let downloader = Arc::new(Downloader::new(
            source.clone(),
            cache.clone(),
            max_concurrency,
            stats.clone(),
        ));

        let session = Self {
            session_id,
            source,
            cache,
            downloader,
            stats,
            info,
            playback_offset: AtomicU64::new(0),
            playback_bps: Mutex::new(1.5 * 1024.0 * 1024.0), // 12 Mbps default
            seek_state: Mutex::new(SeekState::new()),
            chunk_size,
        };

        // Start warmup prefetch in background
        session.start_warmup().await;

        Ok(session)
    }

    async fn start_warmup(&self) {
        match warmup::compute_warmup_ranges(
            self.source.as_ref(),
            self.info.content_length,
            self.chunk_size,
        ).await {
            Ok(ranges) => {
                for (start, end) in ranges {
                    let start_chunk = (start / self.chunk_size) as usize;
                    let end_chunk = (end / self.chunk_size) as usize;
                    self.downloader.prefetch_range(start_chunk, end_chunk);
                }
            }
            Err(e) => {
                tracing::warn!(session_id = %self.session_id, "warmup failed: {}", e);
            }
        }
    }

    /// Called by axum handler: ensure chunks for the requested range are available
    /// and prefetch ahead.
    pub async fn serve_range(&self, start: u64, end: u64) -> Result<Vec<u8>> {
        let first_chunk = (start / self.chunk_size) as usize;
        let last_chunk = (end / self.chunk_size) as usize;

        // Update playback tracking
        self.playback_offset.store(start, Ordering::Relaxed);
        self.update_seek_state(start, end);
        self.schedule_prefetch(start);

        // Wait for all required chunks
        for i in first_chunk..=last_chunk {
            let ready = self.downloader.wait_for_chunk(i).await;
            if !ready {
                return Err(anyhow::anyhow!("chunk {} not available", i));
            }
        }

        // Read from cache
        self.cache.read_range(start, end).ok_or_else(|| {
            anyhow::anyhow!("failed to read range {}-{} from cache", start, end)
        })
    }

    fn schedule_prefetch(&self, start: u64) {
        let content_length = self.info.content_length;
        let bps = *self.playback_bps.lock();

        // Priority window: ~2 minutes ahead
        let priority_bytes = (bps * config::PRIORITY_BUFFER_SECONDS as f64) as u64;
        let priority_end = (start + priority_bytes).min(content_length - 1);

        let start_chunk = (start / self.chunk_size) as usize;
        let priority_end_chunk = (priority_end / self.chunk_size) as usize;

        self.downloader.prefetch_range(start_chunk, priority_end_chunk);
    }

    fn update_seek_state(&self, request_start: u64, request_end: u64) {
        let mut state = self.seek_state.lock();
        let now = std::time::Instant::now();
        state.first_request_at.get_or_insert(now);
        state.request_count += 1;

        if let Some(prev_start) = state.last_request_start {
            let jump = if request_start > prev_start {
                request_start - prev_start
            } else {
                prev_start - request_start
            };

            let overlaps_prev = state.last_request_end.map_or(false, |prev_end| {
                request_start >= prev_start && request_start <= prev_end
            });
            let sequential = state.last_request_end.map_or(false, |prev_end| {
                request_start == prev_end + 1
            });

            if overlaps_prev || sequential || jump <= config::SEEK_THRESHOLD_BYTES {
                state.stable_sequential_hits += 1;
            } else {
                state.stable_sequential_hits = 0;
            }

            // Detect seek
            if state.detection_enabled && jump > config::SEEK_THRESHOLD_BYTES && !overlaps_prev && !sequential {
                // Seek detected — abort out-of-window chunks
                let window_start = (request_start / self.chunk_size) as usize;
                let bps = *self.playback_bps.lock();
                let window_bytes = (bps * config::PRIORITY_BUFFER_SECONDS as f64) as u64;
                let window_end = ((request_start + window_bytes).min(self.info.content_length - 1) / self.chunk_size) as usize;
                self.downloader.abort_outside_window(window_start, window_end);
            }
        }

        state.last_request_start = Some(request_start);
        state.last_request_end = Some(request_end);

        // Enable seek detection after warmup
        if !state.detection_enabled {
            if let Some(first_at) = state.first_request_at {
                let elapsed = now.duration_since(first_at).as_secs();
                if elapsed >= config::SEEK_WARMUP_SECONDS
                    && state.request_count > config::SEEK_WARMUP_REQUESTS
                    && state.stable_sequential_hits >= config::SEEK_STABLE_SEQUENTIAL_HITS
                {
                    state.detection_enabled = true;
                }
            }
        }
    }

    pub fn content_type(&self) -> &str {
        &self.info.content_type
    }

    pub fn content_length(&self) -> u64 {
        self.info.content_length
    }

    pub fn snapshot(&self) -> StatsSnapshot {
        let buffered = self.cache.buffered_bytes_ahead(
            self.playback_offset.load(Ordering::Relaxed),
        );
        self.stats.snapshot(buffered)
    }

    pub fn update_auth(&self, new_url: String, new_headers: HashMap<String, String>) {
        self.source.update_auth(new_url, new_headers);
    }
}
```

**Step 4: Update engine/mod.rs**

Replace `rust/src/engine/mod.rs`:
```rust
pub mod cache;
pub mod downloader;
pub mod session;
pub mod stats;
pub mod warmup;
```

**Step 5: Verify it compiles**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo check
```

Expected: Compiles (with warnings about unused api/todo)

**Step 6: Commit**

```bash
git add rust/src/engine/
git commit -m "feat: implement download engine with parallel downloader, stats, and session management"
```

---

## Task 6: Implement Axum HTTP Server

**Files:**
- Modify: `rust/src/server/handler.rs`
- Modify: `rust/src/server/mod.rs`

**Step 1: Write the HTTP server with Range support**

Replace `rust/src/server/handler.rs`:
```rust
use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use axum::{
    Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use parking_lot::RwLock;
use tokio::net::TcpListener;

use crate::engine::session::ProxySession;

pub type SessionMap = Arc<RwLock<HashMap<String, Arc<ProxySession>>>>;

pub struct ProxyServer {
    port: u16,
    sessions: SessionMap,
    shutdown_tx: Option<tokio::sync::oneshot::Sender<()>>,
}

impl ProxyServer {
    pub async fn start(sessions: SessionMap) -> Result<Self> {
        let app = Router::new()
            .route("/stream/{session_id}", get(stream_handler).head(head_handler))
            .with_state(sessions.clone());

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();

        let (tx, rx) = tokio::sync::oneshot::channel::<()>();

        tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async { let _ = rx.await; })
                .await
                .ok();
        });

        Ok(Self {
            port,
            sessions,
            shutdown_tx: Some(tx),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn url_for_session(&self, session_id: &str) -> String {
        format!("http://127.0.0.1:{}/stream/{}", self.port, session_id)
    }

    pub fn sessions(&self) -> &SessionMap {
        &self.sessions
    }

    pub fn shutdown(mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
    }
}

async fn stream_handler(
    Path(session_id): Path<String>,
    State(sessions): State<SessionMap>,
    headers: HeaderMap,
) -> Response {
    let session = {
        let map = sessions.read();
        map.get(&session_id).cloned()
    };

    let session = match session {
        Some(s) => s,
        None => return (StatusCode::NOT_FOUND, "session not found").into_response(),
    };

    let content_length = session.content_length();
    let content_type = session.content_type().to_string();

    // Parse Range header
    let range = headers.get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_header);

    let (start, end) = match range {
        Some((s, e)) => {
            let end = e.unwrap_or(
                (s + crate::config::MAX_OPEN_ENDED_RESPONSE_BYTES - 1).min(content_length - 1)
            );
            (s, end.min(content_length - 1))
        }
        None => (0, content_length - 1),
    };

    if start >= content_length {
        return (
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{}", content_length))],
        ).into_response();
    }

    // Serve the range
    match session.serve_range(start, end).await {
        Ok(data) => {
            let is_partial = !(start == 0 && end == content_length - 1);
            let status = if is_partial {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            };

            let mut response_headers = HeaderMap::new();
            response_headers.insert(header::CONTENT_TYPE, content_type.parse().unwrap());
            response_headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
            response_headers.insert(
                header::CONTENT_LENGTH,
                (end - start + 1).to_string().parse().unwrap(),
            );
            if is_partial {
                response_headers.insert(
                    header::CONTENT_RANGE,
                    format!("bytes {}-{}/{}", start, end, content_length)
                        .parse()
                        .unwrap(),
                );
            }

            (status, response_headers, data).into_response()
        }
        Err(e) => {
            tracing::error!("serve_range failed: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("proxy failed: {}", e)).into_response()
        }
    }
}

async fn head_handler(
    Path(session_id): Path<String>,
    State(sessions): State<SessionMap>,
    headers: HeaderMap,
) -> Response {
    let session = {
        let map = sessions.read();
        map.get(&session_id).cloned()
    };

    let session = match session {
        Some(s) => s,
        None => return (StatusCode::NOT_FOUND, "session not found").into_response(),
    };

    let content_length = session.content_length();
    let content_type = session.content_type().to_string();

    let range = headers.get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_header);

    let (start, end) = match range {
        Some((s, e)) => {
            let end = e.unwrap_or(content_length - 1);
            (s, end.min(content_length - 1))
        }
        None => (0, content_length - 1),
    };

    let is_partial = !(start == 0 && end == content_length - 1);
    let status = if is_partial {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };

    let mut response_headers = HeaderMap::new();
    response_headers.insert(header::CONTENT_TYPE, content_type.parse().unwrap());
    response_headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    response_headers.insert(
        header::CONTENT_LENGTH,
        (end - start + 1).to_string().parse().unwrap(),
    );
    if is_partial {
        response_headers.insert(
            header::CONTENT_RANGE,
            format!("bytes {}-{}/{}", start, end, content_length)
                .parse()
                .unwrap(),
        );
    }

    (status, response_headers).into_response()
}

fn parse_range_header(value: &str) -> Option<(u64, Option<u64>)> {
    let value = value.trim();
    if !value.starts_with("bytes=") {
        return None;
    }
    let range_str = &value[6..];
    let parts: Vec<&str> = range_str.splitn(2, '-').collect();
    if parts.len() != 2 {
        return None;
    }
    let start: u64 = parts[0].parse().ok()?;
    let end: Option<u64> = if parts[1].is_empty() {
        None
    } else {
        Some(parts[1].parse().ok()?)
    };
    Some((start, end))
}
```

Replace `rust/src/server/mod.rs`:
```rust
pub mod handler;
```

**Step 2: Write integration test**

Create `rust/tests/server_test.rs`:
```rust
use std::collections::HashMap;
use std::sync::Arc;

use axum::{Router, routing::get, http::{StatusCode, HeaderMap, header}};
use parking_lot::RwLock;
use reqwest::Client;
use tokio::net::TcpListener;

/// End-to-end test: fake upstream → ProxySession → axum server → reqwest client
#[tokio::test]
async fn test_proxy_server_range_request() {
    // Start fake upstream
    let content: Vec<u8> = (0..255u8).cycle().take(10 * 1024 * 1024).collect();
    let content_clone = content.clone();

    let upstream = Router::new().route("/video.mp4", get(move |headers: HeaderMap| {
        let content = content_clone.clone();
        async move {
            let range = headers.get("range").and_then(|v| v.to_str().ok()).unwrap_or("");
            if range.starts_with("bytes=") {
                let range_str = &range[6..];
                let parts: Vec<&str> = range_str.split('-').collect();
                let start: usize = parts[0].parse().unwrap_or(0);
                let end: usize = parts.get(1)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(content.len() - 1)
                    .min(content.len() - 1);
                let slice = &content[start..=end];
                (
                    StatusCode::PARTIAL_CONTENT,
                    [
                        (header::CONTENT_RANGE, format!("bytes {}-{}/{}", start, end, content.len())),
                        (header::CONTENT_TYPE, "video/mp4".to_string()),
                    ],
                    slice.to_vec(),
                )
            } else {
                (
                    StatusCode::OK,
                    [
                        (header::CONTENT_RANGE, String::new()),
                        (header::CONTENT_TYPE, "video/mp4".to_string()),
                    ],
                    content.to_vec(),
                )
            }
        }
    }));

    let upstream_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_addr = upstream_listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(upstream_listener, upstream).await.unwrap() });

    // Create session
    let tmp = tempfile::TempDir::new().unwrap();
    let session = ma_proxy_engine::engine::session::ProxySession::new(
        "test_session".to_string(),
        format!("http://{}/video.mp4", upstream_addr),
        HashMap::new(),
        tmp.path(),
        2 * 1024 * 1024, // 2MB chunks
        4,
    ).await.unwrap();

    // Start proxy server
    let sessions: ma_proxy_engine::server::handler::SessionMap =
        Arc::new(RwLock::new(HashMap::new()));
    sessions.write().insert("test_session".to_string(), Arc::new(session));

    let server = ma_proxy_engine::server::handler::ProxyServer::start(sessions).await.unwrap();
    let proxy_url = server.url_for_session("test_session");

    // Request a range through the proxy
    let client = Client::new();
    let resp = client
        .get(&proxy_url)
        .header("Range", "bytes=0-1023")
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 206);
    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len(), 1024);
    assert_eq!(&body[..], &content[..1024]);

    server.shutdown();
}
```

**Step 3: Run test**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo test test_proxy_server_range_request -- --nocapture
```

Expected: PASS

**Step 4: Commit**

```bash
git add rust/src/server/ rust/tests/server_test.rs
git commit -m "feat: implement axum HTTP server with Range request support"
```

---

## Task 7: Wire Up FRB API (Engine Singleton)

**Files:**
- Modify: `rust/src/api/proxy_api.rs`
- Modify: `rust/src/lib.rs`

**Step 1: Implement the engine singleton and wire up API**

Replace `rust/src/api/proxy_api.rs`:
```rust
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use parking_lot::RwLock;
use tokio::runtime::Runtime;

use crate::config::EngineConfig;
use crate::engine::session::ProxySession;
use crate::server::handler::{ProxyServer, SessionMap};

static ENGINE: parking_lot::Mutex<Option<Engine>> = parking_lot::Mutex::new(None);

struct Engine {
    runtime: Arc<Runtime>,
    server: Option<ProxyServer>,
    sessions: SessionMap,
    config: EngineConfig,
}

#[frb(dart_metadata=("freezed"))]
pub struct SessionInfo {
    pub session_id: String,
    pub playback_url: String,
    pub content_length: u64,
    pub content_type: String,
}

#[frb(dart_metadata=("freezed"))]
pub struct ProxyStats {
    pub download_bps: u64,
    pub serve_bps: u64,
    pub buffered_bytes_ahead: u64,
    pub active_workers: u32,
    pub cache_hit_rate: f64,
}

#[frb]
pub fn init_engine(config: EngineConfig) -> Result<()> {
    let mut guard = ENGINE.lock();
    if guard.is_some() {
        return Ok(()); // Already initialized
    }

    let runtime = Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?,
    );

    let sessions: SessionMap = Arc::new(RwLock::new(HashMap::new()));

    let server = runtime.block_on(async {
        ProxyServer::start(sessions.clone()).await
    })?;

    *guard = Some(Engine {
        runtime,
        server: Some(server),
        sessions,
        config,
    });

    Ok(())
}

#[frb]
pub fn create_session(
    url: String,
    headers: HashMap<String, String>,
    file_key: String,
) -> Result<SessionInfo> {
    let guard = ENGINE.lock();
    let engine = guard.as_ref().ok_or_else(|| anyhow!("engine not initialized"))?;

    let session_id = compute_session_id(&url, &file_key);

    // Return existing session if available
    {
        let sessions = engine.sessions.read();
        if let Some(existing) = sessions.get(&session_id) {
            let server = engine.server.as_ref().ok_or_else(|| anyhow!("server not running"))?;
            return Ok(SessionInfo {
                session_id: session_id.clone(),
                playback_url: server.url_for_session(&session_id),
                content_length: existing.content_length(),
                content_type: existing.content_type().to_string(),
            });
        }
    }

    // Close other sessions (single session at a time)
    {
        let mut sessions = engine.sessions.write();
        sessions.clear();
    }

    let cache_dir = PathBuf::from(&engine.config.cache_dir);
    let chunk_size = engine.config.chunk_size;
    let max_concurrency = engine.config.max_concurrency;

    let session = engine.runtime.block_on(async {
        ProxySession::new(
            session_id.clone(),
            url,
            headers,
            &cache_dir,
            chunk_size,
            max_concurrency,
        ).await
    })?;

    let content_length = session.content_length();
    let content_type = session.content_type().to_string();

    engine.sessions.write().insert(session_id.clone(), Arc::new(session));

    let server = engine.server.as_ref().ok_or_else(|| anyhow!("server not running"))?;
    Ok(SessionInfo {
        session_id: session_id.clone(),
        playback_url: server.url_for_session(&session_id),
        content_length,
        content_type,
    })
}

#[frb]
pub fn close_session(session_id: String) -> Result<()> {
    let guard = ENGINE.lock();
    let engine = guard.as_ref().ok_or_else(|| anyhow!("engine not initialized"))?;
    engine.sessions.write().remove(&session_id);
    Ok(())
}

#[frb]
pub fn get_stats(session_id: Option<String>) -> Result<ProxyStats> {
    let guard = ENGINE.lock();
    let engine = guard.as_ref().ok_or_else(|| anyhow!("engine not initialized"))?;
    let sessions = engine.sessions.read();

    if let Some(id) = session_id {
        let session = sessions.get(&id).ok_or_else(|| anyhow!("session not found"))?;
        let snap = session.snapshot();
        Ok(ProxyStats {
            download_bps: snap.download_bps,
            serve_bps: snap.serve_bps,
            buffered_bytes_ahead: snap.buffered_bytes_ahead,
            active_workers: snap.active_workers,
            cache_hit_rate: snap.cache_hit_rate,
        })
    } else {
        // Aggregate across all sessions
        let mut total = ProxyStats {
            download_bps: 0,
            serve_bps: 0,
            buffered_bytes_ahead: 0,
            active_workers: 0,
            cache_hit_rate: 0.0,
        };
        for session in sessions.values() {
            let snap = session.snapshot();
            total.download_bps += snap.download_bps;
            total.serve_bps += snap.serve_bps;
            total.buffered_bytes_ahead += snap.buffered_bytes_ahead;
            total.active_workers += snap.active_workers;
        }
        Ok(total)
    }
}

#[frb]
pub fn update_session_auth(
    session_id: String,
    new_url: String,
    new_headers: HashMap<String, String>,
) -> Result<()> {
    let guard = ENGINE.lock();
    let engine = guard.as_ref().ok_or_else(|| anyhow!("engine not initialized"))?;
    let sessions = engine.sessions.read();
    let session = sessions.get(&session_id).ok_or_else(|| anyhow!("session not found"))?;
    session.update_auth(new_url, new_headers);
    Ok(())
}

#[frb]
pub fn dispose() -> Result<()> {
    let mut guard = ENGINE.lock();
    if let Some(engine) = guard.take() {
        engine.sessions.write().clear();
        if let Some(server) = engine.server {
            server.shutdown();
        }
    }
    Ok(())
}

fn compute_session_id(url: &str, file_key: &str) -> String {
    let input = if !file_key.is_empty() {
        format!("file:{}", file_key)
    } else {
        format!("url:{}", url)
    };
    format!("{:x}", md5::compute(input.as_bytes()))
}
```

**Step 2: Verify compilation**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo check
```

Expected: Compiles

**Step 3: Commit**

```bash
git add rust/src/api/ rust/src/lib.rs
git commit -m "feat: wire up FRB API with engine singleton"
```

---

## Task 8: FRB Codegen and Dart Wrapper

**Files:**
- Modify: `pubspec.yaml`
- Create: Dart bindings (auto-generated by FRB codegen)
- Modify: `lib/features/player/proxy/proxy_controller.dart` (rewrite to thin wrapper)
- Modify: `lib/features/player/proxy/proxy_models.dart` (keep Dart-side models)

**Step 1: Run FRB codegen**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter_rust_bridge_codegen generate
```

Expected: Generates Dart bindings under `lib/src/rust/`

**Step 2: Rewrite proxy_controller.dart as thin FRB wrapper**

Replace `lib/features/player/proxy/proxy_controller.dart` with:
```dart
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';

// Import generated FRB bindings — exact path depends on codegen output
import 'package:ma_palyer/src/rust/api/proxy_api.dart' as rust;

class ProxyController {
  ProxyController._();
  static final ProxyController instance = ProxyController._();

  bool _initialized = false;
  Timer? _statsTimer;
  StreamController<ProxyAggregateStats>? _aggregateStatsController;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final cacheDir = (await getTemporaryDirectory()).path;
    rust.initEngine(
      config: rust.EngineConfig(
        chunkSize: 2 * 1024 * 1024,
        maxConcurrency: 8,
        cacheDir: cacheDir,
      ),
    );
    _initialized = true;
  }

  Future<ResolvedPlaybackEndpoint> createSession(
    PlayableMedia media, {
    String? fileKey,
    Future<Map<String, String>?> Function()? onSourceAuthRejected,
  }) async {
    await _ensureInitialized();

    if (_isM3u8Like(media.url)) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }

    final shouldProxy =
        (fileKey != null && fileKey.isNotEmpty) || _isMp4Like(media.url);
    if (!shouldProxy) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }

    final info = rust.createSession(
      url: media.url,
      headers: Map<String, String>.from(media.headers),
      fileKey: fileKey ?? media.progressKey,
    );

    return ResolvedPlaybackEndpoint(
      originalMedia: media,
      playbackUrl: info.playbackUrl,
      proxySession: ProxySessionDescriptor(
        sessionId: info.sessionId,
        sourceUrl: media.url,
        headers: Map<String, String>.from(media.headers),
        mode: ProxyMode.parallel,
        createdAt: DateTime.now(),
        contentLength: info.contentLength,
      ),
    );
  }

  Stream<ProxyAggregateStats> watchAggregateStats() {
    _aggregateStatsController ??=
        StreamController<ProxyAggregateStats>.broadcast();
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      try {
        final stats = rust.getStats(sessionId: null);
        _aggregateStatsController?.add(
          ProxyAggregateStats(
            proxyRunning: _initialized,
            downloadBps: stats.downloadBps.toDouble(),
            bufferedBytesAhead: stats.bufferedBytesAhead.toInt(),
            activeWorkers: stats.activeWorkers,
            updatedAt: DateTime.now(),
          ),
        );
      } catch (_) {
        // Engine not ready yet
      }
    });
    return _aggregateStatsController!.stream;
  }

  int? getRestoredPosition(String sessionId) => null; // TODO: implement if needed

  Future<void> closeSession(String sessionId) async {
    rust.closeSession(sessionId: sessionId);
  }

  Future<void> invalidateAll() async {
    // Handled by Rust side — close_session for all
  }

  Future<void> dispose() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _aggregateStatsController?.close();
    _aggregateStatsController = null;
    rust.dispose();
    _initialized = false;
  }

  bool _isM3u8Like(String url) => url.toLowerCase().contains('.m3u8');
  bool _isMp4Like(String url) => url.toLowerCase().contains('.mp4');
}
```

**Step 3: Verify the Dart code compiles**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter analyze
```

Expected: No errors (warnings OK)

**Step 4: Commit**

```bash
git add lib/ pubspec.yaml
git commit -m "feat: rewrite ProxyController as thin FRB wrapper (~80 lines)"
```

---

## Task 9: Platform Build Configuration

**Files:**
- Modify: `macos/Podfile` or CMakeLists (as needed by FRB)
- Modify: `android/app/build.gradle` (add Rust NDK targets)
- Modify: `ios/Podfile` (add Rust static library)

**Step 1: Follow FRB platform setup**

Run the FRB integration command to set up platform-specific build files:

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter_rust_bridge_codegen integrate
```

This auto-generates the required platform glue (Podfile entries, Gradle config, CMakeLists).

**Step 2: Build for macOS (primary dev platform)**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter build macos --debug
```

Expected: Builds successfully

**Step 3: Run the app and verify proxy works**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter run -d macos
```

Expected: App launches, video playback works through Rust proxy

**Step 4: Commit**

```bash
git add .
git commit -m "feat: add platform build configuration for Rust proxy engine"
```

---

## Task 10: Integration Testing and Cleanup

**Files:**
- Modify: `test/features/proxy_controller_test.dart` (update to test new wrapper)
- Delete: Old test utilities that reference removed Dart internals

**Step 1: Update Dart tests to test the new FRB-based ProxyController**

The existing 748-line test file tests Dart internals (`_ProxySession`, `_RangeMemoryCache`, etc.) that no longer exist. Key test scenarios should be replicated as Rust integration tests (already partially done in Tasks 2-6).

Update `test/features/proxy_controller_test.dart` to test the public API:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/player/proxy/proxy_controller.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';

void main() {
  // Integration tests for the Rust-backed ProxyController.
  // These require a running Rust engine and are tested via
  // `cargo test` in the rust/ directory.
  //
  // The Dart wrapper is thin enough that unit testing the
  // Rust integration tests covers the critical paths.

  test('m3u8 URLs bypass proxy', () async {
    final media = PlayableMedia(
      url: 'https://example.com/stream.m3u8',
      headers: const {},
      subtitle: null,
      progressKey: 'test',
    );
    final endpoint = await ProxyController.instance.createSession(media);
    expect(endpoint.playbackUrl, media.url);
    expect(endpoint.proxySession, isNull);
  });
}
```

**Step 2: Run Rust tests**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo test
```

Expected: All tests pass

**Step 3: Run Flutter tests**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer
flutter test
```

Expected: Tests pass

**Step 4: Commit**

```bash
git add test/ rust/
git commit -m "test: update integration tests for Rust proxy engine"
```

---

## Task 11: ISO/UDF Auto-Detection Stub (Architecture Reservation)

**Files:**
- Modify: `rust/src/source/iso_source.rs`
- Modify: `rust/src/source/mod.rs`

**Step 1: Write the IsoMediaSource decorator stub**

Replace `rust/src/source/iso_source.rs`:
```rust
use std::sync::Arc;
use anyhow::Result;
use async_trait::async_trait;
use bytes::Bytes;

use super::traits::{MediaSource, SourceInfo};

/// Decorator that maps byte ranges to an inner file within an ISO/UDF container.
/// The inner source provides the full ISO file; this adapter translates
/// fetch_range calls to the correct offset within the ISO.
pub struct IsoMediaSource {
    inner: Arc<dyn MediaSource>,
    /// Byte offset of the target file (e.g. .m2ts) within the ISO
    file_offset: u64,
    /// Size of the target file within the ISO
    file_length: u64,
    /// Content type override for the inner file
    content_type: String,
}

impl IsoMediaSource {
    pub fn new(
        inner: Arc<dyn MediaSource>,
        file_offset: u64,
        file_length: u64,
        content_type: String,
    ) -> Self {
        Self {
            inner,
            file_offset,
            file_length,
            content_type,
        }
    }
}

#[async_trait]
impl MediaSource for IsoMediaSource {
    async fn probe(&self) -> Result<SourceInfo> {
        Ok(SourceInfo {
            content_length: self.file_length,
            content_type: self.content_type.clone(),
            supports_range: true,
        })
    }

    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes> {
        let real_start = self.file_offset + start;
        let real_end = self.file_offset + end;
        self.inner.fetch_range(real_start, real_end).await
    }

    async fn refresh_auth(&self) -> Result<()> {
        self.inner.refresh_auth().await
    }
}

/// Auto-detect whether a source is an ISO and wrap it if needed.
/// Currently a stub — full UDF parsing will be implemented when BT support is added.
pub async fn wrap_if_iso(source: Arc<dyn MediaSource>) -> Result<Arc<dyn MediaSource>> {
    // Check for ISO/UDF magic at offset 32768
    match crate::detect::container::detect_iso(source.as_ref()).await {
        Ok(format) => {
            match format {
                crate::detect::container::ContainerFormat::Iso9660 |
                crate::detect::container::ContainerFormat::Udf => {
                    // TODO: Parse UDF filesystem to find main .m2ts track
                    // For now, log and return unwrapped source
                    tracing::info!("ISO/UDF detected but UDF parsing not yet implemented");
                    Ok(source)
                }
                _ => Ok(source),
            }
        }
        Err(_) => Ok(source), // Detection failed, use source as-is
    }
}
```

**Step 2: Update source/mod.rs**

Replace `rust/src/source/mod.rs`:
```rust
pub mod traits;
pub mod http_source;
pub mod iso_source;
```

**Step 3: Wire auto-detection into session creation**

In `rust/src/engine/session.rs`, update `ProxySession::new` to call `wrap_if_iso` after creating the HttpSource. Add after `let source = Arc::new(HttpSource::new(...))`:

```rust
// Auto-detect container format (ISO/UDF → transparent offset mapping)
let source: Arc<dyn MediaSource> = crate::source::iso_source::wrap_if_iso(source).await?;
```

**Step 4: Verify compilation**

```bash
cd /Users/y/IdeaProjects/MaPlayer/ma_palyer/rust
cargo check
```

Expected: Compiles

**Step 5: Commit**

```bash
git add rust/src/source/ rust/src/engine/session.rs
git commit -m "feat: add IsoMediaSource decorator stub for future ISO/UDF support"
```

---

## Summary

| Task | Description | Dependencies |
|------|------------|-------------|
| 1 | Scaffold Rust crate + FRB | None |
| 2 | MediaSource trait + HttpSource | Task 1 |
| 3 | DiskCache (mmap + BitVec) | Task 1 |
| 4 | Container detection + warmup | Task 2 |
| 5 | Download engine (downloader + stats + session) | Tasks 2, 3, 4 |
| 6 | Axum HTTP server | Task 5 |
| 7 | Wire up FRB API | Task 6 |
| 8 | FRB codegen + Dart wrapper | Task 7 |
| 9 | Platform build config | Task 8 |
| 10 | Integration tests + cleanup | Task 9 |
| 11 | ISO/UDF stub (architecture reservation) | Task 5 |

Tasks 2 and 3 can run in parallel. Task 11 can run in parallel with Tasks 8-10.
