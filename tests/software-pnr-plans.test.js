const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const admin = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'software-pnr-plans-migration.sql'), 'utf8');
const guestMigration = fs.readFileSync(path.join(root, 'supabase', 'guest-checkout-migration.sql'), 'utf8');

test('Software storefront displays enabled plans and sends the selected plan, not a client price', () => {
  assert.match(homepage, /function availableSoftwarePlans\(product\)/);
  assert.match(homepage, /buyProduct\(product\.id,plan\.code\)/);
  assert.match(homepage, /rpc\('prepare_software_plan_payment'/);
  assert.match(homepage, /rpc\('purchase_software_plan'/);
  assert.match(homepage, /qrAmount=paymentOrder\?Number\(paymentOrder\.price\)/);
  assert.match(homepage, /p_plan_code:checkout\.softwarePlanCode/);
});

test('Software plan popup uses the custom accessible dropdown without changing plan data', () => {
  assert.doesNotMatch(homepage, /<select id="software-plan-choice">/);
  assert.doesNotMatch(homepage, /id="software-plan-message"/);
  assert.doesNotMatch(homepage, /Pehle plan chuno/);
  assert.match(homepage, /\.software-plan-list\{position:fixed;z-index:1001/);
  assert.match(homepage, /max-height:240px;overflow-y:auto/);
  assert.match(homepage, /document\.body\.appendChild\(list\)/);
  assert.match(homepage, /const below=Math\.max\(0,viewportHeight-rect\.bottom-gap\)/);
  assert.match(homepage, /const above=Math\.max\(0,rect\.top-gap\)/);
  assert.match(homepage, /const openAbove=below<fullMenuHeight&&above>below/);
  assert.match(homepage, /list\.style\.top=openAbove\?/);
  assert.match(homepage, /class="software-plan-picker modal-field"/);
  assert.match(homepage, /role="combobox"/);
  assert.match(homepage, /role="listbox"/);
  assert.match(homepage, /role="option"/);
  assert.match(homepage, /software-plan-trigger/);
  assert.match(homepage, /software-plan-arrow/);
  assert.match(homepage, /setListOpen\(false\)/);
  assert.match(homepage, /document\.addEventListener\('pointerdown',closeOnOutsideClick\)/);
  assert.match(homepage, /event\.key==='ArrowDown'/);
  assert.match(homepage, /event\.key==='ArrowUp'/);
  assert.match(homepage, /event\.key==='Escape'/);
  assert.match(homepage, /data-plan-code="\$\{plan\.code\}"/);
  assert.match(homepage, /const plan=available\.find\(item=>item\.code===selectedPlanCode\)/);
});

test('Software admin supports three editable prices, MRPs, and enable switches', () => {
  for (const plan of ['2', '4', '6']) {
    assert.match(admin, new RegExp(`id="plan-${plan}-price"`));
    assert.match(admin, new RegExp(`id="plan-${plan}-mrp"`));
    assert.match(admin, new RegExp(`id="plan-${plan}-enabled"`));
    const priceInput = admin.match(new RegExp(`<input id="plan-${plan}-price"[^>]*>`))[0];
    const mrpInput = admin.match(new RegExp(`<input id="plan-${plan}-mrp"[^>]*>`))[0];
    assert.match(priceInput, /type="number".*step="0.01"/);
    assert.match(mrpInput, /type="number".*step="0.01"/);
    assert.doesNotMatch(priceInput, /maxlength|max=/);
    assert.doesNotMatch(mrpInput, /maxlength|max=/);
  }
  assert.match(admin, /#software-plan-fields input\[type=number\]\{min-width:8em\}/);
  assert.match(admin, /@media\(max-width:1000px\)\{#software-plan-fields \.pnr-plan-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)\}\}/);
  assert.match(admin, /@media\(max-width:520px\)\{#software-plan-fields \.pnr-plan-grid\{grid-template-columns:1fr\}\}/);
  assert.match(admin, /product\[`plan_\$\{plan\}_pnr_price`\]/);
  assert.match(admin, /product\[`plan_\$\{plan\}_pnr_enabled`\]/);
  assert.match(admin, /Starting from ₹\$\{money\(softwarePlanStartingPrice\(product\)\)\}/);
});

test('Admin saves and populates each Software PNR plan independently', () => {
  for (const plan of ['2', '4', '6']) {
    assert.match(admin, new RegExp(`id="plan-${plan}-price"`));
    assert.match(admin, new RegExp(`plan_${plan}_pnr_price`));
    assert.match(admin, new RegExp(`plan_${plan}_pnr_mrp`));
    assert.match(admin, new RegExp(`plan_${plan}_pnr_enabled`));
  }
  assert.match(admin, /\$\(`plan-\$\{plan\}-price`\)\.value=product\[priceKey\]/);
  assert.match(admin, /const numericFields=new Set\(\[[\s\S]*'plan_6_pnr_price','plan_6_pnr_mrp'\]\)/);
  assert.match(admin, /plan_\$\{plan\}_pnr_enabled\`]=enabled/);
  assert.match(admin, /from\('products'\)\.update\(changedFields\)/);
});

test('Plan checkout uses plan codes and database verification without trusting a browser price', () => {
  assert.match(homepage, /p_plan_code:checkout\.softwarePlanCode/);
  assert.match(homepage, /p_product_id:product\.id,p_plan_code:checkout\.softwarePlanCode/);
  assert.doesNotMatch(homepage, /prepare_software_plan_payment[\s\S]*p_price|purchase_software_plan[\s\S]*p_price/);
  assert.match(migration, /v_plan_price := v_product\.plan_2_pnr_price/);
  assert.match(migration, /v_plan_price := v_product\.plan_4_pnr_price/);
  assert.match(migration, /v_plan_price := v_product\.plan_6_pnr_price/);
  assert.match(migration, /v_plan_price is null or v_plan_price <= 0/);
});

test('Coupon discount is calculated after the server-selected PNR plan price', () => {
  assert.match(migration, /v_discount := round\(least\([\s\S]*v_plan_price \* v_coupon\.discount_percent \/ 100/);
  assert.match(migration, /v_final := round\(greatest\(v_plan_price - v_discount, 0\), 2\)/);
  assert.match(migration, /FIRST10|RB\(100\|/);
});

test('PNR migration runs first without depending on guest columns', () => {
  assert.match(migration, /Apply first: software-pnr-plans-migration\.sql, then guest-checkout-migration\.sql/);
  assert.doesNotMatch(migration, /guest_email|guest_create_software_order/);
  assert.match(guestMigration, /create or replace function public\.guest_create_order\([\s\S]*p_plan_code text/);
});

test('PNR migration backfills legacy prices and prices authenticated checkout on the server', () => {
  assert.match(migration, /plan_2_pnr_price = coalesce\(plan_2_pnr_price, selling_price, price\)/);
  assert.match(migration, /plan_4_pnr_price = coalesce\(plan_4_pnr_price, selling_price, price\)/);
  assert.match(migration, /plan_6_pnr_price = coalesce\(plan_6_pnr_price, selling_price, price\)/);
  assert.match(migration, /create or replace function public\.prepare_software_plan_payment/);
  assert.match(migration, /create or replace function public\.purchase_software_plan/);
  assert.match(migration, /'software_plan_label', v_order\.software_plan_label/);
});

test('Admin order lists preserve live filters and append the Software plan label', () => {
  for (const source of [migration, guestMigration]) {
    assert.match(source, /software_plan_label text/);
    assert.match(source, /where o\.status not in \('unpaid', 'pending_payment', 'new'\)/);
    assert.match(source, /o\.late_payment, o\.software_plan_label/);
  }
});

test('PNR order guard only runs for paid non-free Software orders', () => {
  assert.match(migration, /when\s*\([\s\S]*new\.product_type[\s\S]*new\.payment_status = 'paid'[\s\S]*new\.used_key_id is null[\s\S]*new\.rental_product_id is null[\s\S]*new\.offer_claim_id is null[\s\S]*new\.is_offer_free[\s\S]*new\.payment_method[\s\S]*\)\s+execute function private\.guard_software_plan_order\(\)/);
  assert.match(migration, /new\.payment_status is distinct from 'paid'/);
  assert.match(migration, /if tg_op = 'UPDATE' then\s+if old\.software_plan_code is null then\s+return new;/);
});

test('PNR order RPCs append plan fields without dropping legacy return fields', () => {
  assert.match(migration, /utr text, coupon_code text,[\s\S]*original_price numeric,[\s\S]*late_payment boolean,\s+software_plan_label text/);
  assert.match(migration, /used_key_id bigint, used_key_remaining_days integer, amount numeric, utr_number text,[\s\S]*status text, total_count bigint,\s+software_plan_label text/);
  assert.match(migration, /vps_storage_gb integer,\s+used_key_id bigint, software_plan_code text, software_plan_label text/);
  assert.match(migration, /case when o\.status in \('delivered', 'completed'\) and o\.used_key_id is not null then dl\.download_url/);
});
