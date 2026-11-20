# Roshan Brand digital store

Responsive storefront with Google customer sign-in, wallet and UPI product checkout, and an email/password admin dashboard at `/admin`.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run [`supabase/setup.sql`](./supabase/setup.sql). You can rerun it to restore missing Software seed products, add product photo/download and VPS/proxy plan fields, and apply timed offers, claim review, payment, free-item transfer, audit, wallet, UPI order verification, UTR uniqueness, settings, and delivery schema/RPCs.
3. Fill in `.env.local` using the blank, commented template in that file. The local server loads `.env.local` first and then `.env`; Vercel uses its project Environment Variables. Guest checkout and server-side alert/email functions also need server-only credentials; never expose or commit their values.
4. In Supabase Authentication, enable the Google provider for customers and configure its Google OAuth client. Add the Supabase callback URL shown in the provider setup to your Google OAuth client's authorized redirect URIs. Add `http://localhost:3000` and your deployed store URL to Supabase's allowed redirect URLs.
5. In Supabase Authentication, create your admin account with the email and password you will use to sign in. Confirm the email if email confirmation is enabled.
6. Add that user's UUID and email to `public.admin_users` using the SQL Editor:

   ```sql
   insert into public.admin_users (id, email)
   values ('AUTH_USER_UUID', 'you@example.com');
   ```

   Find the UUID in **Authentication → Users**. Only accounts listed in this table are authorized to administer the store. Keep database access to this table restricted to the Supabase dashboard/SQL Editor.
7. Run `npm install`, then `npm start`; open `http://localhost:3000` or `http://localhost:3000/admin`.
8. Sign in at `/admin`, open **Settings → Payment settings**, and set your UPI ID and payee name, upload an optional PNG/JPG/WebP QR image, and enable the payment methods you accept. QR image uploads are public-read so customers can load them; only authenticated store admins can upload or change them. Checkout generates exact-amount QR codes from the saved UPI ID and payee settings.

Products and store settings are public-read. Customers can only read their own wallet, transactions, top-up requests, orders, and coupons. Wallet balances and coupon records cannot be changed through direct table writes: purchases, spin results, coupon validation, top-up approvals, refunds, and admin adjustments run through Supabase RPC functions. Coupons apply only to QR/UPI payments; wallet purchases continue to charge the full product price through the existing wallet RPC. Product and rental payment UTRs must be 12 digits; wallet top-up UTRs accept 6 to 64 characters. UTRs cannot be reused across product payments or wallet top-ups. Admins can approve or reject pending UPI product orders.

Product selling price, optional MRP, rating, review count, sold count, and stats visibility are editable in the admin product form. The selling price is saved to both `selling_price` and the existing checkout `price` field. For an existing database, run [`supabase/product-pricing-stats-migration.sql`](./supabase/product-pricing-stats-migration.sql) in the Supabase SQL Editor; it backfills `selling_price` from `price` and leaves product prices unchanged. Fresh installs also get these columns from `supabase/setup.sql`.

For UPI product-payment countdowns and late UTR review, run [`supabase/product-payment-expiry-migration.sql`](./supabase/product-payment-expiry-migration.sql) in the Supabase SQL Editor after `setup.sql`. It creates payment orders before the customer pays, enforces UTR validation/uniqueness and expiry server-side, and schedules expiration every minute when `pg_cron` is available. The singleton `public.payment_timer_config` row defaults to a 10-minute payment window and a 5-minute grace period; configure it in the SQL Editor. If `pg_cron` is unavailable, schedule `public.expire_pending_product_payments()` to run every minute. Wallet payments remain immediate.

For database-backed coupons, run [`supabase/checkout-coupon-migration.sql`](./supabase/checkout-coupon-migration.sql) in the Supabase SQL Editor after the payment-expiry migration. It creates customer-owned coupon records, server-selected Spin & Win prizes (one spin per user per UTC day), coupon validation limits, and database-backed admin prize settings. For QR/UPI orders, the server calculates the final amount from the product price and the coupon record. Wallet purchases remain full-price through the existing wallet RPC. A coupon is reserved when a payment order is created, released after a rejected UPI payment or an unpaid order's grace period, and remains consumed after a successful purchase. Legacy coupons saved in browser storage are not trusted or transferable; the storefront clears them and displays a one-time notice.

