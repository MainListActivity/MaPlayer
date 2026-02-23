use anyhow::Result;
use crate::source::traits::MediaSource;

#[derive(Debug, PartialEq)]
pub enum ContainerFormat {
    Mp4,
    Matroska, // MKV/WebM
    TransportStream,
    Iso9660,
    Udf,
    Unknown,
}

/// Detect container format from file header bytes (first few KB).
pub fn detect_container(header: &[u8]) -> ContainerFormat {
    // MP4/MOV: bytes 4..8 == "ftyp"
    if header.len() >= 8 && &header[4..8] == b"ftyp" {
        return ContainerFormat::Mp4;
    }

    // MKV/WebM: EBML magic bytes at offset 0
    if header.len() >= 4 && header[0..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        return ContainerFormat::Matroska;
    }

    // MPEG-TS: sync byte 0x47 at offset 0 and offset 188
    if header.len() > 188 && header[0] == 0x47 && header[188] == 0x47 {
        return ContainerFormat::TransportStream;
    }

    ContainerFormat::Unknown
}

/// Detect ISO/UDF by checking bytes at offset 32768 (requires source fetch).
/// ISO 9660 volume descriptor starts at sector 16 (32768 bytes).
pub async fn detect_iso(source: &dyn MediaSource) -> Result<ContainerFormat> {
    // Volume descriptor area starts at offset 32768.
    // We read 2048 bytes (one sector) to check identifiers.
    let data = source.fetch_range(32768, 32768 + 2047).await?;

    if data.len() >= 5 {
        // ISO 9660: "CD001" at offset 1 within the descriptor
        if data.len() > 5 && &data[1..6] == b"CD001" {
            return Ok(ContainerFormat::Iso9660);
        }
        // UDF: "BEA01", "NSR02", or "NSR03" at offset 1
        if data.len() > 5 {
            let id = &data[1..6];
            if id == b"BEA01" || id == b"NSR02" || id == b"NSR03" {
                return Ok(ContainerFormat::Udf);
            }
        }
    }

    Ok(ContainerFormat::Unknown)
}

/// For MP4 files, scan top-level atoms to find the moov box.
/// Returns (offset, size) if found.
pub fn find_moov_box(header: &[u8]) -> Option<(u64, u64)> {
    let len = header.len() as u64;
    let mut offset: u64 = 0;

    while offset + 8 <= len {
        let pos = offset as usize;
        // Read 4-byte big-endian size
        let size32 = u32::from_be_bytes([
            header[pos],
            header[pos + 1],
            header[pos + 2],
            header[pos + 3],
        ]) as u64;

        let atom_type = &header[pos + 4..pos + 8];

        let atom_size = if size32 == 1 {
            // 64-bit extended size in bytes 8..16
            if offset + 16 > len {
                break;
            }
            let ext = u64::from_be_bytes([
                header[pos + 8],
                header[pos + 9],
                header[pos + 10],
                header[pos + 11],
                header[pos + 12],
                header[pos + 13],
                header[pos + 14],
                header[pos + 15],
            ]);
            ext
        } else if size32 == 0 {
            // Atom extends to end of file
            len - offset
        } else {
            size32
        };

        if atom_type == b"moov" {
            return Some((offset, atom_size));
        }

        if atom_size == 0 {
            break;
        }
        offset += atom_size;
    }

    None
}
