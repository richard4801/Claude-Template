/* ---------- Identity LoRA + social accounts (phone prototype) ----------
   Specs: plans/lora-training.md and plans/socials.md. Loaded after app.js. */
const PLATFORMS = [['tiktok','TikTok','#111','TT'],['instagram','Instagram','#D62976','IG'],['facebook','Facebook','#1877F2','f'],['youtube','YouTube','#FF0000','YT'],['x','X','#111','X']];
const pb = (k, s=28) => { const p=PLATFORMS.find(x=>x[0]===k); return `<span class="pbadge" style="width:${s}px;height:${s}px;background:${p[2]};font-size:${Math.round(s*.38)}px">${p[3]}</span>`; };
const pname = k => PLATFORMS.find(x=>x[0]===k)[1];
const LORA_PRICE = { gen: 0.02, photoMin: 25, videoMin: 75, gpuHr: 3.99 };
const loraTrainCost = () => (LORA_PRICE.photoMin + LORA_PRICE.videoMin) / 60 * LORA_PRICE.gpuHr;
const CAND_POOL = [['g_front','Green set · front'],['g_tq','Green set · ¾'],['face','Close-up · window light'],['c_front','Crystal dress · full'],['g_side','Green set · side'],['profile','Profile · soft light'],['c_tq','Crystal · ¾'],['g_back','Back · physique'],['hero','Portrait · golden hour'],['c_face','Close-up · choker']];
S.lora = { state: 'none', cands: [], p: 0, phase: '', use: true, v: 0 };
S.acc = { tiktok: null, instagram: null, facebook: null, youtube: null, x: null };
S.posts = [];
S.post = { pl: [], caption: '', ai: false, ad: false, when: 'now', slot: 'Today · 7:30 PM' };
S.postTab = 'scheduled';

const loraLine = () => ({ none: 'Not trained · locks face + physique', gen: 'Building training set…', review: 'Review the training set', training: `Training · ${Math.round(S.lora.p)}%`, done: `v${S.lora.v} ready · ${S.lora.use?'on':'off'}` })[S.lora.state];
const nAcc = () => Object.values(S.acc).filter(Boolean).length;
const profExtras = () => `<div class="pex"><div class="pe press" data-go="lora">${ic('spark',18)}<span><b>Identity LoRA</b><span class="tiny muted">${loraLine()}</span></span></div><div class="pe press" data-go="accounts">${ic('export',18)}<span><b>Accounts</b><span class="tiny muted">${nAcc()} of 5 connected</span></span></div></div>`;

