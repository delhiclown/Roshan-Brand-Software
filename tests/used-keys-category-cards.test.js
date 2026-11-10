const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');

test('Used Keys replaces the fourth customer category card and opens its section', () => {
  assert.match(homepage, /const categories = \[\s*\{id:'software'[\s\S]*?\{id:'proxy'[\s\S]*?\];/);
  assert.doesNotMatch(homepage, /\{id:'residential', title:'Residential Proxies'/);
  assert.match(homepage, /data-used-keys-collection/);
  assert.match(homepage, /navigateSection\('used-keys-view'\)/);
  assert.match(homepage, /<strong class="title-premium">Used Keys<\/strong>/);
  assert.match(homepage, /<h3 class="title-premium">Used Keys/);
});

test('Used Keys card count is based on live available inventory and refreshed in the background', () => {
  assert.match(homepage, /rpc\('list_available_used_keys'\)/);
  assert.match(homepage, /state\.usedKeys\.length===1\?'key':'keys'/);
  assert.match(homepage, /data-used-keys-count/);
  assert.match(homepage, /element\.textContent=usedKeysCountLabel\(\)/);
  assert.match(homepage, /state\.usedKeys=Array\.isArray\(data\)\?data:\[\];[\s\S]*?updateUsedKeysCountBadges\(\)/);
  assert.match(homepage, /setInterval\(\(\)=>refreshUsedKeys\(\)/);
  assert.match(homepage, /refreshUsedKeys\(\)\.catch/);
});

test('top navigation omits Used Keys while preserving the other navigation items', () => {
  const nav = homepage.match(/<nav class="main-nav"[\s\S]*?<\/nav>/);
  const mobileNav = homepage.match(/<nav class="mobile-drawer-panel"[\s\S]*?<\/nav>/);
  assert.ok(nav);
  assert.ok(mobileNav);
  for (const markup of [nav[0], mobileNav[0]]) {
    assert.doesNotMatch(markup, />Used Keys<\/a>/);
    assert.match(markup, />Software<\/a>/);
    assert.match(markup, />Why Us<\/a>/);
    assert.match(markup, />Spin &amp; Win<\/a>/);
    assert.match(markup, />Track Order<\/a>/);
  }
});

test('admin category and offer controls hide Residential Proxies without database deletion', () => {
  assert.doesNotMatch(adminHtml, /<option value="residential">Residential Proxies<\/option>/);
  assert.match(adminHtml, /const categories=\[\{id:'software',title:'Software'\},\{id:'vps',title:'Windows VPS'\},\{id:'proxy',title:'Static Proxy'\}\]/);
  assert.doesNotMatch(adminHtml, /delete\s+from\s+(?:public\.)?products|drop\s+table\s+(?:public\.)?products/i);
});
