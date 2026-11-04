/* ---------- Identity LoRA + social accounts (desktop prototype) ----------
   Specs: plans/lora-training.md and plans/socials.md. Loaded after desktop.js. */
const PLATFORMS = [['tiktok','TikTok','#111','TT'],['instagram','Instagram','#D62976','IG'],['facebook','Facebook','#1877F2','f'],['youtube','YouTube','#FF0000','YT'],['x','X','#111','X']];
const pb = (k, s=24) => { const p=PLATFORMS.find(x=>x[0]===k); return `<span class="pbadge" style="width:${s}px;height:${s}px;background:${p[2]};font-size:${Math.round(s*.38)}px">${p[3]}</span>`; };
const pname = k => PLATFORMS.find(x=>x[0]===k)[1];
const LORA = { gen: 0.02, photoMin: 25, videoMin: 75, gpuHr: 3.99 };
const loraCost = () => (LORA.photoMin + LORA.videoMin) / 60 * LORA.gpuHr;
const CAND_POOL = [['g_front','Green set · front'],['g_tq','Green set · ¾'],['face','Close-up · window light'],['c_front','Crystal dress · full'],['g_side','Green set · side'],['profile','Profile · soft light'],['c_tq','Crystal · ¾'],['g_back','Back · physique'],['hero','Portrait · golden hour'],['c_face','Close-up · choker']];
Object.assign(S, { lora: { state:'none', cands:[], p:0, use:true, v:0 }, acc: { tiktok:null, instagram:null, facebook:null, youtube:null, x:null }, posts: [], postTab: 'scheduled' });
const nAcc = () => Object.values(S.acc).filter(Boolean).length;
const loraLine = () => ({ none:'Not trained', gen:'Building training set…', review:'Review the training set', training:`Training · ${Math.round(S.lora.p)}%`, done:`v${S.lora.v} · ${S.lora.use?'in use':'off'}` })[S.lora.state];
NAV.push(['posts','Posts','export','7']);
PARENT.lora='models';

