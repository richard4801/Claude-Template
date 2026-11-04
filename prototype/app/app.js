/* MUSE clickable prototype. Sample data only. */
const IMG = window.__IMG;
const $ = (s, r=document) => r.querySelector(s);
const store = { get(k,d){ try{ const v=localStorage.getItem('muse.'+k); return v==null?d:JSON.parse(v);}catch(e){return d;} }, set(k,v){ try{localStorage.setItem('muse.'+k,JSON.stringify(v));}catch(e){} } };

const S = {
  theme: store.get('theme','a'), sound: store.get('sound', true),
  stack: [], steps: 10, engine: 'h3', bg: 'keep', motion: 'subtle', lip: false, keepAudio: true, outfit: 0, tool: 'quality',
  use: 'first', consent: 'post', shot: 'Medium', lens: 35, aperture: 'f/2.8', light: 'Golden hour',
  create: { niche: 'Beauty', look: { 'Face shape':'Oval', Eyes:'Brown', Hair:'Black', Texture:'Curly', Body:'Curvy', Makeup:'Soft glam' }, skin: 4 },
  gallery: 'tests', final: [],
  jobs: [
    { id: 'j1', img: 'vid_kick', title: 'Kick test', engine: 'Fast · beta', p: 100, state: 'done', cost: 0.13, tc: '00:01:35' },
    { id: 'j2', img: 'vid_bath', title: 'Bathroom trend', engine: 'Standard · 30 steps', p: 100, state: 'done', cost: 3.05, tc: '00:46:00' },
  ],
  running: null, balance: 6.07, month: 18.93
};
const money = v => '$'+v.toFixed(2);
const LENS = () => (S.use==='full')?9.4:5.2;
const secPerLen = len => 57.8*Math.pow(len/5.2,1.3);
const estMin = () => S.engine==='viggle'? 1.6*(LENS()/5.2) : S.steps*secPerLen(LENS())/60 + 0.5 + (S.lip?4:0);
const estCost = () => S.engine==='viggle'? 0.13*(LENS()/5.2) : estMin()/60*3.99;

/* ---------------- Sound (WebAudio, synthesized, per theme) ---------------- */
let AC = null;
function ac(){ if(!AC){ try{ AC = new (window.AudioContext||window.webkitAudioContext)(); }catch(e){ AC=null; } } if(AC && AC.state==='suspended') AC.resume(); return AC; }
function tone(f1, f2, dur, type='sine', vol=.12, delay=0){
  const a=ac(); if(!a||!S.sound) return; const t=a.currentTime+delay;
  const o=a.createOscillator(), g=a.createGain(); o.type=type; o.frequency.setValueAtTime(f1,t); if(f2) o.frequency.exponentialRampToValueAtTime(f2,t+dur);
  g.gain.setValueAtTime(0.0001,t); g.gain.exponentialRampToValueAtTime(vol,t+.008); g.gain.exponentialRampToValueAtTime(0.0001,t+dur);
  o.connect(g).connect(a.destination); o.start(t); o.stop(t+dur+.02);
}
function noise(dur, freq, q=1, vol=.15, delay=0, type='bandpass', sweepTo){
  const a=ac(); if(!a||!S.sound) return; const t=a.currentTime+delay;
  const b=a.createBuffer(1, Math.floor(a.sampleRate*dur), a.sampleRate), d=b.getChannelData(0); for(let i=0;i<d.length;i++) d[i]=Math.random()*2-1;
  const s=a.createBufferSource(); s.buffer=b; const f=a.createBiquadFilter(); f.type=type; f.frequency.setValueAtTime(freq,t); f.Q.value=q; if(sweepTo) f.frequency.exponentialRampToValueAtTime(sweepTo,t+dur);
  const g=a.createGain(); g.gain.setValueAtTime(vol,t); g.gain.exponentialRampToValueAtTime(0.0001,t+dur);
  s.connect(f).connect(g).connect(a.destination); s.start(t); s.stop(t+dur);
}
/* No UI sounds (decided 2026-11-04: they felt like an arcade game). Only notifications make a sound:
   a soft two-note chime standing in for the phone's own notification sound. */
const NOTIFY = () => { tone(880,null,.5,'sine',.05); tone(1318.5,null,.8,'sine',.035,.11); };
function notifySound(){ try{ NOTIFY(); }catch(e){} }
const snd = k => {};

/* ---------------- Icons ---------------- */
const ICON = __ICONS__;
function ic(n, s=22, cls=''){ const fill=['play','apple','google'].includes(n)?' fill="currentColor" stroke="none"':' fill="none" stroke="currentColor"'; return `<svg class="ic ${cls}" width="${s}" height="${s}" viewBox="0 0 24 24"${fill} stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${ICON[n]}</svg>`; }
const bg = k => `background-image:url(${IMG[k]})`;
const T = () => S.theme;

/* ---------------- Shared parts ---------------- */
const sbar = (over) => `<div class="sb${over?' sb-over':''}"><span>9:41</span><span class="sb-r"><i class="sig"></i><i class="wifi"></i><i class="bat"></i></span></div>`;
const topb = (title='', left='back', right=null, over=false) => `<header class="top${over?' over':''}">${left?`<span class="tb-btn press" data-back>${ic(left)}</span>`:'<span class="tb-btn ghost"></span>'}<h1 class="top-t">${title}</h1>${right?(right[0]==='more'?`<span class="tb-btn press" data-act="menu">${ic('more')}</span>`:`<span class="tb-btn press" data-go="${right[1]}">${ic(right[0])}</span>`):'<span class="tb-btn ghost"></span>'}</header>`;
const wm = (c='') => `<span class="wm ${c}">MUSE</span>`;
const pill = (t,k='') => `<span class="pill ${k}">${t}</span>`;
const stk = (t,c='yellow',r=-6,st='') => T()==='d'?`<span class="stk stk-${c} pop-in" style="transform:rotate(${r}deg);${st}">${t}</span>`:'';
const vf = () => T()==='b'?'<i class="vf tl"></i><i class="vf tr"></i><i class="vf bl"></i><i class="vf br"></i>':'';
function tabbar(active){
  const it=[['home','Home','home'],['grid','Gallery','gallery'],['plus','','source'],['queue','Queue','queue'],['user','You','settings']];
  return `<nav class="tabbar">${it.map(([i,l,g])=> i==='plus'?`<div class="tb-plus press" data-act="plusmenu" aria-label="Create">${ic('plus',24)}</div>`:`<div class="tb-i press${g===active?' on':''}" data-go="${g}">${ic(i)}<span>${l}</span></div>`).join('')}</nav>`;
}
const home = '<div class="homebar"></div>';
const DOODLE = {
  crown:'<svg width="56" height="44" viewBox="0 0 56 44"><path d="M4 38L8 10l14 14L28 4l6 20 14-14 4 28z" fill="#FFE14D" stroke="#111" stroke-width="3" stroke-linejoin="round"/></svg>',
  heart:'<svg width="44" height="40" viewBox="0 0 44 40"><path d="M22 36S4 25 4 13a9 9 0 0118-3 9 9 0 0118 3c0 12-18 23-18 23z" fill="#FF7EB6" stroke="#111" stroke-width="3"/></svg>',
  spark:'<svg width="40" height="40" viewBox="0 0 40 40"><path d="M20 2v10M20 28v10M2 20h10M28 20h10M7 7l7 7M26 26l7 7M33 7l-7 7M14 26l-7 7" stroke="#111" stroke-width="3" stroke-linecap="round"/></svg>'
};

/* ---------------- Screens ---------------- */
const SCREENS = {};

SCREENS.splash = () => {
  const sub = {a:'<span class="cond" style="font-size:16px;transform:none;font-family:var(--mono);letter-spacing:.14em">THE FACE OF YOUR VISION</span>', b:'● REC &nbsp;00:00:00:00', c:'Direct your AI model', d:'<span class="hand">make her move!</span>'}[T()];
  return `<section class="screen splash" data-go="welcome">${sbar(true)}<div class="sp-photo" style="${bg('hero')}">${vf()}</div>
  <div class="sp-mark"><span class="wm wm-xl">MUSE</span><p class="sp-sub">${sub}</p><p class="tiny" style="margin-top:22px;opacity:.75">Tap to start</p></div>
  ${stk('AI model studio','yellow',-8,'position:absolute;left:28px;top:140px')}${home}</section>`;
};
SCREENS.welcome = () => `<section class="screen">${sbar()}
  <div class="wel-grid"><div class="wel-img big" style="${bg('g_front')}">${vf()}</div><div class="wel-img" style="${bg('c_face')}"></div><div class="wel-img" style="${bg('vid_living')}"></div></div>
  ${stk('identity locked','pink',6,'position:absolute;right:26px;top:300px')}
  <div class="pad stack-16 wel-copy"><h2 class="hero-t">${T()==='a'?'<span class="cond" style="font-size:62px">Create your<br>AI model.</span>':'Create your AI model.<br>Direct every shot.'}</h2>
   <p class="muted">Build an original persona, lock her identity, then put her into real clips with the motion kept frame for frame.</p>
      <div class="cta press" data-go="signup">Get started</div><div class="link-c press" data-go="signin">I already have an account</div></div>${home}</section>`;

SCREENS.signin = () => `<section class="screen">${sbar()}${topb('')}
  <div class="pad stack-20"><div>${wm('wm-md')}<h2 class="h2" style="margin-top:14px">Welcome back</h2><p class="muted">Sign in to your studio.</p></div>
   <label class="fld"><span class="lbl">Email</span><span class="inp">jenne@studio.com</span></label>
   <label class="fld"><span class="lbl">Password</span><span class="inp">••••••••••</span><span class="fld-r" data-act="forgot">Forgot?</span></label>
   <div class="cta press" data-act="signin">Sign in</div><div class="or"><i></i><span>or</span><i></i></div>
   <div class="sso press" data-act="signin">${ic('apple',20)} Continue with Apple</div><div class="sso press" data-act="signin">${ic('google',20)} Continue with Google</div>
   <p class="tiny muted center">New here? <b class="acc press" data-go="signup">Create an account</b></p></div>${home}</section>`;

