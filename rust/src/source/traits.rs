use anyhow::Result;
use async_trait::async_trait;
use bytes::Bytes;

pub struct SourceInfo {
    pub content_length: u64,
    pub content_type: String,
    pub supports_range: bool,
}

#[async_trait]
pub trait MediaSource: Send + Sync {
    async fn probe(&self) -> Result<SourceInfo>;
    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes>;
    async fn refresh_auth(&self) -> Result<()> {
        Ok(())
    }
}
