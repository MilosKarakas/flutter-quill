// Drives the default (regular usage) editor and records observable results.
// Usage: node regression.js <baseUrl> <out.json>
const { chromium } = require('playwright-core');
const fs = require('fs');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [baseUrl, outFile] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PNG =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

async function open(browser, query = '') {
  const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(baseUrl + '/' + query);
  let frame = null;
  for (let i = 0; i < 200 && !frame; i++) {
    for (const f of page.frames()) {
      if (f === page.mainFrame()) continue;
      try {
        if (await f.evaluate(() => !!(window.Quill && document.querySelector('.ql-editor')))) frame = f;
      } catch (_) {}
    }
    if (!frame) await sleep(100);
  }
  if (!frame) throw new Error('editor iframe not found');
  await page.waitForFunction(() => typeof window.hGet === 'function');
  await sleep(Number(process.env.SETTLE || 300));
  const api = {
    page,
    frame,
    errors,
    get: async () => JSON.parse(await page.evaluate(() => window.hGet())),
    set: (ops) => page.evaluate((j) => window.hSet(j), JSON.stringify(ops)),
    log: async () => JSON.parse(await page.evaluate(() => window.hLog())),
    format: async () => JSON.parse(await page.evaluate(() => window.hFormat())),
    call: (name, ...args) =>
      page.evaluate(([n, a]) => window.hCall(n, a), [name, JSON.stringify(args)]),
    quill: (fnSrc, arg) =>
      frame.evaluate(
        ([src, a]) => {
          const q = window.Quill.find(document.querySelector('#editor'));
          return new Function('q', 'a', src)(q, a);
        },
        [fnSrc, arg]
      ),
    focusAt: async (index, length = 0) => {
      await frame.click('.ql-editor');
      // Let the editor finish its click-to-focus handling first.
      await sleep(400);
      await frame.evaluate(
        ([i, l]) => {
          const q = window.Quill.find(document.querySelector('#editor'));
          q.focus();
          q.setSelection(i, l, 'user');
        },
        [index, length]
      );
      await sleep(50);
    },
    paste: (data) =>
      frame.evaluate((d) => {
        const dt = new DataTransfer();
        for (const k of Object.keys(d)) dt.setData(k, d[k]);
        const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
        document.querySelector('.ql-editor').dispatchEvent(ev);
      }, data),
    copy: (type = 'copy') =>
      frame.evaluate((t) => {
        const dt = new DataTransfer();
        const ev = new ClipboardEvent(t, { clipboardData: dt, bubbles: true, cancelable: true });
        document.querySelector('.ql-editor').dispatchEvent(ev);
        const out = {};
        for (const k of dt.types) out[k] = dt.getData(k);
        return out;
      }, type),
  };
  return api;
}

