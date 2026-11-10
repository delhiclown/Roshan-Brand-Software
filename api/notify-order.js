const rateLimits = new Map();
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX_REQUESTS = 10;

function sendJson(res, status, body) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(status).json(body);
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  })[character]);
}

function plainText(value, maxLength = 200) {
  return String(value ?? '').replace(/\s+/g, ' ').trim().slice(0, maxLength);
}

function isRateLimited(req) {
  const forwardedFor = req.headers['x-forwarded-for'];
  const ip = String(forwardedFor || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  const now = Date.now();
  const current = rateLimits.get(ip);

  if (!current || current.resetAt <= now) {
    rateLimits.set(ip, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return false;
  }

  current.count += 1;
  if (current.count > RATE_LIMIT_MAX_REQUESTS) return true;

  if (rateLimits.size > 1000) {
    for (const [key, entry] of rateLimits) {
      if (entry.resetAt <= now) rateLimits.delete(key);
    }
  }
  return false;
}

async function fetchWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function responseJson(response) {
  try {
    return await response.json();
  } catch (error) {
    return null;
  }
}

function supabaseHeaders(apiKey, accessToken = apiKey) {
  return {
    apikey: apiKey,
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json'
  };
}

function formatAmount(value) {
  return new Intl.NumberFormat('en-IN', { maximumFractionDigits: 2 }).format(Number(value));
}

function formatTime(value) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) throw new Error('Order payment time is invalid.');
  return new Intl.DateTimeFormat('en-IN', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: true,
    timeZone: 'Asia/Kolkata'
  }).format(date).replace(/\b(am|pm)\b/gi, period => period.toUpperCase());
}

function createOrderMessage(order, user) {
  const metadata = user.user_metadata || {};
  const name = plainText(metadata.full_name || metadata.name || metadata.display_name);
  const email = plainText(user.email, 254);
  const customer = name && email ? `${name} / ${email}` : name || email || 'Customer';
  const product = plainText(order.product_name);
  const type = order.product_type === 'vps' || order.product_type === 'windows-vps'
    ? 'Windows VPS'
    : 'Software';
  const quantity = Math.max(1, Number.parseInt(order.quantity, 10) || 1);
  const amount = Number(order.amount ?? order.price);
  const utr = String(order.utr_number || order.utr || '').trim();
  const paidAt = order.payment_submitted_at || order.utr_submitted_at || order.created_at;

  if (!product || !Number.isFinite(amount) || !/^\d{12}$/.test(utr)) {
    throw new Error('Order is missing alert details.');
  }

  return [
    '🛒 <b>NEW ORDER REQUEST</b>',
    '',
    `Order ID: #${escapeHtml(order.id)}`,
    `Customer: ${escapeHtml(customer)}`,
    `Product: ${escapeHtml(product)}`,
    `Type: ${type}`,
    `Quantity: ${quantity}`,
    `Amount: ₹${formatAmount(amount)}`,
    `UTR: ${escapeHtml(utr)}`,
    `Time: ${escapeHtml(formatTime(paidAt))}`
  ].join('\n');
}

async function sendTelegramMessage(message) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;
  if (!token || !chatId) throw new Error('Telegram bot environment variables are not configured.');

  const response = await fetchWithTimeout(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: message, parse_mode: 'HTML' })
  });
  const result = await responseJson(response);
  if (!response.ok || result?.ok !== true) {
    throw new Error(`Telegram sendMessage failed with status ${response.status}.`);
  }
}

