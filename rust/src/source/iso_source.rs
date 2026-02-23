use std::sync::Arc;
use anyhow::Result;
use async_trait::async_trait;
use bytes::Bytes;
use super::traits::{MediaSource, SourceInfo};

/// Decorator that maps byte ranges to an inner file within an ISO/UDF container.
pub struct IsoMediaSource {
    inner: Arc<dyn MediaSource>,
    file_offset: u64,
    file_length: u64,
    content_type: String,
}

impl IsoMediaSource {
    pub fn new(inner: Arc<dyn MediaSource>, file_offset: u64, file_length: u64, content_type: String) -> Self {
        Self { inner, file_offset, file_length, content_type }
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
        self.inner.fetch_range(self.file_offset + start, self.file_offset + end).await
    }

    async fn refresh_auth(&self) -> Result<()> {
        self.inner.refresh_auth().await
    }
}

/// Auto-detect ISO and wrap if needed. Currently a stub — full UDF parsing for later.
pub async fn wrap_if_iso(source: Arc<dyn MediaSource>) -> Result<Arc<dyn MediaSource>> {
    match crate::detect::container::detect_iso(source.as_ref()).await {
        Ok(format) => {
            match format {
                crate::detect::container::ContainerFormat::Iso9660 |
                crate::detect::container::ContainerFormat::Udf => {
                    tracing::info!("ISO/UDF detected but UDF parsing not yet implemented");
                    Ok(source)
                }
                _ => Ok(source),
            }
        }
        Err(_) => Ok(source),
    }
}