## Order Requests

For UTR-verified Software and VPS requests, run [`supabase/order-requests-migration.sql`](./supabase/order-requests-migration.sql) after `setup.sql`, `product-payment-expiry-migration.sql`, and `checkout-coupon-migration.sql` (in that order). It adds the `unpaid` → `new` → `completed` / `rejected` lifecycle, amount/UTR/payment/completion timestamps, a private `order_delivery` table, admin-only list/detail/save/complete/reject RPCs, customer-owned order delivery, UTR rate limiting, and a database-generated encryption key. License keys and VPS passwords are encrypted with AES-256 before they are stored; only the admin detail RPC and the owning customer’s completed-order RPC decrypt them. Do not delete `private.order_delivery_secrets`; losing that key makes saved credentials unrecoverable. Unpaid and pending-payment orders are hidden from admins; eligible new requests with a UTR appear under **Order Requests**.

### Used Keys

After `setup.sql` and `order-requests-migration.sql` are installed, run [`supabase/security-admin-authorization-migration.sql`](./supabase/security-admin-authorization-migration.sql). It allowlists email-signup metadata to the customer's name, keeps admin membership in the server-managed `admin_users` table, and removes client write access to that table. Admin RPCs must continue to verify `public.is_store_admin()` on the database.

After `order-requests-migration.sql`, run [`supabase/used-keys-migration.sql`](./supabase/used-keys-migration.sql) in the Supabase SQL Editor. It creates private encrypted key inventory and admin-only management RPCs, server-priced UPI QR payment orders, UTR-time stock reservation, rejection release, and completed-owner-only delivery. The storefront hides expired, hidden, reserved, and sold stock. No coupon value is accepted for these orders, and the database rejects attempts to change their price or attach a coupon. The license key inventory uses AES-256 encryption and a keyed duplicate fingerprint; back up `private.order_delivery_secrets` securely.

After that, run [`supabase/used-keys-live-products-migration.sql`](./supabase/used-keys-live-products-migration.sql). Used Keys cards read the current Software name and image from the linked product, while order lists/details and completed customer orders read the current name. Product photo/name edits carry through without a separate Used Key upload or copy.

Run [`supabase/used-keys-multi-key-migration.sql`](./supabase/used-keys-multi-key-migration.sql) after the live-products migration to enable explicit hidden status, per-key bulk details, and key IDs in Order Requests.

Then run [`supabase/used-keys-validity-days-migration.sql`](./supabase/used-keys-validity-days-migration.sql). It preserves existing inventory and encrypted key data, fixes ambiguous ID references, and stores each key’s total validity in days. New and bulk-added keys use the selected Software product’s current Download Link; no per-key link is needed.

For Used Keys inventory countdowns, then run [`supabase/used-keys-auto-validity-migration.sql`](./supabase/used-keys-auto-validity-migration.sql) and [`supabase/used-keys-sold-validity-migration.sql`](./supabase/used-keys-sold-validity-migration.sql). These calculate unsold remaining days from `expiry_at` at 11:00 AM Asia/Kolkata and freeze `sold_validity_days` when a key is sold. Finally, run [`supabase/used-keys-legacy-expiry-cutover-migration.sql`](./supabase/used-keys-legacy-expiry-cutover-migration.sql) once to preserve legacy unsold keys’ current remaining days from `expires_on`; its migration marker prevents resetting the countdown if it is run again.

### Demo Keys

After [`supabase/demo-keys-migration.sql`](./supabase/demo-keys-migration.sql), run [`supabase/demo-custom-software-migration.sql`](./supabase/demo-custom-software-migration.sql) in the Supabase SQL Editor. In **Admin → Demo Keys**, choose an existing Software product or select **Custom** to enter a demo-only software name. Add that demo's own download link, key, and optional photo; custom demo-only entries are excluded from the paid Software storefront and use the supplied key artwork when no photo is set.

### Software PNR plans

