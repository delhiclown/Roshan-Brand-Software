begin;

-- Apply order: 1) software-pnr-plans-migration.sql, 2) guest-checkout-migration.sql.
-- Guest Software orders depend on the plan columns created by the PNR migration.
alter table public.orders alter column user_id drop not null;
alter table public.orders add column if not exists guest_email text;
alter table public.orders add column if not exists guest_whatsapp text;
alter table public.orders add column if not exists guest_access_hash text;
alter table public.orders add column if not exists guest_device_hash text;
alter table public.orders add column if not exists guest_ip_hash text;
alter table public.orders add column if not exists guest_email_sent_at timestamptz;

alter table public.orders drop constraint if exists orders_guest_identity_check;
alter table public.orders add constraint orders_guest_identity_check check (
  (user_id is null and guest_email is not null
    and guest_access_hash is not null and guest_access_hash ~ '^[0-9a-f]{64}$'
    and guest_device_hash is not null and guest_device_hash ~ '^[0-9a-f]{64}$'
    and guest_ip_hash is not null and guest_ip_hash ~ '^[0-9a-f]{64}$')
  or (user_id is not null and guest_email is null and guest_access_hash is null
    and guest_device_hash is null and guest_ip_hash is null)
);
alter table public.orders drop constraint if exists orders_guest_email_check;
alter table public.orders add constraint orders_guest_email_check check (
  guest_email is null or (length(guest_email) between 3 and 254 and guest_email = lower(btrim(guest_email)))
);
alter table public.orders drop constraint if exists orders_guest_whatsapp_check;
alter table public.orders add constraint orders_guest_whatsapp_check check (
  guest_whatsapp is null or length(guest_whatsapp) between 8 and 24
);
create index if not exists orders_guest_email_created_idx
  on public.orders (guest_email, created_at desc) where guest_email is not null;

create table if not exists private.guest_demo_claims (
  id bigint generated always as identity primary key,
  product_id bigint not null references private.demo_key_inventory(product_id) on delete restrict,
  email_hash text not null check (email_hash ~ '^[0-9a-f]{64}$'),
  device_hash text not null check (device_hash ~ '^[0-9a-f]{64}$'),
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  claim_day date not null,
  claimed_at timestamptz not null default clock_timestamp(),
  unique (email_hash, claim_day),
  unique (device_hash, claim_day),
  unique (ip_hash, claim_day)
);
alter table private.guest_demo_claims enable row level security;
revoke all on private.guest_demo_claims from public, anon, authenticated;

create table if not exists private.guest_utr_attempts (
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  attempted_at timestamptz not null default clock_timestamp()
);
create index if not exists guest_utr_attempts_ip_time_idx
  on private.guest_utr_attempts (ip_hash, attempted_at desc);
alter table private.guest_utr_attempts enable row level security;
revoke all on private.guest_utr_attempts from public, anon, authenticated;

create or replace function private.release_guest_used_key_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.used_key_inventory as k
  set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
  where k.id = old.used_key_id and k.status = 'reserved'
    and k.reserved_order_id = old.id;
  return new;
end;
$$;
drop trigger if exists release_guest_used_key_reservation on public.orders;
create trigger release_guest_used_key_reservation
  after update of status on public.orders
  for each row
  when (
    old.user_id is null and old.used_key_id is not null
    and new.status in ('expired', 'rejected', 'cancelled')
  )
  execute function private.release_guest_used_key_reservation();