module.exports = async function notifyOrder(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return sendJson(res, 405, { error: 'Method not allowed.' });
  }
  if (isRateLimited(req)) return sendJson(res, 429, { error: 'Too many requests.' });

  const telegramReady = process.env.TELEGRAM_BOT_TOKEN && process.env.TELEGRAM_CHAT_ID;
  if (!telegramReady) return sendJson(res, 503, { error: 'Telegram alerts are not configured.' });

  const body = req.body && typeof req.body === 'object' ? req.body : {};
  if (body.test === true) {
    const expectedSecret = process.env.TELEGRAM_TEST_SECRET;
    const suppliedSecret = req.headers['x-telegram-test-secret'];
    if (!expectedSecret || suppliedSecret !== expectedSecret) {
      return sendJson(res, 401, { error: 'Unauthorized.' });
    }
    try {
      await sendTelegramMessage('✅ <b>Roshan Admin Alerts test</b>\nTelegram alerts are configured.');
      return sendJson(res, 200, { ok: true });
    } catch (error) {
      console.error('Telegram test message failed:', error);
      return sendJson(res, 502, { error: 'Telegram test message failed.' });
    }
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return sendJson(res, 503, { error: 'Order alert database access is not configured.' });
  }

  const authorization = req.headers.authorization || '';
  const accessToken = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) return sendJson(res, 401, { error: 'Sign in required.' });

  const orderId = String(body.order_id ?? '');
  if (!/^[1-9]\d{0,17}$/.test(orderId)) {
    return sendJson(res, 400, { error: 'A valid order ID is required.' });
  }

  try {
    // Validate the caller's session before looking up an order.
    const userResponse = await fetchWithTimeout(`${supabaseUrl}/auth/v1/user`, {
      headers: supabaseHeaders(anonKey, accessToken)
    });
    if (!userResponse.ok) return sendJson(res, 401, { error: 'Sign in required.' });
    const user = await responseJson(userResponse);
    if (!user?.id) return sendJson(res, 401, { error: 'Sign in required.' });

    // Read all alert details from Supabase; client-supplied order details are ignored.
    const orderQuery = new URLSearchParams({
      select: 'id,user_id,product_name,product_type,quantity,price,amount,utr,utr_number,created_at,payment_submitted_at,utr_submitted_at',
      id: `eq.${orderId}`,
      user_id: `eq.${user.id}`,
      status: 'eq.new',
      limit: '1'
    });
    const orderResponse = await fetchWithTimeout(
      `${supabaseUrl}/rest/v1/orders?${orderQuery}`,
      { headers: supabaseHeaders(serviceRoleKey) }
    );
    if (!orderResponse.ok) throw new Error(`Supabase order lookup failed with status ${orderResponse.status}.`);
    const orders = await responseJson(orderResponse);
    const order = Array.isArray(orders) ? orders[0] : null;
    if (!order) return sendJson(res, 409, { error: 'Order is not eligible for an alert.' });
    if (!['software', 'vps', 'windows-vps'].includes(order.product_type)) {
      return sendJson(res, 409, { error: 'Order type is not eligible for an alert.' });
    }
    if (!/^\d{12}$/.test(String(order.utr_number || order.utr || '').trim())) {
      return sendJson(res, 409, { error: 'Order has no valid submitted UTR.' });
    }
    const message = createOrderMessage(order, user);

    // The unique order_id claim prevents retries and concurrent calls from sending duplicates.
    const claimResponse = await fetchWithTimeout(`${supabaseUrl}/rest/v1/telegram_order_alerts`, {
      method: 'POST',
      headers: { ...supabaseHeaders(serviceRoleKey), Prefer: 'return=minimal' },
      body: JSON.stringify({ order_id: order.id })
    });
    if (claimResponse.status === 409) return sendJson(res, 200, { ok: true, duplicate: true });
    if (!claimResponse.ok) {
      const claimError = await responseJson(claimResponse);
      throw new Error(`Could not claim order alert (${claimResponse.status}): ${claimError?.message || 'database error'}`);
    }

    try {
      await sendTelegramMessage(message);
      const updateResponse = await fetchWithTimeout(
        `${supabaseUrl}/rest/v1/telegram_order_alerts?order_id=eq.${order.id}`,
        {
          method: 'PATCH',
          headers: { ...supabaseHeaders(serviceRoleKey), Prefer: 'return=minimal' },
          body: JSON.stringify({ sent_at: new Date().toISOString(), error: null })
        }
      );
      if (!updateResponse.ok) {
        console.error(`Telegram alert sent, but its status could not be recorded for order #${order.id}.`);
      }
      return sendJson(res, 200, { ok: true });
    } catch (error) {
      console.error(`Telegram alert failed for order #${order.id}:`, error);
      const updateResponse = await fetchWithTimeout(
        `${supabaseUrl}/rest/v1/telegram_order_alerts?order_id=eq.${order.id}`,
        {
          method: 'PATCH',
          headers: { ...supabaseHeaders(serviceRoleKey), Prefer: 'return=minimal' },
          body: JSON.stringify({ error: String(error.message || error).slice(0, 500) })
        }
      ).catch(updateError => {
        console.error(`Could not record Telegram failure for order #${order.id}:`, updateError);
        return null;
      });
      if (updateResponse && !updateResponse.ok) {
        console.error(`Could not record Telegram failure for order #${order.id}; status ${updateResponse.status}.`);
      }
      return sendJson(res, 502, { error: 'Telegram alert could not be sent.' });
    }
  } catch (error) {
    console.error('Order alert request failed:', error);
    return sendJson(res, 500, { error: 'Order alert could not be processed.' });
  }
};