SCREENS.signup = () => `<section class="screen">${sbar()}${topb('')}
  <div class="pad stack-20"><div><h2 class="h2">Create your studio</h2><p class="muted">One account for all your models.</p></div>
   <label class="fld"><span class="lbl">Studio name</span><span class="inp">Jenne Studio</span></label>
   <label class="fld"><span class="lbl">Email</span><span class="inp">jenne@studio.com</span></label>
   <label class="fld"><span class="lbl">Password</span><span class="inp">••••••••••</span></label>
   <div class="chk press${S.ag1?' on':''}" data-act="ag1">${ic('check',16)}<span>I'm 18 or older. I'll only upload clips and images I have the rights to use, and only create original characters.</span></div>
   <div class="chk press${S.ag2?' on':''}" data-act="ag2">${ic('check',16)}<span>I'll label AI content when I post it.</span></div>
   <div class="cta press${S.ag1&&S.ag2?'':' is-off'}" data-act="${S.ag1&&S.ag2?'signin':'needag'}">Create account</div>
   <p class="tiny muted center">By continuing you agree to the MUSE Terms and Acceptable Use Policy.</p></div>${home}</section>`;

SCREENS.home = () => {
  const hello={a:'<span class="cond" style="font-size:56px">Your models</span>',b:'MODELS',c:'Good morning, Jenne',d:'Your crew'}[T()];
  return `<section class="screen">${sbar()}<header class="top">${wm()}<span class="grow"></span><span class="tb-btn press" data-act="notify">${ic('bell')}</span>${T()==='c'?`<span class="tb-btn press" data-go="settings">${ic('user')}</span>`:''}</header>
  <div class="pad stack-16 scroll"><div class="row-b"><h2 class="h2 home-t">${hello}</h2><span class="bal mono press" data-go="credits">${money(S.balance)}</span></div>
   <div class="feature press" style="${bg('g_front')}" data-go="profile">${vf()}<div class="feat-cap"><span class="lbl lbl-inv">Featured</span><b class="feat-name">Sienna Vale</b><span class="tiny">Identity locked · 2 outfits</span></div>
    ${stk('ready to shoot','mint',-5,'position:absolute;right:14px;top:14px')}</div>
   <div class="quick"><div class="qa press" data-go="source">${ic('studio')}<span>New video</span></div><div class="qa press" data-go="shoot">${ic('camera')}<span>Photoshoot</span></div><div class="qa press" data-go="create1">${ic('model')}<span>New model</span></div></div>
   <div class="row-b"><h3 class="h3">All models</h3><span class="tiny muted">2 models</span></div>
   <div class="mgrid"><div class="mcard press" data-go="profile"><div class="mc-img" style="${bg('c_front')}">${vf()}</div><div class="mc-meta"><b>Sienna Vale</b><span class="tiny muted">Fashion · 24</span>${pill('Locked','good')}</div></div>
    <div class="mcard press" data-go="create3"><div class="mc-img init">N</div><div class="mc-meta"><b>Noor Ellis</b><span class="tiny muted">Beauty · 27</span>${pill('Draft · 0/6 shots','warn')}</div></div></div>
  </div>${tabbar('home')}${home}</section>`;
};

const OUTFITS=[['g_front','Green set',['g_front','g_tq','g_side','g_back']],['c_front','Crystal dress',['c_front','c_tq','c_face','c_front']]];
const addTile = (cls='ofit') => `<div class="${cls} press" data-go="outfit" title="Add outfit"><div class="ref-img tall init" style="display:grid;place-items:center">+</div>${cls==='ofit'?'<span>Add outfit</span>':''}</div>`;
SCREENS.profile = () => {
  const t=T(), o=S.outfit;
  if(t==='a') return `<section class="screen">${sbar()}<header class="top">${wm()}<span class="grow"></span><span class="tb-btn press" data-act="menu">${ic('more')}</span></header>
    <div class="strip"><span>${ic('lock',12)} Identity locked · 6/6</span><span>Model profile</span></div>
    <div class="ap-photo press" style="${bg('hero')}" data-go="direct"><span class="cond ap-name">Sienna<br>Vale</span><span class="ap-tag">THE FACE OF YOUR VISION</span></div>
    <div class="carousel"><span class="arrow press" data-act="outfit-prev">${ic('back',18)}</span>${OUTFITS.map(([k],i)=>`<div class="cimg press${i===o?' on':''}" style="${bg(k)}" data-act="outfit-${i}"></div>`).join('')}<div class="cimg press" data-go="outfit" style="display:grid;place-items:center;border:1px dashed var(--line);font-size:24px">+</div><span class="arrow press" data-act="outfit-next">${ic('chev',18)}</span></div>
    <div class="under">OUTFITS ${o+1} / ${OUTFITS.length} · ${OUTFITS[o][1].toUpperCase()}</div>
    <div class="dock"><div class="cta grow press" data-go="source">Make a video</div><div class="cta-2 press" data-go="shoot">${ic('camera',18)} Shoot</div></div>${home}</section>`;
  if(t==='b') return `<section class="screen">${sbar()}<header class="top"><span class="tb-btn press" data-back>${ic('back')}</span><span class="grow center">${wm()}</span><span class="tb-btn press" data-act="menu">${ic('more')}</span></header>
    <div class="vfcard" style="${bg('hero')}">${vf()}<span class="ro" style="left:16px;top:14px">6/6</span><span class="ro" style="right:16px;top:14px">768×1344</span><i class="cross"></i><span class="ro" style="left:16px;bottom:14px">REF · FACE FRONT</span><span class="ro" style="right:16px;bottom:14px">${OUTFITS.length} OUTFITS</span></div>
    <div class="namerow"><b>Sienna Vale</b><span class="active">● ACTIVE</span></div><div class="idl">Identity locked · every shoot and video uses these shots · never add: tattoos, rings</div>
    <div class="pad" style="margin-top:12px"><div class="row-b"><span class="lbl">Outfit</span><span class="tiny mono muted">${o+1} / ${OUTFITS.length}</span></div>
     <div class="refrow" style="margin-top:8px">${OUTFITS.map(([k,n],i)=>`<div class="ofit press${i===o?' on':''}" data-act="outfit-${i}"><div class="ref-img tall" style="${bg(k)}"></div><span>${n}</span></div>`).join('')}${addTile()}</div></div>
    <div class="dock"><div class="cta grow press" data-go="source">Make a video</div><div class="cta-2 press" data-go="shoot">${ic('camera',18)} Shoot</div></div>${home}</section>`;
  if(t==='c') return `<section class="screen">${sbar()}<header class="top"><span class="tb-btn press" data-back>${ic('back')}</span><span class="grow center">${wm('c')}</span><span class="tb-btn press" data-go="settings">${ic('user')}</span></header>
    <div class="ccard" style="${bg('hero')}"></div>
    <div class="cname"><b>Sienna Vale</b><span class="tb-btn press" data-act="menu">${ic('more')}</span></div>
    <span class="cpill">${ic('lock',13)} Identity locked · used by every shoot and video</span>
    <div class="pad row-b" style="margin-top:14px"><b>Outfit</b><span class="tiny muted">${o+1} / ${OUTFITS.length} ›</span></div>
    <div class="ccar">${OUTFITS.map(([k],i)=>`<div class="cimg press${i===o?' on':''}" style="${bg(k)}" data-act="outfit-${i}"></div>`).join('')}<div class="cimg press" data-go="outfit" style="display:grid;place-items:center;background:var(--surface);font-size:26px;color:var(--muted)">+</div><span class="round-btn press" data-act="outfit-next" style="position:absolute;right:14px;top:38px">${ic('chev',16)}</span></div>
    <div class="dock"><div class="cta grow press" data-go="source">Make a video</div><div class="cta-2 press" data-go="shoot">${ic('camera',18)} Shoot</div></div>${home}</section>`;
  return `<section class="screen"><div class="blue" style="padding-bottom:48px;position:relative">${sbar(true)}<header class="top" style="color:#fff"><span class="tb-btn press" data-back>${ic('back')}</span>${wm()}<span class="grow tiny" style="text-align:right;line-height:1.1;font-weight:700;margin-right:4px">CREATE · DIRECT<br>YOUR AI MODEL</span><span class="tb-btn press" data-act="menu">${ic('more')}</span></header>
    <div class="cutout" style="${bg('hero')}"><span class="dname">Sienna<br>Vale</span></div>
    <span class="stk stk-yellow pop-in" style="position:absolute;left:14px;top:120px;transform:rotate(-10deg);font-size:13px;line-height:1.1">REAL LOOKS<br>+ AI POWER</span>
    <span class="doodle pop-in" style="right:24px;top:96px">${DOODLE.crown}</span><span class="doodle pop-in" style="left:22px;top:260px">${DOODLE.heart}</span>
    <span class="stk stk-pink pop-in" style="position:absolute;right:16px;bottom:30px;transform:rotate(-7deg);font-size:18px">IDENTITY<br>LOCKED ${ic('lock',16)}</span></div>
    <div class="pad stack-10" style="margin-top:34px"><b style="color:var(--blue);font-weight:800;letter-spacing:.04em">AI FASHION MODEL</b>
     <div class="row-b"><b>OUTFIT</b><span class="tiny"><b>${OUTFITS.length} LOOKS ›</b></span></div>
     <div class="refrow">${OUTFITS.map(([k,n],i)=>`<div class="ofit press${i===o?' on':''}" data-act="outfit-${i}"><div class="ref-img tall" style="${bg(k)}"></div><span>${n}</span></div>`).join('')}${addTile()}</div></div>
    <div class="dock"><div class="cta grow press" data-go="source">Make a video</div><div class="cta-2 press" data-go="shoot">${ic('camera',18)} Shoot</div></div>${home}</section>`;
};