create or replace function public.guest_create_order(
  p_type text,
  p_product_id bigint,
  p_used_key_id bigint,
  p_plan_code text,
  p_email text,
  p_whatsapp text,
  p_access_hash text,
  p_device_hash text,
  p_ip_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_whatsapp text := nullif(btrim(coalesce(p_whatsapp, '')), '');
  v_product public.products%rowtype;
  v_used_key private.used_key_inventory%rowtype;
  v_rental public.rental_products%rowtype;
  v_order public.orders%rowtype;
  v_timeout integer;
  v_checkout_price numeric(12, 2);
  v_plan_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_plan_label text;
  v_plan_mrp numeric(12, 2);
  v_now timestamptz := clock_timestamp();
  v_type text := lower(btrim(coalesce(p_type, '')));
begin
  if v_type not in ('product', 'used_key', 'rental') then
    return jsonb_build_object('ok', false, 'message', 'This item is not available for guest checkout.');
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]{2,}$'
     or length(v_email) > 254 then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid email address.');
  end if;
  if length(coalesce(v_whatsapp, '')) > 24
     or (v_whatsapp is not null and v_whatsapp !~ '^\+?[0-9 ()-]{8,23}$') then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid WhatsApp number or leave it blank.');
  end if;
  if coalesce(p_access_hash, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_device_hash, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_ip_hash, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'message', 'Guest checkout could not verify this request.');
  end if;
  if not coalesce((
    select s.enable_upi_qr and length(btrim(s.upi_id)) > 0 and length(btrim(s.upi_payee_name)) > 0
    from public.settings as s where s.id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'UPI QR payments are currently unavailable.');
  end if;

  if v_type = 'used_key' then
    if p_used_key_id is null or p_used_key_id <= 0 then
      return jsonb_build_object('ok', false, 'message', 'Choose an available Used Key.');
    end if;
    select k.* into v_used_key
    from private.used_key_inventory as k
    where k.id = p_used_key_id and k.status = 'available' and k.is_visible
      and k.expires_on >= (timezone('Asia/Kolkata', v_now))::date and k.validity_days > 0
      and exists (select 1 from public.product_download_links as d where d.product_id = k.product_id)
    for update;
    if not found then return jsonb_build_object('ok', false, 'message', 'This Used Key is no longer available.'); end if;
    select p.* into v_product from public.products as p
      where p.id = v_used_key.product_id and lower(p.category) = 'software';
    if not found then return jsonb_build_object('ok', false, 'message', 'This Software product is unavailable.'); end if;
  elsif v_type = 'rental' then
    if p_product_id is null or p_product_id <= 0 then
      return jsonb_build_object('ok', false, 'message', 'Choose available rental software.');
    end if;
    select r.* into v_rental from public.rental_products as r
      where r.product_id = p_product_id and r.is_enabled for share;
    if not found then return jsonb_build_object('ok', false, 'message', 'This rental is unavailable.'); end if;
    select p.* into v_product from public.products as p
      where p.id = p_product_id and lower(p.category) = 'software' and p.in_stock for share;
    if not found or not exists (
      select 1 from private.rental_accounts as a
      where a.rental_product_id = p_product_id and a.is_enabled
        and (a.lease_until is null or a.lease_until <= v_now)
    ) then
      return jsonb_build_object('ok', false, 'message', 'No rental IDs are currently available.');
    end if;
  else
    if p_product_id is null or p_product_id <= 0 then
      return jsonb_build_object('ok', false, 'message', 'Choose an available product.');
    end if;
    select p.* into v_product from public.products as p
      where p.id = p_product_id and p.in_stock
        and lower(p.category) in ('software', 'vps', 'windows-vps', 'proxy', 'residential')
      for share;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This product is no longer available for guest checkout.');
    end if;
    if lower(v_product.category) = 'software' then
      if v_plan_code not in ('2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days') then
        return jsonb_build_object('ok', false, 'message', 'Choose a valid 30-day Software PNR plan.');
      end if;
      if v_plan_code = '2_pnr_30_days' and v_product.plan_2_pnr_enabled then
        v_checkout_price := v_product.plan_2_pnr_price;
        v_plan_mrp := v_product.plan_2_pnr_mrp;
        v_plan_label := '2 PNR 30 DAYS';
      elsif v_plan_code = '4_pnr_30_days' and v_product.plan_4_pnr_enabled then
        v_checkout_price := v_product.plan_4_pnr_price;
        v_plan_mrp := v_product.plan_4_pnr_mrp;
        v_plan_label := '4 PNR 30 DAYS';
      elsif v_plan_code = '6_pnr_30_days' and v_product.plan_6_pnr_enabled then
        v_checkout_price := v_product.plan_6_pnr_price;
        v_plan_mrp := v_product.plan_6_pnr_mrp;
        v_plan_label := '6 PNR 30 DAYS';
      else
        return jsonb_build_object('ok', false, 'message', 'This PNR plan is not currently available.');
      end if;
      if v_checkout_price is null or v_checkout_price <= 0 then
        return jsonb_build_object('ok', false, 'message', 'The selected PNR plan has no valid price.');
      end if;
    else
      if v_plan_code <> '' then
        return jsonb_build_object('ok', false, 'message', 'PNR plans are only available for Software products.');
      end if;
      if v_product.price is null or v_product.price <= 0 then
        return jsonb_build_object('ok', false, 'message', 'This product is no longer available for guest checkout.');
      end if;
      v_checkout_price := v_product.price;
    end if;
  end if;

  select c.payment_timeout_minutes into v_timeout
  from public.payment_timer_config as c where c.id = true;
  v_timeout := case when v_type = 'rental' then 30 else coalesce(v_timeout, 10) end;
  insert into public.orders (
    user_id, guest_email, guest_whatsapp, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_id, product_name, product_type, price, amount, status,
    payment_method, payment_status, quantity, coupon_code, discount_percent,
    original_price, created_at, payment_expires_at, used_key_id,
    used_key_validity_days, used_key_expires_on, used_key_fingerprint, rental_product_id,
    used_key_remaining_days, software_plan_code, software_plan_label, software_plan_mrp
  ) values (
    null, v_email, v_whatsapp, p_access_hash, p_device_hash, p_ip_hash,
    v_product.id, v_product.name,
    case when v_type = 'rental' then 'rental' else lower(v_product.category) end,
    case when v_type = 'used_key' then v_used_key.price
      when v_type = 'rental' then v_rental.daily_rate else v_checkout_price end,
    case when v_type = 'used_key' then v_used_key.price
      when v_type = 'rental' then v_rental.daily_rate else v_checkout_price end,
    case when v_type = 'used_key' then 'pending_payment' else 'unpaid' end,
    'upi_qr', 'pending', 1, null, 0,
    case when v_type = 'used_key' then v_used_key.regular_price
      when v_type = 'rental' then null else v_checkout_price end,
    v_now, v_now + make_interval(mins => v_timeout),
    case when v_type = 'used_key' then v_used_key.id end,
    case when v_type = 'used_key' then v_used_key.validity_days end,
    null,
    case when v_type = 'used_key' then v_used_key.license_key_fingerprint end,
    case when v_type = 'rental' then v_product.id end,
    case when v_type = 'used_key' then v_used_key.validity_days end,
    case when v_type = 'product' and lower(v_product.category) = 'software' then v_plan_code end,
    case when v_type = 'product' and lower(v_product.category) = 'software' then v_plan_label end,
    case when v_type = 'product' and lower(v_product.category) = 'software' then v_plan_mrp end
  ) returning * into v_order;

  if v_type = 'used_key' then
    update private.used_key_inventory as k
    set status = 'reserved', reserved_order_id = v_order.id, updated_at = v_now
    where k.id = v_used_key.id and k.status = 'available' and k.is_visible
      and k.reserved_order_id is null;
    if not found then raise exception 'This used key is no longer available.'; end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'product_name', v_order.product_name, 'product_type', v_order.product_type,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'amount', v_order.amount, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', v_now
  );
