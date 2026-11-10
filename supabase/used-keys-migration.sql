begin;

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

create table if not exists private.used_key_inventory (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete restrict,
  software_name text not null,
  license_key_encrypted bytea not null,
  license_key_fingerprint bytea not null unique,
  download_link text not null,
  price numeric(12, 2) not null check (price > 0 and price <= 100000),
  regular_price numeric(12, 2) not null check (regular_price > 0),
  expires_on date not null,
  status text not null default 'available' check (status in ('available', 'reserved', 'sold')),
  is_visible boolean not null default true,
  reserved_order_id bigint,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (length(btrim(software_name)) between 1 and 160),
  check (length(btrim(download_link)) between 1 and 2048),
  check (download_link ~* '^https?://[^[:space:]]+$'),
  check (price < regular_price),
  check ((status = 'reserved') = (reserved_order_id is not null))
);
-- Keep raw license values encrypted and use a keyed fingerprint to reject duplicates.
create index if not exists used_key_inventory_available_idx
  on private.used_key_inventory (expires_on, created_at desc)
  where status = 'available' and is_visible;
revoke all on private.used_key_inventory from public, anon, authenticated;

alter table public.orders add column if not exists used_key_id bigint
  references private.used_key_inventory(id);
alter table public.orders add column if not exists used_key_fingerprint bytea;
alter table public.orders add column if not exists used_key_expires_on date;
alter table public.orders add column if not exists used_key_remaining_days integer
  check (used_key_remaining_days is null or used_key_remaining_days >= 0);

create or replace function public.list_available_used_keys()
returns table(
  id bigint, software_name text, remaining_days integer, price numeric, regular_price numeric, image_url text
)
language sql
security definer
set search_path = ''
as $$
  select k.id, coalesce(p.name, k.software_name),
    greatest(k.expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0),
    k.price, k.regular_price, p.image_url
  from private.used_key_inventory k
  join public.products p on p.id = k.product_id
  where k.status = 'available' and k.is_visible
    and k.expires_on >= (timezone('Asia/Kolkata', clock_timestamp()))::date
  order by k.created_at desc, k.id desc;
$$;

create or replace function public.admin_list_used_keys()
returns table(
  id bigint, product_id bigint, software_name text, license_key text,
  download_link text, price numeric, regular_price numeric, expires_on date,
  status text, is_visible boolean, reserved_order_id bigint, remaining_days integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_encryption_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select encryption_key into v_encryption_key from private.order_delivery_secrets where id = true;
  return query
    select k.id, k.product_id, k.software_name,
      extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key),
      k.download_link, k.price, k.regular_price, k.expires_on, k.status, k.is_visible,
      k.reserved_order_id,
      greatest(k.expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)
    from private.used_key_inventory k
    order by k.created_at desc, k.id desc;
end;
$$;

