begin;

alter table private.used_key_inventory
  add column if not exists validity_days integer;
alter table public.orders
  add column if not exists used_key_validity_days integer;

update public.orders as o
set used_key_validity_days = greatest(coalesce(
  o.used_key_remaining_days,
  o.used_key_expires_on - (timezone('Asia/Kolkata', coalesce(o.payment_submitted_at, o.created_at)))::date,
  1
), 1)
where o.used_key_id is not null and o.used_key_validity_days is null;

update private.used_key_inventory as k
set validity_days = greatest(coalesce(
  (select o.used_key_validity_days
   from public.orders as o
   where o.used_key_id = k.id
   order by case when o.status = 'completed' then 0 else 1 end, o.created_at desc
   limit 1),
  k.expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date,
  1
), 1)
where k.validity_days is null;

alter table private.used_key_inventory
  alter column validity_days set not null;
alter table private.used_key_inventory
  drop constraint if exists used_key_inventory_validity_days_check;
alter table private.used_key_inventory
  add constraint used_key_inventory_validity_days_check check (validity_days > 0);
alter table public.orders
  drop constraint if exists orders_used_key_validity_days_check;
alter table public.orders
  add constraint orders_used_key_validity_days_check
  check (used_key_validity_days is null or used_key_validity_days > 0);

update private.used_key_inventory as k
set status = 'hidden', is_visible = false, updated_at = clock_timestamp()
where k.status = 'available'
  and k.expires_on < (timezone('Asia/Kolkata', clock_timestamp()))::date;

drop function if exists public.admin_save_used_key(bigint, bigint, text, text, numeric, date, boolean);
drop function if exists public.admin_save_used_key(bigint, bigint, text, numeric, integer, boolean);
drop function if exists public.admin_bulk_add_used_keys(bigint, jsonb, text, numeric, date);
drop function if exists public.admin_list_used_keys();

create or replace function public.admin_list_used_keys()
returns table(
  id bigint, product_id bigint, software_name text, license_key text,
  download_link text, price numeric, regular_price numeric, validity_days integer,
  status text, is_visible boolean, reserved_order_id bigint, remaining_days integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_encryption_key text;
  v_today date := (timezone('Asia/Kolkata', clock_timestamp()))::date;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  return query
    select k.id, k.product_id, coalesce(p.name, k.software_name),
      extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key),
      coalesce(dl.download_url, ''), k.price, k.regular_price, k.validity_days,
      k.status, k.is_visible, k.reserved_order_id,
      case when k.status in ('available', 'hidden') then k.validity_days
        else coalesce((
          select case when o.used_key_expires_on is not null
            then greatest(o.used_key_expires_on - v_today, 0)
            else coalesce(o.used_key_remaining_days, k.validity_days) end
          from public.orders as o
          where o.used_key_id = k.id
          order by case when o.status = 'completed' then 0 else 1 end, o.created_at desc
          limit 1
        ), k.validity_days)
      end
    from private.used_key_inventory as k
    left join public.products as p on p.id = k.product_id
    left join public.product_download_links as dl on dl.product_id = k.product_id
    order by k.created_at desc, k.id desc;
end;
$$;

