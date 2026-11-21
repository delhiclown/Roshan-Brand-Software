begin;

alter table public.orders drop constraint if exists orders_guest_identity_check;
alter table public.orders add constraint orders_guest_identity_check check (
  (guest_email is not null
    and guest_access_hash is not null and guest_access_hash ~ '^[0-9a-f]{64}$'
    and ((user_id is null
      and guest_device_hash is not null and guest_device_hash ~ '^[0-9a-f]{64}$'
      and guest_ip_hash is not null and guest_ip_hash ~ '^[0-9a-f]{64}$')
      or (user_id is not null and guest_device_hash is null and guest_ip_hash is null)))
  or (user_id is not null and guest_email is null and guest_access_hash is null
    and guest_device_hash is null and guest_ip_hash is null)
);

create or replace function private.release_guest_used_key_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.used_key_inventory as k
  set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
  where k.id = old.used_key_id and k.status = 'reserved'
    and k.reserved_order_id = old.id;
  return new;
end;
$$;
drop trigger if exists release_guest_used_key_reservation on public.orders;
create trigger release_guest_used_key_reservation
  after update of status on public.orders
  for each row
  when (
    old.used_key_id is not null
    and new.status in ('expired', 'rejected', 'cancelled')
  )
  execute function private.release_guest_used_key_reservation();

create or replace function public.link_guest_orders_to_user()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_linked_count integer := 0;
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'message', 'Sign in to link guest orders.');
  end if;
  select lower(btrim(u.email::text)) into v_email
    from auth.users as u
    where u.id = v_user_id and u.email_confirmed_at is not null;
  if v_email is null then
    return jsonb_build_object('ok', false, 'message', 'Verify your email to link guest orders.');
  end if;
  update public.orders as o
    set user_id = v_user_id, guest_device_hash = null, guest_ip_hash = null
    where o.user_id is null and o.guest_email = v_email
      and o.guest_access_hash is not null;
  get diagnostics v_linked_count = row_count;
  return jsonb_build_object('ok', true, 'linked_count', v_linked_count);
end;
$$;
revoke all on function public.link_guest_orders_to_user() from public, anon;
grant execute on function public.link_guest_orders_to_user() to authenticated;

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
    where o.id = p_order_id and o.guest_email is not null
      and o.guest_access_hash = p_access_hash;
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
revoke all on function public.guest_get_order(bigint, text) from public, anon, authenticated;
grant execute on function public.guest_get_order(bigint, text) to service_role;

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
  v_utr text := regexp_replace(btrim(coalesce(p_utr, '')), '\s+', '', 'g');
  v_latest timestamptz;
  v_attempts integer;
  v_remaining integer;