end;
$$;

create or replace function public.guest_submit_order_utr(
  p_order_id bigint, p_utr text, p_access_hash text, p_ip_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_utr text := btrim(coalesce(p_utr, ''));
  v_attempts integer;
begin
  if p_order_id is null or p_order_id <= 0
     or coalesce(p_access_hash, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_ip_hash, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'message', 'Guest order could not be verified.');
  end if;
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id is null
      and o.guest_access_hash = p_access_hash
      and o.guest_email is not null and o.guest_email_sent_at is null
    for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Guest order could not be verified.'); end if;
  perform pg_advisory_xact_lock(hashtextextended(p_ip_hash, 0));
  select count(*) into v_attempts from private.guest_utr_attempts as a
    where a.ip_hash = p_ip_hash and a.attempted_at > clock_timestamp() - interval '1 hour';
  if v_attempts >= 10 then
    return jsonb_build_object('ok', false, 'message', 'Too many UTR attempts. Try again in an hour.');
  end if;
  insert into private.guest_utr_attempts (ip_hash) values (p_ip_hash);
  if v_utr !~ '^[0-9]{12}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid 12-digit UTR / transaction ID.');
  end if;
  if v_order.status not in ('unpaid', 'pending_payment', 'expired') or v_order.utr is not null then
    return jsonb_build_object('ok', false, 'message', 'This payment order can no longer accept a UTR.');
  end if;
  if v_order.used_key_id is not null and v_order.status = 'expired' then
    return jsonb_build_object('ok', false, 'message', 'This Used Key payment has expired; the key may no longer be reserved.');
  end if;
  if exists (select 1 from public.payment_utr_claims as c where c.utr_normalized = v_utr)
     or exists (select 1 from public.topup_requests as t where lower(t.utr) = lower(v_utr))
     or exists (select 1 from public.orders as o where o.utr_number = v_utr) then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  if v_order.used_key_id is not null then
    update private.used_key_inventory as k
    set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where k.id = v_order.used_key_id and k.status = 'reserved'
      and k.reserved_order_id = v_order.id;
    if not found then raise exception 'The used key reservation is no longer valid.'; end if;
  end if;
  update public.orders as o set
    utr = v_utr, utr_number = v_utr,
    utr_submitted_at = clock_timestamp(), payment_submitted_at = clock_timestamp(),
    late_payment = v_order.status = 'expired'
      or (v_order.payment_expires_at is not null and clock_timestamp() > v_order.payment_expires_at),
    status = 'new', payment_status = 'pending'
  where o.id = v_order.id;
  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'status', 'new');
end;
$$;

