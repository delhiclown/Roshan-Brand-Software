-- Apply order: run software-pnr-plans-migration.sql first, then these files in order.
-- 3/4 - admin list/get/save/complete/rental/guest-delivery functions. Run this file once, after backup and explicit approval.

begin;

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
  v_catalog_download_link text;
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
  elsif v_order.product_type = 'software' then
    select d.download_url into v_catalog_download_link
      from public.product_download_links as d
      join public.products as p on p.id = d.product_id
      where d.product_id = v_order.product_id and p.category = 'software'
        and nullif(btrim(d.download_url), '') is not null;
    if nullif(btrim(v_catalog_download_link), '') is null then
      select d.download_url into v_catalog_download_link
        from public.product_download_links as d
        join public.products as p on p.id = d.product_id
        where p.category = 'software'
          and lower(btrim(p.name)) = lower(btrim(v_order.product_name))
          and nullif(btrim(d.download_url), '') is not null
        order by p.id
        limit 1;
    end if;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'user_id', v_order.user_id, 'customer', v_customer,
    'guest_order', v_order.guest_email is not null, 'guest_email_sent_at', v_order.guest_email_sent_at,
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
      else coalesce(v_delivery.software_name, '') end,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null
      then coalesce(v_download_link, '') else coalesce(v_delivery.download_link, '') end,
    'catalog_download_link', coalesce(v_catalog_download_link, ''),
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
  update public.orders set status = 'completed', payment_status = 'paid', completed_at = clock_timestamp(), delivered_at = clock_timestamp() where id = p_order_id;
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
      o.amount, o.utr_number, o.payment_submitted_at, o.guest_email is not null,
      o.status, o.guest_email_sent_at is not null
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    where o.product_type = 'rental'
      and ((o.status = 'new' and o.utr_number is not null)
        or (o.guest_email is not null and o.status = 'completed' and o.payment_status = 'paid'
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
    where o.id = p_order_id and o.guest_email is not null;
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
    'software_name', coalesce(nullif(btrim(v_delivery.software_name), ''), v_order.product_name),
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
    where o.id = p_order_id and o.guest_email is not null
      and o.status = 'completed' and o.payment_status = 'paid';
  if not found then return jsonb_build_object('ok', false, 'message', 'Completed guest order was not found.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Keep recreated admin functions non-public until file 4 assigns authenticated access.
revoke all on function public.admin_list_orders() from public, anon;
revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.admin_save_order_delivery(bigint, jsonb) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_list_rental_requests() from public, anon;
revoke all on function public.admin_guest_order_delivery(bigint) from public, anon;
revoke all on function public.admin_mark_guest_order_email_sent(bigint) from public, anon;

commit;
