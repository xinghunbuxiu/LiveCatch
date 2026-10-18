# 抖音解析 — 上游对齐记录

迁入日期：2026-10-14  
LiveCatch 模块：`platforms/douyin/`

## 上游来源（按优先级）

| 源 | 链接 | 角色 |
|----|------|------|
| **主参考** | [ihmily/streamget](https://github.com/ihmily/streamget) `platforms/douyin/live_stream.py` + `ab_sign.py` | Web `webcast/room/web/enter` + a_bogus |
| **Rust 对照** | [it-coder/streamget-rs](https://github.com/it-coder/streamget-rs) `src/platforms/douyin/` | `ab_sign.rs` 原样迁入；enter 逻辑对齐 |

**不对齐 / 已移除**：rust-srec（`platforms-parser`）— LiveCatch 已不再依赖。短链展开在本模块 `expand.rs`。  
总览与新增流程见 [`../README.md`](../README.md)。

## 协议摘要

1. **房间 URL**：`https://live.douyin.com/{web_rid}`（短链 `v.douyin.com` → `expand.rs`）
2. **凭证**：`ttwid` cookie（优先用户 cookies；否则 POST `https://ttwid.bytedance.com/ttwid/union/register/`）
3. **进房 API**：`GET https://live.douyin.com/webcast/room/web/enter/?…&a_bogus=`  
   Query 含 `aid=6383`、`web_rid`、`app_name=douyin_web` 等（见 streamget `_get_web_stream_data`）
4. **签名**：`a_bogus = ab_sign(query, user_agent)`（`ab_sign.rs`，streamget-rs 纯 Rust 移植）
5. **状态**：`status == 2` 在播；`4` 已结束
6. **拉流**：`stream_url.flv_pull_url` / `hls_pull_url_map`；合并 `live_core_sdk_data` 的 ORIGIN
7. **播放 URL**：FLV 的 `https://` 改写为 `http://`（Android FFmpeg 无 TLS，同快手）

## 与 streamget 的刻意差异

| 点 | streamget | LiveCatch |
|----|-----------|-----------|
| 输出 | 选 1 条清晰度 | 全部 FLV → `StreamCandidate[]` |
| App reflow API | 有（短链/房间号） | 首版只做 **web enter**；短链先 expand 成 web_rid |
| VR / orientation=2 | 支持 | 首版跳过，走普通 orientation=1 |
| 平台名 | `抖音` | `douyin` |

## 复查清单

- [ ] `ab_sign.py` / streamget-rs `ab_sign.rs` 算法是否变更  
- [ ] `webcast/room/web/enter` 参数是否增减  
- [ ] ttwid 注册地址 / 风控提示字段  
- [ ] `flv_pull_url` 清晰度键名（FULL_HD1 / HD1 / …）  
- [ ] 是否必须强制 App reflow（web enter 失效时）

## 上游定位

```bash
curl -sL https://raw.githubusercontent.com/ihmily/streamget/main/streamget/platforms/douyin/live_stream.py | head
curl -sL https://raw.githubusercontent.com/it-coder/streamget-rs/master/src/platforms/douyin/ab_sign.rs | head
```
