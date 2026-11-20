begin;

alter table private.used_key_inventory
  add column if not exists in_stock boolean not null default true;

alter table private.demo_key_inventory
  add column if not exists in_stock boolean not null default true;

update private.used_key_inventory
  set in_stock = false
  where status = 'sold' and in_stock;

drop function if exists public.admin_list_used_keys();
create function public.admin_list_used_keys()
returns table(
  id bigint, product_id bigint, software_name text, license_key text,
  download_link text, price numeric, regular_price numeric, validity_days integer,
  status text, is_visible boolean, reserved_order_id bigint, remaining_days integer,
  in_stock boolean
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
      case when k.status = 'sold'
        then coalesce(k.sold_validity_days, o.used_key_remaining_days, k.validity_days, 0)
        else private.used_key_remaining_days(k.expiry_at, v_now)
      end,
      k.in_stock
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
revoke all on function public.admin_list_used_keys() from public, anon;
grant execute on function public.admin_list_used_keys() to authenticated;

drop function if exists public.list_available_used_keys();
create function public.list_available_used_keys()
returns table(
  id bigint, software_name text, remaining_days integer, price numeric,
  regular_price numeric, image_url text, in_stock boolean
)
language sql
security definer
set search_path = ''
as $$
  select k.id, coalesce(p.name, k.software_name),
    private.used_key_remaining_days(k.expiry_at, clock_timestamp()),
    k.price, k.regular_price, p.image_url, k.in_stock
  from private.used_key_inventory as k
  join public.products as p on p.id = k.product_id
  where k.status = 'available' and k.is_visible
    and exists (
      select 1 from public.product_download_links as dl
      where dl.product_id = k.product_id
    )
  order by k.created_at desc, k.id desc;
$$;
revoke all on function public.list_available_used_keys() from public;
grant execute on function public.list_available_used_keys() to anon, authenticated;

create or replace function public.admin_set_used_key_stock(p_id bigint, p_in_stock boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_id is null or p_in_stock is null then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid stock status.');
  end if;
  update private.used_key_inventory as k
    set in_stock = p_in_stock, updated_at = clock_timestamp()
    where k.id = p_id and k.status in ('available', 'hidden', 'reserved');
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This Used Key cannot be restocked.');
  end if;
  return jsonb_build_object('ok', true, 'in_stock', p_in_stock);
end;
$$;
revoke all on function public.admin_set_used_key_stock(bigint, boolean) from public, anon;
grant execute on function public.admin_set_used_key_stock(bigint, boolean) to authenticated;

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
    if not found then
      raise exception 'This Used Key is no longer available.';
    end if;
    if v_item.in_stock is not true then
      raise exception 'This Used Key is out of stock. Choose another key.';
    end if;
    if v_item.expiry_at <= v_now
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
      and k.in_stock and k.expiry_at > clock_timestamp();
    if not found then
      raise exception 'This used key is out of stock, unavailable, or has expired.';
    end if;
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
    set status = 'sold', in_stock = false, reserved_order_id = null, updated_at = v_now
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
revoke all on function private.guard_used_key_order() from public, anon, authenticated;

drop function if exists public.admin_list_demo_keys();
create function public.admin_list_demo_keys()
returns table(product_id bigint, software_name text, validity_days integer, claim_count bigint, in_stock boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select i.product_id, p.name, i.validity_days, count(c.id), i.in_stock
    from private.demo_key_inventory as i
    join public.products as p on p.id = i.product_id
    left join private.demo_key_claims as c on c.product_id = i.product_id
    group by i.product_id, p.name, i.validity_days, i.in_stock
    order by p.name;
end;
$$;
revoke all on function public.admin_list_demo_keys() from public, anon;
grant execute on function public.admin_list_demo_keys() to authenticated;

drop function if exists public.list_available_demo_keys();
create function public.list_available_demo_keys()
returns table(
  product_id bigint, software_name text, image_url text, price numeric,
  validity_days integer, in_stock boolean, product_in_stock boolean
)
language sql
security definer
set search_path = ''
as $$
  select p.id, p.name, p.image_url, p.price, i.validity_days,
    i.in_stock and p.in_stock
      and (p.stock_status is null or p.stock_status = 'available'),
    p.in_stock and (p.stock_status is null or p.stock_status = 'available')
  from private.demo_key_inventory as i
  join public.products as p on p.id = i.product_id
  join public.product_download_links as d on d.product_id = p.id and coalesce(btrim(d.download_url), '') <> ''
  where lower(p.category) = 'software'
  order by p.name;
$$;
revoke all on function public.list_available_demo_keys() from public;
grant execute on function public.list_available_demo_keys() to anon, authenticated;

create or replace function public.admin_set_demo_key_stock(p_product_id bigint, p_in_stock boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_product_id is null or p_in_stock is null then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid stock status.');
  end if;
  update private.demo_key_inventory as i
    set in_stock = p_in_stock
    where i.product_id = p_product_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This demo key could not be found.');
  end if;
  return jsonb_build_object('ok', true, 'in_stock', p_in_stock);
end;
$$;
revoke all on function public.admin_set_demo_key_stock(bigint, boolean) from public, anon;
grant execute on function public.admin_set_demo_key_stock(bigint, boolean) to authenticated;

create or replace function public.claim_demo_key(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email_normalized text;
  v_license_key text;
  v_software_name text;
  v_image_url text;
  v_download_url text;
  v_validity_days integer;
  v_claim_id bigint;
begin
  if v_user_id is null then raise exception 'Sign in with Google using a Gmail account to claim a demo key'; end if;
  if coalesce(auth.jwt()->'app_metadata'->>'provider', '') <> 'google' then
    raise exception 'Sign in with Google to claim a demo key';
  end if;
  select lower(btrim(u.email)) into v_email_normalized
  from auth.users as u where u.id = v_user_id;
  if v_email_normalized is null or v_email_normalized !~ '^[^@]+@gmail[.]com$' then
    raise exception 'A Gmail account is required to claim a demo key';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_email_normalized || ':' || p_product_id::text, 0));
  if exists(
    select 1 from private.demo_key_claims as c
    where c.email_normalized = v_email_normalized and c.product_id = p_product_id
  ) then
    return jsonb_build_object('ok', false, 'message', 'This Gmail account has already claimed this software demo');
  end if;
  select p.name, p.image_url, i.validity_days, d.download_url,
         extensions.pgp_sym_decrypt(i.license_key_encrypted, s.encryption_key)
  into v_software_name, v_image_url, v_validity_days, v_download_url, v_license_key
  from private.demo_key_inventory as i
  join public.products as p on p.id = i.product_id
  join public.product_download_links as d on d.product_id = p.id
  cross join private.order_delivery_secrets as s
  where i.product_id = p_product_id and s.id = true
    and lower(p.category) = 'software'
    and i.in_stock
    and p.in_stock
    and (p.stock_status is null or p.stock_status = 'available')
  for share of i, p;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This demo key is out of stock or unavailable.');
  end if;

  insert into private.demo_key_claims (user_id, email_normalized, product_id)
  values (v_user_id, v_email_normalized, p_product_id)
  returning id into v_claim_id;
  return jsonb_build_object(
    'ok', true, 'claim_id', v_claim_id, 'software_name', v_software_name,
    'image_url', v_image_url, 'license_key', v_license_key,
    'download_link', v_download_url, 'validity_days', v_validity_days
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'message', 'This Gmail account has already claimed this software demo');
end;
$$;
revoke all on function public.claim_demo_key(bigint) from public, anon;
grant execute on function public.claim_demo_key(bigint) to authenticated;

drop function if exists public.admin_list_rental_products();
create function public.admin_list_rental_products()
returns table(
  product_id bigint, software_name text, daily_rate numeric,
  available_count bigint, active_count bigint, in_stock boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select r.product_id, p.name, r.daily_rate,
      count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp())),
      count(a.id) filter(where a.is_enabled and a.lease_until > clock_timestamp()),
      p.in_stock and (p.stock_status is null or p.stock_status = 'available')
    from public.rental_products as r
    join public.products as p on p.id = r.product_id
    left join private.rental_accounts as a on a.rental_product_id = r.product_id
    group by r.product_id, p.name, r.daily_rate, p.in_stock, p.stock_status
    order by p.name;
end;
$$;
revoke all on function public.admin_list_rental_products() from public, anon;
grant execute on function public.admin_list_rental_products() to authenticated;

drop function if exists public.list_available_rental_products();
create function public.list_available_rental_products()
returns table(
  product_id bigint, software_name text, image_url text,
  daily_rate numeric, available_count bigint, in_stock boolean
)
language sql
security definer
set search_path = ''
as $$
  select r.product_id, p.name, p.image_url, r.daily_rate,
    count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp())),
    p.in_stock and (p.stock_status is null or p.stock_status = 'available')
  from public.rental_products as r
  join public.products as p on p.id = r.product_id and lower(p.category) = 'software'
  left join private.rental_accounts as a on a.rental_product_id = r.product_id
  where r.is_enabled
  group by r.product_id, p.name, p.image_url, r.daily_rate, p.in_stock, p.stock_status
  having count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp())) > 0
      or not (p.in_stock and (p.stock_status is null or p.stock_status = 'available'))
  order by p.name;
