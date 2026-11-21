begin;

create or replace function public.admin_list_used_keys_with_plan()
returns table(
  id bigint, product_id bigint, software_name text, license_key text,
  download_link text, price numeric, regular_price numeric, validity_days integer,
  status text, is_visible boolean, reserved_order_id bigint, remaining_days integer,
  in_stock boolean, software_plan_code text
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
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
        then coalesce(o.used_key_remaining_days, k.validity_days, 0)
        else greatest(k.expires_on - (timezone('Asia/Kolkata', v_now))::date, 0)
      end,
      coalesce(p.in_stock, false), k.software_plan_code
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

create or replace function public.admin_get_request(p_type text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_topup public.topup_requests%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_encryption_key text;
  v_product_name text;
  v_product_type text;
  v_catalog_download_link text;
  v_auto_license_key text;
  v_auto_license_key_id bigint;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_type = 'topup' then
    select t.* into v_topup from public.topup_requests as t where t.id = p_id;
    if not found then return jsonb_build_object('ok', false, 'message', 'Top-up request not found.'); end if;
    return jsonb_build_object(
      'ok', true, 'id', v_topup.id, 'type', 'topup',
      'customer', coalesce((select u.email::text from auth.users as u where u.id = v_topup.user_id), 'Customer'),
      'product_name', 'Wallet Top-up', 'product_type', 'topup',
      'amount', round(v_topup.amount, 2), 'utr_number', v_topup.utr,
      'payment_time', v_topup.created_at,
      'status', case when v_topup.status = 'pending' then 'utr_submitted'
                     when v_topup.status = 'approved' then 'completed' else 'rejected' end
    );
  end if;
  select o.* into v_order from public.orders as o
  where o.id = p_id and coalesce(o.utr_number, o.utr) is not null;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = p_id;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  select coalesce(p.name, v_order.product_name), coalesce(v_order.product_type, p.category)
  into v_product_name, v_product_type
  from public.products as p where p.id = v_order.product_id;
  if not found then
    v_product_name := v_order.product_name;
    v_product_type := v_order.product_type;
  end if;
  select coalesce(plan_link.download_url, product_link.download_url, '')
  into v_catalog_download_link
  from (select 1) as one_row
  left join public.product_download_links as product_link
    on product_link.product_id = v_order.product_id
  left join public.product_plan_download_links as plan_link
    on plan_link.product_id = v_order.product_id
   and plan_link.software_plan_code = v_order.software_plan_code;
  if v_order.used_key_id is null and v_product_type = 'software'
     and v_order.software_plan_code is not null then
    select k.id, extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key)
    into v_auto_license_key_id, v_auto_license_key
    from private.used_key_inventory as k
    join public.products as p
      on p.id = k.product_id and p.in_stock
    where k.product_id = v_order.product_id
      and k.software_plan_code = v_order.software_plan_code
      and k.status = 'available' and k.is_visible
      and k.expires_on >= (timezone('Asia/Kolkata', clock_timestamp()))::date
    order by k.created_at, k.id
    limit 1;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'type', 'software',
    'customer', coalesce((select u.email::text from auth.users as u where u.id = v_order.user_id), v_order.guest_email, 'Customer'),
    'guest_email', v_order.guest_email, 'guest_whatsapp', v_order.guest_whatsapp,
    'guest_email_sent_at', v_order.guest_email_sent_at,
    'product_id', v_order.product_id, 'product_name', coalesce(v_product_name, v_order.product_name),
    'product_type', v_product_type, 'used_key_id', v_order.used_key_id,
    'amount', round(coalesce(v_order.amount, v_order.price), 2),
    'utr_number', coalesce(v_order.utr_number, v_order.utr),
    'payment_time', coalesce(v_order.payment_submitted_at, v_order.utr_submitted_at, v_order.created_at),
    'status', case
      when v_order.status in ('completed', 'delivered') or v_order.delivered_at is not null
        or nullif(btrim(coalesce(v_order.delivery_text, '')), '') is not null
        or nullif(btrim(coalesce(v_order.delivery_link, '')), '') is not null
        or nullif(btrim(coalesce(v_order.delivery_note, '')), '') is not null
        or exists (select 1 from public.order_delivery as d where d.order_id = v_order.id
          and (nullif(btrim(coalesce(d.software_name, '')), '') is not null
            or d.license_key_encrypted is not null
            or nullif(btrim(coalesce(d.download_link, '')), '') is not null
            or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
            or d.vps_port is not null
            or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
            or d.vps_password_encrypted is not null or d.vps_storage_gb is not null))
        then 'completed'
      when v_order.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
      else v_order.status
    end,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'reject_reason', v_order.reject_reason,
    'software_name', coalesce(v_delivery.software_name, ''),
    'license_key', case when v_delivery.license_key_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_encryption_key) end,
    'download_link', coalesce(v_delivery.download_link, ''),
    'catalog_download_link', coalesce(v_catalog_download_link, ''),
    'auto_license_key', coalesce(v_auto_license_key, ''),
    'auto_license_key_id', v_auto_license_key_id,
    'vps_ip', coalesce(v_delivery.vps_ip, ''), 'vps_port', v_delivery.vps_port,
    'vps_username', coalesce(v_delivery.vps_username, ''),
    'vps_password', case when v_delivery.vps_password_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_encryption_key) end,
    'vps_storage_gb', v_delivery.vps_storage_gb
  );
