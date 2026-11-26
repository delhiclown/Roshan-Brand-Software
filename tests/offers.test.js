const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const homepage = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

test('offers trigger click is not treated as an outside-modal click', () => {
  assert.match(homepage, /function renderOffersTriggerHandler\(\)\{\s*\$\('offers-trigger'\)\?\.addEventListener\('click',\(\)=>openOffersModal\(state\.offers\)\)/);
  assert.match(homepage, /if\(!\$\(\'offers-modal\'\)\.classList\.contains\('hidden'\)[\s\S]*?!event\.target\.closest\('#offers-trigger'\)\)closeOffersModal\(\)/);
});

test('opening offers reveals the modal and coordinates with the official channels popup', () => {
  const openOffersModal = homepage.match(/function openOffersModal\(offers=state\.offers\)\{([\s\S]*?)\n    \}/)?.[1];
  assert.ok(openOffersModal);
  assert.match(openOffersModal, /renderOffersModal\(\);\s*\$\('offers-modal'\)\.classList\.remove\('hidden'\)/);
  assert.doesNotMatch(openOffersModal, /classList\.contains\('hidden'\)\)return/);
  assert.match(openOffersModal, /window\.dispatchEvent\(new Event\('store:offer-modal-open'\)\)/);
  assert.match(homepage, /window\.addEventListener\('store:offer-modal-open',\s*closePopup\)/);
  assert.ok(homepage.includes("if (popup.classList.contains('is-visible') || hasOfferModalOpen()) return;"));
  assert.ok(homepage.includes("if (!channelStats || popup.classList.contains('is-visible') || hasOfferModalOpen()) return;"));
});

test('active offers still load when the optional customer claim-limit column is missing', () => {
  assert.match(homepage, /function isMissingCustomerClaimLimit\(error\)\{/);
  assert.ok(homepage.includes("['42703','PGRST204'].includes(error?.code)"));
  assert.ok(homepage.includes("/\\bcustomer_claim_limit\\b/.test(error?.message||'')"));
  assert.match(homepage, /if\(isMissingCustomerClaimLimit\(error\)\)\{\s*console\.warn\([\s\S]*?\);\s*\(\{data,error\}=await activeOffersQuery\(now,false\)\);\s*\}\s*if\(error\)throw error;/);
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
