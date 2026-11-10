begin;

alter table private.used_key_inventory
  drop constraint if exists used_key_inventory_status_check;
alter table private.used_key_inventory
  add constraint used_key_inventory_status_check
  check (status in ('available', 'reserved', 'sold', 'hidden'));
update private.used_key_inventory
set status = 'hidden', is_visible = false
where status = 'available' and not is_visible;

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
    select k.id, k.product_id, coalesce(p.name, k.software_name),
      extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key),
      k.download_link, k.price, k.regular_price, k.expires_on, k.status, k.is_visible,
      k.reserved_order_id,
      greatest(k.expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)
    from private.used_key_inventory k
    left join public.products p on p.id = k.product_id
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
  v_visible boolean := coalesce(p_is_visible, true);
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
      download_link, price, regular_price, expires_on, is_visible, status
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'), v_link, p_price,
      v_regular_price, p_expires_on, v_visible, case when v_visible then 'available' else 'hidden' end
    ) returning id into v_id;
  else
    select * into v_current from private.used_key_inventory where id = p_id for update;
    if not found or v_current.status not in ('available', 'hidden') then
      return jsonb_build_object('ok', false, 'message', 'Only available or hidden keys can be edited.');
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
      download_link = v_link, price = p_price, regular_price = v_regular_price,
      expires_on = p_expires_on, is_visible = v_visible,
      status = case when v_visible then 'available' else 'hidden' end,
      updated_at = clock_timestamp()
    where id = p_id returning id into v_id;
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
  update private.used_key_inventory
  set is_visible = p_is_visible,
      status = case when p_is_visible then 'available' else 'hidden' end,
      updated_at = clock_timestamp()
  where id = p_id and status in ('available', 'hidden');
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
declare v_item private.used_key_inventory%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select * into v_item from private.used_key_inventory where id = p_id for update;
  if not found or v_item.status not in ('available', 'hidden') then
    return jsonb_build_object('ok', false, 'message', 'Only available or hidden keys can be deleted.');
  end if;
  if exists (select 1 from public.orders where used_key_id = p_id) then
    return jsonb_build_object('ok', false, 'message', 'This key is linked to an order; hide it instead.');
  end if;
  delete from private.used_key_inventory where id = p_id;
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
  v_row jsonb;
  v_license text;
  v_link text;
  v_price numeric(12, 2);
  v_expiry date;
  v_regular_price numeric(12, 2);
  v_count integer := 0;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_keys) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 key records.');
  end if;
  if jsonb_array_length(p_keys) not between 1 and 100 then
    return jsonb_build_object('ok', false, 'message', 'Bulk add accepts 1–100 key records.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and category = 'software';
  if not found then return jsonb_build_object('ok', false, 'message', 'Choose an existing Software product.'); end if;
  v_regular_price := coalesce(v_product.original_price, v_product.selling_price, v_product.price);
  for v_row in select value from jsonb_array_elements(p_keys) as item(value) loop
    if jsonb_typeof(v_row) <> 'object'
       or jsonb_typeof(v_row -> 'license_key') <> 'string'
       or jsonb_typeof(v_row -> 'download_link') <> 'string'
       or jsonb_typeof(v_row -> 'expires_on') <> 'string'
       or coalesce(v_row ->> 'price', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
       or (v_row ->> 'expires_on') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'Every bulk row needs a text key, download link, price, and YYYY-MM-DD expiry.';
    end if;
    v_license := btrim(v_row ->> 'license_key');
    v_link := btrim(v_row ->> 'download_link');
    v_price := (v_row ->> 'price')::numeric;
    v_expiry := (v_row ->> 'expires_on')::date;
    if v_license = '' or length(v_license) > 4000 or v_license ~ '[[:cntrl:]]' then
      raise exception 'Each license key must be 1–4000 printable characters.';
    end if;
    if length(v_link) > 2048 or v_link !~* '^https?://[^[:space:]]+$' then
      raise exception 'Each download link must use HTTP or HTTPS and be at most 2048 characters.';
    end if;
    if v_price <= 0 or v_price > 100000 or v_price >= v_regular_price then
      raise exception 'Each Used Key price must be positive, no more than ₹100,000, and lower than the regular price.';
    end if;
    if v_expiry < (timezone('Asia/Kolkata', clock_timestamp()))::date then
      raise exception 'Each expiry date must be today or later.';
    end if;
  end loop;

  select encryption_key into v_encryption_key from private.order_delivery_secrets where id = true;
  for v_row in select value from jsonb_array_elements(p_keys) as item(value) loop
    v_license := btrim(v_row ->> 'license_key');
    v_link := btrim(v_row ->> 'download_link');
    v_price := (v_row ->> 'price')::numeric;
    v_expiry := (v_row ->> 'expires_on')::date;
    insert into private.used_key_inventory (
      product_id, software_name, license_key_encrypted, license_key_fingerprint,
      download_link, price, regular_price, expires_on
    ) values (
      v_product.id, v_product.name,
      extensions.pgp_sym_encrypt(v_license, v_encryption_key, 'cipher-algo=aes256'),
      extensions.hmac(v_license, v_encryption_key, 'sha256'),
      v_link, v_price, v_regular_price, v_expiry
    );
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_count);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'A license key in this batch already exists in inventory.');
when invalid_datetime_format then
  return jsonb_build_object('ok', false, 'message', 'Enter each expiry date as a valid YYYY-MM-DD date.');
