# Roshan Brand digital store

Responsive storefront with Google customer sign-in, wallet and UPI product checkout, and an email/password admin dashboard at `/admin`.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run [`supabase/setup.sql`](./supabase/setup.sql). You can rerun it to restore missing Software seed products, add product photo/download and VPS/proxy plan fields, and apply timed offers, claim review, payment, free-item transfer, audit, wallet, UPI order verification, UTR uniqueness, settings, and delivery schema/RPCs.
3. Copy `.env.example` to `.env` and add the project's **Project URL** and **anon/public key**. The Telegram serverless function also needs the service-role key; keep it only in server environment variables and never expose it in browser code or commit its value.
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

Products and store settings are public-read. Customers can only read their own wallet, transactions, top-up requests, orders, and coupons. Wallet balances and coupon records cannot be changed through direct table writes: purchases, spin results, coupon validation, top-up approvals, refunds, and admin adjustments run through Supabase RPC functions. Coupons apply only to QR/UPI payments; wallet purchases continue to charge the full product price through the existing wallet RPC. UTRs must be 12 digits and cannot be reused across product payments or wallet top-ups. Admins can approve or reject pending UPI product orders.

Product selling price, optional MRP, rating, review count, sold count, and stats visibility are editable in the admin product form. The selling price is saved to both `selling_price` and the existing checkout `price` field. For an existing database, run [`supabase/product-pricing-stats-migration.sql`](./supabase/product-pricing-stats-migration.sql) in the Supabase SQL Editor; it backfills `selling_price` from `price` and leaves product prices unchanged. Fresh installs also get these columns from `supabase/setup.sql`.

For UPI product-payment countdowns and late UTR review, run [`supabase/product-payment-expiry-migration.sql`](./supabase/product-payment-expiry-migration.sql) in the Supabase SQL Editor after `setup.sql`. It creates payment orders before the customer pays, enforces UTR validation/uniqueness and expiry server-side, and schedules expiration every minute when `pg_cron` is available. The singleton `public.payment_timer_config` row defaults to a 10-minute payment window and a 5-minute grace period; configure it in the SQL Editor. If `pg_cron` is unavailable, schedule `public.expire_pending_product_payments()` to run every minute. Wallet payments remain immediate.

For database-backed coupons, run [`supabase/checkout-coupon-migration.sql`](./supabase/checkout-coupon-migration.sql) in the Supabase SQL Editor after the payment-expiry migration. It creates customer-owned coupon records, server-selected Spin & Win prizes (one spin per user per UTC day), coupon validation limits, and database-backed admin prize settings. For QR/UPI orders, the server calculates the final amount from the product price and the coupon record. Wallet purchases remain full-price through the existing wallet RPC. A coupon is reserved when a payment order is created, released after a rejected UPI payment or an unpaid order's grace period, and remains consumed after a successful purchase. Legacy coupons saved in browser storage are not trusted or transferable; the storefront clears them and displays a one-time notice.

## Order Requests

For UTR-verified Software and VPS requests, run [`supabase/order-requests-migration.sql`](./supabase/order-requests-migration.sql) after `setup.sql`, `product-payment-expiry-migration.sql`, and `checkout-coupon-migration.sql` (in that order). It adds the `unpaid` → `new` → `completed` / `rejected` lifecycle, amount/UTR/payment/completion timestamps, a private `order_delivery` table, admin-only list/detail/save/complete/reject RPCs, customer-owned order delivery, UTR rate limiting, and a database-generated encryption key. License keys and VPS passwords are encrypted with AES-256 before they are stored; only the admin detail RPC and the owning customer’s completed-order RPC decrypt them. Do not delete `private.order_delivery_secrets`; losing that key makes saved credentials unrecoverable. Unpaid orders are omitted from both admin order-list RPCs.

### Used Keys

