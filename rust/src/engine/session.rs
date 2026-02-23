// Proxy session state machine — manages a single file's download and playback proxy.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, Result};
use bytes::Bytes;
use parking_lot::Mutex;
use tokio::sync::mpsc;
use tracing::{debug, info};

use super::cache::DiskCache;
use super::downloader::Downloader;
use super::stats::{StatsCollector, StatsSnapshot};
use super::warmup::compute_warmup_ranges;
use crate::config::{
    PRIORITY_BUFFER_SECONDS, SEEK_STABLE_SEQUENTIAL_HITS, SEEK_THRESHOLD_BYTES,
    SEEK_WARMUP_REQUESTS, SEEK_WARMUP_SECONDS,
};
use crate::source::http_source::HttpSource;
use crate::source::traits::{MediaSource, SourceInfo};

struct SeekState {
    /// Whether seek detection is enabled.
    enabled: bool,
    /// Time of the last seek or session start.
    warmup_start: Instant,
    /// Number of requests since last seek/start.
    request_count: u32,
    /// Number of sequential (non-seek) cache hits in a row.
    sequential_hits: u32,
    /// The last byte offset requested.
    last_offset: u64,
}

impl SeekState {
    fn new() -> Self {
        Self {
            enabled: false,
            warmup_start: Instant::now(),
            request_count: 0,
            sequential_hits: 0,
            last_offset: 0,
        }
    }

    /// Check warmup conditions and potentially enable seek detection.
    fn maybe_enable(&mut self) {
        if self.enabled {
            return;
        }
        let elapsed = self.warmup_start.elapsed().as_secs();
        if elapsed >= SEEK_WARMUP_SECONDS
            && self.request_count >= SEEK_WARMUP_REQUESTS
            && self.sequential_hits >= SEEK_STABLE_SEQUENTIAL_HITS
        {
            self.enabled = true;
            debug!("seek detection enabled");
        }
    }

    /// Determine if the given offset represents a seek (large jump).
    fn is_seek(&self, offset: u64) -> bool {
        if !self.enabled {
            return false;
        }
        let diff = if offset > self.last_offset {
            offset - self.last_offset
        } else {
            self.last_offset - offset
        };
        diff > SEEK_THRESHOLD_BYTES
    }

    /// Update state after serving a request.
    fn update(&mut self, offset: u64, was_sequential: bool) {
        self.request_count += 1;
        self.last_offset = offset;
        if was_sequential {
            self.sequential_hits += 1;
        } else {
            self.sequential_hits = 0;
        }
        self.maybe_enable();
    }

    /// Reset warmup after a detected seek.
    fn reset_warmup(&mut self) {
        self.warmup_start = Instant::now();
        self.request_count = 0;
        self.sequential_hits = 0;
        self.enabled = false;
    }
}

pub struct ProxySession {
    pub session_id: String,
    http_source: Arc<HttpSource>,
    cache: Arc<DiskCache>,
    downloader: Arc<Downloader>,
    stats: Arc<StatsCollector>,
    info: SourceInfo,
    playback_offset: AtomicU64,
    playback_bps: Mutex<f64>,
    seek_state: Mutex<SeekState>,
    chunk_size: u64,
}