SCREENS.lora = () => { const L=S.lora, ok=L.cands.filter(c=>c.ok).length, cost=loraTrainCost(), low=cost>S.balance;
  let body='', dock='';
  if(L.state==='none'){ body=`<div class="lora-hero" style="${bg('hero')}"><span class="lh-cap"><b>Sienna Vale</b><span class="tiny">6 reference shots · no LoRA yet</span></span></div>
    <p class="small">A LoRA is a small add-on trained on one model. It keeps her <b>face and physique</b> the same in every photo and video, beyond what 6 reference shots can hold.</p>
    <div class="list"><div class="li">${ic('camera',20)}<span class="grow"><b>Photo LoRA</b><br><span class="tiny muted">For photoshoots · ~${LORA_PRICE.photoMin} min</span></span></div>
     <div class="li">${ic('studio',20)}<span class="grow"><b>Video LoRA</b><br><span class="tiny muted">For H3 videos · ~${LORA_PRICE.videoMin} min</span></span></div></div>
    <div class="fld"><span class="lbl">How it works</span><div class="steps3"><span><b>1</b>We generate 30 varied shots from her sheet</span><span><b>2</b>You keep the ones that look like her</span><span><b>3</b>We train both LoRAs on what you kept</span></div></div>`;
    dock=`<div class="cta grow press" data-act="lora-gen">Build training set · ${money(30*LORA_PRICE.gen)}</div>`; }
  if(L.state==='gen'){ body=`<p class="small">Generating 30 shots: new angles, outfits, light and expressions, full body included so her physique is learned too.</p><div class="lgrid">${Array.from({length:12},()=>`<div class="lt shimmer"></div>`).join('')}</div>`; dock=`<div class="cta grow is-off">Generating…</div>`; }
  if(L.state==='review'){ body=`<div class="row-b"><b class="h3">${ok} kept</b>${pill(ok>=20?'Enough to train':'Keep at least 20', ok>=20?'good':'warn')}</div>
    <p class="tiny muted">Tap a shot to drop it. Drop anything that doesn't look like her, or shows a tattoo or ring. ${L.cands.filter(c=>c.flag).length} were flagged for you.</p>
    <div class="lgrid">${L.cands.map((c,i)=>`<div class="lt press${c.ok?'':' out'}" data-act="lora-t-${i}" style="${bg(c.k)}">${c.flag?`<span class="lflag">${c.flag}</span>`:''}<span class="lchk">${c.ok?ic('check',13):'✕'}</span></div>`).join('')}</div>`;
    dock= ok<20?`<div class="cta grow is-off" data-act="lora-few">Keep ${20-ok} more to train</div>`: low?`<div class="cta grow press" data-go="credits">Top up to train · ${money(cost)}</div>`:`<div class="cta grow press" data-act="lora-train">Train · ~1 h 40 min · ${money(cost)}</div>`; }
  if(L.state==='training'){ const ph=L.p<25?0:1; body=`<div class="lora-hero" style="${bg('face')}"><span class="lh-cap"><b>Training on ${ok} shots</b><span class="tiny">You can leave this screen. We'll notify you.</span></span></div>
    ${[['Photo LoRA',Math.min(100,L.p*4)],['Video LoRA',Math.max(0,(L.p-25)/75*100)]].map(([n,p],i)=>`<div class="fld"><div class="row-b"><b>${n}</b><span class="tiny mono">${Math.round(p)}%</span></div><div class="pbar"><i data-lp="${i}" style="width:${p}%"></i></div></div>`).join('')}
    <p class="tiny muted mono" id="lora-left">~${Math.max(1,Math.round((100-L.p)/100*100))} min left · demo runs 120× faster</p>`; dock=`<div class="cta-2 grow press" data-back>Back to profile</div>`; }
  if(L.state==='done'){ body=`<div class="row-g"><div class="cmp2"><div class="lt tall" style="${bg('c_face')}"></div><span class="tiny muted">References only</span></div><div class="cmp2"><div class="lt tall" style="${bg('face')}"></div><span class="tiny"><b>With LoRA v${L.v}</b></span></div></div>
    <p class="tiny muted">Same prompt and seed. The LoRA keeps her face shape, freckles and build steady across angles.</p>
    <div class="list"><div class="li"><span class="grow"><b>Use in new renders</b><br><span class="tiny muted">Photos and videos · identity + physique</span></span><span class="tog${L.use?' on':''}" data-act="lora-use"></span></div>
     <div class="li"><span class="grow">Trained on</span><span class="tiny mono">${ok} shots · v${L.v}</span></div>
     <div class="li press" data-act="lora-retrain"><span class="grow">Retrain with more shots</span>${ic('chev',16)}</div></div>`; dock=`<div class="cta grow press" data-go="shoot">Test it in a photoshoot</div>`; }
  return `<section class="screen">${sbar()}${topb('Identity LoRA')}<div class="pad stack-14 scroll fx" style="padding-bottom:130px">${body}</div><div class="dock">${dock}</div>${home}</section>`; };

SCREENS.accounts = () => `<section class="screen">${sbar()}${topb('Accounts')}<div class="pad stack-14 scroll fx" style="padding-bottom:120px">
  <p class="small">Sienna's own accounts. Posts from her renders go here, not to your personal accounts.</p>
  <div class="list">${PLATFORMS.map(([k,n])=>{ const h=S.acc[k]; return `<div class="li">${pb(k,32)}<span class="grow"><b>${n}</b><br><span class="tiny muted">${h?h:'Not connected'}</span></span>${h?`<span class="tiny acc press" data-act="acc-off-${k}">Disconnect</span>`:`<span class="cta-2 press" style="height:36px;padding:0 14px" data-act="acc-on-${k}">Connect</span>`}</div>`; }).join('')}</div>
  <div class="note-box">${ic('shield',18)}<span class="tiny">For now MUSE opens each app with your video and caption ready to post. Direct posting and auto-scheduling switch on per platform once it approves MUSE.</span></div>
  <div class="li press" data-go="posts" style="border:var(--stroke) solid var(--line);border-radius:var(--r)">${ic('queue',20)}<span class="grow">Scheduled and posted</span><span class="tiny muted">${S.posts.length}</span>${ic('chev',16)}</div></div>${home}</section>`;