end;
$$;

create or replace function public.admin_complete_order(p_order_id bigint, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_auto_key private.used_key_inventory%rowtype;
  v_encryption_key text;
  v_license text := btrim(coalesce(p_details ->> 'license_key', ''));
  v_auto_key_id bigint;
  v_claimed_key text;
  v_link text := btrim(coalesce(p_details ->> 'download_link', ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order
  from public.orders as o
  where o.id = p_order_id
    and coalesce(o.utr_number, o.utr) is not null
    and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending')
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Only submitted order requests can be completed.');
  end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  if v_order.product_type = 'software' then
    if btrim(coalesce(p_details ->> 'software_name', '')) = '' or v_license = '' then
      return jsonb_build_object('ok', false, 'message', 'Software Name and License Key are required.');
    end if;
    if length(v_link) > 2048 or (v_link <> '' and v_link !~* '^https?://[^[:space:]]+$') then
      return jsonb_build_object('ok', false, 'message', 'Download links must start with http:// or https://.');
    end if;
    if nullif(p_details ->> 'auto_key_id', '') is not null then
      if (p_details ->> 'auto_key_id') !~ '^[0-9]+$' then
        return jsonb_build_object('ok', false, 'message', 'The selected key is invalid. Reload this order before approving.');
      end if;
      v_auto_key_id := (p_details ->> 'auto_key_id')::bigint;
      select k.* into v_auto_key
      from private.used_key_inventory as k
      join public.products as p
        on p.id = k.product_id and p.in_stock
      where k.id = v_auto_key_id
        and k.product_id = v_order.product_id
        and k.software_plan_code = v_order.software_plan_code
        and k.status = 'available' and k.is_visible
        and k.expires_on >= (timezone('Asia/Kolkata', clock_timestamp()))::date
      for update of k skip locked;
      if not found then
        return jsonb_build_object('ok', false, 'message', 'This key was claimed by another order. Reload this order to select another key.');
      end if;
      v_claimed_key := extensions.pgp_sym_decrypt(v_auto_key.license_key_encrypted, v_encryption_key);
      if v_claimed_key is distinct from p_details ->> 'license_key' then
        return jsonb_build_object('ok', false, 'message', 'The selected key changed. Reload this order before approving.');
      end if;
      update private.used_key_inventory as k
      set status = 'sold', delivered_order_id = p_order_id,
          updated_at = clock_timestamp()
      where k.id = v_auto_key.id;
    elsif exists (
      select 1 from private.used_key_inventory as k
      where k.license_key_fingerprint = extensions.hmac(v_license, v_encryption_key, 'sha256')
    ) then
      return jsonb_build_object('ok', false, 'message', 'This key belongs to the inventory pool. Reset to the suggested key or enter a different custom key.');
    end if;
    insert into public.order_delivery (
      order_id, software_name, license_key_encrypted, download_link
    ) values (
      p_order_id,
      nullif(btrim(p_details ->> 'software_name'), ''),
      extensions.pgp_sym_encrypt(v_license, v_encryption_key),
      nullif(v_link, '')
    )
    on conflict (order_id) do update set
      software_name = excluded.software_name,
      license_key_encrypted = excluded.license_key_encrypted,
      download_link = excluded.download_link;
  end if;
  update public.orders as o
  set status = 'completed',
      payment_status = 'paid',
      completed_at = clock_timestamp(),
      delivered_at = clock_timestamp()
  where o.id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'completed');
end;
$$;

commit;
