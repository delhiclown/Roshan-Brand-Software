const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const guestOrderEmail = require('../api/guest-order-email');

const root = path.join(__dirname, '..');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const splitMigration = fs.readFileSync(path.join(root, 'supabase', 'guest-checkout-3-admin-functions.sql'), 'utf8');
const monolithicMigration = fs.readFileSync(path.join(root, 'supabase', 'guest-checkout-migration.sql'), 'utf8');
const softwareMigration = fs.readFileSync(path.join(root, 'supabase', 'software-pnr-plans-migration.sql'), 'utf8');
const orderRequestFixMigration = fs.readFileSync(
  path.join(root, 'supabase', 'migrations', '20261121190000_fix_order_requests_ambiguous_status.sql'),
  'utf8'
);
const orderDeliveryAutofillMigration = fs.readFileSync(
  path.join(root, 'supabase', 'migrations', '20261121210000_order_delivery_autofill.sql'),
  'utf8'
);
const orderDeliveryExpiryFixMigration = fs.readFileSync(
  path.join(root, 'supabase', 'migrations', '20261121220000_fix_order_delivery_expiry_column.sql'),
  'utf8'
);

test('admin order details prefer saved delivery values and fill catalog defaults', () => {
  assert.match(adminHtml, /request-software-name'\)\.value=data\.software_name\|\|data\.product_name/);
  assert.match(adminHtml, /request-download-link'\)\.value=savedDownloadLink\|\|catalogDownloadLink/);
  assert.match(adminHtml, /Custom software: enter the download link\./);
  assert.match(adminHtml, /Required field\$\{missing\.length===1\?'':'s'\}: \$\{missing\.join\(', '\)\}\./);
  assert.match(adminHtml, /rpc\(complete\?'admin_complete_order':'admin_save_order_delivery'/);

  for (const migration of [splitMigration, monolithicMigration]) {
    assert.match(migration, /where d\.product_id = v_order\.product_id and p\.category = 'software'/);
    assert.match(migration, /lower\(btrim\(p\.name\)\) = lower\(btrim\(v_order\.product_name\)\)/);
    assert.match(migration, /'catalog_download_link', coalesce\(v_catalog_download_link, ''\)/);
    assert.match(migration, /'software_name', coalesce\(nullif\(btrim\(v_delivery\.software_name\), ''\), v_order\.product_name\)/);
    assert.match(migration, /order_id, software_name, license_key_encrypted, download_link/);
  }
  assert.match(softwareMigration, /when o\.status = 'completed' then d\.software_name end/);
  assert.match(softwareMigration, /when o\.status = 'completed' then d\.download_link end/);
});

test('order request migration resolves output conflicts and classifies delivered orders as completed', () => {
  const functions = [
    'admin_list_order_requests',
    'admin_order_request_counts',
    'admin_get_request',
    'admin_review_request',
    'admin_complete_order',
    'admin_reject_order_request'
  ];
  for (const name of functions) {
    const match = orderRequestFixMigration.match(new RegExp(
      `create(?: or replace)? function public\\.${name}\\b[\\s\\S]*?as \\$\\$([\\s\\S]*?)\\$\\$;`,
      'i'
    ));
    assert.ok(match, `missing replacement function ${name}`);
    assert.match(match[1], /#variable_conflict use_column/);
  }

  assert.match(orderRequestFixMigration, /begin;\s*[\s\S]*commit;\s*$/i);
  assert.match(orderRequestFixMigration, /update public\.orders as o\s+set status = 'completed'/i);
  assert.match(orderRequestFixMigration, /o\.status in \('completed', 'delivered'\)[\s\S]*o\.delivered_at is not null/i);
  assert.match(orderRequestFixMigration, /count\(\*\) filter \(where b\.status = 'utr_submitted'\)/i);
  assert.match(orderRequestFixMigration, /count\(\*\) filter \(where b\.status = 'completed'\)/i);
  assert.match(orderRequestFixMigration, /status = case when v_download_url is null then 'pending' else 'completed' end/i);
  assert.match(orderRequestFixMigration, /status = case when p_deliver then 'completed' else o\.status end/i);
});

test('order request table displays RPC errors and renders successful request rows', () => {
  assert.match(adminHtml, /escapeHtml\(error\.message\)/);
  assert.match(adminHtml, /requests\.map\(order=>/);
  assert.match(adminHtml, /<table class="request-table">/);
});

test('order delivery defaults are editable and resettable with plan-specific link precedence', () => {
  for (const field of ['software_name', 'license_key', 'download_link']) {
    assert.match(adminHtml, new RegExp(`data-request-reset="${field}"`));
  }
  assert.match(adminHtml, /Auto-filled from product/);
  assert.match(adminHtml, /Custom software: enter the download link\./);
  assert.match(adminHtml, /software_name:order\.product_name\|\|''/);
  assert.match(adminHtml, /license_key:order\.auto_license_key\|\|''/);
  assert.match(adminHtml, /download_link:order\.catalog_download_link\|\|''/);
  assert.match(adminHtml, /auto_key_id:state\.selectedOrderRequest[\s\S]*?request-license-key'\)\.value===String\(state\.selectedOrderRequest\.auto_license_key/);
  assert.match(adminHtml, /id="plan-2-download-url"/);
  assert.match(adminHtml, /from\('product_plan_download_links'\)\.upsert/);

  assert.match(orderDeliveryAutofillMigration, /create table if not exists public\.product_plan_download_links/);
  assert.match(orderDeliveryAutofillMigration, /coalesce\(plan_link\.download_url, product_link\.download_url, ''\)/);
  assert.match(orderDeliveryAutofillMigration, /k\.software_plan_code = v_order\.software_plan_code/);
  assert.match(orderDeliveryAutofillMigration, /where k\.product_id = v_order\.product_id/);
});

test('unused keys are previews only until an atomic skip-locked approval claim', () => {
  const getRequest = orderDeliveryAutofillMigration.match(
    /create or replace function public\.admin_get_request\b[\s\S]*?as \$\$([\s\S]*?)\$\$;/i
  );
  const completeOrder = orderDeliveryAutofillMigration.match(
    /create or replace function public\.admin_complete_order\b[\s\S]*?as \$\$([\s\S]*?)\$\$;/i
  );
  assert.ok(getRequest);
  assert.ok(completeOrder);
  assert.match(getRequest[1], /order by k\.created_at, k\.id\s+limit 1/i);
  assert.doesNotMatch(getRequest[1], /update private\.used_key_inventory/i);
  assert.match(completeOrder[1], /for update(?: of k)? skip locked/i);
  assert.match(completeOrder[1], /set status = 'sold', delivered_order_id = p_order_id/i);
  assert.doesNotMatch(orderDeliveryAutofillMigration, /k\.in_stock|in_stock\s*=\s*false/i);
  assert.match(completeOrder[1], /join public\.products as p\s+on p\.id = k\.product_id and p\.in_stock/i);
  assert.match(completeOrder[1], /update public\.orders as o\s+set status = 'completed'/i);
  assert.match(completeOrder[1], /license_key_fingerprint = extensions\.hmac\(v_license, v_encryption_key, 'sha256'\)/i);
  assert.match(orderDeliveryAutofillMigration, /software_plan_code text/);
  assert.match(adminHtml, /id="used-key-plan" required/);
  assert.match(adminHtml, /p_software_plan_code:\$\('used-key-plan'\)\.value/);
  assert.match(orderDeliveryAutofillMigration, /admin_save_used_key_for_plan/);
  assert.match(orderDeliveryAutofillMigration, /admin_bulk_add_used_keys_for_plan/);
});

test('expiry fix uses the live key columns and replaces only the three affected functions', () => {
  const functionNames = [...orderDeliveryExpiryFixMigration.matchAll(
    /create or replace function public\.([a-z0-9_]+)\s*\(/gi
  )].map(match => match[1]).sort();
  assert.deepEqual(functionNames, [
    'admin_complete_order',
    'admin_get_request',
    'admin_list_used_keys_with_plan'
  ]);
  assert.match(orderDeliveryExpiryFixMigration, /^begin;/i);
  assert.match(orderDeliveryExpiryFixMigration, /commit;\s*$/i);
  assert.doesNotMatch(orderDeliveryExpiryFixMigration, /expiry_at|sold_validity_days|private\.used_key_remaining_days/i);
  assert.doesNotMatch(orderDeliveryExpiryFixMigration, /k\.in_stock/i);
  assert.match(orderDeliveryExpiryFixMigration, /k\.expires_on >= \(timezone\('Asia\/Kolkata', clock_timestamp\(\)\)\)::date/i);
  assert.match(orderDeliveryExpiryFixMigration, /greatest\(k\.expires_on - \(timezone\('Asia\/Kolkata', v_now\)\)::date, 0\)/i);
  assert.match(orderDeliveryExpiryFixMigration, /for update of k skip locked/i);
  assert.equal((orderDeliveryExpiryFixMigration.match(/#variable_conflict use_column/g) || []).length, 3);
});

test('guest delivery email uses the software name and delivery values saved on the order', async () => {
  assert.match(adminHtml, /if\(order\.guest_email\)\{\s*try\{\s*await sendGuestOrderEmail\(order\.id\)/);
  assert.match(adminHtml, /data\.guest_email\?\[\['WhatsApp',data\.guest_whatsapp\|\|'—'\]\]:\[\]/);
  assert.match(orderDeliveryExpiryFixMigration, /'guest_email', v_order\.guest_email, 'guest_whatsapp', v_order\.guest_whatsapp/);
  assert.match(splitMigration, /where o\.id = p_order_id and o\.guest_email is not null/);
  assert.match(monolithicMigration, /where o\.id = p_order_id and o\.guest_email is not null/);
  const savedEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    RESEND_FROM_EMAIL: process.env.RESEND_FROM_EMAIL
  };
  const originalFetch = global.fetch;
  const requests = [];
  process.env.SUPABASE_URL = 'https://example.supabase.co';
  process.env.SUPABASE_ANON_KEY = 'test-anon-key';
  process.env.RESEND_API_KEY = 'test-resend-key';
  process.env.RESEND_FROM_EMAIL = 'orders@example.com';
  global.fetch = async (url, options = {}) => {
    requests.push({ url: String(url), options });
    if (String(url).endsWith('/auth/v1/user')) return response(200, { id: 'admin' });
    if (String(url).endsWith('/rest/v1/rpc/admin_guest_order_delivery')) {
      return response(200, {
        ok: true,
        email_sent: false,
        order_id: 42,
        guest_email: 'customer@example.com',
        product_name: 'Catalog Name',
        software_name: 'Saved Software Name',
        license_key: 'FINAL-KEY',
        download_link: 'https://downloads.example/final.zip'
      });
    }
    if (String(url).endsWith('/emails')) return response(200, { id: 'email-1' });
    if (String(url).endsWith('/rest/v1/rpc/admin_mark_guest_order_email_sent')) return response(200, { ok: true });
    throw new Error(`Unexpected request: ${url}`);
  };

  const res = {
    statusCode: 200,
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; }
  };
  try {
    await guestOrderEmail({
      method: 'POST',
      headers: { authorization: 'Bearer test-admin-token' },
      body: { order_id: 42 }
    }, res);

    assert.equal(res.statusCode, 200);
    const email = JSON.parse(requests.find(request => request.url.endsWith('/emails')).options.body);
    assert.match(email.text, /Product: Saved Software Name/);
    assert.match(email.text, /FINAL-KEY/);
    assert.match(email.text, /https:\/\/downloads\.example\/final\.zip/);
    assert.doesNotMatch(email.text, /Product: Catalog Name/);
  } finally {
    global.fetch = originalFetch;
    for (const [key, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

function response(status, body) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}