create or replace function public.admin_save_used_key(
  p_id bigint, p_product_id bigint, p_license_key text, p_download_link text,
  p_price numeric, p_expires_on date, p_is_visible boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
  v_current private.used_key_inventory%rowtype;
  v_license text := btrim(coalesce(p_license_key, ''));
  v_link text := btrim(coalesce(p_download_link, ''));
  v_encryption_key text;
  v_regular_price numeric(12, 2);
  v_id bigint;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if v_license = '' or length(v_license) > 4000 or v_license ~ '[[:cntrl:]]' then
    return jsonb_build_object('ok', false, 'message', 'License key must be 1–4000 printable characters.');
  end if;
  if length(v_link) > 2048 or v_link !~* '^https?://[^[:space:]]+$' then
    return jsonb_build_object('ok', false, 'message', 'Download link must use HTTP or HTTPS and be at most 2048 characters.');
  end if;
  if p_price is null or p_price <= 0 or p_price > 100000
     or p_expires_on is null
     or p_expires_on < (timezone('Asia/Kolkata', clock_timestamp()))::date then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid price and an expiry date that has not passed.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'Choose an existing Software product.'); end if;
  v_regular_price := coalesce(v_product.original_price, v_product.selling_price, v_product.price);
  if p_price >= v_regular_price then
    return jsonb_build_object('ok', false, 'message', 'Used Key price must be lower than the regular Software price.');
  end if;
  select encryption_key into v_encryption_key from private.order_delivery_secrets where id = true;
  if p_id is null then
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on, is_visible
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_link, p_price,
      v_regular_price,
      p_expires_on, coalesce(p_is_visible, true)
    ) returning id into v_id;
  else
    select * into v_current from private.used_key_inventory where id = p_id for update;
    if not found or v_current.status <> 'available' then
      return jsonb_build_object('ok', false, 'message', 'Only available keys can be edited.');
    end if;
    if exists (
      select 1 from private.used_key_inventory
      where license_key_fingerprint = extensions.hmac(v_license, v_encryption_key, 'sha256') and id <> p_id
    ) then
      return jsonb_build_object('ok', false, 'message', 'This license key is already in inventory.');
    end if;
    update private.used_key_inventory set
      product_id = v_product.id, software_name = v_product.name,
      license_key_encrypted = extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      license_key_fingerprint = extensions.hmac(v_license, v_encryption_key, 'sha256'),
      download_link = v_link, price = p_price,
      regular_price = v_regular_price,
      expires_on = p_expires_on, is_visible = coalesce(p_is_visible, true),
      updated_at = clock_timestamp()
    where id = p_id returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'This license key is already in inventory.');
end;
$$;

create or replace function public.admin_bulk_add_used_keys(
  p_product_id bigint, p_license_keys jsonb, p_download_link text,
  p_price numeric, p_expires_on date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
  v_encryption_key text;
  v_item text;
  v_json_item jsonb;
  v_link text := btrim(coalesce(p_download_link, ''));
  v_count integer := 0;
  v_fingerprint bytea;
  v_regular_price numeric(12, 2);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_license_keys) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 keys at a time.');
  end if;
  if jsonb_array_length(p_license_keys) not between 1 and 100 then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 keys at a time.');
  end if;
  if length(v_link) > 2048 or v_link !~* '^https?://[^[:space:]]+$'
     or p_price is null or p_price <= 0 or p_price > 100000
     or p_expires_on is null
     or p_expires_on < (timezone('Asia/Kolkata', clock_timestamp()))::date then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid download link, price, and an expiry date that has not passed.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'Choose an existing Software product.'); end if;
  v_regular_price := coalesce(v_product.original_price, v_product.selling_price, v_product.price);
  if p_price >= v_regular_price then
    return jsonb_build_object('ok', false, 'message', 'Used Key price must be lower than the regular Software price.');
  end if;
  select encryption_key into v_encryption_key from private.order_delivery_secrets where id = true;
  for v_json_item in select value from jsonb_array_elements(p_license_keys) as item(value) loop
    if jsonb_typeof(v_json_item) <> 'string' then
      return jsonb_build_object('ok', false, 'message', 'Each bulk license key must be text.');
    end if;
    v_item := btrim(v_json_item #>> '{}');
    if v_item = '' or length(v_item) > 4000 or v_item ~ '[[:cntrl:]]' then
      return jsonb_build_object('ok', false, 'message', 'Each license key must be 1–4000 printable characters.');
    end if;
  end loop;
  for v_json_item in select value from jsonb_array_elements(p_license_keys) as item(value) loop
    v_item := btrim(v_json_item #>> '{}');
    v_fingerprint := extensions.hmac(v_item, v_encryption_key, 'sha256');
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_item, v_encryption_key, 'cipher-algo=aes256'),
      v_fingerprint, v_link, p_price,
      v_regular_price,
      p_expires_on
    );
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_count);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'A license key in this batch already exists in inventory.');
end;
$$;