SCREENS.lora = () => { const L=S.lora, ok=L.cands.filter(c=>c.ok).length, cost=loraCost(), low=cost>S.balance;
  let center='', side='';
  const info = `<div class="list">${[['camera','Photo LoRA',`Photoshoots · ~${LORA.photoMin} min · ${money(LORA.photoMin/60*LORA.gpuHr)}`],['studio','Video LoRA',`H3 videos · ~${LORA.videoMin} min · ${money(LORA.videoMin/60*LORA.gpuHr)}`]].map(([i,n,d])=>`<div class="li">${ic(i,18)}<span class="grow"><b>${n}</b><br><span class="tiny muted">${d}</span></span></div>`).join('')}</div>`;
  if(L.state==='none'){ center=`<div class="lgrid">${CAND_POOL.slice(0,6).map(([k])=>`<div class="lt" style="${bg(k)};opacity:.35"></div>`).join('')}</div><div class="note" style="margin-top:16px">${ic('spark',16)}<span>We generate 30 varied shots from her character sheet: new angles, outfits, light and expressions, with full-body shots so her physique is learned too. You keep the ones that look like her.</span></div>`;
    side=`<p class="small">A LoRA is a small add-on trained on one model. It keeps her <b>face and physique</b> the same in every photo and video, beyond what 6 reference shots can hold.</p>${info}`;
    side+=`<div class="btn pri big" data-act="lora-gen">Build training set · ${money(30*LORA.gen)}</div>`; }
  if(L.state==='gen'){ center=`<div class="lgrid">${Array.from({length:18},()=>'<div class="lt shimmer"></div>').join('')}</div>`; side=`<p class="small">Generating 30 shots…</p>${info}<div class="btn pri big off">Generating…</div>`; }
  if(L.state==='review'){ center=`<div class="row-b" style="margin-bottom:12px"><span class="h2">${ok} of 30 kept</span><span class="tiny muted">Click a shot to drop it or bring it back · ${L.cands.filter(c=>c.flag).length} were flagged for you</span></div>
     <div class="lgrid">${L.cands.map((c,i)=>`<div class="lt press${c.ok?'':' out'}" data-act="lora-t-${i}" style="${bg(c.k)}" title="${c.l}">${c.flag?`<span class="lflag">${c.flag}</span>`:''}<span class="lchk">${c.ok?ic('check',13):'✕'}</span></div>`).join('')}</div>`;
    side=`<div class="row-b"><b>${ok} kept</b>${pill(ok>=20?'Enough to train':'Keep at least 20',ok>=20?'good':'warn')}</div><p class="tiny muted">Drop anything that doesn't look like her, or shows a tattoo, ring or choker. The LoRA learns whatever you keep.</p>${info}
     <div class="estbox"><div><span class="lbl">Time</span><b>~1 h 40</b></div><div><span class="lbl">Cost</span><b>${money(cost)}</b></div><div><span class="lbl">After</span><b>${money(Math.max(0,S.balance-cost))}</b></div></div>
     ${ok<20?`<div class="btn pri big off" data-act="lora-few">Keep ${20-ok} more to train</div>`:low?`<div class="note warn tiny">${ic('wallet',16)}<span>Not enough balance. <span class="link" data-go="credits">Top up</span></span></div><div class="btn pri big off">Train both LoRAs · ${money(cost)}</div>`:`<div class="btn pri big" data-act="lora-train">Train both LoRAs · ${money(cost)}</div>`}`; }
  if(L.state==='training'){ center=`<div class="lgrid">${L.cands.filter(c=>c.ok).slice(0,18).map(c=>`<div class="lt" style="${bg(c.k)}"></div>`).join('')}</div>`;
    side=`<b>Training on ${ok} shots</b><p class="tiny muted">You can keep working. We'll notify you when it's done.</p>${[['Photo LoRA',Math.min(100,L.p*4)],['Video LoRA',Math.max(0,(L.p-25)/75*100)]].map(([n,p],i)=>`<div class="fld"><div class="row-b"><span>${n}</span><span class="mono tiny" data-lpt="${i}">${Math.round(p)}%</span></div><div class="prog"><i data-lp="${i}" style="width:${p}%"></i></div></div>`).join('')}<span class="tiny muted mono" id="lora-left">~${Math.max(1,Math.round(100-L.p))} min left · demo runs 120× faster</span>`; }
  if(L.state==='done'){ center=`<div class="row" style="gap:22px;align-items:flex-start"><div class="col" style="width:280px"><div class="ph34 img" style="${bg('c_face')}"></div><span class="tiny muted">References only</span></div><div class="col" style="width:280px"><div class="ph34 img" style="${bg('face')}"></div><span class="tiny"><b>With LoRA v${L.v}</b></span></div></div><p class="tiny muted" style="margin-top:12px">Same prompt and seed. The LoRA keeps her face shape, freckles and build steady across angles.</p>`;
    side=`<div class="list"><div class="li"><span class="grow"><b>Use in new renders</b><br><span class="tiny muted">Photos and videos</span></span><span class="tog${L.use?' on':''}" data-act="lora-use"></span></div><div class="li"><span class="grow">Trained on</span><span class="mono small">${ok} shots · v${L.v}</span></div></div>
     <div class="btn" data-act="lora-retrain">Retrain with more shots</div><div class="btn pri big" data-go="shoot">Test it in a photoshoot</div>`; }
  return `<div class="page split"><div class="center"><div class="row tiny muted" style="margin-bottom:10px"><span class="link" data-go="models">Models</span>›<span class="link" data-go="profile">${MODEL.name}</span>›<span>Identity LoRA</span></div>${PH('Identity LoRA', MODEL.short+(L.state==='done'?' · v'+L.v:''))}${center}</div>
   <aside class="insp"><div class="insp-scroll">${side}</div></aside></div>`; };

