const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const adminHtml = fs.readFileSync(path.join(__dirname, '..', 'public', 'admin.html'), 'utf8');
const migration = fs.readFileSync(
  path.join(__dirname, '..', 'supabase', 'migrations', '20261126211500_admin_delete_used_key_orders.sql'),
  'utf8'
);

test('Used Key Delete is available for reserved and sold inventory items', () => {
  assert.match(adminHtml, /data-delete-used-key="\$\{item\.id\}">Delete<\/button>/);
  assert.match(adminHtml, /Delete this key and reject its pending order\?/);
  assert.match(adminHtml, /Permanently delete this sold key and all linked order records\?/);
});

test('deleting a reserved key rejects its open order and deleting a sold key removes linked records', () => {
  assert.match(migration, /if v_item\.status = 'reserved' then[\s\S]*?set status = 'rejected',\s+payment_status = 'rejected'/i);
  assert.match(migration, /elsif v_item\.status = 'sold' then[\s\S]*?delete from public\.orders as o where o\.used_key_id = p_id/i);
  assert.match(migration, /delete from private\.used_key_payment_recovery_audit as a[\s\S]*?where a\.used_key_id = p_id/i);
  assert.match(migration, /public\.is_store_admin\(\)[\s\S]*?coalesce\(current_setting\('app\.admin_used_key_delete', true\), ''\)/i);
  assert.match(migration, /where k\.id = p_id/);
});
