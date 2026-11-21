begin;

-- UTR failed-attempt rate-limit configuration
-- Change these two values only: max failed attempts and block duration.
-- MAX_FAILED_UTR_ATTEMPTS_PER_ORDER: 5
-- UTR_BLOCK_DURATION_MINUTES: 5

alter table private.order_utr_attempts
  add column if not exists order_id bigint;
alter table private.guest_utr_attempts
  add column if not exists order_id bigint;

create index if not exists order_utr_attempts_order_time_idx
  on private.order_utr_attempts (order_id, attempted_at desc);
create index if not exists guest_utr_attempts_order_time_idx
  on private.guest_utr_attempts (order_id, attempted_at desc);

alter table public.orders
  add column if not exists payment_screenshot_bytes bytea,
  add column if not exists payment_screenshot_mime text,
  add column if not exists payment_screenshot_submitted_at timestamptz;

create or replace function public.submit_product_payment_utr(p_order_id bigint, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_user_id uuid := auth.uid();
  v_utr text := regexp_replace(btrim(coalesce(p_utr, '')), '\s+', '', 'g');
  v_latest timestamptz;
  v_attempts integer;
  v_remaining integer;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = v_user_id
      and payment_method in ('upi_qr', 'upi_app')
      and status in ('unpaid', 'pending_payment', 'expired')
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'This payment order can no longer accept a UTR.');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 0));
  select count(*), max(attempted_at) into v_attempts, v_latest
  from private.order_utr_attempts
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
    insert into private.order_utr_attempts (user_id, order_id) values (v_user_id, p_order_id);
    select count(*), max(attempted_at) into v_attempts, v_latest
    from private.order_utr_attempts
    where order_id = p_order_id
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
    insert into private.order_utr_attempts (user_id, order_id) values (v_user_id, p_order_id);
    select count(*), max(attempted_at) into v_attempts, v_latest
    from private.order_utr_attempts
    where order_id = p_order_id
      and attempted_at > clock_timestamp() - interval '5 minutes';
    v_remaining := case when v_attempts >= 5 then
      greatest(0, ceil(extract(epoch from (v_latest + interval '5 minutes' - clock_timestamp())))::integer) else 0 end;
    if v_attempts >= 5 then
      return jsonb_build_object('ok', false, 'reason', 'rate_limited',
        'message', 'If you have already paid, do not worry. We will verify your UTR and confirm your order.',
        'order_id', p_order_id, 'retry_after_seconds', v_remaining,
        'wait_message', 'Try again in ' || to_char(make_interval(secs => v_remaining), 'MI:SS'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'duplicate',
      'message', 'This UTR has already been used.',
      'remaining_attempts', greatest(0, 5 - v_attempts));
  end if;

  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then
    insert into private.order_utr_attempts (user_id, order_id) values (v_user_id, p_order_id);
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
    'payment_submitted_at', clock_timestamp()
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
  v_utr text := regexp_replace(btrim(coalesce(p_utr, '')), '\s+', '', 'g');
  v_latest timestamptz;
  v_attempts integer;
  v_remaining integer;
begin
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id is null
      and o.guest_access_hash = p_access_hash
      and o.guest_email is not null and o.guest_email_sent_at is null
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

create or replace function public.submit_payment_screenshot(
  p_order_id bigint, p_screenshot_base64 text, p_screenshot_mime text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_bytes bytea;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if p_screenshot_mime not in ('image/png', 'image/jpeg', 'image/webp') then
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
  where id = p_order_id and user_id = v_user_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'Order could not be verified.');
  end if;
  return jsonb_build_object('ok', true, 'message', 'Payment screenshot submitted for manual verification.');
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
  where id = p_order_id and user_id is null
    and guest_access_hash = p_access_hash;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'Order could not be verified.');
  end if;
  return jsonb_build_object('ok', true, 'message', 'Payment screenshot submitted for manual verification.');
end;
$$;

create or replace function public.admin_order_payment_screenshot(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.orders%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select * into v_row from public.orders where id = p_order_id;
  if not found or v_row.payment_screenshot_bytes is null then
    return jsonb_build_object('ok', false, 'message', 'No payment screenshot is available.');
  end if;
  return jsonb_build_object(
    'ok', true, 'mime', v_row.payment_screenshot_mime,
    'base64', encode(v_row.payment_screenshot_bytes, 'base64')
  );
end;
$$;

revoke all on function public.submit_product_payment_utr(bigint,text) from public, anon;
grant execute on function public.submit_product_payment_utr(bigint,text) to authenticated;
revoke all on function public.guest_submit_order_utr(bigint,text,text,text) from public, anon, authenticated;
grant execute on function public.guest_submit_order_utr(bigint,text,text,text) to service_role;
revoke all on function public.submit_payment_screenshot(bigint,text,text) from public, anon;
grant execute on function public.submit_payment_screenshot(bigint,text,text) to authenticated;
revoke all on function public.guest_submit_payment_screenshot(bigint,text,text,text) from public, anon, authenticated;
grant execute on function public.guest_submit_payment_screenshot(bigint,text,text,text) to service_role;
revoke all on function public.admin_order_payment_screenshot(bigint) from public, anon, authenticated;
grant execute on function public.admin_order_payment_screenshot(bigint) to authenticated;

create or replace function private.force_pending_verification_on_utr()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(btrim(new.utr), '') <> '' or coalesce(btrim(new.utr_number), '') <> '' then
    new.status := 'pending_verification';
    new.payment_status := 'pending';
  end if;
  return new;
end;
$$;

drop trigger if exists force_pending_verification_on_utr on public.orders;
create trigger force_pending_verification_on_utr
before update of utr, utr_number on public.orders
for each row execute function private.force_pending_verification_on_utr();

commit;