impl ProxySession {
    /// Create a new session: probe the source, create cache, start warmup prefetch.
    pub async fn new(
        session_id: String,
        url: String,
        headers: HashMap<String, String>,
        cache_dir: &str,
        chunk_size: u64,
        max_concurrency: u32,
    ) -> Result<Self> {
        let http_source = Arc::new(HttpSource::new(url, headers));

        // Probe the source to get content info.
        let info = http_source.probe().await?;
        if info.content_length == 0 {
            return Err(anyhow!("source content_length is 0"));
        }
        if !info.supports_range {
            return Err(anyhow!("source does not support range requests"));
        }

        info!(
            "session {} probed: {} bytes, type={}",
            session_id, info.content_length, info.content_type
        );
        let effective_concurrency = http_source.effective_concurrency(max_concurrency).await;

        // Auto-detect ISO/UDF and potentially wrap the source.
        let source: Arc<dyn MediaSource> =
            crate::source::iso_source::wrap_if_iso(http_source.clone() as Arc<dyn MediaSource>)
                .await?;

        let cache = Arc::new(DiskCache::new(
            Path::new(cache_dir),
            &session_id,
            info.content_length,
            chunk_size,
        )?);

        let stats = Arc::new(StatsCollector::new());

        let downloader = Arc::new(Downloader::new(
            source.clone(),
            cache.clone(),
            effective_concurrency,
            stats.clone(),
        ));
        info!(
            "session {} downloader concurrency configured={} effective={}",
            session_id, max_concurrency, effective_concurrency
        );

        let session = Self {
            session_id,
            http_source: http_source.clone(),
            cache: cache.clone(),
            downloader: downloader.clone(),
            stats: stats.clone(),
            info,
            playback_offset: AtomicU64::new(0),
            playback_bps: Mutex::new(0.0),
            seek_state: Mutex::new(SeekState::new()),
            chunk_size,
        };

        // Immediately prefetch head chunk (chunk 0) so the player's first
        // request doesn't have to wait.  Also prefetch the tail region
        // (last ~8 MB / 4 chunks) because MP4 moov atoms are commonly at
        // the end and the player will seek there right after reading the head.
        let total_chunks = cache.total_chunks();
        downloader.start_prefetch(0);
        {
            let tail_chunks = 4usize; // ~8 MB with 2 MB chunks
            let tail_start = total_chunks.saturating_sub(tail_chunks);
            for i in tail_start..total_chunks {
                downloader.start_prefetch(i);
            }
        }

        // Kick off warmup prefetch in background (may add more ranges after
        // format detection, but the critical head+tail are already in-flight).
        let warmup_source = source.clone();
        let warmup_downloader = downloader.clone();
        let warmup_cache = cache.clone();
        let cs = chunk_size;
        let cl = session.info.content_length;
        tokio::spawn(async move {
            match compute_warmup_ranges(warmup_source.as_ref(), cl, cs).await {
                Ok(ranges) => {
                    for (range_start, range_end) in ranges {
                        let start_chunk = (range_start / cs) as usize;
                        let end_chunk =
                            ((range_end / cs) + 1).min(warmup_cache.total_chunks() as u64) as usize;
                        warmup_downloader.prefetch_range(start_chunk, end_chunk);
                    }
                }
                Err(e) => {
                    tracing::warn!("warmup prefetch failed: {}", e);
                }
            }
        });

        Ok(session)
    }

