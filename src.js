import { invoke } from '@tauri-apps/api/core';
import { register, unregister } from '@tauri-apps/plugin-global-shortcut';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow, LogicalSize } from '@tauri-apps/api/window';
import './style.css';

const app = document.querySelector('#app');
const state = {
  roomUrl:'', liveTaskId:null, liveGeneration:0, livePhase:'idle', playing:false, busy:false,
  streamUrl:'', protocol:'-', cdn:'-', health:'待连接', latency:null, playback:null,
  events:[], candidates:[], tools:[], maxEvents:120, playerError:'',
  videoPortrait:true,
  grabText:'', grabFlash:'', grabBusy:false, grabLastMs:null, showDiag:false, consoleOpen:false,
  muted:true, sendRequestId:null,
  // 同窗原生内嵌：随包 FFmpeg 画进左侧洞（无 mpv、无全局安装）
  backend:'ffmpeg',
  session:{logged_in_hint:false,has_sessionid:false,has_ttwid:false,cookie_count:0,message:'',path:null},
  pendingStartAfterLogin:false,
  /// 已为该 roomUrl 触发过后台进房绑定，避免 session-updated 死循环
  boundRoomUrl:'',
  sessionBusy:false,
  danmaku:[], // 互动区：只显示弹幕/公屏，不混系统日志
  danmakuTab:'chat', // chat | log
};

let dockTimer = null;
let pumpRaf = null;

const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
const time=()=>new Date().toLocaleTimeString('zh-CN',{hour12:false});
function addEvent(kind,phase,message,level=''){state.events.push({time:time(),kind,phase,message,level});if(state.events.length>state.maxEvents)state.events.splice(0,state.events.length-state.maxEvents);}
function pushDanmaku(user,text,kind='chat'){
  state.danmaku.push({time:time(),user,text:String(text||''),kind});
  if(state.danmaku.length>200) state.danmaku.splice(0,state.danmaku.length-200);
}
function statusTone(){if(state.playing)return 'live';if(['reconnecting','probing','resolving','starting_player','starting','binding'].includes(state.livePhase))return 'warn';if(['error','player_exit','ended'].includes(state.livePhase))return 'err';return '';}
function isEnded(){return state.livePhase==='ended'||/直播已结束/.test(state.health||'')||/直播已结束/.test(state.playerError||'');}
function emptyTitle(){if(state.livePhase==='binding')return '进入直播间…';if(state.livePhase==='reconnecting')return '正在恢复…';if(isEnded())return '直播已结束';return isNative()?'原生监看':'同窗监看';}
function emptySub(){
  if(isEnded()){
    const m=String(state.health||'');
    const title=(m.match(/「([^」]+)」/)||[])[1];
    return title?`「${esc(title)}」已结束，换一个正在播的房间`:'该直播间当前不在播，换一个正在直播的房间试试';
  }
  if(state.playerError)return esc(state.playerError);
  if(isNative()&&state.health==='待连接')return 'FFmpeg 画进左侧洞（同窗内嵌）';
  return esc(state.health);
}
function markLiveEnded(message){
  const msg=String(message||'直播已结束');
  state.livePhase='ended';
  state.health=msg;
  state.playing=false;
  state.playerError='';
  state.grabFlash=msg.includes('直播已结束')?msg:'直播已结束';
  destroyEmbedPlayer();
  stopDockLoop();
  invoke('stop_player').catch(()=>{});
  addEvent('LIVE','ended',msg,'err');
}
function isNative(){return true;}
function playbackText(){
  const p=state.playback;
  if(!p) return state.playing?(isNative()?'FFmpeg':'内嵌'):'—';
  if(p.stalled)return '卡顿';
  if(p.buffering)return '缓冲';
  if(p.ipc_ok===false)return 'IPC异常';
  return '正常';
}
function buffer(){return state.playback?.buffer_sec==null?'-':`${Number(state.playback.buffer_sec).toFixed(2)}s`;}
function playbackSpeed(){return state.playback?.speed==null?'-':`${Number(state.playback.speed).toFixed(2)}x`;}
function latencyMode(){const m=state.playback?.latency_mode;return m==='catchup'?'追赶':m==='recovery'?'恢复':m==='ipc-degraded'?'IPC降级':m==='seek'?'跳边缘':'正常';}

