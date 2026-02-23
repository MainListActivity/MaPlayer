// On-disk chunk cache backed by memory-mapped files and a bitvec completion map.

use std::fs::{self, OpenOptions};
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
    /// Create a new disk cache backed by a temp file in `cache_dir`.
    ///
    /// The file is truncated to `content_length` and memory-mapped.
    /// A bitmap tracks which chunks have been written.
    pub fn new(
        cache_dir: &Path,
        session_id: &str,
        content_length: u64,
        chunk_size: u64,
    ) -> Result<Self> {
        if content_length == 0 {
            return Err(anyhow!("content_length must be > 0"));
        }
        if chunk_size == 0 {
            return Err(anyhow!("chunk_size must be > 0"));
        }

        fs::create_dir_all(cache_dir)?;

        let path = cache_dir.join(format!("{}.cache", session_id));

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;

        file.set_len(content_length)?;

        // SAFETY: we just created the file and own it exclusively.
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

    /// Write `data` into the cache at the given chunk index.
    pub fn put_chunk(&self, chunk_index: usize, data: &[u8]) -> Result<()> {
        if chunk_index >= self.total_chunks {
            return Err(anyhow!(
                "chunk_index {} out of range (total {})",
                chunk_index,
                self.total_chunks
            ));
        }

        let expected_len = self.chunk_len(chunk_index);
        if data.len() != expected_len {
            return Err(anyhow!(
                "data length {} != expected chunk length {}",
                data.len(),
                expected_len
            ));
        }

        let offset = chunk_index as u64 * self.chunk_size;

        {
            let mut mmap = self.mmap.write();
            mmap[offset as usize..offset as usize + data.len()].copy_from_slice(data);
        }

        {
            let mut bitmap = self.bitmap.write();
            if !bitmap[chunk_index] {
                bitmap.set(chunk_index, true);
                self.cached_bytes
                    .fetch_add(data.len() as u64, Ordering::Relaxed);
            }
        }

        Ok(())
    }

    /// Read a single chunk from the cache. Returns `None` if the chunk is not cached.
    pub fn read_chunk(&self, chunk_index: usize) -> Option<Vec<u8>> {
        if chunk_index >= self.total_chunks {
            return None;
        }

        let bitmap = self.bitmap.read();
        if !bitmap[chunk_index] {
            return None;
        }

        let offset = chunk_index as u64 * self.chunk_size;
        let len = self.chunk_len(chunk_index);

        let mmap = self.mmap.read();
        Some(mmap[offset as usize..offset as usize + len].to_vec())
    }

    /// Read an arbitrary byte range `[start, end)` from the cache.
    /// Returns `None` if any chunk overlapping the range is missing.
    pub fn read_range(&self, start: u64, end: u64) -> Option<Vec<u8>> {
        if start >= end || end > self.content_length {
            return None;
        }

        let first_chunk = (start / self.chunk_size) as usize;
        let last_chunk = ((end - 1) / self.chunk_size) as usize;

        // Check all required chunks are present.
        {
            let bitmap = self.bitmap.read();
            for i in first_chunk..=last_chunk {
                if !bitmap[i] {
                    return None;
                }
            }
        }

        let mmap = self.mmap.read();
        Some(mmap[start as usize..end as usize].to_vec())
    }

    /// Check whether a chunk is cached.
    pub fn has_chunk(&self, chunk_index: usize) -> bool {
        if chunk_index >= self.total_chunks {
            return false;
        }
        let bitmap = self.bitmap.read();
        bitmap[chunk_index]
    }

    /// Count the number of contiguous cached bytes starting from `playback_offset`.
    pub fn buffered_bytes_ahead(&self, playback_offset: u64) -> u64 {
        if playback_offset >= self.content_length {
            return 0;
        }

        let chunk_index = (playback_offset / self.chunk_size) as usize;
        let bitmap = self.bitmap.read();

        // The first chunk may be partially consumed by the playback offset.
        if !bitmap[chunk_index] {
            return 0;
        }

        // Bytes remaining in the first (current) chunk.
        let first_chunk_end = std::cmp::min(
            (chunk_index as u64 + 1) * self.chunk_size,
            self.content_length,
        );
        let mut buffered = first_chunk_end - playback_offset;

        // Walk forward through contiguous cached chunks.
        for i in (chunk_index + 1)..self.total_chunks {
            if !bitmap[i] {
                break;
            }
            buffered += self.chunk_len(i) as u64;
        }

        buffered
    }

    /// Byte length of the given chunk. The last chunk may be shorter than `chunk_size`.
    pub fn chunk_len(&self, chunk_index: usize) -> usize {
        if chunk_index + 1 < self.total_chunks {
            self.chunk_size as usize
        } else {
            // Last chunk — may be shorter.
            let remainder = (self.content_length % self.chunk_size) as usize;
            if remainder == 0 {
                self.chunk_size as usize
            } else {
                remainder
            }
        }
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
        // Best-effort deletion of the backing file.
        let _ = fs::remove_file(&self.path);
    }
}
