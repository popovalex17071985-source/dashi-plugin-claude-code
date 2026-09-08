// Проба стены раз в N минут: открываем страницу продавца нашим профилем, пишем строку в лог.
// Пути берутся от самого скрипта: папку можно положить куда угодно.
const HERE = __dirname.replace(/\\/g, '/');
// Выходит с кодом 0, как только стена пропустила.
const { chromium } = require('patchright');
const fs = require('fs');
const URL = 'https://www.farpost.ru/user/iTimePro/';
const EVERY = +(process.argv[2] || 15) * 60000, LOG = `${HERE}/fp-probe.log`;
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  for (let i = 0; i < (EVERY ? 200 : 1); i++) {
    const ctx = await chromium.launchPersistentContext(`${HERE}/profile-farpost`, {
      headless: false, channel: 'chrome', locale: 'ru-RU', viewport: { width: 1366, height: 900 },
      args: ['--disable-blink-features=AutomationControlled'],
      ignoreDefaultArgs: ['--enable-automation', '--no-sandbox'],
    });
    const p = ctx.pages()[0] || await ctx.newPage();
    await p.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
    await sleep(3000);
    if (p.url().includes('/verify')) {
      const box = p.locator('input[type=checkbox]').first();
      if (await box.count()) await box.click({ force: true }).catch(() => {});
      // Проверка ALTCHA -- перебор на машине, на слабой винде может жевать дольше минуты.
      await p.waitForURL(u => !u.href.includes('/verify'), { timeout: 150000 }).catch(() => {});
    }
    const ok = !p.url().includes('/verify');
    const n = ok ? await p.$$eval('tr[data-bulletin-id], .bull-item, [data-bull-id]', e => e.length).catch(() => -1) : 0;
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${ok ? 'OPEN' : 'WALL'} ${p.url()} items=${n}\n`);
    await ctx.close();
    if (ok) { console.log('СТЕНА СНЯТА', p.url(), 'объявлений на 1 стр:', n); process.exit(0); }
    await sleep(EVERY);
  }
  process.exit(3);
})().catch(e => { console.log('ОШИБКА:', e.message.slice(0, 200)); process.exit(1); });
