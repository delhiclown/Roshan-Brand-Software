const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'inventory-stock-toggle-migration.sql'), 'utf8');
const scratchRoot = path.join(root, 'supabase', 'scratch-run');

test('admin inventory cards expose independent stock toggles without replacing Hide/Show', () => {
  assert.match(adminHtml, /data-stock-toggle data-stock="\$\{product\.id\}"/);
  assert.match(adminHtml, /data-stock-toggle data-used-key-stock="\$\{item\.id\}"/);
  assert.match(adminHtml, /data-stock-toggle data-demo-stock="\$\{item\.product_id\}"/);
  assert.match(adminHtml, /data-stock-toggle data-stock="\$\{item\.product_id\}"/);
  assert.match(adminHtml, /data-toggle-used-key="\$\{item\.id\}"/);
  assert.match(adminHtml, /Mark out of stock/);
  assert.match(adminHtml, /Mark in stock/);
  assert.match(adminHtml, /Saving stock…/);
  assert.match(adminHtml, /Stock updated\./);
  assert.match(adminHtml, /setProductStock\(button\.dataset\.stock,button\.dataset\.nextStock,button\)\.catch/);
  assert.match(adminHtml, /setInventoryStock\([^)]*admin_set_used_key_stock/);
  assert.match(adminHtml, /setInventoryStock\([^)]*admin_set_demo_key_stock/);
  assert.match(adminHtml, /button\.disabled=true/);
});

test('customers see out-of-stock used, demo, rental, and regular products with purchase actions disabled', () => {
  assert.match(homepage, /in_stock:product\.in_stock!==false&&\(product\.stock_status==null\|\|product\.stock_status==='available'\)/);
  assert.match(homepage, /data-claim-demo=.*?\$\{available\?'':'disabled'\}/);
  assert.match(homepage, /data-rent-product=.*?\$\{canRent\?'':'disabled'\}/);
  assert.match(homepage, /data-buy-used-key=.*?\$\{canBuy\?'':'disabled'\}/);
  assert.match(homepage, /Out of stock/);
  assert.match(homepage, /state\.usedKeys\.filter\(item=>item\.in_stock!==false&&Number\(item\.remaining_days\)>0\)/);
});

test('new key stock fields default in stock and admin RPCs enforce database authorization', () => {
  assert.match(migration, /alter table private\.used_key_inventory\s+add column if not exists in_stock boolean not null default true/i);
  assert.match(migration, /alter table private\.demo_key_inventory\s+add column if not exists in_stock boolean not null default true/i);
  for (const fn of ['admin_set_used_key_stock', 'admin_set_demo_key_stock']) {
    const body = migration.slice(migration.indexOf(`function public.${fn}`));
    assert.match(body, /if not public\.is_store_admin\(\) then raise exception 'Admin access required'; end if;/);
    assert.match(body, /revoke all on function public\./);
    assert.match(body, /grant execute on function public\./);
  }
  assert.match(migration, /where k\.id = p_id and k\.status in \('available', 'hidden', 'reserved'\)/);
  assert.match(migration, /where i\.product_id = p_product_id/);
});

test('customer availability and checkout UTR submission recheck current stock in SQL', () => {
  assert.match(migration, /i\.in_stock and p\.in_stock/);
  assert.match(migration, /i\.in_stock\s+and\s+p\.in_stock\s+and\s+\(p\.stock_status is null or p\.stock_status = 'available'\)/);
  assert.match(migration, /k\.in_stock and k\.expiry_at > clock_timestamp\(\)/);
  assert.match(migration, /create or replace function private\.guard_order_stock_on_utr\(\)/);
  assert.match(migration, /before update of utr, utr_number on public\.orders/);
  assert.match(migration, /This Used Key is out of stock\. Choose another key\./);
  assert.match(migration, /This product is out of stock\. Please choose another product\./);
  assert.match(migration, /This rental is out of stock\. Please choose another option\./);
  assert.match(migration, /for share/);
});

test('changed RPC return shapes are dropped and re-granted before recreation', () => {
  const changedFunctions = [
    'admin_list_used_keys',
    'list_available_used_keys',
    'admin_list_demo_keys',
    'list_available_demo_keys',
    'admin_list_rental_products',
    'list_available_rental_products'
  ];
  for (const name of changedFunctions) {
    const drop = migration.indexOf(`drop function if exists public.${name}();`);
    const create = migration.indexOf(`create function public.${name}()`, drop);
    assert.ok(drop >= 0 && create > drop, `${name} must be dropped before changing its return columns`);
    assert.ok(migration.indexOf(`grant execute on function public.${name}()`) > create, `${name} must be re-granted`);
  }
});

test('scratch-run assemblies and split parts include the current stock migration', () => {
  const normalize = value => value.replace(/\r\n/g, '\n').trim();
  const source = normalize(migration);
  for (const route of ['route-A-monolithic.sql', 'route-B-split.sql']) {
    assert.ok(normalize(fs.readFileSync(path.join(scratchRoot, route), 'utf8')).includes(source), `${route} is not synchronized`);
  }
  for (const part of [
    path.join('parts-route-A', '17-inventory-stock-toggle-migration.sql'),
    path.join('parts-route-B', '20-inventory-stock-toggle-migration.sql')
  ]) {
    assert.ok(normalize(fs.readFileSync(path.join(scratchRoot, part), 'utf8')).includes(source), `${part} is not synchronized`);
  }
});
