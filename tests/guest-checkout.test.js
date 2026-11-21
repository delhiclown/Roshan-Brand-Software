const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {
  getClientIp,
  isDisposableDomain,
  validateDeviceId,
  validateEmailAddress,
  validateEmailFormat,
  validateWhatsApp
} = require('../lib/guest-checkout-utils');
const { hashGuestValue } = require('../lib/guest-hash');
const { normalizeSoftwarePlanCode } = require('../lib/software-plans');
const guestCheckout = require('../api/guest-checkout');
const fs = require('node:fs');
const path = require('node:path');
const apiSource = fs.readFileSync(path.join(__dirname, '..', 'api', 'guest-checkout.js'), 'utf8');
const migration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'guest-checkout-migration.sql'), 'utf8');
const publicIndex = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');
const serviceWorker = fs.readFileSync(path.join(__dirname, '..', 'public', 'service-worker.js'), 'utf8');
const envExample = fs.readFileSync(path.join(__dirname, '..', '.env.example'), 'utf8');
const readme = fs.readFileSync(path.join(__dirname, '..', 'README.md'), 'utf8');

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; }
  };
}

test('email validation normalizes regular addresses and rejects disposable or invalid domains', async () => {
  assert.equal(validateEmailFormat(' Customer@Example.com ').email, 'customer@example.com');
  assert.equal(isDisposableDomain('mailinator.com'), true);
  assert.equal(isDisposableDomain('sub.yopmail.com'), true);
  assert.equal(isDisposableDomain('example.com'), false);
  assert.throws(() => validateEmailFormat('not-an-email'), /valid email/i);
  assert.throws(() => validateEmailFormat('user@mailinator.com'), /temporary email/i);
  await assert.rejects(
    validateEmailAddress('user@example.com', async () => []),
    /cannot receive email/i
  );
  assert.equal(
    await validateEmailAddress('user@example.com', async () => [{ exchange: 'mx.example.com' }]),
    'user@example.com'
  );
  await assert.rejects(
    validateEmailAddress('user@example.com', async () => { throw Object.assign(new Error('missing'), { code: 'ENOTFOUND' }); }),
    /cannot receive email/i
  );
});

test('guest device, phone, and IP values require safe formats', () => {
  assert.equal(validateDeviceId('4f2b77ab-27c9-4c8f-a01f-99792e3e8b26'), '4f2b77ab-27c9-4c8f-a01f-99792e3e8b26');
  assert.throws(() => validateDeviceId('not-a-device'), /verify this device/i);
  assert.equal(validateWhatsApp(''), '');
  assert.equal(validateWhatsApp('+91 98765 43210'), '9876543210');
  assert.equal(validateWhatsApp('09876543210'), '9876543210');
  for (const phone of ['9876543210', '8876543210', '7876543210', '6876543210']) {
    assert.equal(validateWhatsApp(phone), phone);
  }
  assert.throws(() => validateWhatsApp('987654321'), /10-digit Indian mobile/i);
  assert.throws(() => validateWhatsApp('5876543210'), /10-digit Indian mobile/i);
  assert.throws(() => validateWhatsApp('98765432100'), /10-digit Indian mobile/i);
  assert.throws(() => validateWhatsApp('abc9876543210'), /10-digit Indian mobile/i);

  const previousVercel = process.env.VERCEL;
  delete process.env.VERCEL;
  assert.equal(getClientIp({ headers: {}, socket: { remoteAddress: '127.0.0.1' } }), '127.0.0.1');
  process.env.VERCEL = '1';
  assert.equal(getClientIp({ headers: { 'x-forwarded-for': '203.0.113.8, 10.0.0.1' }, socket: { remoteAddress: '10.0.0.2' } }), '203.0.113.8');
  if (previousVercel === undefined) delete process.env.VERCEL;
  else process.env.VERCEL = previousVercel;
});

