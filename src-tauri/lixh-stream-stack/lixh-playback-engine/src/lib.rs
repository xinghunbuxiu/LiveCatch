pub mod native_surface;
use lixh_stream_resolver::{ResolvedStream,StreamCandidate};
use lixh_stream_supervisor::{PlaybackTelemetry,StreamSupervisor,SupervisorAction};
use std::time::{SystemTime,UNIX_EPOCH};
#[derive(Debug)]pub enum EngineError{NoCandidate,Backend(String)}
pub trait PlaybackBackend:Send+'static{type Telemetry:Clone+Send+'static;fn open(&mut self,url:&str)->Result<(),String>;fn start(&mut self)->Result<(),String>;fn stop(&mut self)->Result<(),String>;fn telemetry(&self)->Self::Telemetry;fn to_supervisor_telemetry(&self,now_ms:i64,t:&Self::Telemetry)->PlaybackTelemetry;}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum EngineState{Idle,Playing,ReResolving,Stopped}
#[derive(Debug,Clone)]pub enum EngineEvent{Started{index:usize},Switched{from:Option<usize>,to:usize,reason:String},ReResolve{reason:String},Stopped}
pub struct PlaybackEngine<B:PlaybackBackend>{backend:B,supervisor:StreamSupervisor,candidates:Vec<StreamCandidate>,current_url:Option<String>,state:EngineState}
impl<B:PlaybackBackend> PlaybackEngine<B>{
 pub fn from_resolved(backend:B,resolved:ResolvedStream)->Result<Self,EngineError>{if resolved.streams.is_empty(){return Err(EngineError::NoCandidate)}let candidates=resolved.streams;Ok(Self{backend,supervisor:StreamSupervisor::new(candidates.clone()),candidates,current_url:None,state:EngineState::Idle})}
 pub fn backend(&self)->&B{&self.backend} pub fn backend_mut(&mut self)->&mut B{&mut self.backend} pub fn state(&self)->EngineState{self.state}
 pub fn start(&mut self)->Result<EngineEvent,EngineError>{let index=self.supervisor.select_initial().ok_or(EngineError::NoCandidate)?;self.start_candidate(index)}
 pub fn start_candidate(&mut self,index:usize)->Result<EngineEvent,EngineError>{self.start_candidate_with_reason(index,"initial/start")}
 fn start_candidate_with_reason(&mut self,index:usize,reason:&str)->Result<EngineEvent,EngineError>{let url=self.candidates.get(index).ok_or(EngineError::NoCandidate)?.url.clone();let previous=self.supervisor.current();self.backend.stop().map_err(EngineError::Backend)?;self.backend.open(&url).map_err(EngineError::Backend)?;self.backend.start().map_err(EngineError::Backend)?;self.supervisor.set_current(index);self.current_url=Some(url);self.state=EngineState::Playing;Ok(match previous{Some(from)if from!=index=>EngineEvent::Switched{from:Some(from),to:index,reason:reason.into()},_=>EngineEvent::Started{index}})}
 pub fn poll(&mut self)->Result<(SupervisorAction,Option<EngineEvent>),EngineError>{let now=unix_ms();let raw=self.backend.telemetry();let t=self.backend.to_supervisor_telemetry(now,&raw);let action=self.supervisor.observe(t);let event=match &action{SupervisorAction::Switch{index,reason}=>Some(self.start_candidate_with_reason(*index,reason)?),SupervisorAction::ReResolve{reason}=>{self.backend.stop().map_err(EngineError::Backend)?;self.state=EngineState::ReResolving;Some(EngineEvent::ReResolve{reason:reason.clone()})},SupervisorAction::Keep=>None};Ok((action,event))}
 pub fn stop(&mut self)->Result<EngineEvent,EngineError>{self.backend.stop().map_err(EngineError::Backend)?;self.state=EngineState::Stopped;Ok(EngineEvent::Stopped)}
 pub fn current_url(&self)->Option<&str>{self.current_url.as_deref()} pub fn current_index(&self)->Option<usize>{self.supervisor.current()} pub fn candidates(&self)->&[StreamCandidate]{&self.candidates}
}
fn unix_ms()->i64{SystemTime::now().duration_since(UNIX_EPOCH).map(|d|d.as_millis()as i64).unwrap_or(0)}