create or replace function public.admin_save_used_key(
  p_id bigint, p_product_id bigint, p_license_key text,
  p_price numeric, p_validity_days integer, p_is_visible boolean default true
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
  v_download_link text;
  v_encryption_key text;
  v_regular_price numeric(12, 2);
  v_id bigint;
  v_visible boolean := coalesce(p_is_visible, true);
  v_today date := (timezone('Asia/Kolkata', clock_timestamp()))::date;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if v_license = '' or length(v_license) > 4000 or v_license ~ '[[:cntrl:]]' then
    return jsonb_build_object('ok', false, 'message', 'License key must be 1–4000 printable characters.');
  end if;
  if p_price is null or p_price <= 0 or p_price > 100000
     or p_validity_days is null or p_validity_days not between 1 and 36500 then
    return jsonb_build_object('ok', false, 'message', 'Enter a positive price and validity between 1 and 36500 days.');
  end if;
  select p.* into v_product
  from public.products as p
  where p.id = p_product_id and p.category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'Choose an existing Software product.'); end if;
  select dl.download_url into v_download_link
  from public.product_download_links as dl where dl.product_id = v_product.id;
  if v_download_link is null then
    return jsonb_build_object('ok', false, 'message', 'Add a Download Link to this Software product first.');
  end if;
  v_regular_price := coalesce(v_product.original_price, v_product.selling_price, v_product.price);
  if p_price >= v_regular_price then
    return jsonb_build_object('ok', false, 'message', 'Used Key price must be lower than the regular Software price.');
  end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  if p_id is null then
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on, validity_days, is_visible, status
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_download_link, p_price,
      v_regular_price, v_today + p_validity_days, p_validity_days, v_visible,
      case when v_visible then 'available' else 'hidden' end
    ) returning id into v_id;
  else
    select k.* into v_current
    from private.used_key_inventory as k
    where k.id = p_id
    for update;
    if not found or v_current.status not in ('available', 'hidden') then
      return jsonb_build_object('ok', false, 'message', 'Only available or hidden keys can be edited.');
    end if;
    if exists (
      select 1 from private.used_key_inventory as other_key
      where other_key.license_key_fingerprint = extensions.hmac(v_license, v_encryption_key, 'sha256')
        and other_key.id <> p_id
    ) then
      return jsonb_build_object('ok', false, 'message', 'This license key is already in inventory.');
    end if;
    update private.used_key_inventory as k set
      product_id = v_product.id, software_name = v_product.name,
      license_key_encrypted = extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      license_key_fingerprint = extensions.hmac(v_license, v_encryption_key, 'sha256'),
      download_link = v_download_link, price = p_price, regular_price = v_regular_price,
      expires_on = v_today + p_validity_days, validity_days = p_validity_days,
      is_visible = v_visible, status = case when v_visible then 'available' else 'hidden' end,
      updated_at = clock_timestamp()
    where k.id = p_id
    returning k.id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'This license key is already in inventory.');
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
  update private.used_key_inventory as k
  set is_visible = p_is_visible,
      status = case when p_is_visible then 'available' else 'hidden' end,
      updated_at = clock_timestamp()
  where k.id = p_id and k.status in ('available', 'hidden');
  if not found then return jsonb_build_object('ok', false, 'message', 'Only available or hidden keys can be changed.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_delete_used_key(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item private.used_key_inventory%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select k.* into v_item
  from private.used_key_inventory as k where k.id = p_id for update;
  if not found or v_item.status not in ('available', 'hidden') then
    return jsonb_build_object('ok', false, 'message', 'Only available or hidden keys can be deleted.');
  end if;
  if exists (select 1 from public.orders as o where o.used_key_id = p_id) then
    return jsonb_build_object('ok', false, 'message', 'This key is linked to an order; hide it instead.');
  end if;
  delete from private.used_key_inventory as k where k.id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_bulk_add_used_keys_with_details(
  p_product_id bigint, p_keys jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
  v_encryption_key text;
  v_download_link text;
  v_row jsonb;
  v_license text;
  v_price numeric(12, 2);
  v_validity_days integer;
  v_regular_price numeric(12, 2);
  v_count integer := 0;
  v_today date := (timezone('Asia/Kolkata', clock_timestamp()))::date;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_keys) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 key records.');
  end if;
  if jsonb_array_length(p_keys) not between 1 and 100 then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 key records.');
  end if;
  select p.* into v_product
  from public.products as p
  where p.id = p_product_id and p.category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'Choose an existing Software product.'); end if;
  select dl.download_url into v_download_link
  from public.product_download_links as dl where dl.product_id = v_product.id;
  if v_download_link is null then
    return jsonb_build_object('ok', false, 'message', 'Add a Download Link to this Software product first.');
  end if;
  v_regular_price := coalesce(v_product.original_price, v_product.selling_price, v_product.price);
  for v_row in select item.value from jsonb_array_elements(p_keys) as item(value) loop
    if jsonb_typeof(v_row) <> 'object'
       or jsonb_typeof(v_row -> 'license_key') <> 'string'
       or coalesce(v_row ->> 'price', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
       or coalesce(v_row ->> 'validity_days', '') !~ '^[0-9]+$' then
      raise exception 'Each bulk row needs a text key, price, and whole-number days.';
    end if;
    v_license := btrim(v_row ->> 'license_key');
    v_price := (v_row ->> 'price')::numeric;
    v_validity_days := (v_row ->> 'validity_days')::integer;
    if v_license = '' or length(v_license) > 4000 or v_license ~ '[[:cntrl:]]' then
      raise exception 'Each license key must be 1–4000 printable characters.';
    end if;
    if v_price <= 0 or v_price > 100000 or v_price >= v_regular_price then
      raise exception 'Each Used Key price must be positive, no more than ₹100,000, and lower than the regular price.';
    end if;
    if v_validity_days not between 1 and 36500 then
      raise exception 'Each key validity must be between 1 and 36500 days.';
    end if;
  end loop;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  for v_row in select item.value from jsonb_array_elements(p_keys) as item(value) loop
    v_license := btrim(v_row ->> 'license_key');
    v_price := (v_row ->> 'price')::numeric;
    v_validity_days := (v_row ->> 'validity_days')::integer;
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on, validity_days
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_download_link,
      v_price, v_regular_price, v_today + v_validity_days, v_validity_days
    );
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_count);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'message', 'A license key in this batch already exists in inventory.');
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'message', 'Enter a whole-number price and validity for every key.');
  when numeric_value_out_of_range then
    return jsonb_build_object('ok', false, 'message', 'Each price or validity must be within its allowed range.');
