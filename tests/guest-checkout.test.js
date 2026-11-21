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
const productPaymentMigration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'product-payment-expiry-migration.sql'), 'utf8');
const softwarePlanMigration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'software-pnr-plans-migration.sql'), 'utf8');
const usedKeyPaymentMigration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'used-keys-auto-validity-migration.sql'), 'utf8');
const expiryRecoveryMigration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '20261121055800_checkout_expiry_recovery.sql'), 'utf8');
const trackingMigration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '20261121065000_guest_order_tracking_account_linking.sql'), 'utf8');
const setupSql = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'setup.sql'), 'utf8');
const publicIndex = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');
const trackingPage = fs.readFileSync(path.join(__dirname, '..', 'public', 'order.html'), 'utf8');
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
  assert.match(publicIndex, /id="guest-email" type="email"[^>]*required/);
  assert.match(publicIndex, /WhatsApp number \(required\)/);
  assert.match(apiSource, /const email = await validateEmailAddress\(body\.email\)/);
  assert.match(apiSource, /const whatsapp = validateWhatsApp\(body\.whatsapp\)/);
  assert.equal(validateDeviceId('4f2b77ab-27c9-4c8f-a01f-99792e3e8b26'), '4f2b77ab-27c9-4c8f-a01f-99792e3e8b26');
  assert.throws(() => validateDeviceId('not-a-device'), /verify this device/i);
  assert.equal(validateWhatsApp('9876543210'), '9876543210');
  assert.equal(validateWhatsApp('+919876543210'), '919876543210');
  assert.equal(validateWhatsApp('123456789012345'), '123456789012345');
  for (const phone of ['', '123456789', '1234567890123456', '++1234567890', 'abc1234567890']) {
    assert.throws(() => validateWhatsApp(phone), /10 to 15 digits/i);
  }

  const previousVercel = process.env.VERCEL;
  delete process.env.VERCEL;
  assert.equal(getClientIp({ headers: {}, socket: { remoteAddress: '127.0.0.1' } }), '127.0.0.1');
  process.env.VERCEL = '1';
  assert.equal(getClientIp({ headers: { 'x-forwarded-for': '203.0.113.8, 10.0.0.1' }, socket: { remoteAddress: '10.0.0.2' } }), '203.0.113.8');
  if (previousVercel === undefined) delete process.env.VERCEL;
  else process.env.VERCEL = previousVercel;
});

