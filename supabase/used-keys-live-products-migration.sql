begin;

drop function if exists public.list_available_used_keys();
create function public.list_available_used_keys()
returns table(
  id bigint, software_name text, remaining_days integer, price numeric,
  regular_price numeric, image_url text
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
        o.product_id,
        case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end product_name,
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
    'product_id', v_order.product_id,
    'product_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products p where p.id = v_order.product_id), v_order.product_name)
      else v_order.product_name end,
    'product_type', case when v_order.used_key_id is not null then 'used_key' else coalesce(v_order.product_type, '') end,
    'used_key_id', v_order.used_key_id, 'used_key_expires_on', v_order.used_key_expires_on,
    'amount', v_order.amount, 'utr_number', v_order.utr_number,
    'payment_submitted_at', v_order.payment_submitted_at, 'created_at', v_order.created_at,
    'completed_at', v_order.completed_at, 'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products p where p.id = v_order.product_id), v_used_key.software_name)
      else coalesce(v_delivery.software_name, '') end,
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
    select o.id, o.product_id,
      case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end,
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
      case when o.status = 'completed' and o.used_key_id is not null then p.name
        when o.status = 'completed' then d.software_name end,
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
grant execute on function public.list_available_used_keys() to anon, authenticated;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.my_orders() to authenticated;

commit;
