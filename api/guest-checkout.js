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

function publicSiteOrigin() {
  const configuredOrigin = String(process.env.PUBLIC_SITE_URL || '').trim();
  if (configuredOrigin) {
    const url = new URL(configuredOrigin);
    if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Public site URL must use HTTP or HTTPS.');
    return url.origin;
  }
  const deploymentHost = process.env.VERCEL_PROJECT_PRODUCTION_URL || process.env.VERCEL_URL;
  if (deploymentHost) return `https://${deploymentHost.replace(/^https?:\/\//i, '')}`;
  return `http://localhost:${Number(process.env.PORT) || 3000}`;
}

function demoKeyEmail(data) {
  const name = escapeHtml(data.software_name);
  const key = escapeHtml(data.license_key);
  const link = String(data.download_link || '');
  const safeLink = /^https?:\/\/\S+$/i.test(link) ? link : '';
  return {
    subject: 'Your Tatkal X demo key is ready',
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
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const action = String(body.action || '');

    if (action === 'create_order' || action === 'claim_demo') {
      if (isRateLimited(ip)) return sendJson(res, 429, { error: 'Too many requests. Please wait a minute and try again.' });
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
        let emailSent = true;
        try {
          await sendGuestEmail({ to: email, ...demoKeyEmail(data) });
        } catch (error) {
          console.error('Guest demo was claimed but its email could not be sent:', error);
          emailSent = false;
        }
        return sendJson(res, 200, { ok: true, demo: { ...data, email_sent: emailSent } });
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
      const token = accessToken(body.access_token);
      const data = await callRpc('guest_submit_order_utr', {
        p_order_id: orderId(body.order_id),
        p_utr: String(body.utr || '').trim(),
        p_access_hash: hashAccessToken(token),
        p_ip_hash: hashGuestValue(ip)
      });
      if (!data?.ok) {
        return sendJson(res, data?.reason === 'rate_limited' ? 429 : 400, {
          error: data?.message || 'Could not submit this UTR.',
          reason: data?.reason || 'server_error',
          retry_after_seconds: data?.retry_after_seconds || 0,
          remaining_attempts: data?.remaining_attempts
        });
      }
      if (data.customer_email) {
        try {
          const trackingUrl = `${publicSiteOrigin()}/order/${encodeURIComponent(String(data.order_id))}?token=${encodeURIComponent(token)}`;
          await sendGuestEmail({
            to: data.customer_email,
            subject: 'We received your payment details',
            html: `<p>We received your payment details and will confirm shortly.</p><p>Order ID: <strong>#${escapeHtml(String(data.order_id))}</strong></p><p><a href="${escapeHtml(trackingUrl)}">Track your order</a></p><p>Verification pending? We will send the product to your email once confirmed.</p>`,
            text: `We received your payment details and will confirm shortly.\nOrder ID: #${data.order_id}\nTrack your order: ${trackingUrl}\nVerification pending? We will send the product to your email once confirmed.`
          });
        } catch (error) {
          console.error('UTR was submitted but confirmation email failed:', error);
        }
      }
      return sendJson(res, 200, { ok: true, order: data });
    }

    if (action === 'upload_screenshot') {
      const mime = String(body.mime || '');
      const base64 = String(body.screenshot_base64 || '');
      const data = await callRpc('guest_submit_payment_screenshot', {
        p_order_id: orderId(body.order_id),
        p_access_hash: hashAccessToken(accessToken(body.access_token)),
        p_screenshot_base64: base64,
        p_screenshot_mime: mime
      });
      if (!data?.ok) return sendJson(res, 400, { error: data?.message || 'Could not upload the screenshot.', reason: data?.reason || 'server_error' });
      return sendJson(res, 200, data);
    }

    if (action === 'get_order') {
      let guestOrderId;
      let accessHash;
      try {
        guestOrderId = orderId(body.order_id);
        accessHash = hashAccessToken(accessToken(body.access_token));
      } catch {
        return sendJson(res, 404, { error: 'Order could not be found.' });
      }
      const data = await callRpc('guest_get_order', {
        p_order_id: guestOrderId,
        p_access_hash: accessHash
      });
      if (!data?.ok) return sendJson(res, 404, { error: 'Order could not be found.' });
      return sendJson(res, 200, { ok: true, order: data });
    }

    if (action === 'get_orders') {
      if (!Array.isArray(body.orders) || body.orders.length > 25) {
        return sendJson(res, 400, { error: 'Guest order history request is invalid.' });
      }
      const credentials = body.orders.map(item => ({
        orderId: orderId(item?.order_id),
        accessHash: hashAccessToken(accessToken(item?.access_token))
      }));
      const results = await Promise.all(credentials.map(({ orderId: guestOrderId, accessHash }) =>
        callRpc('guest_get_order', {
          p_order_id: guestOrderId,
          p_access_hash: accessHash
        })
      ));
      return sendJson(res, 200, {
        ok: true,
        orders: results.filter(result => result?.ok)
      });
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
