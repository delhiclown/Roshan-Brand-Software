begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

alter table public.orders add column if not exists amount numeric(12, 2);
alter table public.orders add column if not exists utr_number text;
alter table public.orders add column if not exists payment_submitted_at timestamptz;
alter table public.orders add column if not exists completed_at timestamptz;
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (
  status in ('unpaid', 'new', 'completed', 'rejected', 'pending_payment',
    'pending', 'pending_verification', 'delivered', 'refunded', 'expired')
);
update public.orders set amount = price where amount is null;
update public.orders set utr_number = utr
  where utr_number is null and utr ~ '^[0-9]{12}$';
update public.orders set payment_submitted_at = utr_submitted_at
  where payment_submitted_at is null and utr_submitted_at is not null;
update public.orders set payment_submitted_at = created_at
  where payment_submitted_at is null and utr_number is not null;
update public.orders set status = 'unpaid'
  where status = 'pending_payment' and payment_method in ('upi_qr', 'upi_app')
    and utr is null and offer_claim_id is null;
update public.orders set status = 'new'
  where status = 'pending_verification' and product_type in ('software', 'vps')
    and utr ~ '^[0-9]{12}$';
alter table public.orders alter column amount set not null;
alter table public.orders drop constraint if exists orders_amount_nonnegative;
alter table public.orders add constraint orders_amount_nonnegative check (amount >= 0);
alter table public.orders drop constraint if exists orders_utr_number_format;
alter table public.orders add constraint orders_utr_number_format
  check (utr_number is null or utr_number ~ '^[0-9]{12}$');
create unique index if not exists orders_utr_number_unique_idx
  on public.orders (utr_number) where utr_number is not null;
create index if not exists orders_request_status_created_idx
  on public.orders (status, created_at desc)
  where status in ('new', 'completed', 'rejected');

create or replace function private.sync_order_request_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.amount := new.price;
  if new.utr_number is null and new.utr ~ '^[0-9]{12}$' then
    new.utr_number := new.utr;
  end if;
  if new.utr is null then new.utr := new.utr_number; end if;
  if new.payment_submitted_at is null then
    new.payment_submitted_at := new.utr_submitted_at;
  end if;
  if new.utr_submitted_at is null then
    new.utr_submitted_at := new.payment_submitted_at;
  end if;
  return new;
end;
$$;
drop trigger if exists sync_order_request_columns on public.orders;
create trigger sync_order_request_columns
  before insert or update on public.orders
  for each row execute function private.sync_order_request_columns();
revoke all on function private.sync_order_request_columns() from public, anon, authenticated;

create table if not exists private.order_delivery_secrets (
  id boolean primary key default true check (id),
  encryption_key text not null
);
insert into private.order_delivery_secrets (id, encryption_key)
  values (true, encode(extensions.gen_random_bytes(32), 'hex'))
  on conflict (id) do nothing;
revoke all on private.order_delivery_secrets from public, anon, authenticated;

create table if not exists public.order_delivery (
  order_id bigint primary key references public.orders(id) on delete cascade,
  software_name text not null default '',
  license_key_encrypted bytea,
  download_link text not null default '',
  vps_ip text not null default '',
  vps_port integer,
  vps_username text not null default '',
  vps_password_encrypted bytea,
  vps_storage_gb integer,
  updated_at timestamptz not null default now()
);
alter table public.order_delivery enable row level security;
revoke all on public.order_delivery from public, anon, authenticated;

create table if not exists private.order_utr_attempts (
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default clock_timestamp()
);
create index if not exists order_utr_attempts_user_time_idx
  on private.order_utr_attempts (user_id, attempted_at desc);
revoke all on private.order_utr_attempts from public, anon, authenticated;