const stepbars = n => `<div class="stepbars">${[0,1].map(i=>`<i class="${i<n?'on':''}"></i>`).join('')}</div>`;
SCREENS.create1 = () => `<section class="screen">${sbar()}${topb('New model')}
  <div class="pad stack-8">${stepbars(1)}<span class="lbl">Step 1 of 2</span><h2 class="h2">Who is she?</h2></div>
  <div class="pad stack-16" style="margin-top:12px"><label class="fld"><span class="lbl">Name</span><span class="inp typing">Noor Ellis</span></label>
   <div class="fld"><span class="lbl">Age · <b class="mono" id="age-v">27</b></span><div class="slider" data-slider="age" data-min="18" data-max="70" data-val="27"><i style="width:17%"></i><b style="left:17%"></b></div><div class="scale mono"><span>18</span><span>70</span></div></div>
   <div class="fld"><span class="lbl">Niche</span><div class="chips">${['Fashion','Beauty','Fitness','Travel','Food','Tech'].map(x=>`<span class="chip${x===S.create.niche?' on':''}" data-act="niche-${x}">${x}</span>`).join('')}</div></div>
   <div class="note-box">${ic('shield',18)}<span>Models are always 18+ and original. No lookalikes of real people.</span></div></div>
  <div class="dock"><div class="cta grow press" data-go="create3">Next: Character sheet</div></div>${home}</section>`;
const SHEET_SLOTS=[['face','Face · front','face'],['profile','Face · profile','profile'],['front','Body · front','g_front'],['tq','Body · ¾','g_tq'],['side','Body · side','g_side'],['back','Body · back','g_back']];
S.sheet = S.sheet || { face:{img:'face',src:'upload'}, profile:{img:'profile',src:'upload'}, front:{img:'g_front',src:'upload'} };
SCREENS.create3 = () => { const filled=SHEET_SLOTS.filter(([k])=>S.sheet[k]&&!S.sheet[k].busy).length; const faces=['face','profile'].filter(k=>S.sheet[k]).length;
  return `<section class="screen">${sbar()}${topb('New model')}
  <div class="pad stack-8">${stepbars(2)}<span class="lbl">Step 2 of 2</span><h2 class="h2">Character sheet</h2></div>
  <div class="pad stack-12 scroll" style="margin-top:8px;padding-bottom:130px"><p class="muted">Upload your model's images. Tap a slot to add or replace a shot.</p>
   <div class="slots">${SHEET_SLOTS.map(([k,n])=>{ const s=S.sheet[k];
     return `<div class="slot press" data-act="slot-${k}">${s?`<div class="ref-img${s.busy?' shimmer':''}" style="${s.busy?'':bg(s.img)}"></div>`:`<div class="slot-e">${ic('upload',20)}</div>`}<span>${n}${s&&!s.busy?` · <b class="${s.src==='generated'?'acc':''}">${s.src==='generated'?'filled in':'yours'}</b>`:''}</span></div>`; }).join('')}</div>
   <div class="cta-2 press" data-act="sheet-upload">${ic('upload',18)} Upload images</div>
   ${filled<6&&filled>0?`<div class="opt press" data-act="sheet-fill"><b>${ic('spark',16)} Fill missing angles from your images</b><span class="tiny muted">Optional. Adds the ${6-filled} missing angle${6-filled>1?'s':''} of your model · $${(0.02*(6-filled)).toFixed(2)}</span></div>`:''}
   ${faces<2?`<div class="note-box warn">${ic('shield',18)}<span>Tip: two face close-ups keep her face sharp and consistent in videos. You can still save without them.</span></div>`:`<div class="note-box">${ic('check',18)}<span>${filled} of 6 shots. ${filled<6?'More angles help when she turns. Optional.':'Full sheet. Her identity is locked.'}</span></div>`}
  </div>
  <div class="dock"><div class="cta grow press" data-act="model-saved">Save model · ${filled}/6</div></div>${home}</section>`; };

/* ---------- New outfit set ---------- */
S.newOutfit = S.newOutfit || { mode:'describe', desc:'Cream cable-knit sweater, light-wash straight jeans, white sneakers', state:'idle' };
SCREENS.outfit = () => { const o=S.newOutfit, angles=[['Front','c_front'],['¾','c_tq'],['Side','c_face'],['Back','c_front']];
  return `<section class="screen">${sbar()}${topb('New outfit')}
  <div class="pad stack-14 scroll" style="padding-bottom:120px"><h2 class="h2">Outfit set</h2><p class="muted">Sienna in a new outfit, from four angles. Used by every shoot and video with this outfit.</p>
   <div class="seg"><span class="${o.mode==='describe'?'on':''}" data-act="omode-describe">Describe</span><span class="${o.mode==='photo'?'on':''}" data-act="omode-photo">From a photo</span><span class="${o.mode==='own'?'on':''}" data-act="omode-own">My own set</span></div>
   ${o.mode==='describe'?`<label class="fld"><span class="lbl">Describe the outfit</span><textarea class="inp area" id="o-desc" rows="3">${o.desc}</textarea></label>`:
     o.mode==='photo'?`<div class="opt press" data-act="upload"><b>${ic('upload',16)} Upload a product or outfit photo</b><span class="tiny muted">Flat-lay, mannequin or model photo. We'll dress Sienna in it.</span></div>`:
     `<div class="opt press" data-act="upload"><b>${ic('upload',16)} Upload front, ¾, side and back</b><span class="tiny muted">Already have a set? Bring it in as is. Any missing angle can be generated later.</span></div>`}
   <label class="fld"><span class="lbl">Name</span><span class="inp">Cream knit + jeans</span></label>
   <div class="slots" style="grid-template-columns:1fr 1fr">${angles.map(([n,k],i)=>`<div class="slot"><div class="ref-img${o.state==='busy'?' shimmer':''}" style="${o.state==='done'?bg(k):''}"></div><span>${n}</span></div>`).join('')}</div>
   <p class="tiny muted">Plain, unbranded clothes work best. Visible logos carry into the video.</p></div>
  <div class="dock">${o.state==='done'?`<div class="cta-2 press" data-act="outfit-gen">${ic('retry',18)} Retake</div><div class="cta grow press" data-act="outfit-save">Save outfit</div>`:`<div class="cta grow press" data-act="outfit-gen">${o.mode==='own'?'Use my images':'Generate outfit set · $0.08'}</div>`}</div>${home}</section>`; };

/* ---------- Prompt engine (shared by every generator) ---------- */
const HOUSE = 'realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss';
function buildPrompt(kind){
  const m={name:'Sienna Vale', look:'young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin', never:['tattoos','rings']};
  const o=OUTFITS[S.outfit]||OUTFITS[0];
  if(kind==='shoot'){
    const parts={
      identity:`${m.name}: ${m.look}. Identity from 6 locked reference images.`,
      outfit:`Wearing: ${o[1].toLowerCase()} (outfit reference set).`,
      scene:`Scene: ${(S.scene||'Rooftop · golden hour').toLowerCase()}.`,
      camera:`Camera: ${S.shot.toLowerCase()} shot, ${S.lens}mm lens, ${S.aperture}${S.lens<=24?', slight wide-angle distortion':S.lens>=85?', compressed background, creamy bokeh':''}.`,
      light:`Light: ${S.light.toLowerCase()}; grade: ${(S.grade||'Phone-natural').toLowerCase()}.`,
      direction: S.direction? `Direction: ${S.direction}` : '',
      style:`Style: ${HOUSE}.`,
      negative:`Never add: ${m.never.join(', ')}, logos, extra fingers, warped jewellery.`,
      seed: S.lockSeed? 'Seed: locked (variations keep the same look).' : 'Seed: new each shot.'
    };
    return parts;
  }
}
const promptText = parts => Object.values(parts).filter(Boolean).join('\n');

const TOOLS=[['model','Model'],['outfit','Outfit'],['bg','Background'],['audio','Sound'],['quality','Quality']];
const SHOOT_TOOLS=[['model','Model'],['outfit','Outfit'],['bg','Scene'],['camera','Camera'],['light','Light'],['spark','Prompt']];
const toolstrip = (list=TOOLS, cur=S.tool, prefix='tool') => `<div class="tools">${list.map(([k,l])=>`<div class="tool press${k===cur?' on':''}" data-act="${prefix}-${k}">${ic(k,20)}<span>${l}</span></div>`).join('')}</div>`;
function sheetBody(){
  const t=T();
  if(S.tool==='quality'){
    let stepsUI;
    if(S.engine==='viggle') stepsUI = `<div class="note-box warn">${ic('shield',18)}<span>Fast · beta renders in about 2 minutes with exact motion timing, but faces are softer and can warp slightly. Fixed quality, no steps.</span></div>`;
    else if(t==='b') stepsUI = `<div class="plate"><i class="screw s1"></i><i class="screw s2"></i><i class="screw s3"></i><i class="screw s4"></i><span class="lbl">Steps</span><span class="stepsbadge" id="steps-v">${S.steps}</span><span class="tiny acc" id="steps-rec">${S.steps===10?'Recommended':S.steps>10?'Rarely worth it':'Below tested range'}</span>
        <div class="dialrow"><span class="knob-btn press" data-act="steps-dec">${ic('back',16)}</span><div class="knob" id="knob" style="transform:rotate(${(S.steps-17)*10}deg)"><i></i></div><span class="knob-btn press" data-act="steps-inc">${ic('chev',16)}</span></div>
        <div class="ruler" style="align-self:stretch">${Array.from({length:27},(_,i)=>`<i class="${i%5===0?'big':''}${i+4===S.steps?' on':''}"></i>`).join('')}</div><div class="scale mono" style="align-self:stretch"><span>4</span><span>10</span><span>20</span><span>30</span></div></div>`;
    else { const pct=(S.steps-4)/26*100; stepsUI = `<div class="${t==='c'?'stepcard':''} fld"><div class="row-b"><span class="lbl">Steps</span>${t==='d'?`<span class="stk stk-yellow" style="transform:rotate(-5deg)" id="steps-rec">${S.steps===10?'RECOMMENDED':S.steps>10?'TAKES LONGER':'TOO FEW?'}</span>`:pill(`<span id="steps-rec">${S.steps===10?'Recommended':S.steps>10?'Rarely worth it':'Below tested'}</span>`,S.steps===10?'good':'warn')}</div>
        <b class="stepnum${t==='a'?'':' mono'}" id="steps-v">${S.steps}</b><div class="slider" data-slider="steps" data-min="4" data-max="30" data-val="${S.steps}"><i style="width:${pct}%"></i><b style="left:${pct}%"></b></div><div class="scale mono"><span>4</span><span>10</span><span>20</span><span>30</span></div>
        <p class="tiny muted" id="steps-delta">${stepsDelta()}</p></div>`; }
    return `<div class="row-b"><b class="h3">Quality</b><div class="seg sm"><span class="${S.engine==='h3'?'on':''}" data-act="engine-h3">Standard</span><span class="${S.engine==='viggle'?'on':''}" data-act="engine-viggle">Fast · beta</span></div></div>${stepsUI}
