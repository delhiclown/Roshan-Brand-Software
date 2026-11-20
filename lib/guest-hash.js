const crypto = require('node:crypto');

function hashGuestValue(value) {
  const secret = process.env.GUEST_HASH_SECRET;
  if (!secret || secret.length < 32) {
    const error = new Error('GUEST_HASH_SECRET is missing or shorter than 32 characters.');
    error.code = 'GUEST_HASH_SECRET_NOT_CONFIGURED';
    throw error;
  }
  return crypto.createHmac('sha256', secret).update(String(value)).digest('hex');
}

module.exports = { hashGuestValue };
