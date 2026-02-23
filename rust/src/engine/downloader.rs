// Multi-connection chunk downloader — fetches byte ranges from the source in parallel.

use std::sync::Arc;

use anyhow::Result;
use parking_lot::Mutex;
use tokio::sync::{Notify, Semaphore};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use super::cache::DiskCache;
use super::stats::StatsCollector;
use crate::source::traits::MediaSource;

pub struct Downloader {
    source: Arc<dyn MediaSource>,
    cache: Arc<DiskCache>,
    urgent_semaphore: Arc<Semaphore>,
    background_semaphore: Arc<Semaphore>,
    stats: Arc<StatsCollector>,
    chunk_notifiers: Arc<Mutex<Vec<Option<Arc<Notify>>>>>,
    cancel_tokens: Arc<Mutex<Vec<Option<CancellationToken>>>>,
    shutdown_token: CancellationToken,
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
        let urgent_permits = 2usize;
        let background_permits = (max_concurrency as usize).saturating_sub(urgent_permits).max(1);
        Self {
            source,
            cache,
            urgent_semaphore: Arc::new(Semaphore::new(urgent_permits)),
            background_semaphore: Arc::new(Semaphore::new(background_permits)),
            stats,
            chunk_notifiers: Arc::new(Mutex::new(vec![None; total_chunks])),
            cancel_tokens: Arc::new(Mutex::new(vec![None; total_chunks])),
            shutdown_token: CancellationToken::new(),
            max_retries: 3,
        }
    }

    /// Cancel all in-flight downloads and prevent new ones from starting.
    pub fn shutdown(&self) {
        self.shutdown_token.cancel();
        // Also cancel all individual chunk tokens so in-flight fetches exit promptly.
        let tokens = self.cancel_tokens.lock();
        for slot in tokens.iter() {
            if let Some(token) = slot {
                token.cancel();
            }
        }
    }

    /// Idempotent: start downloading a chunk with background priority.
    pub fn start_prefetch(&self, chunk_index: usize) {
        self.start_download(chunk_index, Arc::clone(&self.background_semaphore), false);
    }

    /// Idempotent: start downloading a chunk with urgent priority (dedicated permits).
    pub fn start_urgent_prefetch(&self, chunk_index: usize) {
        self.start_download(chunk_index, Arc::clone(&self.urgent_semaphore), true);
    }

    fn start_download(&self, chunk_index: usize, semaphore: Arc<Semaphore>, urgent: bool) {
        // Don't start new work if shutdown has been requested.
        if self.shutdown_token.is_cancelled() {
            return;
        }

        // Already cached — nothing to do.
        if self.cache.has_chunk(chunk_index) {
            return;
        }

        // Check if already in-flight.
        {
            let tokens = self.cancel_tokens.lock();
            if tokens[chunk_index].is_some() {
                return;
            }
        }

        // Set up notifier and cancel token.
        let token = CancellationToken::new();
        let notify = Arc::new(Notify::new());

        {
            let mut tokens = self.cancel_tokens.lock();
            // Double-check after acquiring lock.
            if tokens[chunk_index].is_some() {
                return;
            }
            tokens[chunk_index] = Some(token.clone());
        }
        {
            let mut notifiers = self.chunk_notifiers.lock();
            notifiers[chunk_index] = Some(notify.clone());
        }

        let source = Arc::clone(&self.source);
        let cache = Arc::clone(&self.cache);
        let stats = Arc::clone(&self.stats);
        let cancel_tokens = Arc::clone(&self.cancel_tokens);
        let chunk_notifiers = Arc::clone(&self.chunk_notifiers);
        let shutdown_token = self.shutdown_token.clone();
        let max_retries = self.max_retries;
        let chunk_size = cache.chunk_size();

        tokio::spawn(async move {
            let _result = Self::download_chunk_task(
                chunk_index,
                source,
                cache,
                semaphore,
                stats,
                token,
                shutdown_token,
                max_retries,
                chunk_size,
                urgent,
            )
            .await;

            // Notify waiters regardless of success/failure.
            {
                let notifiers = chunk_notifiers.lock();
                if let Some(n) = &notifiers[chunk_index] {
                    n.notify_waiters();
                }
            }

            // Cleanup: remove token and notifier.
            {
                let mut tokens = cancel_tokens.lock();
                tokens[chunk_index] = None;
            }
            {
                let mut notifiers = chunk_notifiers.lock();
                notifiers[chunk_index] = None;
            }
        });
    }

    async fn download_chunk_task(
        chunk_index: usize,
        source: Arc<dyn MediaSource>,
        cache: Arc<DiskCache>,
        semaphore: Arc<Semaphore>,
        stats: Arc<StatsCollector>,
        token: CancellationToken,
        shutdown_token: CancellationToken,
        max_retries: u32,
        chunk_size: u64,
        urgent: bool,
    ) -> Result<()> {
        // Check shutdown before waiting for semaphore.
        if shutdown_token.is_cancelled() {
            debug!("chunk {} skipped: shutdown in progress", chunk_index);
            return Ok(());
        }

        let priority_label = if urgent { "urgent" } else { "background" };

        // Acquire semaphore permit, but bail if shutdown fires while waiting.
        let _permit = tokio::select! {
            permit = semaphore.acquire() => {
                permit.map_err(|e| anyhow::anyhow!("{}", e))?
            }
            _ = shutdown_token.cancelled() => {
                debug!("chunk {} cancelled while waiting for {} semaphore", chunk_index, priority_label);
                return Ok(());
            }
        };

        debug!("chunk {} acquired {} semaphore permit", chunk_index, priority_label);
        stats.increment_workers();

        let result = Self::fetch_with_retry(
            chunk_index,
            &source,
            &cache,
            &stats,
            &token,
            max_retries,
            chunk_size,
        )
        .await;

        stats.decrement_workers();
        result
    }

    async fn fetch_with_retry(
        chunk_index: usize,
        source: &Arc<dyn MediaSource>,
        cache: &Arc<DiskCache>,
        stats: &Arc<StatsCollector>,
        token: &CancellationToken,
        max_retries: u32,
        chunk_size: u64,
    ) -> Result<()> {
        let start = chunk_index as u64 * chunk_size;
        let end = start + cache.chunk_len(chunk_index) as u64 - 1;

        for attempt in 0..=max_retries {
            // Check cancellation before each attempt.
            if token.is_cancelled() {
                debug!("chunk {} cancelled before fetch", chunk_index);
                return Ok(());
            }

            match source.fetch_range(start, end).await {
                Ok(data) => {
                    // Check cancellation after fetch.
                    if token.is_cancelled() {
                        debug!("chunk {} cancelled after fetch", chunk_index);
                        return Ok(());
                    }

                    cache.put_chunk(chunk_index, &data)?;
                    stats.record_downloaded(data.len() as u64);
                    debug!("chunk {} downloaded ({} bytes)", chunk_index, data.len());
                    return Ok(());
                }
                Err(e) => {
                    let msg = e.to_string();
                    if msg.contains("auth_rejected") {
                        warn!(
                            "chunk {} auth rejected, refreshing auth (attempt {})",
                            chunk_index, attempt
                        );
                        if let Err(re) = source.refresh_auth().await {
                            warn!("refresh_auth failed: {}", re);
                        }
                        // Retry after auth refresh.
                        continue;
                    }

                    if attempt < max_retries {
                        warn!(
                            "chunk {} fetch failed (attempt {}): {}",
                            chunk_index, attempt, e
                        );
                        tokio::time::sleep(std::time::Duration::from_millis(
                            500 * (attempt as u64 + 1),
                        ))
                        .await;
                    } else {
                        warn!(
                            "chunk {} fetch failed after {} retries: {}",
                            chunk_index, max_retries, e
                        );
                        return Err(e);
                    }
                }
            }
        }

        Ok(())
    }

    /// Wait until the chunk is cached. Returns `true` if available, `false` on timeout/failure.
    pub async fn wait_for_chunk(&self, chunk_index: usize) -> bool {
        if self.cache.has_chunk(chunk_index) {
            return true;
        }

        // Ensure the chunk is being fetched.
        self.start_prefetch(chunk_index);

        // Get the notifier.
        let notify = {
            let notifiers = self.chunk_notifiers.lock();
            notifiers[chunk_index].clone()
        };

        if let Some(notify) = notify {
            notify.notified().await;
        }

        self.cache.has_chunk(chunk_index)
    }

    /// Cancel all in-flight downloads outside the range [start_chunk, end_chunk).
    pub fn abort_outside_window(&self, start_chunk: usize, end_chunk: usize) {
        let tokens = self.cancel_tokens.lock();
        for (i, slot) in tokens.iter().enumerate() {
            if i >= start_chunk && i < end_chunk {
                continue;
            }
            if let Some(token) = slot {
                token.cancel();
            }
        }
    }

    /// Start prefetching all chunks in the range [start_chunk, end_chunk).
    pub fn prefetch_range(&self, start_chunk: usize, end_chunk: usize) {
        let end = end_chunk.min(self.cache.total_chunks());
        for i in start_chunk..end {
            self.start_prefetch(i);
        }
    }
}
