# 直播平台解析（`platforms/`）

LiveCatch 房间解析只走本目录下的**原生后端**，**不再依赖** rust-srec / `platforms-parser`（旧称 strev）。

未匹配到任何后端的 URL → 直接返回「暂不支持该平台链接」。

## 当前已接入

| 目录 | `id` | 上游协议参考 |
|------|------|----------------|
| `douyin/` | `douyin` | ihmily/streamget + streamget-rs（web enter + a_bogus） |
| `kuaishou/` | `kuaishou` | ihmily/streamget `KwaiLiveStream` |
| `xiaohongshu/` | `xiaohongshu` | ihmily/streamget `RedNoteLiveStream` |

每个目录有独立的 [`UPSTREAM.md`](./douyin/UPSTREAM.md)，记录迁入日期、协议摘要、与上游差异、复查清单。

## 注册顺序

[`mod.rs`](./mod.rs) 里 `default_registry()`：**先匹配先赢**。新增平台插在列表前部；不要再加 catch-all。

```text
DouyinBackend → KuaishouBackend → XiaohongshuBackend
```

## 新增 / 对齐一个平台（标准流程）

1. **选上游**  
   优先 [ihmily/streamget](https://github.com/ihmily/streamget) 对应 `platforms/<site>/live_stream.py`；有 [streamget-rs](https://github.com/it-coder/streamget-rs) 则作 Rust 对照。勿默认去对齐 yt-dlp / rust-srec（后者已移除）。

2. **建目录**  
   `platforms/<name>/`：`mod.rs`（`PlatformBackend`）、`parse.rs`（纯解析 + 单测）、`UPSTREAM.md`（从现有平台抄模板）。

3. **实现要点**  
   - `matches(url)`：认领该站全部相关 host，错误路径给中文提示，避免落到「暂不支持」黑盒。  
   - `prepare_url`：短链展开、规范化房间 URL。  
   - `resolve` → [`ResolvedStream`](../types.rs)；播放地址 **`https://` 改写成 `http://`**（Android 自带 FFmpeg 仅 `--enable-protocol=http`）。  
   - 多清晰度用 [`ranked_candidates`](../rank.rs)；`priority` 越小越优先（听播偏瘦档）。

4. **注册**  
   `mod.rs`：`mod <name>;` + `default_registry` 插入 + 单测「本后端赢」。

5. **测与发**  
   ```bash
   cargo test -p lixh-stream-resolver --lib
   # 同步到解析机后：
   cargo build -p lixh-stream-resolver --bin lixh_resolve_server --release
   # 见 deploy/lixh-resolve/README.md
   ```

6. **改版复查**  
   打开该站 `UPSTREAM.md` 清单，对照上游 `live_stream.py` 的正则 / API / CDN 域名，更新「迁入日期」。

## UPSTREAM.md 建议章节

- 上游来源表（主参考 / Rust 对照 / 明确不对齐谁）  
- 协议摘要（URL → 拉页/API → 字段 → 播放 URL）  
- 与上游的刻意差异（输出多档、http 改写、平台 id 等）  
- 复查清单 + `curl` 定位上游文件的命令

## 历史说明

早期 LiveCatch 用 rust-srec（`platforms-parser`）做兜底提取。抖音 / 快手 / 小红书迁完后已删除该依赖，构建不再需要 `vendor/rust-srec` 或 GitHub 拉 srec。若再迁新站，只扩本目录原生模块即可。