create or replace function public.prepare_product_payment(
  p_order_id bigint, p_product_id bigint, p_coupon_code text, p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_product public.products%rowtype;
  v_order public.orders%rowtype;
  v_coupon public.coupons%rowtype;
  v_coupon_code text := upper(nullif(btrim(coalesce(p_coupon_code, '')), ''));
  v_timeout integer;
  v_grace integer;
  v_created_at timestamptz;
  v_discount numeric(12, 2) := 0;
  v_final numeric(12, 2);
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if p_payment_method not in ('upi_qr', 'upi_app') then
    return jsonb_build_object('ok', false, 'message', 'Choose a supported UPI payment method.');
  end if;
  if not coalesce((
    select case p_payment_method when 'upi_qr' then enable_upi_qr when 'upi_app' then enable_upi_app end
      and length(trim(upi_id)) > 0 and length(trim(upi_payee_name)) > 0
    from public.settings where id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'This payment method is currently unavailable.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and in_stock = true for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Product is unavailable.'); end if;
  if p_order_id is not null then
    select * into v_order from public.orders
      where id = p_order_id and user_id = v_user_id and product_id = p_product_id
        and status = 'unpaid' and utr is null and offer_claim_id is null
        and payment_expires_at > clock_timestamp()
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This payment order can no longer be changed.');
    end if;
  end if;
  if v_coupon_code is not null then
    if v_coupon_code !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' then
      return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
    end if;
    select * into v_coupon from public.coupons
      where user_id = v_user_id and upper(btrim(code)) = v_coupon_code for update;
    if not found then return jsonb_build_object('ok', false, 'message', 'Invalid coupon'); end if;
    if v_coupon.expires_at <= clock_timestamp() or v_coupon.status = 'expired' then
      update public.coupons set status = 'expired'
        where id = v_coupon.id and status = 'unused';
      return jsonb_build_object('ok', false, 'message', 'Coupon expired');
    end if;
    if v_coupon.status = 'used'
       and (v_order.id is null or v_coupon.used_order_id is distinct from v_order.id) then
      return jsonb_build_object('ok', false, 'message', 'Coupon already used');
    end if;
    if v_coupon.status not in ('unused', 'used') then
      return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
    end if;
    v_discount := round(least(
      v_product.price * v_coupon.discount_percent / 100,
      case when v_coupon.max_discount_amount > 0 then v_coupon.max_discount_amount else v_product.price end
    ), 2);
  end if;
  v_final := round(greatest(v_product.price - v_discount, 0), 2);
  if v_final <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The calculated payment amount is invalid.');
  end if;
  if v_order.id is not null and v_order.coupon_code is not null
     and upper(btrim(v_order.coupon_code)) is distinct from v_coupon_code then
    update public.coupons set
      status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null
    where used_order_id = v_order.id;
  end if;
  select payment_timeout_minutes, payment_grace_minutes into v_timeout, v_grace
    from public.payment_timer_config where id = true;
  v_timeout := coalesce(v_timeout, 10);
  v_grace := coalesce(v_grace, 5);
  if v_order.id is null then
    v_created_at := clock_timestamp();
    insert into public.orders (
      user_id, product_id, product_name, product_type, price, status,
      payment_method, payment_status, coupon_code, discount_percent,
      original_price, created_at, payment_expires_at
    ) values (
      v_user_id, v_product.id, v_product.name, v_product.category, v_final,
      'unpaid', p_payment_method, 'pending', v_coupon.code,
      coalesce(v_coupon.discount_percent, 0), v_product.price, v_created_at,
      v_created_at + make_interval(mins => v_timeout)
    ) returning * into v_order;
  else
    update public.orders set
      product_name = v_product.name, product_type = v_product.category,
      price = v_final, payment_method = p_payment_method,
      coupon_code = v_coupon.code, discount_percent = coalesce(v_coupon.discount_percent, 0),
      original_price = v_product.price
    where id = v_order.id returning * into v_order;
  end if;
  if v_coupon.id is not null then
    update public.coupons set status = 'used',
      used_at = coalesce(used_at, clock_timestamp()), used_order_id = v_order.id
    where id = v_coupon.id;
  end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'original_price', v_order.original_price,
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(), 'timeout_minutes', v_timeout, 'grace_minutes', v_grace
  );
end;
$$;

create or replace function public.get_my_pending_product_payment(p_order_id bigint, p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = auth.uid() and product_id = p_product_id
      and payment_method in ('upi_qr', 'upi_app') and status in ('unpaid', 'expired')
      and utr is null and offer_claim_id is null;
  if not found then return jsonb_build_object('ok', false, 'message', 'No active payment order was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true),
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'original_price', v_order.original_price
  );
end;
$$;

create or replace function public.submit_product_payment_utr(p_order_id bigint, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_user_id uuid := auth.uid();
  v_utr text := btrim(coalesce(p_utr, ''));
  v_attempts integer;
  v_late boolean;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select count(*) into v_attempts from private.order_utr_attempts
    where user_id = v_user_id and attempted_at > clock_timestamp() - interval '1 hour';
  if v_attempts >= 5 then
    return jsonb_build_object('ok', false, 'message', 'Too many UTR attempts. Try again in an hour.');
  end if;
  insert into private.order_utr_attempts (user_id) values (v_user_id);
  if v_utr !~ '^[0-9]{12}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid 12-digit UTR / transaction ID.');
  end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = v_user_id
      and payment_method in ('upi_qr', 'upi_app')
      and status in ('unpaid', 'expired') and utr is null and offer_claim_id is null
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This payment order can no longer accept a UTR.');
  end if;
  if exists (select 1 from public.payment_utr_claims where utr_normalized = v_utr)
     or exists (select 1 from public.topup_requests where lower(utr) = lower(v_utr))
     or exists (select 1 from public.orders where utr_number = v_utr) then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  v_late := v_order.status = 'expired'
    or (v_order.payment_expires_at is not null and clock_timestamp() > v_order.payment_expires_at);
  update public.orders set
    utr = v_utr, utr_number = v_utr,
    utr_submitted_at = clock_timestamp(), payment_submitted_at = clock_timestamp(),
    late_payment = v_late,
    status = case when v_order.product_type in ('software', 'vps') then 'new' else 'pending_verification' end,
    payment_status = 'pending'
  where id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id,
    'status', case when v_order.product_type in ('software', 'vps') then 'new' else 'pending_verification' end,
    'late_payment', v_late, 'payment_submitted_at', clock_timestamp()
  );
end;
$$;

create or replace function public.resubmit_order_utr(p_order_id bigint, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_utr text := btrim(coalesce(p_utr, ''));
  v_attempts integer;
  v_order public.orders%rowtype;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select count(*) into v_attempts from private.order_utr_attempts
    where user_id = v_user_id and attempted_at > clock_timestamp() - interval '1 hour';
  if v_attempts >= 5 then
    return jsonb_build_object('ok', false, 'message', 'Too many UTR attempts. Try again in an hour.');
  end if;
  insert into private.order_utr_attempts (user_id) values (v_user_id);
  if v_utr !~ '^[0-9]{12}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid 12-digit UTR / transaction ID.');
  end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = v_user_id and status = 'rejected'
      and payment_method in ('upi_qr', 'upi_app')
      and product_type in ('software', 'vps') for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This order cannot accept a new UTR.');
  end if;
  if exists (select 1 from public.payment_utr_claims where utr_normalized = v_utr)
     or exists (select 1 from public.topup_requests where lower(utr) = lower(v_utr))
     or exists (select 1 from public.orders where utr_number = v_utr) then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  update public.orders set utr = v_utr, utr_number = v_utr,
    utr_submitted_at = clock_timestamp(), payment_submitted_at = clock_timestamp(),
    payment_status = 'pending', reject_reason = null, status = 'new'
    where id = v_order.id;
  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'status', 'new');
