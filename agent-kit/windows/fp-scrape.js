// Сбор витрины магазина Фарпоста. ЗАПУСКАЕТСЯ НА ВИНДЕ (рядом со скриптом), как
// Пути берутся от самого скрипта: папку можно положить куда угодно.
const HERE = __dirname.replace(/\\/g, '/');
// авитошный сборщик: с сервера farpost пускает только на /verify.
// Проверено 07.09.2026 на TehnoSet -- 1922 позиции, 39 страниц, ~2 мин (до щадящего режима;
// теперь ~6 с на страницу плюс передышки -- 20 страниц ≈ 3 мин).
// Сбор витрины магазина Фарпоста. Настоящий Chrome + отдельный постоянный профиль
// (не авитошный: у Фарпоста своя кука ring/ring_session, мешать их незачем).
// Проверка ALTCHA -- одна галка, кука живёт ~400 дней, поэтому profile отдельный и постоянный.
const { chromium } = require('patchright');
const fs = require('fs');

// Аргумент -- слаг компании (/company/<slug>/) или полная ссылка на страницу
// продавца (/user/<name>/): iTime и AppleDubai сидят на /user/, не на /company/.
const ARG = process.argv[2] || 'TehnoSet';
const URL = ARG.startsWith('http') ? ARG.replace(/\/?$/, '/') : `https://www.farpost.ru/company/${ARG}/`;
const SLUG = URL.split('/').filter(Boolean).pop();
const PROFILE = `${HERE}/profile-farpost`;
const OUT = `${HERE}/farpost-${SLUG}.json`;

const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: false, channel: 'chrome', locale: 'ru-RU', viewport: { width: 1366, height: 900 },
    args: ['--disable-blink-features=AutomationControlled'],
    ignoreDefaultArgs: ['--enable-automation', '--no-sandbox'],
  });
  // Щадящий режим (после бана 07.09): браузер тянет на страницу полсотни запросов --
  // картинки, шрифты, метрики. Пускаем только сам документ и скрипты Фарпоста
  // (они нужны стене ALTCHA), остальное режем: одна страница = единицы запросов.
  await ctx.route('**/*', route => {
    const r = route.request(); const t = r.resourceType(); const h = new globalThis.URL(r.url()).hostname; // URL выше -- ссылка магазина, не класс
    const ours = /(^|\.)farpost\.ru$/.test(h);
    if (ours && (t === 'document' || t === 'script' || t === 'xhr' || t === 'fetch')) return route.continue();
    return route.abort();
  });
  const p = ctx.pages()[0] || await ctx.newPage();
  await p.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await sleep(3000);

  // Проверка «я не робот»: ОДНА попытка с галкой. Каждый провал Фарпост считает
  // (счётчик f= в адресе) и продлевает бан, поэтому не долбим.
  if (p.url().includes('/verify')) {
    const box = p.locator('input[type=checkbox]').first();
    if (await box.count()) { await box.click({ force: true }).catch(() => {}); }
    await p.waitForURL(u => !u.href.includes('/verify'), { timeout: 150000 }).catch(() => {});
  }
  console.log('URL после проверки:', p.url());
  if (p.url().includes('/verify')) {
    console.log('НЕ ПРОШЛИ проверку');
    await ctx.close(); process.exit(2);
  }

  // Витрина: собираем со всех страниц пагинации.
  const items = []; const seen = new Set();
  // Потолок в 40 страниц = ровно 2000 позиций, и AppleDubaiVL упёрся в него
  // 08.09.2026: круглое число -- это обрезка, а не конец каталога. Цикл сам
  // выходит по первой странице без новых позиций, потолок нужен лишь как
  // страховка от бесконечной пагинации.
  for (let page = 1; page <= 200; page++) {
    const u = page === 1 ? URL : `${URL}?page=${page}`;
    if (page > 1) {
      // Темп человека: 4-8 с между страницами и передышка в полминуты каждые десять.
      await sleep(4000 + Math.random() * 4000);
      if (page % 10 === 1) await sleep(30000);
      await p.goto(u, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await sleep(1500);
      if (p.url().includes('/verify')) { console.log('стена на стр', page, '-- стоп, сохраняю что есть'); break; }
    }
    const rows = await p.$$eval('tr[data-bulletin-id], .bull-item, [data-bull-id]', els => els.map(el => {
      const a = el.querySelector('a.bulletinLink, a[href*="/"]');
      // ТОЛЬКО data-role=price: контейнер вокруг цены содержит ещё «доставка до ТК
      // 2 000 ₽», и селектор по [class*=price] склеивал их в «724992000».
      const price = el.querySelector('[data-role="price"]');
      const city = el.querySelector('.bull-delivery__city');
      // Цвет и тип симки лежат прямо в витрине, в аннотации:
      // «Новый, 256 Гб, Синий, 3G, 4G LTE, 5G, Dual-SIM, NFC, eSIM».
      // Карточки открывать не нужно.
      const ann = el.querySelector('.bull-item__annotation');
      return {
        id: el.getAttribute('data-bulletin-id') || el.getAttribute('data-bull-id') || null,
        title: a ? a.textContent.trim() : null,
        url: a ? a.getAttribute('href') : null,
        price: price ? Number(price.textContent.replace(/[^\d]/g, '')) || null : null,
        city: city ? city.textContent.trim() : null,
        specs: ann ? ann.textContent.replace(/\s+/g, ' ').trim() : null,
      };
    })).catch(() => []);
    const fresh = rows.filter(r => r.title && !seen.has(r.url));
    fresh.forEach(r => { seen.add(r.url); items.push(r); });
    console.log(`стр ${page}: +${fresh.length} (всего ${items.length})`);
    if (!fresh.length) break;
  }
  fs.writeFileSync(OUT, JSON.stringify({ slug: SLUG, url: URL, ts: new Date().toISOString(), items }, null, 1));
  console.log('записано:', OUT, '| позиций:', items.length);
  await ctx.close();
})().catch(e => { console.log('ОШИБКА:', e.message.slice(0, 300)); process.exit(1); });
