import { invoke } from '@tauri-apps/api/core';
import { register, unregister } from '@tauri-apps/plugin-global-shortcut';
import { getCurrentWindow, LogicalSize } from '@tauri-apps/api/window';
import './style.css';

const app=document.querySelector('#app');
const state={
  roomUrl:'',liveTaskId:null,liveGeneration:0,livePhase:'idle',playing:false,busy:false,
  streamUrl:'',protocol:'-',cdn:'-',health:'待连接',latency:null,playback:null,
  events:[],maxEvents:80,playerError:'',backend:'ffmpeg',videoMode:false
};
let dockTimer=null,pumpRaf=null;
const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
const time=()=>new Date().toLocaleTimeString('zh-CN',{hour12:false});
function addEvent(kind,phase,message,level=''){state.events.push({time:time(),kind,phase,message,level});if(state.events.length>state.maxEvents)state.events.splice(0,state.events.length-state.maxEvents);}
function generationFromResult(r){return Number((r?.message||'').match(/generation=(\d+)/)?.[1]||0);}
function markLiveEnded(message){state.livePhase='ended';state.health=String(message||'直播已结束');state.playing=false;state.playerError='';destroyEmbedPlayer();stopDockLoop();invoke('stop_player').catch(()=>{});}
function isEnded(){return state.livePhase==='ended'||/直播已结束/.test(state.health||'')||/直播已结束/.test(state.playerError||'');}
function statusText(){if(state.playing)return 'LIVE';if(['reconnecting','probing','resolving','starting_player','starting','binding'].includes(state.livePhase))return '连接中';if(isEnded())return '已结束';if(state.livePhase==='error'||state.livePhase==='player_exit')return '错误';return '待播放';}
function playbackText(){const p=state.playback;if(!p)return state.playing?'FFmpeg':'—';if(p.stalled)return '卡顿';if(p.buffering)return '缓冲';if(p.ipc_ok===false)return 'IPC异常';return '正常';}
function buffer(){return state.playback?.buffer_sec==null?'-':`${Number(state.playback.buffer_sec).toFixed(2)}s`;}
function playbackSpeed(){return state.playback?.speed==null?'-':`${Number(state.playback.speed).toFixed(2)}x`;}
function latencyMode(){const m=state.playback?.latency_mode;return m==='catchup'?'追赶':m==='recovery'?'恢复':m==='ipc-degraded'?'IPC降级':m==='seek'?'跳边缘':'低延迟';}
function stopDockLoop(){if(dockTimer){clearInterval(dockTimer);dockTimer=null;}if(pumpRaf){cancelAnimationFrame(pumpRaf);pumpRaf=null;}window.removeEventListener('resize',syncNativeDock);}
function startEmbedPump(){if(pumpRaf)return;const loop=()=>{pumpRaf=requestAnimationFrame(loop);if(state.playing)invoke('player_embed_tick').catch(()=>{});};pumpRaf=requestAnimationFrame(loop);}
function destroyEmbedPlayer(){const screen=document.querySelector('.screen');if(screen){screen.style.removeProperty('--src-ar');screen.style.removeProperty('--screen-w');}}
async function fitAppWindow(mode){const target=mode==='force-landscape'||mode==='landscape'?'landscape':'portrait';const size=target==='landscape'?{width:1100,height:760}:{width:820,height:760};try{await getCurrentWindow().setMinSize(new LogicalSize(640,560));await getCurrentWindow().setSize(new LogicalSize(size.width,size.height));}catch(_){}}
async function syncNativeDock(){
  if(!state.playing)return;
  const el=document.querySelector('.screen'),stage=document.querySelector('.stage');
  if(!el||!stage)return;
  const r=el.getBoundingClientRect(),sr=stage.getBoundingClientRect();
  let x=Math.max(sr.left,r.left),y=Math.max(sr.top,r.top,56),right=Math.min(sr.right,r.right),bottom=Math.min(sr.bottom,r.bottom);
  const w=Math.round(Math.max(0,right-x)),h=Math.round(Math.max(0,bottom-y));
  if(w<80||h<120)return;
  try{await invoke('dock_native_player',{x:Math.round(x),y:Math.round(y),w,h});}catch(_){}
}
function startDockLoop(){stopDockLoop();if(!state.playing)return;syncNativeDock();startEmbedPump();dockTimer=setInterval(()=>void syncNativeDock(),250);window.addEventListener('resize',syncNativeDock);}
function screenHtml(){if(!state.playing)return `<div class="empty"><div class="empty-mark">▶</div><div class="empty-title">${isEnded()?'直播已结束':'粘贴链接开始播放'}</div><div class="empty-sub">${esc(state.playerError||state.health||'低延迟 FFmpeg 播放器')}</div></div>`;return `<div class="native-stage"><div class="native-veil"><span class="live-pill"><span class="dot"></span> LIVE</span><span>${esc(state.protocol)} · 源延迟 ${state.latency??'-'} ms</span><span>缓冲 ${buffer()} · ${latencyMode()} · ${playbackSpeed()}</span></div></div>`;}
function render(){
  app.innerHTML=`<div class="app-shell ${state.videoMode?'video-mode':''}">
    <header class="topbar">
      <div class="brand"><span class="brand-mark">LC</span><span>LiveCatch</span></div>
      <div class="url-bar"><input id="url" aria-label="直播链接" placeholder="粘贴直播链接" value="${esc(state.roomUrl)}"><button class="play-btn" id="start" ${state.busy?'disabled':''}>${state.busy?'连接中…':'播放'}</button><button class="stop-btn" id="stop" ${state.playing||state.busy?'':'disabled'}>停止</button></div>
      <div class="status"><span class="dot ${state.playing?'live':''}"></span>${statusText()}</div>
    </header>
    <main class="stage"><section class="player-wrap"><div class="screen">${screenHtml()}</div></section>
      <footer class="player-bar"><span>🔊 声音：开启</span><span>延迟：${state.latency==null?'—':esc(state.latency+' ms')}</span><span>缓冲：${buffer()}</span><span>播放：${playbackText()}</span><button id="video-mode" class="mode-btn ${state.videoMode?'on':''}">${state.videoMode?'退出视频模式':'视频模式'}</button></footer>
    </main>
  </div>`;
  const u=document.querySelector('#url');u?.addEventListener('input',e=>state.roomUrl=e.target.value);u?.addEventListener('keydown',e=>{if(e.key==='Enter')start();});
  document.querySelector('#start')?.addEventListener('click',start);document.querySelector('#stop')?.addEventListener('click',stop);
  document.querySelector('#video-mode')?.addEventListener('click',async()=>{state.videoMode=!state.videoMode;await fitAppWindow(state.videoMode?'force-landscape':'force-portrait');render();});
  if(state.playing)queueMicrotask(startDockLoop);else stopDockLoop();
}
async function start(){
  const input=document.querySelector('#url');state.roomUrl=(input?.value??state.roomUrl).trim();
  if(!state.roomUrl)return alert('请输入直播间地址');
  if(state.busy)return;
  // 看播不强制登录；登录仅用于发弹幕
  state.pendingStartAfterLogin=false;
  destroyEmbedPlayer();
  stopDockLoop();
  state.busy=true;state.playing=false;state.liveTaskId=null;state.liveGeneration=0;state.livePhase='starting';state.health='任务提交中';state.candidates=[];state.playerError='';state.streamUrl='';state.videoPortrait=true;state.muted=true;addEvent('LIVE','starting','提交 FFmpeg 同窗内嵌');
  fitAppWindow('force-portrait');
  render();
  // 先把监视器洞坐标写入后端，FFmpeg 洞在开播前就位
  try{
    const topMin=56;
    const danmaku=0;
    const hole=document.querySelector('.screen')||document.querySelector('.stage-main');
    const stage=document.querySelector('.stage');
    if(hole && stage){
      const r=hole.getBoundingClientRect();
      const sr=stage.getBoundingClientRect();
      let x=Math.max(sr.left, r.left);
      let y=Math.max(sr.top, r.top, topMin);
      let right=Math.min(sr.right, r.right, window.innerWidth);
      let bottom=Math.min(sr.bottom, r.bottom);
      let w=Math.round(Math.max(0, right-x));
      let h=Math.round(Math.max(0, bottom-y));
      x=Math.round(x); y=Math.round(y);
      if(w>=80 && h>=120){
        await invoke('dock_native_player',{x,y,w,h});
      }
    }
  }catch(_){}
  try{
    const r=await invoke('start_live',{roomUrl:state.roomUrl});
    state.liveTaskId=r.task_id;state.liveGeneration=generationFromResult(r);state.livePhase='queued';state.health='任务已入队';
    addEvent('LIVE','queued',`task=${r.task_id} generation=${state.liveGeneration}`);
    // 已登录时后端 start_live 会并行进房绑定；标记避免 session-updated 再绑一次
  }catch(e){
    state.livePhase='error';state.health=String(e);addEvent('LIVE','error',String(e),'err');alert('启动失败：'+e);
  }finally{state.busy=false;render();}
}

