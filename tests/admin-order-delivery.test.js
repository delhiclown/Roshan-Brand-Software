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

test('guest delivery email uses the software name and delivery values saved on the order', async () => {
  assert.match(adminHtml, /if\(order\.guest_email\)\{\s*try\{\s*await sendGuestOrderEmail\(order\.id\)/);
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
