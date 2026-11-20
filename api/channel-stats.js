const CACHE_DURATION_MS = 5 * 60 * 1000;

let cachedStats = null;
let cacheExpiresAt = 0;

function sendJson(res, status, body) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  return res.status(status).json(body);
}

function validHttpsUrl(value) {
  if (typeof value !== 'string') return false;
  try {
    return new URL(value).protocol === 'https:';
  } catch (error) {
    return false;
  }
}

function normalizeStats(data) {
  const whatsappFollowers = Number(data?.whatsapp_followers);
  const telegramFollowers = Number(data?.telegram_followers);
  if (!Number.isSafeInteger(whatsappFollowers) || whatsappFollowers <= 0
    || !Number.isSafeInteger(telegramFollowers) || telegramFollowers <= 0
    || !validHttpsUrl(data?.whatsapp_link) || !validHttpsUrl(data?.telegram_link)) {
    throw new Error('Channel settings returned invalid public values.');
  }
  return {
    whatsapp_followers: whatsappFollowers,
    whatsapp_link: data.whatsapp_link,
    telegram_followers: telegramFollowers,
    telegram_link: data.telegram_link
  };
}

async function callRpc(name, token) {
  const baseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!baseUrl || !anonKey) throw new Error('Supabase public API configuration is missing.');
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${token || anonKey}`,
      'Content-Type': 'application/json'
    },
    body: '{}'
  });
  let data = null;
  try {
    data = await response.json();
  } catch (error) {
    data = null;
  }
  if (!response.ok) {
    const failure = new Error(`Channel settings RPC ${name} returned HTTP ${response.status}.`);
    failure.status = response.status;
    throw failure;
  }
  return data;
}

module.exports = async function channelStats(req, res) {
  if (req.method === 'GET') {
    if (cachedStats && Date.now() < cacheExpiresAt) return sendJson(res, 200, cachedStats);
    const previousStats = cachedStats;
    try {
      cachedStats = normalizeStats(await callRpc('public_channel_stats'));
      cacheExpiresAt = Date.now() + CACHE_DURATION_MS;
      return sendJson(res, 200, cachedStats);
    } catch (error) {
      console.error('Could not refresh public channel stats:', error);
      if (previousStats) return sendJson(res, 200, previousStats);
      const status = /configuration is missing/i.test(error.message) ? 503 : 502;
      return sendJson(res, status, { error: 'Channel stats are temporarily unavailable.' });
    }
  }

  if (req.method === 'POST') {
    const token = String(req.headers.authorization || '').match(/^Bearer\s+(.+)$/i)?.[1];
    if (!token) return sendJson(res, 401, { error: 'Sign in as an admin to refresh channel stats.' });
    try {
      const settings = normalizeStats(await callRpc('admin_get_channel_settings', token));
      cachedStats = settings;
      cacheExpiresAt = Date.now() + CACHE_DURATION_MS;
      return sendJson(res, 200, { ok: true });
    } catch (error) {
      if (error.status === 401 || error.status === 403) {
        return sendJson(res, 403, { error: 'Only an authorized admin can refresh channel stats.' });
      }
      console.error('Could not refresh channel stats after admin update:', error);
      const status = /configuration is missing/i.test(error.message) ? 503 : 502;
      return sendJson(res, status, { error: 'Channel stats cache could not be refreshed.' });
    }
  }

  res.setHeader('Allow', 'GET, POST');
  return sendJson(res, 405, { error: 'Method not allowed.' });
};
