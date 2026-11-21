const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const homepage = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('checkout UPI URLs use trimmed, encoded parameters with a safe short note', () => {
  assert.match(homepage, /function isValidCheckoutUpiId\(value\)[\s\S]*String\(value\|\|''\)\.trim\(\)/);
  assert.match(homepage, /const qrParams=new URLSearchParams\(\{pa:upiId,pn:payee,am:qrAmount\.toFixed\(2\),cu:'INR',tn:qrNote\}\)/);
  assert.match(homepage, /\.replace\(\/\[\^A-Za-z0-9 \]\//);
  assert.match(homepage, /\.trim\(\)\.slice\(0,40\)/);
});

test('mobile checkout launches UPI apps from the click handler and provides fallbacks', () => {
  for (const scheme of ['gpay://upi/pay', 'phonepe://pay', 'paytmmp://pay', 'upi://pay']) {
    assert.ok(homepage.includes(scheme), `missing UPI scheme ${scheme}`);
  }
  assert.match(homepage, /data-upi-scheme="\$\{scheme\}"/);
  assert.match(homepage, /window\.location\.href=deepLink/);
  assert.doesNotMatch(homepage, /href="\$\{scheme\}\?\$\{qrParams\.toString\(\)\}"/);
  assert.match(homepage, /window\.setTimeout\(\(\)=>\{[\s\S]*?1500\)/);
  assert.match(homepage, /document\.visibilityState==='hidden'/);
  assert.match(homepage, /window\.addEventListener\('blur',markOpened\)/);
  assert.match(homepage, /App not found\. Copy the UPI ID or scan the QR code instead/);
  assert.match(homepage, /copy-checkout-upi-fallback/);
  assert.match(homepage, /UPI ID not configured, please use Scan QR/);
});