create or replace function public.admin_set_used_key_visibility(p_id bigint, p_is_visible boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  update private.used_key_inventory set is_visible = p_is_visible, updated_at = clock_timestamp()
  where id = p_id and status = 'available';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only available keys can be hidden or shown.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_delete_used_key(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_item private.used_key_inventory%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select * into v_item from private.used_key_inventory where id = p_id for update;
  if not found or v_item.status <> 'available' then
    return jsonb_build_object('ok', false, 'message', 'Only available keys can be deleted.');
  end if;
  if exists (select 1 from public.orders where used_key_id = p_id) then
    return jsonb_build_object('ok', false, 'message', 'This key is linked to an order; hide it instead.');
  end if;
  delete from private.used_key_inventory where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.prepare_used_key_payment(p_used_key_id bigint, p_order_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_item private.used_key_inventory%rowtype;
  v_order public.orders%rowtype;
  v_timeout integer;
  v_grace integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if not coalesce((
    select enable_upi_qr and length(trim(upi_id)) > 0 and length(trim(upi_payee_name)) > 0
    from public.settings where id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'UPI QR payments are currently unavailable.');
  end if;
  select * into v_item from private.used_key_inventory
    where id = p_used_key_id and status = 'available' and is_visible
      and expires_on >= (timezone('Asia/Kolkata', v_now))::date
    for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'This used key is no longer available.'); end if;
  select payment_timeout_minutes, payment_grace_minutes into v_timeout, v_grace
    from public.payment_timer_config where id = true;
  v_timeout := coalesce(v_timeout, 10);
  v_grace := coalesce(v_grace, 5);
  if p_order_id is null then
    insert into public.orders (
      user_id, product_id, product_name, product_type, price, status,
      payment_method, payment_status, coupon_code, discount_percent, original_price,
      amount, created_at, payment_expires_at, used_key_id, used_key_expires_on, used_key_fingerprint
    ) values (
      v_user_id, v_item.product_id, v_item.software_name, 'software', v_item.price,
      'pending_payment', 'upi_qr', 'pending', null, 0, v_item.regular_price,
      v_item.price, v_now, v_now + make_interval(mins => v_timeout),
      v_item.id, v_item.expires_on, v_item.license_key_fingerprint
    ) returning * into v_order;
  else
    select * into v_order from public.orders
      where id = p_order_id and user_id = v_user_id and used_key_id = v_item.id
        and status = 'pending_payment' and utr is null
        and payment_expires_at > v_now
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This payment order can no longer be changed.');
    end if;
  end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_item.price, 'payment_method', 'upi_qr', 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', v_now,
    'timeout_minutes', v_timeout, 'grace_minutes', v_grace
  );
end;
$$;

create or replace function public.get_my_pending_used_key_payment(p_order_id bigint, p_used_key_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = auth.uid() and used_key_id = p_used_key_id
      and status in ('pending_payment', 'expired') and utr is null;
  if not found then return jsonb_build_object('ok', false, 'message', 'No resumable Used Keys payment was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true)
  );
end;
$$;

create or replace function private.guard_used_key_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item private.used_key_inventory%rowtype;
  v_today date := (timezone('Asia/Kolkata', clock_timestamp()))::date;
begin
  if tg_op = 'INSERT' then
    if new.used_key_id is null then return new; end if;
    select * into v_item from private.used_key_inventory where id = new.used_key_id for share;
    if not found or new.product_id <> v_item.product_id or new.price <> v_item.price
       or new.product_type <> 'software' or new.payment_method <> 'upi_qr'
       or new.status <> 'pending_payment' or new.payment_status <> 'pending'
       or new.quantity <> 1 or new.coupon_code is not null or new.discount_percent <> 0
       or new.offer_id is not null or new.offer_claim_id is not null or new.is_offer_free
       or new.used_key_expires_on is distinct from v_item.expires_on
       or new.used_key_fingerprint is distinct from v_item.license_key_fingerprint then
      raise exception 'Used Keys checkout details are invalid.';
    end if;
    return new;
  end if;
  if old.used_key_id is null then return new; end if;
  select * into v_item from private.used_key_inventory where id = new.used_key_id for share;
  if not found or new.product_id is distinct from v_item.product_id
     or new.price is distinct from v_item.price
     or new.product_name is distinct from v_item.software_name
     or new.used_key_expires_on is distinct from v_item.expires_on
     or new.used_key_fingerprint is distinct from v_item.license_key_fingerprint then
    raise exception 'This used key changed after checkout. Start a new order at the current price.';
  end if;
  if new.used_key_id is distinct from old.used_key_id
     or new.used_key_fingerprint is distinct from old.used_key_fingerprint
     or new.product_id is distinct from old.product_id
     or new.product_name is distinct from old.product_name
     or new.product_type is distinct from old.product_type
     or new.price is distinct from old.price
     or new.amount is distinct from old.amount
     or new.original_price is distinct from old.original_price
     or new.payment_method <> 'upi_qr'
     or new.coupon_code is not null or new.discount_percent <> 0
     or new.offer_id is not null or new.offer_claim_id is not null or new.is_offer_free
     or new.used_key_expires_on is distinct from old.used_key_expires_on then
    raise exception 'Used Keys orders cannot change price, key, or coupon.';
  end if;
  if new.status = 'new' and old.status is distinct from 'new' then
    -- Reserve only after the existing UTR flow accepts the payment reference.
    update private.used_key_inventory set
      status = 'reserved', reserved_order_id = new.id, updated_at = clock_timestamp()
    where id = new.used_key_id and status = 'available' and is_visible
      and expires_on >= v_today;
    if not found then raise exception 'This used key is no longer available.'; end if;
    new.used_key_remaining_days := greatest(new.used_key_expires_on - v_today, 0);
  elsif new.status = 'rejected' and old.status = 'new' then
    update private.used_key_inventory set
      status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where id = old.used_key_id and status = 'reserved' and reserved_order_id = old.id;
    if not found then raise exception 'The used key reservation could not be released.'; end if;
  elsif new.status = 'completed' and old.status = 'new' then
    update private.used_key_inventory set
      status = 'sold', reserved_order_id = null, updated_at = clock_timestamp()
    where id = old.used_key_id and status = 'reserved' and reserved_order_id = old.id;
    if not found then raise exception 'The used key reservation is no longer valid.'; end if;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_used_key_order on public.orders;
create trigger guard_used_key_order
  before insert or update on public.orders
  for each row execute function private.guard_used_key_order();
revoke all on function private.guard_used_key_order() from public, anon, authenticated;

create or replace function private.release_deleted_used_key_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.used_key_id is not null then
    update private.used_key_inventory set
      status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where id = old.used_key_id and status = 'reserved' and reserved_order_id = old.id;
  end if;
  return old;
end;
$$;
drop trigger if exists release_deleted_used_key_order on public.orders;
create trigger release_deleted_used_key_order
  after delete on public.orders
  for each row execute function private.release_deleted_used_key_order();
revoke all on function private.release_deleted_used_key_order() from public, anon, authenticated;

create or replace function private.lock_used_key_delivery()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_used_key_id bigint;
  v_license text;
  v_encryption_key text;
begin
  select used_key_id into v_used_key_id from public.orders where id = new.order_id;
  if v_used_key_id is null then return new; end if;
  select encryption_key into v_encryption_key from private.order_delivery_secrets where id = true;
  select software_name, download_link,
    extensions.pgp_sym_decrypt(license_key_encrypted, v_encryption_key)
  into new.software_name, new.download_link, v_license
  from private.used_key_inventory where id = v_used_key_id;
  if v_license is null then raise exception 'The reserved used key could not be loaded.'; end if;
  new.license_key_encrypted := extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256');
  return new;
end;
$$;
drop trigger if exists lock_used_key_delivery on public.order_delivery;
create trigger lock_used_key_delivery
  before insert or update on public.order_delivery
  for each row execute function private.lock_used_key_delivery();
revoke all on function private.lock_used_key_delivery() from public, anon, authenticated;

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
  ) from public.orders
    where status in ('new', 'completed', 'rejected')
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
  if p_status not in ('all', 'new', 'completed', 'rejected') then raise exception 'Invalid order request status.'; end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then raise exception 'Invalid pagination parameters.'; end if;
  return query
    with filtered as (
      select o.id, o.user_id, coalesce(u.email::text, 'Customer') customer,
        o.product_id, o.product_name,
        case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end product_type,
        o.amount, o.utr_number, o.payment_submitted_at, o.created_at, o.status
      from public.orders o
      join auth.users u on u.id = o.user_id
      left join public.products p on p.id = o.product_id
      where o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
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
  v_used_key private.used_key_inventory%rowtype;
  v_key text;
  v_customer text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders o where o.id = p_order_id
    and status in ('new', 'completed', 'rejected') and utr_number is not null
    and product_type in ('software', 'vps');
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  select coalesce(email::text, 'Customer') into v_customer from auth.users where id = v_order.user_id;
  select * into v_delivery from public.order_delivery where order_id = p_order_id;
  select encryption_key into v_key from private.order_delivery_secrets where id = true;
  if v_order.used_key_id is not null then
    select * into v_used_key from private.used_key_inventory where id = v_order.used_key_id;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'customer', v_customer,
    'product_id', v_order.product_id, 'product_name', v_order.product_name,
    'product_type', case when v_order.used_key_id is not null then 'used_key' else coalesce(v_order.product_type, '') end,
    'used_key_id', v_order.used_key_id, 'used_key_expires_on', v_order.used_key_expires_on,
    'amount', v_order.amount, 'utr_number', v_order.utr_number,
    'payment_submitted_at', v_order.payment_submitted_at, 'created_at', v_order.created_at,
    'completed_at', v_order.completed_at, 'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', case when v_order.used_key_id is not null then v_used_key.software_name else coalesce(v_delivery.software_name, '') end,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null then v_used_key.download_link else coalesce(v_delivery.download_link, '') end,
    'vps_ip', coalesce(v_delivery.vps_ip, ''), 'vps_port', v_delivery.vps_port,
    'vps_username', coalesce(v_delivery.vps_username, ''),
    'vps_password', case when v_delivery.vps_password_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_key) end,
    'vps_storage_gb', v_delivery.vps_storage_gb
  );
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
  vps_username text, vps_password text, vps_storage_gb integer, used_key_id bigint
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
    select o.id, o.product_id, o.product_name,
      case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end,
      o.price, o.status, o.created_at,
      case when o.status in ('delivered', 'completed') then o.delivery_text end,
      case when o.status in ('delivered', 'completed') then coalesce(d.download_link, o.delivery_link) end,
      case when o.status in ('delivered', 'completed') and o.used_key_id is not null
        then 'Remaining validity: ' || greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)::text || ' days'
        when o.status in ('delivered', 'completed') then o.delivery_note end,
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
      case when o.status = 'completed' then d.vps_storage_gb end,
      o.used_key_id
    from public.orders o
    left join public.products p on p.id = o.product_id
    left join public.order_delivery d on d.order_id = o.id
    where o.user_id = v_user_id
    order by o.created_at desc limit 50;
