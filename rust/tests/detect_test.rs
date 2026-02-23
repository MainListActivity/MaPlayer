use ma_proxy_engine::detect::container::{detect_container, find_moov_box, ContainerFormat};

#[test]
fn test_detect_mp4() {
    // MP4/MOV: bytes 4..8 = "ftyp"
    let mut header = vec![0u8; 256];
    // size = 8, type = "ftyp"
    header[0..4].copy_from_slice(&8u32.to_be_bytes());
    header[4..8].copy_from_slice(b"ftyp");
    assert_eq!(detect_container(&header), ContainerFormat::Mp4);
}

#[test]
fn test_detect_mkv() {
    // MKV/WebM: EBML magic bytes [0x1A, 0x45, 0xDF, 0xA3]
    let mut header = vec![0u8; 256];
    header[0] = 0x1A;
    header[1] = 0x45;
    header[2] = 0xDF;
    header[3] = 0xA3;
    assert_eq!(detect_container(&header), ContainerFormat::Matroska);
}

#[test]
fn test_detect_ts() {
    // MPEG-TS: sync byte 0x47 at offsets 0 and 188
    let mut header = vec![0u8; 256];
    header[0] = 0x47;
    header[188] = 0x47;
    assert_eq!(detect_container(&header), ContainerFormat::TransportStream);
}

#[test]
fn test_find_moov_at_start() {
    // Construct: ftyp atom (8 bytes) + moov atom (100 bytes)
    let mut header = vec![0u8; 256];

    // ftyp atom: size=8, type="ftyp"
    header[0..4].copy_from_slice(&8u32.to_be_bytes());
    header[4..8].copy_from_slice(b"ftyp");

    // moov atom: size=100, type="moov" starting at offset 8
    header[8..12].copy_from_slice(&100u32.to_be_bytes());
    header[12..16].copy_from_slice(b"moov");

    let result = find_moov_box(&header);
    assert_eq!(result, Some((8, 100)));
}

#[test]
fn test_find_moov_not_present() {
    // Construct: ftyp atom (8 bytes) + mdat atom (100 bytes), no moov
    let mut header = vec![0u8; 256];

    // ftyp atom: size=8, type="ftyp"
    header[0..4].copy_from_slice(&8u32.to_be_bytes());
    header[4..8].copy_from_slice(b"ftyp");

    // mdat atom: size=100, type="mdat" starting at offset 8
    header[8..12].copy_from_slice(&100u32.to_be_bytes());
    header[12..16].copy_from_slice(b"mdat");

    let result = find_moov_box(&header);
    assert_eq!(result, None);
}