$$;
revoke all on function public.list_available_rental_products() from public;
grant execute on function public.list_available_rental_products() to anon, authenticated;

create or replace function private.guard_order_stock_on_utr()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_in_stock boolean;
  v_product_id bigint;
begin
  if new.utr is not distinct from old.utr
     and new.utr_number is not distinct from old.utr_number then
    return new;
  end if;
  if nullif(btrim(coalesce(new.utr, new.utr_number, '')), '') is null then
    return new;
  end if;
  if new.used_key_id is not null then
    select k.in_stock into v_in_stock
    from private.used_key_inventory as k
    where k.id = new.used_key_id
    for share;
    if not found or v_in_stock is not true then
      raise exception 'This Used Key is out of stock. Choose another key.';
    end if;
    return new;
  end if;
  v_product_id := coalesce(new.rental_product_id, new.product_id);
  if v_product_id is null then return new; end if;
  select p.in_stock and (p.stock_status is null or p.stock_status = 'available')
    into v_in_stock
  from public.products as p
  where p.id = v_product_id
  for share;
  if not found or v_in_stock is not true then
    if new.rental_product_id is not null or new.product_type = 'rental' then
      raise exception 'This rental is out of stock. Please choose another option.';
    end if;
    raise exception 'This product is out of stock. Please choose another product.';
  end if;
  return new;
end;
$$;
revoke all on function private.guard_order_stock_on_utr() from public, anon, authenticated;
drop trigger if exists orders_guard_stock_on_utr on public.orders;
create trigger orders_guard_stock_on_utr
  before update of utr, utr_number on public.orders
  for each row execute function private.guard_order_stock_on_utr();

commit;