After the guest-checkout prerequisites above except guest checkout itself, run [`supabase/software-pnr-plans-migration.sql`](./supabase/software-pnr-plans-migration.sql) before installing guest checkout. The guest checkout migration depends on the plan columns created here. It adds 2, 4, and 6 PNR / 30-day prices, optional per-plan MRP, and per-plan availability switches. Existing Software prices are copied into all three plans; no products or orders are deleted. In **Admin → Software**, edit each plan's rate and availability. New Software products also need at least one enabled plan with a price. The storefront displays the lowest enabled price and collects the selected plan before checkout.

Signed-in UPI and wallet purchases, plus guest UPI checkout, read the selected plan's amount from the database. Orders retain the plan label and price snapshot; admin order lists show the selected plan, and existing payment verification and key-delivery controls remain in place.

### Guest checkout and delivery

After the setup, order-request, Used Key, Rental, Demo Key, and Software PNR prerequisites above, install guest checkout using **one** of these alternatives:

- Run [`supabase/guest-checkout-migration.sql`](./supabase/guest-checkout-migration.sql) once as the monolithic migration; or
- Run [`supabase/guest-checkout-1-tables-trigger.sql`](./supabase/guest-checkout-1-tables-trigger.sql), [`supabase/guest-checkout-2-guest-functions.sql`](./supabase/guest-checkout-2-guest-functions.sql), [`supabase/guest-checkout-3-admin-functions.sql`](./supabase/guest-checkout-3-admin-functions.sql), and [`supabase/guest-checkout-4-reject-refund-grants.sql`](./supabase/guest-checkout-4-reject-refund-grants.sql) in that order.

Do not run both alternatives as part of a fresh install: they install overlapping functions and schema changes. The split files are explicitly intended to be run once, in order, after a backup. Guest checkout makes account ownership nullable only for explicitly marked guest orders, adds private token-protected order lookups, extends the existing admin verification flow to guest and other paid product orders, and adds one-per-day Demo Key claim limits by email, device, and IP. Demo email addresses are checked for a deliverable MX domain and common disposable providers.

Configure these server-only values in `.env` for local use and in each Vercel environment:

- `GUEST_HASH_SECRET`: a randomly generated secret with at least 32 characters. It is used to HMAC email, device, and IP identifiers before storing demo-abuse records. If it is missing or too short, the server logs the configuration reason and customers see “Checkout is temporarily unavailable. Please contact support.”
- `RESEND_API_KEY`: an API key from Resend.
- `RESEND_FROM_EMAIL`: a sender address verified in Resend, for example `Roshan Brand <orders@your-verified-domain.example>`.
- `SUPABASE_SERVICE_ROLE_KEY`: required by the guest API and must remain server-only.

Guest orders use UPI QR and UTR review; the guest receives delivery on screen and by Resend after an admin completes the order. Free guest demos do not require a UTR and are sent after the daily eligibility checks. If an order email fails, the admin panel shows a retry action; the order remains recorded. Do not send the service-role key, Resend key, or hash secret to the browser.

On the Login form, **Remember me** is unchecked by default. Without it, the auth session is stored for the current browser session; with it, the saved session expires after 30 days. Registration uses Full Name, Email, and Password (minimum 6 characters).

### Official channel popup settings

After the other required migrations, run [`supabase/channel-settings-migration.sql`](./supabase/channel-settings-migration.sql) in the Supabase SQL Editor. It seeds WhatsApp at 7,000 followers and Telegram at 4,500 with the existing channel links. In **Admin → Settings → Channel Settings**, update each positive whole-number follower count and its HTTPS channel link, then save. The homepage popup reads these public values from `/api/channel-stats`; timestamps are displayed in IST, and a reminder appears when a follower count has not changed for seven days. The API caches results on the server for five minutes and uses the last available values if a refresh fails. Channel table access is restricted; admin reads and writes are authorized by database RPCs. No Telegram bot token or auto-sync configuration is used.

