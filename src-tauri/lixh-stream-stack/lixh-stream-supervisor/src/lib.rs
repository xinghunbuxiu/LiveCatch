use lixh_stream_resolver::StreamCandidate;
use serde::{Deserialize, Serialize};

#[derive(Debug,Clone,Serialize,Deserialize)]
pub struct PlaybackTelemetry{pub now_ms:i64,pub video_pts_ms:i64,pub input_buffer_ms:i64,pub video_frames:u64,pub dropped_frames:u64,pub reconnects:u64,pub decode_hw:i32}
#[derive(Debug,Clone,Serialize,Deserialize)]
pub enum SupervisorAction{Keep,Switch{index:usize,reason:String},ReResolve{reason:String}}
#[derive(Debug,Clone)]
pub struct StreamSupervisor{candidates:Vec<StreamCandidate>,current:Option<usize>,last_progress_ms:Option<i64>,last_progress_wall_ms:Option<i64>,last_observe_ms:Option<i64>,failed_candidates:Vec<usize>,consecutive_stalls:u32,failures:u32,stall_threshold_ms:i64,hard_stall_ms:i64,max_stalls:u32,max_failures:u32}
impl StreamSupervisor{
 pub fn new(candidates:Vec<StreamCandidate>)->Self{Self{candidates,current:None,last_progress_ms:None,last_progress_wall_ms:None,last_observe_ms:None,failed_candidates:Vec::new(),consecutive_stalls:0,failures:0,stall_threshold_ms:1200,hard_stall_ms:3000,max_stalls:3,max_failures:2}}
 pub fn set_current(&mut self,index:usize){self.current=Some(index);self.last_progress_ms=None;self.last_progress_wall_ms=None;self.last_observe_ms=None;self.consecutive_stalls=0;self.failures=0}
 pub fn current(&self)->Option<usize>{self.current}
 pub fn select_initial(&self)->Option<usize>{self.candidates.iter().enumerate().filter(|(_,c)|!c.audio_only).min_by_key(|(i,c)|(c.priority,std::cmp::Reverse(c.bitrate),*i)).map(|(i,_)|i)}
 pub fn observe(&mut self,t:PlaybackTelemetry)->SupervisorAction{
  if self.current.is_none(){return SupervisorAction::ReResolve{reason:"no current candidate".into()}}
  let elapsed=self.last_observe_ms.map(|v|(t.now_ms-v).max(0)).unwrap_or(0);self.last_observe_ms=Some(t.now_ms);
  let progressed=t.video_pts_ms>=0&&self.last_progress_ms.map(|p|t.video_pts_ms>p).unwrap_or(true);
  if progressed{self.last_progress_ms=Some(t.video_pts_ms);self.last_progress_wall_ms=Some(t.now_ms);self.consecutive_stalls=0;return SupervisorAction::Keep}
  let stalled=self.last_progress_wall_ms.map(|v|(t.now_ms-v).max(0)).unwrap_or(elapsed);
  if t.input_buffer_ms>=self.hard_stall_ms||stalled>=self.hard_stall_ms{return self.failure_action("hard stall")}
  if t.input_buffer_ms>=self.stall_threshold_ms||stalled>=self.stall_threshold_ms{self.consecutive_stalls+=1;if self.consecutive_stalls>=self.max_stalls{return self.failure_action("repeated stall")}}
  SupervisorAction::Keep
 }
 pub fn report_failure(&mut self,reason:&str)->SupervisorAction{self.failures+=1;self.failure_action(reason)}
 fn failure_action(&mut self,reason:&str)->SupervisorAction{
  if self.failures>=self.max_failures{return SupervisorAction::ReResolve{reason:reason.into()}}
  if let Some(current)=self.current{if !self.failed_candidates.contains(&current){self.failed_candidates.push(current)}}
  let next=self.candidates.iter().enumerate().find(|(i,c)|Some(*i)!=self.current&&!c.audio_only&&!self.failed_candidates.contains(i)).map(|(i,_)|i);
  match next{Some(index)=>SupervisorAction::Switch{index,reason:reason.into()},None=>SupervisorAction::ReResolve{reason:reason.into()}}
 }
}
impl PlaybackTelemetry{pub fn from_ffmpeg(now_ms:i64,stats:&lixh_player_core::LixhStats)->Self{Self{now_ms,video_pts_ms:stats.last_video_pts_ms,input_buffer_ms:stats.input_buffer_ms,video_frames:stats.video_frames,dropped_frames:stats.dropped_frames,reconnects:stats.reconnects,decode_hw:stats.decode_hw}}}
#[cfg(test)]mod tests{
 use super::*;
 fn candidate(url:&str)->StreamCandidate{StreamCandidate{url:url.into(),format:"flv".into(),media_format:"live".into(),quality:"auto".into(),bitrate:0,codec:String::new(),fps:0.0,priority:0,headers_needed:false,audio_only:false}}
 fn telemetry(now_ms:i64,pts:i64)->PlaybackTelemetry{PlaybackTelemetry{now_ms,video_pts_ms:pts,input_buffer_ms:0,video_frames:1,dropped_frames:0,reconnects:0,decode_hw:1}}
 #[test]fn failed_candidate_is_current_candidate(){let mut s=StreamSupervisor::new(vec![candidate("a"),candidate("b"),candidate("c")]);s.set_current(0);assert!(matches!(s.report_failure("decode error"),SupervisorAction::Switch{index:1,..}));assert!(matches!(s.report_failure("decode error"),SupervisorAction::Switch{index:2,..}))}
 #[test]fn stall_timer_uses_time_since_last_video_progress(){let mut s=StreamSupervisor::new(vec![candidate("a"),candidate("b")]);s.set_current(0);assert!(matches!(s.observe(telemetry(0,100)),SupervisorAction::Keep));assert!(matches!(s.observe(telemetry(800,100)),SupervisorAction::Keep));assert!(matches!(s.observe(telemetry(1600,100)),SupervisorAction::Keep));assert!(matches!(s.observe(telemetry(2800,100)),SupervisorAction::Switch{..}))}
}