end;
$$;

create or replace function public.expire_pending_product_payments()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grace integer;
  v_expired integer;
begin
  select payment_grace_minutes into v_grace
    from public.payment_timer_config where id = true;
  v_grace := coalesce(v_grace, 5);
  update public.orders set status = 'expired', payment_status = 'rejected'
    where status in ('pending_payment', 'unpaid') and utr is null
      and payment_expires_at is not null
      and payment_expires_at + make_interval(mins => v_grace) <= clock_timestamp();
  get diagnostics v_expired = row_count;
  update public.coupons c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
    from public.orders o
    where c.used_order_id = o.id and o.status = 'expired' and o.utr is null
      and o.payment_expires_at + make_interval(mins => v_grace) <= clock_timestamp();
  return v_expired;
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
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query select o.id, o.user_id, coalesce(u.email::text, ''), o.product_name,
      coalesce(o.product_type, p.category, ''), o.price, o.status, o.created_at,
      o.delivery_text, o.delivery_link, o.delivery_note, o.delivered_at,
      o.payment_method, o.payment_status, o.utr, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at, o.late_payment
    from public.orders o
    join auth.users u on u.id = o.user_id
    left join public.products p on p.id = o.product_id
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
  return (select jsonb_build_object(
    'new', count(*) filter (where status = 'new'),
    'completed', count(*) filter (where status = 'completed'),
    'rejected', count(*) filter (where status = 'rejected'),
    'all', count(*)
  ) from public.orders   where status in ('new', 'completed', 'rejected')
    and utr_number is not null and product_type in ('software', 'vps'));
