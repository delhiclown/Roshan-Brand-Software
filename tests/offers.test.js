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

test('offers and claim popups use a translucent blurred backdrop', () => {
  assert.match(homepage, /\.offers-modal\{[^}]*background:rgba\(0,0,0,\.45\);backdrop-filter:blur\(4px\)\}/);
  assert.match(homepage, /\.offer-claim-modal\{[^}]*background:rgba\(0,0,0,\.45\);backdrop-filter:blur\(4px\)\}/);
  assert.match(homepage, /\.offers-modal>\.orders-backdrop,.offer-claim-modal>\.orders-backdrop\{background:transparent\}/);
  assert.match(homepage, /:root\[data-theme="light"\] \.offers-modal\{background:rgba\(0,0,0,\.45\)\}/);
});

test('known and single-product offers skip product selection while multi-product offers keep it', () => {
  const checkout = homepage.match(/function openOfferCheckout\(offer\)\{([\s\S]*?)\n    \}/)?.[1];
  const claim = homepage.match(/function openOfferClaim\(offerId,existingClaim=null\)\{([\s\S]*?)\n    \}/)?.[1];
  assert.ok(checkout);
  assert.ok(claim);
  assert.match(checkout, /if\(offer\.product_id\)\{[\s\S]*?openSoftwareProduct\(product\.id\)/);
  assert.match(checkout, /if\(products\.length===1\)\{\s*openSoftwareProduct\(products\[0\]\.id\);\s*return;\s*\}/);
  assert.match(checkout, /const productId=\$\('offer-buy-product'\)\.value;[\s\S]*?openSoftwareProduct\(productId\)/);
  assert.match(claim, /const lockedProductId=offer\.product_id\|\|existingClaim\?\.product_id/);
  assert.match(claim, /eligibleProducts\.length===1\?eligibleProducts\[0\]:null/);
  assert.match(claim, /productSelect\.classList\.toggle\('hidden',Boolean\(selectedProduct\)\)/);
  assert.match(claim, /selectedProductLabel\.textContent=selectedProduct\?`Selected product: \$\{selectedProduct\.name\}`:''/);
});