end;
$$;

create or replace function public.list_available_used_keys()
returns table(
  id bigint, software_name text, remaining_days integer, price numeric,
  regular_price numeric, image_url text
)
language sql
security definer
set search_path = ''
as $$
  select k.id, coalesce(p.name, k.software_name), k.validity_days,
    k.price, k.regular_price, p.image_url
  from private.used_key_inventory as k
  join public.products as p on p.id = k.product_id
  where k.status = 'available' and k.is_visible and k.validity_days > 0
    and exists (
      select 1 from public.product_download_links as dl
      where dl.product_id = k.product_id
    )
  order by k.created_at desc, k.id desc;
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
  v_product public.products%rowtype;
  v_order public.orders%rowtype;
  v_timeout integer;
  v_grace integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if not coalesce((
    select s.enable_upi_qr and length(trim(s.upi_id)) > 0 and length(trim(s.upi_payee_name)) > 0
    from public.settings as s where s.id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'UPI QR payments are currently unavailable.');
  end if;
  select k.* into v_item
  from private.used_key_inventory as k
  where k.id = p_used_key_id and k.status = 'available' and k.is_visible
    and k.validity_days > 0
    and exists (
      select 1 from public.product_download_links as dl where dl.product_id = k.product_id
    )
  for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'This used key is no longer available.'); end if;
  select p.* into v_product from public.products as p
  where p.id = v_item.product_id and p.category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'This Software product is unavailable.'); end if;
  select c.payment_timeout_minutes, c.payment_grace_minutes into v_timeout, v_grace
  from public.payment_timer_config as c where c.id = true;
  v_timeout := coalesce(v_timeout, 10);
  v_grace := coalesce(v_grace, 5);
  if p_order_id is null then
    insert into public.orders (
      user_id, product_id, product_name, product_type, price, status,
      payment_method, payment_status, coupon_code, discount_percent, original_price,
      amount, created_at, payment_expires_at, used_key_id, used_key_validity_days,
      used_key_expires_on, used_key_fingerprint
    ) values (
      v_user_id, v_item.product_id, v_product.name, 'software', v_item.price,
      'pending_payment', 'upi_qr', 'pending', null, 0, v_item.regular_price,
      v_item.price, v_now, v_now + make_interval(mins => v_timeout),
      v_item.id, v_item.validity_days, null, v_item.license_key_fingerprint
    ) returning * into v_order;
  else
    select o.* into v_order
    from public.orders as o
    where o.id = p_order_id and o.user_id = v_user_id and o.used_key_id = v_item.id
      and o.status = 'pending_payment' and o.utr is null
      and o.payment_expires_at > v_now
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
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select o.* into v_order from public.orders as o
  where o.id = p_order_id and o.user_id = auth.uid() and o.used_key_id = p_used_key_id
    and o.status in ('pending_payment', 'expired') and o.utr is null;
  if not found then return jsonb_build_object('ok', false, 'message', 'No resumable Used Keys payment was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(),
    'grace_minutes', (select c.payment_grace_minutes
      from public.payment_timer_config as c where c.id = true)
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
    select k.* into v_item
    from private.used_key_inventory as k where k.id = new.used_key_id for share;
    if not found or new.product_id <> v_item.product_id or new.price <> v_item.price
       or new.product_type <> 'software' or new.payment_method <> 'upi_qr'
       or new.status <> 'pending_payment' or new.payment_status <> 'pending'
       or new.quantity <> 1 or new.coupon_code is not null or new.discount_percent <> 0
       or new.offer_id is not null or new.offer_claim_id is not null or new.is_offer_free
       or new.used_key_validity_days is distinct from v_item.validity_days
       or new.used_key_expires_on is not null
       or new.used_key_fingerprint is distinct from v_item.license_key_fingerprint then
      raise exception 'Used Keys checkout details are invalid.';
    end if;
    return new;
  end if;
  if old.used_key_id is null then return new; end if;
  select k.* into v_item
  from private.used_key_inventory as k where k.id = new.used_key_id for share;
  if not found or new.product_id is distinct from v_item.product_id
     or new.price is distinct from v_item.price
     or new.used_key_validity_days is distinct from v_item.validity_days
     or new.used_key_fingerprint is distinct from v_item.license_key_fingerprint then
    raise exception 'This used key changed after checkout. Start a new order at the current price.';
  end if;
  if new.used_key_id is distinct from old.used_key_id
     or new.used_key_fingerprint is distinct from old.used_key_fingerprint
     or new.product_id is distinct from old.product_id
     or new.product_type is distinct from old.product_type
     or new.price is distinct from old.price
     or new.amount is distinct from old.amount
     or new.original_price is distinct from old.original_price
     or new.payment_method <> 'upi_qr'
     or new.coupon_code is not null or new.discount_percent <> 0
     or new.offer_id is not null or new.offer_claim_id is not null or new.is_offer_free
     or (new.used_key_expires_on is distinct from old.used_key_expires_on
         and not (new.status = 'completed' and old.status = 'new')) then
    raise exception 'Used Keys orders cannot change price, key, or coupon.';
  end if;
  if new.status = 'new' and old.status is distinct from 'new' then
    update private.used_key_inventory as k
    set status = 'reserved', reserved_order_id = new.id, updated_at = clock_timestamp()
    where k.id = new.used_key_id and k.status = 'available' and k.is_visible;
    if not found then raise exception 'This used key is no longer available.'; end if;
    new.used_key_remaining_days := v_item.validity_days;
  elsif new.status = 'rejected' and old.status = 'new' then
    update private.used_key_inventory as k
    set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where k.id = old.used_key_id and k.status = 'reserved' and k.reserved_order_id = old.id;
    if not found then raise exception 'The used key reservation could not be released.'; end if;
  elsif new.status = 'completed' and old.status = 'new' then
    update private.used_key_inventory as k
    set status = 'sold', reserved_order_id = null, updated_at = clock_timestamp()
    where k.id = old.used_key_id and k.status = 'reserved' and k.reserved_order_id = old.id;
    if not found then raise exception 'The used key reservation is no longer valid.'; end if;
    new.used_key_expires_on :=
      (timezone('Asia/Kolkata', coalesce(new.completed_at, clock_timestamp())))::date
      + new.used_key_validity_days;
    new.used_key_remaining_days := new.used_key_validity_days;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_used_key_order on public.orders;
create trigger guard_used_key_order
  before insert or update on public.orders
  for each row execute function private.guard_used_key_order();

create or replace function private.release_deleted_used_key_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.used_key_id is not null then
    update private.used_key_inventory as k
    set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where k.id = old.used_key_id and k.status = 'reserved' and k.reserved_order_id = old.id;
  end if;
  return old;
end;
$$;
drop trigger if exists release_deleted_used_key_order on public.orders;
create trigger release_deleted_used_key_order
  after delete on public.orders
  for each row execute function private.release_deleted_used_key_order();

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
  select o.used_key_id into v_used_key_id
  from public.orders as o where o.id = new.order_id;
  if v_used_key_id is null then return new; end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  select coalesce(p.name, k.software_name), dl.download_url,
    extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key)
  into new.software_name, new.download_link, v_license
  from private.used_key_inventory as k
  join public.products as p on p.id = k.product_id
  left join public.product_download_links as dl on dl.product_id = k.product_id
  where k.id = v_used_key_id;
  if v_license is null then raise exception 'The reserved used key could not be loaded.'; end if;
  if new.download_link is null then raise exception 'The Software product Download Link is missing.'; end if;
  new.license_key_encrypted := extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256');
  return new;
