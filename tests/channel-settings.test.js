const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const migration = fs.readFileSync(path.join(root, 'supabase', 'channel-settings-migration.sql'), 'utf8');
const admin = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

function createResponse() {
  return {
    headers: {},
    setHeader(name, value) {
      this.headers[name] = value;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    }
  };
}

test('channel settings migration protects writes and seeds the current public defaults', () => {
  assert.match(migration, /7000/);
  assert.match(migration, /4500/);
  assert.match(migration, /whatsapp\.com\/channel\/0029Vb8dm4yD38CPjHRE440V/);
  assert.match(migration, /https:\/\/t\.me\/tatkalsoftwareservices/);
  assert.match(migration, /alter table public\.channel_settings enable row level security/i);
  assert.match(migration, /public\.is_store_admin\(\)/);
  assert.match(migration, /grant execute on function public\.admin_save_channel_settings[\s\S]*to authenticated/i);
  assert.match(admin, /id="channel-settings-form"/);
  assert.match(admin, /Follower count 7 din se update nahi hua/);
});

test('public endpoint returns only the cached channel fields and admin refresh replaces the cache', async () => {
  const endpointPath = path.join(root, 'api', 'channel-stats.js');
  delete require.cache[require.resolve(endpointPath)];
  const handler = require(endpointPath);
  const previousFetch = global.fetch;
  const previousUrl = process.env.SUPABASE_URL;
  const previousKey = process.env.SUPABASE_ANON_KEY;
  process.env.SUPABASE_URL = 'https://project.example';
  process.env.SUPABASE_ANON_KEY = 'public-test-key';
  let fetchCount = 0;
  const originalStats = {
    whatsapp_followers: 7000,
    whatsapp_link: 'https://whatsapp.com/channel/example',
    telegram_followers: 4500,
    telegram_link: 'https://t.me/example'
  };
  const updatedStats = {
    whatsapp_followers: 8100,
    whatsapp_link: 'https://whatsapp.com/channel/updated',
    telegram_followers: 4600,
    telegram_link: 'https://t.me/updated'
  };
  global.fetch = async (url, options) => {
    fetchCount++;
    const isAdmin = String(url).endsWith('/admin_get_channel_settings');
    return {
      ok: true,
      status: 200,
      async json() {
        return isAdmin ? updatedStats : originalStats;
      }
    };
  };

  try {
    const first = createResponse();
    await handler({method: 'GET', headers: {}}, first);
    assert.equal(first.statusCode, 200);
    assert.deepEqual(first.body, originalStats);
    assert.equal(first.headers['Cache-Control'], 'no-store');
    assert.equal(fetchCount, 1);

    const second = createResponse();
    await handler({method: 'GET', headers: {}}, second);
    assert.deepEqual(second.body, originalStats);
    assert.equal(fetchCount, 1);

    const refresh = createResponse();
    await handler({method: 'POST', headers: {authorization: 'Bearer admin-token'}}, refresh);
    assert.deepEqual(refresh.body, {ok: true});
    assert.equal(fetchCount, 2);

    const afterRefresh = createResponse();
    await handler({method: 'GET', headers: {}}, afterRefresh);
    assert.deepEqual(afterRefresh.body, updatedStats);
    assert.equal(fetchCount, 2);
  } finally {
    global.fetch = previousFetch;
    if (previousUrl === undefined) delete process.env.SUPABASE_URL;
    else process.env.SUPABASE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.SUPABASE_ANON_KEY;
    else process.env.SUPABASE_ANON_KEY = previousKey;
  }
});

test('homepage popup reads dynamic channel data without hardcoded member totals', () => {
  assert.match(homepage, /fetch\('\/api\/channel-stats'/);
  assert.match(homepage, /roshan-community-popup-stats/);
  assert.match(homepage, /Math\.floor\(count \/ 1000\) \* 1000/);
  assert.doesNotMatch(homepage, /7,000\+ members|4,500\+ members/);
  assert.match(homepage, /target="_blank" rel="noopener noreferrer" data-community-popup-join="whatsapp"/);
});