async function stop(){
  state.busy=false;destroyEmbedPlayer();stopDockLoop();
  try{await invoke('stop_player');await invoke('clear_room')}catch(e){addEvent('LIVE','stop_error',String(e),'warn')}
  state.playing=false;state.liveTaskId=null;state.liveGeneration=0;state.livePhase='stopped';state.health='已停止';state.streamUrl='';state.playback=null;state.playerError='';state.videoPortrait=true;
  addEvent('LIVE','stopped','已停止');render();
  fitAppWindow('portrait');
}

listen('live-event',e=>{
  const x=e.payload||{};
  // Binding progress may arrive before task_id is assigned — never hijack an active play.
  if(x.phase==='binding'){
    if(state.playing || ['resolving','probing','starting_player','playing'].includes(state.livePhase)){
      
      render();
      return;
    }
    state.livePhase='binding';
    state.health=x.message||'正在进入直播间…';
    
    addEvent('LIVE','enter_room',x.message||'','warn');
    render();
    return;
  }
  if(!state.liveTaskId||x.task_id!==state.liveTaskId)return;
  if(state.liveGeneration&&Number(x.generation)!==Number(state.liveGeneration))return;
  state.livePhase=x.phase||state.livePhase;
  state.health=x.message||state.health;
  if(x.candidates?.length)state.candidates=x.candidates;
  if(x.stream_url)state.streamUrl=x.stream_url;
  if(x.protocol)state.protocol=x.protocol;
  if(x.cdn)state.cdn=x.cdn;
  if(x.latency_ms!=null)state.latency=x.latency_ms;
  if(x.playback)state.playback=x.playback;
  if(x.phase==='playing'){
    state.playing=true;
    if(state.roomUrl){
    }
  }
  else if(['reconnecting','source_switching','playback_stalled','playback_ipc_degraded'].includes(x.phase)){
    // keep playing UI for ipc-degraded / health samples on native; only hard-stop on reconnect/switch
    if(['reconnecting','source_switching'].includes(x.phase)){ state.playing=false; destroyEmbedPlayer(); stopDockLoop(); }
  }
  else if(x.phase==='ended' || (['error','player_exit'].includes(x.phase) && /直播已结束/.test(x.message||''))){
    markLiveEnded(x.message||'直播已结束');
    render();
    return;
  }
  else if(['error','player_exit','stopped'].includes(x.phase)){state.playing=false;destroyEmbedPlayer();stopDockLoop();}
  // Don't full re-render on every playback_health — update chips only when possible
  if(x.phase==='playback_health' && state.playing){
    const chip=document.querySelector('.buf-chip');
    if(chip && x.playback?.buffer_sec!=null) chip.textContent=`缓冲 ${Number(x.playback.buffer_sec).toFixed(2)}s`;
    const ll=document.querySelector('.ll-chip');
    if(ll) ll.textContent=`LL ${latencyMode()} · ${playbackSpeed()}`;
    const veil=document.querySelector('.native-veil .native-hint:last-child');
    if(veil) veil.textContent=`缓冲 ${buffer()} · LL ${latencyMode()} · ${playbackSpeed()}`;
    return;
  }
  addEvent('LIVE',x.phase||'event',x.message||'',(x.phase==='error'||x.phase==='ended')?'err':(['reconnecting','playback_stalled','playback_ipc_degraded'].includes(x.phase)?'warn':x.phase==='playing'?'ok':''));
  render();
});


async function refreshTools(){try{await invoke('tool_status');}catch(_){}}
async function init(){render();try{state.backend=await invoke('player_backend');}catch(_){}addEvent('SYSTEM','ready',`LiveCatch low-latency player · ${state.backend}`);try{await fitAppWindow('force-portrait');}catch(_){}render();try{await register('CommandOrControl+L',()=>document.querySelector('#url')?.focus());}catch(_){}}
init().catch(e=>{console.error(e);app.innerHTML=`<div class="fatal">启动失败：${esc(e)}</div>`;});
window.addEventListener('beforeunload',()=>{destroyEmbedPlayer();stopDockLoop();unregister('CommandOrControl+L').catch(()=>{});});
