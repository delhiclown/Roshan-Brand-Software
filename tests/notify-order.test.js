const test = require('node:test');
const assert = require('node:assert/strict');
const notifyOrder = require('../api/notify-order');

const originalEnv = { ...process.env };
const originalFetch = global.fetch;
const requests = [];
let order;
let claimStatus = 201;
let telegramStatus = 200;
let requestSequence = 0;

function response(status, data) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() { return data; }
  };
}

function setOrder(overrides = {}) {
  order = {
    id: 42,
    user_id: 'user-1',
    product_name: '<OCEAN PRO>',
    product_type: 'software',
    quantity: 1,
    amount: 1299,
    price: 1299,
    utr: '123456789012',
    utr_number: '123456789012',
    created_at: '2026-11-11T00:00:00.000Z',
    payment_submitted_at: '2026-11-11T00:00:00.000Z',
    ...overrides
  };
}

function request(body = { order_id: 42 }, headers = {}) {
  return {
    method: 'POST',
    headers: { authorization: 'Bearer customer-session', ...headers },
    socket: { remoteAddress: `test-client-${++requestSequence}` },
    body
  };
}

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; }
  };
}

async function call(body, headers) {
  const res = responseRecorder();
  await notifyOrder(request(body, headers), res);
  return res;
}

test.beforeEach(() => {
  process.env.SUPABASE_URL = 'https://supabase.example';
  process.env.SUPABASE_ANON_KEY = 'anon-test';
  process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-test';
  process.env.TELEGRAM_BOT_TOKEN = 'telegram-test';
  process.env.TELEGRAM_CHAT_ID = 'chat-test';
  process.env.TELEGRAM_TEST_SECRET = 'test-secret';
  requests.length = 0;
  claimStatus = 201;
  telegramStatus = 200;
  setOrder();
  global.fetch = async (url, options = {}) => {
    requests.push({ url: String(url), options });
    if (String(url).endsWith('/auth/v1/user')) {
      return response(200, { id: 'user-1', email: 'customer@example.com', user_metadata: { full_name: 'Customer <One>' } });
    }
    if (String(url).includes('/rest/v1/orders?')) return response(200, order ? [order] : []);
    if (String(url).endsWith('/rest/v1/telegram_order_alerts') && options.method === 'POST') {
      return response(claimStatus, {});
    }
    if (String(url).includes('/rest/v1/telegram_order_alerts?') && options.method === 'PATCH') {
      return response(204, null);
    }
    if (String(url).includes('api.telegram.org')) {
      return response(telegramStatus, { ok: telegramStatus === 200 });
    }
    throw new Error(`Unexpected request: ${url}`);
  };
});

test.after(() => {
  global.fetch = originalFetch;
  for (const key of Object.keys(process.env)) {
    if (!(key in originalEnv)) delete process.env[key];
  }
  for (const [key, value] of Object.entries(originalEnv)) process.env[key] = value;
});

test('sends an escaped alert using database order details', async () => {
  const res = await call({ order_id: 42, product_name: 'untrusted', utr: '000000000000' });
  assert.equal(res.statusCode, 200);
  const telegramRequest = requests.find(item => item.url.includes('api.telegram.org'));
  const message = JSON.parse(telegramRequest.options.body).text;
  assert.match(message, /Customer &lt;One&gt; \/ customer@example\.com/);
  assert.match(message, /Product: &lt;OCEAN PRO&gt;/);
  assert.match(message, /UTR: 123456789012/);
  assert.equal(requests.filter(item => item.url.includes('api.telegram.org')).length, 1);
});

test('does not claim or alert an order without a valid UTR', async () => {
  setOrder({ utr: null, utr_number: null });
  const res = await call();
  assert.equal(res.statusCode, 409);
  assert.equal(requests.some(item => item.options.method === 'POST'), false);
  assert.equal(requests.some(item => item.url.includes('api.telegram.org')), false);
});

test('does not alert an order that is not returned as eligible', async () => {
  order = null;
  const res = await call();
  assert.equal(res.statusCode, 409);
  assert.equal(requests.some(item => item.url.includes('api.telegram.org')), false);
});

test('duplicate claims never send a second Telegram message', async () => {
  claimStatus = 409;
  const res = await call();
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.duplicate, true);
  assert.equal(requests.some(item => item.url.includes('api.telegram.org')), false);
});

test('reports Telegram failure without losing the order claim', async () => {
  telegramStatus = 502;
  const res = await call();
  assert.equal(res.statusCode, 502);
  const failureUpdate = requests.find(item =>
    item.options.method === 'PATCH' && item.url.includes('telegram_order_alerts')
  );
  assert.ok(failureUpdate);
  assert.match(JSON.parse(failureUpdate.options.body).error, /Telegram sendMessage failed/);
});

test('test message route requires its secret', async () => {
  const unauthorized = await call({ test: true });
  assert.equal(unauthorized.statusCode, 401);
  const authorized = await call({ test: true }, { 'x-telegram-test-secret': 'test-secret' });
  assert.equal(authorized.statusCode, 200);
});