`;
  }
  if(S.tool==='bg') return `<b class="h3">Background</b>
      <div class="opt press${S.bg==='keep'?' on':''}" data-act="bg-keep"><b>Keep the real room</b><span class="tiny muted">Best realism. Uses the clip's own background.</span></div>
      <div class="opt press${S.bg==='photo'?' on':''}" data-act="bg-photo"><b>New background photo</b><span class="tiny muted">Vertical photo, same camera height, similar light.</span></div>
      ${S.bg==='photo'?`<div class="fld"><span class="lbl">Background motion</span><div class="seg">${[['still','Still'],['subtle','Subtly alive'],['busy','Busy']].map(([k,l])=>`<span class="${S.motion===k?'on':''}" data-act="motion-${k}">${l}</span>`).join('')}</div></div>`:''}
`;
  if(S.tool==='audio') return `<b class="h3">Sound</b>
      <div class="opt press${S.keepAudio?' on':''}" data-act="audio-keep"><b>Keep the clip's audio</b><span class="tiny muted">The song or voice from your source clip.</span></div>
      <div class="opt press${!S.keepAudio?' on':''}" data-act="audio-new"><b>Replace audio</b><span class="tiny muted">Upload a new track or voiceover.</span></div>
      <div class="row-b"><span><b>Lip sync</b><br><span class="tiny muted">Only when the performer talks or sings · adds ~4 min</span></span><span class="tog${S.lip?' on':''}" data-act="lip"></span></div>`;
  if(S.tool==='outfit') return `<b class="h3">Outfit</b><div class="refrow">${OUTFITS.map(([k,n],i)=>`<div class="ofit press${i===S.outfit?' on':''}" data-act="outfit-${i}"><div class="ref-img tall" style="${bg(k)}"></div><span>${n}</span></div>`).join('')}${addTile()}</div><p class="tiny muted">Never add: tattoos, rings. Removed automatically.</p>`;
  if(S.tool==='model') return `<b class="h3">Model</b><div class="refrow"><div class="ofit on"><div class="ref-img tall" style="${bg('face')}"></div><span>Sienna</span></div><div class="ofit"><div class="ref-img tall init">N</div><span>Noor · needs close-ups</span></div></div>`;
  return '';
}
function shootSheet(){
  const k=S.stool||'camera';
  if(k==='spark'){ const p=buildPrompt('shoot');
    return `<div class="row-b"><b class="h3">Prompt</b><span class="tiny muted">Built from your choices</span></div>
     <label class="fld"><span class="lbl">Your direction</span><textarea class="inp area" id="dir" rows="2" placeholder="e.g. laughing mid-step, hair blowing, holding an iced coffee">${S.direction||''}</textarea></label>
     <div class="row-b"><span><b>Lock look</b><br><span class="tiny muted">Same seed, so retakes stay consistent</span></span><span class="tog${S.lockSeed?' on':''}" data-act="lockseed"></span></div>
     <div class="fld"><span class="lbl">Final prompt</span><div class="pbox">${Object.entries(p).filter(([,v])=>v).map(([kk,v])=>`<div><span class="pk">${kk}</span>${v.replace(/^[A-Za-z ]+: /,'')}</div>`).join('')}</div></div>
     <div class="row-g"><div class="cta-2 grow press" data-act="copyprompt">Copy</div><div class="cta-2 grow press" data-act="editprompt">Edit as text</div></div>`; }
  if(k==='camera') return `<div class="row-b"><b class="h3">Camera</b><span class="tiny acc press" data-act="shoot-reset">Reset</span></div>
   <div class="fld"><span class="lbl">Shot</span><div class="seg">${['Close','Medium','Full','Wide'].map(x=>`<span class="${S.shot===x?'on':''}" data-act="shot-${x}">${x}</span>`).join('')}</div></div>
   <div class="fld"><span class="lbl">Lens · ${S.lens}mm</span><div class="chips">${[16,24,35,50,85].map(x=>`<span class="chip${S.lens===x?' on':''}" data-act="lens-${x}">${x}mm</span>`).join('')}</div></div>
   <div class="fld"><span class="lbl">Aperture</span><div class="chips">${['f/1.4','f/2.8','f/5.6','f/11'].map(x=>`<span class="chip${S.aperture===x?' on':''}" data-act="ap-${x}">${x}</span>`).join('')}</div></div>`;
  if(k==='light') return `<b class="h3">Light</b><div class="chips">${['Golden hour','Overcast','Ring light','Window light','Flash','Neon night'].map(x=>`<span class="chip${S.light===x?' on':''}" data-act="light-${x}">${x}</span>`).join('')}</div>
   <div class="fld"><span class="lbl">Grade</span><div class="chips">${['Phone-natural','Warm film','Editorial','Muted'].map(x=>`<span class="chip${(S.grade||'Phone-natural')===x?' on':''}" data-act="grade-${x}">${x}</span>`).join('')}</div></div>`;
  if(k==='bg') return `<b class="h3">Scene</b><div class="chips">${['Rooftop · golden hour','Bedroom mirror','Café window','Beach noon','City night'].map(x=>`<span class="chip${(S.scene||'Rooftop · golden hour')===x?' on':''}" data-act="scene-${x}">${x}</span>`).join('')}</div><label class="fld"><span class="lbl">Or describe your own</span><textarea class="inp area" id="scene-custom" rows="2" placeholder="e.g. sunlit rooftop bar, string lights, city skyline">${S.sceneCustom||''}</textarea></label>`;
  if(k==='outfit') return `<b class="h3">Outfit</b><div class="refrow">${OUTFITS.map(([kk,n],i)=>`<div class="ofit press${i===S.outfit?' on':''}" data-act="outfit-${i}"><div class="ref-img tall" style="${bg(kk)}"></div><span>${n}</span></div>`).join('')}${addTile()}</div>`;
  return `<b class="h3">Model</b><div class="refrow"><div class="ofit on"><div class="ref-img tall" style="${bg('face')}"></div><span>Sienna</span></div><div class="ofit"><div class="ref-img tall init">N</div><span>Noor · draft</span></div></div>`;
}
function stepsDelta(){ if(S.steps===10) return 'Same quality as 15 or 20 steps in testing, for less time.'; const d=(S.steps-10)*secPerLen(LENS())/60, c=d/60*3.99; return `${d>0?'+':'−'}${Math.abs(d).toFixed(1)} min · ${d>0?'+':'−'}${money(Math.abs(c))} vs 10 steps${S.steps>10?' · no visible gain in testing':' · may lose detail'}`; }
function genLabel(){ const m=estMin(); return `Generate · ${m<2?Math.round(m*60)+'s':Math.round(m)+' min'} · ${money(estCost())}`; }
SCREENS.direct = () => {
  const t=T(), readout = t==='b'?`<span class="readout tl-r mono"><i class="rec"></i> 00:00:05:04</span><span class="readout br-r mono">OUTPUT 768×1344</span>`:'';
  const head = t==='a'?`<header class="top">${'<span class="tb-btn press" data-back>'+ic('back')+'</span>'}<span class="grow center">${wm('c')}</span><span class="tiny mono" style="letter-spacing:.12em">VIDEO STUDIO</span></header>`: topb(t==='b'?'Video studio':'Video studio','back',['more','settings']);
  return `<section class="screen">${sbar()}${head}
  <div class="canvas" style="${bg(S.bg==='photo'?'vid_bath':'vid_living')}">${vf()}${readout}<div class="canvas-bar"><span class="press" data-act="play">${ic('play',16)}</span><div class="track"><i id="trk" style="width:38%"></i></div><span class="mono tiny">0:02 / 0:05</span></div>
   </div>
  ${toolstrip()}<div class="bsheet stack-12" id="sheet"><i class="grab"></i>${sheetBody()}</div>
  <div class="dock tight"><div class="cta grow press" id="gen" data-act="generate">${genLabel()}</div></div>${home}</section>`;
};
SCREENS.source = () => { const bad=S.clipBad;
  const ck = bad ? [['People in frame','2 found','bad','Crop it, or pick a clip with one person'],['Watermark','TikTok logo','bad','Use the original file, not a download'],['1080×1920 · 30fps','OK','good'],['Length 22s','Over 15s','bad','Trim to 15s or less'],['Performer talking','No','']]
                 : [['One person in frame','Yes','good'],['Watermark','None','good'],['1080×1920 · 30fps','OK','good'],['Length 9.4s','Max 15s','good'],['Performer talking','No','']];
  const opt=(k,l)=>{ const len=k==='full'?9.4:5.2, m=S.steps*secPerLen(len)/60+0.5, c=m/60*3.99; return `<span class="${S.use===k?'on':''}" data-act="use-${k}">${l} · ~${Math.round(m)}m · ${money(c)}</span>`; };
  const blocked = bad;
  return `<section class="screen">${sbar()}${topb('New video')}
  <div class="pad stack-14 scroll" style="padding-bottom:130px"><div class="clipcard"><div class="clip-th" style="${bg('src_clip')}">${ic('play',18)}</div><div class="stack-8 grow">${ck.map(([x,y,k,fix])=>`<div class="stack-4"><div class="row-b tiny"><span>${x}</span>${pill((k==='bad'?'✕ ':k==='good'?'✓ ':'')+y,k==='bad'?'warn':k)}</div>${fix?`<span class="tiny" style="color:var(--warn)">${fix}</span>`:''}</div>`).join('')}</div></div>
   <span class="tiny acc press" data-act="clipbad" style="align-self:flex-start;padding:6px 0">${bad?'Use the good sample clip':'Preview: what a failing clip looks like'}</span>
   ${bad?'':`<div class="fld"><span class="lbl">Use · price at ${S.steps} steps</span><div class="seg">${opt('first','First 5.2s')}${opt('full','Full 9.4s')}</div></div>`}
