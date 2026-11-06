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

Products and store settings are public-read. Customers can only read their own wallet, transactions, top-up requests, and orders. Wallet balances cannot be changed through table writes: purchases, top-up approvals, refunds, and admin adjustments run through transactional, row-locking Supabase RPC functions. Wallet product purchases remain full-price and immediate. QR/UPI product payments create orders pending manual admin verification; coupons apply only to those payment methods. UTRs must be 12 digits and cannot be reused across product payments or wallet top-ups. Admins can approve or reject pending UPI product orders.

## Deploy to Vercel

Import this GitHub repository as a Vercel project with the repository root as the project root and no build command. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as Vercel environment variables for the environments you use; never add a service-role key. Vercel serves the storefront and admin page from `public/` and exposes the public configuration endpoint at `/api/config`. Add your deployed store URL to Supabase's allowed redirect URLs and configure the Google OAuth redirect URLs as described above.

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