end;
$$;
drop trigger if exists lock_used_key_delivery on public.order_delivery;
create trigger lock_used_key_delivery
  before insert or update on public.order_delivery
  for each row execute function private.lock_used_key_delivery();

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
  select o.* into v_order from public.orders as o
  where o.id = p_order_id and o.status in ('new', 'completed', 'rejected')
    and o.utr_number is not null and o.product_type in ('software', 'vps');
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  select coalesce(u.email::text, 'Customer') into v_customer
  from auth.users as u where u.id = v_order.user_id;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = p_order_id;
  select s.encryption_key into v_key
  from private.order_delivery_secrets as s where s.id = true;
  if v_order.used_key_id is not null then
    select k.* into v_used_key from private.used_key_inventory as k where k.id = v_order.used_key_id;
    select dl.download_url into v_download_link
    from public.product_download_links as dl where dl.product_id = v_order.product_id;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'customer', v_customer,
    'product_id', v_order.product_id,
    'product_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_order.product_name)
      else v_order.product_name end,
    'product_type', case when v_order.used_key_id is not null then 'used_key' else coalesce(v_order.product_type, '') end,
    'used_key_id', v_order.used_key_id, 'used_key_expires_on', v_order.used_key_expires_on,
    'used_key_remaining_days', v_order.used_key_remaining_days,
    'amount', v_order.amount, 'utr_number', v_order.utr_number,
    'payment_submitted_at', v_order.payment_submitted_at, 'created_at', v_order.created_at,
    'completed_at', v_order.completed_at, 'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_used_key.software_name)
      else coalesce(v_delivery.software_name, '') end,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null then coalesce(v_download_link, '')
      else coalesce(v_delivery.download_link, '') end,
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
  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  return query
    select o.id, o.product_id,
      case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end,
      case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end,
      o.price, o.status, o.created_at,
      case when o.status in ('delivered', 'completed') then o.delivery_text end,
      case when o.status in ('delivered', 'completed') and o.used_key_id is not null then dl.download_url
        when o.status in ('delivered', 'completed') then coalesce(d.download_link, o.delivery_link) end,
      case when o.status in ('delivered', 'completed') and o.used_key_id is not null
        then 'Remaining validity: ' || greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)::text
          || ' days · Expires: ' || to_char(o.used_key_expires_on, 'YYYY-MM-DD')
        when o.status in ('delivered', 'completed') then o.delivery_note end,
      o.delivered_at, o.payment_method, o.payment_status, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at, o.late_payment,
      o.amount, o.utr_number, o.payment_submitted_at, o.completed_at,
      case when o.status = 'completed' and o.used_key_id is not null then p.name
        when o.status = 'completed' then d.software_name end,
      case when o.status = 'completed' and d.license_key_encrypted is not null
        then extensions.pgp_sym_decrypt(d.license_key_encrypted, v_key) end,
      case when o.status = 'completed' and o.used_key_id is not null then dl.download_url
        when o.status = 'completed' then d.download_link end,
      case when o.status = 'completed' then d.vps_ip end,
      case when o.status = 'completed' then d.vps_port end,
      case when o.status = 'completed' then d.vps_username end,
      case when o.status = 'completed' and d.vps_password_encrypted is not null
        then extensions.pgp_sym_decrypt(d.vps_password_encrypted, v_key) end,
      case when o.status = 'completed' then d.vps_storage_gb end,
      o.used_key_id
    from public.orders as o
    left join public.products as p on p.id = o.product_id
    left join public.order_delivery as d on d.order_id = o.id
    left join public.product_download_links as dl on dl.product_id = o.product_id
    where o.user_id = v_user_id
    order by o.created_at desc limit 50;