</div>
  <div class="dock"><div class="cta grow press${blocked?' is-off':''}" ${blocked?'data-act="blocked"':'data-go="direct"'}>${bad?'Fix the clip to continue':'Next: Direct'}</div></div>${home}</section>`; };

SCREENS.shoot = () => `<section class="screen">${sbar()}${topb('Photoshoot','back',['more','settings'])}
  <div class="canvas short" style="${bg('c_tq')};height:220px">${vf()}${T()==='b'?`<span class="readout tl-r mono">${S.lens}MM · ${S.aperture.toUpperCase()} · 4300K</span>`:''}${stk('rooftop · golden hour','yellow',-4,'position:absolute;left:12px;bottom:12px')}</div>
  ${toolstrip(SHOOT_TOOLS, S.stool||'camera', 'stool')}
  <div class="bsheet stack-14" id="ssheet"><i class="grab"></i>${shootSheet()}</div>
  <div class="dock tight"><div class="cta grow press" data-act="shoot">Shoot 4 · ~32s · $0.12</div></div>${home}</section>`;

const failCard = () => S.failDismissed?'':`<div class="note-box warn" style="align-items:center">${ic('shield',18)}<span class="grow"><b>Render failed · Mirror selfie</b><br><span class="tiny">The GPU disconnected at step 3. $0.19 refunded.</span></span><span class="cta-2 press" style="height:40px" data-act="retryfail">Retry</span></div>`;
function fmt(s){ s=Math.max(0,Math.round(s)); return String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0'); }
SCREENS.queue = () => {
  const t=T(), r=S.running, jobs=[...(r?[r]:[]), ...S.jobs];
  const kpis = `<div class="kpis"><div><span class="lbl">Month</span><b class="mono">${money(S.month)}</b></div><div><span class="lbl">Balance</span><b class="mono">${money(S.balance)}</b></div><div><span class="lbl">GPU</span><b class="mono">${S.running?'H100':'Off'}</b></div></div>`;
  if(t==='a') return `<section class="screen">${sbar()}<header class="top">${wm()}<span class="grow"></span><span class="tiny mono" style="letter-spacing:.12em">RENDER QUEUE <b class="acc">●</b></span></header>
    <div class="pad scroll"><div class="row-b" style="align-items:flex-end;margin-top:6px"><span class="cond renders-t">Your renders</span><span class="tiny mono">${r?'1 RUNNING · ':''}${S.jobs.length} DONE</span></div>
     ${jobs.map(j=>`<div class="rj press" data-act="open-${j.id}"><div class="th" style="${bg(j.img)}"></div><div class="grow stack-4"><b style="font-weight:500">${j.title}</b><span class="meta">9:16 · ${j.engine.toUpperCase()}</span><div class="row-b"><div class="bar grow"><i data-job="${j.id}" style="width:${j.p}%"></i></div><span class="mono tiny" data-pct="${j.id}">${Math.round(j.p)}%</span></div></div><span class="muted tb-btn press" data-act="jmenu-${j.id}">${ic('more',18)}</span></div>`).join('')}
     <div class="cta-2 press" data-go="source" style="margin-top:16px">${ic('plus',18)} New video</div>
    </div>${tabbar('queue')}${home}</section>`;
  if(t==='c'){ const stages=[['Model processing',30],['Outfit generation',55],['Video rendering',92],['Finalizing',100]];
    const p = r? r.p : 100;
    if(!r) return `<section class="screen">${sbar()}<header class="top">${wm('c')}<span class="grow"></span><span class="tb-btn press" data-go="settings">${ic('user')}</span></header>
    <div class="pad stack-14 scroll"><h2 class="h2">Render queue</h2><div class="stage-row" style="flex-direction:column;align-items:flex-start"><span class="muted">Queue</span><b style="font-size:22px;font-weight:500">Nothing rendering right now</b><span class="tiny muted">You're not being charged.</span><div class="cta-2 press" data-go="source" style="align-self:stretch;margin-top:6px">${ic('plus',18)} New video</div></div>
     ${failCard()}<span class="lbl">Finished</span>${S.jobs.map(j=>`<div class="job press" data-act="open-${j.id}"><div class="job-th" style="${bg(j.img)}"></div><div class="grow stack-4"><div class="row-b"><b>${j.title}</b><span class="mono tiny">${money(j.cost)}</span></div><span class="tiny muted">${j.engine} · took ${j.tc}</span>${pill('Done','good')}</div></div>`).join('')}</div>
    ${tabbar('queue')}${home}</section>`;
    return `<section class="screen">${sbar()}${topb('Render queue',null)}
    <div class="pad stack-14"><span class="muted" style="margin-top:8px">Time left</span><b class="bigtime" id="bigtime">${fmt(r.left)}</b><span class="muted">Generating your video…</span>
     ${stages.map(([n,lim],i)=>{ const prev=i?stages[i-1][1]:0; const sp=Math.max(0,Math.min(100,(p-prev)/(lim-prev)*100)); const st=sp>=100?'done':sp>0?'run':'';
       return `<div class="stage-row"><span class="stage-ic ${st}">${st==='done'?ic('check',14):''}</span><div class="grow stack-4"><div class="row-b"><span>${n}</span><span class="mono tiny" data-stagep="${i}">${Math.round(sp)}%</span></div><div class="bar"><i data-stage="${i}" style="width:${sp}%"></i></div></div></div>`; }).join('')}
     <div class="row-b tiny muted"><span>${S.jobs.length} finished · see Gallery</span><span class="acc press" data-go="gallery">Open ›</span></div></div>
    ${tabbar('queue')}${home}</section>`; }
  if(t==='d') return `<section class="screen">${sbar()}<header class="top">${wm()}<span class="grow tiny" style="text-align:right;font-weight:700">RENDER QUEUE</span><span class="tb-btn press" data-go="settings">${ic('quality')}</span></header>
    <div class="pad stack-12 scroll"><div style="position:relative"><span class="dhead">YOUR RENDERS</span><span class="doodle" style="right:4px;top:0">${DOODLE.crown}</span></div>${failCard()}
     ${jobs.map((j,i)=>`<div class="djob press" data-act="open-${j.id}"><div class="th" style="${bg(j.img)}"></div><div class="grow stack-4"><b>Sienna Vale · ${j.title}</b><span class="tiny muted">${j.engine}</span><div class="row-b" style="gap:8px"><div class="dbar grow${j.state==='done'?' p':''}"><i data-job="${j.id}" style="width:${j.p}%"></i></div><span class="bigpct" data-pct="${j.id}">${Math.round(j.p)}%</span></div><span class="tiny muted">${j.state==='done'?'Done · '+money(j.cost):'~'+fmt(j.left)+' left · '+money(j.cost)}</span></div></div>`).join('')}
     <div class="cta big press" data-go="source" style="margin-top:6px">${ic('plus',22)} New video</div>
    </div>${tabbar('queue')}${home}</section>`;
  return `<section class="screen">${sbar()}${topb('Render queue',null)}
    <div class="pad stack-12 scroll"><div class="row-b"><span class="tiny mono acc">${r?'1 ACTIVE':'NOTHING RUNNING'}</span>${pill(r?'● Rendering':'Idle',r?'good':'')}</div>
     ${jobs.map(j=>`<div class="job press" data-act="open-${j.id}"><div class="job-th" style="${bg(j.img)}"></div><div class="grow stack-4"><div class="row-b"><span class="tc" data-tc="${j.id}">${j.state==='done'?j.tc:fmt(j.left)}</span><span class="st ${j.state==='done'?'':'r'}">● ${j.state==='done'?'DONE':'RENDERING'}</span></div>
       <span class="tiny muted">Sienna Vale · ${j.title}</span><span class="tiny mono muted">9:16 · 24fps · ${j.engine}</span><div class="row-b" style="gap:8px"><div class="bar grow"><i data-job="${j.id}" style="width:${j.p}%"></i></div><span class="mono tiny" data-pct="${j.id}">${Math.round(j.p)}%</span></div></div></div>`).join('')}
     ${failCard()}${kpis}</div>${tabbar('queue')}${home}</section>`;
};

SCREENS.result = () => { const j=S.open||S.jobs[0];
  return `<section class="screen"><div class="full" style="${bg(j.img==='c_tq'?'c_tq':j.img)}">${sbar(true)}${topb('Take 1 of 1','back',['more','settings'],true)}${vf()}
   <div class="res-side"><div class="rs press" data-go="direct">${ic('retry')}<span>Retry · ${money(estCost())}</span></div><div class="rs press" data-act="export">${ic('export')}<span>Export</span></div></div>
   </div>
  <div class="res-sheet stack-12"><div class="row-b"><div><b class="h3">${j.title}</b><div class="tiny muted">${j.engine} · ${money(j.cost)}</div></div>${pill(S.final.includes(j.id)?'Final':'Test',S.final.includes(j.id)?'good':'')}</div>
   <p class="tiny muted">${ic('shield',14)} Exports carry the AI-generated label. Brand posts also need #ad.</p>
   <div class="row-g"><div class="cta-2 grow press" data-act="discard">Discard</div><div class="cta grow press" data-act="approve">${S.final.includes(j.id)?'Approved ✓':'Approve'}</div></div></div>${home}</section>`; };

SCREENS.gallery = () => { const fresh=S.newShots||0; S.newShots=0; const tiles=[...(S.shots||[]).map(s=>[s[0],s[1]+'',s[2]]),...S.jobs.filter(j=>j.id.length>3).map(j=>[j.img,j.title,j.id]),['vid_living','10 steps','g1'],['vid_kick','Fast · beta','j1'],['vid_bath','30 steps','j2'],['c_front','Shoot','g4'],['vid_living2','15 steps','g5'],['c_tq','Shoot','g6']];
  const list = S.gallery==='final' ? tiles.filter(x=>S.final.includes(x[2])) : tiles;
  return `<section class="screen">${sbar()}<header class="top">${wm()}<span class="grow"></span><span class="tb-btn">${ic('grid')}</span></header>
  <div class="pad stack-14"><h2 class="h2">${T()==='a'?'<span class="cond" style="font-size:56px">Gallery</span>':'Gallery'}</h2>
   <div class="seg"><span class="${S.gallery==='tests'?'on':''}" data-act="gal-tests">Tests · ${tiles.length}</span><span class="${S.gallery==='final'?'on':''}" data-act="gal-final">Final · ${S.final.length}</span></div>
   ${list.length?`<div class="gal">${list.map(([k,l],i)=>`<div class="gt pop-in" style="${bg(k)};animation-delay:${i*60}ms${i<fresh?';box-shadow:0 0 0 3px var(--accent)':''}"><span class="gt-l">${i<fresh?'New · ':''}${l}</span></div>`).join('')}</div>`:`<div class="note-box">${ic('spark',18)}<span>Nothing approved yet. Approve a take to move it here.</span></div>`}
   <p class="tiny muted">Test renders stay separate from your Final gallery.</p></div>${tabbar('gallery')}${home}</section>`; };

const THEMES=[['a','Editorial','#EFEBE3','#141210','#B5121B'],['b','Camera Body','#0D0E0F','#ECEAE5','#F2A93B'],['c','Soft Tactile','#E7E2D9','#23262A','#6E8465'],['d','Creator Pop','#1F4BFF','#FFF6EC','#FF7EB6']];
SCREENS.settings = () => `<section class="screen">${sbar()}${topb('Settings',null)}
  <div class="pad stack-16"><div class="fld"><span class="lbl">Theme</span><div class="thms">${THEMES.map(([k,n,b,f,a])=>`<div class="thm press${k===T()?' on':''}" data-act="theme-${k}"><div class="thm-prev" style="background-image:url(${IMG['th_'+k]})"></div><span>${n}</span>${k===T()?`<b class="thm-c">${ic('check',14)}</b>`:''}</div>`).join('')}</div></div>
   <div class="list"><div class="li press" data-act="sound">${ic('audio',20)}<span class="grow">Notification sound</span><span class="tog${S.sound?' on':''}"></span></div>
    <div class="li press" data-go="credits">${ic('wallet',20)}<span class="grow">Credits & billing</span><span class="tiny muted">${money(S.balance)}</span>${ic('chev',16)}</div>
    
    <div class="li press" data-act="signout">${ic('user',20)}<span class="grow">Sign out</span>${ic('chev',16)}</div></div>
   <p class="tiny muted center">Video model: MiniMax H3 · Lip sync: LatentSync</p></div>${tabbar('settings')}${home}</section>`;

SCREENS.credits = () => `<section class="screen">${sbar()}${topb('Credits')}
  <div class="pad stack-16"><div class="balcard"><span class="lbl lbl-inv">GPU balance</span><b class="bal-n mono" id="bal">${money(S.balance)}</b><span class="tiny">≈ ${Math.floor(S.balance/estCost())} videos at 10 steps</span>${stk('top up!','yellow',-6,'position:absolute;right:16px;top:16px')}</div>
   <div class="fld"><span class="lbl">Top up</span><div class="seg">${['$10','$25','$50','$100'].map(x=>`<span class="${x==='$25'?'on':''}">${x}</span>`).join('')}</div></div>
   <div class="kpis"><div><span class="lbl">This month</span><b class="mono">${money(S.month)}</b></div><div><span class="lbl">Per video</span><b class="mono">~${money(estCost())}</b></div><div><span class="lbl">Videos</span><b class="mono">${9+S.jobs.length}</b></div></div>
   <div class="fld"><span class="lbl">Spend limits</span><div class="li">${ic('shield',20)}<span class="grow">Per job</span><span class="mono tiny">$5.00</span></div><div class="li">${ic('shield',20)}<span class="grow">Per day</span><span class="mono tiny">$15.00</span></div></div></div>
  <div class="dock"><div class="cta grow press" data-act="topup">Add $25</div></div>${home}</section>`;

/* ---------------- Navigation + transitions (per theme) ---------------- */
const MOTION = {
  a: { dur: 460, ease: 'cubic-bezier(.22,.61,.36,1)', inF: d => [{opacity:0, transform:`translateY(${d>0?18:-18}px)`},{opacity:1, transform:'none'}], outF: d => [{opacity:1},{opacity:0}] },
  b: { dur: 230, ease: 'cubic-bezier(.4,0,.2,1)', inF: d => [{transform:`translateX(${d>0?100:-30}%)`},{transform:'none'}], outF: d => [{transform:'none', filter:'brightness(1)'},{transform:`translateX(${d>0?-30:100}%)`, filter:'brightness(.5)'}], flash: true },
  c: { dur: 520, ease: 'cubic-bezier(.2,1.25,.35,1)', inF: d => [{transform:`translateX(${d>0?100:-25}%) scale(.96)`, borderRadius:'40px'},{transform:'none', borderRadius:'0px'}], outF: d => [{transform:'none', opacity:1},{transform:`translateX(${d>0?-25:100}%) scale(.94)`, opacity:.6}] },
  d: { dur: 480, ease: 'cubic-bezier(.3,1.6,.5,1)', inF: d => [{transform:`translateY(${d>0?40:-40}%) rotate(${d>0?6:-6}deg) scale(.85)`, opacity:0},{transform:'none', opacity:1}], outF: d => [{transform:'none', opacity:1},{transform:'scale(.9)', opacity:0}] },
};
let busy=false;
function render(name, dir=0){
  closeMenu();
  const phone=$('#phone'); const old=phone.querySelector('.view'); const v=document.createElement('div'); v.className='view';
  v.innerHTML = SCREENS[name](); phone.appendChild(v); S.screen=name; bindScreen(v);
  const m=MOTION[S.theme];
  if(old){ if(dir===0){ old.remove(); }
    else { busy=true; const oa=old.animate(m.outF(dir),{duration:m.dur,easing:m.ease,fill:'forwards'}); v.animate(m.inF(dir),{duration:m.dur,easing:m.ease});
      if(m.flash){ const f=$('#flash'); f.classList.remove('go'); void f.offsetWidth; f.classList.add('go'); }
      oa.onfinish=()=>{ old.remove(); busy=false; }; setTimeout(()=>{ if(old.isConnected) old.remove(); busy=false; }, m.dur+80); } }
  updateSide();
}
function go(name){ if(busy||name===S.screen) return; S.stack.push(S.screen); snd('nav'); render(name, 1); }
function back(){ if(busy) return; const p=S.stack.pop()||'home'; snd('nav'); render(p, -1); }
function refresh(){ const v=$('#phone .view'); if(!v) return; const y=v.querySelector('.scroll')?.scrollTop; v.innerHTML=SCREENS[S.screen](); bindScreen(v); }
function refreshSheet(){ const sh=$('#sheet'); if(sh){ sh.innerHTML='<i class="grab"></i>'+sheetBody(); bindScreen(sh); const g=$('#gen'); if(g) g.textContent=genLabel(); sh.animate([{transform:'translateY(14px)',opacity:.6},{transform:'none',opacity:1}],{duration:260,easing:MOTION[S.theme].ease}); } }

const MENUS = {
  plus: [['studio','New video','go:source'],['camera','Photoshoot','go:shoot'],['model','New model','go:create1']],
  pay: [['wallet','Card · Visa / Mastercard','m-paid'],['wallet','USDT (TRC-20)','m-paid'],['wallet','Virtual dollar card','m-paid']],
  profile: [['spark','Edit character sheet','go:create3'],['grid','Character sheet','go:create3'],['outfit','Add outfit','go:outfit'],['retry','Duplicate model','m-dup'],['export','Share profile card','m-share'],['shield','Delete model','m-delete','danger']],
  direct: [['spark','Show prompt','m-prompt'],['quality','Save as preset','m-preset'],['retry','Reset settings','m-reset'],['studio','Change clip','go:source'],['quality','How steps work','m-stepshelp']],
  shoot: [['spark','Show prompt','m-shootprompt'],['quality','Save as preset','m-preset'],['retry','Reset camera','shoot-reset'],['model','Change model','m-model']],
  result: [['export','Download','export'],['spark','Copy prompt','m-copy'],['grid','Compare takes','m-compare'],['bell','Report a problem','m-report'],['shield','Delete take','discard','danger']],
  job: [['play','Watch','m-watch'],['retry','Run again with same settings','m-rerun'],['spark','Copy prompt','m-copy'],['shield','Remove from list','m-remove','danger']]
};
function openMenu(kind, anchor, jobId){
  closeMenu(); const items=MENUS[kind]; if(!items) return; S.menuJob=jobId||null;
  const ph=$('#phone'), pr=ph.getBoundingClientRect(), ar=anchor.getBoundingClientRect(), sc=pr.width/ph.offsetWidth;
  const scrim=document.createElement('div'); scrim.className='menu-scrim'; scrim.onclick=closeMenu;
  const m=document.createElement('div'); m.className='menu'; m.setAttribute('role','menu');
  m.innerHTML=items.map(([i,l,ac,cls])=>`<div class="mi ${cls||''}" role="menuitem" data-mi="${ac}">${ic(i,18)}<span>${l}</span></div>`).join('');
  const top=(ar.bottom-pr.top)/sc+4; m.style.top=Math.min(top, ph.offsetHeight-items.length*46-40)+'px'; m.style.right=Math.max(12,(pr.right-ar.right)/sc)+'px';
  ph.appendChild(scrim); ph.appendChild(m); snd('tap');
  m.animate([{opacity:0,transform:'scale(.85) translateY(-6px)'},{opacity:1,transform:'none'}],{duration:180,easing:MOTION[S.theme].ease});
  m.addEventListener('click',e=>{ const it=e.target.closest('[data-mi]'); if(!it) return; e.stopPropagation(); const v=it.dataset.mi; closeMenu(); snd('tap'); menuAction(v); });
}
function closeMenu(){ document.querySelectorAll('#phone .menu,#phone .menu-scrim').forEach(x=>x.remove()); }
function menuAction(v){
  if(v.startsWith('go:')) return go(v.slice(3));
  const job=[S.running,...S.jobs].find(x=>x&&x.id===S.menuJob);
  const msg={ 'm-dup':'Duplicated as "Sienna Vale copy"', 'm-share':'Profile card ready to share', 'm-delete':'Delete is disabled in this demo',
    'm-preset':'Saved as preset "Living-room dance · 10 steps"', 'm-stepshelp':'10 steps is enough: 15 and 20 looked the same in testing', 'm-model':'Only Sienna is ready · Noor needs close-ups',
    'm-compare':'Compare takes · needs 2+ takes', 'm-report':'Thanks · report sent with the prompt and seed', 'm-copy':'Prompt copied', 'm-paid':'Demo · no payment taken', 'm-rerun':'Settings loaded · tap Generate' }[v];
  if(v==='m-reset'){ S.steps=10; S.engine='h3'; S.bg='keep'; S.lip=false; S.keepAudio=true; refreshSheet(); return toast('Reset to recommended'); }
  if(v==='m-prompt'){ return toast('Prompt: replace the performer with Sienna · keep motion & room · '+S.steps+' steps'); }
  if(v==='m-shootprompt'){ S.stool='spark'; document.querySelectorAll('.tool').forEach(t=>t.classList.toggle('on', t.dataset.act==='stool-spark')); return rShoot(); }
  if(v==='m-watch'&&job){ if(job.state!=='done') return toast('Still rendering'); S.open=job; return go('result'); }
  if(v==='m-remove'&&job){ S.jobs=S.jobs.filter(x=>x!==job); refresh(); return toast('Removed'); }
  if(v==='m-rerun'){ go('direct'); }
  if(v==='export'||v==='discard'||v==='shoot-reset') return act(v, document.body);
  if(msg) toast(msg);
}
function rShoot(){ const sh=$('#ssheet'); if(sh){ sh.innerHTML='<i class="grab"></i>'+shootSheet(); } const ro=document.querySelector('.canvas .readout'); if(ro) ro.textContent=`${S.lens}MM · ${S.aperture.toUpperCase()} · 4300K`; }
function toast(msg, onTap){ const t=$('#toast'); t.innerHTML=ic('spark',18)+'<span>'+msg+'</span>'; t.classList.add('show'); t.onclick=()=>{ t.classList.remove('show'); onTap&&onTap(); }; clearTimeout(toast.t); toast.t=setTimeout(()=>t.classList.remove('show'), 3200); }
function confetti(){ if(S.theme!=='d') return; const c=document.createElement('div'); c.className='confetti'; const cols=['#FF7EB6','#FFE14D','#39D98A','#1F4BFF','#fff'];
  for(let i=0;i<40;i++){ const p=document.createElement('i'); p.style.left=Math.random()*100+'%'; p.style.background=cols[i%5]; p.style.animationDelay=(Math.random()*.4)+'s'; p.style.borderRadius=S.theme==='c'?'50%':'2px'; if(S.theme==='c') p.style.border='0'; c.appendChild(p); }
  $('#phone').appendChild(c); setTimeout(()=>c.remove(), 2000); }

/* ---------------- Interactions ---------------- */
function setSteps(n){ n=Math.max(4,Math.min(30,n)); if(n===S.steps) return; S.steps=n; snd('tick');
  const v=$('#steps-v'); if(v){ v.textContent=n; v.animate([{transform:'scale(1.25)'},{transform:'scale(1)'}],{duration:180}); }
  const rec=$('#steps-rec'); if(rec) rec.textContent = S.theme==='d'?(n===10?'RECOMMENDED':n>10?'TAKES LONGER':'TOO FEW?'):(n===10?'Recommended':n>10?'Rarely worth it':'Below tested range');
  const k=$('#knob'); if(k) k.style.transform=`rotate(${(n-17)*10}deg)`;
  const sl=document.querySelector('[data-slider="steps"]'); if(sl){ const p=(n-4)/26*100; sl.querySelector('i').style.width=p+'%'; sl.querySelector('b').style.left=p+'%'; }
  document.querySelectorAll('.plate .ruler i').forEach((t,i)=>t.classList.toggle('on', i+4===n));
  const g=$('#gen'); if(g) g.textContent=genLabel(); const sd=$('#steps-delta'); if(sd) sd.textContent=stepsDelta(); }
function bindScreen(root){
  root.querySelectorAll('[data-slider]').forEach(sl=>{
    const min=+sl.dataset.min, max=+sl.dataset.max;
    const upd=e=>{ const r=sl.getBoundingClientRect(); const x=Math.max(0,Math.min(1,(e.clientX-r.left)/r.width)); const val=Math.round(min+x*(max-min));
      if(sl.dataset.slider==='steps') setSteps(val); else { if(+sl.dataset.val!==val){ sl.dataset.val=val; snd('tick'); } sl.querySelector('i').style.width=x*100+'%'; sl.querySelector('b').style.left=x*100+'%'; const o=$('#age-v'); if(o) o.textContent=val; } };
    sl.style.touchAction='none';
    sl.addEventListener('pointerdown',e=>{ sl.setPointerCapture(e.pointerId); upd(e); const mv=ev=>upd(ev); sl.addEventListener('pointermove',mv); sl.addEventListener('pointerup',()=>sl.removeEventListener('pointermove',mv),{once:true}); });
  });
  const knob=root.querySelector('#knob');
  if(knob){ let start=null, startSteps=10;
    knob.addEventListener('pointerdown',e=>{ knob.setPointerCapture(e.pointerId); const r=knob.getBoundingClientRect(); start={cx:r.left+r.width/2, cy:r.top+r.height/2, a:Math.atan2(e.clientY-(r.top+r.height/2), e.clientX-(r.left+r.width/2))}; startSteps=S.steps; });
    knob.addEventListener('pointermove',e=>{ if(!start) return; let a=Math.atan2(e.clientY-start.cy, e.clientX-start.cx)-start.a; if(a>Math.PI) a-=2*Math.PI; if(a<-Math.PI) a+=2*Math.PI; setSteps(startSteps+Math.round(a*180/Math.PI/10)); });
    knob.addEventListener('pointerup',()=>start=null);
  }
}
function act(a, el){
  const [k, ...rest] = a.split('-'); const v = rest.join('-');
  if(a==='signin'){ snd('go'); S.stack=[]; render('home',1); return; }
  if(a==='ag1'||a==='ag2'){ S[a]=!S[a]; refresh(); return; }
  if(a==='needag'){ toast('Tick both boxes to continue'); return; }
  if(a==='signout'){ S.stack=[]; render('welcome',-1); return; }
  if(k==='slot'){ S.sheet[v]={img:(SHEET_SLOTS.find(x=>x[0]===v)||[])[2],src:'upload'}; toast('Image added · '+(SHEET_SLOTS.find(x=>x[0]===v)||[])[1]); refresh(); return; }
  if(a==='sheet-upload'){ const miss=SHEET_SLOTS.filter(([kk])=>!S.sheet[kk]); if(!miss.length){ toast('All 6 slots filled · tap one to replace'); return; } miss.forEach(([kk,,img])=>S.sheet[kk]={img,src:'upload'}); toast(miss.length+' images added'); refresh(); return; }
  if(a==='sheet-fill'){ const miss=SHEET_SLOTS.filter(([kk])=>!S.sheet[kk]); miss.forEach(([kk])=>S.sheet[kk]={busy:true}); refresh(); snd('go');
    setTimeout(()=>{ miss.forEach(([kk,,img])=>S.sheet[kk]={img,src:'generated'}); snd('done'); if(S.screen==='create3') refresh(); },1600); return; }
  if(k==='omode'){ S.newOutfit.mode=v; S.newOutfit.state='idle'; refresh(); return; }
  if(a==='outfit-gen'){ const d=$('#o-desc'); if(d) S.newOutfit.desc=d.value; S.newOutfit.state='busy'; refresh(); snd('go'); setTimeout(()=>{ S.newOutfit.state='done'; snd('done'); if(S.screen==='outfit') refresh(); },1700); return; }
  if(a==='outfit-save'){ OUTFITS.push(['c_tq','Cream knit + jeans',['c_front','c_tq','c_face','c_front']]); S.outfit=OUTFITS.length-1; S.newOutfit.state='idle'; snd('done'); confetti(); toast('Outfit saved · selected for your next shoot'); back(); return; }
  if(a==='lockseed'){ S.lockSeed=!S.lockSeed; rShoot(); return; }
  if(a==='copyprompt'){ const t=promptText(buildPrompt('shoot')); try{ navigator.clipboard.writeText(t).then(()=>toast('Prompt copied'),()=>toast('Copy blocked here · use Edit as text')); }catch(e){ toast('Copy blocked here'); } return; }
  if(a==='editprompt'){ toast('Advanced: edit the full prompt as text (pro mode)'); return; }
  if(a==='menu'){ openMenu(S.screen, el); return; }
  if(a==='plusmenu'){ openMenu('plus', el); return; }
  if(k==='jmenu'){ openMenu('job', el, v); return; }
  if(k==='stool'){ S.stool=v; document.querySelectorAll('.tool').forEach(t=>t.classList.toggle('on', t.dataset.act===a)); const sh=$('#ssheet'); if(sh){ sh.innerHTML='<i class="grab"></i>'+shootSheet(); sh.animate([{transform:'translateY(14px)',opacity:.6},{transform:'none',opacity:1}],{duration:260,easing:MOTION[S.theme].ease}); } return; }
  if(k==='scene'){ S.scene=v; rShoot(); return; } if(k==='grade'){ S.grade=v; rShoot(); return; }
  if(a==='shoot-reset'){ S.shot='Medium'; S.lens=35; S.aperture='f/2.8'; rShoot(); return; }
  if(a==='forgot'){ toast('Reset link sent to jenne@studio.com (demo)'); return; }
  if(a==='audio-keep'){ S.keepAudio=true; refreshSheet(); return; } if(a==='audio-new'){ S.keepAudio=false; refreshSheet(); toast('Pick a track or voiceover (demo)'); return; }
  if(a==='retryfail'){ S.failDismissed=true; toast('Retrying · settings loaded'); go('direct'); return; }
  if(a==='discard'){ const j=S.open; S.jobs=S.jobs.filter(x=>x!==j); toast('Discarded'); back(); return; }
  if(k==='tool'){ S.tool=v; document.querySelectorAll('.tool').forEach(t=>t.classList.toggle('on', t.dataset.act===a)); refreshSheet(); return; }
  if(k==='engine'){ S.engine=v; refreshSheet(); return; }
  if(a==='lip'){ S.lip=!S.lip; refreshSheet(); return; }
  if(a==='audio'){ S.keepAudio=!S.keepAudio; refreshSheet(); return; }
  if(k==='bg'){ S.bg=v; const c=document.querySelector('.canvas'); if(c){ c.animate([{filter:'blur(8px)',opacity:.6},{filter:'none',opacity:1}],{duration:420}); c.style.backgroundImage=`url(${IMG[v==='photo'?'vid_bath':'vid_living']})`; } refreshSheet(); return; }
  if(k==='motion'){ S.motion=v; refreshSheet(); return; }
  if(a==='steps-inc'){ setSteps(S.steps+1); return; } if(a==='steps-dec'){ setSteps(S.steps-1); return; }
  if(k==='outfit' && S.screen==='shoot'){ S.outfit=+v; rShoot(); return; }
  if(k==='outfit'){ if(v==='next') S.outfit=(S.outfit+1)%OUTFITS.length; else if(v==='prev') S.outfit=(S.outfit+OUTFITS.length-1)%OUTFITS.length; else S.outfit=+v;
    if(S.screen==='direct') refreshSheet(); else refresh(); return; }
  if(k==='shot'){ S.shot=v; rShoot(); return; }
  if(k==='light'){ S.light=v; rShoot(); return; }
  if(k==='lens'){ S.lens=+v; rShoot(); return; } if(k==='ap'){ S.aperture=v; rShoot(); return; }
  if(a==='clipbad'){ S.clipBad=!S.clipBad; refresh(); return; }
  if(a==='blocked'){ toast('Fix the clip checks first'); return; }
  if(k==='use'){ S.use=v; refresh(); return; }
  if(k==='niche'){ S.create.niche=v; refresh(); return; }
  if(k==='skin'){ S.create.skin=+v; refresh(); return; }
  if(a.startsWith('look|')){ const [,kk,vv]=a.split('|'); S.create.look[kk]=vv; refresh(); return; }
  if(k==='gal'){ S.gallery=v; refresh(); return; }
  if(k==='theme'){ setTheme(v); return; }
  if(a==='sound'){ S.sound=!S.sound; store.set('sound',S.sound); refresh(); if(S.sound) snd('tap'); return; }
  if(a==='portraits'){ el.classList.add('shimmer'); el.textContent='Generating portraits…'; snd('go'); setTimeout(()=>{ snd('done'); go('create3'); }, 1400); return; }
  if(a==='upload'){ toast('Choose 6 separate images · not a character sheet'); return; }
  if(a==='model-saved'){ snd('done'); confetti(); toast('Model saved · character sheet ready'); S.stack=[]; render('home',1); return; }
  if(a==='shoot'){ if(el.dataset.busy) return; el.dataset.busy=1; el.classList.add('shimmer'); el.textContent='Shooting…'; snd('go'); if(S.theme==='b'){ const f=$('#flash'); f.classList.remove('go'); void f.offsetWidth; f.classList.add('go'); }
    setTimeout(()=>{ const pool=[OUTFITS[S.outfit][0],'c_face','face','g_tq']; S.shots=[...pool.map((k,n)=>[k,(S.scene||'Rooftop · golden hour').split(' · ')[0]+' · '+(n+1),'s'+Date.now()+n]), ...(S.shots||[])];
      S.balance=Math.max(0,S.balance-0.12); S.month+=0.12; S.newShots=4; snd('done'); confetti();
      el.classList.remove('shimmer'); delete el.dataset.busy; el.removeAttribute('data-act'); el.dataset.go='gallery'; el.innerHTML=ic('grid',18)+' 4 shots ready · View in Gallery'; }, 1600); return; }
  if(a==='generate'){ startJob(el); return; }
  if(k==='open'){ const j=[S.running,...S.jobs].find(x=>x&&x.id===v); if(!j) return; if(j.state!=='done'){ toast('Still rendering · step '+Math.ceil(j.p/10)+' of 10'); return; } S.open=j; go('result'); return; }
  if(a==='approve'){ const j=S.open||S.jobs[0]; if(!S.final.includes(j.id)) S.final.push(j.id); snd('done'); confetti(); refresh(); toast('Moved to Final gallery'); return; }
  if(a==='export'){ toast('Exported 1080×1920 · AI label on'); return; }
  if(a==='topup'){ openMenu('pay', el); return; }
  if(a==='notify'){ toast(S.running?'Rendering · '+fmt(S.running.left)+' left':'No new notifications'); return; }
  if(a==='play'){ const t=$('#trk'); if(t){ t.style.transition='width 2.5s linear'; t.style.width='100%'; setTimeout(()=>{ t.style.transition='none'; t.style.width='0%'; },2600); } return; }
}
function startJob(el){
  if(S.running){ toast('One render at a time in this demo'); return; }
  if(estCost()>S.balance){ toast('Not enough balance · top up in Credits'); return; }
  el.classList.add('shimmer'); el.textContent='Starting GPU…'; snd('go');
  const total = S.engine==='viggle'? 95 : Math.round(S.steps*57.8); // seconds (measured on H100 + FA3)
  S.running = { id:'j'+Date.now(), img:'vid_living', title:'Living-room dance', engine: S.engine==='viggle'?'Fast · beta':`Standard · ${S.steps} steps`, p:0, state:'running', cost: S.engine==='viggle'?0.13:total/3600*3.99, total, left: total, tc:'' };
  setTimeout(()=>{ el.classList.remove('shimmer'); go('queue'); }, 900);
  const speed = 24, t0 = Date.now(); // demo runs 24x faster
  clearInterval(startJob.iv);
  startJob.iv = setInterval(()=>{ const r=S.running; if(!r) return clearInterval(startJob.iv);
    const el = (Date.now()-t0)/1000*speed; r.left = Math.max(0, r.total-el); r.p = Math.min(100, el/r.total*100);
    document.querySelectorAll(`[data-job="${r.id}"]`).forEach(b=>b.style.width=r.p+'%');
    document.querySelectorAll(`[data-pct="${r.id}"]`).forEach(b=>b.textContent=Math.round(r.p)+'%');
    document.querySelectorAll(`[data-tc="${r.id}"]`).forEach(b=>b.textContent=fmt(r.left));
    const bt=$('#bigtime'); if(bt) bt.textContent=fmt(r.left);
    if(S.screen==='queue' && S.theme==='c'){ const stages=[30,55,92,100]; stages.forEach((lim,i)=>{ const prev=i?stages[i-1]:0; const sp=Math.max(0,Math.min(100,(r.p-prev)/(lim-prev)*100)); const b=document.querySelector(`[data-stage="${i}"]`); if(b) b.style.width=sp+'%'; const tx=document.querySelector(`[data-stagep="${i}"]`); if(tx) tx.textContent=Math.round(sp)+'%'; }); }
    if(r.p>=100){ clearInterval(startJob.iv); r.state='done'; r.tc=fmt(r.total); S.jobs.unshift(r); S.running=null; S.balance=Math.max(0,S.balance-r.cost); S.month+=r.cost; notifySound(); confetti();
      toast('Render done · tap to watch', ()=>{ S.open=r; go('result'); }); if(S.screen==='queue') refresh(); }
  }, 250);
}
function setTheme(t){ if(t===S.theme) return; closeMenu(); S.theme=t; store.set('theme',t); const ph=$('#phone');
  ph.animate([{filter:'blur(0)',opacity:1},{filter:'blur(6px)',opacity:.2}],{duration:180}).onfinish=()=>{ document.body.className='t-'+t; ph.className='phone t-'+t; refresh(); snd('theme'); ph.animate([{filter:'blur(6px)',opacity:.2},{filter:'blur(0)',opacity:1}],{duration:380,easing:'ease-out'}); updateSide(); }; }

document.addEventListener('input', e=>{ if(e.target.id==='scene-custom'){ S.sceneCustom=e.target.value; S.scene=e.target.value||'Rooftop · golden hour'; document.querySelectorAll('#ssheet .chip').forEach(c=>c.classList.remove('on')); return; } if(e.target.id==='dir'){ S.direction=e.target.value; const pb=document.querySelector('.pbox'); if(pb){ const p=buildPrompt('shoot'); pb.innerHTML=Object.entries(p).filter(([,v])=>v).map(([kk,v])=>`<div><span class="pk">${kk}</span>${v.replace(/^[A-Za-z ]+: /,'')}</div>`).join(''); } } });
document.addEventListener('pointerdown', e=>{ const p=e.target.closest('.press,.chip,.seg span,.tool,.tog,.thm,.sw'); if(p){ p.classList.add('pressed'); ac(); } });
document.addEventListener('pointerup', ()=>document.querySelectorAll('.pressed').forEach(x=>x.classList.remove('pressed')));
document.addEventListener('click', e=>{
  const sp=e.target.closest('[data-side]'); if(sp){ const [k,v]=sp.dataset.side.split(':'); if(k==='theme') setTheme(v); if(k==='go'){ S.stack=[]; render(v,1);} if(k==='sound'){ S.sound=!S.sound; store.set('sound',S.sound); updateSide(); } return; }
  if(!e.target.closest('#phone')) return;
  const b=e.target.closest('[data-back]'); if(b){ back(); return; }
  const a=e.target.closest('[data-act]'); if(a){ snd('tap'); act(a.dataset.act, a); return; }
  const g=e.target.closest('[data-go]'); if(g){ snd('tap'); go(g.dataset.go); return; }
});
function updateSide(){ const s=$('#side'); if(!s) return; s.querySelectorAll('[data-side^="theme"]').forEach(b=>b.setAttribute('aria-pressed', b.dataset.side==='theme:'+S.theme)); const sb=s.querySelector('[data-side="sound"]'); if(sb) sb.setAttribute('aria-pressed', S.sound); }

document.body.className='t-'+S.theme; $('#phone').className='phone t-'+S.theme;
render('splash');