const scenarios = {
  async typing(e) {
    await e.focusAt(11);
    await e.page.keyboard.type(' foo');
    await sleep(200);
    return { doc: await e.get(), log: await e.log() };
  },
  async boldShortcut(e) {
    await e.focusAt(0, 5);
    await e.page.keyboard.press('Meta+b');
    await sleep(200);
    return { doc: await e.get(), format: await e.format() };
  },
  async controllerToggles(e) {
    await e.focusAt(0, 5);
    await e.call('toggleItalic');
    await e.call('toggleUnderline');
    await e.call('toggleBulletList');
    await sleep(200);
    const a = { doc: await e.get(), format: await e.format() };
    await e.call('toggleOrderedList');
    await sleep(200);
    return { ...a, doc2: await e.get(), format2: await e.format() };
  },
  async listTabIndent(e) {
    await e.set([
      { insert: 'one' }, { insert: '\n', attributes: { list: 'bullet' } },
      { insert: 'two' }, { insert: '\n', attributes: { list: 'bullet' } },
      { insert: 'three' }, { insert: '\n', attributes: { list: 'bullet' } },
    ]);
    await e.focusAt(4);
    await e.page.keyboard.press('Tab');
    await sleep(150);
    const tab = await e.get();
    await e.focusAt(8);
    await e.page.keyboard.press('Tab');
    await sleep(150);
    const tab2 = await e.get();
    await e.focusAt(4);
    await e.page.keyboard.press('Shift+Tab');
    await sleep(150);
    return { tab, tab2, shiftTab: await e.get() };
  },
  async enterBackspace(e) {
    await e.focusAt(5);
    await e.page.keyboard.press('Enter');
    await e.page.keyboard.type('xy');
    await e.page.keyboard.press('Backspace');
    await sleep(200);
    return { doc: await e.get(), log: await e.log() };
  },
  async pastePlain(e) {
    await e.focusAt(6);
    await e.paste({ 'text/plain': 'pasted https://a.com text ' });
    await sleep(300);
    return { doc: await e.get(), log: await e.log() };
  },
  async pasteHtmlWithImage(e) {
    await e.focusAt(6);
    await e.paste({
      'text/plain': 'bold',
      'text/html': '<b>bold</b><img src="' + PNG + '"><iframe src="https://evil.example"></iframe>',
    });
    await sleep(300);
    return { doc: await e.get() };
  },
  async pasteImageFileOnly(e) {
    await e.focusAt(6);
    await e.frame.evaluate(async (png) => {
      const blob = await (await fetch(png)).blob();
      const dt = new DataTransfer();
      dt.items.add(new File([blob], 'a.png', { type: 'image/png' }));
      const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
      document.querySelector('.ql-editor').dispatchEvent(ev);
    }, PNG);
    await sleep(800);
    return { doc: await e.get() };
  },
  async autolinkTyping(e) {
    await e.focusAt(11);
    await e.page.keyboard.type(' see https://example.com ');
    await sleep(300);
    return { doc: await e.get() };
  },
  async undoRedo(e) {
    await e.focusAt(11);
    await e.page.keyboard.type('abc');
    await sleep(1200);
    await e.page.keyboard.type('def');
    await sleep(100);
    await e.page.keyboard.press('Meta+z');
    await sleep(200);
    const undo = await e.get();
    await e.page.keyboard.press('Meta+Shift+z');
    await sleep(200);
    return { undo, redo: await e.get() };
  },
  async copyCut(e) {
    await e.set([{ insert: 'Hello ' }, { insert: 'bold', attributes: { bold: true } }, { insert: ' end\n' }]);
    await e.focusAt(3, 8);
    const copy = await e.copy('copy');
    await sleep(100);
    const cut = await e.copy('cut');
    await sleep(200);
    return { copy, cut, doc: await e.get() };
  },
  async setContentsWithEmbeds(e) {
    await e.set([
      { insert: 'a' },
      { insert: { image: PNG } },
      { insert: 'b\n' },
      { insert: 'H' },
      { insert: '\n', attributes: { header: 1 } },
      { insert: 'code' },
      { insert: '\n', attributes: { 'code-block': true } },
    ]);
    await sleep(200);
    return { doc: await e.get(), log: await e.log() };
  },
  async controllerApi(e) {
    await e.call('clear');
    await e.call('insertText', 0, 'abc');
    await e.call('replaceText', 1, 1, 'XYZ');
    await e.focusAt(2);
    await e.call('insertTextAtCursor', '__');
    await sleep(200);
    return { doc: await e.get(), log: await e.log() };
  },
  async formatStateLink(e) {
    await e.set([{ insert: 'go ' }, { insert: 'here', attributes: { link: 'https://x.com' } }, { insert: ' now\n' }]);
    await e.focusAt(5);
    await sleep(200);
    const inside = await e.format();
    await e.focusAt(3);
    await sleep(200);
    return { inside, edge: await e.format() };
  },
  async dropImageFile(e) {
    await e.focusAt(6);
    await e.frame.evaluate(async (png) => {
      const blob = await (await fetch(png)).blob();
      const dt = new DataTransfer();
      dt.items.add(new File([blob], 'a.png', { type: 'image/png' }));
      const root = document.querySelector('.ql-editor');
      const r = root.getBoundingClientRect();
      for (const type of ['dragenter', 'dragover', 'drop']) {
        root.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 }));
      }
    }, PNG);
    await sleep(800);
    return { doc: await e.get() };
  },
  async readOnly(e) {
    // Opened with ?readOnly=1.
    await e.frame.click('.ql-editor');
    await e.page.keyboard.type('zzz');
    await e.paste({ 'text/plain': 'pasted' });
    await sleep(300);
    return { doc: await e.get(), log: await e.log() };
  },
};

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, headless: true });
  const results = {};
  const only = process.env.ONLY ? process.env.ONLY.split(',') : null;
  for (const [name, fn] of Object.entries(scenarios)) {
    if (only && !only.includes(name)) continue;
    const extra = process.env.EXTRA || '';
    const parts = [extra, name === 'readOnly' ? 'readOnly=1' : ''].filter(Boolean);
    const e = await open(browser, parts.length ? '?' + parts.join('&') : '');
    try {
      results[name] = await fn(e);
    } catch (err) {
      results[name] = { error: String(err) };
    }
    if (e.errors.length) results[name].pageErrors = e.errors;
    await e.page.close();
  }
  await browser.close();
  fs.writeFileSync(outFile, JSON.stringify(results, null, 2));
  console.log('wrote', outFile, Object.keys(results).length, 'scenarios');
})();
