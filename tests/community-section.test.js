const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const homepage = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('homepage QR community section is removed while the separate official-channels popup remains', () => {
  assert.doesNotMatch(homepage, /id="community-section"/);
  assert.doesNotMatch(homepage, /community-qr-tile/);
  assert.match(homepage, /id="community-popup"/);
  assert.match(homepage, /Join official channels/);
});