After `setup.sql` and `order-requests-migration.sql` are installed, run [`supabase/security-admin-authorization-migration.sql`](./supabase/security-admin-authorization-migration.sql). It allowlists email-signup metadata to the customer's name, keeps admin membership in the server-managed `admin_users` table, and removes client write access to that table. Admin RPCs must continue to verify `public.is_store_admin()` on the database.

After `order-requests-migration.sql`, run [`supabase/used-keys-migration.sql`](./supabase/used-keys-migration.sql) in the Supabase SQL Editor. It creates private encrypted key inventory and admin-only management RPCs, server-priced UPI QR payment orders, UTR-time stock reservation, rejection release, and completed-owner-only delivery. The storefront hides expired, hidden, reserved, and sold stock. No coupon value is accepted for these orders, and the database rejects attempts to change their price or attach a coupon. The license key inventory uses AES-256 encryption and a keyed duplicate fingerprint; back up `private.order_delivery_secrets` securely.

After that, run [`supabase/used-keys-live-products-migration.sql`](./supabase/used-keys-live-products-migration.sql). Used Keys cards read the current Software name and image from the linked product, while order lists/details and completed customer orders read the current name. Product photo/name edits carry through without a separate Used Key upload or copy.

Run [`supabase/used-keys-multi-key-migration.sql`](./supabase/used-keys-multi-key-migration.sql) after the live-products migration to enable explicit hidden status, per-key bulk details, and key IDs in Order Requests.

Then run [`supabase/used-keys-validity-days-migration.sql`](./supabase/used-keys-validity-days-migration.sql). It preserves existing inventory and encrypted key data, fixes ambiguous ID references, and changes key validity to a number of days that begins when the order is completed. New and bulk-added keys use the selected Software product’s current Download Link; no per-key link or calendar expiry is needed.

In **Admin → Used Keys**, each inventory row represents one independent key; the same Software product can have any number of keys. Add a key using the existing Software dropdown, key, price, and validity in days. For bulk add, choose the Software once and enter one tab-separated row per key in the bulk box: `KEY<TAB>PRICE<TAB>DAYS`. Filter by Software or search software/key/link in inventory. The customer-facing card uses the linked Software product’s image; missing or failed images show a default, and cards can be sorted by price or validity. The regular price comes from the selected Software product’s MRP (or its current price if no MRP is set). A submitted valid UTR reserves only that key, rejection releases it, and completion starts the key’s validity and marks it sold. Telegram order alerts include the current software name, key ID, remaining days, amount, and UTR.

The storefront already provides the payment QR/UPI settings and exact checkout amount. Submitting a 12-digit UTR changes the eligible Software/VPS request to `new`; without a submitted UTR it remains `unpaid` and is never listed to admins. Rejected customers can submit a different valid UTR for the same order. Order UTR submissions are limited to five attempts per customer per hour. Other existing product categories and wallet purchases keep their existing fulfillment paths.

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

Import this GitHub repository as a Vercel project with the repository root as the project root and no build command. Add the environment variables listed above for each Vercel environment you use. `SUPABASE_SERVICE_ROLE_KEY` and Telegram credentials must remain server-only and must never be exposed in frontend code. Vercel serves the storefront and admin page from `public/`, exposes the public configuration endpoint at `/api/config`, and deploys `/api/notify-order` as a serverless function. Add your deployed store URL to Supabase's allowed redirect URLs and configure the Google OAuth redirect URLs as described above.

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
- `SUPABASE_SERVICE_ROLE_KEY`: server-only credential for `/api/notify-order`; never expose it to browsers or commit the real value.
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`: server-only Telegram bot and destination configuration.
- `TELEGRAM_TEST_SECRET`: server-only secret required to send the test message.
- `PORT`: optional web server port (defaults to `3000`).

The six requested Software products are inserted by the setup script. The other categories start empty and can be populated in the admin panel. Windows VPS, Static Proxy, and Residential Proxies products can be organized into named plan sections with category-specific IP, data-size, OS, specification, IP-count, validity, stock, price, badge, and expandable detail fields; the storefront provides search, category-appropriate filters, section jumps, and the existing checkout.
