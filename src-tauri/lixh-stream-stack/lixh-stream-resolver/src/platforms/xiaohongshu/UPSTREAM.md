# 小红书解析 — 上游对齐记录

迁入日期：2026-10-14  
LiveCatch 模块：`platforms/xiaohongshu/`

## 上游来源（按优先级）

| 源 | 链接 | 角色 |
|----|------|------|
| **主参考** | [ihmily/streamget](https://github.com/ihmily/streamget) `streamget/platforms/rednote/live_stream.py` | 成熟 Python 实现，协议真相 |
| **Rust 对照** | [it-coder/streamget-rs](https://github.com/it-coder/streamget-rs) `src/platforms/rednote/live_stream.rs` | 同逻辑 Rust 移植 |

**不对齐**：yt-dlp；rust-srec 已从 LiveCatch 移除（上游本无小红书 extractor）。  
总览与新增流程见 [`../README.md`](../README.md)。

## 协议摘要（与 streamget 对齐）

1. **URL**：`xiaohongshu.com` / `xhslink.com` / `xhs.cn`  
   - `xhslink.com` 短链先跟 Location 展开  
   - `user_id`：`/user/profile/{id}` 或 query `host_id`
2. **拉页**：移动端 UA + `xy-common-params` + `Referer: https://app.xhs.cn/`
3. **解析**：HTML 里 `window.__INITIAL_STATE__=…` → JSON（`undefined` → `null`）  
   - `liveStream.liveStatus == "success"`  
   - `roomData.roomInfo.roomTitle` 不含「回放」  
   - `roomInfo.deeplink` 取 `host_nickname`、`flvUrl`
4. **播放地址**：从 `flvUrl` 路径 `live/{roomId}.…` 抽出 roomId，拼  
   - `http://live-source-play.xhscdn.com/live/{roomId}.flv`  
   - `http://live-source-play.xhscdn.com/live/{roomId}.m3u8`  
   （上游已用 plain HTTP，契合 Android FFmpeg 无 TLS）
5. **未开播**：回落个人页抓 `@昵称 的个人主页`，`is_live=false`、空 streams。

## 与 streamget 的刻意差异

| 点 | streamget | LiveCatch |
|----|-----------|-----------|
| 输出 | 单条 flv/m3u8 | FLV + HLS → `StreamCandidate[]`，`ranked_candidates` |
| `__INITIAL_STATE__` 正则 | 两侧强制空格 | 空白可选，并以 `</script>` / `;` 收尾（防改版） |
| 平台名 | `小红书` | `xiaohongshu`（机器可读） |
| 认领范围 | RedNote 类 | 任意 xhs host，未开播返回空 streams |

## 复查清单（上游改版时）

- [ ] `live_stream.py` 里 `__INITIAL_STATE__` / `liveStatus` / `deeplink` 字段是否变了  
- [ ] CDN 域名是否仍为 `live-source-play.xhscdn.com`  
- [ ] 移动端 UA / `xy-common-params` 是否仍够用  
- [ ] 对照更新本文件「迁入日期」

## 上游定位线索

```bash
curl -sL https://raw.githubusercontent.com/ihmily/streamget/main/streamget/platforms/rednote/live_stream.py | head
curl -sL https://raw.githubusercontent.com/it-coder/streamget-rs/master/src/platforms/rednote/live_stream.rs | head
```