test('guest WhatsApp input is digit-only, capped, and normalizes pasted country prefixes', () => {
  assert.equal((publicIndex.match(/id="guest-whatsapp"/g) || []).length, 1);
  assert.match(publicIndex, /id="guest-whatsapp"[^>]*inputmode="numeric"[^>]*maxlength="10"/);
  assert.match(publicIndex, /const normalizeGuestWhatsApp=value=>\{\s*const digits=String\(value\|\|''\)\.replace\(\/\\D\/g,''\);\s*return digits\.length>10\?digits\.slice\(-10\):digits;/);
  assert.match(publicIndex, /guestWhatsApp\.addEventListener\('paste',event=>\{\s*event\.preventDefault\(\);[\s\S]*normalizeGuestWhatsApp\(pasted\)/);
  assert.match(publicIndex, /const digits=String\(whatsappInput\.value\|\|''\)\.replace\(\/\\D\/g,''\)\.slice\(-10\)/);
});

test('service worker does not cache page navigations and advances its cache version', () => {
  assert.match(serviceWorker, /const CACHE_NAME = 'roshan-static-v6'/);
  assert.match(serviceWorker, /if \(request\.mode === 'navigate'\) \{\s*if \(url\.pathname === '\/' \|\| url\.pathname === '\/index\.html'\) return;/);
});

test('guest hash secret is documented without exposing a real value', () => {
  assert.match(envExample, /^GUEST_HASH_SECRET=replace-with-at-least-32-random-characters$/m);
  assert.match(readme, /`GUEST_HASH_SECRET`[\s\S]*at least 32 characters[\s\S]*server logs the configuration reason[\s\S]*Checkout is temporarily unavailable/);
  assert.doesNotMatch(readme, /Guest checkout privacy settings are not configured/);
});

test('guest identity hashes reject a missing or too-short secret without exposing it', () => {
  const previousSecret = process.env.GUEST_HASH_SECRET;
  try {
    delete process.env.GUEST_HASH_SECRET;
    assert.throws(() => hashGuestValue('customer@example.com'), error => {
      assert.equal(error.code, 'GUEST_HASH_SECRET_NOT_CONFIGURED');
      assert.match(error.message, /GUEST_HASH_SECRET is missing or shorter than 32 characters/);
      return true;
    });
    process.env.GUEST_HASH_SECRET = 'short';
    assert.throws(() => hashGuestValue('customer@example.com'), /GUEST_HASH_SECRET is missing or shorter than 32 characters/);
    process.env.GUEST_HASH_SECRET = 'test-secret-with-more-than-32-characters';
    const hash = hashGuestValue('customer@example.com');
    assert.match(hash, /^[0-9a-f]{64}$/);
    assert.notEqual(hash, 'customer@example.com');
  } finally {
    if (previousSecret === undefined) delete process.env.GUEST_HASH_SECRET;
    else process.env.GUEST_HASH_SECRET = previousSecret;
  }
});

test('guest checkout hides missing-secret details from customers and logs the cause', async () => {
  const previousSecret = process.env.GUEST_HASH_SECRET;
  const originalError = console.error;
  const logged = [];
  delete process.env.GUEST_HASH_SECRET;
  console.error = (...args) => logged.push(args);
  try {
    const res = responseRecorder();
    await guestCheckout({
      method: 'POST',
      headers: {},
      socket: { remoteAddress: '127.0.0.2' },
      body: { action: 'submit_utr', order_id: 1, access_token: 'A'.repeat(43), utr: '123456789012' }
    }, res);
    assert.equal(res.statusCode, 503);
    assert.equal(res.body.error, 'Checkout is temporarily unavailable. Please contact support.');
    assert.match(String(logged[0]?.[1]?.message), /GUEST_HASH_SECRET is missing or shorter than 32 characters/);
  } finally {
    console.error = originalError;
    if (previousSecret === undefined) delete process.env.GUEST_HASH_SECRET;
    else process.env.GUEST_HASH_SECRET = previousSecret;
  }
});

test('guest checkout shows a support message when its database function is missing', async () => {
  const env = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    GUEST_HASH_SECRET: process.env.GUEST_HASH_SECRET
  };
  const originalFetch = global.fetch;
  const originalError = console.error;
  const logged = [];
  process.env.SUPABASE_URL = 'https://unit-test.invalid';
  process.env.SUPABASE_SERVICE_ROLE_KEY = 'unit-test-service-key';
  process.env.GUEST_HASH_SECRET = 'test-secret-with-more-than-32-characters';
  global.fetch = async () => ({
    ok: false,
    status: 404,
    json: async () => ({ code: 'PGRST202', message: 'Could not find the function public.guest_submit_order_utr.' })
  });
  console.error = (...args) => logged.push(args);
  try {
    const res = responseRecorder();
    await guestCheckout({
      method: 'POST',
      headers: {},
      socket: { remoteAddress: '127.0.0.3' },
      body: { action: 'submit_utr', order_id: 1, access_token: 'A'.repeat(43), utr: '123456789012' }
    }, res);
    assert.equal(res.statusCode, 503);
    assert.equal(res.body.error, 'Checkout is temporarily unavailable. Please contact support.');
    assert.match(String(logged[0]?.[1]?.message), /Could not find the function/);
  } finally {
    global.fetch = originalFetch;
    console.error = originalError;
    for (const [key, value] of Object.entries(env)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test('guest checkout endpoint rejects non-POST requests without contacting Supabase', async () => {
  const res = responseRecorder();
  await guestCheckout({ method: 'GET', headers: {}, socket: {} }, res);
  assert.equal(res.statusCode, 405);
  assert.equal(res.headers.Allow, 'POST');
  assert.equal(res.body.error, 'Method not allowed.');
  assert.equal(res.headers['Cache-Control'], 'no-store');
});

test('guest order history only returns orders authorized by each saved access token', async () => {
  const originalFetch = global.fetch;
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    GUEST_HASH_SECRET: process.env.GUEST_HASH_SECRET
  };
  const token = 'A'.repeat(43);
  let rpcRequest;
  process.env.SUPABASE_URL = 'https://unit-test.invalid';
  process.env.SUPABASE_SERVICE_ROLE_KEY = 'unit-test-service-key';
  process.env.GUEST_HASH_SECRET = 'test-secret-with-more-than-32-characters';
  global.fetch = async (url, options) => {
    rpcRequest = { url, body: JSON.parse(options.body) };
    return {
      ok: true,
      status: 200,
      json: async () => ({ ok: true, order_id: 19, status: 'new' })
    };
  };
  try {
    const res = responseRecorder();
    await guestCheckout({
      method: 'POST',
      headers: {},
      socket: { remoteAddress: '127.0.0.4' },
      body: { action: 'get_orders', orders: [{ order_id: 19, access_token: token }] }
    }, res);
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['Cache-Control'], 'no-store');
    assert.match(rpcRequest.url, /\/rpc\/guest_get_order$/);
    assert.equal(rpcRequest.body.p_order_id, 19);
    assert.equal(
      rpcRequest.body.p_access_hash,
      crypto.createHash('sha256').update(token).digest('hex')
    );
    assert.deepEqual(res.body.orders, [{ ok: true, order_id: 19, status: 'new' }]);
  } finally {
    global.fetch = originalFetch;
    for (const [key, value] of Object.entries(previousEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test('UTR success closes checkout and guest order credentials persist for My Orders', () => {
  assert.match(publicIndex, /if\(!\/\^\\d\{12\}\$\/\.test\(utr\)\)/);
  assert.match(publicIndex, /closeModal\(\);\s*showNotice\('UTR submitted\. Your order is under review\.'\);\s*openOrdersPanel\(\)/);
  assert.match(publicIndex, /function closeModal\(\)\s*\{\s*stopCheckoutPaymentTimer\(\)/);
  assert.match(publicIndex, /function stopCheckoutPaymentTimer\(\)\s*\{\s*if\(state\.checkoutTimer!==null\)\{clearInterval\(state\.checkoutTimer\)/);
  assert.match(publicIndex, /const guestOrderStorageKey='roshan-guest-orders-v1'/);
  assert.match(publicIndex, /persistGuestOrderCredential\(result\.order\.order_id,result\.access_token\)/);
  assert.match(publicIndex, /action:'get_orders',orders:credentials/);
  assert.match(publicIndex, /if\(!state\.user&&!state\.guestMode\)/);
});

test('checkout does not resume expired saved orders and Try Again creates a fresh payment order', () => {
  assert.match(publicIndex, /cache:'no-store'/);
  assert.match(publicIndex, /const activeOrder=\['unpaid','pending_payment'\]\.includes\(data\.status\)\s*&&Number\.isFinite\(expiresAt\)\s*&&expiresAt>checkoutServerNow\((?:state\.checkout|checkout)\)/);
  assert.match(publicIndex, /data-new-payment[\s\S]*?checkout\.paymentOrder=null;checkout\.paymentOrderSignature=null;checkout\.paymentTimerExpired=false;[\s\S]*?storageKeys\.forEach\(key=>localStorage\.removeItem\(key\)\)[\s\S]*?void ensureCheckoutPaymentOrder\(\)/);
  assert.match(publicIndex, /p_order_id:\['unpaid','pending_payment'\]\.includes\(checkout\.paymentOrder\?\.status\)&&existingExpiry>checkoutServerNow\(checkout\)/);
  assert.match(publicIndex, /anchorCheckoutServerTime\(checkout,data\.server_now,data\.order_id\);[\s\S]*?checkout\.paymentOrder=\{\s*order_id:data\.order_id/);
  assert.match(apiSource, /function sendJson\(res, status, body\)\s*\{\s*res\.setHeader\('Cache-Control', 'no-store'\)/);
  assert.match(migration, /insert into public\.orders \([\s\S]*?v_now \+ make_interval\(mins => v_timeout\)/);
});

test('guest Software checkout accepts only the three database plan IDs', () => {
  assert.equal(normalizeSoftwarePlanCode('2_PNR_30_DAYS'), '2_pnr_30_days');
  assert.equal(normalizeSoftwarePlanCode(' 4_pnr_30_days '), '4_pnr_30_days');
  assert.equal(normalizeSoftwarePlanCode('6_pnr_30_days'), '6_pnr_30_days');
  assert.equal(normalizeSoftwarePlanCode(''), null);
  assert.throws(() => normalizeSoftwarePlanCode('999_pnr_30_days'), /valid 30-day software pnr plan/i);
});

test('guest Software orders use the plan-aware RPC and database plan price', () => {
  assert.match(apiSource, /callRpc\('guest_create_order',\s*\{[\s\S]*p_plan_code:\s*softwarePlanCode/);
  assert.match(migration, /create or replace function public\.guest_create_order\([\s\S]*p_plan_code text/);
  assert.match(migration, /if v_plan_code not in \('2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days'\)/);
  assert.match(migration, /v_checkout_price := v_product\.plan_2_pnr_price/);
  assert.match(migration, /software_plan_code, software_plan_label, software_plan_mrp/);
});

test('guest Used Key orders reserve inventory atomically and release it on terminal payment state', () => {
  assert.match(migration, /k\.expires_on >= \(timezone\('Asia\/Kolkata', v_now\)\)::date/);
  assert.doesNotMatch(migration, /k\.expiry_at/);
  assert.match(migration, /for update;\s*if not found then return jsonb_build_object\('ok', false, 'message', 'This Used Key is no longer available\.'/);
  assert.match(migration, /set status = 'reserved', reserved_order_id = v_order\.id[\s\S]*if not found then raise exception 'This used key is no longer available.'/);
  assert.match(migration, /set status = 'available', reserved_order_id = null[\s\S]*where k\.id = v_order\.used_key_id[\s\S]*k\.reserved_order_id = v_order\.id/);
  assert.match(migration, /release_guest_used_key_reservation[\s\S]*new\.status in \('expired', 'rejected', 'cancelled'\)/);
});

test('guest order request shape retains Used Key columns and guest refunds never touch a wallet', () => {
  assert.match(migration, /product_type text, used_key_id bigint, used_key_remaining_days integer, amount numeric, utr_number text/);
  assert.match(migration, /end as used_key_remaining_days/);
  assert.match(migration, /if v_order\.user_id is null then\s+return jsonb_build_object\('ok', false, 'message', 'Guest orders cannot be refunded to a wallet/);
});

test('admin order list retains the PNR label and legacy visibility filter', () => {
  assert.match(migration, /late_payment boolean,\s+software_plan_label text/);
  assert.match(migration, /o\.late_payment, o\.software_plan_label/);
  assert.match(migration, /where o\.status not in \('unpaid', 'pending_payment', 'new'\)/);
});

test('guest admin actions preserve coupon, offer, and wallet behavior', () => {
  assert.match(migration, /update public\.coupons as c set[\s\S]*where c\.used_order_id = p_order_id/);
  assert.match(migration, /insert into public\.offer_audit_events/);
  assert.match(migration, /update public\.wallets as w set\s+balance = w\.balance \+ v_order\.price/);
  assert.match(migration, /if v_order\.user_id is null then\s+return jsonb_build_object\('ok', false/);
  assert.match(migration, /create function public\.admin_list_rental_requests\(\)[\s\S]*guest_email_sent_at/);
});
