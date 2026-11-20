const crypto = require('node:crypto');

function hashGuestValue(value) {
  const secret = process.env.GUEST_HASH_SECRET;
  if (!secret || secret.length < 32) throw new Error('Guest checkout privacy settings are not configured.');
  return crypto.createHmac('sha256', secret).update(String(value)).digest('hex');
}

module.exports = { hashGuestValue };
