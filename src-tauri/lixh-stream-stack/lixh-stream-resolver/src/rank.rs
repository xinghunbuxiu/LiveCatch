use crate::types::StreamCandidate;
use std::collections::HashSet;

pub fn ranked_candidates(streams: &[StreamCandidate]) -> Vec<StreamCandidate> {
    let mut seen = HashSet::new();
    let mut candidates: Vec<_> = streams
        .iter()
        .filter(|s| !s.url.trim().is_empty())
        .filter(|s| seen.insert(s.url.clone()))
        .cloned()
        .collect();
    candidates.sort_by(|a, b| {
        a.audio_only
            .cmp(&b.audio_only)
            .then_with(|| a.priority.cmp(&b.priority))
            .then_with(|| b.bitrate.cmp(&a.bitrate))
            .then_with(|| b.fps.total_cmp(&a.fps))
            .then_with(|| a.quality.cmp(&b.quality))
            .then_with(|| a.url.cmp(&b.url))
    });
    candidates
}

pub fn best_candidate(streams: &[StreamCandidate]) -> Option<StreamCandidate> {
    ranked_candidates(streams).into_iter().next()
}