In **Admin → Used Keys**, each inventory row represents one independent key; the same Software product can have any number of keys. Add a key using the existing Software dropdown, key, price, and validity in days. For bulk add, choose the Software once and enter one tab-separated row per key in the bulk box: `KEY<TAB>PRICE<TAB>DAYS`. Filter by Software or search software/key/link in inventory. The customer-facing card uses the linked Software product’s image; missing or failed images show a default, and cards can be sorted by price or validity. The regular price comes from the selected Software product’s MRP (or its current price if no MRP is set). A submitted valid UTR reserves only that key, rejection releases it, and completion starts the key’s validity and marks it sold. Telegram order alerts include the current software name, key ID, remaining days, amount, and UTR.

The storefront already provides the payment QR/UPI settings and exact checkout amount. Submitting a 12-digit UTR changes the eligible Software/VPS request to `new`; without a submitted UTR it remains `unpaid`. Both the legacy **Orders** list and **Order Requests** hide orders with status `unpaid` or `pending_payment`; eligible `new` requests with a UTR appear under **Order Requests**. Rejected customers can submit a different valid UTR for the same order. Order UTR submissions are limited to five attempts per customer per hour. Other existing product categories and wallet purchases keep their existing fulfillment paths.

### Telegram order alerts

After a successful UTR submission changes a Software/VPS order to `new`, the storefront sends only its order ID and signed-in session to `/api/notify-order`. The Vercel function verifies the session, reads the order and customer details from Supabase, and sends the Telegram message. Orders without a valid UTR or in any other status are ignored. A private database table claims each order once, preventing duplicate alerts even if the request is repeated.

After running `supabase/order-requests-migration.sql`, run [`supabase/telegram-order-alerts-migration.sql`](./supabase/telegram-order-alerts-migration.sql) in the Supabase SQL Editor. Add these Vercel environment variables for the deployments you use:

- `TELEGRAM_BOT_TOKEN`: token for the Roshan Admin Alerts bot.
- `TELEGRAM_CHAT_ID`: the admin chat ID where alerts should arrive.
- `TELEGRAM_TEST_SECRET`: a long random secret used only to authorize the test message route.
- `SUPABASE_URL` and `SUPABASE_ANON_KEY`: the same project URL and public anon key used by the storefront.
- `SUPABASE_SERVICE_ROLE_KEY`: the Supabase service-role/secret key, used only by the serverless function. Never add it to frontend code or expose it in a `NEXT_PUBLIC_`/browser variable.

To test Telegram delivery, send a `POST` request to `/api/notify-order` with JSON `{"test":true}` and header `x-telegram-test-secret: <TELEGRAM_TEST_SECRET>`. The endpoint sends a test message but does not access or modify an order.

The order table stores one product name and a quantity per order, so an alert includes that product name and quantity. The Telegram call is best-effort: a failure is logged and does not undo or block the order submission.

#### Telegram alert test checklist

1. Send the test request above and confirm **Roshan Admin Alerts** receives it.
2. Submit a valid UTR for a Software/VPS order. Confirm the order reaches **New** and one Telegram message includes its database-backed customer, product, amount, UTR, and payment time.
3. Start another checkout and do not submit a UTR. Confirm it remains unpaid and no Telegram alert arrives.
4. For a failure check, temporarily use an invalid bot token and submit a fresh valid UTR. Confirm the order still succeeds for the customer and a Telegram failure appears in the Vercel function logs. Restore the correct token afterward; the same order will not be retried automatically.

### Inventory stock toggles

After the Used Keys, Demo Keys, Rental, and one guest-checkout route above, run [`supabase/inventory-stock-toggle-migration.sql`](./supabase/inventory-stock-toggle-migration.sql). It may be applied before optional channel or Telegram migrations. It adds independent stock flags for Used and Demo keys, admin-only stock controls for those inventories, out-of-stock status in customer listings, and a database trigger that rechecks current stock when a UTR is submitted. Product stock continues to use `products.in_stock` and `products.stock_status` with the existing admin-only RLS policy. New key inventory defaults to in stock. Do not execute this migration against a project until its prerequisites have been installed.