function stopDockLoop(){
  if(dockTimer){ clearInterval(dockTimer); dockTimer=null; }
  if(pumpRaf){ cancelAnimationFrame(pumpRaf); pumpRaf=null; }
}

function startEmbedPump(){
  if(pumpRaf) return;
  const loop=()=>{
    pumpRaf=requestAnimationFrame(loop);
    if(state.playing && state.backend==='ffmpeg'){
      invoke('player_embed_tick').catch(()=>{});
    }
  };
  pumpRaf=requestAnimationFrame(loop);
}


function destroyEmbedPlayer(){
  const screen=document.querySelector('.screen');
  if(screen){
    screen.style.removeProperty('--src-ar');
    screen.style.removeProperty('--screen-w');
  }
}

function screenModeClass(){
  if(!state.playing) return 'idle portrait';
  return 'portrait native-hole';
}

/** 应用窗口宽 = 左舞台 + 右弹幕；始终保持左右结构，不压成上下。 */
async function fitAppWindow(mode){
  const force=mode==='force-portrait'||mode==='force-landscape';
  const target=mode==='force-landscape'||mode==='landscape'?'landscape':'portrait';
  if(!force && state.winMode===target) return;
  state.winMode=target;
  // 弹幕栏 360；左侧加宽，避免右栏被窗口边缘裁切
  const DANMAKU=360;
  const size=target==='landscape'
    ? {width:1000 + DANMAKU, height:860}
    : {width:600 + DANMAKU, height:900};
  try{
    await getCurrentWindow().setMinSize(new LogicalSize(DANMAKU + 500, 720));
    await getCurrentWindow().setSize(new LogicalSize(size.width, size.height));
  }catch(_){}
}
async function tryUnmute(){
  state.grabFlash='声音在内嵌播放器中，点监视器或用系统音量';
  render();
}

async function syncNativeDock(){
  if(!isNative() || !state.playing) return;
  const el=document.querySelector('#native-stage')||document.querySelector('.screen');
  const stage=document.querySelector('.stage');
  if(!el || !stage) return;
  const r=el.getBoundingClientRect();
  const sr=stage.getBoundingClientRect();
  // 严格裁进左舞台：顶栏以下、弹幕栏以左
  const topMin=56;
  let x=Math.max(sr.left, r.left);
  let y=Math.max(sr.top, r.top, topMin);
  let right=Math.min(sr.right, r.right);
  let bottom=Math.min(sr.bottom, r.bottom);
  let w=Math.max(0, right-x);
  let h=Math.max(0, bottom-y);
  x=Math.round(x); y=Math.round(y); w=Math.round(w); h=Math.round(h);
  if(w<80 || h<120) return;
  try{
    await invoke('dock_native_player',{x,y,w,h});
  }catch(_){}
}

function startDockLoop(){
  stopDockLoop();
  if(!isNative()) return;
  syncNativeDock();
  if(state.backend==='ffmpeg'){
    startEmbedPump();
  }
  // 洞口几何同步
  let n=0;
  dockTimer=setInterval(()=>{
    void syncNativeDock();
    n+=1;
    if(n===20 && dockTimer){ clearInterval(dockTimer); dockTimer=setInterval(()=>void syncNativeDock(), 500); }
  }, 100);
  window.addEventListener('resize', syncNativeDock);
  window.addEventListener('move', syncNativeDock);
}

function screenHtml(){
  if(isNative()){
    if(state.playing){
      return `<div id="native-stage" class="native-stage">
        <div class="native-veil">
          <div class="live-pill"><span class="dot live"></span> NATIVE</div>
          <h2>贴合监看中</h2>
          <p>${esc(state.protocol)} · 源延迟 ${state.latency??'-'} ms</p>
          <p class="native-hint">缓冲 ${buffer()} · LL ${latencyMode()} · ${playbackSpeed()}</p>
        </div>
      </div>`;
    }
    return `<div class="empty"><div class="empty-mark">▶</div><div class="empty-title">${emptyTitle()}</div><div class="empty-sub">${emptySub()}</div></div>`;
  }
  return `<div class="empty"><div class="empty-mark">▶</div><div class="empty-title">${emptyTitle()}</div><div class="empty-sub">${emptySub()}</div></div>`;
}

