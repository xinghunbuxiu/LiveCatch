use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StreamCandidate {
    pub url: String,
    pub format: String,
    pub media_format: String,
    pub quality: String,
    pub bitrate: u64,
    pub codec: String,
    pub fps: f64,
    pub priority: u32,
    pub headers_needed: bool,
    pub audio_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResolvedStream {
    pub platform: String,
    pub site_url: String,
    pub title: String,
    pub artist: String,
    pub is_live: bool,
    pub streams: Vec<StreamCandidate>,
    pub headers: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, Default)]
pub struct ResolveOptions {
    pub cookies: Option<String>,
    pub extras: Option<Value>,
}