All order mutations and private delivery reads go through authenticated Supabase RPCs, with `auth.uid()` ownership checks and `is_store_admin()` checks; direct client access to `order_delivery` and the encryption key is revoked. The browser uses Supabase bearer-token authorization rather than cookie authentication, so cross-site form requests cannot attach the customer/admin JWT (CSRF). SQL parameters are bound by PostgREST, database functions validate UTRs, URLs, numeric fields and lengths, and rendered customer/admin values are HTML-escaped.

### Order-request test checklist

Run these checks using two customer accounts and one account listed in `public.admin_users`:

1. Start a Software/VPS checkout and stop before entering a UTR. Confirm the customer sees **Payment Pending**, while **Admin → Order Requests** and the existing **Orders** list do not show it.
2. Submit an empty, non-numeric, or non-12-digit UTR. Confirm it is rejected. Submit the same valid UTR on another order (or a wallet top-up) and confirm the duplicate is rejected. Repeat invalid submissions until the hourly limit is reached and confirm further attempts are blocked.
3. Submit an unused 12-digit UTR. Confirm the customer sees **Payment verification pending** and the admin **New** tab shows the request with its amount, customer, UTR, and payment time.
4. As admin, save partial delivery details and reopen the request to confirm draft persistence. Complete a Software request with all three required fields or a VPS request with IP, port, username, password, and storage. Confirm the customer can see/copy the software key and download, or reveal/copy the VPS password and see its storage.
5. Reject another new request with a reason. Confirm the customer sees that reason and can resubmit a different 12-digit UTR; verify that the request returns to the **New** tab.
6. Sign in as the second customer and attempt to load the first customer's order through `my_orders`; confirm it is absent. Confirm the second customer cannot invoke the first customer's delivery through any customer RPC. Before an order is completed, verify that customer responses contain no license key, download link, or VPS credentials.

## Deploy to Vercel

Import this GitHub repository as a Vercel project with the repository root as the project root and no build command. Add the environment variables listed above for each Vercel environment you use. `SUPABASE_SERVICE_ROLE_KEY`, `GUEST_HASH_SECRET`, `RESEND_API_KEY`, and Telegram credentials must remain server-only and must never be exposed in frontend code. Vercel serves the storefront and admin page from `public/`, exposes the public configuration endpoint at `/api/config`, and deploys the endpoints under `/api/` as serverless functions. Add your deployed store URL to Supabase's allowed redirect URLs and configure the Google OAuth redirect URLs as described above.

## Supabase SQL execution order

For a fresh database, run the root-level SQL files below in the listed order from the Supabase SQL Editor. Take a database backup before applying migrations to an existing production database.

1. [`supabase/setup.sql`](./supabase/setup.sql) — always first.
2. [`supabase/product-payment-expiry-migration.sql`](./supabase/product-payment-expiry-migration.sql).
3. [`supabase/checkout-coupon-migration.sql`](./supabase/checkout-coupon-migration.sql).
4. [`supabase/order-requests-migration.sql`](./supabase/order-requests-migration.sql).
5. [`supabase/security-admin-authorization-migration.sql`](./supabase/security-admin-authorization-migration.sql).
6. [`supabase/used-keys-migration.sql`](./supabase/used-keys-migration.sql).
7. [`supabase/used-keys-live-products-migration.sql`](./supabase/used-keys-live-products-migration.sql).
8. [`supabase/used-keys-multi-key-migration.sql`](./supabase/used-keys-multi-key-migration.sql).
9. [`supabase/used-keys-validity-days-migration.sql`](./supabase/used-keys-validity-days-migration.sql).
10. [`supabase/used-keys-auto-validity-migration.sql`](./supabase/used-keys-auto-validity-migration.sql).
11. [`supabase/used-keys-sold-validity-migration.sql`](./supabase/used-keys-sold-validity-migration.sql).
12. [`supabase/used-keys-legacy-expiry-cutover-migration.sql`](./supabase/used-keys-legacy-expiry-cutover-migration.sql) — run once, after the preceding Used Keys migrations.
13. [`supabase/demo-keys-migration.sql`](./supabase/demo-keys-migration.sql).
14. [`supabase/demo-custom-software-migration.sql`](./supabase/demo-custom-software-migration.sql).
15. [`supabase/software-pnr-plans-migration.sql`](./supabase/software-pnr-plans-migration.sql).
16. Guest checkout: run either [`supabase/guest-checkout-migration.sql`](./supabase/guest-checkout-migration.sql) once, or run the split scripts [`supabase/guest-checkout-1-tables-trigger.sql`](./supabase/guest-checkout-1-tables-trigger.sql), [`supabase/guest-checkout-2-guest-functions.sql`](./supabase/guest-checkout-2-guest-functions.sql), [`supabase/guest-checkout-3-admin-functions.sql`](./supabase/guest-checkout-3-admin-functions.sql), and [`supabase/guest-checkout-4-reject-refund-grants.sql`](./supabase/guest-checkout-4-reject-refund-grants.sql) in that order. Never run both alternatives.
17. [`supabase/inventory-stock-toggle-migration.sql`](./supabase/inventory-stock-toggle-migration.sql) — run after one guest-checkout route.
18. [`supabase/channel-settings-migration.sql`](./supabase/channel-settings-migration.sql).
19. [`supabase/telegram-order-alerts-migration.sql`](./supabase/telegram-order-alerts-migration.sql) — requires order requests.

