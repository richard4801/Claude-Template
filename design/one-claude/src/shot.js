const { chromium } = require('playwright');
(async () => { const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
for (const f of ['1_edit_panel','2_chat_list','3_memory','4_go_ahead']) { await p.goto('file://' + __dirname + '/' + f + '.html'); await p.waitForTimeout(300); await p.screenshot({ path: __dirname + '/../' + f + '.png' }); }
await b.close(); })();
