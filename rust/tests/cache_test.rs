use ma_proxy_engine::engine::cache::DiskCache;

const MB: u64 = 1024 * 1024;

#[test]
fn test_disk_cache_put_and_read() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::new(dir.path(), "sess1", 10 * MB, 2 * MB).unwrap();

    assert_eq!(cache.total_chunks(), 5);
    assert!(!cache.has_chunk(0));

    // Write chunk 0 (2 MB of 0xAB).
    let data = vec![0xABu8; 2 * MB as usize];
    cache.put_chunk(0, &data).unwrap();

    assert!(cache.has_chunk(0));
    assert!(!cache.has_chunk(1));

    let read_back = cache.read_chunk(0).unwrap();
    assert_eq!(read_back.len(), 2 * MB as usize);
    assert_eq!(read_back, data);

    // Unwritten chunk returns None.
    assert!(cache.read_chunk(1).is_none());

    assert_eq!(cache.cached_bytes(), 2 * MB);
}

#[test]
fn test_disk_cache_buffered_bytes_ahead() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::new(dir.path(), "sess2", 10 * MB, 2 * MB).unwrap();

    // Cache chunks 0, 1, 2.
    for i in 0..3 {
        let data = vec![i as u8; 2 * MB as usize];
        cache.put_chunk(i, &data).unwrap();
    }

    // From offset 0, contiguous cached = chunks 0+1+2 = 6 MB.
    assert_eq!(cache.buffered_bytes_ahead(0), 6 * MB);

    // From offset 1 MB (middle of chunk 0), still contiguous through chunk 2.
    // Remaining in chunk 0: 1 MB, chunk 1: 2 MB, chunk 2: 2 MB = 5 MB.
    assert_eq!(cache.buffered_bytes_ahead(1 * MB), 5 * MB);

    // From offset 6 MB (start of chunk 3, which is not cached): 0.
    assert_eq!(cache.buffered_bytes_ahead(6 * MB), 0);
}

#[test]
fn test_disk_cache_last_chunk_shorter() {
    let dir = tempfile::tempdir().unwrap();
    // 5 MB file with 2 MB chunks => chunks of 2, 2, 1 MB.
    let cache = DiskCache::new(dir.path(), "sess3", 5 * MB, 2 * MB).unwrap();

    assert_eq!(cache.total_chunks(), 3);
    assert_eq!(cache.chunk_len(0), 2 * MB as usize);
    assert_eq!(cache.chunk_len(1), 2 * MB as usize);
    assert_eq!(cache.chunk_len(2), 1 * MB as usize);

    // Write and read the last (shorter) chunk.
    let data = vec![0xCDu8; 1 * MB as usize];
    cache.put_chunk(2, &data).unwrap();
    let read_back = cache.read_chunk(2).unwrap();
    assert_eq!(read_back, data);
}