[`supabase/product-pricing-stats-migration.sql`](./supabase/product-pricing-stats-migration.sql) is only needed for an existing database that does not already have those columns; fresh installs get them from `setup.sql`. [`supabase/migrations/20261112084600_used_key_utr_pending_payment_fix.sql`](./supabase/migrations/20261112084600_used_key_utr_pending_payment_fix.sql) is a targeted Used Key payment-recovery fix, not a standard fresh-install migration; apply it only when that specific recovery applies to the production data. Files in `supabase/backup/`, `supabase/scratch-run/`, and `supabase/tests/` are backup, test, or assembly scripts and are not part of this production execution list.

## Favicon

The storefront and admin page load the shared favicon assets from the site root. Keep `favicon.ico`, `favicon-192.png`, `apple-touch-icon.png`, and `site.webmanifest` in `public/`; the static server exposes them at `/favicon.ico`, `/favicon-192.png`, `/apple-touch-icon.png`, and `/site.webmanifest`. `favicon.svg` is the editable vector source for the generated image files. After deploying a favicon change, open the direct icon URLs to confirm they load, then hard-refresh the site or clear Chrome's cached images and files if the old icon remains.

## Progressive Web App (PWA)

The storefront can be installed from supported browsers over HTTPS (localhost is also supported for development). `public/manifest.json` defines the app name, standalone display, dark navy colors, and 192x192/512x512 icons. The root-scoped `public/service-worker.js` caches same-origin static assets and the offline page only; page navigations, `/api/` requests, and admin/login/checkout/order/payment paths are always network-only. The install control appears when Chrome offers an install prompt. On iPhone/iPad, use **Share → Add to Home Screen**.

The app icons in `public/icons/` are derived from `public/favicon.svg`. To regenerate them from the existing logo PNG, install Pillow with `python -m pip install Pillow`, then run this from the project root:

```python
from pathlib import Path
from PIL import Image

source = Image.open("public/favicon-192.png").convert("RGBA")
icons = Path("public/icons")
icons.mkdir(parents=True, exist_ok=True)
source.save(icons / "icon-192.png", format="PNG", optimize=True)
source.resize((512, 512), Image.Resampling.LANCZOS).save(
    icons / "icon-512.png", format="PNG", optimize=True
)
```

Keep the logo artwork inside the central 80% safe area for maskable use. Verify `/manifest.json`, `/icons/icon-192.png`, `/icons/icon-512.png`, `/service-worker.js`, and `/offline.html` after deployment. In Chrome DevTools, check **Application → Manifest** and **Application → Service Workers**, then use Lighthouse's installability/PWA checks. Install prompts are browser-controlled and may not appear when the app is already installed or its install criteria are not met.

