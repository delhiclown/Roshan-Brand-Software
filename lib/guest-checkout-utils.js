const { resolveMx } = require('node:dns/promises');

const disposableDomains = new Set([
  '10minutemail.com',
  '10minutemail.net',
  '33mail.com',
  'dispostable.com',
  'emailondeck.com',
  'fakeinbox.com',
  'getnada.com',
  'guerrillamail.com',
  'inboxkitten.com',
  'maildrop.cc',
  'mailinator.com',
  'mailnesia.com',
  'mintemail.com',
  'mohmal.com',
  'mytemp.email',
  'sharklasers.com',
  'temp-mail.org',
  'tempail.com',
  'tempmail.com',
  'tempmailo.com',
  'throwawaymail.com',
  'tmpmail.net',
  'trashmail.com',
  'yopmail.com'
]);

function isDisposableDomain(domain) {
  const normalized = String(domain || '').toLowerCase().replace(/\.$/, '');
  for (const blocked of disposableDomains) {
    if (normalized === blocked || normalized.endsWith(`.${blocked}`)) return true;
  }
  return false;
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function validateEmailFormat(email) {
  const normalized = normalizeEmail(email);
  if (normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(normalized)) {
    throw new Error('Enter a valid email address.');
  }
  const domain = normalized.slice(normalized.lastIndexOf('@') + 1);
  if (isDisposableDomain(domain)) {
    throw new Error('Temporary email addresses are not allowed. Use your regular email address.');
  }
  return { email: normalized, domain };
}

async function validateEmailAddress(email, resolveMxRecords = resolveMx) {
  const normalized = validateEmailFormat(email);
  let records;
  let timer;
  try {
    records = await Promise.race([
      resolveMxRecords(normalized.domain),
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error('Email domain verification timed out.')), 4000);
      })
    ]);
  } catch (error) {
    if (error.code === 'ENODATA' || error.code === 'ENOTFOUND') {
      throw new Error('This email domain cannot receive email. Check the address and try again.');
    }
    if (error.message === 'Email domain verification timed out.') {
      throw new Error('Email domain verification is temporarily unavailable. Please try again.');
    }
    throw new Error('Email domain verification is temporarily unavailable. Please try again.');
  } finally {
    clearTimeout(timer);
  }
  if (!Array.isArray(records) || !records.some(record => record.exchange && record.exchange !== '.')) {
    throw new Error('This email domain cannot receive email. Check the address and try again.');
  }
  return normalized.email;
}

function getClientIp(req) {
  const vercelIp = req.headers['x-vercel-forwarded-for'];
  const forwardedIp = req.headers['x-forwarded-for'];
  const isVercel = Boolean(process.env.VERCEL || req.headers['x-vercel-id']);
  const value = vercelIp || (isVercel ? forwardedIp : req.socket?.remoteAddress || forwardedIp) || '';
  const ip = String(value).split(',')[0].trim();
  if (!ip || ip.length > 64 || /[\s,]/.test(ip)) throw new Error('Could not determine the request IP address.');
  return ip;
}

function validateDeviceId(value) {
  const deviceId = String(value || '').trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(deviceId)) {
    throw new Error('Could not verify this device. Reload the page and try again.');
  }
  return deviceId;
}

function validateWhatsApp(value) {
  const phone = String(value || '').trim();
  if (!phone) return '';

  if (!/^[+]?[0-9 ()-]+$/.test(phone)) {
    throw new Error('Enter a valid 10-digit Indian mobile number or leave it blank.');
  }

  const digits = phone.replace(/\D/g, '');
  let normalized = digits;
  if (digits.length === 12 && digits.startsWith('91')) normalized = digits.slice(2);
  else if (digits.length === 11 && digits.startsWith('0')) normalized = digits.slice(1);

  if (!/^[6-9][0-9]{9}$/.test(normalized)) {
    throw new Error('Enter a valid 10-digit Indian mobile number or leave it blank.');
  }
  return normalized;
}

module.exports = {
  getClientIp,
  isDisposableDomain,
  normalizeEmail,
  validateDeviceId,
  validateEmailAddress,
  validateEmailFormat,
  validateWhatsApp
};