end;
$$;

create or replace function public.admin_list_order_requests(
  p_status text default 'all', p_search text default '', p_page integer default 1, p_page_size integer default 20
)
returns table(
  id bigint, user_id uuid, customer text, product_id bigint, product_name text,
  product_type text, amount numeric, utr_number text, payment_submitted_at timestamptz,
  created_at timestamptz, status text, total_count bigint
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
      select o.id, o.user_id, coalesce(u.email::text, 'Customer') customer,
        o.product_id, o.product_name, coalesce(o.product_type, p.category, '') product_type,
        o.amount, o.utr_number, o.payment_submitted_at, o.created_at, o.status
      from public.orders o
      join auth.users u on u.id = o.user_id
      left join public.products p on p.id = o.product_id
      where o.status in ('new', 'completed', 'rejected')
        and o.utr_number is not null
        and coalesce(o.product_type, p.category, '') in ('software', 'vps')
        and (p_status = 'all' or o.status = p_status)
        and (v_search = '' or o.id::text ilike '%' || v_search || '%'
          or coalesce(u.email::text, '') ilike '%' || v_search || '%'
          or coalesce(o.utr_number, '') ilike '%' || v_search || '%')
    )
    select f.*, count(*) over()
    from filtered f
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
  v_key text;
  v_customer text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders o where o.id = p_order_id
    and status in ('new', 'completed', 'rejected')
    and utr_number is not null and product_type in ('software', 'vps');
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  select coalesce(email::text, 'Customer') into v_customer from auth.users where id = v_order.user_id;
  select * into v_delivery from public.order_delivery where order_id = p_order_id;
  select encryption_key into v_key from private.order_delivery_secrets where id = true;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'customer', v_customer,
    'product_id', v_order.product_id, 'product_name', v_order.product_name,
    'product_type', coalesce(v_order.product_type, ''), 'amount', v_order.amount,
    'utr_number', v_order.utr_number, 'payment_submitted_at', v_order.payment_submitted_at,
    'created_at', v_order.created_at, 'completed_at', v_order.completed_at,
    'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', coalesce(v_delivery.software_name, ''),
    'license_key', case when v_delivery.license_key_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) end,
    'download_link', coalesce(v_delivery.download_link, ''),
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
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then
    return jsonb_build_object('ok', false, 'message', 'Order details are invalid.');
  end if;
  select * into v_order from public.orders where id = p_order_id and status = 'new' for update;
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
  elsif v_type = 'vps' then
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
      if v_port !~ '^[0-9]{1,5}$' then
        return jsonb_build_object('ok', false, 'message', 'VPS port must be between 1 and 65535.');
      end if;
      if v_port::integer not between 1 and 65535 then
        return jsonb_build_object('ok', false, 'message', 'VPS port must be between 1 and 65535.');
      end if;
    end if;
    if v_storage <> '' then
      if v_storage !~ '^[0-9]{1,6}$' then
        return jsonb_build_object('ok', false, 'message', 'Storage must be a whole number between 1 and 100000 GB.');
      end if;
      if v_storage::integer not between 1 and 100000 then
        return jsonb_build_object('ok', false, 'message', 'Storage must be a whole number between 1 and 100000 GB.');
      end if;
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'Unsupported order product type.');
  end if;
  select encryption_key into v_key from private.order_delivery_secrets where id = true;
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
  v_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select * into v_order from public.orders where id = p_order_id and status = 'new' for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be completed.'); end if;
  v_saved := public.admin_save_order_delivery(p_order_id, p_details);
  if not coalesce((v_saved ->> 'ok')::boolean, false) then return v_saved; end if;
  select * into v_delivery from public.order_delivery where order_id = p_order_id;
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