create or replace function public.guest_get_order(p_order_id bigint, p_access_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_used_key private.used_key_inventory%rowtype;
  v_rental private.rental_accounts%rowtype;
  v_encryption_key text;
begin
  if p_order_id is null or p_order_id <= 0
     or coalesce(p_access_hash, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'message', 'Guest order was not found.');
  end if;
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id is null and o.guest_access_hash = p_access_hash;
  if not found then return jsonb_build_object('ok', false, 'message', 'Guest order was not found.'); end if;
  select s.encryption_key into v_encryption_key from private.order_delivery_secrets as s where s.id = true;
  if v_order.used_key_id is not null then
    select k.* into v_used_key from private.used_key_inventory as k where k.id = v_order.used_key_id;
  end if;
  if v_order.status = 'completed' and v_order.product_type = 'rental' then
    select a.* into v_rental from private.rental_accounts as a
      where a.id = v_order.rental_account_id and a.lease_order_id = v_order.id
        and a.lease_until > clock_timestamp();
  end if;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_name', v_order.product_name,
    'product_type', v_order.product_type, 'amount', v_order.amount,
    'status', v_order.status, 'payment_status', v_order.payment_status,
    'utr_number', v_order.utr_number, 'created_at', v_order.created_at,
    'payment_expires_at', v_order.payment_expires_at, 'completed_at', v_order.completed_at,
    'reject_reason', v_order.reject_reason, 'email_sent', v_order.guest_email_sent_at is not null,
    'license_key', case when v_order.status = 'completed' and v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_encryption_key)
      when v_order.status = 'completed' and v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_encryption_key) else '' end,
    'download_link', case when v_order.status = 'completed' and v_order.used_key_id is not null
      then v_used_key.download_link when v_order.status = 'completed'
      then coalesce(v_delivery.download_link, '') else '' end,
    'software_name', case when v_order.status = 'completed'
      then coalesce(v_delivery.software_name, v_order.product_name) else '' end,
    'vps_ip', case when v_order.status = 'completed' then coalesce(v_delivery.vps_ip, '') else '' end,
    'vps_port', case when v_order.status = 'completed' then v_delivery.vps_port end,
    'vps_username', case when v_order.status = 'completed' then coalesce(v_delivery.vps_username, '') else '' end,
    'vps_password', case when v_order.status = 'completed' and v_delivery.vps_password_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_encryption_key) else '' end,
    'vps_storage_gb', case when v_order.status = 'completed' then v_delivery.vps_storage_gb end,
    'rental_access', case when v_order.status = 'completed' and v_rental.id is not null
      then extensions.pgp_sym_decrypt(v_rental.account_encrypted, v_encryption_key) else '' end,
    'rental_expires_at', case when v_order.status = 'completed' then v_order.rental_expires_at end
  );
end;
$$;

create or replace function public.guest_claim_demo_key(
  p_product_id bigint, p_email text, p_email_hash text, p_device_hash text, p_ip_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_software_name text;
  v_download_url text;
  v_license_key text;
  v_validity_days integer;
  v_day date := (timezone('utc', clock_timestamp()))::date;
begin
  if p_product_id is null or p_product_id <= 0
     or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]{2,}$'
     or length(v_email) > 254
     or coalesce(p_email_hash, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_device_hash, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_ip_hash, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'message', 'Demo claim could not verify this request.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_email_hash || ':' || v_day::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(p_device_hash || ':' || v_day::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(p_ip_hash || ':' || v_day::text, 0));

  select p.name, d.download_url, i.validity_days,
    extensions.pgp_sym_decrypt(i.license_key_encrypted, s.encryption_key)
  into v_software_name, v_download_url, v_validity_days, v_license_key
  from private.demo_key_inventory as i
  join public.products as p on p.id = i.product_id
  join public.product_download_links as d on d.product_id = p.id
  cross join private.order_delivery_secrets as s
  where i.product_id = p_product_id and s.id = true
    and lower(p.category) = 'software' and p.in_stock is distinct from false
    and coalesce(btrim(d.download_url), '') <> '';
  if not found then return jsonb_build_object('ok', false, 'message', 'This demo key is not available.'); end if;

  begin
    insert into private.guest_demo_claims (product_id, email_hash, device_hash, ip_hash, claim_day)
      values (p_product_id, p_email_hash, p_device_hash, p_ip_hash, v_day);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'message', 'One demo key per email, device, and IP address is allowed each day.');
  end;
  return jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'software_name', v_software_name,
    'license_key', v_license_key, 'download_link', v_download_url,
    'validity_days', v_validity_days
  );
end;
$$;