test('guest WhatsApp input requires 10 to 15 digits and server validates it too', () => {
  assert.equal((publicIndex.match(/id="guest-whatsapp"/g) || []).length, 1);
  assert.match(publicIndex, /id="guest-whatsapp"[^>]*maxlength="16"[^>]*required/);
  assert.match(publicIndex, /inputmode="tel" autocomplete="tel" maxlength="16" pattern="\\\+\?\[0-9\]\{10,15\}" required/);
  assert.match(publicIndex, /Enter 10 to 15 digits, with an optional \+/);
  assert.match(publicIndex, /validateGuestWhatsApp=\(\)=>\{\s*const whatsapp=String\(guestWhatsApp\.value\|\|''\)\.trim\(\)/);
  assert.match(apiSource, /const whatsapp = validateWhatsApp\(body\.whatsapp\)/);
  assert.match(publicIndex, /Message us on WhatsApp/);
  assert.match(publicIndex, /guestWhatsAppButton\(order\)/);
  assert.match(publicIndex, /if\(!whatsappNumber\)return ''/);
  assert.match(publicIndex, /Order number: \$\{order\.order_id/);
  assert.match(publicIndex, /Type: \$\{order\.order_type==='demo'\?'Demo key':'Paid order'\}/);
  assert.match(publicIndex, /encodeURIComponent\(message\)/);
  assert.match(publicIndex, /settings\?\.whatsapp_number/);
  assert.match(apiSource, /email_sent: emailSent/);
  assert.match(apiSource, /let emailSent = true;[\s\S]*emailSent = false;[\s\S]*sendJson\(res, 200, \{ ok: true, demo: \{ \.\.\.data, email_sent: emailSent \} \}\)/);
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

test('tracking requests hide invalid-token details behind the same not-found response', async () => {
  const res = responseRecorder();
  await guestCheckout({
    method: 'POST',
    headers: {},
    socket: { remoteAddress: '127.0.0.4' },
    body: { action: 'get_order', order_id: 19, access_token: 'invalid' }
  }, res);
  assert.equal(res.statusCode, 404);
  assert.deepEqual(res.body, { error: 'Order could not be found.' });
});

test('guest UTR confirmation email includes the capability tracking link and requested message', async () => {
  const originalFetch = global.fetch;
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    GUEST_HASH_SECRET: process.env.GUEST_HASH_SECRET,
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    RESEND_FROM_EMAIL: process.env.RESEND_FROM_EMAIL,
    PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL
  };
  const token = 'A'.repeat(43);
  let emailPayload;
  process.env.SUPABASE_URL = 'https://unit-test.invalid';
  process.env.SUPABASE_SERVICE_ROLE_KEY = 'unit-test-service-key';
  process.env.GUEST_HASH_SECRET = 'test-secret-with-more-than-32-characters';
  process.env.RESEND_API_KEY = 'test-resend-key';
  process.env.RESEND_FROM_EMAIL = 'orders@example.com';
  process.env.PUBLIC_SITE_URL = 'https://store.example/';
  global.fetch = async (url, options) => {
    if (String(url).endsWith('/rpc/guest_submit_order_utr')) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          order_id: 42,
          status: 'pending_verification',
          customer_email: 'customer@example.com'
        })
      };
    }
    if (String(url) === 'https://api.resend.com/emails') {
      emailPayload = JSON.parse(options.body);
      return { ok: true, status: 200, json: async () => ({ id: 'email-42' }) };
    }
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const res = responseRecorder();
    await guestCheckout({
      method: 'POST',
      headers: {},
      socket: { remoteAddress: '127.0.0.4' },
      body: { action: 'submit_utr', order_id: 42, access_token: token, utr: '123456789012' }
    }, res);
    assert.equal(res.statusCode, 200);
    assert.match(emailPayload.text, /https:\/\/store\.example\/order\/42\?token=A{43}/);
    assert.match(emailPayload.text, /Verification pending\? We will send the product to your email once confirmed\./);
    assert.match(emailPayload.html, /We received your payment details and will confirm shortly\./);
  } finally {
    global.fetch = originalFetch;
    for (const [key, value] of Object.entries(previousEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test('UTR success keeps checkout available and guest order credentials persist for tracking', () => {
  assert.match(publicIndex, /if\(!\/\^\\d\{12\}\$\/\.test\(utr\)\)/);
  assert.match(publicIndex, /guestOrder\.submitted=true;\s*guestOrder\.order=\{\.\.\.guestOrder\.order,\.\.\.result\.order,status:result\.order\?\.status\|\|'pending_verification'\};\s*renderGuestOrderStatus\(\)/);
  assert.match(publicIndex, /\/order\/\$\{encodeURIComponent\(String\(orderId\)\)\}\?token=/);
  assert.match(publicIndex, /Verification pending\? We will send the product to your email once confirmed\./);
  assert.match(publicIndex, /function closeModal\(\)\s*\{\s*stopCheckoutPaymentTimer\(\)/);
  assert.match(publicIndex, /function stopCheckoutPaymentTimer\(\)\s*\{\s*if\(state\.checkoutTimer!==null\)\{clearInterval\(state\.checkoutTimer\)/);
  assert.match(publicIndex, /const guestOrderStorageKey='roshan-guest-orders-v1'/);
  assert.match(publicIndex, /persistGuestOrderCredential\(result\.order\.order_id,result\.access_token\)/);
  assert.match(publicIndex, /action:'get_orders',orders:credentials/);
  assert.match(publicIndex, /if\(!state\.user&&!state\.guestMode\)/);
  assert.match(publicIndex, /rpc\('link_guest_orders_to_user'\)/);
  assert.match(trackingPage, /action: 'get_order'/);
  assert.match(trackingPage, /if \(order\.status === 'completed'\)/);
  assert.doesNotMatch(trackingPage, /innerHTML/);
  assert.match(trackingPage, /Order could not be found\./);
});

test('guest tracking and account linking require the order token and verified email', () => {
  assert.match(trackingMigration, /u\.email_confirmed_at is not null/);
  assert.match(trackingMigration, /o\.guest_email = v_email/);
  assert.match(trackingMigration, /set user_id = v_user_id, guest_device_hash = null, guest_ip_hash = null/);
  assert.match(trackingMigration, /o\.guest_access_hash = p_access_hash/);
  assert.match(trackingMigration, /status = 'completed' and v_delivery\.license_key_encrypted/);
  assert.match(trackingMigration, /revoke all on function public\.guest_get_order\(bigint, text\) from public, anon, authenticated/);
  assert.match(trackingMigration, /grant execute on function public\.guest_get_order\(bigint, text\) to service_role/);
  assert.match(trackingMigration, /grant execute on function public\.link_guest_orders_to_user\(\) to authenticated/);
  assert.match(setupSql, /alter table public\.orders enable row level security/);
  assert.match(setupSql, /for select to authenticated using \(user_id = \(select auth\.uid\(\)\)\)/);
  assert.match(setupSql, /revoke all on public\.wallets, public\.wallet_transactions, public\.topup_requests, public\.orders from anon, authenticated/);
});

test('checkout back and reopen creates an active QR and keeps expired orders secondary', () => {
  assert.match(publicIndex, /cache:'no-store'/);
  assert.match(publicIndex, /const activeOrder=\['unpaid','pending_payment'\]\.includes\(data\.status\)\s*&&Number\.isFinite\(expiresAt\)\s*&&expiresAt>checkoutServerNow\((?:state\.checkout|checkout)\)/);
  assert.doesNotMatch(publicIndex, /const activePaymentProduct=sessionStorage\.getItem\('active_upi_product'\)/);
  assert.match(publicIndex, /window\.addEventListener\('pageshow',event=>\{\s*clearPersistedCheckoutIntent\(\);\s*if\(event\.persisted&&\(state\.checkout\|\|\$\('wallet-dialog'\)\.classList\.contains\('checkout-dialog'\)\)\)closeModal\(\)/);
  assert.match(publicIndex, /window\.addEventListener\('popstate',\(\)=>\{\s*if\(state\.checkout\|\|\$\('wallet-dialog'\)\.classList\.contains\('checkout-dialog'\)\)closeModal\(\)/);
  assert.match(publicIndex, /void latePaymentRestore\.then\(\(\)=>\{if\(state\.checkout===checkout\)renderCheckout\(\)\}\)/);
  assert.match(publicIndex, /<details class="checkout-late-payment"><summary>Already paid for an expired order\? Submit UTR<\/summary>/);
  assert.match(publicIndex, /const cutoff=Date\.now\(\)-86400000/);
  assert.match(publicIndex, /checkout\.paymentOrder=null;\s*checkout\.paymentOrderSignature=null;\s*checkout\.paymentTimerExpired=false/);
  assert.match(publicIndex, /async function startNewCheckoutPayment\(checkout,expiredOrder,automatic\)/);
  assert.match(publicIndex, /data-new-payment[\s\S]*?startNewCheckoutPayment\(checkout,checkout\.paymentOrder,false\)/);
  assert.match(publicIndex, /function clearCheckoutOrderStorage\(checkout\)/);
  assert.match(publicIndex, /async function checkoutRpcWithTimeout\(request,operation\)/);
  assert.match(publicIndex, /Promise\.race\(\[request,timeout\]\)/);
  assert.match(publicIndex, /setTimeout\(\(\)=>reject\(new Error\(`\$\{operation\} timed out after 10 seconds/);
  assert.match(publicIndex, /function persistLatePaymentOrders\(checkout\)/);
  assert.match(publicIndex, /get_my_expired_payment_orders/);
  assert.match(publicIndex, /checkout\.paymentCreationFailed=true/);
  assert.match(publicIndex, /clearCheckoutOrderStorage\(checkout\);[\s\S]*?checkout\.paymentOrder=null;[\s\S]*?checkout\.paymentOrderSignature=null/);
  assert.match(publicIndex, /data\.status==='pending_verification'/);
  assert.match(publicIndex, /Time is up\. Generate a new QR to pay\./);
  assert.match(publicIndex, /p_order_id:\['unpaid','pending_payment'\]\.includes\(checkout\.paymentOrder\?\.status\)&&existingExpiry>checkoutServerNow\(checkout\)/);
  assert.match(publicIndex, /anchorCheckoutServerTime\(checkout,data\.server_now,data\.order_id\);[\s\S]*?checkout\.paymentOrder=\{\s*order_id:data\.order_id/);
  assert.match(productPaymentMigration, /v_created_at := clock_timestamp\(\);[\s\S]*?v_created_at \+ make_interval\(mins => v_timeout\)/);
  assert.match(productPaymentMigration, /payment_expires_at > clock_timestamp\(\)/);
  assert.match(softwarePlanMigration, /v_created_at := clock_timestamp\(\);[\s\S]*?v_created_at \+ make_interval\(mins => v_timeout\)/);
  assert.match(usedKeyPaymentMigration, /v_now \+ make_interval\(mins => v_timeout\)/);
  assert.match(expiryRecoveryMigration, /'created_at', o\.created_at/);
  assert.match(expiryRecoveryMigration, /and o\.status = 'expired' and o\.utr is null/);
  assert.match(apiSource, /function sendJson\(res, status, body\)\s*\{\s*res\.setHeader\('Cache-Control', 'no-store'\)/);
  assert.match(migration, /insert into public\.orders \([\s\S]*?v_now \+ make_interval\(mins => v_timeout\)/);
  assert.match(expiryRecoveryMigration, /status = 'expired', payment_status = 'rejected'[\s\S]*?payment_expires_at <= clock_timestamp\(\)/);
  assert.match(expiryRecoveryMigration, /status = 'pending_verification'/);
  assert.match(expiryRecoveryMigration, /create or replace function public\.get_my_expired_payment_orders/);
  assert.match(expiryRecoveryMigration, /'\* \* \* \* \*'/);
  assert.match(expiryRecoveryMigration, /Payment QR lifetime in minutes \(default 10\)/);
  assert.match(expiryRecoveryMigration, /Late-payment UTR grace period in minutes \(default 5\)/);
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
