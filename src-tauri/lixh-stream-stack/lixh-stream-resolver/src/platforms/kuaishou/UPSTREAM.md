# 快手解析 — 上游对齐记录

迁入日期：2026-10-14  
LiveCatch 模块：`platforms/kuaishou/`

## 上游来源（按优先级）

| 源 | 链接 | 角色 |
|----|------|------|
| **主参考** | [ihmily/streamget](https://github.com/ihmily/streamget) `streamget/platforms/kuaishou/live_stream.py` | 成熟 Python 实现，协议真相 |
| **Rust 对照** | [it-coder/streamget-rs](https://github.com/it-coder/streamget-rs) `src/platforms/kuaishou/live_stream.rs` | 同逻辑 Rust 移植（0★，只作对照） |
| 备选旧路 | [go-olive/tv](https://github.com/go-olive/tv) `kuaishou.go` | GraphQL `LiveDetail`，需 cookie，2022 停更 |

**不对齐**：yt-dlp / Streamlink；rust-srec 已从 LiveCatch 移除。  
总览与新增流程见 [`../README.md`](../README.md)。

## 协议摘要（与 streamget 对齐）

1. **房间 URL**：`https://live.kuaishou.com/u/{principalId}`  
   - 也接受 `/profile/{id}`（live 或 www），内部规范成 `/u/{id}` 再拉页（profile 页常无 `playUrls`）  
   - 任意 `kuaishou.com` host 由本后端认领，错误路径给中文提示
2. **可选预检**（有 cookie 时）：  
   `GET https://live.kuaishou.com/live_api/baseuser/userinfo/byid?...&principalId={id}`  
   - `data.result == 2` → 风控  
   - `data.userInfo.living == false` → 未开播，可直接返回
3. **拉流主路径**：`GET` 房间页 HTML，解析  
   `window.__INITIAL_STATE__=...;(function(){var s;`  
   （streamget 正则带前导空格；线上常见 `<script>window.__INITIAL_STATE__=`，**空格必须可选**）  
   再截取 `{"liveStream"…},"gameInfo` 片段为 JSON。
4. **播放地址**：`liveStream.playUrls.h264.adaptationSet.representation[]`  
   （无 `h264` 键时退回 `playUrls[0].adaptationSet.representation`）  
   每项含 `url` / `bitrate` 等 → **仅 FLV**（streamget 文档：无 HLS）。
5. **请求头**：桌面 Chrome UA + `Referer: https://live.kuaishou.com/`（streamget 写死了某个 profile，我们改成站点根，避免绑死主播）。

## 与 streamget 的刻意差异

| 点 | streamget | LiveCatch |
|----|-----------|-----------|
| 输出 | 按清晰度选 1 条 FLV | 全部 representation → `StreamCandidate[]`，由 `ranked_candidates` 排序 |
| Referer | `…/profile/cym030000` | `https://live.kuaishou.com/`（不下发 Origin） |
| 无 cookie | Python 缩进易踩坑；rs 版始终拉 HTML | 与 **streamget-rs** 一致：始终拉 HTML |
| Cookie | 字符串 | `ResolveCtx.cookies` |
| 平台名 | `快手直播` | `kuaishou`（机器可读；UI 可另映射） |
| 播放 URL | 页面里多为 `https://…yximgs.com/….flv` | **改写为 `http://`**：Android 自带 FFmpeg 仅 `--enable-protocol=http`，无 TLS，否则客户端 `open_failed` |

## 复查清单（上游改版时）

- [ ] `live_stream.py` 里 `__INITIAL_STATE__` / `gameInfo` 正则是否变了（注意前导空白）  
- [ ] `playUrls` 是否仍走 `h264.adaptationSet.representation`  
- [ ] `userinfo/byid` 是否仍可用、风控码是否仍为 `result == 2`  
- [ ] 是否开始要求强制 cookie / 签名参数  
- [ ] 对照更新本文件「迁入日期」与下方 git 线索

## 上游定位线索（复查时用）

```bash
# streamget 快手文件
curl -sL https://raw.githubusercontent.com/ihmily/streamget/main/streamget/platforms/kuaishou/live_stream.py | head

# streamget-rs
curl -sL https://raw.githubusercontent.com/it-coder/streamget-rs/master/src/platforms/kuaishou/live_stream.rs | head
```

本地实现入口：`mod.rs`（`KuaishouBackend`）、`parse.rs`（HTML → play list）。
