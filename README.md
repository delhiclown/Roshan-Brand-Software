# Roshan Brand digital store

Responsive storefront with Google customer sign-in, wallet and UPI product checkout, and an email/password admin dashboard at `/admin`.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run [`supabase/setup.sql`](./supabase/setup.sql). You can rerun it to restore missing Software seed products, add product photo/download and VPS/proxy plan fields, and apply timed offers, claim review, payment, free-item transfer, audit, wallet, UPI order verification, UTR uniqueness, settings, and delivery schema/RPCs.
3. Copy `.env.example` to `.env` and add the project's **Project URL** and **anon/public key**. Do not put a `service_role` key in this app.
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

## Deploy to Vercel

Import this GitHub repository as a Vercel project with the repository root as the project root and no build command. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as Vercel environment variables for the environments you use; never add a service-role key. Vercel serves the storefront and admin page from `public/` and exposes the public configuration endpoint at `/api/config`. Add your deployed store URL to Supabase's allowed redirect URLs and configure the Google OAuth redirect URLs as described above.

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
- `PORT`: optional web server port (defaults to `3000`).

The six requested Software products are inserted by the setup script. The other categories start empty and can be populated in the admin panel. Linux VPS, Linux Proxy, and Residential Proxies products can be organized into named plan sections with category-specific IP, data-size, OS, specification, IP-count, validity, stock, price, badge, and expandable detail fields; the storefront provides search, category-appropriate filters, section jumps, and the existing checkout.
