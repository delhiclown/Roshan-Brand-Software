const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const securityMigration = fs.readFileSync(
  path.join(root, 'supabase', 'security-admin-authorization-migration.sql'),
  'utf8'
);
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

test('signup accepts only name, email, and password and sends only the name as metadata', () => {
  assert.match(homepage, /id="login-name" name="name" type="text"[^>]*maxlength="100"/);
  assert.match(homepage, /data:\{full_name:fullName\}/);
  assert.doesNotMatch(homepage, /data:\{[^}]*is_admin|data:\{[^}]*role\s*:/i);
  assert.match(securityMigration, /new\.raw_user_meta_data := case[\s\S]*jsonb_build_object\('full_name', v_name\)/i);
  assert.doesNotMatch(securityMigration, /raw_user_meta_data\s*->>\s*'(?:is_admin|role)'/i);
});

test('admin membership is server-controlled and user metadata never grants admin access', () => {
  assert.match(securityMigration, /revoke all on public\.admin_users from public, anon, authenticated/i);
  assert.match(securityMigration, /grant select on public\.admin_users to authenticated/i);
  assert.match(securityMigration, /create policy "Admins can view own admin record"[\s\S]*for select to authenticated using \(id = \(select auth\.uid\(\)\)\)/i);
  assert.match(securityMigration, /admins\.id = \(select auth\.uid\(\)\)/i);
  assert.doesNotMatch(securityMigration, /insert\s+into\s+public\.admin_users/i);
});

test('every declared admin RPC requires the database-backed admin membership check', () => {
  const migrationDirectory = path.join(root, 'supabase');
  const sqlFiles = fs.readdirSync(migrationDirectory).filter(file => file.endsWith('.sql'));
  const definitions = new Map();
  for (const file of sqlFiles) {
    const sql = fs.readFileSync(path.join(migrationDirectory, file), 'utf8');
    const functionPattern = /create(?:\s+or\s+replace)?\s+function\s+([a-z0-9_.]+)\s*\([\s\S]*?\bas\s+\$\$([\s\S]*?)\$\$;/gi;
    for (const match of sql.matchAll(functionPattern)) {
      if (/\.admin_/i.test(match[1])) definitions.set(match[1].toLowerCase(), match[2]);
    }
  }
  assert.ok(definitions.size > 0, 'Expected admin RPC definitions in SQL migrations.');
  for (const [name, body] of definitions) {
    assert.match(body, /public\.is_store_admin\s*\(\s*\)/i, `${name} must verify admin membership.`);
  }
});
