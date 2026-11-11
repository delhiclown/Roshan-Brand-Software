const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');

test('homepage collection and category grids render all six requested cards in order', () => {
  const expected = ['Software', 'Used Keys', 'Rental Software', 'Demo Keys', 'Residential Proxies', 'Windows VPS'];
  const categories = homepage.match(/const categories = \[([\s\S]*?)\n    \];/);
  assert.ok(categories);
  const orderedTitles = [...categories[1].matchAll(/title:'([^']+)'/g)].map(match => match[1]);
  assert.deepEqual(orderedTitles, expected);
  assert.match(homepage, /id:'used-keys', title:'Used Keys'/);
  assert.match(homepage, /id:'rental-software', title:'Rental Software'/);
  assert.match(homepage, /id:'demo-keys', title:'Demo Keys'/);
  assert.match(homepage, /data-collection="\$\{category\.id\}"/);
  assert.match(homepage, /function openCollection\(collection\)/);
  assert.match(homepage, /'used-keys':'used-keys-view'/);
  assert.match(homepage, /'rental-software':'rental-software-view'/);
  assert.match(homepage, /'demo-keys':'demo-keys-view'/);
  assert.match(homepage, /grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/);
  assert.match(homepage, /@media\(max-width:639\.98px\)\{[\s\S]*?\.hero-category-grid,\.category-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
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

test('admin Software categories and offers restore Residential Proxies without deleting old data', () => {
  assert.match(adminHtml, /<option value="residential">Residential Proxies<\/option>/);
  assert.match(adminHtml, /const categories=\[\{id:'software',title:'Software'\},\{id:'vps',title:'Windows VPS'\},\{id:'proxy',title:'Static Proxy'\},\{id:'residential',title:'Residential Proxies'\}\]/);
  assert.doesNotMatch(adminHtml, /delete\s+from\s+(?:public\.)?products|drop\s+table\s+(?:public\.)?products/i);
});
