const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const homepage = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const utrMigration = fs.readFileSync(
  path.join(root, 'supabase', 'migrations', '20261121230000_idempotent_checkout_utr_status.sql'),
  'utf8'
);

test('checkout fits mobile viewports and keeps its form scrollable above safe areas', () => {
  assert.match(homepage, /<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">/);
  assert.match(homepage, /\*\{box-sizing:border-box\}/);
  assert.match(homepage, /\.checkout-dialog\{[^}]*max-width:100%;min-width:0;max-height:100dvh;overflow-x:hidden;overflow-y:auto;[^}]*-webkit-overflow-scrolling:touch/);
  assert.match(homepage, /max-height:calc\(100dvh - max\(8px,env\(safe-area-inset-top,0px\)\) - max\(8px,env\(safe-area-inset-bottom,0px\)\)\)/);
  assert.match(homepage, /#wallet-modal \.dialog\.checkout-dialog\{[^}]*max-height:calc\(100dvh - max\(8px,env\(safe-area-inset-top,0px\)\)\)/);
  assert.match(homepage, /\.checkout-tabs\{[^}]*auto-fit[^}]*min\(100%,110px\)/);
  assert.match(homepage, /\.checkout-dialog input\{font-size:16px\}/);
});

test('guest payment controls use concise screenshot text and center the UTR submit button responsively', () => {
  assert.match(homepage, /guest-order-submit[^}]*width:min\(100%,260px\);margin:12px auto 0;text-align:center/);
  assert.match(homepage, /class="modal-primary guest-order-submit" id="guest-order-submit"[^>]*>Submit UTR for review<\/button>/);
  assert.match(homepage, /id="guest-upload-screenshot" type="button">Upload screenshot<\/button>/);
  assert.doesNotMatch(homepage, /Upload screenshot for manual verification/);
});

test('UTR submission has visible progress, clear success and duplicate states, and logs RPC errors', () => {
  assert.match(homepage, /inputmode="numeric" autocomplete="off" maxlength="12" pattern="\[0-9\]\{12\}"/);
  assert.match(homepage, /checkout\.submittingPayment=true;[\s\S]*?submit\.disabled=true;submit\.textContent='Submitting\.\.\.'/);
  assert.match(homepage, /checkoutRpcWithTimeout\(state\.client\.rpc\('submit_product_payment_utr'[\s\S]*?'UTR submission'\)/);
  assert.match(homepage, /Your UTR has been submitted\. Please wait for verification\./);
  assert.match(homepage, /Please wait, your UTR is already submitted\./);
  assert.match(homepage, /console\.error\('Could not submit checkout UTR:',error\)/);
  assert.match(homepage, /orders-utr-submitted/);
});

test('UTR RPC locks and returns a distinct already-submitted result for the same order', () => {
  assert.match(utrMigration, /select o\.\* into v_order from public\.orders as o[\s\S]*?for update;/);
  assert.match(utrMigration, /if v_order\.utr is not null or v_order\.utr_number is not null then[\s\S]*?'reason', 'already_submitted'[\s\S]*?'message', 'Please wait, your UTR is already submitted\.'/);
  assert.match(utrMigration, /'status', 'pending_verification'/);
});

test('all checkout app buttons use same-sized local SVG badges', () => {
  assert.equal((homepage.match(/class="checkout-app-logo"/g) || []).length, 4);
  assert.match(homepage, /\['PhonePe','phonepe:\/\/pay','<svg class="checkout-app-logo"/);
  assert.match(homepage, /\.checkout-app-logo\{width:24px;height:24px;flex:none;border-radius:50%\}/);
  assert.match(homepage, /\.checkout-app-links button\{width:100%;min-height:48px/);
});
