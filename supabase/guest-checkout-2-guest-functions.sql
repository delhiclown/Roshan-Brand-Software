-- Apply order: run software-pnr-plans-migration.sql first, then these files in order.
-- 2/4 - guest_* functions. Run this file once, after backup and explicit approval.

begin;

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

-- Keep guest RPCs inaccessible until file 4 grants them to service_role.
revoke all on function public.guest_create_order(text, bigint, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_submit_order_utr(bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_get_order(bigint, text) from public, anon, authenticated;
revoke all on function public.guest_claim_demo_key(bigint, text, text, text, text) from public, anon, authenticated;

commit;
