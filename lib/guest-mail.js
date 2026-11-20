function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  })[character]);
}

async function sendGuestEmail({ to, subject, html, text }) {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.RESEND_FROM_EMAIL;
  if (!apiKey || !from) throw new Error('Resend email settings are not configured.');

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject, html, text }),
      signal: controller.signal
    });
    const result = await response.json().catch(() => null);
    if (!response.ok || !result?.id) {
      throw new Error(`Resend could not deliver the email (HTTP ${response.status}).`);
    }
    return result.id;
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = { escapeHtml, sendGuestEmail };
