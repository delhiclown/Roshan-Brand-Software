const test = require('node:test');
const assert = require('node:assert/strict');
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
  assert.equal(validateWhatsApp('9876543210'), '9876543210');
  assert.throws(() => validateWhatsApp('987654321'), /10-digit Indian mobile/i);
  assert.throws(() => validateWhatsApp('5876543210'), /10-digit Indian mobile/i);
  assert.throws(() => validateWhatsApp('abc9876543210'), /10-digit Indian mobile/i);

  const previousVercel = process.env.VERCEL;
  delete process.env.VERCEL;
  assert.equal(getClientIp({ headers: {}, socket: { remoteAddress: '127.0.0.1' } }), '127.0.0.1');
  process.env.VERCEL = '1';
  assert.equal(getClientIp({ headers: { 'x-forwarded-for': '203.0.113.8, 10.0.0.1' }, socket: { remoteAddress: '10.0.0.2' } }), '203.0.113.8');
  if (previousVercel === undefined) delete process.env.VERCEL;
  else process.env.VERCEL = previousVercel;
});

test('guest identity hashes are secret-keyed and do not expose the input', () => {
  const previousSecret = process.env.GUEST_HASH_SECRET;
  process.env.GUEST_HASH_SECRET = 'test-secret-with-more-than-32-characters';
  const hash = hashGuestValue('customer@example.com');
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.notEqual(hash, 'customer@example.com');
  if (previousSecret === undefined) delete process.env.GUEST_HASH_SECRET;
  else process.env.GUEST_HASH_SECRET = previousSecret;
});

test('guest checkout endpoint rejects non-POST requests without contacting Supabase', async () => {
  const res = responseRecorder();
  await guestCheckout({ method: 'GET', headers: {}, socket: {} }, res);
  assert.equal(res.statusCode, 405);
  assert.equal(res.headers.Allow, 'POST');
  assert.equal(res.body.error, 'Method not allowed.');
  assert.equal(res.headers['Cache-Control'], 'no-store');
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
