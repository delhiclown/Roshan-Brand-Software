const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const adminHtml = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const setupSql = fs.readFileSync(path.join(root, 'supabase', 'setup.sql'), 'utf8');
const usedKeysSql = fs.readFileSync(path.join(root, 'supabase', 'inventory-stock-toggle-migration.sql'), 'utf8');
const demoRentalSql = fs.readFileSync(path.join(root, 'supabase', 'demo-keys-migration.sql'), 'utf8');
const recentMigrations = fs.readdirSync(path.join(root, 'supabase', 'migrations'))
  .filter(name => /^20261121.*\.sql$/.test(name))
  .map(name => fs.readFileSync(path.join(root, 'supabase', 'migrations', name), 'utf8'));

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
  assert.match(homepage, /category\.id==='used-keys'\?'<span class="hero-category-art"/);
  assert.match(homepage, /src="\/categories\/used-keys-banner\.png"/);
  assert.match(homepage, /category\.id === 'used-keys' \? '\/categories\/used-keys-banner\.png'/);
  assert.match(homepage, /\.category\[data-collection="used-keys"\] \.category-banner-image\{object-fit:contain;background:#060b17\}/);
  assert.match(homepage, /category\.id==='demo-keys'\?'<span class="hero-category-art"/);
  assert.match(homepage, /src="\/categories\/demo-keys-banner\.png"/);
  assert.match(homepage, /category\.id === 'demo-keys' \? '\/categories\/demo-keys-banner\.png'/);
  assert.match(homepage, /\.category\[data-collection="demo-keys"\] \.category-banner-image\{object-fit:contain;background:#060b17\}/);
  assert.match(homepage, /category\.id==='rental-software'\?'<span class="hero-category-art"/);
  assert.match(homepage, /src="\/categories\/rental-software-banner\.png"/);
  assert.match(homepage, /category\.id === 'rental-software' \? '\/categories\/rental-software-banner\.png'/);
  assert.match(homepage, /\.category\[data-collection="rental-software"\] \.category-banner-image\{object-fit:contain;background:#060b17\}/);
  assert.match(homepage, /@media\(max-width:639\.98px\)\{[\s\S]*?\.hero-category-grid,\.category-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
});

test('Used Keys card count is based on live available inventory and refreshed in the background', () => {
  assert.match(homepage, /collectionRpc\('list_available_used_keys'\)/);
  assert.match(homepage, /availableCount===1\?'key':'keys'/);
  assert.match(homepage, /state\.usedKeys\.filter\(item=>item\.in_stock!==false&&Number\(item\.remaining_days\)>0\)/);
  assert.match(homepage, /data-used-keys-count/);
  assert.match(homepage, /element\.textContent=usedKeysCountLabel\(\)/);
  assert.match(homepage, /state\.usedKeys=Array\.isArray\(data\)\?data:\[\];[\s\S]*?updateUsedKeysCountBadges\(\)/);
  assert.match(homepage, /setInterval\(\(\)=>refreshUsedKeys\(\)/);
  assert.match(homepage, /refreshUsedKeys\(\)\.catch/);
});

test('all catalog RPCs time out independently and expose a Retry action on failure', () => {
  assert.match(homepage, /const COLLECTION_RPC_TIMEOUT_MS=15000/);
  assert.match(homepage, /Promise\.race\(\[[\s\S]*?state\.client\.rpc\(functionName\)[\s\S]*?setTimeout\(/);
  assert.match(homepage, /const productsRequest=requestWithTimeout\([\s\S]*?'Products query'/);
  assert.match(homepage, /const settingsRequest=requestWithTimeout\([\s\S]*?'Store settings query'/);
  assert.match(homepage, /const spinPrizesRequest=requestWithTimeout\([\s\S]*?'Spin-prize settings RPC'/);
  for (const [rpcName, handlerName] of [
    ['list_available_used_keys', 'handleUsedKeysLoadError'],
    ['list_available_demo_keys', 'handleDemoKeysLoadError'],
    ['list_available_rental_products', 'handleRentalProductsLoadError']
  ]) {
    assert.match(homepage, new RegExp(`collectionRpc\\('${rpcName}'\\)`));
    assert.match(homepage, new RegExp(`renderCollectionLoadError\\([\\s\\S]*?${handlerName}`));
  }
  assert.match(homepage, /state\.usedKeysLoading=false/);
  assert.match(homepage, /state\.demoKeysLoading=false/);
  assert.match(homepage, /state\.rentalProductsLoading=false/);
  assert.match(homepage, /data-retry-collection>Retry<\/button>/);
});

test('a pending Used Keys RPC rejects on its deadline instead of leaving Loading active forever', async () => {
  const helper = homepage.match(/const COLLECTION_RPC_TIMEOUT_MS=15000;[\s\S]*?function collectionRpc\(functionName\)\{[\s\S]*?\n    \}/);
  assert.ok(helper);
  const request = vm.runInNewContext(`${helper[0]}; collectionRpc('list_available_used_keys')`, {
    state: {client: {rpc: () => new Promise(() => {})}},
    window: {
      setTimeout: callback => { queueMicrotask(callback); return 1; },
      clearTimeout: () => {}
    }
  });
  await assert.rejects(request, /list_available_used_keys timed out after 15 seconds/);
});

test('category cards use live catalog counts and count products shown even when out of stock', () => {
  assert.match(homepage, /state\.demoKeys\.length===1\?'demo key':'demo keys'/);
  assert.match(homepage, /state\.rentalProducts\.length===1\?'rental':'rentals'/);
  assert.match(homepage, /state\.products\.filter\(product\s*=>\s*normalizeCategory\(product\.category\)\s*===\s*normalizeCategory\(category\.id\)\)\.length/);
  assert.doesNotMatch(homepage, /state\.products\.filter\(product\s*=>\s*normalizeCategory\(product\.category\)\s*===\s*normalizeCategory\(category\.id\)\s*&&\s*product\.in_stock!==false\)/);
  assert.match(homepage, /void refreshDemoKeys\(\)\.catch\(handleDemoKeysLoadError\)/);
  assert.match(homepage, /void refreshRentalProducts\(\)\.catch\(handleRentalProductsLoadError\)/);
});

test('catalog RPC grants and public product access remain configured without recent loader replacements', () => {
  assert.match(usedKeysSql, /grant execute on function public\.list_available_used_keys\(\) to anon, authenticated/i);
  assert.match(usedKeysSql, /grant execute on function public\.list_available_demo_keys\(\) to anon, authenticated/i);
  assert.match(usedKeysSql, /grant execute on function public\.list_available_rental_products\(\) to anon, authenticated/i);
  assert.match(demoRentalSql, /grant execute on function public\.list_available_demo_keys\(\) to anon, authenticated/i);
  assert.match(demoRentalSql, /grant execute on function public\.list_available_rental_products\(\) to anon, authenticated/i);
  assert.match(usedKeysSql, /create function public\.list_available_used_keys\(\)[\s\S]*?returns table\([\s\S]*?in_stock boolean[\s\S]*?\)[\s\S]*?security definer/i);
  assert.match(usedKeysSql, /create function public\.list_available_demo_keys\(\)[\s\S]*?returns table\([\s\S]*?in_stock boolean, product_in_stock boolean[\s\S]*?\)[\s\S]*?security definer/i);
  assert.match(usedKeysSql, /create function public\.list_available_rental_products\(\)[\s\S]*?returns table\([\s\S]*?available_count bigint, in_stock boolean[\s\S]*?\)[\s\S]*?security definer/i);
  assert.match(setupSql, /create policy "Anyone can read products" on public\.products[\s\S]*?for select to anon, authenticated using \(true\)/i);
  assert.match(setupSql, /grant select on public\.products, public\.settings to anon, authenticated/i);
  for (const migration of recentMigrations) {
    assert.doesNotMatch(migration, /(?:create|drop)\s+(?:or replace\s+)?function\s+public\.(?:list_available_used_keys|list_available_demo_keys|list_available_rental_products)\s*\(/i);
    assert.doesNotMatch(migration, /(?:create|drop)\s+policy[^;]*\bon\s+public\.products\b/i);
  }
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
