// Открывает НАШ профиль на странице проверки и ждёт, пока её пройдут руками.
// Пути берутся от самого скрипта: папку можно положить куда угодно.
const HERE = __dirname.replace(/\\/g, '/');
// Кука ring/ring_session ложится в этот профиль, и обходчик дальше идёт сам.
// Обычный Chrome хозяина не годится: у него свой профиль, наша кука туда не попадёт.
const { chromium } = require('patchright');
const WAIT_MIN = Number(process.argv[3] || 20);
(async () => {
  const ctx = await chromium.launchPersistentContext(`${HERE}/profile-farpost`, {
    headless: false, channel: 'chrome', locale: 'ru-RU', viewport: { width: 1200, height: 850 },
    args: ['--disable-blink-features=AutomationControlled', '--window-position=80,60'],
    ignoreDefaultArgs: ['--enable-automation', '--no-sandbox'],
  });
  const p = ctx.pages()[0] || await ctx.newPage();
  const url = process.argv[2] || 'https://www.farpost.ru/company/TehnoSet/';
  await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  console.log('окно открыто:', p.url());
  console.log(`жду до ${WAIT_MIN} мин, пока проверку пройдут руками`);
  const until = Date.now() + WAIT_MIN * 60000;
  while (Date.now() < until) {
    if (!p.url().includes('/verify')) {
      console.log('ПРОВЕРКА ПРОЙДЕНА, страница:', p.url());
      await p.waitForTimeout(4000);
      await ctx.close();
      process.exit(0);
    }
    await p.waitForTimeout(3000);
  }
  console.log('не дождался, окно закрываю');
  await ctx.close();
  process.exit(3);
})().catch(e => { console.log('ОШИБКА:', e.message.slice(0, 200)); process.exit(1); });
