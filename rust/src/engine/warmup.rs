use anyhow::Result;
use crate::detect::container::{detect_container, find_moov_box, ContainerFormat};
use crate::source::traits::MediaSource;

/// Determine which byte ranges to prefetch for fast playback start.
/// Returns a list of (start, end) inclusive ranges.
pub async fn compute_warmup_ranges(
    source: &dyn MediaSource,
    content_length: u64,
    chunk_size: u64,
) -> Result<Vec<(u64, u64)>> {
    // Fetch first min(chunk_size, 32KB) for format detection
    let probe_size = chunk_size.min(32 * 1024).min(content_length);
    let header = source.fetch_range(0, probe_size.saturating_sub(1)).await?;

    let format = detect_container(&header);

    let mut ranges = Vec::new();

    match format {
        ContainerFormat::Mp4 => {
            // Scan for moov box in the header we already have
            if let Some((moov_offset, moov_size)) = find_moov_box(&header) {
                // moov is in the header area — prefetch from start through end of moov
                let moov_end = moov_offset + moov_size - 1;
                let end = moov_end.max(chunk_size - 1).min(content_length - 1);
                ranges.push((0, end));
            } else {
                // moov likely at end of file — prefetch head + tail
                ranges.push((0, chunk_size.min(content_length) - 1));
                if content_length > chunk_size {
                    let tail_start = content_length.saturating_sub(chunk_size);
                    ranges.push((tail_start, content_length - 1));
                }
            }
        }
        ContainerFormat::Matroska | ContainerFormat::TransportStream => {
            // Sequential formats — just the head chunk
            ranges.push((0, chunk_size.min(content_length) - 1));
        }
        _ => {
            // Unknown format — head + tail as a safe default
            ranges.push((0, chunk_size.min(content_length) - 1));
            if content_length > chunk_size {
                let tail_start = content_length.saturating_sub(chunk_size);
                ranges.push((tail_start, content_length - 1));
            }
        }
    }

    Ok(ranges)
}
