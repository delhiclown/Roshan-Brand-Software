const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const homepage = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('offers trigger click is not treated as an outside-modal click', () => {
  assert.match(homepage, /function renderOffersTriggerHandler\(\)\{\s*\$\('offers-trigger'\)\?\.addEventListener\('click',\(\)=>openOffersModal\(state\.offers\)\)/);
  assert.match(homepage, /if\(!\$\(\'offers-modal\'\)\.classList\.contains\('hidden'\)[\s\S]*?!event\.target\.closest\('#offers-trigger'\)\)closeOffersModal\(\)/);
});

test('active offers open once on each page visit and include all active admin offers', () => {
  assert.match(homepage, /autoPopupOfferIds:new Set\(\)/);
  assert.match(homepage, /const unseen=state\.offers\.filter\(offer=>!state\.autoPopupOfferIds\.has\(String\(offer\.id\)\)\)/);
  assert.match(homepage, /function markOffersSeen\(offers\)\{\s*offers\.forEach\(offer=>state\.autoPopupOfferIds\.add\(String\(offer\.id\)\)\)/);
  assert.match(homepage, /\.eq\('enabled',true\)\.lte\('starts_at',now\)\.gt\('ends_at',now\)/);
  assert.doesNotMatch(homepage, /roshan-brand-seen-offers/);
});

test('offers popup stays centered on narrow mobile screens and has a close control', () => {
  assert.match(homepage, /\.offers-modal\{align-items:center;padding:10px\}/);
  assert.match(homepage, /<button class="offers-close" id="offers-close" type="button" aria-label="Close offers">×<\/button>/);
});
