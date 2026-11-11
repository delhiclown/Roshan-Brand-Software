const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'demo-keys-migration.sql'), 'utf8');
const customDemoMigration = fs.readFileSync(path.join(root, 'supabase', 'demo-custom-software-migration.sql'), 'utf8');
const notifyOrder = fs.readFileSync(path.join(root, 'api', 'notify-order.js'), 'utf8');

test('customers can claim a Google Gmail demo and view it with the software download in My Orders', () => {
  assert.match(homepage, /id="demo-keys-view"/);
  assert.match(homepage, /data-claim-demo=/);
  assert.match(homepage, /Free Demo Key/);
  assert.match(homepage, /data-buy-demo-product=/);
  assert.match(homepage, /Paid key kharido/);
  assert.match(homepage, /rpc\('claim_demo_key'/);
  assert.match(homepage, /rpc\('my_demo_keys'\)/);
  assert.match(homepage, /download_link:item\.download_link/);
  assert.match(homepage, /demo_validity_days:item\.validity_days/);
});

test('rental flow uses exact server amount, UTR verification and admin-only account assignment', () => {
  assert.match(homepage, /id="rental-software-view"/);
  assert.match(homepage, /rpc\('list_available_rental_products'\)/);
  assert.match(homepage, /rpc\('create_rental_order'/);
  assert.match(homepage, /am:amount\.toFixed\(2\)/);
  assert.match(homepage, /rpc\('submit_rental_payment_utr'/);
  assert.match(homepage, /rpc\('my_rental_orders'\)/);
  assert.match(adminHtml, /id="rental-panel"/);
  assert.match(adminHtml, /rpc\('admin_save_rental_product'/);
  assert.match(adminHtml, /rpc\('admin_add_rental_accounts'/);
  assert.match(adminHtml, /rpc\('admin_review_rental_payment'/);
  assert.match(migration, /for update skip locked/);
  assert.match(migration, /lease_until = clock_timestamp\(\) \+ interval '1 day'/);
  assert.match(migration, /extensions\.pgp_sym_encrypt\(v_account, v_encryption_key/);
  assert.match(migration, /extensions\.pgp_sym_decrypt\(a\.account_encrypted, v_encryption_key\)/);
  assert.match(migration, /a\.lease_order_id = o\.id and a\.lease_until > clock_timestamp\(\)/);
  assert.match(migration, /unique index if not exists orders_utr_number_unique_idx|payment_utr_claims/);
  assert.match(migration, /if not public\.is_store_admin\(\) then raise exception 'Admin access required'; end if;/);
});

test('admin has a separate demo-key inventory form with custom software and photo upload', () => {
  assert.match(adminHtml, /id="demo-keys-panel"/);
  assert.match(adminHtml, /id="demo-key-product"/);
  assert.match(adminHtml, /<option value="__custom__">Custom<\/option>/);
  assert.match(adminHtml, /id="demo-key-custom-name"/);
  assert.match(adminHtml, /id="demo-key-custom-image" type="file"/);
  assert.match(adminHtml, /id="demo-key-image-preview"/);
  assert.match(adminHtml, /id="demo-key-download-url" type="url"/);
  assert.match(adminHtml, /id="demo-key-value"/);
  assert.match(adminHtml, /id="demo-key-days"/);
  assert.match(adminHtml, /rpc\('admin_save_demo_key_with_link'/);
  assert.match(adminHtml, /rpc\('admin_save_custom_demo_key'/);
  assert.match(adminHtml, /rpc\('admin_list_demo_keys'\)/);
});

test('custom demo software has its own download link and stays out of the paid storefront', () => {
  assert.match(customDemoMigration, /add column if not exists demo_only boolean not null default false/);
  assert.match(customDemoMigration, /create or replace function public\.admin_save_demo_key_with_link/);
  assert.match(customDemoMigration, /create or replace function public\.admin_save_custom_demo_key/);
  assert.match(customDemoMigration, /p_image_url text default null/);
  assert.match(adminHtml, /p_image_url:imageUrl/);
  assert.match(customDemoMigration, /set image_url = p_image_url/);
  assert.match(homepage, /const USED_KEY_FALLBACK_IMAGE=['"]\/assets\/demo-key-artwork\.png['"]/);
  assert.match(homepage, /safeHttpUrl\(item\.image_url\)\|\|USED_KEY_FALLBACK_IMAGE/);
  assert.match(homepage, /Number\(item\.price\)>0\?`<button class="back"/);
  assert.match(customDemoMigration, /insert into public\.product_download_links/);
  assert.match(customDemoMigration, /'software', btrim\(p_software_name\), 'Demo-only software', 0, 0, true/);
  assert.match(customDemoMigration, /if not public\.is_store_admin\(\) then raise exception 'Admin access required'; end if;/);
  assert.match(homepage, /details,demo_only'\)\.eq\('demo_only',false\)/);
});

test('new Software products already support uploaded photos, selling price, and saved download links', () => {
  assert.match(adminHtml, /id="product-image" type="file"/);
  assert.match(adminHtml, /id="price" type="number"/);
  assert.match(adminHtml, /id="download-url" type="url"/);
  assert.match(adminHtml, /uploadProductImage\(file\)/);
  assert.match(adminHtml, /product\.image_url=await uploadProductImage\(file\)/);
  assert.match(adminHtml, /selling_price:sellingPrice/);
  assert.match(adminHtml, /from\('product_download_links'\)\.upsert/);
  assert.match(homepage, /select\('id,category,name,description,image_url,price/);
  assert.match(homepage, /class="product-image" src="\$\{escapeHtml\(imageUrl\)\}"/);
});

test('demo inventory is encrypted, Gmail claims are unique, and owner/admin boundaries are enforced server-side', () => {
  assert.match(migration, /license_key_encrypted bytea not null/);
  assert.match(migration, /extensions\.pgp_sym_encrypt/);
  assert.match(migration, /extensions\.pgp_sym_decrypt/);
  assert.match(migration, /unique \(email_normalized, product_id\)/);
  assert.match(migration, /auth\.jwt\(\)->'app_metadata'->>'provider'.*'google'/s);
  assert.match(migration, /v_email_normalized !~ '\^\[\^@\]\+@gmail\[.\]com\$'/);
  assert.match(migration, /where c\.user_id = v_user_id and c\.email_normalized = v_email/);
  assert.match(migration, /if not public\.is_store_admin\(\) then raise exception 'Admin access required'; end if;/);
  assert.match(migration, /revoke all on private\.demo_key_inventory, private\.demo_key_claims from anon, authenticated/);
});

test('all Demo and Rental admin RPCs enforce database admin authorization and private delivery ownership', () => {
  const adminFunctions = [...migration.matchAll(/create or replace function public\.admin_[a-z0-9_]+\s*\([\s\S]*?\n\$\$;/gi)];
  assert.equal(adminFunctions.length, 7);
  for (const [functionSql] of adminFunctions) {
    assert.match(functionSql, /if not public\.is_store_admin\(\) then raise exception 'Admin access required'; end if;/);
  }
  assert.match(migration, /where c\.user_id = v_user_id and c\.email_normalized = v_email/);
  assert.match(migration, /where o\.user_id = v_user_id and o\.product_type = 'rental'/);
  assert.match(homepage, /filter\(order=>order\.product_type!=='rental'\)/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(notifyOrder, /'rental'\]\.includes\(order\.product_type\)/);
  assert.match(notifyOrder, /order\.product_type === 'rental'[\s\S]*?'RENTAL SOFTWARE · 1 DAY'/);
});

test('homepage and admin inline scripts parse after Demo Keys changes', () => {
  for (const [file, html] of [['public/index.html', homepage], ['public/admin.html', adminHtml]]) {
    const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
      .map(match => match[1])
      .filter(script => script.trim());
    assert.ok(scripts.length > 0, `${file} should contain inline scripts`);
    scripts.forEach((script, index) => {
      assert.doesNotThrow(() => new vm.Script(script, { filename: `${file} inline script ${index + 1}` }));
    });
  }
});
