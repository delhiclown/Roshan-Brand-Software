const { escapeHtml, sendGuestEmail } = require('../lib/guest-mail');

function sendJson(res, status, body) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(status).json(body);
}

async function jsonOrNull(response) {
  try {
    return await response.json();
  } catch (error) {
    return null;
  }
}

function deliveryEmail(order) {
  const productName = String(order.software_name || order.product_name || 'Product');
  const details = [];
  if (order.license_key) details.push(['Key / account', order.license_key]);
  if (order.download_link) details.push(['Download link', order.download_link]);
  if (order.vps_ip) details.push(['IP address', order.vps_ip]);
  if (order.vps_port) details.push(['Port', order.vps_port]);
  if (order.vps_username) details.push(['Username', order.vps_username]);
  if (order.vps_password) details.push(['Password', order.vps_password]);
  if (order.vps_storage_gb) details.push(['Storage', `${order.vps_storage_gb} GB`]);
  if (order.rental_access) details.push(['Rental access', order.rental_access]);
  const rows = details.map(([label, value]) => `<p><strong>${escapeHtml(label)}:</strong><br><code>${escapeHtml(value)}</code></p>`).join('');
  const text = [
    `Order #${order.order_id} is complete.`,
    `Product: ${productName}`,
    ...details.map(([label, value]) => `${label}: ${value}`)
  ].join('\n');
  return {
    to: order.guest_email,
    subject: `Your Roshan Brand order #${order.order_id} is ready`,
    html: `<div style="font-family:Arial,sans-serif;line-height:1.6;color:#111827"><h2>Your order is complete</h2><p>Order #${escapeHtml(order.order_id)} · ${escapeHtml(productName)}</p>${rows}<p>If you need help, share order #${escapeHtml(order.order_id)} with support.</p></div>`,
    text
  };
}

module.exports = async function guestOrderEmail(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return sendJson(res, 405, { error: 'Method not allowed.' });
  }
  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!supabaseUrl || !anonKey) return sendJson(res, 503, { error: 'Guest order email access is not configured.' });

  const token = String(req.headers.authorization || '').match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return sendJson(res, 401, { error: 'Sign in as an admin to send guest order email.' });
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const orderId = Number(body.order_id);
  if (!Number.isSafeInteger(orderId) || orderId <= 0) return sendJson(res, 400, { error: 'Order reference is invalid.' });

  try {
    const baseUrl = supabaseUrl.replace(/\/+$/, '');
    const headers = {
      apikey: anonKey,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json'
    };
    const userResponse = await fetch(`${baseUrl}/auth/v1/user`, { headers });
    if (!userResponse.ok) return sendJson(res, 401, { error: 'Your admin session has expired. Sign in again.' });

    const orderResponse = await fetch(`${baseUrl}/rest/v1/rpc/admin_guest_order_delivery`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ p_order_id: orderId })
    });
    const order = await jsonOrNull(orderResponse);
    if (!orderResponse.ok) {
      console.error('Could not read guest order delivery for email:', order);
      return sendJson(res, orderResponse.status === 401 ? 401 : 403, { error: 'Only an authorized admin can email a completed guest order.' });
    }
    if (!order?.ok) return sendJson(res, 400, { error: order?.message || 'Guest order delivery is not ready.' });
    if (order.email_sent) return sendJson(res, 200, { ok: true, already_sent: true });

    await sendGuestEmail(deliveryEmail(order));
    const markResponse = await fetch(`${baseUrl}/rest/v1/rpc/admin_mark_guest_order_email_sent`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ p_order_id: orderId })
    });
    const marked = await jsonOrNull(markResponse);
    if (!markResponse.ok || !marked?.ok) {
      throw new Error('The delivery email was sent, but its status could not be saved.');
    }
    return sendJson(res, 200, { ok: true });
  } catch (error) {
    console.error('Could not send guest order delivery email:', error);
    const status = /not configured/i.test(error.message) ? 503 : 502;
    return sendJson(res, status, { error: error.message || 'Guest order email could not be sent.' });
  }
};
