const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const migrationPath = path.join(__dirname, '..', 'supabase', 'used-keys-validity-days-migration.sql');
const migration = fs.readFileSync(migrationPath, 'utf8');
const autoValidityMigration = fs.readFileSync(
  path.join(__dirname, '..', 'supabase', 'used-keys-auto-validity-migration.sql'),
  'utf8'
);
const adminHtml = fs.readFileSync(path.join(__dirname, '..', 'public', 'admin.html'), 'utf8');
const customerHtml = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('Used Keys migration qualifies ID references in database routines', () => {
  assert.match(migration, /from private\.order_delivery_secrets as s where s\.id = true/);
  assert.doesNotMatch(migration, /\bwhere\s+id\s*=/i);
  assert.doesNotMatch(migration, /\band\s+id\s*(?:<>|!=|=)/i);
  assert.match(migration, /where k\.id = p_id/);
  assert.match(migration, /other_key\.id <> p_id/);
});

test('Used Keys migration backfills duration without dropping legacy expiry or key data', () => {
  assert.match(migration, /drop function if exists public\.admin_list_used_keys\(\)/i);
  assert.match(migration, /add column if not exists validity_days integer/i);
  assert.match(migration, /add column if not exists used_key_validity_days integer/i);
  assert.match(migration, /update private\.used_key_inventory as k[\s\S]*?set validity_days =/i);
  assert.doesNotMatch(migration, /drop column[^;]*(?:expires_on|download_link|license_key)/i);
  assert.match(migration, /extensions\.pgp_sym_decrypt\(k\.license_key_encrypted/i);
});

test('Used Keys admin form sends days and uses the Software download link', () => {
  assert.match(adminHtml, /id="used-key-days" type="number"/);
  assert.doesNotMatch(adminHtml, /id="used-key-download"|id="used-key-expiry"/);
  assert.match(adminHtml, /p_validity_days:Number\(\$\('used-key-days'\)\.value\)/);
  assert.match(adminHtml, /return \{license_key,price:Number\(price\),validity_days:Number\(days\)\}/);
  assert.match(migration, /from public\.product_download_links as dl where dl\.product_id = v_product\.id/);
  assert.match(migration, /drop function if exists public\.admin_bulk_add_used_keys\(/i);
});

test('Used Key validity starts on completion and owner orders receive live links and expiry', () => {
  assert.match(migration, /new\.status = 'completed' and old\.status = 'new'/);
  assert.match(migration, /new\.used_key_expires_on\s*:=\s*\(timezone\('Asia\/Kolkata', coalesce\(new\.completed_at, clock_timestamp\(\)\)\)\)::date\s*\+\s*new\.used_key_validity_days/i);
  assert.match(migration, /left join public\.product_download_links as dl on dl\.product_id = o\.product_id/i);
  assert.match(migration, /'Remaining validity: '/);
  assert.match(customerHtml, /order\.delivery_note/);
});

test('Used Keys automatic expiry uses IST 11 AM and backfills existing inventory', () => {
  assert.match(autoValidityMigration, /add column if not exists expiry_at timestamptz/i);
  assert.match(autoValidityMigration, /where k\.expiry_at is null/i);
  assert.match(autoValidityMigration, /time '11:00'\)\s+at time zone 'Asia\/Kolkata'/i);
  assert.match(autoValidityMigration, /private\.used_key_remaining_days\(k\.expiry_at, clock_timestamp\(\)\)/i);
  assert.match(autoValidityMigration, /ceil\(extract\(epoch from \(p_expiry_at - p_now\)\) \/ 86400\)/i);
  assert.match(autoValidityMigration, /k\.expiry_at > v_now/i);
  assert.match(autoValidityMigration, /new\.used_key_remaining_days := v_remaining_days/i);
  assert.match(customerHtml, /const expired=Number\(item\.remaining_days\)<=0/);
  assert.match(customerHtml, /\$\{expired\?'disabled':''\}\>\$\{expired\?'Expired':'Buy Now'\}/);
  assert.match(adminHtml, /const expired=Number\(item\.remaining_days\)<=0&&editable/);
  assert.match(adminHtml, /const status=expired\?'Expired'/);
});
