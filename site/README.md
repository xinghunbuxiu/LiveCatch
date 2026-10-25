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

配色取自参考站（syncrozero.com）的设计语言：

| Token | 值 | 用途 |
|---|---|---|
| `--bg` | `#05070a` | 页面底色（近黑） |
| `--panel` | `#10110e` | 卡片/面板 |
| `--ink` | `#f2f2e9` | 主文字（暖白） |
| `--ink-dim` | `#a5a699` | 次要文字 |
| `--accent` | `#00c878` | 强调色（青绿） |

排版用等宽字体做小标签（`01 / PRODUCT`、`A / 01`），正文用系统中文字体栈。
所有动效都尊重 `prefers-reduced-motion`。

## 内容边界

页面上的性能数字（`~90ms` 音频缓冲、`0` 丢帧、`MediaCodec` 硬解）来自本项目
在华为 AGS6-W00 / Android 12 上的实测。换机型或换版本后应重新测量再更新，
不要把历史数字当成普遍承诺。