create or replace function public.admin_reject_order_request(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) < 3 or length(v_reason) > 1000 then
    return jsonb_build_object('ok', false, 'message', 'Enter a rejection reason between 3 and 1000 characters.');
  end if;
  update public.orders set status = 'rejected', payment_status = 'rejected',
    reject_reason = v_reason, completed_at = null
  where id = p_order_id and status = 'new';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be rejected.'); end if;
  update public.coupons set
    status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
  where used_order_id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

drop function if exists public.my_orders();
create function public.my_orders()
returns table(
  id bigint, product_id bigint, product_name text, product_type text, price numeric, status text,
  created_at timestamptz, delivery_text text, delivery_link text, delivery_note text,
  delivered_at timestamptz, payment_method text, payment_status text, coupon_code text,
  discount_percent numeric, original_price numeric, reject_reason text, quantity integer,
  offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean,
  amount numeric, utr_number text, payment_submitted_at timestamptz, completed_at timestamptz,
  software_name text, license_key text, download_link text, vps_ip text, vps_port integer,
  vps_username text, vps_password text, vps_storage_gb integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_key text;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  select encryption_key into v_key from private.order_delivery_secrets where id = true;
  return query
    select o.id, o.product_id, o.product_name, coalesce(o.product_type, p.category, ''),
      o.price, o.status, o.created_at,
      case when o.status in ('delivered', 'completed') then o.delivery_text end,
      case when o.status in ('delivered', 'completed') then coalesce(d.download_link, o.delivery_link) end,
      case when o.status in ('delivered', 'completed') then o.delivery_note end,
      o.delivered_at, o.payment_method, o.payment_status, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at, o.late_payment,
      o.amount, o.utr_number, o.payment_submitted_at, o.completed_at,
      case when o.status = 'completed' then d.software_name end,
      case when o.status = 'completed' and d.license_key_encrypted is not null
        then extensions.pgp_sym_decrypt(d.license_key_encrypted, v_key) end,
      case when o.status = 'completed' then d.download_link end,
      case when o.status = 'completed' then d.vps_ip end,
      case when o.status = 'completed' then d.vps_port end,
      case when o.status = 'completed' then d.vps_username end,
      case when o.status = 'completed' and d.vps_password_encrypted is not null
        then extensions.pgp_sym_decrypt(d.vps_password_encrypted, v_key) end,
      case when o.status = 'completed' then d.vps_storage_gb end
    from public.orders o
    left join public.products p on p.id = o.product_id
    left join public.order_delivery d on d.order_id = o.id
    where o.user_id = v_user_id
    order by o.created_at desc limit 50;
end;
$$;

revoke all on function public.prepare_product_payment(bigint, bigint, text, text) from public, anon;
revoke all on function public.get_my_pending_product_payment(bigint, bigint) from public, anon;
revoke all on function public.submit_product_payment_utr(bigint, text) from public, anon;
revoke all on function public.resubmit_order_utr(bigint, text) from public, anon;
revoke all on function public.expire_pending_product_payments() from public, anon, authenticated;
revoke all on function public.admin_list_orders() from public, anon;
revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.admin_save_order_delivery(bigint, jsonb) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_reject_order_request(bigint, text) from public, anon;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.prepare_product_payment(bigint, bigint, text, text) to authenticated;
grant execute on function public.get_my_pending_product_payment(bigint, bigint) to authenticated;
grant execute on function public.submit_product_payment_utr(bigint, text) to authenticated;
grant execute on function public.resubmit_order_utr(bigint, text) to authenticated;
grant execute on function public.admin_list_orders() to authenticated;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_request(bigint) to authenticated;
grant execute on function public.admin_save_order_delivery(bigint, jsonb) to authenticated;
grant execute on function public.admin_complete_order(bigint, jsonb) to authenticated;
grant execute on function public.admin_reject_order_request(bigint, text) to authenticated;
grant execute on function public.my_orders() to authenticated;

commit;