begin
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.guest_email is not null
      and o.guest_access_hash = p_access_hash
      and o.guest_email_sent_at is null
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'Guest order could not be verified.');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 0));
  select count(*), max(attempted_at) into v_attempts, v_latest
  from private.guest_utr_attempts
  where order_id = p_order_id
    and attempted_at > clock_timestamp() - interval '5 minutes';
  if v_attempts >= 5 and v_latest is not null then
    v_remaining := greatest(0, ceil(extract(epoch from (v_latest + interval '5 minutes' - clock_timestamp())))::integer);
    if v_remaining > 0 then
      return jsonb_build_object('ok', false, 'reason', 'rate_limited',
        'message', 'If you have already paid, do not worry. We will verify your UTR and confirm your order.',
        'order_id', p_order_id, 'retry_after_seconds', v_remaining,
        'wait_message', 'Try again in ' || to_char(make_interval(secs => v_remaining), 'MI:SS'));
    end if;
  end if;

  if v_utr !~ '^[0-9]{12}$' then
    insert into private.guest_utr_attempts (ip_hash, order_id) values (p_ip_hash, p_order_id);
    select count(*), max(attempted_at) into v_attempts, v_latest
    from private.guest_utr_attempts where order_id = p_order_id
      and attempted_at > clock_timestamp() - interval '5 minutes';
    if v_attempts >= 5 then
      v_remaining := greatest(0, ceil(extract(epoch from (v_latest + interval '5 minutes' - clock_timestamp())))::integer);
      return jsonb_build_object('ok', false, 'reason', 'rate_limited',
        'message', 'If you have already paid, do not worry. We will verify your UTR and confirm your order.',
        'order_id', p_order_id, 'retry_after_seconds', v_remaining,
        'wait_message', 'Try again in ' || to_char(make_interval(secs => v_remaining), 'MI:SS'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'invalid_format',
      'message', 'Enter exactly 12 digits for the UTR / transaction ID.',
      'remaining_attempts', greatest(0, 5 - v_attempts));
  end if;

  if exists (select 1 from public.payment_utr_claims where utr_normalized = v_utr)
     or exists (select 1 from public.topup_requests where lower(utr) = lower(v_utr))
     or exists (select 1 from public.orders where coalesce(utr_number, utr) = v_utr) then
    insert into private.guest_utr_attempts (ip_hash, order_id) values (p_ip_hash, p_order_id);
    select count(*), max(attempted_at) into v_attempts, v_latest
    from private.guest_utr_attempts where order_id = p_order_id
      and attempted_at > clock_timestamp() - interval '5 minutes';
    if v_attempts >= 5 then
      v_remaining := greatest(0, ceil(extract(epoch from (v_latest + interval '5 minutes' - clock_timestamp())))::integer);
      return jsonb_build_object('ok', false, 'reason', 'rate_limited',
        'message', 'If you have already paid, do not worry. We will verify your UTR and confirm your order.',
        'order_id', p_order_id, 'retry_after_seconds', v_remaining,
        'wait_message', 'Try again in ' || to_char(make_interval(secs => v_remaining), 'MI:SS'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'duplicate',
      'message', 'This UTR has already been used.');
  end if;

  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then
    insert into private.guest_utr_attempts (ip_hash, order_id) values (p_ip_hash, p_order_id);
    return jsonb_build_object('ok', false, 'reason', 'duplicate',
      'message', 'This UTR has already been used.');
  end if;

  update public.orders set
    utr = v_utr, utr_number = v_utr,
    utr_submitted_at = clock_timestamp(), payment_submitted_at = clock_timestamp(),
    late_payment = (v_order.status = 'expired'
      or (v_order.payment_expires_at is not null and clock_timestamp() > v_order.payment_expires_at)),
    status = 'pending_verification', payment_status = 'pending'
  where id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'status', 'pending_verification',
    'message', 'We received your payment details and will confirm shortly.',
    'customer_email', v_order.guest_email
  );
end;
$$;

create or replace function public.guest_submit_payment_screenshot(
  p_order_id bigint, p_access_hash text, p_screenshot_base64 text, p_screenshot_mime text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bytes bytea;
begin
  if p_screenshot_mime not in ('image/png','image/jpeg','image/webp') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_format',
      'message', 'Upload a PNG, JPG, or WebP screenshot.');
  end if;
  begin
    v_bytes := decode(replace(p_screenshot_base64, E'\n', ''), 'base64');
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'invalid_format',
      'message', 'The screenshot could not be read.');
  end;
  if octet_length(v_bytes) > 2 * 1024 * 1024 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_format',
      'message', 'The screenshot must be 2 MB or smaller.');
  end if;
  update public.orders
  set payment_screenshot_bytes = v_bytes,
      payment_screenshot_mime = p_screenshot_mime,
      payment_screenshot_submitted_at = clock_timestamp()
  where id = p_order_id and guest_email is not null
    and guest_access_hash = p_access_hash;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'Order could not be verified.');
  end if;
  return jsonb_build_object('ok', true, 'message', 'Payment screenshot submitted for manual verification.');
end;
$$;

create or replace function public.admin_list_rental_requests()
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

revoke all on function public.guest_submit_order_utr(bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.guest_submit_order_utr(bigint, text, text, text) to service_role;
revoke all on function public.guest_submit_payment_screenshot(bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.guest_submit_payment_screenshot(bigint, text, text, text) to service_role;
revoke all on function public.admin_list_rental_requests() from public, anon;
revoke all on function public.admin_guest_order_delivery(bigint) from public, anon;
revoke all on function public.admin_mark_guest_order_email_sent(bigint) from public, anon;
grant execute on function public.admin_list_rental_requests() to authenticated;
grant execute on function public.admin_guest_order_delivery(bigint) to authenticated;
grant execute on function public.admin_mark_guest_order_email_sent(bigint) to authenticated;

commit;