drop function if exists public.admin_list_orders();
create function public.admin_list_orders()
returns table(
  id bigint, user_id uuid, user_email text, product_name text, product_type text,
  price numeric, status text, created_at timestamptz, delivery_text text,
  delivery_link text, delivery_note text, delivered_at timestamptz,
  payment_method text, payment_status text, utr text, coupon_code text,
  discount_percent numeric, original_price numeric, reject_reason text,
  quantity integer, offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean,
  software_plan_label text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select o.id, o.user_id, coalesce(u.email::text, o.guest_email, ''), o.product_name,
      coalesce(o.product_type, p.category, ''), o.price, o.status, o.created_at,
      o.delivery_text, o.delivery_link, o.delivery_note, o.delivered_at,
      o.payment_method, o.payment_status, o.utr, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at,
      o.late_payment, o.software_plan_label
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    left join public.products as p on p.id = o.product_id
    where o.status not in ('unpaid', 'pending_payment', 'new')
    order by case when o.status in ('new', 'pending_verification') then 0 else 1 end,
      o.created_at desc;
end;
$$;

create or replace function public.admin_order_request_counts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return (
    select jsonb_build_object(
      'new', count(*) filter (where status = 'new'),
      'completed', count(*) filter (where status = 'completed'),
      'rejected', count(*) filter (where status = 'rejected'),
      'all', count(*)
    )
    from public.orders as o
    left join public.products as p on p.id = o.product_id
    where (
      (o.status in ('new', 'completed', 'rejected') and (
        (o.utr_number is not null and coalesce(o.product_type, p.category, '') in ('software', 'vps', 'rental'))
        or o.offer_claim_id is not null
      ))
    )
  );
end;
$$;

create or replace function public.admin_list_order_requests(
  p_status text default 'all', p_search text default '', p_page integer default 1, p_page_size integer default 20
)
returns table(
  id bigint, user_id uuid, customer text, product_id bigint, product_name text,
  product_type text, used_key_id bigint, used_key_remaining_days integer, amount numeric, utr_number text,
  payment_submitted_at timestamptz, created_at timestamptz, status text, total_count bigint,
  software_plan_label text
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_search text := left(btrim(coalesce(p_search, '')), 120);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('all', 'new', 'completed', 'rejected') then
    raise exception 'Invalid order request status.';
  end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then
    raise exception 'Invalid pagination parameters.';
  end if;
  return query
    with filtered as (
      select o.id, o.user_id, coalesce(u.email::text, o.guest_email, 'Customer') customer,
        o.product_id,
        case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end product_name,
        case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end product_type,
        o.used_key_id,
        case when o.used_key_id is not null
          then case when o.used_key_expires_on is not null
            then greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)
            else coalesce(o.used_key_remaining_days, o.used_key_validity_days)
          end
        end as used_key_remaining_days,
        o.amount, o.utr_number, o.payment_submitted_at, o.created_at, o.status,
        o.software_plan_label
      from public.orders as o
      left join auth.users as u on u.id = o.user_id
      left join public.products as p on p.id = o.product_id
      where (
        (o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
          and coalesce(o.product_type, p.category, '') in ('software', 'vps'))
        or (o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
          and coalesce(o.product_type, p.category, '') = 'rental')
        or (o.status in ('new', 'completed', 'rejected') and o.offer_claim_id is not null)
      )
        and (p_status = 'all' or o.status = p_status)
        and (v_search = '' or o.id::text ilike '%' || v_search || '%'
          or coalesce(u.email::text, o.guest_email, '') ilike '%' || v_search || '%'
          or coalesce(o.utr_number, '') ilike '%' || v_search || '%'
          or coalesce(o.used_key_id::text, '') ilike '%' || v_search || '%'
          or coalesce(o.software_plan_label, '') ilike '%' || v_search || '%')
    )
    select f.id, f.user_id, f.customer, f.product_id, f.product_name, f.product_type,
      f.used_key_id, f.used_key_remaining_days, f.amount, f.utr_number,
      f.payment_submitted_at, f.created_at, f.status, count(*) over(), f.software_plan_label
    from filtered as f
    order by case f.status when 'new' then 0 when 'completed' then 1 else 2 end,
      f.payment_submitted_at desc nulls last, f.created_at desc
    offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;

create or replace function public.admin_get_order_request(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_used_key private.used_key_inventory%rowtype;
  v_download_link text;
  v_key text;
  v_customer text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id
    and o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
    and o.product_type in ('software', 'vps');
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  v_customer := coalesce(v_order.guest_email, 'Customer');
  if v_order.user_id is not null then
    select coalesce(u.email::text, v_customer) into v_customer
      from auth.users as u where u.id = v_order.user_id;
  end if;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = p_order_id;
  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  if v_order.used_key_id is not null then
    select k.* into v_used_key from private.used_key_inventory as k where k.id = v_order.used_key_id;
    select d.download_url into v_download_link
      from public.product_download_links as d where d.product_id = v_order.product_id;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'user_id', v_order.user_id, 'customer', v_customer,
    'guest_order', v_order.user_id is null, 'guest_email_sent_at', v_order.guest_email_sent_at,
    'product_id', v_order.product_id,
    'product_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_order.product_name)
      else v_order.product_name end,
    'product_type', case when v_order.used_key_id is not null then 'used_key' else coalesce(v_order.product_type, '') end,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp,
    'used_key_id', v_order.used_key_id, 'used_key_expires_on', v_order.used_key_expires_on,
    'used_key_remaining_days', v_order.used_key_remaining_days,
    'guest_email', v_order.guest_email,
    'amount', v_order.amount, 'utr_number', v_order.utr_number,
    'payment_submitted_at', v_order.payment_submitted_at, 'created_at', v_order.created_at,
    'completed_at', v_order.completed_at, 'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_used_key.software_name)
      else coalesce(v_delivery.software_name, v_order.product_name) end,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null
      then coalesce(v_download_link, '') else coalesce(v_delivery.download_link, '') end,
    'vps_ip', coalesce(v_delivery.vps_ip, ''), 'vps_port', v_delivery.vps_port,
    'vps_username', coalesce(v_delivery.vps_username, ''),
    'vps_password', case when v_delivery.vps_password_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_key) end,
    'vps_storage_gb', v_delivery.vps_storage_gb
  );
