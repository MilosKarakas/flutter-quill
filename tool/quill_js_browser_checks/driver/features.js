// Feature checks for image, video, and block-style behaviour in the
// QuillJsEditorView iframe (harness modes full and two).
// Usage: node features.js <baseUrl>   Prints PASS/FAIL per check and exits 1
// on any failure. ONLY=<substring> runs matching checks; CHROME=<path> picks
// the browser.
const { chromium } = require('playwright-core');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [baseUrl] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PNG =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

async function findFrames(page, count) {
  for (let i = 0; i < 200; i++) {
    const found = [];
    for (const f of page.frames()) {
      if (f === page.mainFrame()) continue;
      try {
        if (await f.evaluate(() => !!(window.Quill && document.querySelector('.ql-editor')))) found.push(f);
      } catch (_) {}
    }
    if (found.length >= count) return found;
    await sleep(100);
  }
  throw new Error('editor iframe not found');
}

// Flutter reports exceptions in callbacks to the console, not as page
// errors; a check fails when any appear while it runs.
const flutterExceptions = [];
const quillWarnings = [];

async function open(browser, query, frameCount = 1) {
  const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => {
    const t = m.text();
    if (/EXCEPTION CAUGHT BY|Another exception was thrown/.test(t)) flutterExceptions.push(t.slice(0, 300));
    if (/Overwriting formats\/list/.test(t)) quillWarnings.push(t.slice(0, 200));
  });
  page.on('pageerror', (e) => {
    // An asset download cut off when a check closes its page is not an
    // editor error (seen with the debug dev server).
    if (/failed to complete HTTP request/.test(String(e))) return;
    flutterExceptions.push('pageerror: ' + String(e).slice(0, 300));
  });
  await page.goto(baseUrl + '/' + query);
  const frames = await findFrames(page, frameCount);
  await page.waitForFunction(() => typeof window.hGet === 'function');
  await sleep(300);
  const frame = frames[0];
  const q = (f) => (src, arg) =>
    f.evaluate(
      ([s, a]) => {
        const quill = window.Quill.find(document.querySelector('#editor'));
        return new Function('q', 'a', s)(quill, a);
      },
      [src, arg]
    );
  return {
    page,
    frame,
    frames,
    errors,
    get: async () => JSON.parse(await page.evaluate(() => window.hGet())),
    set: (ops) => page.evaluate((j) => window.hSet(j), JSON.stringify(ops)),
    log: async () => JSON.parse(await page.evaluate(() => window.hLog())),
    block: async () => JSON.parse(await page.evaluate(() => window.hFormat2())),
    call: (name, ...args) =>
      page.evaluate(([n, a]) => window.hCall(n, a), [name, JSON.stringify(args)]),
    nextMedia: (v) => page.evaluate((j) => (window.hNextMedia = j), v == null ? null : JSON.stringify(v)),
    quill: q(frame),
    quillOf: q,
    focusAt: async (index, length = 0, f = frame) => {
      await f.evaluate(
        ([i, l]) => {
          const quill = window.Quill.find(document.querySelector('#editor'));
          quill.focus();
          quill.setSelection(i, l, 'user');
        },
        [index, length]
      );
      await sleep(80);
    },
    pasteFiles: (data, withPng, f = frame) =>
      f.evaluate(
        async ([d, png, add]) => {
          const dt = new DataTransfer();
          if (add) {
            const blob = await (await fetch(png)).blob();
            dt.items.add(new File([blob], 'a.png', { type: 'image/png' }));
          }
          for (const k of Object.keys(d)) dt.setData(k, d[k]);
          const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
          document.querySelector('.ql-editor').dispatchEvent(ev);
        },
        [data, PNG, withPng]
      ),
  };
}

const embeds = (doc, kind) => doc.filter((op) => op.insert && typeof op.insert === 'object' && op.insert[kind]);

// The document as lines: [text, line attributes] (embeds as '<embed>').
function lines(doc) {
  const out = [];
  let text = '';
  for (const op of doc) {
    if (typeof op.insert !== 'string') { text += '<embed>'; continue; }
    const parts = op.insert.split('\n');
    for (let i = 0; i < parts.length; i++) {
      text += parts[i];
      if (i < parts.length - 1) { out.push([text, op.attributes || {}]); text = ''; }
    }
  }
  return out;
}
const B = (extra) => Object.assign({ list: 'bullet' }, extra || {});
// Attribute order inside a line does not matter.
const canon = (ls) => JSON.stringify(ls.map(([t, a]) => [t, Object.keys(a).sort().reduce((o, k) => ((o[k] = a[k]), o), {})]));
const sameLines = (doc, expected) => canon(lines(doc)) === canon(expected);
const LIST3 = [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'two' }, { insert: '\n', attributes: B() }, { insert: 'three' }, { insert: '\n', attributes: B() }];

async function listCase(b, setup, act, expected) {
  const e = await open(b, '?mode=full');
  await e.set(setup);
  await sleep(150);
  await act(e);
  await sleep(350);
  const doc = await e.get();
  return { ok: sameLines(doc, expected), got: lines(doc), expected };
}

