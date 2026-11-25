const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const admin = fs.readFileSync(path.join(root, 'public', 'admin.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'offer-qr-checkout-migration.sql'), 'utf8');

test('Claim opens the offer product buy flow and resumes that offer after login', () => {
  assert.match(homepage, /if\(offer\.claim_enabled\)\{\s*closeOffersModal\(\);\s*openOfferCheckout\(offer\)/);
  assert.match(homepage, /buyProduct\(product\.id,plan\.code,selectedOfferId\)/);
  assert.match(homepage, /pending_offer_checkout/);
  assert.match(homepage, /buyProduct\(pending\.productId,pending\.planCode,pending\.offerId\)/);
});

test('offer amount and quantities are computed from database product plan and offer settings', () => {
  assert.match(migration, /v_amount := round\(v_unit_price \* v_offer\.paid_quantity, 2\)/);
  assert.match(migration, /v_offer\.paid_quantity \+ v_offer\.free_quantity/);
  assert.match(migration, /insert into public\.orders\([\s\S]*offer_paid_quantity, offer_free_quantity, software_plan_code/);
  assert.match(homepage, /rpc\('prepare_offer_product_payment'/);
  assert.match(homepage, /qrAmount=paymentOrder\?Number\(paymentOrder\.price\)/);
  assert.match(homepage, /rpc\('submit_product_payment_utr'/);
});

test('offer orders stay unpaid and pending verification until admin review', () => {
  assert.match(migration, /'unpaid', 'upi_qr', 'pending'/);
  assert.match(migration, /'pending_verification', 'utr_submitted'/);
  assert.match(homepage, /'pending_verification','utr_submitted'\]\.includes\(checkout\.paymentOrder\?\.status\)/);
  assert.match(homepage, /Your UTR has been submitted\. The order will be delivered only after admin verification\./);
  assert.match(homepage, /offer_free_quantity/);
  assert.match(homepage, /'pending_verification','utr_submitted','completed','delivered','rejected','expired'/);
  assert.match(admin, /Offer: \$\{escapeHtml\(offerDetails\.offer_title/);
  assert.match(admin, /Enter exactly \$\{offerKeyCount\} license keys, one per line/);
  assert.match(admin, /suppliedKeys!==offerKeyCount/);
  assert.match(homepage, /offerDetails\.offer_title/);
  assert.match(migration, /create or replace function public\.admin_list_offer_order_details/);
});

test('per-customer claim limit is managed in Offers settings and enforced server-side', () => {
  assert.match(admin, /id="offer-customer-claim-limit"/);
  assert.match(admin, /customer_claim_limit:customerClaimLimit/);
  assert.match(migration, /customer_claim_limit integer not null default 1/);
  assert.match(migration, /v_count >= v_offer\.customer_claim_limit/);
  assert.match(migration, /You have reached the claim limit for this offer/);
});

test('UTR entry validates 12 digits and blocks duplicate submissions while pending', () => {
  assert.match(homepage, /if\(!\/\^\\d\{12\}\$\/\.test\(submittedUtr\)\)/);
  assert.match(homepage, /checkout\.submittingPayment=true;[\s\S]*?submit\.disabled=true;submit\.textContent='Submitting\.\.\.'/);
  assert.match(migration, /pending_verification/);
  assert.match(migration, /payment_expires_at/);
});
