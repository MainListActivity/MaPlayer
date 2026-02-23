// Live statistics aggregation — download progress, cache hit rates, connection counts.

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Instant;

use parking_lot::Mutex;

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

pub struct StatsCollector {
    download_bytes_total: AtomicU64,
    serve_bytes_total: AtomicU64,
    active_workers: AtomicU32,
    requested_bytes: AtomicU64,
    cache_hit_bytes: AtomicU64,
    last_sample: Mutex<StatsSample>,
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

    /// Record a request: `total` bytes were requested, of which `cached` were already in cache.
    pub fn record_request(&self, total: u64, cached: u64) {
        self.requested_bytes.fetch_add(total, Ordering::Relaxed);
        self.cache_hit_bytes.fetch_add(cached, Ordering::Relaxed);
    }

    pub fn increment_workers(&self) {
        self.active_workers.fetch_add(1, Ordering::Relaxed);
    }

    pub fn decrement_workers(&self) {
        self.active_workers.fetch_sub(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self, buffered_bytes_ahead: u64) -> StatsSnapshot {
        let now = Instant::now();
        let current_download = self.download_bytes_total.load(Ordering::Relaxed);
        let current_serve = self.serve_bytes_total.load(Ordering::Relaxed);

        let (download_bps, serve_bps) = {
            let mut sample = self.last_sample.lock();
            let elapsed = now.duration_since(sample.at).as_secs_f64();

            let (dbps, sbps) = if elapsed > 0.1 {
                let d = ((current_download - sample.download_bytes) as f64 / elapsed) as u64;
                let s = ((current_serve - sample.serve_bytes) as f64 / elapsed) as u64;
                (d, s)
            } else {
                (0, 0)
            };

            // Update sample for next call
            sample.at = now;
            sample.download_bytes = current_download;
            sample.serve_bytes = current_serve;

            (dbps, sbps)
        };

        let requested = self.requested_bytes.load(Ordering::Relaxed);
        let cache_hit = self.cache_hit_bytes.load(Ordering::Relaxed);
        let cache_hit_rate = if requested > 0 {
            cache_hit as f64 / requested as f64
        } else {
            0.0
        };

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

impl Default for StatsCollector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stats_basic() {
        let stats = StatsCollector::new();
        stats.record_downloaded(1000);
        stats.record_downloaded(500);
        assert_eq!(stats.total_downloaded(), 1500);

        stats.record_served(200);
        stats.record_request(1000, 300);

        stats.increment_workers();
        stats.increment_workers();
        stats.decrement_workers();

        let snap = stats.snapshot(4096);
        assert_eq!(snap.buffered_bytes_ahead, 4096);
        assert_eq!(snap.active_workers, 1);
        assert!((snap.cache_hit_rate - 0.3).abs() < f64::EPSILON);
    }
}
