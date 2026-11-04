/* MUSE desktop (Mac) prototype. Same themes, data, pricing and prompt engine as the phone prototype. */
const IMG = window.__IMG;
const $ = (s, r=document) => r.querySelector(s);
const store = { get(k,d){ try{ const v=localStorage.getItem('muse.d.'+k); return v==null?d:JSON.parse(v);}catch(e){return d;} }, set(k,v){ try{localStorage.setItem('muse.d.'+k,JSON.stringify(v));}catch(e){} } };

const S = {
  theme: store.get('theme','a'), sound: store.get('sound', true), pro: store.get('pro', false),
  screen: 'home', stack: [], authed: true, authTab: 'in', att: [false,false],
  steps: 10, engine: 'h3', use: 'first', takes: 1, keepAudio: true, lip: false, bg: 'keep', motion: 'subtle', outfit: 0, clipBad: false, showPrompt: false,
  itab: 'scene', shot: 'Medium', lens: 35, aperture: 'f/2.8', light: 'Golden hour', grade: 'Phone-natural', scene: 'Rooftop · golden hour', sceneCustom: '', direction: '', lockSeed: true,
  shootState: 'idle', shots: [], gallery: 'tests', picked: [], fresh: [], final: ['g1'], open: null, cmp: false,
  create: { step: 1, name: '', niche: 'Beauty', personality: '', notes: '' }, sheet: {}, settingsSec: 'appearance',
  never: ['tattoos','rings'],
  jobs: [
    { id:'j3', img:'vid_living', title:'Living room dance', engine:'Standard', steps:10, len:5.2, p:0, state:'queued', cost:0.66 },
    { id:'j1', img:'vid_kick', title:'Kick test', engine:'Fast · beta', steps:4, len:5.2, p:100, state:'done', cost:0.13 },
    { id:'j2', img:'vid_bath', title:'Bathroom trend', engine:'Standard', steps:30, len:5.2, p:100, state:'done', cost:3.05 },
  ],
  failed: true, gpu: 'idle', balance: 6.07, month: 18.93, today: 0.66
};
const money = v => '$'+v.toFixed(2);
const LENS = () => (S.use==='full')?9.4:5.2;
const secPerLen = len => 57.8*Math.pow(len/5.2,1.3);
const estMin = () => S.engine==='viggle'? 1.6*(LENS()/5.2) : S.steps*secPerLen(LENS())/60 + 0.5 + (S.lip?4:0);
const estCost = () => (S.engine==='viggle'? 0.13*(LENS()/5.2) : estMin()/60*3.99);
const totalCost = () => estCost()*S.takes;
const fmtMin = m => m<2? Math.round(m*60)+'s' : Math.round(m)+' min';

/* sound (shared with the phone prototype) */
__SOUND__

const ICON = __ICONS__;
function ic(n, s=18, cls=''){ const fill=['play','apple','google'].includes(n)?' fill="currentColor" stroke="none"':' fill="none" stroke="currentColor"'; return `<svg class="ic ${cls}" width="${s}" height="${s}" viewBox="0 0 24 24"${fill} stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${ICON[n]||ICON.spark}</svg>`; }
const bg = k => `background-image:url(${IMG[k]})`;
const pill = (t,k='') => `<span class="pill ${k}">${t}</span>`;
const stk = (t,r=-4,st='') => S.theme==='d'?`<span class="stk" style="transform:rotate(${r}deg);${st}">${t}</span>`:'';
const T = () => S.theme;

/* ---------------- data ---------------- */
const MODEL = { name:'Sienna Vale', short:'Sienna', niche:'Beauty · lifestyle', look:'young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin' };
const OUTFITS = [['g_front','Green set',['g_front','g_tq','g_side','g_back']],['c_front','Crystal dress',['c_front','c_tq','c_face','c_front']]];
const SLOTS = [['face','Face · front','face'],['profile','Face · profile','profile'],['front','Body · front','g_front'],['tq','Body · ¾','g_tq'],['side','Body · side','g_side'],['back','Body · back','g_back']];
const SIENNA_SHEET = { face:'yours', profile:'yours', front:'yours', tq:'yours', side:'yours', back:'yours' };
const GALLERY = [['vid_living','Living room · 10 steps','g1','video'],['vid_kick','Kick test · Fast','j1','video'],['vid_bath','Bathroom · 30 steps','j2','video'],['c_front','Shoot · crystal','g4','photo'],['vid_living2','Living room · 15 steps','g5','video'],['c_tq','Shoot · crystal ¾','g6','photo'],['g_front','Shoot · green set','g7','photo']];
const THEMES = [['a','Editorial','#EFEBE3','#B5121B'],['b','Camera Body','#0D0E0F','#F2A93B'],['c','Soft Tactile','#E7E2D9','#6E8465'],['d','Creator Pop','#1F4BFF','#FF7EB6']];

/* ---------------- prompt engine (plans/prompt-system.md) ---------------- */
const HOUSE = 'realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss';
function shootPrompt(){
  const o = OUTFITS[S.outfit];
  const scene = (S.sceneCustom||'').trim() || S.scene;
  return {
    identity:`${MODEL.name}: ${MODEL.look}. Identity from 6 locked reference images.`,
    outfit:`Wearing: ${o[1].toLowerCase()} (outfit reference set).`,
    scene:`Scene: ${scene.toLowerCase()}.`,
    camera:`Camera: ${S.shot.toLowerCase()} shot, ${S.lens}mm lens, ${S.aperture}${S.lens<=24?', slight wide-angle distortion':S.lens>=85?', compressed background, creamy bokeh':''}.`,
    light:`Light: ${S.light.toLowerCase()}; grade: ${S.grade.toLowerCase()}.`,
    direction: S.direction.trim()? `Direction: ${S.direction.trim()}` : '',
    style:`Style: ${HOUSE}.`,
    negative:`Never add: ${S.never.join(', ')}, logos, extra fingers, warped jewellery.`,
    seed: S.lockSeed? 'Seed: locked (retakes keep the same look).' : 'Seed: new each shot.'
  };
}
function videoPrompt(){
  const o = OUTFITS[S.outfit];
  return `subject_definitions:
  Subject 1: the performer in the source clip, a young woman with a floral forearm tattoo and two silver rings.
  Target: ${MODEL.name}, ${MODEL.look} (reference images 1–6).
summary:
  Replace Subject 1 with ${MODEL.name}, keeping the exact motion, timing, camera and ${S.bg==='keep'?'background':'new background photo ('+S.motion+')'}.
retention_analysis:
  Keep: pose, choreography, hand positions, room, lighting${S.keepAudio?', audio (fully_copy)':''}.
  Replace: face, hair, skin, body proportions, outfit.
detailed_description:
  ${MODEL.name} wears the ${o[1].toLowerCase()} from the outfit reference images. None of Subject 1's ${S.never.join(' or ')} remain.
steps: ${S.engine==='viggle'?'4 (Fast · beta, fixed)':S.steps} · clip: ${LENS()}s · takes: ${S.takes}`;
}

/* ---------------- shell ---------------- */
const NAV = [['home','Home','home','1'],['models','Models','model','2'],['studio','Video studio','studio','3'],['shoot','Photoshoot','camera','4'],['queue','Queue','queue','5'],['gallery','Gallery','grid','6']];
const PARENT = { profile:'models', create:'models', result:'gallery', credits:'settings' };
function running(){ return S.jobs.find(j=>j.state==='running'); }
function shell(inner){
  const r = running(), active = PARENT[S.screen]||S.screen, q = S.jobs.filter(j=>j.state==='running'||j.state==='queued').length;
  return `<div class="win">
  <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><span class="tb-title">MUSE Studio</span>
   <div class="search" data-act="palette">${ic('spark',15)}<span>Search or jump to…</span><kbd>⌘K</kbd></div>
   <div class="tb-right">
    ${r?`<div class="jobchip" data-go="queue"><span class="led on"></span>step ${Math.min(r.steps,Math.floor(r.p/100*r.steps)+1)}/${r.steps}<span class="mini"><i style="width:${r.p}%"></i></span></div>`:''}
    <div class="thdots" title="Theme"><span>Theme</span>${THEMES.map(([k,n,b,a])=>`<b class="${k===T()?'on':''}" style="background:linear-gradient(135deg,${b} 50%,${a} 50%)" data-act="theme-${k}" title="${n}"></b>`).join('')}</div>
    <span class="icbtn" data-act="sound" title="Sound">${ic('audio',18)}</span>
    <span class="icbtn" data-act="menu-account">${ic('user',18)}</span>
   </div></div>
  <div class="wbody">
   <nav class="side"><div class="wm">MUSE</div>
    ${NAV.map(([k,l,i,n])=>`<div class="nav${active===k?' on':''}" data-go="${k}">${ic(i,18)}<span>${l}</span>${k==='queue'&&q?`<span class="cnt">${q}</span>`:`<span class="k">⌘${n}</span>`}</div>`).join('')}
    <div class="grp">Create</div>
    <div class="nav" data-act="new-video">${ic('plus',18)}<span>New video</span><span class="k">⌘N</span></div>
    <div class="nav" data-go="create">${ic('model',18)}<span>New model</span></div>
    <div class="sp"></div>
    <div class="nav${active==='settings'?' on':''}" data-go="settings">${ic('quality',18)}<span>Settings</span><span class="k">⌘,</span></div>
    <div class="balbox" data-go="credits"><span class="lbl">GPU balance</span><b id="bal">${money(S.balance)}</b><span class="tiny muted">≈ ${Math.max(0,Math.floor(S.balance/0.66))} videos at 10 steps</span><div class="bar"><i style="width:${Math.min(100,S.balance/25*100)}%"></i></div></div>
   </nav>
   <main class="main" id="main">${inner}</main>
  </div>
</div>`;
}

/* ---------------- screens ---------------- */
const SCREENS = {};
const PH = (eyebrow, title, right='') => `<div class="ph"><div class="grow"><div class="eyebrow">${eyebrow}</div><h1 class="h1">${title}</h1></div>${right}</div>`;

