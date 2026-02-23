# Rust Proxy Engine Design

## 目标

将 `proxy_controller.dart`（~1682 行）的核心代理下载逻辑迁移到 Rust，通过 Flutter Rust Bridge (FRB) 通信。目的：

1. 性能提升：tokio 真并发 + mmap 零拷贝
2. 架构扩展：预留 BT 种子边下边播能力（librqbit）
3. ISO 原盘支持：自动检测 ISO/UDF 容器，透明暴露内部 .m2ts
4. 修复当前 Dart 实现的已知问题（伪并发、轮询 hack、文件截断）

## 架构总览

```
Dart (Flutter)
  ├── FRB: init / create_session / close_session / watch_stats / dispose
  └── media_kit → http://127.0.0.1:{port}/stream/{session_id}
        ↓
Rust crate: ma_proxy_engine
  ├── axum HTTP 服务器 (Range 支持)
  ├── 下载引擎 (reqwest + tokio::Semaphore)
  ├── 磁盘缓存 (mmap + 分片位图)
  ├── 容器自动检测 (MP4 moov / ISO UDF)
  ├── trait MediaSource
  │     ├── impl HttpSource (云盘)
  │     ├── impl TorrentSource (未来 BT, librqbit)
  │     └── impl IsoMediaSource (装饰器, UDF 偏移映射)
  └── 统计/监控
```

## Rust crate 结构

```
rust/
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── api/
│   │   └── proxy_api.rs          # FRB 公开 API
│   ├── engine/
│   │   ├── mod.rs
│   │   ├── session.rs            # ProxySession 生命周期管理
│   │   ├── downloader.rs         # 分片并行下载器
│   │   ├── cache.rs              # 磁盘缓存 (mmap + BitVec)
│   │   ├── warmup.rs             # 容器感知的启动预热
│   │   └── stats.rs              # 实时统计
│   ├── server/
│   │   ├── mod.rs
│   │   └── handler.rs            # axum HTTP Range handler
│   ├── source/
│   │   ├── mod.rs
│   │   ├── traits.rs             # trait MediaSource
│   │   ├── http_source.rs        # 云盘 HTTP Range 下载
│   │   └── iso_source.rs         # ISO/UDF 偏移映射装饰器
│   ├── detect/
│   │   ├── mod.rs
│   │   └── container.rs          # 容器格式自动检测
│   └── config.rs
```

## trait MediaSource

```rust
#[async_trait]
pub trait MediaSource: Send + Sync {
    async fn probe(&mut self) -> Result<SourceInfo>;
    async fn fetch_range(&self, start: u64, end: u64) -> Result<Bytes>;
    async fn refresh_auth(&mut self) -> Result<()> { Ok(()) }
}

pub struct SourceInfo {
    pub content_length: u64,
    pub content_type: String,
    pub supports_range: bool,
    pub inner_file_offset: Option<u64>,
    pub inner_file_length: Option<u64>,
}
```

### 数据源实现

| 实现 | 本次实现 | 说明 |
|------|---------|------|
| `HttpSource` | 是 | 云盘 URL + auth headers, reqwest Range 请求 |
| `TorrentSource` | 否（预留） | librqbit 顺序优先下载 |
| `IsoMediaSource` | 否（预留） | 装饰器，UDF 偏移映射，将 ISO 内 .m2ts 暴露为独立流 |

### 容器自动检测

Rust 内部自动处理，Dart 无感知：

```rust
async fn wrap_source_if_needed(source: Box<dyn MediaSource>) -> Box<dyn MediaSource> {
    let header = source.fetch_range(0, 32768).await?;
    match detect_container(&header) {
        Container::Iso9660 | Container::Udf => {
            let (offset, length) = parse_udf_main_track(&source).await?;
            Box::new(IsoMediaSource::new(source, offset, length))
        }
        _ => source,
    }
}
```

检测方式：
- ISO 9660: 偏移 32768 处 `CD001`
- UDF: 偏移 32768 处 `BEA01` / `NSR02` / `NSR03`
- 选取 ISO 内最大的 `.m2ts` / `.evo` 文件

## 磁盘缓存 (mmap)

```rust
pub struct DiskCache {
    file: File,
    mmap: MmapMut,          // memmap2
    bitmap: BitVec,          // bitvec
    chunk_size: u64,         // 默认 2MB
    path: PathBuf,
}
```