    /// Serve a byte range [start, end) to the player.
    pub async fn serve_range(&self, start: u64, end: u64) -> Result<Vec<u8>> {
        let t0 = Instant::now();
        let end = end.min(self.info.content_length);
        if start >= end {
            return Err(anyhow!("invalid range: start={} end={}", start, end));
        }

        let range_len = end - start;

        // Update playback tracking.
        self.playback_offset.store(start, Ordering::Relaxed);

        // Seek detection.
        let is_seek = {
            let seek = self.seek_state.lock();
            seek.is_seek(start)
        };

        if is_seek {
            debug!("seek detected at offset {}", start);
            let start_chunk = (start / self.chunk_size) as usize;
            // Keep a window of chunks around the seek target.
            let window_chunks = 32usize; // ~64MB window with 2MB chunks
            let window_end = (start_chunk + window_chunks).min(self.cache.total_chunks());
            self.downloader
                .abort_outside_window(start_chunk, window_end);

            let mut seek = self.seek_state.lock();
            seek.reset_warmup();
        }

        // Calculate which chunks we need.
        let first_chunk = (start / self.chunk_size) as usize;
        let last_chunk = ((end - 1) / self.chunk_size) as usize;

        // Record cache hit stats.
        let mut cached_bytes = 0u64;
        for i in first_chunk..=last_chunk {
            if self.cache.has_chunk(i) {
                cached_bytes += self.cache.chunk_len(i) as u64;
            }
        }
        self.stats
            .record_request(range_len, cached_bytes.min(range_len));

        // Prioritize the required playback window with urgent (dedicated) permits
        // so the player's blocking request isn't starved by background prefetch.
        for i in first_chunk..=last_chunk {
            self.downloader.start_urgent_prefetch(i);
        }

        // Wait for required chunks.
        for i in first_chunk..=last_chunk {
            if !self.downloader.wait_for_chunk(i).await {
                return Err(anyhow!("failed to download chunk {}", i));
            }
        }

        // Schedule prefetch ahead based on estimated playback bitrate.
        let bps = {
            let bps = self.playback_bps.lock();
            *bps
        };
        let prefetch_bytes = if bps > 0.0 {
            (bps * PRIORITY_BUFFER_SECONDS as f64) as u64
        } else {
            // Default: prefetch 20 chunks ahead.
            self.chunk_size * 20
        };
        let prefetch_end_byte = (end + prefetch_bytes).min(self.info.content_length);
        let prefetch_end_chunk =
            ((prefetch_end_byte + self.chunk_size - 1) / self.chunk_size) as usize;
        let prefetch_end_chunk = prefetch_end_chunk.min(self.cache.total_chunks());
        let prefetch_start_chunk = last_chunk.saturating_add(1);
        if prefetch_start_chunk < prefetch_end_chunk {
            self.downloader
                .prefetch_range(prefetch_start_chunk, prefetch_end_chunk);
        }

        // Read from cache.
        let data = self
            .cache
            .read_range(start, end)
            .ok_or_else(|| anyhow!("cache read failed for range [{}, {})", start, end))?;

        // Update served stats and playback bitrate estimate.
        self.stats.record_served(data.len() as u64);

        // Update seek state.
        {
            let mut seek = self.seek_state.lock();
            let was_sequential = !is_seek;
            seek.update(start, was_sequential);
        }

        // Simple bitrate estimation: use the serve rate as approximation.
        // Update bps based on the range length (this is a rough heuristic).
        if range_len > 0 {
            let mut bps = self.playback_bps.lock();
            if *bps == 0.0 {
                // Initial estimate based on a common media bitrate.
                *bps = range_len as f64 * 8.0;
            } else {
                // Exponential moving average.
                *bps = *bps * 0.9 + range_len as f64 * 8.0 * 0.1;
            }
        }

        debug!(
            "serve_range session={} range=[{}, {}) bytes={} elapsed_ms={}",
            self.session_id,
            start,
            end,
            data.len(),
            t0.elapsed().as_millis()
        );

        Ok(data)
    }

