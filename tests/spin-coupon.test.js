const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const homepage = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');
const migration = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'spin-coupon-cooldown-migration.sql'), 'utf8');

test('copied spin coupons are marked for the customer and not restored after refresh', () => {
  assert.match(homepage, /rpc\('mark_spin_coupon_copied',\{p_coupon_code:coupon\.code\}\)/);
  assert.match(homepage, /state\.spinCoupon=null;\s*renderCouponBanner\(\)/);
  assert.match(homepage, /!coupon\.copied_at&&!copiedIds\.has\(String\(coupon\.id\)\)/);
  assert.match(migration, /add column if not exists copied_at timestamptz/);
  assert.match(migration, /create or replace function public\.mark_spin_coupon_copied/);
});

test('server allows a spin only after 24 hours have elapsed', () => {
  assert.match(migration, /created_at > clock_timestamp\(\) - interval '24 hours'/);
  assert.match(migration, /You can spin again 24 hours after your last spin\./);
});