end;
$$;

revoke all on function public.list_available_used_keys() from public;
revoke all on function public.admin_list_used_keys() from public, anon;
revoke all on function public.admin_save_used_key(bigint, bigint, text, text, numeric, date, boolean) from public, anon;
revoke all on function public.admin_bulk_add_used_keys(bigint, jsonb, text, numeric, date) from public, anon;
revoke all on function public.admin_set_used_key_visibility(bigint, boolean) from public, anon;
revoke all on function public.admin_delete_used_key(bigint) from public, anon;
revoke all on function public.prepare_used_key_payment(bigint, bigint) from public, anon;
revoke all on function public.get_my_pending_used_key_payment(bigint, bigint) from public, anon;
revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.list_available_used_keys() to anon, authenticated;
grant execute on function public.admin_list_used_keys() to authenticated;
grant execute on function public.admin_save_used_key(bigint, bigint, text, text, numeric, date, boolean) to authenticated;
grant execute on function public.admin_bulk_add_used_keys(bigint, jsonb, text, numeric, date) to authenticated;
grant execute on function public.admin_set_used_key_visibility(bigint, boolean) to authenticated;
grant execute on function public.admin_delete_used_key(bigint) to authenticated;
grant execute on function public.prepare_used_key_payment(bigint, bigint) to authenticated;
grant execute on function public.get_my_pending_used_key_payment(bigint, bigint) to authenticated;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_request(bigint) to authenticated;
grant execute on function public.my_orders() to authenticated;

commit;