end;
$$;

create or replace function public.admin_save_order_delivery(p_order_id bigint, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_type text;
  v_name text := btrim(coalesce(p_details ->> 'software_name', ''));
  v_license text := coalesce(p_details ->> 'license_key', '');
  v_link text := btrim(coalesce(p_details ->> 'download_link', ''));
  v_ip text := btrim(coalesce(p_details ->> 'vps_ip', ''));
  v_port text := btrim(coalesce(p_details ->> 'vps_port', ''));
  v_username text := btrim(coalesce(p_details ->> 'vps_username', ''));
  v_password text := coalesce(p_details ->> 'vps_password', '');
  v_storage text := btrim(coalesce(p_details ->> 'vps_storage_gb', ''));
  v_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then
    return jsonb_build_object('ok', false, 'message', 'Order details are invalid.');
  end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id and o.status = 'new' for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be edited.'); end if;
  v_type := coalesce(v_order.product_type, '');
  if length(v_name) > 160 or length(v_license) > 4000 or length(v_link) > 2048
     or length(v_ip) > 64 or length(v_username) > 160 or length(v_password) > 4000 then
    return jsonb_build_object('ok', false, 'message', 'One or more order details exceed the allowed length.');
  end if;
  if v_link <> '' and v_link !~* '^https?://[^[:space:]]+$' then
    return jsonb_build_object('ok', false, 'message', 'Download link must use HTTP or HTTPS.');
  end if;
  if v_type = 'software' then
    if v_port <> '' or v_storage <> '' then
      return jsonb_build_object('ok', false, 'message', 'VPS-only fields are not valid for software orders.');
    end if;
  elsif v_type in ('vps', 'windows-vps') then
    if v_ip <> '' and v_ip !~ '^[0-9A-Fa-f:.]+$' then
      return jsonb_build_object('ok', false, 'message', 'Enter a valid VPS IP address.');
    end if;
    if v_ip <> '' then
      begin
        perform v_ip::inet;
      exception when invalid_text_representation then
        return jsonb_build_object('ok', false, 'message', 'Enter a valid VPS IP address.');
      end;
    end if;
    if v_port <> '' then
      if v_port !~ '^[0-9]{1,5}$' or v_port::integer not between 1 and 65535 then
        return jsonb_build_object('ok', false, 'message', 'VPS port must be between 1 and 65535.');
      end if;
    end if;
    if v_storage <> '' then
      if v_storage !~ '^[0-9]{1,6}$' or v_storage::integer not between 1 and 100000 then
        return jsonb_build_object('ok', false, 'message', 'Storage must be a whole number between 1 and 100,000 GB.');
      end if;
    end if;
  elsif v_type = 'rental' then
    return jsonb_build_object('ok', false, 'message', 'Review rental delivery in the Rental Software panel.');
  end if;

  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  insert into public.order_delivery (
    order_id, software_name, license_key_encrypted, download_link,
    vps_ip, vps_port, vps_username, vps_password_encrypted, vps_storage_gb, updated_at
  ) values (
    p_order_id, v_name,
    case when v_license = '' then null else extensions.pgp_sym_encrypt(v_license, v_key, 'cipher-algo=aes256') end,
    v_link, v_ip, nullif(v_port, '')::integer, v_username,
    case when v_password = '' then null else extensions.pgp_sym_encrypt(v_password, v_key, 'cipher-algo=aes256') end,
    nullif(v_storage, '')::integer, clock_timestamp()
  )
  on conflict (order_id) do update set
    software_name = excluded.software_name,
    license_key_encrypted = excluded.license_key_encrypted,
    download_link = excluded.download_link, vps_ip = excluded.vps_ip,
    vps_port = excluded.vps_port, vps_username = excluded.vps_username,
    vps_password_encrypted = excluded.vps_password_encrypted,
    vps_storage_gb = excluded.vps_storage_gb, updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true, 'message', 'Order details saved.');