SCREENS.post = () => { const P=S.post, j=S.open||S.jobs[0], conn=PLATFORMS.filter(([k])=>S.acc[k]);
  const label = P.when==='now' ? `Post to ${P.pl.length||'…'} account${P.pl.length===1?'':'s'}` : `Schedule · ${P.slot}`;
  return `<section class="screen">${sbar()}${topb('Post')}<div class="pad stack-14 scroll fx" style="padding-bottom:130px">
  <div class="prow" style="border:0;padding:0;background:none"><div class="pthumb" style="${bg(j.img)}"></div><div class="grow"><b>${j.title}</b><div class="tiny muted">Sienna Vale · 1080×1920</div></div></div>
  <div class="fld"><span class="lbl">Post to</span>${conn.length?`<div class="chips">${conn.map(([k,n])=>`<span class="chip pchip${P.pl.includes(k)?' on':''}" data-act="pl-${k}">${pb(k,20)} ${n}</span>`).join('')}</div>`:''}
   ${conn.length<5?`<span class="tiny acc press" data-go="accounts" style="padding:4px 0">+ Connect ${conn.length?'more accounts':'Sienna\'s accounts'}</span>`:''}</div>
  <label class="fld"><span class="lbl">Caption</span><textarea class="inp area" id="cap" rows="3" placeholder="Write a caption and hashtags">${P.caption}</textarea></label>
  <div class="list"><div class="li"><span class="grow"><b>Mark as AI-generated</b><br><span class="tiny muted">Turns on the platform's own AI label</span></span><span class="tog${P.ai?' on':''}" data-act="post-ai"></span></div>
   <div class="li"><span class="grow"><b>Paid partnership</b><br><span class="tiny muted">Turns on the platform's branded-content tag</span></span><span class="tog${P.ad?' on':''}" data-act="post-ad"></span></div></div>
  <div class="fld"><span class="lbl">When</span><div class="seg"><span class="${P.when==='now'?'on':''}" data-act="when-now">Now</span><span class="${P.when==='later'?'on':''}" data-act="when-later">Schedule</span></div>
   ${P.when==='later'?`<div class="chips">${['Today · 7:30 PM','Tomorrow · 12:00 PM','Fri · 6:00 PM'].map(x=>`<span class="chip${P.slot===x?' on':''}" data-act="slot-${x}">${x}</span>`).join('')}</div><span class="tiny muted">We'll notify you at that time and open each app with the post ready.</span>`:''}</div>
  </div><div class="dock"><div class="cta grow press${P.pl.length?'':' is-off'}" data-act="${P.pl.length?'post-go':'post-none'}">${label}</div></div>${home}</section>`; };

SCREENS.posts = () => { const list=S.posts.filter(p=>S.postTab==='scheduled'?p.state==='scheduled':p.state==='posted');
  return `<section class="screen">${sbar()}${topb('Posts')}<div class="pad stack-14 scroll fx" style="padding-bottom:120px">
  <div class="seg"><span class="${S.postTab==='scheduled'?'on':''}" data-act="ptab-scheduled">Scheduled · ${S.posts.filter(p=>p.state==='scheduled').length}</span><span class="${S.postTab==='posted'?'on':''}" data-act="ptab-posted">Posted · ${S.posts.filter(p=>p.state==='posted').length}</span></div>
  ${list.length?list.map(p=>`<div class="prow"><div class="pthumb" style="${bg(p.img)}"></div><div class="grow stack-4"><b class="small">${p.title}</b><div class="row" style="gap:4px">${p.pl.map(k=>pb(k,18)).join('')}<span class="tiny muted" style="margin-left:4px">${p.state==='scheduled'?p.slot:'Posted '+p.ago}</span></div>
    ${p.state==='posted'?`<span class="tiny mono muted">${p.views.toLocaleString()} views · ${p.likes.toLocaleString()} likes · ${p.comments} comments</span>`:''}</div></div>`).join('')
   :`<div class="note-box">${ic('spark',18)}<span>${S.postTab==='scheduled'?'Nothing scheduled. Open a finished take and tap Post.':'Nothing posted yet.'}</span></div>`}
  </div>${home}</section>`; };

/* Result screen: Post button instead of the automatic-label line */
SCREENS.result = () => { const j=S.open||S.jobs[0], posted=S.posts.find(p=>p.jid===j.id&&p.state==='posted');
  return `<section class="screen"><div class="full" style="${bg(j.img==='c_tq'?'c_tq':j.img)}">${sbar(true)}${topb('Take 1 of 1','back',['more','settings'],true)}${vf()}
   <div class="res-side"><div class="rs press" data-go="direct">${ic('retry')}<span>Retry · ${money(estCost())}</span></div><div class="rs press" data-act="export">${ic('export')}<span>Export</span></div><div class="rs press" data-act="post-open">${ic('upload')}<span>Post</span></div></div>
   </div>
  <div class="res-sheet stack-12"><div class="row-b"><div><b class="h3">${j.title}</b><div class="tiny muted">${j.engine} · ${money(j.cost)}</div></div>${pill(S.final.includes(j.id)?'Final':'Test',S.final.includes(j.id)?'good':'')}</div>
   ${posted?`<p class="tiny mono muted">${posted.pl.map(k=>pb(k,16)).join(' ')} ${posted.views.toLocaleString()} views · ${posted.likes.toLocaleString()} likes</p>`:''}
   <div class="row-g"><div class="cta-2 grow press" data-act="discard">Discard</div><div class="cta grow press" data-act="approve">${S.final.includes(j.id)?'Approved ✓':'Approve'}</div></div></div>${home}</section>`; };

/* Profile: add the LoRA + Accounts tiles above the dock in every theme */
{ const prof=SCREENS.profile; SCREENS.profile=()=>prof().replace('<div class="dock"><div class="cta grow press" data-go="source">', profExtras()+'<div class="dock"><div class="cta grow press" data-go="source">'); }
/* Settings: posts & accounts entry */
{ const st=SCREENS.settings; SCREENS.settings=()=>st().replace('<div class="li press" data-go="credits">', `<div class="li press" data-go="accounts">${ic('export',20)}<span class="grow">Sienna's accounts</span><span class="tiny muted">${nAcc()}/5</span>${ic('chev',16)}</div><div class="li press" data-go="posts">${ic('queue',20)}<span class="grow">Scheduled posts</span><span class="tiny muted">${S.posts.filter(p=>p.state==='scheduled').length}</span>${ic('chev',16)}</div><div class="li press" data-go="credits">`); }
/* Prompt engine: identity layer names the LoRA when it's on */
{ const bp=buildPrompt; buildPrompt=k=>{ const p=bp(k); if(p&&S.lora.state==='done'&&S.lora.use) p.identity=p.identity.replace('Identity from 6 locked reference images.', `Identity from 6 locked reference images + LoRA sienna_v${S.lora.v} (photo).`); return p; }; }
MENUS.profile.splice(2,0,['spark','Identity LoRA','go:lora'],['export','Accounts','go:accounts']);
MENUS.result.splice(1,0,['upload','Post','post-open']);

let loraIv=null;
{ const act0=act; act=function(a, el){
  { const c=$('#cap'); if(c) S.post.caption=c.value; }
  if(a==='lora-gen'){ if(S.balance<0.6) return toast('Not enough balance'); S.balance-=0.6; S.month+=0.6; S.lora.state='gen'; snd('go'); refresh();
    setTimeout(()=>{ S.lora.cands=Array.from({length:30},(_,i)=>{ const [k,l]=CAND_POOL[i%CAND_POOL.length]; const flag=[9,19,23].includes(i)?(k==='c_face'?'choker':i===23?'face drift':'ring'):''; return {k,l,ok:!flag,flag}; }); S.lora.state='review'; snd('done'); if(S.screen==='lora') refresh(); }, 1800); return; }
  if(a.startsWith('lora-t-')){ const c=S.lora.cands[+a.slice(7)]; c.ok=!c.ok; snd('tick'); refresh(); return; }
  if(a==='lora-few'){ toast('Keep at least 20 shots so the LoRA learns her well'); return; }
  if(a==='lora-train'){ const cost=loraTrainCost(); if(cost>S.balance){ toast('Not enough balance'); return; } S.balance-=cost; S.month+=cost; S.lora.state='training'; S.lora.p=0; snd('go'); refresh();
    clearInterval(loraIv); const t0=Date.now(); loraIv=setInterval(()=>{ S.lora.p=Math.min(100,(Date.now()-t0)/1000*120/60); // 100 min at 120x
      const L=S.lora; [Math.min(100,L.p*4),Math.max(0,(L.p-25)/75*100)].forEach((p,i)=>{ const b=document.querySelector(`[data-lp="${i}"]`); if(b){ b.style.width=p+'%'; b.parentElement.previousElementSibling.lastElementChild.textContent=Math.round(p)+'%'; } });
      const lf=$('#lora-left'); if(lf) lf.textContent=`~${Math.max(1,Math.round(100-L.p))} min left · demo runs 120× faster`;
      if(L.p>=100){ clearInterval(loraIv); L.state='done'; L.v+=1; notifySound(); confetti(); toast(`Identity LoRA v${L.v} is ready`, ()=>go('lora')); if(['lora','profile'].includes(S.screen)) refresh(); } }, 300); return; }
  if(a==='lora-use'){ S.lora.use=!S.lora.use; refresh(); return; }
  if(a==='lora-retrain'){ S.lora.state='review'; refresh(); return; }
  if(a.startsWith('acc-on-')){ const k=a.slice(7); el.classList.add('shimmer'); el.textContent='Signing in…'; setTimeout(()=>{ S.acc[k]=k==='youtube'?'Sienna Vale':k==='facebook'?'Sienna Vale (Page)':'@sienna.vale'; snd('done'); toast(pname(k)+' connected'); refresh(); },900); return; }
  if(a.startsWith('acc-off-')){ S.acc[a.slice(8)]=null; S.post.pl=S.post.pl.filter(x=>x!==a.slice(8)); refresh(); return; }
  if(a==='post-open'){ closeMenu(); const j=S.open||S.jobs[0]; S.post={pl:PLATFORMS.map(p=>p[0]).filter(k=>S.acc[k]).slice(0,2),caption:'',ai:false,ad:false,when:'now',slot:'Today · 7:30 PM'}; go('post'); return; }
  if(a.startsWith('pl-')){ const k=a.slice(3), P=S.post; P.pl=P.pl.includes(k)?P.pl.filter(x=>x!==k):[...P.pl,k]; refresh(); return; }
  if(a==='post-ai'){ S.post.ai=!S.post.ai; refresh(); return; } if(a==='post-ad'){ S.post.ad=!S.post.ad; refresh(); return; }
  if(a==='when-now'||a==='when-later'){ S.post.when=a.slice(5); refresh(); return; }
  if(a.startsWith('slot-')){ S.post.slot=a.slice(5); refresh(); return; }
  if(a==='post-none'){ toast('Pick at least one account'); return; }
  if(a==='post-go'){ const P=S.post, j=S.open||S.jobs[0], c=$('#cap'); if(c) P.caption=c.value;
    const p={jid:j.id,img:j.img,title:j.title,pl:[...P.pl],caption:P.caption,ai:P.ai,ad:P.ad,slot:P.slot,state:P.when==='now'?'posted':'scheduled',ago:'just now',views:0,likes:0,comments:0};
    if(p.state==='posted'){ p.views=1240+Math.floor(Math.random()*900); p.likes=Math.floor(p.views*.11); p.comments=Math.floor(p.views*.008); } S.posts.unshift(p); snd('done');
    toast(p.state==='posted'?`Opening ${pname(P.pl[0])} with your post ready…`:`Scheduled for ${P.slot} · we'll remind you`, ()=>{ S.postTab=p.state; go('posts'); }); back(); return; }
  if(a.startsWith('ptab-')){ S.postTab=a.slice(5); refresh(); return; }
  if(a==='export'){ toast('Exported 1080×1920 to your camera roll'); return; }
  return act0(a, el); }; }
{ const ma=menuAction; menuAction=v=>{ if(v==='post-open') return act(v, document.body); return ma(v); }; }