    /// Serve a byte range [start, end) as a stream of Bytes chunks.
    ///
    /// Returns a receiver that yields data piece-by-piece as each underlying
    /// cache chunk becomes available.  The HTTP handler can start writing to
    /// the socket as soon as the first piece arrives, preventing player
    /// timeouts even when later chunks are still downloading.
    pub fn serve_range_stream(
        self: &Arc<Self>,
        start: u64,
        end: u64,
    ) -> Result<mpsc::Receiver<Result<Bytes>>> {
        let end = end.min(self.info.content_length);
        if start >= end {
            return Err(anyhow!("invalid range: start={} end={}", start, end));
        }

        let range_len = end - start;

        // Update playback tracking.
        self.playback_offset.store(start, Ordering::Relaxed);

        // Seek detection.
        let is_seek = {
            let seek = self.seek_state.lock();
            seek.is_seek(start)
        };

        if is_seek {
            debug!("seek detected at offset {}", start);
            let start_chunk = (start / self.chunk_size) as usize;
            let window_chunks = 32usize;
            let window_end = (start_chunk + window_chunks).min(self.cache.total_chunks());
            self.downloader
                .abort_outside_window(start_chunk, window_end);

            let mut seek = self.seek_state.lock();
            seek.reset_warmup();
        }

        let first_chunk = (start / self.chunk_size) as usize;
        let last_chunk = ((end - 1) / self.chunk_size) as usize;

        // Record cache hit stats.
        let mut cached_bytes = 0u64;
        for i in first_chunk..=last_chunk {
            if self.cache.has_chunk(i) {
                cached_bytes += self.cache.chunk_len(i) as u64;
            }
        }
        self.stats
            .record_request(range_len, cached_bytes.min(range_len));

        // Dispatch urgent downloads for all required chunks up-front.
        for i in first_chunk..=last_chunk {
            self.downloader.start_urgent_prefetch(i);
        }

        // Channel with enough buffer for all chunks so sender doesn't block.
        let chunk_count = last_chunk - first_chunk + 1;
        let (tx, rx) = mpsc::channel::<Result<Bytes>>(chunk_count.max(1));

        let session = Arc::clone(self);
        let t0 = Instant::now();

        tokio::spawn(async move {
            let mut total_sent = 0u64;

            for i in first_chunk..=last_chunk {
                // Wait for this specific chunk.
                if !session.downloader.wait_for_chunk(i).await {
                    let _ = tx
                        .send(Err(anyhow!("failed to download chunk {}", i)))
                        .await;
                    return;
                }

                // Calculate the slice of this chunk that falls within [start, end).
                let chunk_start_byte = i as u64 * session.chunk_size;
                let chunk_end_byte =
                    (chunk_start_byte + session.cache.chunk_len(i) as u64).min(end);
                let slice_start = start.max(chunk_start_byte);
                let slice_end = end.min(chunk_end_byte);

                if slice_start >= slice_end {
                    continue;
                }

                // Read just this slice from the mmap.
                match session.cache.read_range(slice_start, slice_end) {
                    Some(data) => {
                        total_sent += data.len() as u64;
                        if tx.send(Ok(Bytes::from(data))).await.is_err() {
                            // Receiver dropped (client disconnected).
                            debug!("stream receiver dropped at chunk {}", i);
                            return;
                        }
                    }
                    None => {
                        let _ = tx
                            .send(Err(anyhow!(
                                "cache read failed for chunk {} slice [{}, {})",
                                i,
                                slice_start,
                                slice_end
                            )))
                            .await;
                        return;
                    }
                }
            }

            // All chunks sent — schedule prefetch ahead.
            let bps = {
                let bps = session.playback_bps.lock();
                *bps
            };
            let prefetch_bytes = if bps > 0.0 {
                (bps * PRIORITY_BUFFER_SECONDS as f64) as u64
            } else {
                session.chunk_size * 20
            };
            let prefetch_end_byte = (end + prefetch_bytes).min(session.info.content_length);
            let prefetch_end_chunk =
                ((prefetch_end_byte + session.chunk_size - 1) / session.chunk_size) as usize;
            let prefetch_end_chunk = prefetch_end_chunk.min(session.cache.total_chunks());
            let prefetch_start_chunk = last_chunk.saturating_add(1);
            if prefetch_start_chunk < prefetch_end_chunk {
                session
                    .downloader
                    .prefetch_range(prefetch_start_chunk, prefetch_end_chunk);
            }

            // Update stats.
            session.stats.record_served(total_sent);
            {
                let mut seek = session.seek_state.lock();
                let was_sequential = !is_seek;
                seek.update(start, was_sequential);
            }
            if range_len > 0 {
                let mut bps = session.playback_bps.lock();
                if *bps == 0.0 {
                    *bps = range_len as f64 * 8.0;
                } else {
                    *bps = *bps * 0.9 + range_len as f64 * 8.0 * 0.1;
                }
            }

            debug!(
                "serve_range_stream session={} range=[{}, {}) bytes={} elapsed_ms={}",
                session.session_id,
                start,
                end,
                total_sent,
                t0.elapsed().as_millis()
            );
        });

        Ok(rx)
    }

    /// Get a stats snapshot.
    pub fn snapshot(&self) -> StatsSnapshot {
        let offset = self.playback_offset.load(Ordering::Relaxed);
        let buffered = self.cache.buffered_bytes_ahead(offset);
        self.stats.snapshot(buffered)
    }

    /// Update authentication credentials (new URL / headers from token refresh).
    pub fn update_auth(&self, new_url: String, new_headers: HashMap<String, String>) {
        self.http_source.update_auth(new_url, new_headers);
    }

    /// Get the content type of the source.
    pub fn content_type(&self) -> &str {
        &self.info.content_type
    }

    /// Get the total content length.
    pub fn content_length(&self) -> u64 {
        self.info.content_length
    }

    /// Cancel all in-flight download workers.
    pub fn shutdown(&self) {
        self.downloader.shutdown();
    }
}

impl Drop for ProxySession {
    fn drop(&mut self) {
        debug!("ProxySession {} dropped, shutting down downloader", self.session_id);
        self.downloader.shutdown();
    }
}