end;
$$;

create or replace function public.admin_complete_order(p_order_id bigint, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_saved jsonb;
  v_delivery public.order_delivery%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id and o.status = 'new' for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be completed.'); end if;
  v_saved := public.admin_save_order_delivery(p_order_id, p_details);
  if not coalesce((v_saved ->> 'ok')::boolean, false) then return v_saved; end if;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = p_order_id;
  if v_order.product_type = 'software' then
    if btrim(v_delivery.software_name) = '' or v_delivery.license_key_encrypted is null
       or btrim(v_delivery.download_link) = '' then
      return jsonb_build_object('ok', false, 'message', 'Software name, license key, and download link are required.');
    end if;
  elsif v_order.product_type = 'vps' then
    if btrim(v_delivery.vps_ip) = '' or v_delivery.vps_port is null
       or btrim(v_delivery.vps_username) = '' or v_delivery.vps_password_encrypted is null
       or v_delivery.vps_storage_gb is null then
      return jsonb_build_object('ok', false, 'message', 'All VPS details, including storage, are required.');
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'Unsupported order product type.');
  end if;
  update public.orders set status = 'completed', payment_status = 'paid',
    completed_at = clock_timestamp(), delivered_at = clock_timestamp()
  where id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'completed');
end;
$$;

drop function if exists public.admin_list_rental_requests();
create function public.admin_list_rental_requests()
returns table(
  order_id bigint, customer_email text, software_name text, amount numeric,
  utr_number text, created_at timestamptz, guest_order boolean, status text, email_sent boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select o.id, coalesce(u.email::text, o.guest_email, ''), o.product_name,
      o.amount, o.utr_number, o.payment_submitted_at, o.user_id is null,
      o.status, o.guest_email_sent_at is not null
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    where o.product_type = 'rental'
      and ((o.status = 'new' and o.utr_number is not null)
        or (o.user_id is null and o.status = 'completed' and o.payment_status = 'paid'
          and o.guest_email_sent_at is null))
    order by o.payment_submitted_at desc, o.id desc;
end;
$$;

create or replace function public.admin_guest_order_delivery(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_used_key private.used_key_inventory%rowtype;
  v_rental private.rental_accounts%rowtype;
  v_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id is null and o.guest_email is not null;
  if not found then return jsonb_build_object('ok', false, 'message', 'Guest order was not found.'); end if;
  if v_order.status <> 'completed' or v_order.payment_status <> 'paid' then
    return jsonb_build_object('ok', false, 'message', 'Complete and verify the guest order before sending delivery.');
  end if;
  if v_order.guest_email_sent_at is not null then
    return jsonb_build_object('ok', true, 'email_sent', true);
  end if;
  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = v_order.id;
  if v_order.used_key_id is not null then
    select k.* into v_used_key from private.used_key_inventory as k where k.id = v_order.used_key_id;
  end if;
  if v_order.product_type = 'rental' then
    select a.* into v_rental from private.rental_accounts as a
      where a.id = v_order.rental_account_id and a.lease_order_id = v_order.id
        and a.lease_until > clock_timestamp();
    if not found then return jsonb_build_object('ok', false, 'message', 'Rental access is not available for email delivery.'); end if;
  end if;
  return jsonb_build_object(
    'ok', true, 'email_sent', false, 'order_id', v_order.id,
    'guest_email', v_order.guest_email, 'product_name', v_order.product_name,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null
      then v_used_key.download_link else coalesce(v_delivery.download_link, '') end,
    'vps_ip', coalesce(v_delivery.vps_ip, ''), 'vps_port', v_delivery.vps_port,
    'vps_username', coalesce(v_delivery.vps_username, ''),
    'vps_password', case when v_delivery.vps_password_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_key) else '' end,
    'vps_storage_gb', v_delivery.vps_storage_gb,
    'rental_access', case when v_rental.id is not null
      then extensions.pgp_sym_decrypt(v_rental.account_encrypted, v_key) else '' end
  );
end;
$$;

create or replace function public.admin_mark_guest_order_email_sent(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  update public.orders as o set guest_email_sent_at = coalesce(o.guest_email_sent_at, clock_timestamp())
    where o.id = p_order_id and o.user_id is null and o.guest_email is not null
      and o.status = 'completed' and o.payment_status = 'paid';
  if not found then return jsonb_build_object('ok', false, 'message', 'Completed guest order was not found.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_reject_order_request(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) < 3 or length(v_reason) > 1000 then
    return jsonb_build_object('ok', false, 'message', 'Enter a rejection reason between 3 and 1000 characters.');
  end if;
  update public.orders as o set status = 'rejected', payment_status = 'rejected',
    reject_reason = v_reason, completed_at = null
  where o.id = p_order_id and o.status = 'new';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be rejected.'); end if;
  update public.coupons as c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
  where c.used_order_id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

create or replace function public.admin_reject_product_payment(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) > 4000 then
    return jsonb_build_object('ok', false, 'message', 'Rejection reason must be 4000 characters or fewer.');
  end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status <> 'pending_verification' or v_order.payment_status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'This payment is no longer awaiting verification.');
  end if;
  update public.orders as o set status = 'rejected', payment_status = 'rejected',
    reject_reason = nullif(v_reason, '') where o.id = p_order_id;
  update public.coupons as c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
  where c.used_order_id = p_order_id;
  if v_order.offer_claim_id is not null then
    insert into public.offer_audit_events(actor_id, action, offer_id, claim_id, order_id, details)
    values (
      auth.uid(), 'offer_payment_rejected', v_order.offer_id, v_order.offer_claim_id, v_order.id,
      jsonb_build_object('reason', v_reason, 'utr', v_order.utr)
    );
  end if;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

create or replace function public.admin_refund_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_balance numeric(12, 2);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status = 'refunded' then
    return jsonb_build_object('ok', false, 'message', 'This order has already been refunded.');
  end if;
  if v_order.payment_status <> 'paid' then
    return jsonb_build_object('ok', false, 'message', 'Only paid orders can be refunded to a wallet.');
  end if;
  if v_order.user_id is null then
    return jsonb_build_object('ok', false, 'message', 'Guest orders cannot be refunded to a wallet. Process the refund outside the wallet.');
  end if;
  insert into public.wallets (user_id) values (v_order.user_id) on conflict (user_id) do nothing;
  select w.balance into v_balance from public.wallets as w where w.user_id = v_order.user_id for update;
  update public.wallets as w set balance = w.balance + v_order.price, updated_at = now()
    where w.user_id = v_order.user_id returning w.balance into v_balance;
  update public.orders as o set status = 'refunded' where o.id = v_order.id;
  insert into public.wallet_transactions (user_id, type, amount, note, order_id)
    values (v_order.user_id, 'refund', v_order.price, 'Refund: ' || v_order.product_name, v_order.id);
  return jsonb_build_object('ok', true, 'balance', v_balance, 'amount', v_order.price);
end;
$$;

revoke all on function public.guest_create_order(text, bigint, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_submit_order_utr(bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_get_order(bigint, text) from public, anon, authenticated;
revoke all on function public.guest_claim_demo_key(bigint, text, text, text, text) from public, anon, authenticated;
grant execute on function public.guest_create_order(text, bigint, bigint, text, text, text, text, text, text) to service_role;
grant execute on function public.guest_submit_order_utr(bigint, text, text, text) to service_role;
grant execute on function public.guest_get_order(bigint, text) to service_role;
grant execute on function public.guest_claim_demo_key(bigint, text, text, text, text) to service_role;

revoke all on function public.admin_list_orders() from public, anon;
revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.admin_save_order_delivery(bigint, jsonb) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_list_rental_requests() from public, anon;
revoke all on function public.admin_guest_order_delivery(bigint) from public, anon;
revoke all on function public.admin_mark_guest_order_email_sent(bigint) from public, anon;
revoke all on function public.admin_reject_order_request(bigint, text) from public, anon;
revoke all on function public.admin_reject_product_payment(bigint, text) from public, anon;
revoke all on function public.admin_refund_order(bigint) from public, anon;
grant execute on function public.admin_list_orders() to authenticated;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_request(bigint) to authenticated;
grant execute on function public.admin_save_order_delivery(bigint, jsonb) to authenticated;
grant execute on function public.admin_complete_order(bigint, jsonb) to authenticated;
grant execute on function public.admin_list_rental_requests() to authenticated;
grant execute on function public.admin_guest_order_delivery(bigint) to authenticated;
grant execute on function public.admin_mark_guest_order_email_sent(bigint) to authenticated;
grant execute on function public.admin_reject_order_request(bigint, text) to authenticated;
grant execute on function public.admin_reject_product_payment(bigint, text) to authenticated;
grant execute on function public.admin_refund_order(bigint) to authenticated;

commit;