Admins can review top-ups and pending UPI product payments, refund orders once, and add or deduct customer balances with an audit note. In each product editor, admins can upload a JPG, PNG, WebP, or GIF photo (up to 5 MB) and set that product's HTTP/HTTPS download link. Product photos are public; download links are kept in an admin-only table and are delivered when a wallet purchase succeeds or a UPI payment is approved. Products without a download link continue to use manual order delivery.

Product and settings changes are reflected on the store through Supabase Realtime and periodic refresh.

Admins can create, schedule, edit, disable, and delete timed offers from **Admin → Offers**. Customers see a one-time popup for each new active offer and can reopen current offers from the navbar. Offer writes are protected by Supabase admin-only RLS policies and database validation; anonymous customers can read only enabled offers within their scheduled start/end window.

Claim-enabled Software offers require an admin-configured paid/free quantity. A customer submits a WhatsApp-sharing screenshot (PNG/JPG/WebP, up to 2 MB); an admin reviews it before the paid-quantity order is created. The customer pays through the exact-amount UPI QR and submits a 12-digit UTR, which is checked for reuse. After the existing admin payment verification marks the order paid, an admin manually transfers the free quantity into the customer's orders. Screenshot data is private and is available only through the admin review RPC. Unreviewed claims, rejected-claim resubmissions, and unpaid offer orders expire after 24 hours. The setup script schedules the expiry RPC every five minutes using Supabase `pg_cron`; if the extension is unavailable in your project, configure an equivalent scheduled invocation before relying on automatic expiry. The SQL RPCs and RLS enforce customer ownership, one claim per offer/customer, screenshot/UTR uniqueness, and admin-only review and transfer. Recent-claim names are shown publicly only with customer consent and admin approval; the displayed benefit count is an admin-managed value and is not the actual claim total.

## Interface

The storefront and admin dashboard open in dark mode and share a light/dark preference saved in the browser. Their typography uses Sora for headings and Inter for body text. Cards use per-category accent colors, glassy gradients, layered shadows, and pointer-based 3D tilt; motion respects the device's reduced-motion preference. The visual effects use CSS and lightweight browser event handlers, with no additional visual libraries required.

## Order delivery

Wallet purchases without a product-level download link create orders with a pending fulfillment status. In **Admin → Orders**, select an order to save a delivery draft, paste delivery details (line breaks are preserved), optionally add an HTTPS/HTTP download link and customer note, then choose **Deliver**. Product-level download links are delivered automatically at purchase. The customer can open **My Orders** and view/copy details after delivery. Order delivery changes are performed by admin-only Supabase RPCs; customer order history uses a signed-in-owner RPC that withholds delivery fields until the order is delivered.

The checkout offers **Pay from Wallet**, **Scan QR (UPI)**, and **UPI ID / App**. Wallet payment uses the existing wallet purchase RPC and ignores coupons. QR/UPI submissions require a 12-digit UTR, create a pending-verification product order without deducting wallet balance, and show its payment and coupon details in **Admin → Orders**. The customer can track pending, approved, and rejected states in **My Orders**. Wallet top-ups remain a separate request flow.

## Environment

- `SUPABASE_URL`: Supabase project URL.
- `SUPABASE_ANON_KEY`: Supabase anon/public key. This key is safe to use in a browser because database access is restricted by RLS.
- `SUPABASE_SERVICE_ROLE_KEY`: server-only credential for guest checkout and other server endpoints; never expose it to browsers or commit the real value.
- `GUEST_HASH_SECRET`: random server-only secret of at least 32 characters used to protect guest abuse-prevention hashes.
- `RESEND_API_KEY`, `RESEND_FROM_EMAIL`: server-only Resend email configuration; the sender must be verified with Resend.
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`: server-only Telegram bot and destination configuration.
- `TELEGRAM_TEST_SECRET`: server-only secret required to send the test message.
- `PORT`: optional web server port (defaults to `3000`).

The six requested Software products are inserted by the setup script. The other categories start empty and can be populated in the admin panel. Windows VPS, Static Proxy, and Residential Proxies products can be organized into named plan sections with category-specific IP, data-size, OS, specification, IP-count, validity, stock, price, badge, and expandable detail fields; the storefront provides search, category-appropriate filters, section jumps, and the existing checkout.