SCREENS.posts = () => { const list=S.posts.filter(p=>p.state===S.postTab);
  return `<div class="page">${PH('Social','Posts', `<div class="seg" style="width:320px"><span class="${S.postTab==='scheduled'?'on':''}" data-act="ptab-scheduled">Scheduled · ${S.posts.filter(p=>p.state==='scheduled').length}</span><span class="${S.postTab==='posted'?'on':''}" data-act="ptab-posted">Posted · ${S.posts.filter(p=>p.state==='posted').length}</span></div>`)}
   <div class="gpu" style="grid-template-columns:repeat(5,1fr)">${PLATFORMS.map(([k,n])=>`<div class="card row">${pb(k,30)}<span class="grow"><b class="small">${n}</b><br><span class="tiny muted">${S.acc[k]||'Not connected'}</span></span>${S.acc[k]?'':`<span class="link tiny" data-act="acc-on-${k}">Connect</span>`}</div>`).join('')}</div>
   ${list.length?`<table class="tbl"><thead><tr><th></th><th>Post</th><th>Accounts</th><th>${S.postTab==='scheduled'?'When':'Results'}</th><th>Labels</th></tr></thead><tbody>${list.map(p=>`<tr class="rowh"><td style="width:60px"><div class="th img" style="${bg(p.img)}"></div></td><td><b>${p.title}</b><br><span class="tiny muted">${p.caption||'No caption'}</span></td><td>${p.pl.map(k=>pb(k,20)).join(' ')}</td><td class="mono small">${p.state==='scheduled'?p.slot:`${p.views.toLocaleString()} views · ${p.likes.toLocaleString()} likes · ${p.comments} comments`}</td><td class="tiny muted">${[p.ai?'AI label':'',p.ad?'Paid':''].filter(Boolean).join(' · ')||'—'}</td></tr>`).join('')}</tbody></table>`
   :`<div class="note">${ic('spark',16)}<span>${S.postTab==='scheduled'?'Nothing scheduled. Open a finished take in the Gallery and click Post.':'Nothing posted yet.'}</span></div>`}
   <p class="tiny muted" style="margin-top:16px">For now MUSE opens each app (or its upload page) with your video and caption ready. Direct posting and auto-scheduling switch on per platform once it approves MUSE.</p></div>`; };

/* Profile: LoRA card + accounts */
{ const prof=SCREENS.profile; SCREENS.profile=()=>prof().replace('<div class="sec-h"><span class="h2">Outfits</span>', `<div class="sec-h"><span class="h2">Identity LoRA</span><span class="tiny muted">Locks face and physique across photos and videos</span></div>
  <div class="card row" style="gap:16px"><span class="ico-sq">${ic('spark',20)}</span><span class="grow"><b>${loraLine()}</b><br><span class="tiny muted">${S.lora.state==='done'?'Trained on '+S.lora.cands.filter(c=>c.ok).length+' shots you approved':'Train a photo and a video LoRA from 30 shots you approve · about '+money(30*LORA.gen+loraCost())}</span></span><div class="btn${S.lora.state==='none'?' pri':''}" data-go="lora">${S.lora.state==='none'?'Train LoRA':'Open'}</div></div>
  <div class="sec-h"><span class="h2">Accounts</span><span class="tiny muted">Sienna's own social accounts · ${nAcc()} of 5 connected</span></div>
  <div class="accs">${PLATFORMS.map(([k,n])=>`<div class="card row">${pb(k,30)}<span class="grow"><b class="small">${n}</b><br><span class="tiny muted">${S.acc[k]||'Not connected'}</span></span>${S.acc[k]?`<span class="link tiny" data-act="acc-off-${k}">Disconnect</span>`:`<div class="btn sm" data-act="acc-on-${k}">Connect</div>`}</div>`).join('')}</div>
  <div class="sec-h"><span class="h2">Outfits</span>`); }
