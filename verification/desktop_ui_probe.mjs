import fs from 'node:fs';
import crypto from 'node:crypto';

const log = fs.readFileSync(process.argv[2], 'utf8');
const port = log.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//)?.[1];
if (!port) throw new Error('No local desktop inspection endpoint');

async function call(target, method, params) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  try {
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, {once: true});
      ws.addEventListener('error', reject, {once: true});
    });
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Inspection timed out')), 3000);
      ws.addEventListener('message', event => {
        const message = JSON.parse(event.data);
        if (message.id === 1) {
          clearTimeout(timer);
          resolve(message);
        }
      });
    });
    ws.send(JSON.stringify({id: 1, method, params}));
    const result = await response;
    if (result.error || result.result?.exceptionDetails) throw new Error('Page inspection failed');
    return result.result;
  } finally {
    ws.close();
  }
}

async function evaluate(target, expression) {
  const result = await call(target, 'Runtime.evaluate', {expression, returnByValue: true});
  return JSON.parse(result.result.value);
}

const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const observations = [];
for (const target of targets.filter(t => t.type === 'page' && t.url.startsWith('app://'))) {
  const profileMenu = await evaluate(target, `JSON.stringify((() => {
    const button = [...document.querySelectorAll('button')].find(e =>
      /^(打开个人资料菜单|Open profile menu)$/i.test(e.getAttribute('aria-label') ?? ''));
    const rect = button?.getBoundingClientRect();
    return {opened: Boolean(button),
      name: button?.querySelector(':scope > span.truncate')?.textContent ?? null,
      x: rect ? rect.x + rect.width / 2 : 0,
      y: rect ? rect.y + rect.height / 2 : 0};
  })())`);
  if (profileMenu.opened) {
    const point = {x: profileMenu.x, y: profileMenu.y, button: 'left', clickCount: 1};
    await call(target, 'Input.dispatchMouseEvent', {type: 'mousePressed', ...point});
    await call(target, 'Input.dispatchMouseEvent', {type: 'mouseReleased', ...point});
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  const data = await evaluate(target, `JSON.stringify({
    text: document.body?.innerText ?? '',
    buttons: [...document.querySelectorAll('button')].map(e => ({
      label: e.getAttribute('aria-label') ?? '', title: e.title ?? ''
    })),
    settingsLinks: [...document.querySelectorAll('a[href]')]
      .filter(e => /settings/.test(e.getAttribute('href')))
      .map(e => e.getAttribute('href'))
  })`);
  const emails = [...new Set(data.text.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g) ?? [])];
  observations.push({
    page: target.url.split('?')[0],
    textLength: data.text.length,
    buttonCount: data.buttons.length,
    profileMenuOpened: profileMenu.opened,
    profileNameFingerprint: profileMenu.name ?
      crypto.createHash('sha256').update(profileMenu.name).digest('hex').slice(0, 12) : null,
    emailFingerprints: emails.map(e => crypto.createHash('sha256').update(e).digest('hex').slice(0, 12)),
    labels: data.buttons.map(e => e.label || e.title).filter(Boolean)
      .filter(s => /settings|account|profile|设置|账号|账户|个人/i.test(s))
      .map(s => s.replace(/[^\s@]+@[^\s@]+/g, '[email]')),
    settingsLinks: data.settingsLinks.filter(s => s.startsWith('/settings')),
    signInVisible: /(?:^|\n)(?:Sign in|Log in|登录)(?:\n|$)/.test(data.text)
  });
}
console.log(JSON.stringify(observations));