function danmakuHtml(){
  if(state.danmakuTab==='log'){
    const rows=state.events.slice(-80);
    if(!rows.length) return `<div class="dm empty">暂无系统日志</div>`;
    return rows.map(e=>`<div class="dm"><span class="who sys">${esc(e.time)}</span><span class="who">${esc(e.kind)}</span>${esc(e.phase)} · ${esc(e.message)}</div>`).join('');
  }
  const rows=state.danmaku.slice(-120);
  if(!rows.length){
    return `<div class="dm empty">暂无弹幕。进入直播间后会自动订阅互动；也可手动发送公屏数字。<br>（系统日志请点「日志」）</div>`;
  }
  return rows.map(d=>{
    const cls=d.kind==='me'?'me':(d.kind==='notice'||d.kind==='gift'||d.kind==='enter')?'sys':'';
    const lvl=d.kind==='me'?'★':d.kind==='notice'?'·':d.kind==='gift'?'礼':d.kind==='enter'?'进':'14';
    return `<div class="dm${d.kind==='notice'||d.kind==='gift'?' sys':''}"><span class="lvl">${lvl}</span><span class="who ${cls}">${esc(d.user||'用户')}</span>${esc(d.text)}</div>`;
  }).join('');
}

function render(){
  const tone=statusTone();
    const lat=state.latency==null?'—':`${state.latency} ms`;
  const canSend=!!state.grabText && !state.grabBusy && !!state.roomUrl;
    const sessHasCookie=!!state.session?.has_sessionid;
  const sessOk=!!state.session?.live_ok;
  const sessName=(state.session?.account_nickname||state.session?.account_display_id||'').trim();
  const sessLabel=sessOk?(sessName?`已登录 · ${sessName}`:'已登录'):(sessHasCookie?(sessName?`Cookie · ${sessName}`:'已存 Cookie'):'登录发弹幕');
  const sessOn=sessHasCookie; // 顶栏绿点：已登录（发弹幕用）
  const tab=state.danmakuTab||'chat';
  app.innerHTML=`<div class="desk live">
    <header class="topbar">
      <div class="brand"><div class="brand-mark">LC</div><div class="brand-name">LiveCatch<span class="version">0.45</span></div></div>
      <div class="top-room">
        <input id="url" aria-label="直播间地址" placeholder="粘贴直播间链接，例如 https://live.douyin.com/…" value="${esc(state.roomUrl)}">
        <button class="btn btn-primary" id="start" ${state.busy?'disabled':''}>${state.busy?'连接中…':'进入直播间'}</button>
        <button class="btn btn-secondary" id="stop">停</button>
      </div>
      <div class="top-actions">
        <button type="button" class="sess-chip ${sessOn?'on':''}" id="sess-login" ${state.sessionBusy?'disabled':''} title="${esc(state.session?.message||'')}">
          <span class="dot"></span>${esc(sessLabel)}
        </button>
        <span class="lat-chip buf-chip">${state.playback?.buffer_sec!=null?`缓冲 ${Number(state.playback.buffer_sec).toFixed(2)}s`:'缓冲 —'}</span>
        <span class="lat-chip ll-chip">LL ${latencyMode()}</span>
        <div class="top-live"><span class="dot ${tone}"></span><span>${state.playing?'LIVE':state.livePhase==='binding'?'进房中':state.livePhase==='reconnecting'?'重连中':state.livePhase==='ended'||isEnded()?'已结束':state.livePhase==='resolving'||state.livePhase==='probing'?'处理中':'待连接'}</span></div>
      </div>
    </header>

    <div class="workspace">
      <main class="stage">
        <div class="stage-main"><div class="screen ${screenModeClass()}">${screenHtml()}</div></div>
        <div class="stage-foot">
          <div class="stage-stat"><label>后端</label><b>${state.backend}</b></div>
          <div class="stage-stat"><label>协议</label><b>${esc(state.protocol)}</b></div>
          <div class="stage-stat"><label>源延迟</label><b>${state.latency==null?'-':lat}</b></div>
          <div class="stage-stat"><label>画面</label><b class="orient-chip">${state.videoPortrait===false?'横屏':'竖屏'}</b></div>
          <div class="stage-stat"><label>播放</label><b>${playbackText()}</b></div>
          <button type="button" class="audio-btn ${state.muted?'':'on'}" id="unmute">${isNative()?'声音在播放器':(state.muted?'点击开声':'已开声')}</button>
        </div>
      </main>

      <aside class="danmaku">
        <div class="danmaku-head">
          <b>${tab==='chat'?'弹幕':'日志'}</b>
          <div class="danmaku-tabs">
            <button type="button" class="${tab==='chat'?'on':''}" id="tab-chat">互动</button>
            <button type="button" class="${tab==='log'?'on':''}" id="tab-log">日志</button>
            <button type="button" id="clear-danmaku">清空</button>
          </div>
        </div>
        <div class="danmaku-list" id="danmaku-list">${danmakuHtml()}</div>
        <div class="danmaku-compose">
          <div class="sess-bar">
            <button type="button" class="mini" id="sess-clear" ${state.sessionBusy?'disabled':''}>退出登录</button>
            <span class="lat-chip soft">${sessOk?(sessName?`账号 ${sessName}`:'已登录'):(sessHasCookie?'已登录':'未登录')}</span>
            <div class="sess-meta">${esc(state.session?.message||(sessHasCookie?'已登录，可发公屏弹幕':'看播无需登录；发弹幕请点上方「登录发弹幕」'))}</div>
          </div>
          <div class="compose-row">
            <input id="grab" inputmode="numeric" autocomplete="off" placeholder="公屏数字" value="${esc(state.grabText)}" aria-label="公屏数字" ${state.grabBusy?'disabled':''}>
            <button class="send" id="grab-send" ${canSend?'':'disabled'}>${state.grabBusy?'…':'发送'}</button>
          </div>
          <div class="numpad">
            ${[1,2,3,4,5,6,7,8,9,'⌫',0,'清'].map(k=>`<button type="button" class="num-key" data-k="${esc(k)}" ${state.grabBusy?'disabled':''}>${k}</button>`).join('')}
          </div>
          <div class="grab-flash ${state.grabFlash?'on':''}">${esc(state.grabFlash||'听数字 → 敲入 → Enter 发送到公屏')}</div>
        </div>
      </aside>
    </div>
  </div>`;

  const urlEl=document.querySelector('#url');
  urlEl?.addEventListener('input',e=>state.roomUrl=e.target.value);
  urlEl?.addEventListener('keydown',e=>{if(e.key==='Enter')start();});
  document.querySelector('#start')?.addEventListener('click',start);
  document.querySelector('#stop')?.addEventListener('click',stop);
  document.querySelector('#unmute')?.addEventListener('click',tryUnmute);
  document.querySelector('#tab-chat')?.addEventListener('click',()=>{state.danmakuTab='chat';render();});
  document.querySelector('#tab-log')?.addEventListener('click',()=>{state.danmakuTab='log';render();});
  document.querySelector('#clear-danmaku')?.addEventListener('click',()=>{
    if(state.danmakuTab==='log') state.events=[];
    else state.danmaku=[];
    render();
  });

  const grabEl=document.querySelector('#grab');
  grabEl?.addEventListener('input',e=>{state.grabText=e.target.value.replace(/[^\d]/g,'');});
  grabEl?.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();sendGrab();}});
  document.querySelector('#grab-send')?.addEventListener('click',sendGrab);
  document.querySelector('#sess-login')?.addEventListener('click',()=>sessionAction('login'));
  document.querySelector('#sess-clear')?.addEventListener('click',()=>sessionAction('clear'));
  document.querySelectorAll('.num-key').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const k=btn.getAttribute('data-k');
      if(k==='清'){state.grabText='';}
      else if(k==='⌫'){state.grabText=state.grabText.slice(0,-1);}
      else{state.grabText=(state.grabText+k).slice(0,12);}
      render();
      queueMicrotask(()=>document.querySelector('#grab')?.focus());
    });
  });

  const list=document.querySelector('#danmaku-list');
  if(list) list.scrollTop=list.scrollHeight;


  if(state.playing && isNative()){
    queueMicrotask(()=>startDockLoop());
  } else {
    stopDockLoop();
  }

  if(state.playing){
    queueMicrotask(()=>{
      const a=document.activeElement;
      if(!a || a===document.body || a.id==='grab') document.querySelector('#grab')?.focus();
    });
  }
}

