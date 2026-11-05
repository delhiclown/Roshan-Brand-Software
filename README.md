# Roshan Brand digital store

Responsive storefront with Google customer sign-in, a transactional Supabase wallet, and an email/password admin dashboard at `/admin`.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run [`supabase/setup.sql`](./supabase/setup.sql). You can rerun it to restore missing Software seed products, safely add product photo/download support and order-delivery columns, and reapply policies and RPCs.
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
8. Sign in at `/admin`, open **Settings**, and set your UPI ID, WhatsApp number, Telegram link, and site title.

Products and store settings are public-read. Customers can only read their own wallet, transactions, top-up requests, and orders. Wallet balances cannot be changed through table writes: purchases, top-up approvals, refunds, and admin adjustments run through transactional, row-locking Supabase RPC functions. Pending UPI top-ups require admin verification. The database functions can later be replaced by a payment-provider webhook calling a similarly trusted server-side credit function.

## Deploy to Vercel

Import this GitHub repository as a Vercel project with the repository root as the project root and no build command. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as Vercel environment variables for the environments you use; never add a service-role key. Vercel serves the storefront and admin page from `public/` and exposes the public configuration endpoint at `/api/config`. Add your deployed store URL to Supabase's allowed redirect URLs and configure the Google OAuth redirect URLs as described above.

Admins can review top-ups, refund orders once, and add or deduct customer balances with an audit note. In each product editor, admins can upload a JPG, PNG, WebP, or GIF photo (up to 5 MB) and set that product's HTTP/HTTPS download link. Product photos are public; download links are kept in an admin-only table and are copied into a customer's order only when the wallet purchase succeeds. Products with a saved download link are marked delivered immediately, and the customer sees the named download link under that product and in **My Orders**. Products without a download link continue to use manual order delivery.

Product and settings changes are reflected on the store through Supabase Realtime and periodic refresh.

## Interface

The storefront and admin dashboard open in dark mode and share a light/dark preference saved in the browser. Their typography uses Sora for headings and Inter for body text. Cards use per-category accent colors, glassy gradients, layered shadows, and pointer-based 3D tilt; motion respects the device's reduced-motion preference. The visual effects use CSS and lightweight browser event handlers, with no additional visual libraries required.

## Order delivery

Wallet purchases without a product-level download link create orders with a pending fulfillment status. In **Admin → Orders**, select an order to save a delivery draft, paste delivery details (line breaks are preserved), optionally add an HTTPS/HTTP download link and customer note, then choose **Deliver**. Product-level download links are delivered automatically at purchase. The customer can open **My Orders** and view/copy details after delivery. Order delivery changes are performed by admin-only Supabase RPCs; customer order history uses a signed-in-owner RPC that withholds delivery fields until the order is delivered.

This version keeps the existing Supabase wallet checkout: customers sign in and pay from their wallet. UPI UTR top-ups remain a separate top-up request flow and are not tied to individual product orders.

## Environment

- `SUPABASE_URL`: Supabase project URL.
- `SUPABASE_ANON_KEY`: Supabase anon/public key. This key is safe to use in a browser because database access is restricted by RLS.
- `PORT`: optional web server port (defaults to `3000`).

The six requested Software products are inserted by the setup script. The other categories start empty and can be populated in the admin panel.
