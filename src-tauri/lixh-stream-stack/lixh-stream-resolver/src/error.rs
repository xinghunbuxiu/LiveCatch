//! Map nested extractor / transport errors into short UI-facing Chinese tips.

use anyhow::anyhow;

pub fn map_resolve_error(err: anyhow::Error) -> anyhow::Error {
    let full = format!("{err:#}");
    if full.contains("服务繁忙") {
        return anyhow!("抖音接口繁忙（请确认直播间正在开播后稍后重试）");
    }
    if full.contains("StreamerNotFound") || full.contains("streamer not found") {
        return anyhow!("未找到该直播间，请检查链接");
    }
    if full.contains("直播已结束") || full.contains("not live") {
        return anyhow!("直播已结束或不在播");
    }
    if full.contains("HTML error page") || full.contains("rate limiting or blocking") {
        return anyhow!("抖音接口拒绝请求，请稍后重试或更换网络");
    }
    if full.contains("Failed to extract ttwid") {
        return anyhow!("获取抖音凭证失败，请检查网络后重试");
    }
    if full.contains("展开抖音短链")
        || full.contains("短链未返回")
        || full.contains("响应中无 web_rid")
    {
        return anyhow!("抖音短链展开失败，请改用 live.douyin.com 直播间号");
    }
    if full.contains("unsupported extractor") || full.contains("UnsupportedExtractor") {
        return anyhow!("暂不支持该平台链接");
    }
    if full.contains("快手疑似封禁") || full.contains("快手账号异常") {
        return anyhow!("{full}");
    }
    if full.contains("快手") {
        let leaf = full.rsplit(": ").next().unwrap_or(&full).trim();
        return anyhow!("{leaf}");
    }
    // Keep the cause chain for transport failures (cert/DNS/reset), not just the leaf.
    if full.contains("error sending request")
        || full.contains("connection")
        || full.contains("timed out")
        || full.contains("dns error")
        || full.contains("certificate")
        || full.contains("tls")
    {
        return anyhow!("网络请求失败: {full}");
    }
    // Drop leading "resolve:" / "extract stream metadata:" noise for UI.
    let leaf = full.rsplit(": ").next().unwrap_or(&full).trim();
    if leaf != full {
        anyhow!("{leaf}")
    } else {
        err
    }
}

/// Whether a resolve failure is worth a short retry (busy / transport blips).
#[allow(dead_code)] // used when backends add attempt loops
pub fn is_retryable_extract(err: &anyhow::Error) -> bool {
    let msg = format!("{err:#}").to_ascii_lowercase();
    msg.contains("服务繁忙")
        || msg.contains("繁忙")
        || msg.contains("rate limit")
        || msg.contains("timeout")
        || msg.contains("timed out")
        || msg.contains("connection")
        || msg.contains("temporarily")
}
