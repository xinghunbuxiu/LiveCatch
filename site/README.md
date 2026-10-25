# LiveCatch 官网

单文件静态站，无构建、无外部依赖，可直接放到任意静态托管。

```
site/index.html     # 全部内容（内联 CSS/JS）
```

## 本地预览

```bash
open site/index.html          # 或任意静态服务器
python3 -m http.server 8080 -d site
```

## 部署

把 `site/` 整个目录上传到静态托管即可（nginx / OSS / Cloudflare Pages / Vercel）。
nginx 最小配置：

```nginx
location / {
    root /var/www/livecatch-site;
    index index.html;
    try_files $uri $uri/ /index.html;
}
```

## 上线前要替换

| 位置 | 现在 | 要改成 |
|---|---|---|
| 页脚备案号 | `ICP 备案号待填` / `公安备案号待填` | 真实备案编号（未备案不要上线） |
| `<script>` 里的 `DOWNLOADS` | 全空 | Android / Windows / macOS 的下载地址 |
| `<meta property="og:*">` | 无图 | 加 `og:image` 指向 1200×630 分享图 |

`DOWNLOADS` 留空时按钮会显示"即将开放"，不会产生死链。

## 设计说明

浅色纸质编辑风：米白纸底 + 单一朱红强调，衬线标题配无衬线正文，
等宽字体只用于小标签。刻意与常见"黑底 + 霓虹绿"的科技站区分开。

| Token | 值 | 用途 |
|---|---|---|
| `--paper` | `#f7f4ee` | 页面底色（暖米白，叠两层点阵模拟纸纹） |
| `--paper-2` | `#efeae0` | 次级面板 |
| `--rule` | `#ddd5c7` | 分隔线 |
| `--ink` | `#1b1917` | 主文字 |
| `--ink-2` | `#57524b` | 正文/次要 |
| `--ink-3` | `#8d8579` | 标签/注释 |
| `--accent` | `#c8402f` | 强调色（朱红） |

字体栈：

- 标题/引文：`Songti SC → Source Han Serif SC → Noto Serif CJK SC → SimSun → Georgia`
- 正文：`PingFang SC → Hiragino Sans GB → Microsoft YaHei → system-ui`
- 小标签：等宽（`SF Mono / Menlo / Consolas`）

版式要点：

- 章节头用 `120px | 1fr` 两栏网格，编号在左、标题在右
- 功能列表用带编号的横线行（`A / 01`），不用卡片阴影
- 播放方式三栏用竖线分隔，首栏标"默认"
- 所有圆角为 0，靠 1px 细线建立层次

动效仅做滚动淡入，且 `prefers-reduced-motion: reduce` 时完全跳过。

## 内容边界

页面上的性能数字（`~90ms` 音频缓冲、`0` 丢帧、`MediaCodec` 硬解）来自本项目
在华为 AGS6-W00 / Android 12 上的实测。换机型或换版本后应重新测量再更新，
不要把历史数字当成普遍承诺。