| 对比 | Dart（当前） | Rust（新） |
|---|---|---|
| 存储 | 内存 HashMap | 磁盘文件 mmap |
| 容量限制 | 1GB LRU 淘汰 | 等于文件大小，OS 管理 |
| 进程重启 | 全部丢失 | 可恢复 |
| seek | 淘汰旧 chunk | 磁盘保留，无需淘汰 |
| 内存占用 | 实际 1GB | OS 按需加载，RSS 低 |

移动端大文件（>4GB）：可分段 mmap 或按需映射窗口，实现细节层面处理。

## 启动预热 (Warmup Prefetch)

`create_session` 阶段，在后台预取播放器启动所需数据：

```
MP4/MOV:
  ├── 下载头部 32KB（ftyp box）
  ├── 扫描 moov 位置:
  │     moov 在头部 → 下载 moov 所在 chunk
  │     moov 在尾部 → 下载尾部 chunk
  └── 两端预取，播放器 probe 零等待

MKV/WebM: 下载头部 chunk（EBML header + SeekHead）
MPEG-TS:  下载头部 chunk（PAT/PMT）
其他:     头尾各 2MB
```

`create_session` 立即返回，预热异步执行。

## 下载引擎

### 两阶段预取
```
请求到达 stream_handler:
  阶段 1: 优先预取 ~2 分钟（基于 playback_bps），tokio::spawn 不阻塞
  阶段 2: await 当前请求所需 chunk 的 Notify
```

### Seek 检测
```
新请求偏移与上次差 > 4MB:
  - CancellationToken 取消非必需 inflight 下载
  - 围绕新位置启动预取
  - 磁盘缓存无需淘汰
```

### 并行控制
```
Semaphore(8):
  acquire → reqwest range → memcpy to mmap → bitmap[i]=1 → notify → release

中止检查点:
  - 下载前: CancellationToken.is_cancelled()
  - 下载后: 再次检查
```

### 认证刷新
```
401/403 → FRB callback → Dart 刷新凭据 → update_session_auth() → 重试
```

### 与 Dart 实现的改进

| 问题 | Dart | Rust |
|---|---|---|
| 并发控制 | `_scheduleChunk` 伪并发 | tokio Semaphore 真并发 |
| chunk 等待 | 40ms 轮询 hack | tokio Notify 精确唤醒 |
| 取消下载 | abort flag | CancellationToken 协作取消 |
| seek 淘汰 | LRU 淘汰 | 无需淘汰（磁盘） |

## FRB API

```rust
pub fn init_engine(config: EngineConfig) -> Result<EngineHandle>
pub async fn create_session(url: String, headers: HashMap<String,String>, file_key: String) -> Result<SessionInfo>
pub fn close_session(session_id: String) -> Result<()>
pub fn watch_stats(session_id: Option<String>) -> Stream<ProxyStats>
pub fn dispose() -> Result<()>
```

```rust
pub struct EngineConfig {
    pub chunk_size: u64,        // 默认 2MB
    pub max_concurrency: u32,   // 默认 8
    pub cache_dir: String,
}

pub struct SessionInfo {
    pub session_id: String,
    pub playback_url: String,   // http://127.0.0.1:{port}/stream/{session_id}
}

pub struct ProxyStats {
    pub download_bps: u64,
    pub serve_bps: u64,
    pub buffered_bytes_ahead: u64,
    pub active_workers: u32,
    pub cache_hit_rate: f64,
}
```

## Dart 侧改造

- `ProxyController` 缩减为 ~50 行 FRB 包装
- `player_page.dart` 改动极小：`createSession` / `watchStats` 签名基本不变
- 删除 `proxy_controller.dart` 约 1500 行代理逻辑
- 认证刷新通过 FRB 反向 callback 实现

## 平台支持

全平台：macOS / iOS / Android / Windows / Linux，通过 FRB 交叉编译。

## 关键依赖

### Rust
- `axum` — HTTP 服务器
- `reqwest` — HTTP 客户端
- `tokio` — 异步运行时
- `memmap2` — mmap
- `bitvec` — 分片位图
- `flutter_rust_bridge` — FRB 代码生成

### 未来扩展
- `librqbit` — BT 种子下载（预留 TorrentSource）
- UDF 解析库 — ISO 原盘支持（预留 IsoMediaSource）
