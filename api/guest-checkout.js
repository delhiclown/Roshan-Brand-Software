const crypto = require('node:crypto');
const {
  getClientIp,
  validateDeviceId,
  validateEmailAddress,
  validateWhatsApp
} = require('../lib/guest-checkout-utils');
const { escapeHtml, sendGuestEmail } = require('../lib/guest-mail');
const { hashGuestValue } = require('../lib/guest-hash');
const { normalizeSoftwarePlanCode } = require('../lib/software-plans');

const requestLimits = new Map();
const RATE_WINDOW_MS = 60 * 1000;
const RATE_LIMIT = 30;

function sendJson(res, status, body) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(status).json(body);
}

function isRateLimited(ip) {
  const now = Date.now();
  const current = requestLimits.get(ip);
  if (!current || current.resetAt <= now) {
    requestLimits.set(ip, { count: 1, resetAt: now + RATE_WINDOW_MS });
    return false;
  }
  current.count += 1;
  if (current.count > RATE_LIMIT) return true;
  if (requestLimits.size > 1000) {
    for (const [key, entry] of requestLimits) {
      if (entry.resetAt <= now) requestLimits.delete(key);
    }
  }
  return false;
}

function environment() {
  const url = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) throw new Error('Guest checkout database access is not configured.');
  return { url: url.replace(/\/+$/, ''), serviceRoleKey };
}

async function callRpc(functionName, parameters) {
  const { url, serviceRoleKey } = environment();
  const response = await fetch(`${url}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(parameters)
  });
  let result;
  try {
    result = await response.json();
  } catch (error) {
    throw new Error(`Guest checkout database returned HTTP ${response.status}.`);
  }
  if (!response.ok) {
    const message = String(result?.message || result?.hint || `Database request failed with HTTP ${response.status}.`).slice(0, 400);
    const error = new Error(message);
    if (result?.code) error.code = String(result.code);
    error.status = response.status;
    throw error;
  }
  return result;
}

function orderId(value) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw new Error('Order reference is invalid.');
  return id;
}

function accessToken(value) {
  const token = String(value || '');
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('Guest order access has expired. Contact support with your order number.');
  return token;
}

function hashAccessToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function demoKeyEmail(data) {
  const name = escapeHtml(data.software_name);
  const key = escapeHtml(data.license_key);
  const link = String(data.download_link || '');
  const safeLink = /^https?:\/\/\S+$/i.test(link) ? link : '';
  return {
    subject: 'Your Roshan Brand demo key is ready',
    html: `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#111827"><h2>Your free demo key is ready</h2><p>Software: <strong>${name}</strong></p><p>Demo key: <code>${key}</code></p>${safeLink ? `<p><a href="${escapeHtml(safeLink)}">Download ${name}</a></p>` : ''}<p>Keep this key private.</p></div>`,
    text: `Your free demo key is ready.\nSoftware: ${data.software_name}\nDemo key: ${data.license_key}${safeLink ? `\nDownload: ${safeLink}` : ''}`
  };
}

module.exports = async function guestCheckout(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return sendJson(res, 405, { error: 'Method not allowed.' });
  }

  let ip;
  try {
    ip = getClientIp(req);
    if (isRateLimited(ip)) return sendJson(res, 429, { error: 'Too many requests. Please wait a minute and try again.' });
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const action = String(body.action || '');

    if (action === 'create_order' || action === 'claim_demo') {
      const email = await validateEmailAddress(body.email);
      const whatsapp = validateWhatsApp(body.whatsapp);
      const deviceId = validateDeviceId(body.device_id);
      const emailHash = hashGuestValue(email);
      const deviceHash = hashGuestValue(deviceId);
      const ipHash = hashGuestValue(ip);
      const productId = Number(body.product_id);
      if (!Number.isSafeInteger(productId) || productId <= 0) throw new Error('Choose an available product.');

      if (action === 'claim_demo') {
        const data = await callRpc('guest_claim_demo_key', {
          p_product_id: productId,
          p_email: email,
          p_email_hash: emailHash,
          p_device_hash: deviceHash,
          p_ip_hash: ipHash
        });
        if (!data?.ok) return sendJson(res, 400, { error: data?.message || 'Could not claim this demo key.' });
        try {
          await sendGuestEmail({ to: email, ...demoKeyEmail(data) });
        } catch (error) {
          console.error('Guest demo was claimed but its email could not be sent:', error);
          return sendJson(res, 502, {
            error: 'Your demo key is shown on this page, but the email could not be sent. Please save the key and contact support.',
            demo: data
          });
        }
        return sendJson(res, 200, { ok: true, demo: data });
      }

      const type = String(body.type || '');
      if (!['product', 'used_key', 'rental'].includes(type)) throw new Error('This item is not available for guest checkout.');
      const accessTokenValue = crypto.randomBytes(32).toString('base64url');
      const softwarePlanCode = type === 'product'
        ? normalizeSoftwarePlanCode(body.software_plan_code)
        : null;
      const accessHash = hashAccessToken(accessTokenValue);
      const data = await callRpc('guest_create_order', {
        p_type: type,
        p_product_id: type === 'product' ? productId : null,
        p_used_key_id: type === 'used_key' ? productId : null,
        p_plan_code: softwarePlanCode,
        p_email: email,
        p_whatsapp: whatsapp,
        p_access_hash: accessHash,
        p_device_hash: deviceHash,
        p_ip_hash: ipHash
      });
      if (!data?.ok) return sendJson(res, 400, { error: data?.message || 'Could not start guest checkout.' });
      return sendJson(res, 201, { ok: true, order: data, access_token: accessTokenValue });
    }

    if (action === 'submit_utr') {
      const data = await callRpc('guest_submit_order_utr', {
        p_order_id: orderId(body.order_id),
        p_utr: String(body.utr || '').trim(),
        p_access_hash: hashAccessToken(accessToken(body.access_token)),
        p_ip_hash: hashGuestValue(ip)
      });
      if (!data?.ok) return sendJson(res, 400, { error: data?.message || 'Could not submit this UTR.' });
      return sendJson(res, 200, { ok: true, order: data });
    }

    if (action === 'get_order') {
      const data = await callRpc('guest_get_order', {
        p_order_id: orderId(body.order_id),
        p_access_hash: hashAccessToken(accessToken(body.access_token))
      });
      if (!data?.ok) return sendJson(res, 404, { error: data?.message || 'Guest order was not found.' });
      return sendJson(res, 200, { ok: true, order: data });
    }

    return sendJson(res, 400, { error: 'Unknown guest checkout action.' });
  } catch (error) {
    console.error('Guest checkout request failed:', error);
    const message = String(error?.message || '');
    const missingDatabaseFunction = ['PGRST202', '42883'].includes(String(error?.code || ''))
      || /could not find the function|function .* does not exist/i.test(message);
    const configurationFailure = error?.code === 'GUEST_HASH_SECRET_NOT_CONFIGURED'
      || /guest checkout database access is not configured/i.test(message);
    if (missingDatabaseFunction || configurationFailure) {
      return sendJson(res, 503, { error: 'Checkout is temporarily unavailable. Please contact support.' });
    }
    const status = /not configured/i.test(message) ? 503 : 400;
    return sendJson(res, status, { error: message || 'Guest checkout failed. Please try again.' });
  }
};
