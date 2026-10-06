use std::sync::Arc;
use std::thread::{self,JoinHandle};
#[derive(Debug)]pub enum HostError{AlreadyPlaying,NotOpened,JoinFailed,Backend(String)}
pub trait NativePlayer:Send+Sync+'static{fn open(&self,url:&str)->Result<(),HostError>;fn play_blocking(&self)->Result<(),HostError>;fn stop(&self)->Result<(),HostError>;}
pub struct PlayerHost<P:NativePlayer>{player:Arc<P>,play_thread:Option<JoinHandle<Result<(),HostError>>>}
impl<P:NativePlayer> PlayerHost<P>{
 pub fn new(player:P)->Self{Self{player:Arc::new(player),play_thread:None}}
 pub fn player(&self)->Arc<P>{Arc::clone(&self.player)}
 pub fn open(&mut self,url:&str)->Result<(),HostError>{self.stop_and_join()?;self.player.open(url)}
 pub fn start(&mut self)->Result<(),HostError>{if self.play_thread.is_some(){return Err(HostError::AlreadyPlaying)}let player=Arc::clone(&self.player);self.play_thread=Some(thread::Builder::new().name("lixh-player-play".into()).spawn(move||player.play_blocking()).map_err(|e|HostError::Backend(format!("spawn failed: {e}")))?);Ok(())}
 pub fn stop_and_join(&mut self)->Result<(),HostError>{self.player.stop()?;if let Some(h)=self.play_thread.take(){h.join().map_err(|_|HostError::JoinFailed)??;}Ok(())}
 pub fn is_playing(&self)->bool{self.play_thread.is_some()}
}
impl<P:NativePlayer> Drop for PlayerHost<P>{fn drop(&mut self){let _=self.stop_and_join();}}
pub struct CorePlayerAdapter{player:lixh_player_core::Player}
impl CorePlayerAdapter{pub fn new(callbacks:lixh_player_core::LixhCallbacks)->Result<Self,HostError>{let player=lixh_player_core::Player::new(callbacks).map_err(HostError::Backend)?;Ok(Self{player})}pub fn stats(&self)->lixh_player_core::LixhStats{self.player.stats()}}
impl NativePlayer for CorePlayerAdapter{
 fn open(&self,url:&str)->Result<(),HostError>{self.player.open(url).map_err(HostError::Backend)}
 fn play_blocking(&self)->Result<(),HostError>{self.player.play().map_err(HostError::Backend)}
 fn stop(&self)->Result<(),HostError>{self.player.stop();Ok(())}
}