when numeric_value_out_of_range then
  return jsonb_build_object('ok', false, 'message', 'Each price must be no more than ₹100,000.');
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
declare v_search text := left(btrim(coalesce(p_search, '')), 120);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('all', 'new', 'completed', 'rejected') then raise exception 'Invalid order request status.'; end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then raise exception 'Invalid pagination parameters.'; end if;
  return query
    with filtered as (
      select o.id, o.user_id, coalesce(u.email::text, 'Customer') customer,
        o.product_id,
        case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end product_name,
        case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end product_type,
        o.used_key_id,
        case when o.used_key_id is not null
          then greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0) end,
        o.amount, o.utr_number, o.payment_submitted_at, o.created_at, o.status
      from public.orders o
      join auth.users u on u.id = o.user_id
      left join public.products p on p.id = o.product_id
      where o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
        and coalesce(o.product_type, p.category, '') in ('software', 'vps')
        and (p_status = 'all' or o.status = p_status)
        and (v_search = '' or o.id::text ilike '%' || v_search || '%'
          or coalesce(u.email::text, '') ilike '%' || v_search || '%'
          or coalesce(o.utr_number, '') ilike '%' || v_search || '%'
          or coalesce(o.used_key_id::text, '') ilike '%' || v_search || '%')
    )
    select f.*, count(*) over()
    from filtered f
    order by case f.status when 'new' then 0 when 'completed' then 1 else 2 end,
      f.payment_submitted_at desc nulls last, f.created_at desc
    offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;

revoke all on function public.admin_list_used_keys() from public, anon;
revoke all on function public.admin_save_used_key(bigint, bigint, text, text, numeric, date, boolean) from public, anon;
revoke all on function public.admin_set_used_key_visibility(bigint, boolean) from public, anon;
revoke all on function public.admin_delete_used_key(bigint) from public, anon;
revoke all on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
grant execute on function public.admin_list_used_keys() to authenticated;
grant execute on function public.admin_save_used_key(bigint, bigint, text, text, numeric, date, boolean) to authenticated;
grant execute on function public.admin_set_used_key_visibility(bigint, boolean) to authenticated;
grant execute on function public.admin_delete_used_key(bigint) to authenticated;
grant execute on function public.admin_bulk_add_used_keys_with_details(bigint, jsonb) to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;

commit;
