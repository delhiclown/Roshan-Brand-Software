begin;

alter table private.used_key_inventory
  add column if not exists expiry_at timestamptz;

with local_clock as (
  select timezone('Asia/Kolkata', clock_timestamp()) as now_ist
)
update private.used_key_inventory as k
set expiry_at =
  ((local_clock.now_ist::date + greatest(coalesce(k.validity_days, 1), 1)
      - case when local_clock.now_ist::time < time '11:00' then 1 else 0 end)
      + time '11:00') at time zone 'Asia/Kolkata'
from local_clock
where k.expiry_at is null;

alter table private.used_key_inventory
  alter column expiry_at set not null;

create index if not exists used_key_inventory_expiry_at_idx
  on private.used_key_inventory (expiry_at, created_at desc)
  where status = 'available' and is_visible;

create or replace function private.used_key_remaining_days(
  p_expiry_at timestamptz, p_now timestamptz
)
returns integer
language sql
stable
set search_path = ''
as $$
  select greatest(
    ceil(extract(epoch from (p_expiry_at - p_now)) / 86400)::integer,
    0
  );
$$;
revoke all on function private.used_key_remaining_days(timestamptz, timestamptz)
  from public, anon, authenticated;

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
  v_now timestamptz := clock_timestamp();
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  return query
    select k.id, k.product_id, coalesce(p.name, k.software_name),
      extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key),
      coalesce(dl.download_url, ''), k.price, k.regular_price, k.validity_days,
      k.status, k.is_visible, k.reserved_order_id,
      case when k.status = 'sold' then coalesce(o.used_key_remaining_days, k.validity_days)
        else private.used_key_remaining_days(k.expiry_at, v_now)
      end
    from private.used_key_inventory as k
    left join public.products as p on p.id = k.product_id
    left join public.product_download_links as dl on dl.product_id = k.product_id
    left join lateral (
      select ord.used_key_remaining_days
      from public.orders as ord
      where ord.used_key_id = k.id
      order by case when ord.status = 'completed' then 0 else 1 end, ord.created_at desc
      limit 1
    ) as o on true
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
  v_now timestamptz := clock_timestamp();
  v_today date := (timezone('Asia/Kolkata', v_now))::date;
  v_expiry_at timestamptz;
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
  v_expiry_at :=
    ((v_today + p_validity_days
      - case when timezone('Asia/Kolkata', v_now)::time < time '11:00' then 1 else 0 end)
      + time '11:00') at time zone 'Asia/Kolkata';
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  if p_id is null then
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on, validity_days, expiry_at,
      is_visible, status
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_download_link, p_price,
      v_regular_price, v_today + p_validity_days, p_validity_days, v_expiry_at,
      v_visible, case when v_visible then 'available' else 'hidden' end
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
      expiry_at = v_expiry_at, is_visible = v_visible,
      status = case when v_visible then 'available' else 'hidden' end,
      updated_at = clock_timestamp()
    where k.id = p_id
    returning k.id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'This license key is already in inventory.');
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
  v_now timestamptz := clock_timestamp();
  v_today date := (timezone('Asia/Kolkata', v_now))::date;
  v_expiry_at timestamptz;
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
    v_expiry_at :=
      ((v_today + v_validity_days
        - case when timezone('Asia/Kolkata', v_now)::time < time '11:00' then 1 else 0 end)
        + time '11:00') at time zone 'Asia/Kolkata';
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on, validity_days, expiry_at
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_download_link,
      v_price, v_regular_price, v_today + v_validity_days, v_validity_days, v_expiry_at
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
  select k.id, coalesce(p.name, k.software_name),
    private.used_key_remaining_days(k.expiry_at, clock_timestamp()),
    k.price, k.regular_price, p.image_url
  from private.used_key_inventory as k
  join public.products as p on p.id = k.product_id
  where k.status = 'available' and k.is_visible
    and exists (
      select 1 from public.product_download_links as dl
      where dl.product_id = k.product_id
    )
  order by k.created_at desc, k.id desc;
$$;

create or replace function public.prepare_used_key_payment(
  p_used_key_id bigint, p_order_id bigint default null
)
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
    and k.expiry_at > v_now
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

create or replace function private.guard_used_key_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item private.used_key_inventory%rowtype;
  v_now timestamptz := clock_timestamp();
  v_remaining_days integer;
begin
  if tg_op = 'INSERT' then
    if new.used_key_id is null then return new; end if;
    select k.* into v_item
    from private.used_key_inventory as k where k.id = new.used_key_id for share;
    if not found or v_item.expiry_at <= v_now
       or new.product_id <> v_item.product_id or new.price <> v_item.price
       or new.product_type <> 'software' or new.payment_method <> 'upi_qr'
       or new.status <> 'pending_payment' or new.payment_status <> 'pending'
       or new.quantity <> 1 or new.coupon_code is not null or new.discount_percent <> 0
       or new.offer_id is not null or new.offer_claim_id is not null or new.is_offer_free
       or new.used_key_validity_days is distinct from v_item.validity_days
       or new.used_key_expires_on is not null
       or new.used_key_fingerprint is distinct from v_item.license_key_fingerprint then
      raise exception 'Used Keys checkout details are invalid or expired.';
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
    where k.id = new.used_key_id and k.status = 'available' and k.is_visible
      and k.expiry_at > clock_timestamp();
    if not found then raise exception 'This used key is no longer available or has expired.'; end if;
    new.used_key_remaining_days :=
      private.used_key_remaining_days(v_item.expiry_at, clock_timestamp());
  elsif new.status = 'rejected' and old.status = 'new' then
    update private.used_key_inventory as k
    set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
    where k.id = old.used_key_id and k.status = 'reserved' and k.reserved_order_id = old.id;
    if not found then raise exception 'The used key reservation could not be released.'; end if;
  elsif new.status = 'completed' and old.status = 'new' then
    v_now := clock_timestamp();
    v_remaining_days := private.used_key_remaining_days(v_item.expiry_at, v_now);
    if v_remaining_days <= 0 then
      raise exception 'This used key expired before the order was completed.';
    end if;
    update private.used_key_inventory as k
    set status = 'sold', reserved_order_id = null, updated_at = v_now
    where k.id = old.used_key_id and k.status = 'reserved' and k.reserved_order_id = old.id
      and k.expiry_at > v_now;
    if not found then raise exception 'The used key reservation is no longer valid or has expired.'; end if;
    new.used_key_expires_on :=
      (timezone('Asia/Kolkata', v_now))::date + v_remaining_days;
    new.used_key_remaining_days := v_remaining_days;
  end if;
  return new;
end;
$$;

revoke all on function public.admin_list_used_keys() from public, anon;
revoke all on function public.admin_save_used_key(bigint, bigint, text, numeric, integer, boolean) from public, anon;
revoke all on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) from public, anon;
revoke all on function public.list_available_used_keys() from public;
revoke all on function public.prepare_used_key_payment(bigint, bigint) from public, anon;
revoke all on function private.guard_used_key_order() from public, anon, authenticated;
grant execute on function public.admin_list_used_keys() to authenticated;
grant execute on function public.admin_save_used_key(bigint, bigint, text, numeric, integer, boolean) to authenticated;
grant execute on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) to authenticated;
grant execute on function public.list_available_used_keys() to anon, authenticated;
grant execute on function public.prepare_used_key_payment(bigint, bigint) to authenticated;

commit;
