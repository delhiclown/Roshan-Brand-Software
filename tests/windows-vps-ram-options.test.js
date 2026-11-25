const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const admin = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const tracking = fs.readFileSync(path.join(root, 'public', 'order.html'), 'utf8');
const api = fs.readFileSync(path.join(root, 'api', 'guest-checkout.js'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'windows-vps-ram-options-migration.sql'), 'utf8');

test('Windows VPS admin edits each RAM rate and availability independently', () => {
  assert.match(admin, /id="windows-vps-options-fields"/);
  assert.ok(admin.includes("const isWindowsVps=isVps&&$('os-type').value==='Windows'"));
  for (const ram of ['4', '8', '16', '32']) {
    assert.match(admin, new RegExp(`id="windows-vps-${ram}-price"`));
    assert.match(admin, new RegExp(`id="windows-vps-${ram}-enabled"`));
  }
  assert.match(admin, /product\.windows_vps_options=isWindowsVps\?windowsVpsOptions:null/);
  assert.match(admin, /JSON\.stringify\(value\)!==JSON\.stringify\(existing\[key\]\?\?null\)/);
});

test('Windows VPS customers choose an enabled RAM option before checkout', () => {
  assert.match(homepage, /const windowsVpsRamOptions=\[4,8,16,32\]/);
  assert.match(homepage, /function availableWindowsVpsPlans\(product\)/);
  assert.match(homepage, /function openWindowsVpsOptions\(productId\)/);
  assert.match(homepage, /select\('[^']*windows_vps_options/);
  assert.match(homepage, /data-windows-vps-plan="\$\{plan\.code\}"/);
  assert.match(homepage, /buyProduct\(product\.id,plan\.code\)/);
  assert.match(homepage, /prepare_windows_vps_payment/);
  assert.match(homepage, /purchase_windows_vps/);
  assert.match(tracking, /addDeliveryRow\('VPS configuration', order\.software_plan_label/);
});

test('Windows VPS order prices and availability are checked in the database', () => {
  assert.match(migration, /add column if not exists windows_vps_options jsonb/);
  assert.match(migration, /create or replace function public\.prepare_windows_vps_payment/);
  assert.match(migration, /create or replace function public\.purchase_windows_vps/);
  assert.match(migration, /create or replace function public\.guest_create_windows_vps_order/);
  assert.match(migration, /option->>'enabled' = 'true'/);
  assert.match(migration, /v_plan_price := \(v_option->>'price'\)::numeric/);
  assert.match(api, /guest_create_windows_vps_order/);
  assert.match(migration, /revoke all on function public\.guest_create_windows_vps_order[\s\S]*from public, anon, authenticated/);
});