/* Result: Post button, no automatic label line */
{ const res=SCREENS.result; SCREENS.result=()=>{ const posted=S.posts.find(p=>p.jid===S.open&&p.state==='posted');
  return res().replace(/<p class="tiny muted">[^]*?Exports carry the AI-generated label\. Brand posts also need #ad\.<\/p>/, `<div class="btn pri" data-act="post-open">${ic('upload',16)}Post to Sienna's accounts</div>${posted?`<div class="card col" style="gap:6px"><span class="lbl">Posted</span><span>${posted.pl.map(k=>pb(k,20)).join(' ')}</span><span class="mono small">${posted.views.toLocaleString()} views · ${posted.likes.toLocaleString()} likes · ${posted.comments} comments</span></div>`:''}`); }; }
/* Prompt engine: identity layer names the LoRA */
{ const sp=shootPrompt; shootPrompt=()=>{ const p=sp(); if(S.lora.state==='done'&&S.lora.use) p.identity=p.identity.replace('Identity from 6 locked reference images.','Identity from 6 locked reference images + LoRA sienna_v'+S.lora.v+' (photo).'); return p; };
  const vp=videoPrompt; videoPrompt=()=>{ let t=vp(); if(S.lora.state==='done'&&S.lora.use) t=t.replace('(reference images 1–6).','(reference images 1–6, LoRA sienna_v'+S.lora.v+' video).'); return t; }; }
MENUS.profile.splice(1,0,['spark','Identity LoRA','go:lora']);
MENUS.result.splice(1,0,['upload','Post…','post-open']);
CMDS.push(['Identity LoRA','go:lora','spark',''],['Posts','go:posts','export','⌘7']);

function postModal(){ closeMenu(); const P={ pl:PLATFORMS.map(p=>p[0]).filter(k=>S.acc[k]).slice(0,2), caption:'', ai:false, ad:false, when:'now', slot:'Today · 7:30 PM' };
  const t=galleryTiles().find(x=>x[2]===S.open)||galleryTiles()[0]; const win=$('.win'); const bgd=document.createElement('div'); bgd.className='modal-bg';
  const draw=()=>{ const ta=bgd.querySelector('#cap'); if(ta) P.caption=ta.value; const conn=PLATFORMS.filter(([k])=>S.acc[k]);
    bgd.innerHTML=`<div class="modal" style="width:820px"><div class="row-b"><div><div class="eyebrow">${MODEL.short}</div><h2 class="h1" style="font-size:${T()==='a'?48:32}px">Post</h2></div><span class="icbtn" data-m="close">✕</span></div>
     <div class="row" style="gap:22px;align-items:flex-start"><div class="ph9 img" style="${bg(t[0])};width:170px;flex:none"></div><div class="col grow" style="gap:16px">
      <div class="fld"><span class="lbl">Post to</span>${conn.length?`<div class="chips">${conn.map(([k,n])=>`<span class="chip${P.pl.includes(k)?' on':''}" data-m="pl-${k}">${pb(k,18)} ${n}</span>`).join('')}</div>`:''}${conn.length<5?`<span class="link tiny" data-m="connect">+ Connect ${conn.length?'more accounts':"Sienna's accounts"}</span>`:''}</div>
      <label class="fld"><span class="lbl">Caption</span><textarea class="inp" id="cap" rows="3" placeholder="Write a caption and hashtags">${P.caption}</textarea></label>
      <div class="list"><div class="li"><span class="grow"><b>Mark as AI-generated</b><br><span class="tiny muted">Turns on the platform's own AI label</span></span><span class="tog${P.ai?' on':''}" data-m="ai"></span></div><div class="li"><span class="grow"><b>Paid partnership</b><br><span class="tiny muted">Turns on the platform's branded-content tag</span></span><span class="tog${P.ad?' on':''}" data-m="ad"></span></div></div>
      <div class="fld"><span class="lbl">When</span><div class="seg" style="width:300px"><span class="${P.when==='now'?'on':''}" data-m="w-now">Now</span><span class="${P.when==='later'?'on':''}" data-m="w-later">Schedule</span></div>
       ${P.when==='later'?`<div class="chips">${['Today · 7:30 PM','Tomorrow · 12:00 PM','Fri · 6:00 PM'].map(x=>`<span class="chip${P.slot===x?' on':''}" data-m="s-${x}">${x}</span>`).join('')}</div><span class="tiny muted">We'll notify you at that time and open each app with the post ready.</span>`:''}</div></div></div>
     <div class="row"><span class="grow"></span><div class="btn" data-m="close">Cancel</div><div class="btn pri${P.pl.length?'':' off'}" data-m="${P.pl.length?'go':'none'}">${P.when==='now'?`Post to ${P.pl.length} account${P.pl.length===1?'':'s'}`:'Schedule · '+P.slot}</div></div></div>`;
    bgd.querySelectorAll('[data-m]').forEach(x=>x.onclick=e=>{ e.stopPropagation(); const m=x.dataset.m; snd('tap'); const ta=bgd.querySelector('#cap'); if(ta) P.caption=ta.value;
      if(m==='close'){ bgd.remove(); return; } if(m==='connect'){ bgd.remove(); go('profile'); return; }
      if(m.startsWith('pl-')){ const k=m.slice(3); P.pl=P.pl.includes(k)?P.pl.filter(y=>y!==k):[...P.pl,k]; return draw(); }
      if(m==='ai'){ P.ai=!P.ai; return draw(); } if(m==='ad'){ P.ad=!P.ad; return draw(); }
      if(m.startsWith('w-')){ P.when=m.slice(2); return draw(); } if(m.startsWith('s-')){ P.slot=m.slice(2); return draw(); }
      if(m==='none'){ toast('Pick at least one account'); return; }
      if(m==='go'){ const p={jid:t[2],img:t[0],title:t[1],pl:[...P.pl],caption:P.caption,ai:P.ai,ad:P.ad,slot:P.slot,state:P.when==='now'?'posted':'scheduled',views:0,likes:0,comments:0};
        if(p.state==='posted'){ p.views=1240+Math.floor(Math.random()*900); p.likes=Math.floor(p.views*.11); p.comments=Math.floor(p.views*.008); }
        S.posts.unshift(p); bgd.remove(); snd('done'); toast(p.state==='posted'?`Opening ${pname(p.pl[0])} with your post ready…`:`Scheduled for ${p.slot}. We'll remind you.`, 'View posts', ()=>{ S.postTab=p.state; go('posts'); }); refresh(); } }); };
  bgd.onclick=e=>{ if(e.target===bgd) bgd.remove(); }; draw(); win.append(bgd); }

let loraIv=null;
{ const act0=act; act=function(a, el){
  if(a==='lora-gen'){ S.balance-=0.6; S.month+=0.6; S.lora.state='gen'; snd('go'); refresh();
    setTimeout(()=>{ S.lora.cands=Array.from({length:30},(_,i)=>{ const [k,l]=CAND_POOL[i%CAND_POOL.length]; const flag=[9,19,23].includes(i)?(k==='c_face'?'choker':i===23?'face drift':'ring'):''; return {k,l,ok:!flag,flag}; }); S.lora.state='review'; snd('done'); if(S.screen==='lora') refresh(); }, 1800); return; }
  if(a.startsWith('lora-t-')){ const c=S.lora.cands[+a.slice(7)]; c.ok=!c.ok; snd('tick'); return refresh(); }
  if(a==='lora-few') return toast('Keep at least 20 shots so the LoRA learns her well');
  if(a==='lora-train'){ const cost=loraCost(); if(cost>S.balance) return toast('Not enough balance'); S.balance-=cost; S.month+=cost; S.today+=cost; S.lora.state='training'; S.lora.p=0; snd('go'); refresh();
    clearInterval(loraIv); const t0=Date.now(); loraIv=setInterval(()=>{ const L=S.lora; L.p=Math.min(100,(Date.now()-t0)/1000*2);
      [Math.min(100,L.p*4),Math.max(0,(L.p-25)/75*100)].forEach((p,i)=>{ const b=document.querySelector(`[data-lp="${i}"]`); if(b) b.style.width=p+'%'; const tx=document.querySelector(`[data-lpt="${i}"]`); if(tx) tx.textContent=Math.round(p)+'%'; });
      const lf=$('#lora-left'); if(lf) lf.textContent=`~${Math.max(1,Math.round(100-L.p))} min left · demo runs 120× faster`;
      if(L.p>=100){ clearInterval(loraIv); L.state='done'; L.v+=1; notifySound(); toast(`Identity LoRA v${L.v} is ready`, 'Open', ()=>go('lora')); if(['lora','profile'].includes(S.screen)) refresh(); } }, 300); return; }
  if(a==='lora-use'){ S.lora.use=!S.lora.use; return refresh(); }
  if(a==='lora-retrain'){ S.lora.state='review'; return refresh(); }
  if(a.startsWith('acc-on-')){ const k=a.slice(7); el.textContent='Signing in…'; setTimeout(()=>{ S.acc[k]=k==='youtube'?'Sienna Vale':k==='facebook'?'Sienna Vale (Page)':'@sienna.vale'; snd('done'); toast(pname(k)+' connected'); refresh(); },900); return; }
  if(a.startsWith('acc-off-')){ S.acc[a.slice(8)]=null; return refresh(); }
  if(a==='post-open') return postModal();
  if(a.startsWith('ptab-')){ S.postTab=a.slice(5); return refresh(); }
  if(a==='export'){ snd('go'); return toast('Exported 1080×1920'); }
  return act0(a, el); }; }
render(0); fit();
