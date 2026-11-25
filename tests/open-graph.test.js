const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

function metaContent(attribute, name) {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = homepage.match(new RegExp(`<meta\\s+${attribute}="${escapedName}"\\s+content="([^"]*)"\\s*>`, 'i'));
  assert.ok(match, `Missing ${name} metadata`);
  return match[1].replace(/&amp;/g, '&');
}

test('homepage has complete share metadata and a social-sized preview image', () => {
  const title = metaContent('property', 'og:title');
  const description = metaContent('property', 'og:description');
  assert.ok(title.length <= 60);
  assert.ok(description.length <= 150);
  assert.equal(metaContent('property', 'og:type'), 'website');
  assert.equal(metaContent('property', 'og:site_name'), 'Tatkal X');
  assert.match(title, /^Tatkal X\b/);
  assert.equal(metaContent('property', 'og:url'), 'https://tatkalx.com/');
  assert.equal(metaContent('property', 'og:image'), 'https://tatkalx.com/og-image.png');
  assert.match(homepage, /<link rel="canonical" href="https:\/\/tatkalx\.com\/">/);
  assert.equal(metaContent('name', 'twitter:card'), 'summary_large_image');
  assert.equal(metaContent('name', 'twitter:image'), 'https://tatkalx.com/og-image.png');

  const image = fs.readFileSync(path.join(root, 'public', 'og-image.png'));
  assert.equal(image.toString('hex', 0, 8), '89504e470d0a1a0a');
  assert.equal(image.readUInt32BE(16), 1200);
  assert.equal(image.readUInt32BE(20), 630);
});