SCREENS.auth = () => { const up = S.authTab==='up', ok = S.att[0]&&S.att[1];
  return `<div class="win"><div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><span class="tb-title">MUSE Studio</span><span class="grow"></span>
   <div class="thdots"><span>Theme</span>${THEMES.map(([k,n,b,a])=>`<b class="${k===T()?'on':''}" style="background:linear-gradient(135deg,${b} 50%,${a} 50%)" data-act="theme-${k}" title="${n}"></b>`).join('')}</div></div>
  <div class="auth"><div class="art"><div class="img" style="${bg('hero')}"></div><div class="ov"><span class="eyebrow" style="color:rgba(255,255,255,.8)">AI model studio</span><h2 class="h1" style="color:#fff">Your models.<br>Real motion.</h2><p style="max-width:420px;opacity:.9">Build original AI models from your own images, dress them, shoot them, and put them into real clips.</p></div></div>
  <div class="form"><div class="eyebrow">${up?'Create account':'Welcome back'}</div><h1 class="h1">${up?'Join MUSE':'Sign in'}</h1>
   <div class="sso" data-act="signin">${ic('apple',18)}Continue with Apple</div>
   <div class="sso" data-act="signin">${ic('google',18)}Continue with Google</div>
   <div class="row"><div class="hr grow"></div><span class="tiny muted">or with email</span><div class="hr grow"></div></div>
   <input class="inp" placeholder="you@studio.com"><input class="inp" type="password" placeholder="Password">
   ${up?`<div class="chk${S.att[0]?' on':''}" data-act="att-0"><span class="bx">${ic('check',14)}</span><span>I'm 18 or older. I'll only upload clips and images I have the rights to use, and only create original characters.</span></div>
   <div class="chk${S.att[1]?' on':''}" data-act="att-1"><span class="bx">${ic('check',14)}</span><span>I'll label AI content when I post it.</span></div>`:''}
   <div class="btn pri big${up&&!ok?' off':''}" data-act="${up&&!ok?'att-need':'signin'}">${up?'Create account':'Sign in'}</div>
   <p class="tiny muted">${up?'Already have an account? <span class="link" data-act="auth-in">Sign in</span>':'New here? <span class="link" data-act="auth-up">Create an account</span>'}</p>
   <p class="tiny muted">By continuing you agree to the MUSE Terms and Acceptable Use Policy.</p></div></div>
</div>`; };

SCREENS.home = () => { const r = running() || S.jobs.find(j=>j.state==='queued'); const review = S.jobs.filter(j=>j.state==='done'&&!S.final.includes(j.id)).length;
  return `<div class="page">${PH(new Date().toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'}), 'Good evening', `<div class="btn" data-go="shoot">${ic('camera',16)}Photoshoot</div><div class="btn pri" data-act="new-video">${ic('plus',16)}New video</div>`)}
  <div class="kpis"><div class="kpi"><span class="lbl">GPU balance</span><b>${money(S.balance)}</b><span class="tiny muted">≈ ${Math.floor(S.balance/0.66)} videos at 10 steps</span></div>
   <div class="kpi"><span class="lbl">This month</span><b>${money(S.month)}</b><span class="tiny muted">${9+S.jobs.length} renders</span></div>
   <div class="kpi"><span class="lbl">In the queue</span><b>${S.jobs.filter(j=>j.state==='running'||j.state==='queued').length}</b><span class="tiny muted">${running()?'H100 running':'GPU off · starts on demand'}</span></div>
   <div class="kpi"><span class="lbl">To review</span><b>${review}</b><span class="tiny muted">takes waiting for approval</span></div></div>
  <div class="hero-row" style="margin-top:22px">
   <div class="card"><div class="row-b" style="margin-bottom:14px"><span class="h2">Pick up where you left off</span>${stk('live!',4)}</div>
    ${r?`<div class="continue"><div class="ph9 img" style="${bg(r.img)}"></div><div class="col grow" style="justify-content:center;gap:12px"><span class="lbl">${r.state==='running'?'Rendering':'Queued'} · ${r.engine} · ${r.steps} steps</span><b class="h2">${r.title}</b>
      <div class="prog"><i style="width:${r.p}%"></i></div><span class="tiny muted mono">${r.state==='running'?jobLine(r):'Starts when you press Run queue'}</span>
      <div class="row">${r.state==='queued'?`<div class="btn pri sm" data-act="runq">${ic('play',14)}Run queue · ${money(r.cost)}</div>`:''}<div class="btn sm" data-go="queue">Open queue</div></div></div></div>`
     :`<div class="note">${ic('spark',16)}<span>Nothing rendering. Start a new video or a photoshoot.</span></div>`}
   </div>
   <div class="card qa"><span class="h2" style="margin-bottom:4px">Create</span>
    <div class="opt press" data-act="new-video"><span class="ico">${ic('studio',20)}</span><span class="grow"><b>New video</b><br><span class="tiny muted">Swap your model into a real clip</span></span><span class="kbd">⌘N</span></div>
    <div class="opt press" data-go="shoot"><span class="ico">${ic('camera',20)}</span><span class="grow"><b>Photoshoot</b><br><span class="tiny muted">Stills in any scene, camera and light</span></span></div>
    <div class="opt press" data-go="create"><span class="ico">${ic('model',20)}</span><span class="grow"><b>New model</b><br><span class="tiny muted">Upload your own reference images</span></span></div></div></div>
  <div class="sec-h"><span class="h2">Latest takes</span><span class="link" data-go="gallery">Open gallery</span></div>
  <div class="grid6">${galleryTiles().slice(0,6).map(([k,l,id])=>`<div class="gt" data-act="open-${id}"><div class="ph9 img" style="${bg(k)}"><span class="cap">${l}</span></div></div>`).join('')}</div>
  <div class="sec-h"><span class="h2">Your models</span><span class="link" data-go="models">All models</span></div>
  <div class="grid5">${modelCard()}<div class="addtile" data-go="create">${ic('plus',22)}<span>New model</span></div></div></div>`; };

const modelCard = () => `<div class="mcard press" data-go="profile"><div class="ph34 img" style="${bg('hero')}"><span class="tag">${pill('6/6 shots','good')}</span></div><div class="mb"><b>${MODEL.name}</b><span class="tiny muted">${MODEL.niche} · ${OUTFITS.length} outfits</span></div></div>`;
SCREENS.models = () => `<div class="page">${PH('Library','Models',`<div class="btn pri" data-go="create">${ic('plus',16)}New model</div>`)}
  <div class="grid5">${modelCard()}
   <div class="mcard press" data-act="toast-noor"><div class="ph34 init">N</div><div class="mb"><b>Noor</b><span class="tiny muted">Draft · ${pill('needs face close-ups','warn')}</span></div></div>
   <div class="addtile" data-go="create">${ic('plus',22)}<span>New model<br><span class="tiny">Bring your own images</span></span></div></div></div>`;

SCREENS.profile = () => `<div class="page"><div class="row tiny muted" style="margin-bottom:10px"><span class="link" data-go="models">Models</span>›<span>${MODEL.name}</span></div>
  <div class="prof"><div class="col" style="gap:14px"><div class="heroimg img" style="${bg('hero')}"></div>
    <div class="row"><div class="btn pri grow" data-act="new-video">${ic('studio',16)}New video</div><div class="btn grow" data-go="shoot">${ic('camera',16)}Shoot</div><span class="icbtn" data-act="menu-profile">${ic('more',18)}</span></div>
    <div class="card col"><span class="lbl">Niche</span><span>${MODEL.niche}</span><span class="lbl">Personality</span><span>Warm, a little dry, morning-routine energy.</span><span class="lbl">Notes</span><span class="small muted">Honey-blonde with brown roots is part of the look. Keep the freckles.</span></div></div>
   <div><div class="eyebrow">Model</div><h1 class="h1">${MODEL.name}</h1>
    <div class="sec-h"><span class="h2">Character sheet</span><span class="row"><span class="tiny muted">Tap a shot to replace it</span><div class="btn sm" data-act="upload-sheet">${ic('upload',14)}Upload images</div></span></div>
    <div class="slots">${SLOTS.map(([k,l,img])=>`<div class="slot"><div class="ph34 img" style="${bg(img)}"><span class="tag">${pill('yours','yours')}</span><div class="hov"><span data-act="replace-${k}">Replace</span><span data-act="retake-${k}">Retake with AI</span></div></div><span>${l}</span></div>`).join('')}</div>
    <div class="sec-h"><span class="h2">Outfits</span><div class="btn sm" data-act="outfit-new">${ic('plus',14)}Add outfit</div></div>
    <div class="ofs">${OUTFITS.map(([c,n,a],i)=>`<div class="ofset"><div class="row-b"><b>${n}</b><span class="tiny muted">front · ¾ · side · back</span></div><div class="angs">${a.map(x=>`<div class="ph34 img" style="${bg(x)}"></div>`).join('')}</div></div>`).join('')}</div>
    <div class="sec-h"><span class="h2">Never add</span><span class="tiny muted">Removed from every render automatically</span></div>
    <div class="chips">${S.never.map((n,i)=>`<span class="chip">${n}<span class="x" data-act="never-del-${i}">✕</span></span>`).join('')}<span class="chip" data-act="never-add">${ic('plus',14)}Add</span></div>
   </div></div></div>`;

SCREENS.create = () => { const c=S.create, filled=SLOTS.filter(([k])=>S.sheet[k]).length, faces=['face','profile'].filter(k=>S.sheet[k]).length, busy=SLOTS.some(([k])=>S.sheet[k]==='busy');
  const steps = `<div class="stepper"><span class="st${c.step===1?' on':''}"><b>1</b>Basics</span><span class="ln"></span><span class="st${c.step===2?' on':''}"><b>2</b>Character sheet</span></div>`;
  if(c.step===1) return `<div class="page"><div class="row tiny muted" style="margin-bottom:10px"><span class="link" data-go="models">Models</span>›<span>New model</span></div>${PH('New model','Basics')}${steps}
   <div style="max-width:640px" class="col"><label class="fld"><span class="lbl">Name</span><input class="inp" id="c-name" placeholder="e.g. Noor" value="${c.name}"></label>
    <div class="fld"><span class="lbl">Niche</span><div class="chips">${['Beauty','Fashion','Fitness','Food','Tech','Travel','Lifestyle'].map(n=>`<span class="chip${c.niche===n?' on':''}" data-act="niche-${n}">${n}</span>`).join('')}</div></div>
    <label class="fld"><span class="lbl">Personality <span class="muted">(optional)</span></span><input class="inp" id="c-pers" placeholder="e.g. warm, a little dry, morning-routine energy" value="${c.personality}"></label>
    <label class="fld"><span class="lbl">Notes <span class="muted">(optional)</span></span><textarea class="inp" id="c-notes" rows="3" placeholder="Anything about the look you want kept">${c.notes}</textarea></label>
    <div class="row" style="margin-top:8px"><div class="btn" data-go="models">Cancel</div><div class="btn pri" data-act="create-next">Next: character sheet</div></div></div></div>`;
  return `<div class="page"><div class="row tiny muted" style="margin-bottom:10px"><span class="link" data-go="models">Models</span>›<span>New model</span></div>${PH('New model · '+(c.name||'Untitled'),'Character sheet',`<div class="btn" data-act="create-back">Back</div><div class="btn pri${busy?' off':''}" data-act="${busy?'noop':'create-save'}">Save model</div>`)}${steps}
   <div class="drop" id="drop" data-act="upload-all"><span class="bigic">${ic('upload',24)}</span><span class="grow"><b>Drop your reference images here</b><br><span class="tiny muted">Or click to choose. We sort them into the slots below, and you can move any image to another slot.</span></span><div class="btn">Choose files</div></div>
   <div class="sec-h"><span class="h2">${filled}/6 shots</span><span class="tiny muted">Two face close-ups give the sharpest face</span></div>
   <div class="slots">${SLOTS.map(([k,l,img])=>{ const v=S.sheet[k]; return `<div class="slot">${v==='busy'?`<div class="ph34 shimmer"></div>`:v?`<div class="ph34 img" style="${bg(img)}"><span class="tag">${pill(v==='ai'?'AI':'yours',v==='ai'?'acc':'yours')}</span><div class="hov"><span data-act="slot-up-${k}">Replace</span><span data-act="slot-clear-${k}">Remove</span></div></div>`:`<div class="ph34 empty press" data-act="slot-up-${k}">${ic('plus',20)}<br>Add</div>`}<span>${l}</span></div>`; }).join('')}</div>
   ${faces<2&&filled>0?`<div class="note warn" style="margin-top:16px">${ic('shield',16)}<span>No ${faces?'profile':'face'} close-up yet. You can still save, but faces come out softer without both close-ups.</span></div>`:''}
   ${filled>0&&filled<6?`<div class="card row" style="margin-top:16px"><span class="grow"><b>Fill missing angles from your images</b><br><span class="tiny muted">Optional. AI makes the ${6-filled} empty angle${6-filled>1?'s':''} from what you uploaded · ${money(0.02*(6-filled))}</span></span><div class="btn" data-act="fill-missing">Fill ${6-filled}</div></div>`:''}
  </div>`; };

function jobLine(j){ const left=(100-j.p)/100*j.mins; return `step ${Math.min(j.steps,Math.floor(j.p/100*j.steps)+1)}/${j.steps} · ~${left<1?Math.max(1,Math.round(left*60))+'s':Math.round(left)+' min'} left`; }

SCREENS.studio = () => { const bad=S.clipBad, low = totalCost()>S.balance, blocked = bad||low;
  const ck = bad ? [['People in frame','2 found','bad','Crop it, or pick a clip with one person'],['Watermark','TikTok logo','bad','Use the original file, not a download'],['1080×1920 · 30fps','OK','good'],['Length 22s','Over 15s','bad','Trim to 15s or less'],['Performer talking','No','']]
                 : [['One person in frame','Yes','good'],['Watermark','None','good'],['1080×1920 · 30fps','OK','good'],['Length 9.4s','Max 15s','good'],['Performer talking','No','']];
  const pct=(S.steps-4)/26*100;
  const stepsUI = S.engine==='viggle' ? `<div class="note warn">${ic('shield',16)}<span>Fast · beta renders in about 2 minutes with exact motion timing, but faces are softer and can warp slightly. Fixed quality, no steps.</span></div>`
    : T()==='b' ? `<div class="knobwrap"><div class="knob" id="knob" style="transform:rotate(${(S.steps-17)*10}deg)"><i></i></div><div class="col" style="gap:4px"><span class="lbl">Steps</span><b class="stepnum" id="steps-v">${S.steps}</b><span class="readout" id="steps-rec">${S.steps===10?'RECOMMENDED':S.steps>10?'RARELY WORTH IT':'BELOW TESTED'}</span><span class="tiny muted">Drag or scroll the dial · ← → keys</span></div></div><p class="tiny muted" id="steps-delta">${stepsDelta()}</p>`
    : `<div class="row-b"><span class="lbl">Steps</span>${T()==='d'?stk(S.steps===10?'RECOMMENDED':'TAKES LONGER',-4):pill(`<span id="steps-rec">${S.steps===10?'Recommended':S.steps>10?'Rarely worth it':'Below tested'}</span>`,S.steps===10?'good':'warn')}</div>
       <b class="stepnum" id="steps-v">${S.steps}</b><div class="slider" id="slider"><i style="width:${pct}%"></i><b style="left:${pct}%"></b></div><div class="scale"><span>4</span><span>10</span><span>20</span><span>30</span></div><p class="tiny muted" id="steps-delta">${stepsDelta()}</p>`;
  return `<div class="page split">
  <div class="lcol"><div class="row-b"><span class="h2">Source clip</span><span class="icbtn" data-act="menu-direct">${ic('more',18)}</span></div>
   <div class="ph9 img" style="${bg('src_clip')};width:100%;max-width:180px;align-self:center"><span class="cap">${ic('play',12)} 0:09 · 1080×1920</span></div>
   <div class="btn sm" data-act="change-clip">${ic('upload',14)}Change clip</div>
   <div class="col"><span class="lbl">Clip check</span><div class="checks">${ck.map(([x,y,k,fix])=>`<div class="ck"><div class="row-b"><span>${x}</span>${pill((k==='bad'?'✕ ':k==='good'?'✓ ':'')+y,k==='bad'?'warn':k)}</div>${fix?`<span class="fix">${fix}</span>`:''}</div>`).join('')}</div>
    <span class="link tiny" data-act="clipbad">${bad?'Use the good sample clip':'Preview: what a failing clip looks like'}</span></div></div>
  <div class="center"><div class="ph" style="margin-bottom:8px"><div class="grow"><div class="eyebrow">Video studio</div><h1 class="h1">New video</h1>${T()==='b'?`<div class="readout" style="margin-top:8px"><span class="rec">●</span> REF · FACE FRONT · ${OUTFITS.length} OUTFITS · OUTPUT 768×1344</div>`:''}</div></div>
   <div class="stagebox"><div class="col" style="align-items:center"><div class="ph9 img" style="${bg('src_clip')}"><span class="cap">Source · performer</span></div></div>
    <div class="arrowc"><span class="circ">${ic('chev',18)}</span><span>Motion, timing and room are kept. The person is replaced.</span></div>
    <div class="col" style="align-items:center"><div class="ph9 img" style="${bg(OUTFITS[S.outfit][2][0])}"><span class="cap">${MODEL.short} · ${OUTFITS[S.outfit][1]}</span></div></div></div>
   <div class="timeline"><div class="row-b"><span class="lbl">Use</span><div class="seg" style="width:420px">${[['first','First 5.2s'],['full','Full 9.4s']].map(([k,l])=>`<span class="${S.use===k?'on':''}" data-act="use-${k}">${l}</span>`).join('')}</div></div>
    <div class="tl-track">${['src_clip','src_clip','src_clip','src_clip','src_clip','src_clip','src_clip','src_clip','src_clip','src_clip'].map((k,i)=>`<i style="${bg(k)};opacity:${.35+i%3*.1}"></i>`).join('')}<span class="tl-sel" style="width:${LENS()/9.4*100}%"></span></div>
    <div class="tl-scale"><span>0s</span><span>2s</span><span>4s</span><span>6s</span><span>8s</span><span>9.4s</span></div></div>
   ${S.pro||S.showPrompt?`<div class="sec-h"><span class="h2">Prompt</span><span class="row"><span class="tiny muted">Built automatically · pro mode</span><div class="btn sm" data-act="copy">Copy</div></span></div><pre class="promptpre">${videoPrompt()}</pre>`:''}
  </div>
  <aside class="insp"><div class="insp-scroll">
   <div class="fld"><span class="lbl">Model</span><div class="thumbs"><div class="t on"><div class="ph34 img" style="${bg('face')}"></div>${MODEL.short}</div><div class="t" data-act="toast-noor"><div class="ph34 init" style="font-size:22px">N</div>Noor</div></div></div>
   <div class="fld"><div class="row-b"><span class="lbl">Outfit</span><span class="link tiny" data-act="outfit-new">+ New outfit</span></div><div class="thumbs">${OUTFITS.map(([k,n],i)=>`<div class="t${i===S.outfit?' on':''}" data-act="outfit-${i}"><div class="ph34 img" style="${bg(k)}"></div>${n}</div>`).join('')}</div><span class="tiny muted">Never add: ${S.never.join(', ')}. Removed automatically.</span></div>
   <div class="fld"><span class="lbl">Engine</span><div class="seg"><span class="${S.engine==='h3'?'on':''}" data-act="engine-h3">Standard</span><span class="${S.engine==='viggle'?'on':''}" data-act="engine-viggle">Fast · beta</span></div></div>
   <div class="fld" id="stepsbox">${stepsUI}</div>
   <div class="row-b"><span><b>Takes</b><br><span class="tiny muted">Different seeds, compared side by side</span></span><div class="num"><span data-act="takes-dec">−</span><b>${S.takes}</b><span data-act="takes-inc">+</span></div></div>
   <div class="fld"><span class="lbl">Background</span><div class="seg"><span class="${S.bg==='keep'?'on':''}" data-act="bg-keep">Keep the room</span><span class="${S.bg==='photo'?'on':''}" data-act="bg-photo">New photo</span></div>
    ${S.bg==='photo'?`<div class="seg">${[['still','Still'],['subtle','Subtly alive'],['busy','Busy']].map(([k,l])=>`<span class="${S.motion===k?'on':''}" data-act="motion-${k}">${l}</span>`).join('')}</div><span class="tiny muted">Vertical photo, same camera height, similar light.</span>`:''}</div>
   <div class="row-b"><span><b>Keep the clip's audio</b><br><span class="tiny muted">Off = upload a new track</span></span><span class="tog${S.keepAudio?' on':''}" data-act="audio"></span></div>
   <div class="row-b"><span><b>Lip sync</b><br><span class="tiny muted">Only when the performer talks or sings · +4 min</span></span><span class="tog${S.lip?' on':''}" data-act="lip"></span></div>
   ${S.pro?'':`<span class="link tiny" data-act="showprompt">${S.showPrompt?'Hide':'Show'} the prompt</span>`}
  </div>
  <div class="insp-foot"><div class="estbox"><div><span class="lbl">Time</span><b id="est-t">${fmtMin(estMin()*S.takes)}</b></div><div><span class="lbl">Cost</span><b id="est-c">${money(totalCost())}</b></div><div><span class="lbl">After</span><b id="est-a">${money(Math.max(0,S.balance-totalCost()))}</b></div></div>
   ${low&&!bad?`<div class="note warn tiny">${ic('wallet',16)}<span>Not enough balance for this render. <span class="link" data-go="credits">Top up</span></span></div>`:''}
   <div class="btn pri big${blocked?' off':''}" id="gen" data-act="${blocked?(bad?'blocked':'lowbal'):'generate'}">${bad?'Fix the clip to continue':genLabel()}</div><span class="tiny muted" style="text-align:center">⌘↵ to generate · renders keep running if you close the app</span></div></aside></div>`; };
function stepsDelta(){ if(S.steps===10) return 'Same quality as 15 or 20 steps in testing, for less time.'; const d=(S.steps-10)*secPerLen(LENS())/60, c=d/60*3.99; return `${d>0?'+':'−'}${Math.abs(d).toFixed(1)} min · ${d>0?'+':'−'}${money(Math.abs(c))} vs 10 steps${S.steps>10?' · no visible gain in testing':' · may lose detail'}`; }
function genLabel(){ return `Generate${S.takes>1?' '+S.takes+' takes':''} · ${fmtMin(estMin()*S.takes)} · ${money(totalCost())}`; }

const SHOTS_IMG = ['c_front','c_tq','g_front','hero'];
SCREENS.shoot = () => { const p=shootPrompt(), st=S.shootState;
  const tabs=[['scene','Scene'],['camera','Camera'],['light','Light'],['prompt','Prompt']];
  let body='';
  if(S.itab==='scene') body = `<div class="fld"><span class="lbl">Scene</span><div class="chips">${['Rooftop · golden hour','Bedroom mirror','Café window','Beach noon','City night','Studio white'].map(x=>`<span class="chip${S.scene===x&&!S.sceneCustom.trim()?' on':''}" data-act="scene-${x}">${x}</span>`).join('')}</div></div>
     <label class="fld"><span class="lbl">Or describe your own</span><textarea class="inp" id="scene-custom" rows="3" placeholder="e.g. sunlit rooftop bar, string lights, city skyline">${S.sceneCustom}</textarea></label>`;
  if(S.itab==='camera') body = `<div class="fld"><span class="lbl">Shot</span><div class="seg">${['Close','Medium','Full','Wide'].map(x=>`<span class="${S.shot===x?'on':''}" data-act="shot-${x}">${x}</span>`).join('')}</div></div>
     <div class="fld"><span class="lbl">Lens · ${S.lens}mm</span><div class="chips">${[16,24,35,50,85].map(x=>`<span class="chip${S.lens===x?' on':''}" data-act="lens-${x}">${x}mm</span>`).join('')}</div><span class="tiny muted">${S.lens<=24?'Wide: more room in frame, slight stretch at the edges.':S.lens>=85?'Tele: flattering face, blurred background.':'Natural phone-camera look.'}</span></div>
     <div class="fld"><span class="lbl">Aperture</span><div class="chips">${['f/1.4','f/2.8','f/5.6','f/11'].map(x=>`<span class="chip${S.aperture===x?' on':''}" data-act="ap-${x}">${x}</span>`).join('')}</div></div>
     <span class="link tiny" data-act="shoot-reset">Reset camera</span>`;
  if(S.itab==='light') body = `<div class="fld"><span class="lbl">Light</span><div class="chips">${['Golden hour','Overcast','Ring light','Window light','Flash','Neon night'].map(x=>`<span class="chip${S.light===x?' on':''}" data-act="light-${x}">${x}</span>`).join('')}</div></div>
     <div class="fld"><span class="lbl">Grade</span><div class="chips">${['Phone-natural','Warm film','Editorial','Muted'].map(x=>`<span class="chip${S.grade===x?' on':''}" data-act="grade-${x}">${x}</span>`).join('')}</div></div>`;
  if(S.itab==='prompt') body = `<label class="fld"><span class="lbl">Your direction</span><textarea class="inp" id="dir" rows="3" placeholder="e.g. laughing mid-step, hair blowing, holding an iced coffee">${S.direction}</textarea><span class="tiny muted">Adds detail. It can't change her identity or the never-add list.</span></label>
     <div class="row-b"><span><b>Lock look</b><br><span class="tiny muted">Same seed, so retakes stay consistent</span></span><span class="tog${S.lockSeed?' on':''}" data-act="lockseed"></span></div>
     <div class="fld"><span class="lbl">Final prompt</span><div class="pbox" id="pbox">${pboxHTML(p)}</div></div>
     <div class="row"><div class="btn sm grow" data-act="copy">Copy</div><div class="btn sm grow" data-act="edittext">Edit as text</div></div>`;
  return `<div class="page split"><div class="center">${PH('Photoshoot', MODEL.short+' · '+OUTFITS[S.outfit][1], `<span class="icbtn" data-act="menu-shoot">${ic('more',18)}</span>`)}
   <div class="toolbar"><span class="lbl">Model</span><div class="thumbs"><div class="t on" style="width:44px"><div class="ph34 img" style="${bg('face')}"></div></div></div><span class="lbl" style="margin-left:14px">Outfit</span>
    <div class="seg">${OUTFITS.map(([k,n],i)=>`<span class="${i===S.outfit?'on':''}" data-act="outfit-${i}">${n}</span>`).join('')}</div><span class="link tiny" data-act="outfit-new">+ New outfit</span>${T()==='b'?`<span class="readout" style="margin-left:auto" id="ro">${S.lens}MM · ${S.aperture.toUpperCase()} · 4300K</span>`:''}</div>
   <div class="shots">${SHOTS_IMG.map((k,i)=>st==='busy'?`<div class="ph34 shimmer"></div>`:st==='done'?`<div class="ph34 img pop" style="${bg(k)};animation-delay:${i*80}ms"><span class="tag">${pill('AI','acc')}</span></div>`:`<div class="ph34 empty">${ic('camera',22)}<br>Shot ${i+1}</div>`).join('')}</div>
   ${st==='done'?`<div class="row" style="margin-top:18px"><div class="btn pri" data-act="shots-gallery">${ic('grid',16)}View in Gallery</div><div class="btn" data-act="shoot">${ic('retry',16)}Shoot 4 more · $0.08</div><span class="tiny muted">${S.lockSeed?'Lock look is on: retakes keep the same face and styling.':''}</span></div>`:''}
  </div>
  <aside class="insp"><div class="itabs">${tabs.map(([k,l])=>`<span class="${S.itab===k?'on':''}" data-act="itab-${k}">${l}</span>`).join('')}</div>
   <div class="insp-scroll">${body}</div>
   <div class="insp-foot"><div class="btn pri big${st==='busy'?' off':''}" data-act="${st==='busy'?'noop':'shoot'}">${st==='busy'?'Shooting…':'Shoot 4 · ~20s · $0.08'}</div></div></aside></div>`; };
const pboxHTML = p => Object.entries(p).filter(([,v])=>v).map(([k,v])=>`<div><span class="pk">${k}</span>${v.replace(/^[A-Za-z ]+: /,'')}</div>`).join('');

SCREENS.queue = () => { const r=running(), active=S.jobs.filter(j=>j.state==='running'||j.state==='queued'), done=S.jobs.filter(j=>j.state==='done');
  const row = j => `<tr class="rowh"><td style="width:60px"><div class="th img" style="${bg(j.img)}"></div></td><td><b>${j.title}</b><br><span class="tiny muted">${MODEL.short} · ${j.engine}${j.engine==='Standard'?' · '+j.steps+' steps':''} · ${j.len}s</span></td>
    <td style="width:300px">${j.state==='done'?pill('✓ Done','good'):j.state==='running'?`<div class="prog"><i style="width:${j.p}%"></i></div><span class="tiny muted mono">${jobLine(j)}</span>`:pill('Queued')}</td>
    <td class="mono" style="width:90px">${money(j.cost)}</td><td style="width:150px;text-align:right">${j.state==='done'?`<span class="btn sm" data-act="open-${j.id}">Review</span>`:''}<span class="icbtn" style="display:inline-grid" data-act="menu-job-${j.id}">${ic('more',18)}</span></td></tr>`;
  return `<div class="page">${PH('Jobs','Queue', active.some(j=>j.state==='queued')&&!r?`<div class="btn pri" data-act="runq">${ic('play',14)}Run queue · ${money(active.reduce((a,j)=>a+j.cost,0))}</div>`:'')}
  <div class="gpu"><div class="card row"><span class="led${r?' on':''}"></span><span class="grow"><b>${r?'H100 80GB · rendering':'GPU is off'}</b><br><span class="tiny muted">${r?'Shuts down automatically 5 min after the queue empties':'Starts on demand · setup takes 1–2 min from the network volume'}</span></span></div>
   <div class="card col" style="gap:4px"><span class="lbl">Spent today</span><b class="mono" style="font-size:20px">${money(S.today)} <span class="tiny muted">of $15.00 cap</span></b><div class="prog"><i style="width:${S.today/15*100}%"></i></div></div>
   <div class="card col" style="gap:4px"><span class="lbl">Balance</span><b class="mono" style="font-size:20px">${money(S.balance)}</b><span class="link tiny" data-go="credits">Top up</span></div></div>
  ${S.failed?`<div class="note warn" style="margin-bottom:18px;align-items:center">${ic('shield',18)}<span class="grow"><b>Render failed · Mirror selfie</b> · The GPU disconnected at step 3. $0.19 refunded.</span><span class="btn sm" data-act="retryfail">Retry · $0.66</span><span class="link tiny" data-act="dismissfail">Dismiss</span></div>`:''}
  <div class="sec-h" style="margin-top:0"><span class="h2">Active</span><span class="tiny muted">${active.length} job${active.length===1?'':'s'}</span></div>
  ${active.length?`<table class="tbl"><thead><tr><th></th><th>Clip</th><th>Status</th><th>Cost</th><th></th></tr></thead><tbody>${active.map(row).join('')}</tbody></table>`:`<div class="note">${ic('queue',16)}<span>Nothing in the queue. The GPU is off, so you're not paying for anything. <span class="link" data-act="new-video">Start a new video</span></span></div>`}
  <div class="sec-h"><span class="h2">Finished</span><span class="tiny muted">Last 7 days</span></div>
  <table class="tbl"><tbody>${done.map(row).join('')}</tbody></table></div>`; };

function galleryTiles(){ const jobs=S.jobs.filter(j=>j.state==='done'&&j.id.length>3).map(j=>[j.img,j.title,j.id,'video']); return [...S.shots.map(s=>[s[0],s[1],s[2],'photo']),...jobs,...GALLERY]; }
SCREENS.gallery = () => { const all=galleryTiles(), list = S.gallery==='final'? all.filter(t=>S.final.includes(t[2])) : all;
  if(S.cmp){ const items=S.picked.map(id=>all.find(t=>t[2]===id)).filter(Boolean);
    return `<div class="page">${PH('Compare takes', items.length+' takes side by side', `<div class="btn" data-act="cmp-close">Done</div>`)}
     <div class="cmp" style="grid-template-columns:repeat(${items.length},minmax(0,300px));justify-content:center">${items.map(([k,l,id])=>`<div class="col"><div class="ph9 img" style="${bg(k)}"></div><b>${l}</b><span class="tiny muted mono">${l.includes('Fast')?'Fast · beta · 4 steps · $0.13':l.includes('30')?'Standard · 30 steps · $3.05':l.includes('15')?'Standard · 15 steps · $0.98':'Standard · 10 steps · $0.66'}</span><div class="row"><div class="btn sm grow${S.final.includes(id)?'':' pri'}" data-act="approve-${id}">${S.final.includes(id)?'Approved ✓':'Approve'}</div><div class="btn sm" data-act="open-${id}">Open</div></div></div>`).join('')}</div></div>`; }
  return `<div class="page">${PH('Results','Gallery', `<div class="seg" style="width:300px"><span class="${S.gallery==='tests'?'on':''}" data-act="gal-tests">Tests · ${all.length}</span><span class="${S.gallery==='final'?'on':''}" data-act="gal-final">Final · ${S.final.length}</span></div>`)}
   <p class="tiny muted" style="margin:-8px 0 16px">Test renders stay separate from your Final gallery. Select takes to compare them side by side.</p>
   ${list.length?`<div class="gal">${list.map(([k,l,id,kind])=>`<div class="gt${S.picked.includes(id)?' picked':''}${S.fresh.includes(id)?' fresh':''}" data-act="open-${id}"><div class="ph9 img" style="${bg(k)}"><span class="cap">${S.fresh.includes(id)?'New · ':''}${l}</span>${kind==='video'?`<span class="tag" style="color:#fff">${ic('play',14)}</span>`:''}</div><span class="sel" data-act="pick-${id}">${S.picked.includes(id)?ic('check',14):''}</span></div>`).join('')}</div>`
   :`<div class="note">${ic('spark',16)}<span>Nothing approved yet. Approve a take to move it here.</span></div>`}
   ${S.picked.length?`<div class="cmpbar"><span>${S.picked.length} selected</span><div class="btn sm pri${S.picked.length<2?' off':''}" data-act="${S.picked.length<2?'noop':'cmp-open'}">Compare</div><div class="btn sm" data-act="pick-clear">Clear</div></div>`:''}</div>`; };

SCREENS.result = () => { const all=galleryTiles(), t=all.find(x=>x[2]===S.open)||all[0], [k,l,id,kind]=t, fin=S.final.includes(id), j=S.jobs.find(x=>x.id===id);
  return `<div class="page"><div class="row tiny muted" style="margin-bottom:10px"><span class="link" data-go="gallery">Gallery</span>›<span>${l}</span></div>
  <div class="result"><div class="ph9 img" style="${bg(k)}">${kind==='video'?`<span class="cap">${ic('play',12)} 0:05 · 768×1344</span>`:''}</div>
   <div class="col" style="width:380px;gap:16px"><div class="row-b"><div><div class="eyebrow">${kind==='video'?'Video take':'Photo'}</div><h1 class="h2" style="font-size:30px">${l}</h1></div>${pill(fin?'Final':'Test',fin?'good':'')}<span class="icbtn" data-act="menu-result">${ic('more',18)}</span></div>
    <div class="list">${[['Model',MODEL.name],['Outfit',OUTFITS[0][1]],['Engine',j?j.engine:(kind==='video'?'Standard':'Photo')],['Steps',j?j.steps:(kind==='video'?'10':'—')],['Cost',j?money(j.cost):(kind==='video'?'$0.66':'$0.02')],['Seed','48213 · locked']].map(([a,b])=>`<div class="li"><span class="grow muted">${a}</span><span class="mono small">${b}</span></div>`).join('')}</div>
    <div class="row"><div class="btn grow" data-act="discard">Discard</div><div class="btn pri grow" data-act="approve-${id}">${fin?'Approved ✓':'Approve'}</div></div>
    <div class="row"><div class="btn grow" data-act="retake">${ic('retry',16)}Retake with changes</div><div class="btn grow" data-act="export">${ic('export',16)}Export 1080×1920</div></div>
    <p class="tiny muted">${ic('shield',13)} Exports carry the AI-generated label. Brand posts also need #ad.</p></div></div></div>`; };

SCREENS.settings = () => { const sec=S.settingsSec;
  const secs=[['appearance','Appearance'],['defaults','Render defaults'],['costs','Costs & limits'],['notif','Notifications'],['about','About']];
  let body='';
  if(sec==='appearance') body=`<span class="h2">Theme</span><div class="thms">${THEMES.map(([k,n])=>`<div class="thm press${k===T()?' on':''}" data-act="theme-${k}"><div class="thm-prev" style="background-image:url(${IMG['dth_'+k]||IMG['th_'+k]})"></div><span class="nm">${n}${k===T()?ic('check',16):''}</span></div>`).join('')}</div>
   <div class="list"><div class="li">${ic('audio',18)}<span class="grow">Sound effects<br><span class="tiny muted">Each theme has its own sounds</span></span><span class="tog${S.sound?' on':''}" data-act="sound"></span></div>
   <div class="li">${ic('spark',18)}<span class="grow">Pro mode<br><span class="tiny muted">Show and edit the prompts behind every render</span></span><span class="tog${S.pro?' on':''}" data-act="pro"></span></div></div>`;
  if(sec==='defaults') body=`<span class="h2">Render defaults</span><div class="list"><div class="li"><span class="grow">Default steps<br><span class="tiny muted">10 looked the same as 15 and 20 in testing</span></span><div class="num"><span data-act="steps-dec">−</span><b>${S.steps}</b><span data-act="steps-inc">+</span></div></div>
   <div class="li"><span class="grow">Default engine</span><div class="seg" style="width:260px"><span class="${S.engine==='h3'?'on':''}" data-act="engine-h3">Standard</span><span class="${S.engine==='viggle'?'on':''}" data-act="engine-viggle">Fast · beta</span></div></div>
   <div class="li"><span class="grow">Export size</span><span class="mono small">1080×1920 · 9:16</span></div>
   <div class="li"><span class="grow">Keep test renders for</span><span class="mono small">30 days</span></div></div>
   <span class="h2">House style</span><textarea class="inp" rows="3">${HOUSE}</textarea><span class="tiny muted">Added to every photo prompt. Never-add lists are set per model.</span>`;
  if(sec==='costs') body=`<span class="h2">Costs & limits</span><div class="kpis" style="grid-template-columns:repeat(3,1fr)"><div class="kpi"><span class="lbl">Balance</span><b>${money(S.balance)}</b></div><div class="kpi"><span class="lbl">This month</span><b>${money(S.month)}</b></div><div class="kpi"><span class="lbl">Per video</span><b>~$0.66</b></div></div>
   <div class="list"><div class="li">${ic('shield',18)}<span class="grow">Spend cap per job</span><span class="mono small">$5.00</span></div><div class="li">${ic('shield',18)}<span class="grow">Spend cap per day</span><span class="mono small">$15.00</span></div>
   <div class="li">${ic('bell',18)}<span class="grow">Warn before a job goes over budget</span><span class="tog on"></span></div><div class="li">${ic('quality',18)}<span class="grow">Shut down idle GPU after</span><span class="mono small">5 min</span></div></div>
   <div class="btn pri" style="align-self:flex-start" data-go="credits">${ic('wallet',16)}Credits & top up</div>`;
  if(sec==='notif') body=`<span class="h2">Notifications</span><div class="list"><div class="li"><span class="grow">Render finished</span><span class="tog on"></span></div><div class="li"><span class="grow">Render failed</span><span class="tog on"></span></div><div class="li"><span class="grow">Balance below $5</span><span class="tog on"></span></div><div class="li"><span class="grow">Also notify my Android phone</span><span class="tog on"></span></div></div>`;
  if(sec==='about') body=`<span class="h2">About</span><div class="list"><div class="li"><span class="grow">Version</span><span class="mono small">0.1 prototype</span></div><div class="li"><span class="grow">Video model</span><span class="small">MiniMax H3</span></div><div class="li"><span class="grow">Lip sync</span><span class="small">LatentSync</span></div><div class="li"><span class="grow">Terms of Service</span>${ic('chev',16)}</div><div class="li"><span class="grow">Acceptable Use Policy</span>${ic('chev',16)}</div><div class="li" data-act="signout"><span class="grow">Sign out</span>${ic('chev',16)}</div></div>`;
  return `<div class="page">${PH('Preferences','Settings')}<div class="sgrid"><div class="snav">${secs.map(([k,l])=>`<div class="nav${sec===k?' on':''}" data-act="sec-${k}"><span>${l}</span></div>`).join('')}</div><div class="col" style="gap:16px;max-width:900px">${body}</div></div></div>`; };

SCREENS.credits = () => `<div class="page">${PH('Billing','Credits')}
  <div class="kpis" style="grid-template-columns:repeat(3,1fr)"><div class="kpi"><span class="lbl">GPU balance</span><b>${money(S.balance)}</b><span class="tiny muted">≈ ${Math.floor(S.balance/0.66)} videos at 10 steps</span></div><div class="kpi"><span class="lbl">This month</span><b>${money(S.month)}</b></div><div class="kpi"><span class="lbl">Per video</span><b>~${money(0.66)}</b><span class="tiny muted">5s clip · 10 steps · H100</span></div></div>
  <div class="sec-h"><span class="h2">Top up</span></div><div class="row"><div class="seg" style="width:420px">${['$10','$25','$50','$100'].map(x=>`<span class="${x==='$25'?'on':''}">${x}</span>`).join('')}</div><div class="btn pri" data-act="menu-pay">${ic('wallet',16)}Add $25</div></div>
  <div class="sec-h"><span class="h2">Recent spend</span></div>
  <table class="tbl"><tbody>${S.jobs.filter(j=>j.state!=='queued').map(j=>`<tr><td>${j.title}</td><td class="muted">${j.engine}</td><td class="mono" style="text-align:right">−${money(j.cost)}</td></tr>`).join('')}<tr><td>Mirror selfie (failed)</td><td class="muted">Refunded</td><td class="mono" style="text-align:right">+$0.19</td></tr></tbody></table></div>`;

/* ---------------- menus ---------------- */
const MENUS = {
  profile: [['spark','Edit character sheet','upload-sheet'],['outfit','Add outfit','outfit-new'],['retry','Duplicate model','t:Model duplicated'],['export','Share profile card','t:Profile card copied'],['shield','Delete model','t:Delete is disabled in the prototype','danger']],
  direct: [['spark','Show prompt','showprompt'],['quality','Save as preset','t:Saved as preset "Dance · 10 steps"'],['retry','Reset settings','reset'],['upload','Change clip','change-clip']],
  shoot: [['spark','Show prompt','itab-prompt'],['quality','Save as preset','t:Saved as preset'],['retry','Reset camera','shoot-reset']],
  result: [['export','Download','export'],['spark','Copy prompt','copy'],['grid','Compare takes','cmp-from-result'],['bell','Report a problem','t:Thanks, we\'ll look at this take'],['shield','Delete take','discard','danger']],
  job: [['play','Watch','jobopen'],['retry','Run again with same settings','t:Added to the queue'],['spark','Copy prompt','copy'],['shield','Remove from list','jobremove','danger']],
  account: [['user','Sienna\'s studio',''],['wallet','Credits','go:credits'],['quality','Settings','go:settings'],['shield','Sign out','signout','danger']],
  pay: [['wallet','Card · Visa / Mastercard','paid'],['wallet','USDT (TRC-20)','paid'],['wallet','Virtual dollar card','paid']]
};
let menuJob=null;
function openMenu(kind, anchor){ closeMenu(); const win=$('.win'), wr=win.getBoundingClientRect(), r=anchor.getBoundingClientRect(), sc=wr.width/1440;
  const m=document.createElement('div'); m.className='menu'; m.innerHTML=MENUS[kind].map(([i,l,a,d])=>`<div class="mi${d?' '+d:''}" data-mi="${a}">${ic(i,16)}<span>${l}</span></div>`).join('');
  const s=document.createElement('div'); s.className='scrim'; s.onclick=closeMenu; win.append(s,m);
  const top=(r.bottom-wr.top)/sc+6, right=(wr.right-r.right)/sc; m.style.top=top+'px'; m.style.right=right+'px';
  m.animate([{opacity:0,transform:'translateY(-6px) scale(.97)'},{opacity:1,transform:'none'}],{duration:160,easing:'ease-out'});
  m.querySelectorAll('[data-mi]').forEach(x=>x.onclick=()=>{ closeMenu(); const a=x.dataset.mi; if(!a) return; snd('tap'); if(a.startsWith('go:')) go(a.slice(3)); else if(a.startsWith('t:')) toast(a.slice(2)); else act(a); }); snd('tap'); }
function closeMenu(){ document.querySelectorAll('.menu,.scrim').forEach(x=>x.remove()); }

/* ---------------- modal: outfit set ---------------- */
function outfitModal(){ closeMenu(); const o={mode:'describe', state:'idle'}; const win=$('.win'); const bgd=document.createElement('div'); bgd.className='modal-bg';
  const draw=()=>{ bgd.innerHTML=`<div class="modal"><div class="row-b"><div><div class="eyebrow">${MODEL.short}</div><h2 class="h1" style="font-size:${T()==='a'?48:32}px">New outfit set</h2></div><span class="icbtn" data-m="close">✕</span></div>
   <div class="seg">${[['describe','Describe it'],['photo','From a photo'],['own','My own set']].map(([k,l])=>`<span class="${o.mode===k?'on':''}" data-m="mode-${k}">${l}</span>`).join('')}</div>
   ${o.mode==='describe'?`<textarea class="inp" rows="2" placeholder="e.g. sheer crystal mini dress, silver strappy heels"></textarea>`:o.mode==='photo'?`<div class="drop">${ic('upload',22)}<span class="grow"><b>Drop a product photo</b><br><span class="tiny muted">It's used as a reference image, so the outfit matches.</span></span></div>`:`<div class="drop">${ic('upload',22)}<span class="grow"><b>Drop your 4 angle images</b><br><span class="tiny muted">Front, ¾, side and back. Any you skip can be filled in.</span></span></div>`}
   <div class="grid4">${['Front','¾','Side','Back'].map((a,i)=>`<div class="col" style="gap:6px">${o.state==='busy'?'<div class="ph34 shimmer"></div>':o.state==='done'?`<div class="ph34 img" style="${bg(['c_front','c_tq','c_face','c_front'][i])}"><span class="tag">${pill(o.mode==='own'?'yours':'AI',o.mode==='own'?'yours':'acc')}</span></div>`:`<div class="ph34 empty">${a}</div>`}<span class="tiny">${a}</span></div>`).join('')}</div>
   <p class="tiny muted">All four angles use one seed, so the outfit matches from every side. Never add: logos.</p>
   <div class="row"><span class="grow"></span>${o.state==='done'?`<div class="btn" data-m="gen">Retake · $0.08</div><div class="btn pri" data-m="save">Save outfit</div>`:`<div class="btn pri${o.state==='busy'?' off':''}" data-m="gen">${o.mode==='own'?'Use my images':'Generate 4 angles · $0.08'}</div>`}</div></div>`;
   bgd.querySelectorAll('[data-m]').forEach(x=>x.onclick=e=>{ e.stopPropagation(); const m=x.dataset.m; snd('tap');
     if(m==='close'){ bgd.remove(); return; } if(m.startsWith('mode-')){ o.mode=m.slice(5); o.state='idle'; draw(); return; }
     if(m==='gen'){ if(o.state==='busy') return; if(o.mode==='own'){ o.state='done'; draw(); return; } o.state='busy'; draw(); setTimeout(()=>{ o.state='done'; snd('done'); draw(); },1600); return; }
     if(m==='save'){ bgd.remove(); toast('Outfit saved to '+MODEL.short); } }); };
  bgd.onclick=e=>{ if(e.target===bgd) bgd.remove(); }; draw(); win.append(bgd); bgd.firstChild.animate([{opacity:0,transform:'translateY(16px) scale(.98)'},{opacity:1,transform:'none'}],{duration:260,easing:'cubic-bezier(.2,1,.3,1)'}); }

/* ---------------- command palette ---------------- */
const CMDS = [['New video','new-video','studio','⌘N'],['Photoshoot','go:shoot','camera','⌘4'],['New model','go:create','model',''],['Home','go:home','home','⌘1'],['Models','go:models','model','⌘2'],['Queue','go:queue','queue','⌘5'],['Gallery','go:gallery','grid','⌘6'],['Settings','go:settings','quality','⌘,'],['Credits & top up','go:credits','wallet',''],['Theme: Editorial','theme-a','palette',''],['Theme: Camera Body','theme-b','palette',''],['Theme: Soft Tactile','theme-c','palette',''],['Theme: Creator Pop','theme-d','palette',''],['Toggle sound','sound','audio',''],['Toggle pro mode (show prompts)','pro','spark','']];
function palette(){ closeMenu(); if($('.pal')) return; const win=$('.win'); const p=document.createElement('div'); p.className='pal'; let sel=0, list=CMDS;
  p.innerHTML=`<div class="pal-box"><input id="pal-in" placeholder="Type a command or screen…"><div class="pal-list" id="pal-list"></div></div>`;
  const draw=()=>{ $('#pal-list',p).innerHTML=list.map(([l,a,i,k],n)=>`<div class="mi${n===sel?' sel':''}" data-pa="${a}">${ic(i,16)}<span>${l}</span>${k?`<span class="kbd">${k}</span>`:''}</div>`).join('')||'<div class="mi muted">No matches</div>';
    p.querySelectorAll('[data-pa]').forEach(x=>x.onclick=()=>run(x.dataset.pa)); };
  const run=a=>{ p.remove(); if(a.startsWith('go:')) go(a.slice(3)); else act(a); };
  p.onclick=e=>{ if(e.target===p) p.remove(); }; win.append(p); draw(); const inp=$('#pal-in',p); inp.focus();
  inp.oninput=()=>{ const q=inp.value.toLowerCase(); list=CMDS.filter(c=>c[0].toLowerCase().includes(q)); sel=0; draw(); };
  inp.onkeydown=e=>{ if(e.key==='ArrowDown'){ sel=Math.min(list.length-1,sel+1); draw(); e.preventDefault(); } else if(e.key==='ArrowUp'){ sel=Math.max(0,sel-1); draw(); e.preventDefault(); } else if(e.key==='Enter'&&list[sel]) run(list[sel][1]); else if(e.key==='Escape') p.remove(); }; snd('tap'); }

/* ---------------- render + navigation ---------------- */
const MOTION = {
  a: { dur: 420, ease: 'cubic-bezier(.22,.61,.36,1)', f: d => [{opacity:0, transform:`translateY(${d>=0?14:-14}px)`},{opacity:1, transform:'none'}] },
  b: { dur: 200, ease: 'cubic-bezier(.4,0,.2,1)', f: d => [{opacity:0, transform:`translateX(${d>=0?24:-24}px)`, filter:'brightness(.5)'},{opacity:1, transform:'none', filter:'brightness(1)'}] },
  c: { dur: 480, ease: 'cubic-bezier(.2,1.25,.35,1)', f: d => [{opacity:0, transform:'scale(.97)'},{opacity:1, transform:'none'}] },
  d: { dur: 420, ease: 'cubic-bezier(.3,1.6,.5,1)', f: d => [{opacity:0, transform:'translateY(26px) rotate(.6deg)'},{opacity:1, transform:'none'}] }
};
function render(anim=0){ closeMenu(); const sc=$('#scaler'); sc.className='scaler t-'+S.theme;
  sc.innerHTML = S.authed ? shell(SCREENS[S.screen]()) : SCREENS.auth();
  const w=$('.win',sc); if(w) w.append(TOASTEL);
  bind(sc); if(anim!==null){ const m=$('#main .page')||$('.auth'); if(m) m.animate(MOTION[S.theme].f(anim),{duration:MOTION[S.theme].dur,easing:MOTION[S.theme].ease}); } }
function refresh(){ const pg=$('#main .page'); const ys=[...document.querySelectorAll('#main .center,#main .page,#main .insp-scroll,#main .lcol')].map(e=>e.scrollTop); render(null); [...document.querySelectorAll('#main .center,#main .page,#main .insp-scroll,#main .lcol')].forEach((e,i)=>e.scrollTop=ys[i]||0); }
function go(name){ if(name===S.screen){ return; } S.stack.push(S.screen); if(name!=='gallery'){ S.cmp=false; } snd('nav'); S.screen=name; render(1); }
const TOASTEL=document.createElement('div'); TOASTEL.className='toast'; TOASTEL.id='toast';
function toast(msg, linkTxt, onLink){ const t=TOASTEL; if(!t) return; t.innerHTML=ic('spark',16)+`<span class="grow">${msg}</span>`+(linkTxt?`<span class="link">${linkTxt}</span>`:''); t.classList.add('show'); const l=t.querySelector('.link'); if(l) l.onclick=()=>{ t.classList.remove('show'); onLink&&onLink(); }; clearTimeout(toast.t); toast.t=setTimeout(()=>t.classList.remove('show'), 3600); }
function setTheme(t){ if(t===S.theme) return; S.theme=t; store.set('theme',t); render(null); snd('theme'); const w=$('.win'); if(w) w.animate([{filter:'blur(6px)',opacity:.6},{filter:'none',opacity:1}],{duration:380,easing:'ease-out'}); }
function setSteps(n){ n=Math.max(4,Math.min(30,n)); if(n===S.steps) return; S.steps=n; snd('tick');
  const v=$('#steps-v'); if(!v||S.screen!=='studio'){ refresh(); return; }
  v.textContent=n; const r=$('#steps-rec'); if(r) r.textContent= T()==='b'?(n===10?'RECOMMENDED':n>10?'RARELY WORTH IT':'BELOW TESTED'):(n===10?'Recommended':n>10?'Rarely worth it':'Below tested');
  const pct=(n-4)/26*100, sl=$('#slider'); if(sl){ sl.querySelector('i').style.width=pct+'%'; sl.querySelector('b').style.left=pct+'%'; }
  const k=$('#knob'); if(k) k.style.transform=`rotate(${(n-17)*10}deg)`;
  const d=$('#steps-delta'); if(d) d.textContent=stepsDelta();
  $('#est-t').textContent=fmtMin(estMin()*S.takes); $('#est-c').textContent=money(totalCost()); $('#est-a').textContent=money(Math.max(0,S.balance-totalCost()));
  const g=$('#gen'); if(g&&!S.clipBad){ const low=totalCost()>S.balance; if(low!==g.classList.contains('off')){ refresh(); return; } g.textContent=genLabel(); }
  const pre=$('.promptpre'); if(pre) pre.textContent=videoPrompt(); }

function bind(root){
  root.querySelectorAll('[data-go]').forEach(e=>e.onclick=ev=>{ ev.stopPropagation(); snd('tap'); go(e.dataset.go); });
  root.querySelectorAll('[data-act]').forEach(e=>e.onclick=ev=>{ ev.stopPropagation(); snd('tap'); act(e.dataset.act, e); });
  const sl=$('#slider'); if(sl){ const at=x=>{ const r=sl.getBoundingClientRect(); setSteps(Math.round(4+Math.max(0,Math.min(1,(x-r.left)/r.width))*26)); };
    sl.onpointerdown=e=>{ sl.setPointerCapture(e.pointerId); at(e.clientX); sl.onpointermove=m=>at(m.clientX); sl.onpointerup=()=>{ sl.onpointermove=null; }; }; }
  const kn=$('#knob'); if(kn){ kn.onwheel=e=>{ e.preventDefault(); setSteps(S.steps+(e.deltaY<0?1:-1)); };
    kn.onpointerdown=e=>{ kn.setPointerCapture(e.pointerId); const y0=e.clientY, s0=S.steps; kn.onpointermove=m=>setSteps(s0+Math.round((y0-m.clientY)/8)); kn.onpointerup=()=>{ kn.onpointermove=null; }; }; }
  const ta=(id,key,after)=>{ const el=$('#'+id); if(el) el.oninput=()=>{ S[key]=el.value; after&&after(); }; };
  ta('scene-custom','sceneCustom',()=>{ document.querySelectorAll('[data-act^="scene-"]').forEach(c=>c.classList.toggle('on', !S.sceneCustom.trim() && c.dataset.act==='scene-'+S.scene)); });
  ta('dir','direction',()=>{ const pb=$('#pbox'); if(pb) pb.innerHTML=pboxHTML(shootPrompt()); });
  const cn=$('#c-name'); if(cn) cn.oninput=()=>S.create.name=cn.value; const cp=$('#c-pers'); if(cp) cp.oninput=()=>S.create.personality=cp.value; const cno=$('#c-notes'); if(cno) cno.oninput=()=>S.create.notes=cno.value;
  root.querySelectorAll('input,textarea').forEach(i=>i.onclick=e=>e.stopPropagation());
  const dr=$('#drop'); if(dr){ dr.ondragover=e=>{ e.preventDefault(); dr.classList.add('over'); }; dr.ondragleave=()=>dr.classList.remove('over'); dr.ondrop=e=>{ e.preventDefault(); act('upload-all'); }; }
}

/* ---------------- jobs ---------------- */
let ticker=null;
function startQueue(){ const next=S.jobs.find(j=>j.state==='queued'); if(!next||running()) return; next.state='running'; next.mins = next.mins || (next.engine==='Fast · beta'?1.6:next.steps*secPerLen(next.len)/60+0.5); S.gpu='on';
  clearInterval(ticker); const t0=Date.now(), dur=next.mins*60/24*1000;
  ticker=setInterval(()=>{ next.p=Math.min(100,(Date.now()-t0)/dur*100);
    if(next.p>=100){ clearInterval(ticker); next.state='done'; S.fresh.push(next.id); snd('done'); toast(`<b>${next.title}</b> is ready.`, 'Review', ()=>{ S.open=next.id; go('result'); }); if(S.jobs.some(j=>j.state==='queued')) setTimeout(startQueue,600); }
    if(['queue','home'].includes(S.screen)||next.state==='done') refresh(); else { const c=$('.jobchip'); if(c){ c.innerHTML=`<span class="led on"></span>step ${Math.min(next.steps,Math.floor(next.p/100*next.steps)+1)}/${next.steps}<span class="mini"><i style="width:${next.p}%"></i></span>`; } else refresh(); } }, 400); }

function act(a, el){
  if(a.startsWith('theme-')) return setTheme(a.slice(6));
  if(a.startsWith('menu-')){ const k=a.slice(5); if(k.startsWith('job-')){ menuJob=k.slice(4); return openMenu('job', el); } return openMenu(k, el); }
  if(a==='palette') return palette();
  if(a==='sound'){ S.sound=!S.sound; store.set('sound',S.sound); if(S.sound) snd('tap'); toast('Sound '+(S.sound?'on':'off')); return refresh(); }
  if(a==='pro'){ S.pro=!S.pro; store.set('pro',S.pro); toast('Pro mode '+(S.pro?'on: prompts are shown':'off')); return refresh(); }
  if(a==='new-video'){ return go('studio'); }
  if(a==='signin'){ S.authed=true; S.screen='home'; snd('go'); return render(1); }
  if(a==='signout'){ S.authed=false; S.authTab='in'; return render(1); }
  if(a==='auth-up'||a==='auth-in'){ S.authTab=a==='auth-up'?'up':'in'; return render(0); }
  if(a.startsWith('att-')){ if(a==='att-need'){ toast('Tick both boxes to create your account'); return; } const i=+a.slice(4); S.att[i]=!S.att[i]; return render(null); }
  if(a==='toast-noor') return toast('Noor is a draft. Add face close-ups to use her.');
  /* studio */
  if(a==='clipbad'){ S.clipBad=!S.clipBad; return refresh(); }
  if(a==='change-clip') return toast('Pick a clip from Finder, or drag one onto the window');
  if(a.startsWith('use-')){ S.use=a.slice(4); return refresh(); }
  if(a.startsWith('engine-')){ S.engine=a.slice(7); return refresh(); }
  if(a==='steps-inc') return setSteps(S.steps+1); if(a==='steps-dec') return setSteps(S.steps-1);
  if(a==='takes-inc'){ S.takes=Math.min(4,S.takes+1); return refresh(); } if(a==='takes-dec'){ S.takes=Math.max(1,S.takes-1); return refresh(); }
  if(a.startsWith('bg-')){ S.bg=a.slice(3); return refresh(); } if(a.startsWith('motion-')){ S.motion=a.slice(7); return refresh(); }
  if(a==='audio'){ S.keepAudio=!S.keepAudio; return refresh(); } if(a==='lip'){ S.lip=!S.lip; return refresh(); }
  if(a==='showprompt'){ if(S.screen!=='studio'){ go('studio'); } S.showPrompt=!S.showPrompt; return refresh(); }
  if(a==='reset'){ Object.assign(S,{steps:10,engine:'h3',takes:1,lip:false,keepAudio:true,bg:'keep',use:'first'}); toast('Settings reset'); return refresh(); }
  if(a.startsWith('outfit-')){ if(a==='outfit-new') return outfitModal(); S.outfit=+a.slice(7); return refresh(); }
  if(a==='blocked') return toast('Fix the clip first: one person, no watermark, 15s or less');
  if(a==='lowbal') return toast('Not enough balance for this render', 'Top up', ()=>go('credits'));
  if(a==='generate'){ const c=totalCost(); S.balance-=c; S.today+=c; S.month+=c; for(let i=S.takes-1;i>=0;i--){ S.jobs.unshift({ id:'n'+Date.now()+i, img:S.outfit?'vid_living2':'vid_living', title:`${MODEL.short} · ${OUTFITS[S.outfit][1]}${S.takes>1?' · take '+(i+1):''}`, engine:S.engine==='viggle'?'Fast · beta':'Standard', steps:S.engine==='viggle'?4:S.steps, len:LENS(), p:0, state:'queued', cost:estCost(), mins:estMin() }); }
    snd('go'); startQueue(); toast(`Rendering ${S.takes>1?S.takes+' takes':'1 take'} · ${money(c)}. You'll get a notification when it's done.`, 'Open queue', ()=>go('queue')); return refresh(); }
  /* queue */
  if(a==='runq'){ snd('go'); startQueue(); toast('GPU starting · about 1–2 min'); return refresh(); }
  if(a==='retryfail'){ S.failed=false; S.jobs.push({ id:'r'+Date.now(), img:'vid_living2', title:'Mirror selfie · retry', engine:'Standard', steps:10, len:5.2, p:0, state:'queued', cost:0.66 }); startQueue(); return refresh(); }
  if(a==='dismissfail'){ S.failed=false; return refresh(); }
  if(a==='jobopen'){ S.open=menuJob; return go('result'); }
  if(a==='jobremove'){ S.jobs=S.jobs.filter(j=>j.id!==menuJob||j.state==='running'); return refresh(); }
  /* gallery */
  if(a==='gal-tests'||a==='gal-final'){ S.gallery=a.slice(4); return refresh(); }
  if(a.startsWith('pick-')){ if(a==='pick-clear'){ S.picked=[]; return refresh(); } const id=a.slice(5); S.picked=S.picked.includes(id)?S.picked.filter(x=>x!==id):[...S.picked,id].slice(-4); return refresh(); }
  if(a==='cmp-open'){ S.cmp=true; return render(1); } if(a==='cmp-close'){ S.cmp=false; return render(-1); }
  if(a==='cmp-from-result'){ S.picked=[S.open,'g5','g1'].filter((v,i,ar)=>v&&ar.indexOf(v)===i).slice(0,3); S.cmp=true; return go('gallery'); }
  if(a.startsWith('open-')){ S.open=a.slice(5); S.fresh=S.fresh.filter(x=>x!==S.open); return go('result'); }
  if(a.startsWith('approve-')){ const id=a.slice(8); if(!S.final.includes(id)){ S.final.push(id); snd('done'); toast('Moved to Final'); } return refresh(); }
  if(a==='discard'){ toast('Take discarded'); S.jobs=S.jobs.filter(j=>j.id!==S.open); return go('gallery'); }
  if(a==='export'){ snd('go'); return toast('Exported 1080×1920 with the AI-generated label'); }
  if(a==='retake'){ return go(galleryTiles().find(t=>t[2]===S.open)?.[3]==='photo'?'shoot':'studio'); }
  if(a==='copy'){ try{ navigator.clipboard.writeText(S.screen==='shoot'?Object.values(shootPrompt()).filter(Boolean).join('\n'):videoPrompt()); }catch(e){} return toast('Prompt copied'); }
  /* shoot */
  if(a.startsWith('itab-')){ if(S.screen!=='shoot'){ S.itab=a.slice(5); return go('shoot'); } S.itab=a.slice(5); return refresh(); }
  if(a.startsWith('scene-')){ S.scene=a.slice(6); S.sceneCustom=''; return refresh(); }
  if(a.startsWith('shot-')){ S.shot=a.slice(5); return refresh(); } if(a.startsWith('lens-')){ S.lens=+a.slice(5); return refresh(); }
  if(a.startsWith('ap-')){ S.aperture=a.slice(3); return refresh(); } if(a.startsWith('light-')){ S.light=a.slice(6); return refresh(); } if(a.startsWith('grade-')){ S.grade=a.slice(6); return refresh(); }
  if(a==='lockseed'){ S.lockSeed=!S.lockSeed; return refresh(); }
  if(a==='shoot-reset'){ Object.assign(S,{shot:'Medium',lens:35,aperture:'f/2.8'}); toast('Camera reset'); return refresh(); }
  if(a==='edittext'){ const pb=$('#pbox'); if(pb){ pb.outerHTML=`<textarea class="inp" rows="9" style="font-family:var(--mono);font-size:12px">${Object.values(shootPrompt()).filter(Boolean).join('\n')}</textarea>`; toast('Editing as text. Your edits apply to the next shoot only.'); } return; }
  if(a==='shoot'){ S.shootState='busy'; snd('go'); refresh(); S.balance-=0.08; setTimeout(()=>{ S.shootState='done'; const t=Date.now(); S.shots=[...SHOTS_IMG.map((k,i)=>[k,'Shoot · '+(S.sceneCustom.trim()||S.scene).split('·')[0].trim()+' '+(i+1),'s'+t+i]),...S.shots]; S.fresh=S.shots.slice(0,4).map(s=>s[2]); snd('done'); if(S.screen==='shoot') refresh(); },1800); return; }
  if(a==='shots-gallery'){ S.gallery='tests'; return go('gallery'); }
  /* models */
  if(a.startsWith('niche-')){ S.create.niche=a.slice(6); return refresh(); }
  if(a==='create-next'){ S.create.step=2; return render(1); } if(a==='create-back'){ S.create.step=1; return render(-1); }
  if(a==='create-save'){ const n=SLOTS.filter(([k])=>S.sheet[k]).length; toast(`${S.create.name||'New model'} saved with ${n}/6 shots${n<6?' · you can add the rest any time':''}`); S.create={step:1,name:'',niche:'Beauty',personality:'',notes:''}; S.sheet={}; return go('models'); }
  if(a==='upload-all'){ const order=['face','front','tq','back']; order.forEach((k,i)=>setTimeout(()=>{ S.sheet[k]='yours'; snd('tick'); refresh(); },i*180)); return; }
  if(a.startsWith('slot-up-')){ S.sheet[a.slice(8)]='yours'; return refresh(); }
  if(a.startsWith('slot-clear-')){ delete S.sheet[a.slice(11)]; return refresh(); }
  if(a==='fill-missing'){ const miss=SLOTS.filter(([k])=>!S.sheet[k]).map(([k])=>k); miss.forEach(k=>S.sheet[k]='busy'); S.balance-=0.02*miss.length; refresh(); setTimeout(()=>{ miss.forEach(k=>S.sheet[k]='ai'); snd('done'); refresh(); },1600); return; }
  if(a==='upload-sheet') return toast('Choose images from Finder, or drop them on a slot');
  if(a.startsWith('replace-')) return toast('Choose a new image for this slot');
  if(a.startsWith('retake-')) return toast('Retaking this angle from your other images · $0.02');
  if(a.startsWith('never-del-')){ S.never.splice(+a.slice(10),1); return refresh(); }
  if(a==='never-add'){ const opts=['necklaces','logos','glasses','piercings'].filter(x=>!S.never.includes(x)); if(opts[0]) S.never.push(opts[0]); return refresh(); }
  /* settings */
  if(a.startsWith('sec-')){ S.settingsSec=a.slice(4); return refresh(); }
  if(a==='paid'){ S.balance+=25; snd('done'); toast('$25.00 added'); return refresh(); }
  if(a==='noop') return;
}

document.addEventListener('keydown', e=>{ const tag=(e.target.tagName||'').toLowerCase(); const typing=tag==='input'||tag==='textarea';
  if(e.key==='Escape'){ closeMenu(); document.querySelectorAll('.pal,.modal-bg').forEach(x=>x.remove()); return; }
  if(!S.authed) return;
  if((e.metaKey||e.ctrlKey)&&e.key==='k'){ e.preventDefault(); return palette(); }
  if((e.metaKey||e.ctrlKey)&&e.key==='n'){ e.preventDefault(); return go('studio'); }
  if((e.metaKey||e.ctrlKey)&&e.key===','){ e.preventDefault(); return go('settings'); }
  if((e.metaKey||e.ctrlKey)&&e.key==='Enter'&&S.screen==='studio'){ e.preventDefault(); const g=$('#gen'); return g&&act(g.dataset.act); }
  if((e.metaKey||e.ctrlKey)&&/^[1-7]$/.test(e.key)){ e.preventDefault(); return go(NAV[+e.key-1][0]); }
  if(!typing&&S.screen==='studio'&&S.engine==='h3'&&(e.key==='ArrowRight'||e.key==='ArrowLeft')){ setSteps(S.steps+(e.key==='ArrowRight'?1:-1)); }
});
function fit(){ const sc=$('#scaler'); const s=Math.min(1,(innerWidth-32)/1440,(innerHeight-32)/900); sc.style.transform=`scale(${s})`; }
addEventListener('resize', fit);
const start=new URLSearchParams(location.search); if(start.get('theme')) S.theme=start.get('theme'); if(start.get('screen')) S.screen=start.get('screen'); if(start.get('auth')==='0') S.authed=false;
/* first render happens at the end of features.js */
