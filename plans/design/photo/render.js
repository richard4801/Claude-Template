// Renders the Photo tab frames: node plans/design/photo/render.js  (PNGs at deviceScaleFactor 2, plus a fit report).
const { chromium } = require('playwright');
const path = require('path'), fs = require('fs');
const dir = __dirname, file = 'file://' + path.join(dir, 'photo.html');
(async () => {
  const b = await chromium.launch();
  const report = [];
  const shot = async (name, w, h, qs, save = true) => {
    const p = await b.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
    await p.goto(file + '?' + qs); await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(150);
    const fit = await p.evaluate(() => {
      const over = [...document.querySelectorAll('.panel, .stage, .bar, .main, .app')].filter(e => e.scrollHeight > e.clientHeight + 1 || e.scrollWidth > e.clientWidth + 1).map(e => e.className);
      return { page: document.documentElement.scrollHeight <= innerHeight && document.documentElement.scrollWidth <= innerWidth, over };
    });
    report.push(`${name} ${w}x${h} ${fit.page && !fit.over.length ? 'FITS' : 'CUT ' + JSON.stringify(fit)}`);
    if (save) await p.screenshot({ path: path.join(dir, name + '.png') });
    await p.close();
  };
  for (const t of ['a', 'b']) for (const s of ['empty', 'filled', 'results']) {
    await shot(`${t}-${s}-1152`, 1152, 720, `theme=${t}&state=${s}`);
    await shot(`${t}-${s}-1440`, 1440, 900, `theme=${t}&state=${s}`, s === 'results');
    await shot(`${t}-${s}-phone`, 390, 844, `theme=${t}&state=${s}&layout=phone`);
  }
  await shot('a-presets-1152', 1152, 720, 'theme=a&state=presets');
  await shot('b-presets-1152', 1152, 720, 'theme=b&state=presets');
  fs.writeFileSync(path.join(dir, 'fit-check.txt'), report.join('\n') + '\n');
  console.log(report.join('\n'));
  await b.close();
})();