async function sendGrab(){
  const text=(state.grabText||'').trim();
  if(!text){state.grabFlash='先输入主播说的数字';render();return;}
  if(!state.roomUrl){state.grabFlash='先粘贴直播间并开看';render();return;}
  await refreshSession();
  if(!sessionReady()){
    state.grabFlash='发弹幕需先登录：请点「登录发弹幕」';
    render();
    try{ await invoke('open_douyin_login'); }catch(_){}
    return;
  }
  // 已有 Cookie：发送前若未绑定，由后端静默按房间绑定（不再扫码）
  if(state.grabBusy)return;
  state.grabBusy=true;
  state.grabFlash=`发送「${text}」…`;
  addEvent('GRAB','send',text);
  render();
  const t0=performance.now();
  try{
    const r=await invoke('send_text',{roomUrl:state.roomUrl,text});
    state.sendRequestId=r.request_id;
    if(r.status==='sent'){
      state.grabFlash=`已发送「${text}」· ${r.send_ms??'-'}ms`;
      pushDanmaku('我', text, 'me');
      state.grabText='';
      state.grabBusy=false;
      state.grabLastMs=Number(r.send_ms||Math.round(performance.now()-t0));
      render();
      queueMicrotask(()=>document.querySelector('#grab')?.focus());
      return;
    }
    // queued: keep grabBusy until q1-result（Cookie HTTP 直发）
    if(r.status==='queued'){
      state.grabFlash=r.message||`发送「${text}」…`;
      render();
      return;
    }
    state.grabFlash=`${r.status}：${r.message||''}`;
    if(r.status==='duplicate'){state.grabFlash='重复发送已拦截';}
  }catch(e){
    try{ await navigator.clipboard.writeText(text); }catch(_){}
    state.grabFlash=`直发失败，已复制「${text}」：${e}`;
    addEvent('GRAB','send_error',String(e),'err');
    state.grabBusy=false;
    render();
    queueMicrotask(()=>document.querySelector('#grab')?.focus());
    return;
  }
  state.grabLastMs=Math.round(performance.now()-t0);
  state.grabBusy=false;
  render();
  queueMicrotask(()=>document.querySelector('#grab')?.focus());
}