const checks = {
  async 'toolbar insert twice adds two images (not edit of the first)'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(11);
    await e.nextMedia({ source: PNG, alt: 'one' });
    await e.call('requestImageEmbed');
    await sleep(300);
    await e.nextMedia({ source: PNG, alt: 'two' });
    await e.call('requestImageEmbed');
    await sleep(300);
    const doc = await e.get();
    const log = (await e.log()).log.map((s) => JSON.parse(s));
    const imgs = embeds(doc, 'image');
    return { ok: imgs.length === 2 && log[1].current === null, imgs: imgs.length, secondCurrent: log[1].current };
  },
  async 'caret at start of the line after an image inserts a new image'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG } }, { insert: 'b\n' }]);
    await sleep(200);
    await e.focusAt(3);
    await e.nextMedia(null);
    await e.call('requestImageEmbed');
    await sleep(200);
    const log = (await e.log()).log.map((s) => JSON.parse(s));
    return { ok: log.length === 1 && log[0].current === null, current: log[0] && log[0].current };
  },
  async 'selected image (clicked) opens edit and SAME source updates alt only'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG }, attributes: { width: '40', height: '40' } }, { insert: 'b\n' }]);
    await sleep(300);
    await e.frame.click('.ql-editor img');
    await sleep(300);
    await e.nextMedia({ source: 'SAME', alt: 'edited', width: 40, height: 40 });
    await e.call('requestImageEmbed');
    await sleep(300);
    const doc = await e.get();
    const log = (await e.log()).log.map((s) => JSON.parse(s));
    const imgs = embeds(doc, 'image');
    return {
      ok: log[0].current !== null && imgs.length === 1 && imgs[0].attributes.alt === 'edited' && imgs[0].insert.image.startsWith('data:image/png'),
      current: log[0].current,
      imgs,
    };
  },
  async 'double-click opens edit for that image'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG }, attributes: { width: '40', height: '40' } }, { insert: 'b\n' }]);
    await sleep(300);
    await e.nextMedia(null);
    await e.frame.dblclick('.ql-editor img');
    await sleep(300);
    const log = (await e.log()).log.map((s) => JSON.parse(s));
    return { ok: log.length === 1 && log[0].current && log[0].current.embedded === true, log };
  },
  async 'image survives after the editor that received it is disposed'(b) {
    const e = await open(b, '?mode=two', 2);
    const [fa, fb] = e.frames;
    await e.focusAt(0, 0, fa);
    await e.pasteFiles({}, true, fa);
    await sleep(1200);
    const docA = await e.get();
    if (embeds(docA, 'image').length !== 1) return { ok: false, reason: 'paste did not insert', docA };
    await e.call('removeFirst');
    await sleep(800);
    await e.page.evaluate((j) => window.hSetB(j), JSON.stringify(docA));
    await sleep(800);
    const info = await fb.evaluate(() => {
      const img = document.querySelector('.ql-editor img');
      if (!img) return null;
      return fetch(img.src).then((r) => r.ok, () => false).then((fetchable) => ({ src: img.src.slice(0, 5), fetchable }));
    });
    const frameCount = e.page.frames().length - 1;
    return { ok: !!info && info.fetchable, info, frameCount };
  },
  async 'loom embed URL is accepted'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(11);
    await e.nextMedia({ source: 'https://www.loom.com/embed/abc123' });
    await e.call('requestVideoEmbed');
    await sleep(300);
    const v = embeds(await e.get(), 'video');
    return { ok: v.length === 1 && v[0].insert.video === 'https://www.loom.com/embed/abc123', v };
  },
  async 'editing alt of an existing loom video applies'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { video: 'https://www.loom.com/embed/abc123' }, attributes: { width: '560', height: '315' } }, { insert: 'b\n' }]);
    await sleep(300);
    await e.focusAt(2);
    await e.nextMedia({ source: 'SAME', alt: 'Demo', width: 560, height: 315 });
    await e.call('requestVideoEmbed');
    await sleep(300);
    const v = embeds(await e.get(), 'video');
    return { ok: v.length === 1 && v[0].attributes.alt === 'Demo', v };
  },
  async 'vimeo unlisted link keeps its hash'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(11);
    await e.nextMedia({ source: 'https://vimeo.com/123456/abcdef1234' });
    await e.call('requestVideoEmbed');
    await sleep(300);
    const v = embeds(await e.get(), 'video');
    return { ok: v.length === 1 && v[0].insert.video === 'https://player.vimeo.com/video/123456?h=abcdef1234', v };
  },
  async 'paste of short Office-style text with a picture keeps the text'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(6);
    await e.pasteFiles({ 'text/plain': 'word', 'text/html': '<html><body><p class=MsoNormal>word</p></body></html>' }, true);
    await sleep(1200);
    const doc = await e.get();
    const text = doc.map((o) => (typeof o.insert === 'string' ? o.insert : '')).join('');
    return { ok: embeds(doc, 'image').length === 0 && text.includes('word'), doc };
  },
  async 'paste of an image file with only a filename inserts the image'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(6);
    await e.pasteFiles({ 'text/plain': 'a.png' }, true);
    await sleep(1200);
    const doc = await e.get();
    return { ok: embeds(doc, 'image').length === 1, doc };
  },
  async 'paste of a copied image (img-only html) inserts the image'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(6);
    await e.pasteFiles({ 'text/html': '<meta charset="utf-8"><img src="https://x.example/a.png">' }, true);
    await sleep(1200);
    const doc = await e.get();
    return { ok: embeds(doc, 'image').length === 1, doc };
  },
  async 'block style: heading + paragraph selection is mixed'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'T' }, { insert: '\n', attributes: { header: 1 } }, { insert: 'p\n' }]);
    await e.focusAt(0, 3);
    await sleep(300);
    return { ok: (await e.block()).mixed === true, state: await e.block() };
  },
  async 'block style: heading + preformatted selection is mixed'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'T' }, { insert: '\n', attributes: { header: 2 } }, { insert: 'c' }, { insert: '\n', attributes: { 'code-block': true } }]);
    await e.focusAt(0, 3);
    await sleep(300);
    return { ok: (await e.block()).mixed === true, state: await e.block() };
  },
  async 'block style: two H2 lines are H2, not mixed'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a' }, { insert: '\n', attributes: { header: 2 } }, { insert: 'b' }, { insert: '\n', attributes: { header: 2 } }]);
    await e.focusAt(0, 3);
    await sleep(300);
    const s = await e.block();
    return { ok: s.mixed === false && s.blockStyle === 'heading2', s };
  },
  async 'block style: paragraphs around an image are paragraph, not mixed'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG } }, { insert: 'b\n' }]);
    await e.focusAt(0, 4);
    await sleep(300);
    const s = await e.block();
    return { ok: s.mixed === false && s.blockStyle === 'paragraph', s };
  },
  async 'block style: collapsed caret on H3 shows H3'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'abc' }, { insert: '\n', attributes: { header: 3 } }]);
    await e.focusAt(1);
    await sleep(300);
    const s = await e.block();
    return { ok: s.mixed === false && s.blockStyle === 'heading3', s };
  },
  async 'applying a heading to several lines keeps the selection'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'one\ntwo\nthree\n' }]);
    await e.focusAt(1, 6);
    await e.call('applyBlockStyle', 'heading2');
    await sleep(400);
    const sel = await e.quill('const r = q.getSelection(); return r && [r.index, r.length];');
    const doc = await e.get();
    const h2 = doc.filter((o) => o.attributes && o.attributes.header === 2).length;
    return { ok: h2 === 2 && sel && sel[0] === 1 && sel[1] === 6, sel, doc };
  },
  async 'applying a heading at a caret keeps the caret'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'one\ntwo\n' }]);
    await e.focusAt(5);
    await e.call('applyBlockStyle', 'heading1');
    await sleep(400);
    const sel = await e.quill('const r = q.getSelection(); return r && [r.index, r.length];');
    return { ok: sel && sel[0] === 5 && sel[1] === 0, sel };
  },
  async 'height-only image renders at that height (read-only)'(b) {
    const e = await open(b, '?mode=full&readOnly=1');
    await e.set([{ insert: { image: PNG }, attributes: { height: '50' } }, { insert: '\n' }]);
    await sleep(500);
    const h = await e.frame.evaluate(() => document.querySelector('.ql-editor img').getBoundingClientRect().height);
    return { ok: Math.round(h) === 50, h };
  },
  async 'same-origin video iframe is fully sandboxed; youtube keeps same-origin'(b) {
    const e = await open(b, '?mode=full');
    const origin = await e.page.evaluate(() => location.origin);
    await e.set([
      { insert: { video: origin + '/evil' }, attributes: { width: '200', height: '100' } },
      { insert: { video: 'https://www.youtube.com/embed/abc' }, attributes: { width: '200', height: '100' } },
      { insert: '\n' },
    ]);
    await sleep(300);
    const s = await e.frame.evaluate(() => [...document.querySelectorAll('.ql-editor iframe')].map((f) => f.getAttribute('sandbox')));
    return { ok: !s[0].includes('allow-same-origin') && s[1].includes('allow-same-origin'), s };
  },
  async 'corner resize writes exactly the previewed size, one change'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG }, attributes: { width: '200', height: '100' } }, { insert: 'b\n' }]);
    await sleep(300);
    await e.frame.click('.ql-editor img');
    await sleep(300);
    const box = await e.frame.evaluate(() => {
      const h = document.querySelector('.inline-media-resize-handle[data-corner="se"]').getBoundingClientRect();
      return { x: h.left + h.width / 2, y: h.top + h.height / 2 };
    });
    const off = await e.frame.evaluate(() => {
      const r = window.frameElement.getBoundingClientRect();
      return { x: r.left, y: r.top };
    });
    const before = (await e.log()).changes;
    await e.page.mouse.move(off.x + box.x, off.y + box.y);
    await e.page.mouse.down();
    await e.page.mouse.move(off.x + box.x + 37, off.y + box.y + 5, { steps: 5 });
    await sleep(100);
    const preview = await e.frame.evaluate(() => {
      const i = document.querySelector('.ql-editor img');
      return [i.getAttribute('width'), i.getAttribute('height')];
    });
    await e.page.mouse.up();
    await sleep(300);
    const img = embeds(await e.get(), 'image')[0];
    const after = (await e.log()).changes;
    return {
      ok: img.attributes.width === preview[0] && img.attributes.height === preview[1] && after - before === 1,
      preview,
      stored: [img.attributes.width, img.attributes.height],
      changes: after - before,
    };
  },
  async 'Backspace removes a selected image; Enter continues below'(b) {
    const e = await open(b, '?mode=full');
    const big = { width: '80', height: '80' };
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG }, attributes: big }, { insert: { image: PNG }, attributes: big }, { insert: 'b\n' }]);
    await sleep(300);
    await e.frame.click('.ql-editor img');
    await sleep(300);
    await e.page.keyboard.press('Backspace');
    await sleep(200);
    const afterDelete = embeds(await e.get(), 'image').length;
    await e.frame.click('.ql-editor img');
    await sleep(300);
    await e.page.keyboard.press('Enter');
    await e.page.keyboard.type('x');
    await sleep(200);
    const doc = await e.get();
    return { ok: afterDelete === 1 && JSON.stringify(doc).includes('"x\\nb\\n"'), afterDelete, doc };
  },
  async 'dropping an image file inserts it at the drop point'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(0);
    await e.frame.evaluate(async (png) => {
      const blob = await (await fetch(png)).blob();
      const dt = new DataTransfer();
      dt.items.add(new File([blob], 'a.png', { type: 'image/png' }));
      const root = document.querySelector('.ql-editor');
      const r = root.getBoundingClientRect();
      for (const type of ['dragenter', 'dragover', 'drop']) {
        root.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true, clientX: r.left + 20, clientY: r.top + 12 }));
      }
    }, PNG);
    await sleep(1200);
    const doc = await e.get();
    const imgs = embeds(doc, 'image');
    return { ok: imgs.length === 1 && imgs[0].insert.image.startsWith('data:image/png'), doc };
  },
  async 'copy of an image writes a data URL to the clipboard html'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'a\n' }, { insert: { image: PNG } }, { insert: 'b\n' }]);
    await sleep(300);
    await e.focusAt(0, 4);
    const html = await e.frame.evaluate(() => {
      const dt = new DataTransfer();
      document.querySelector('.ql-editor').dispatchEvent(new ClipboardEvent('copy', { clipboardData: dt, bubbles: true, cancelable: true }));
      return dt.getData('text/html');
    });
    return { ok: html.includes('data:image/png') && !html.includes('blob:'), html: html.slice(0, 200) };
  },
  async 'heading menu applies H1 then Paragraph clears it'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(2);
    await e.call('applyBlockStyle', 'heading1');
    await sleep(200);
    const h = await e.get();
    await e.call('applyBlockStyle', 'preformatted');
    await sleep(200);
    const pre = await e.get();
    await e.call('applyBlockStyle', 'paragraph');
    await sleep(200);
    const p = await e.get();
    return {
      ok: JSON.stringify(h).includes('"header":1') && JSON.stringify(pre).includes('"code-block":true') && JSON.stringify(p) === JSON.stringify([{ insert: 'Hello world\n' }]),
      h, pre, p,
    };
  },
  async 'two dropped images keep their order and both follow the caret'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(5);
    await e.frame.evaluate(async () => {
      async function png(w, h, color) {
        const c = new OffscreenCanvas(w, h);
        const ctx = c.getContext('2d');
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, w, h);
        return new File([await c.convertToBlob({ type: 'image/png' })], w + '.png', { type: 'image/png' });
      }
      const dt = new DataTransfer();
      dt.items.add(await png(30, 10, 'red'));
      dt.items.add(await png(20, 10, 'blue'));
      const root = document.querySelector('.ql-editor');
      const r = root.getBoundingClientRect();
      for (const type of ['dragenter', 'dragover', 'drop']) {
        root.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true, clientX: r.left + 40, clientY: r.top + 12 }));
      }
    });
    await sleep(1500);
    const imgs = embeds(await e.get(), 'image').map((o) => o.attributes.width);
    return { ok: JSON.stringify(imgs) === JSON.stringify(['30', '20']), imgs };
  },
  async 'one undo removes an inserted image'(b) {
    const e = await open(b, '?mode=full');
    await sleep(1200);
    await e.focusAt(5);
    await e.nextMedia({ source: PNG, alt: 'x', width: 40, height: 40 });
    await e.call('requestImageEmbed');
    await sleep(1200);
    const withImg = embeds(await e.get(), 'image').length;
    await e.focusAt(0);
    await e.page.keyboard.press('Meta+z');
    await sleep(300);
    const doc = await e.get();
    return { ok: withImg === 1 && embeds(doc, 'image').length === 0 && JSON.stringify(doc) === JSON.stringify([{ insert: 'Hello world\n' }]), withImg, doc };
  },
  async 'Preformatted loaded as "plain" is reported as true'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'x' }, { insert: '\n', attributes: { 'code-block': 'plain' } }]);
    await sleep(200);
    const doc = await e.get();
    return { ok: JSON.stringify(doc).includes('"code-block":true'), doc };
  },

  async 'reapplying Preformatted to a code line adds no data-language="true"'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'c' }, { insert: '\n', attributes: { 'code-block': true } }, { insert: 'p\n' }]);
    await e.focusAt(0, 3);
    await e.call('applyBlockStyle', 'preformatted');
    await sleep(300);
    const attrs = await e.frame.evaluate(() => [...document.querySelectorAll('.ql-code-block')].map((n) => n.getAttribute('data-language')));
    const doc = await e.get();
    const code = doc.filter((o) => o.attributes && o.attributes['code-block'] === true).length;
    return { ok: code === 2 && !attrs.includes('true'), attrs, doc };
  },
  async 'block style label after select-all over many uniform lines'(b) {
    const e = await open(b, '?mode=full');
    const ops = [];
    for (let i = 0; i < 400; i++) ops.push({ insert: 'line ' + i }, { insert: '\n', attributes: { header: 2 } });
    await e.set(ops);
    await e.focusAt(0, 400 * 8);
    await sleep(400);
    const s = await e.block();
    return { ok: s.blockStyle === 'heading2' && s.mixed === false, s };
  },

  async 'a video inserted mid-line keeps its alt and 560 by 315'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(5);
    await e.nextMedia({ source: 'https://www.youtube.com/embed/x', alt: 'Demo' });
    await e.call('requestVideoEmbed');
    await sleep(400);
    const doc = await e.get();
    const v = embeds(doc, 'video');
    const ok = v.length === 1 && v[0].attributes && v[0].attributes.alt === 'Demo' &&
      v[0].attributes.width === '560' && v[0].attributes.height === '315' &&
      JSON.stringify(doc[0]) === JSON.stringify({ insert: 'Hello\n' });
    return { ok, doc };
  },
  async 'an image inserted mid-line in a heading keeps alt and size, and the heading'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'Hello world' }, { insert: '\n', attributes: { header: 1 } }]);
    await e.focusAt(5);
    await e.nextMedia({ source: PNG, alt: 'Pic', width: 80, height: 40 });
    await e.call('requestImageEmbed');
    await sleep(400);
    const doc = await e.get();
    const img = embeds(doc, 'image')[0];
    const heads = doc.filter((o) => o.attributes && o.attributes.header === 1).length;
    const caret = await e.quill('const r = q.getSelection(); return r && r.index;');
    return {
      ok: !!img && img.attributes.alt === 'Pic' && img.attributes.width === '80' && heads === 2 && caret === 7,
      doc, caret,
    };
  },
  async 'a mid-line drop reports the sized image in that same change'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(5);
    const before = (await e.log()).changes;
    await e.frame.evaluate(async () => {
      const c = new OffscreenCanvas(30, 10);
      c.getContext('2d').fillRect(0, 0, 30, 10);
      const dt = new DataTransfer();
      dt.items.add(new File([await c.convertToBlob({ type: 'image/png' })], 'a.png', { type: 'image/png' }));
      const root = document.querySelector('.ql-editor');
      const r = root.getBoundingClientRect();
      for (const type of ['dragenter', 'dragover', 'drop']) {
        root.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true, clientX: r.left + 40, clientY: r.top + 12 }));
      }
    });
    await sleep(1200);
    const log = await e.log();
    const first = JSON.parse(log.lastChange);
    const img = embeds(first, 'image')[0];
    return { ok: log.changes - before === 1 && !!img && img.attributes && img.attributes.width === '30', changes: log.changes - before, first };
  },
  async 'pasting an image file over selected text replaces the text'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(0, 5);
    await e.pasteFiles({}, true);
    await sleep(1200);
    const doc = await e.get();
    const text = doc.map((o) => (typeof o.insert === 'string' ? o.insert : '')).join('');
    return { ok: embeds(doc, 'image').length === 1 && !text.includes('Hello') && text.includes('world'), doc };
  },
  async 'relative and protocol-relative same-origin videos get the strict sandbox'(b) {
    const e = await open(b, '?mode=full');
    const host = await e.page.evaluate(() => location.host);
    await e.set([
      { insert: { video: '/media/clip.html' }, attributes: { width: '200', height: '100' } },
      { insert: { video: '//' + host + '/x' }, attributes: { width: '200', height: '100' } },
      { insert: { video: '//www.youtube.com/embed/abc' }, attributes: { width: '200', height: '100' } },
      { insert: '\n' },
    ]);
    await sleep(300);
    const s = await e.frame.evaluate(() => [...document.querySelectorAll('.ql-editor iframe')].map((f) => f.getAttribute('sandbox')));
    return { ok: !s[0].includes('allow-same-origin') && !s[1].includes('allow-same-origin') && s[2].includes('allow-same-origin'), s };
  },
  async 'the size fill for an unsized image adds no undo step'(b) {
    const e = await open(b, '?mode=full');
    await e.focusAt(11);
    await e.page.keyboard.type(' typed');
    await sleep(1300);
    // Insert an unsized image outside the history, like a loaded document.
    const before = await e.quill(
      'q.history.ignoreChange = true; q.updateContents({ ops: [{ retain: 0 }, { insert: { image: a } }] }, "api"); q.history.ignoreChange = false; return JSON.stringify(q.history.stack.undo);',
      PNG
    );
    await sleep(800);
    const after = await e.quill('return JSON.stringify(q.history.stack.undo);');
    const img = embeds(await e.get(), 'image')[0];
    return { ok: before === after && !!img && img.attributes && img.attributes.width === '1', sized: img && img.attributes };
  },

  // List items that are also headings or Preformatted, matched against
  // TinyMCE 6.8.4 with the Angular support-article configuration.
  async 'list: caret in item -> Heading 1 keeps the bullet'(b) {
    return listCase(b, LIST3, async (e) => { await e.focusAt(5); await e.call('applyBlockStyle', 'heading1'); },
      [['one', B()], ['two', B({ 'list-block': 'h1' })], ['three', B()]]);
  },
  async 'list: caret in item -> Preformatted keeps the bullet'(b) {
    return listCase(b, LIST3, async (e) => { await e.focusAt(5); await e.call('applyBlockStyle', 'preformatted'); },
      [['one', B()], ['two', B({ 'list-block': 'pre' })], ['three', B()]]);
  },
  async 'list: two items selected -> Heading 2'(b) {
    return listCase(b, LIST3, async (e) => { await e.focusAt(1, 4); await e.call('applyBlockStyle', 'heading2'); },
      [['one', B({ 'list-block': 'h2' })], ['two', B({ 'list-block': 'h2' })], ['three', B()]]);
  },
  async 'list: item + paragraph after -> Heading 2 on both kinds'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'para\n' }],
      async (e) => { await e.focusAt(1, 5); await e.call('applyBlockStyle', 'heading2'); },
      [['one', B({ 'list-block': 'h2' })], ['para', { header: 2 }]]);
  },
  async 'list: paragraph + item -> Heading 2 on both kinds'(b) {
    return listCase(b, [{ insert: 'para\n' }, { insert: 'one' }, { insert: '\n', attributes: B() }],
      async (e) => { await e.focusAt(1, 5); await e.call('applyBlockStyle', 'heading2'); },
      [['para', { header: 2 }], ['one', B({ 'list-block': 'h2' })]]);
  },
  async 'list: heading item -> Paragraph keeps a plain item'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h1' }) }],
      async (e) => { await e.focusAt(5); await e.call('applyBlockStyle', 'paragraph'); },
      [['one', B()], ['two', B()]]);
  },
  async 'list: heading item -> Heading 3 and -> Preformatted'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h1' }) }]);
    await e.focusAt(1);
    await e.call('applyBlockStyle', 'heading3');
    await sleep(250);
    const h3 = lines(await e.get());
    await e.call('applyBlockStyle', 'preformatted');
    await sleep(250);
    const pre = lines(await e.get());
    return { ok: canon(h3) === canon([['two', B({ 'list-block': 'h3' })]]) && canon(pre) === canon([['two', B({ 'list-block': 'pre' })]]), h3, pre };
  },
  async 'list: numbered item -> Heading 3 stays numbered'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: { list: 'ordered' } }, { insert: 'two' }, { insert: '\n', attributes: { list: 'ordered' } }],
      async (e) => { await e.focusAt(1); await e.call('applyBlockStyle', 'heading3'); },
      [['one', { list: 'ordered', 'list-block': 'h3' }], ['two', { list: 'ordered' }]]);
  },
  async 'list: nested item -> Heading 2 keeps its level'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'nest' }, { insert: '\n', attributes: B({ indent: 1 }) }],
      async (e) => { await e.focusAt(5); await e.call('applyBlockStyle', 'heading2'); },
      [['one', B()], ['nest', B({ indent: 1, 'list-block': 'h2' })]]);
  },
  async 'list: menu label shows the heading of a heading item'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }]);
    await e.focusAt(1);
    await sleep(300);
    const caret = await e.block();
    await e.focusAt(0, 2);
    await sleep(300);
    const range = await e.block();
    return { ok: caret.blockStyle === 'heading2' && !caret.mixed && range.blockStyle === 'heading2' && !range.mixed, caret, range };
  },
  async 'list: bullet button on a heading line drops the heading'(b) {
    return listCase(b, [{ insert: 'title' }, { insert: '\n', attributes: { header: 2 } }],
      async (e) => { await e.focusAt(1); await e.call('toggleBulletList'); },
      [['title', B()]]);
  },
  async 'list: bullet button off a heading item leaves a heading'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'three' }, { insert: '\n', attributes: B() }],
      async (e) => { await e.focusAt(5); await e.call('toggleBulletList'); },
      [['one', B()], ['two', { header: 2 }], ['three', B()]]);
  },
  async 'list: bullet button off a Preformatted item leaves a code line'(b) {
    return listCase(b, [{ insert: 'code' }, { insert: '\n', attributes: B({ 'list-block': 'pre' }) }],
      async (e) => { await e.focusAt(1); await e.call('toggleBulletList'); },
      [['code', { 'code-block': true }]]);
  },
  async 'list: numbered button on a heading bullet item keeps the heading'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(1); await e.call('toggleOrderedList'); },
      [['two', { list: 'ordered', 'list-block': 'h2' }]]);
  },
  async 'list: Enter at the end of a heading item starts a plain item'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Enter'); await e.page.keyboard.type('x'); },
      [['two', B({ 'list-block': 'h2' })], ['x', B()]]);
  },
  async 'list: Enter in the middle of a heading item keeps it on both halves'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(2); await e.page.keyboard.press('Enter'); },
      [['tw', B({ 'list-block': 'h2' })], ['o', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Enter at the start of a heading item leaves a plain item above'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(0); await e.page.keyboard.press('Enter'); },
      [['', B()], ['two', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Enter twice at the end of a heading item leaves the list'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Enter'); await sleep(100); await e.page.keyboard.press('Enter'); },
      [['two', B({ 'list-block': 'h2' })], ['', {}]]);
  },
  async 'list: Enter at the end of a Preformatted item continues Preformatted'(b) {
    return listCase(b, [{ insert: 'code' }, { insert: '\n', attributes: B({ 'list-block': 'pre' }) }],
      async (e) => { await e.focusAt(4); await e.page.keyboard.press('Enter'); await e.page.keyboard.type('x'); },
      [['code', B({ 'list-block': 'pre' })], ['x', B({ 'list-block': 'pre' })]]);
  },
  async 'list: Enter at the end of a plain item after a heading item stays plain'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two' }, { insert: '\n', attributes: B() }],
      async (e) => { await e.focusAt(7); await e.page.keyboard.press('Enter'); await e.page.keyboard.type('x'); },
      [['one', B({ 'list-block': 'h2' })], ['two', B()], ['x', B()]]);
  },
  async 'list: Backspace at the start of the first heading item leaves a heading'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two' }, { insert: '\n', attributes: B() }],
      async (e) => { await e.focusAt(0); await e.page.keyboard.press('Backspace'); },
      [['one', { header: 2 }], ['two', B()]]);
  },
  async 'list: Delete at the end of a heading item keeps the heading'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two' }, { insert: '\n', attributes: B() }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Delete'); },
      [['onetwo', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Tab and Shift+Tab keep the heading'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }]);
    // Quill nests from the start of the line; inside the text, Tab types a
    // tab character in any list item (as before this work).
    await e.focusAt(4);
    await e.page.keyboard.press('Tab');
    await sleep(250);
    const tab = lines(await e.get());
    await e.focusAt(4);
    await e.page.keyboard.press('Shift+Tab');
    await sleep(250);
    const back = lines(await e.get());
    return {
      ok: canon(tab) === canon([['one', B()], ['two', B({ indent: 1, 'list-block': 'h2' })]]) &&
        canon(back) === canon([['one', B()], ['two', B({ 'list-block': 'h2' })]]),
      tab, back,
    };
  },
  async 'list: pasted <li><h2> and <li><pre> HTML keeps both'(b) {
    const e = await open(b, '?mode=full');
    const r = await e.quill(
      'return [q.clipboard.convert({ html: "<ul><li>one</li><li><h2>two</h2></li></ul>" }).ops, q.clipboard.convert({ html: "<ol><li><pre>code</pre></li></ol>" }).ops];'
    );
    const a = lines(r[0]);
    const c = lines(r[1]);
    return {
      ok: canon(a) === canon([['one', B()], ['two', B({ 'list-block': 'h2' })]]) &&
        canon(c) === canon([['code', { list: 'ordered', 'list-block': 'pre' }]]),
      a, c,
    };
  },
  async 'list: a list-block value on a non-list line is ignored'(b) {
    return listCase(b, [{ insert: 'para' }, { insert: '\n', attributes: { 'list-block': 'h2' } }],
      async () => {}, [['para', {}]]);
  },
  async 'list: styling several lines is one undo step'(b) {
    const e = await open(b, '?mode=full');
    await e.set(LIST3);
    await sleep(1200);
    await e.focusAt(1, 8);
    await e.call('applyBlockStyle', 'heading2');
    await sleep(300);
    await e.quill('q.history.undo();');
    await sleep(300);
    const doc = await e.get();
    return { ok: sameLines(doc, [['one', B()], ['two', B()], ['three', B()]]), got: lines(doc) };
  },
  async 'list: styled items line up with plain items like TinyMCE'(b) {
    const e = await open(b, '?mode=full');
    const ops = [];
    const add = (text, attrs) => ops.push({ insert: text }, { insert: '\n', attributes: attrs });
    add('plain', B());
    for (const v of ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre']) add(v + ' item', B({ 'list-block': v }));
    add('nested plain', B({ indent: 1 }));
    add('nested h2', B({ indent: 1, 'list-block': 'h2' }));
    add('one', { list: 'ordered' });
    add('ordered h1', { list: 'ordered', 'list-block': 'h1' });
    add('ordered pre', { list: 'ordered', 'list-block': 'pre' });
    await e.set(ops);
    await sleep(400);
    const m = await e.frame.evaluate(() => {
      const probe = () => {
        const p = document.createElement('span');
        p.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
        return p;
      };
      return [...document.querySelectorAll('.ql-editor li')].map((li) => {
        const ui = li.querySelector('.ql-ui');
        const text = [...li.childNodes].find((n) => n.nodeType === 3);
        const range = document.createRange();
        range.selectNodeContents(text);
        const textLeft = range.getClientRects()[0].left;
        const a = probe();
        const t = probe();
        ui.appendChild(a);
        li.insertBefore(t, text);
        const markerBaseline = a.getBoundingClientRect().top;
        const textBaseline = t.getBoundingClientRect().top;
        a.remove();
        t.remove();
        const cs = getComputedStyle(ui);
        const before = getComputedStyle(ui, '::before');
        return {
          text: text.data, block: li.getAttribute('data-list-block'), indent: li.className,
          textLeft: Math.round(textLeft), baselineGap: Math.round(markerBaseline - textBaseline),
          markerSize: before.fontSize, markerFamily: cs.fontFamily, markerWeight: before.fontWeight,
          liSize: getComputedStyle(li).fontSize,
        };
      });
    });
    const plain = m[0];
    const nestedPlain = m.find((x) => x.text === 'nested plain');
    const problems = [];
    for (const x of m) {
      const ref = x.indent.includes('ql-indent-1') ? nestedPlain : plain;
      if (Math.abs(x.textLeft - ref.textLeft) > 1) problems.push(x.text + ': text starts at ' + x.textLeft + ', plain at ' + ref.textLeft);
      if (Math.abs(x.baselineGap) > 1) problems.push(x.text + ': marker baseline off by ' + x.baselineGap);
      if (Math.abs(parseFloat(x.markerSize) - parseFloat(plain.markerSize)) > 0.05) problems.push(x.text + ': marker ' + x.markerSize + ' vs ' + plain.markerSize);
      if (x.markerFamily !== plain.markerFamily) problems.push(x.text + ': marker font ' + x.markerFamily);
      if (x.markerWeight !== plain.markerWeight) problems.push(x.text + ': marker weight ' + x.markerWeight);
    }
    const h2 = m.find((x) => x.text === 'h2 item');
    if (h2.liSize !== '24px' && parseFloat(h2.liSize) !== parseFloat(plain.liSize) * 1.5) problems.push('h2 size ' + h2.liSize);
    if (process.env.SHOT) await e.frame.locator('.ql-editor').screenshot({ path: process.env.SHOT });
    return { ok: problems.length === 0, problems };
  },

  async 'list: Backspace at the start of a later heading item removes its bullet'(b) {
    // TinyMCE merges the item into the one above. This editor removes the
    // bullet instead, for every list item (unchanged from before this work),
    // so a heading item becomes a heading line.
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(4); await e.page.keyboard.press('Backspace'); },
      [['one', B()], ['two', { header: 2 }]]);
  },

  async 'bold/italic text in headings keeps the heading size (sized marks)'(b) {
    const e = await open(b, '?mode=full&styles=superuser');
    const biu = { bold: true, italic: true, underline: true };
    await e.set([
      { insert: 'plain heading' }, { insert: '\n', attributes: { header: 1 } },
      { insert: 'marked heading', attributes: biu }, { insert: '\n', attributes: { header: 1 } },
      { insert: 'plain item' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) },
      { insert: 'marked item', attributes: biu }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) },
      { insert: 'body' }, { insert: '\n' },
      { insert: 'marked body', attributes: biu }, { insert: '\n' },
    ]);
    await sleep(400);
    const m = await e.frame.evaluate(() => [...document.querySelectorAll('.ql-editor > *')].map((line) => {
      const mark = line.querySelector('strong, em');
      return {
        text: line.textContent,
        height: Math.round(line.getBoundingClientRect().height),
        lineSize: getComputedStyle(line).fontSize,
        markSize: mark ? getComputedStyle(mark.querySelector('em, u') || mark).fontSize : null,
      };
    }));
    // ol wraps both items; measure items instead.
    const items = await e.frame.evaluate(() => [...document.querySelectorAll('.ql-editor li')].map((li) => {
      const mark = li.querySelector('strong, em');
      return {
        text: li.textContent, height: Math.round(li.getBoundingClientRect().height),
        lineSize: getComputedStyle(li).fontSize,
        markSize: mark ? getComputedStyle(mark.querySelector('em, u') || mark).fontSize : null,
      };
    }));
    const heads = m.filter((x) => x.text.endsWith('heading'));
    const bodies = m.filter((x) => x.text.includes('body'));
    const problems = [];
    for (const group of [heads, items, bodies]) {
      const [plain, marked] = group;
      if (marked.markSize !== marked.lineSize) problems.push(marked.text + ': mark ' + marked.markSize + ' in ' + marked.lineSize);
      if (Math.abs(marked.height - plain.height) > 1) problems.push(marked.text + ': height ' + marked.height + ' vs ' + plain.height);
    }
    // Body text keeps the configured 16px for marks.
    if (bodies[1].markSize !== '16px') problems.push('body mark ' + bodies[1].markSize);
    return { ok: problems.length === 0, problems };
  },

  async 'list: list-block before list in a delta still loads the style'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: { 'list-block': 'h2', list: 'bullet' } }, { insert: 'two' }, { insert: '\n', attributes: { 'list-block': 'pre', list: 'ordered' } }],
      async () => {}, [['one', B({ 'list-block': 'h2' })], ['two', { list: 'ordered', 'list-block': 'pre' }]]);
  },
  async 'list: Backspace at the start of a paragraph below a heading item keeps the heading'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two\n' }],
      async (e) => { await e.focusAt(4); await e.page.keyboard.press('Backspace'); },
      [['onetwo', B({ 'list-block': 'h2' })]]);
  },
  async 'list: deleting a selection from a heading item into a paragraph keeps the heading'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two\n' }],
      async (e) => { await e.focusAt(1, 5); await e.page.keyboard.press('Backspace'); },
      [['oo', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Delete at the end of a heading item keeps it when a paragraph follows'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two\n' }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Delete'); },
      [['onetwo', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Delete at the end of a heading item keeps it when a heading follows'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }, { insert: 'two' }, { insert: '\n', attributes: { header: 1 } }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Delete'); },
      [['onetwo', B({ 'list-block': 'h2' })]]);
  },
  async 'list: Shift+Enter at the end of a heading item starts a plain item'(b) {
    return listCase(b, [{ insert: 'two' }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(3); await e.page.keyboard.press('Shift+Enter'); await e.page.keyboard.type('x'); },
      [['two', B({ 'list-block': 'h2' })], ['x', B()]]);
  },
  async 'Shift+Enter at the end of a heading starts a paragraph, as Enter does'(b) {
    return listCase(b, [{ insert: 'title' }, { insert: '\n', attributes: { header: 2 } }],
      async (e) => { await e.focusAt(5); await e.page.keyboard.press('Shift+Enter'); await e.page.keyboard.type('x'); },
      [['title', { header: 2 }], ['x', {}]]);
  },
  async 'list: Enter on an empty heading item leaves the list as a paragraph'(b) {
    return listCase(b, [{ insert: 'one' }, { insert: '\n', attributes: B() }, { insert: '\n', attributes: B({ 'list-block': 'h2' }) }],
      async (e) => { await e.focusAt(4); await e.page.keyboard.press('Enter'); },
      [['one', B()], ['', {}]]);
  },
  async 'an SVG data URL loaded with the document stays blocked'(b) {
    const e = await open(b, '?mode=full');
    const svg = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPg==';
    await e.set([{ insert: { image: svg } }, { insert: '\n' }]);
    await sleep(300);
    const img = await e.frame.evaluate(() => { const i = document.querySelector('.ql-editor img'); return { src: i.getAttribute('src'), dataSrc: i.getAttribute('data-src') }; });
    const kept = embeds(await e.get(), 'image')[0];
    return { ok: !img.src.startsWith('blob:') && img.dataSrc === svg && kept.insert.image === svg, img };
  },
  async 'a pasted image with a foreign blob: URL is dropped; a known one is kept'(b) {
    const e = await open(b, '?mode=full');
    await e.set([{ insert: { image: PNG } }, { insert: '\n' }]);
    await sleep(300);
    const r = await e.quill(
      'const own = document.querySelector(".ql-editor img").getAttribute("src");' +
      'const foreign = q.clipboard.convert({ html: "<p>a</p><img src=\\"blob:https://other.example/123\\">" }).ops;' +
      'const known = q.clipboard.convert({ html: "<img src=\\"" + own + "\\">" }).ops;' +
      'return [own.slice(0, 5), foreign, known.map((o) => typeof o.insert === "object" ? "image" : o.insert)];'
    );
    const foreignImages = r[1].filter((o) => typeof o.insert === 'object').length;
    return { ok: r[0] === 'blob:' && foreignImages === 0 && r[2].includes('image'), r };
  },
  async 'the list format registers without Quill overwrite warnings'(b) {
    const before = quillWarnings.length;
    const e = await open(b, '?mode=full');
    await sleep(300);
    return { ok: quillWarnings.length === before, warnings: quillWarnings.slice(before) };
  },

};

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, headless: true });
  const only = process.env.ONLY;
  let failed = 0;
  for (const [name, fn] of Object.entries(checks)) {
    if (only && !name.includes(only)) continue;
    let r;
    const seen = flutterExceptions.length;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        r = await fn(browser);
      } catch (err) {
        r = { ok: false, error: String(err).split('\n')[0] };
      }
      // Chrome occasionally drops a page, or aborts the app's own download,
      // in a long debug-build run; that is the browser and the dev server,
      // not the editor, so the check runs once more.
      if (!(r.error && /has been closed|editor iframe not found/.test(r.error))) break;
      flutterExceptions.length = seen;
    }
    if (flutterExceptions.length > seen) {
      r = { ...r, ok: false, exceptions: flutterExceptions.slice(seen, seen + 3) };
    }
    if (!r.ok) failed++;
    console.log((r.ok ? 'PASS ' : 'FAIL ') + name + (r.ok ? '' : '  ' + JSON.stringify(r).slice(0, 400)));
  }
  for (const p of browser.contexts()) await p.close();
  await browser.close();
  console.log(failed ? failed + ' FAILED' : 'ALL PASSED');
  process.exit(failed ? 1 : 0);
})();
