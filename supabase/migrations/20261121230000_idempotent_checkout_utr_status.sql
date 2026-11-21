begin;

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
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id = v_user_id
      and o.payment_method in ('upi_qr', 'upi_app')
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_order',
      'message', 'This payment order can no longer accept a UTR.');
  end if;
  if v_order.utr is not null or v_order.utr_number is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_submitted',
      'already_submitted', true,
      'message', 'Please wait, your UTR is already submitted.',
      'order_id', v_order.id, 'status', v_order.status);
  end if;
  if v_order.status not in ('unpaid', 'pending_payment', 'expired') then
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

  update public.orders as o set
    utr = v_utr, utr_number = v_utr,
    utr_submitted_at = clock_timestamp(), payment_submitted_at = clock_timestamp(),
    late_payment = (v_order.status = 'expired'
      or (v_order.payment_expires_at is not null and clock_timestamp() > v_order.payment_expires_at)),
    status = 'pending_verification', payment_status = 'pending'
  where o.id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'status', 'pending_verification',
    'message', 'Your UTR has been submitted. Please wait for verification.',
    'payment_submitted_at', clock_timestamp()
  );
end;
$$;

revoke all on function public.submit_product_payment_utr(bigint,text) from public, anon;
grant execute on function public.submit_product_payment_utr(bigint,text) to authenticated;

commit;