function sessionReady(){
  // 有 Cookie 即可尝试发公屏（HTTP + 盘上 Cookie）
  return !!(state.session?.has_sessionid || state.session?.logged_in_hint);
}

function generationFromResult(r){return Number((r?.message||'').match(/generation=(\d+)/)?.[1]||0);}
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
    const danmaku=360;
    const hole=document.querySelector('.screen')||document.querySelector('.stage-main');
    const stage=document.querySelector('.stage');
    if(hole && stage){
      const r=hole.getBoundingClientRect();
      const sr=stage.getBoundingClientRect();
      let x=Math.max(sr.left, r.left);
      let y=Math.max(sr.top, r.top, topMin);
      let right=Math.min(sr.right, r.right, window.innerWidth-danmaku);
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
    invoke('subscribe_danmaku',{roomUrl:state.roomUrl}).catch(e=>addEvent('SYSTEM','danmaku_sub',String(e),'warn'));
    // 已登录时后端 start_live 会并行进房绑定；标记避免 session-updated 再绑一次
    if(state.session?.has_sessionid) state.boundRoomUrl=state.roomUrl;
  }catch(e){
    state.livePhase='error';state.health=String(e);addEvent('LIVE','error',String(e),'err');alert('启动失败：'+e);
  }finally{state.busy=false;render();}
}
async function stop(){
  state.busy=false;destroyEmbedPlayer();stopDockLoop();
  try{await invoke('unsubscribe_danmaku');}catch(_){}
  try{await invoke('stop_player');await invoke('clear_room')}catch(e){addEvent('LIVE','stop_error',String(e),'warn')}
  state.playing=false;state.liveTaskId=null;state.liveGeneration=0;state.livePhase='stopped';state.health='已停止';state.streamUrl='';state.playback=null;state.playerError='';state.videoPortrait=true;state.boundRoomUrl='';
  addEvent('LIVE','stopped','已停止');render();
  fitAppWindow('portrait');
}
async function refreshTools(){try{state.tools=await invoke('tool_status');}catch(e){state.tools=[];addEvent('SYSTEM','tool_status',String(e),'warn');}}
async function refreshSession(){
  try{ state.session=await invoke('douyin_session_status'); }
  catch(e){ state.session={...(state.session||{}),message:String(e)}; addEvent('SESSION','status',String(e),'warn'); }
}
async function sessionAction(kind){
  if(state.sessionBusy)return;
  state.sessionBusy=true;render();
  try{
    if(kind==='login'){
      await invoke('open_douyin_login');
      addEvent('SESSION','login','已打开抖音登录窗','ok');
      state.grabFlash='请扫码登录（LiveCatch 皮肤，确认后自动保存）';
    }else if(kind==='save'){
      state.session=await invoke('save_douyin_session');
      addEvent('SESSION','save',state.session.message||'saved',state.session.logged_in_hint?'ok':'warn');
      state.grabFlash=state.session.logged_in_hint?'Cookie 已保存':'Cookie 已写盘，但可能不完整';
    }else if(kind==='verify'){
      const r=await invoke('verify_douyin_session');
      addEvent('SESSION','verify',r.message||'',r.ok?'ok':'warn');
      state.grabFlash=r.message||(r.ok?'验证通过':'验证未通过');
      await refreshSession();
    }else if(kind==='clear'){
      state.session=await invoke('clear_douyin_session');
      state.boundRoomUrl='';
      addEvent('SESSION','clear','已清除本地会话与 WebView Cookie');
      state.grabFlash='已退出登录（Cookie 已清），再次登录需重新扫码';
    }
  }catch(e){
    addEvent('SESSION',kind,String(e),'err');
    state.grabFlash=`会话操作失败：${e}`;
  }finally{
    state.sessionBusy=false;render();
  }
}