end;
$$;

drop function if exists public.admin_list_order_requests(text, text, integer, integer);
create function public.admin_list_order_requests(
  p_status text default 'all', p_search text default '', p_page integer default 1, p_page_size integer default 20
)
returns table(
  id bigint, user_id uuid, customer text, product_id bigint, product_name text,
  product_type text, used_key_id bigint, used_key_remaining_days integer, amount numeric, utr_number text,
  payment_submitted_at timestamptz, created_at timestamptz, status text, total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_search text := left(btrim(coalesce(p_search, '')), 120);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('all', 'new', 'completed', 'rejected') then raise exception 'Invalid order request status.'; end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then raise exception 'Invalid pagination parameters.'; end if;
  return query
    with filtered as (
      select o.id, o.user_id, coalesce(u.email::text, 'Customer') as customer, o.product_id,
        case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end as product_name,
        case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end as product_type,
        o.used_key_id, o.used_key_remaining_days, o.amount, o.utr_number,
        o.payment_submitted_at, o.created_at, o.status
      from public.orders as o
      join auth.users as u on u.id = o.user_id
      left join public.products as p on p.id = o.product_id
      where o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
        and coalesce(o.product_type, p.category, '') in ('software', 'vps')
        and (p_status = 'all' or o.status = p_status)
        and (v_search = '' or o.id::text ilike '%' || v_search || '%'
          or coalesce(u.email::text, '') ilike '%' || v_search || '%'
          or coalesce(o.utr_number, '') ilike '%' || v_search || '%'
          or coalesce(o.used_key_id::text, '') ilike '%' || v_search || '%')
    )
    select f.*, count(*) over()
    from filtered as f
    order by case f.status when 'new' then 0 when 'completed' then 1 else 2 end,
      f.payment_submitted_at desc nulls last, f.created_at desc
    offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;

revoke all on function public.admin_list_used_keys() from public, anon;
revoke all on function public.admin_save_used_key(bigint, bigint, text, numeric, integer, boolean) from public, anon;
revoke all on function public.admin_set_used_key_visibility(bigint, boolean) from public, anon;
revoke all on function public.admin_delete_used_key(bigint) from public, anon;
revoke all on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) from public, anon;
revoke all on function public.prepare_used_key_payment(bigint, bigint) from public, anon;
revoke all on function public.get_my_pending_used_key_payment(bigint, bigint) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.my_orders() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function private.guard_used_key_order() from public, anon, authenticated;
revoke all on function private.release_deleted_used_key_order() from public, anon, authenticated;
revoke all on function private.lock_used_key_delivery() from public, anon, authenticated;
grant execute on function public.admin_list_used_keys() to authenticated;
grant execute on function public.admin_save_used_key(bigint, bigint, text, numeric, integer, boolean) to authenticated;
grant execute on function public.admin_set_used_key_visibility(bigint, boolean) to authenticated;
grant execute on function public.admin_delete_used_key(bigint) to authenticated;
grant execute on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) to authenticated;
grant execute on function public.list_available_used_keys() to anon, authenticated;
grant execute on function public.prepare_used_key_payment(bigint, bigint) to authenticated;
grant execute on function public.get_my_pending_used_key_payment(bigint, bigint) to authenticated;
grant execute on function public.admin_get_order_request(bigint) to authenticated;
grant execute on function public.my_orders() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;

commit;