listen('live-event',e=>{
  const x=e.payload||{};
  // Binding progress may arrive before task_id is assigned — never hijack an active play.
  if(x.phase==='binding'){
    if(state.playing || ['resolving','probing','starting_player','playing'].includes(state.livePhase)){
      state.grabFlash=x.message||state.grabFlash;
      render();
      return;
    }
    state.livePhase='binding';
    state.health=x.message||'正在进入直播间…';
    state.grabFlash=x.message||state.grabFlash;
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
      invoke('subscribe_danmaku',{roomUrl:state.roomUrl}).catch(()=>{});
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

listen('q1-result',e=>{
  const x=e.payload||{};
  const rid=String(x.request_id||'');
  if(rid.startsWith('dm-sub-')||rid.startsWith('dm-unsub-')){
    const msg=String(x.message||'');
    const failed=x.status==='failed'||x.status==='error';
    if(failed && /直播已结束/.test(msg)){
      markLiveEnded(msg);
      state.grabFlash=msg;
      render();
      return;
    }
    state.grabFlash=x.status==='subscribed'||x.status==='unsubscribed'||x.status==='queued'
      ?(msg||x.status)
      :`弹幕订阅：${x.status} ${msg}`;
    if(failed) addEvent('SYSTEM','danmaku_sub',msg||x.status,'warn');
    render();
    return;
  }
  if(state.sendRequestId&&x.request_id&&x.request_id!==state.sendRequestId)return;
  state.grabBusy=false;
  if(x.send_ms!=null)state.grabLastMs=Number(x.send_ms);
  if(x.status==='sent'){
    const sentText=String(x.code||state.grabText||'');
    const via=x.transport==='http-chat'?'HTTP':(x.transport==='webview-http'||x.transport==='webview-chat'?'WebView·HTTP':(x.transport||''));
    state.grabFlash=`已发送「${sentText}」· ${via||'通道未知'} · ${x.send_ms??'-'}ms`;
    if(sentText) pushDanmaku('我', sentText, 'me');
    state.grabText='';
    addEvent('GRAB','sent',`${via||'?'} | ${x.message||'ok'}`,'ok');
  }else{
    const failedText=String(x.code||state.grabText||'');
    state.grabFlash=`发送失败：${x.message||x.status||''}`;
    if(failedText){ try{ navigator.clipboard.writeText(failedText); }catch(_){ } }
    addEvent('GRAB',x.status||'failed',x.message||'','warn');
  }
  render();
  queueMicrotask(()=>document.querySelector('#grab')?.focus());
});

listen('danmaku-event',e=>{
  const x=e.payload||{};
  const user=x.user||'观众';
  const text=x.text||'';
  if(!text) return;
  const kind=x.kind==='gift'||x.kind==='enter'||x.kind==='notice'||x.kind==='me'?x.kind:'chat';
  // 系统 notice 进日志，不污染公屏列表
  if(kind==='notice'){
    addEvent('DANMAKU','notice',`${user}: ${text}`,'');
    return;
  }
  pushDanmaku(user, text, kind);
  const list=document.querySelector('#danmaku-list');
  if(list && state.danmakuTab!=='log'){
    list.querySelectorAll('.dm.empty').forEach(n=>n.remove());
    const whoCls=kind==='notice'||kind==='gift'||kind==='enter'?'sys':kind==='me'?'me':'';
    const lvl=kind==='me'?'★':kind==='notice'?'·':kind==='gift'?'礼':kind==='enter'?'进':'14';
    const row=document.createElement('div');
    row.className=kind==='notice'||kind==='gift'?'dm sys':'dm';
    row.innerHTML=`<span class="lvl">${lvl}</span><span class="who ${whoCls}">${esc(user)}</span>${esc(text)}`;
    list.appendChild(row);
    while(list.children.length>120) list.removeChild(list.firstChild);
    list.scrollTop=list.scrollHeight;
  } else {
    render();
  }
});

listen('session-updated',e=>{
  const st=e.payload||{};
  state.session=st;
  const hasCookie=!!st.has_sessionid;
  const ok=!!st.live_ok;
  const who=(st.account_nickname||st.account_display_id||'').trim();
  state.grabFlash=ok
    ?(who?`登录成功 · 账号「${who}」`:'登录成功，账号已就绪')
    :(hasCookie
      ?(st.message||'Cookie 已保存')
      :(st.message||'会话已更新'));
  addEvent('SESSION','auto_saved',st.message||'ok',ok?'ok':'warn');
  render();
  // 登录成功后只绑定一次；enter_room 自己也会发 session-updated，绝不能再调 bind
  if(hasCookie && ok && state.roomUrl && state.boundRoomUrl!==state.roomUrl){
    const watching=state.playing || ['queued','resolving','probing','starting_player','playing','binding','reconnecting'].includes(state.livePhase);
    if(watching){
      state.boundRoomUrl=state.roomUrl;
      invoke('bind_douyin_room',{roomUrl:state.roomUrl})
        .then(()=>addEvent('SESSION','bind_after_login','登录后进房绑定…','ok'))
        .catch(err=>{
          state.boundRoomUrl='';
          addEvent('SESSION','bind_after_login',String(err),'warn');
        });
    }
  }
});

listen('login-flow',e=>{
  const x=e.payload||{};
  const step=x.step||'?';
  const status=x.status||'';
  const detail=x.detail||'';
  const level=status==='fail'?'warn':(status==='ok'?'ok':'info');
  addEvent('FLOW',`${step}:${status}`,detail,level);
  if(status==='start'||status==='fail'||status==='ok'||status==='landed'){
    state.grabFlash=`${step} · ${status}${detail?`：${detail}`:''}`;
    render();
  }
});

listen('session-bind',e=>{
  const x=e.payload||{};
  state.grabFlash=x.message||x.status||'进房中';
  if(x.status==='ok'||x.status==='left') refreshSession();
  if(x.status==='failed') addEvent('SESSION','bind',x.message||'failed','warn');
  if(x.status==='left') addEvent('SESSION','leave_room',x.message||'left','ok');
  render();
});

async function init(){
  // Paint UI immediately — never wait on IPC before first frame (white screen otherwise).
  render();
  try{ state.backend=await invoke('player_backend'); }catch(_){ state.backend='ffmpeg'; }
  let libNote='';
  try{
    const st=await invoke('player_ffmpeg_status');
    if(st?.message) libNote=' · '+String(st.message).slice(0,48);
  }catch(_){}
  addEvent('SYSTEM','ready',`数字台 0.45 · 后端 ${state.backend}（FFmpeg 同窗内嵌，无全局安装）${libNote}`);
  render();
  try{ await fitAppWindow('force-portrait'); }catch(_){}
  await Promise.all([refreshTools(), refreshSession()]);
  render();
  try{ await register('CommandOrControl+Shift+K',()=>document.querySelector('#grab')?.focus()); }catch(e){ addEvent('SYSTEM','shortcut',String(e),'warn'); }
}
init().catch(e=>{
  console.error(e);
  if(app) app.innerHTML=`<div style="padding:24px;color:#fe2c55">启动失败：${esc(e)}</div>`;
});
window.addEventListener('beforeunload',()=>{destroyEmbedPlayer();stopDockLoop();unregister('CommandOrControl+Shift+K').catch(()=>{});});
window.addEventListener('keydown',e=>{
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='l'){e.preventDefault();document.querySelector('#url')?.focus();return;}
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();document.querySelector('#grab')?.focus();}
});