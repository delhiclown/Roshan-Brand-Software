begin;

-- Payment timer configuration defaults: 10 minutes to pay, then a 5-minute
-- grace period for late UTR submission. Adjust payment_timer_config to change them.
comment on column public.payment_timer_config.payment_timeout_minutes is
  'Payment QR lifetime in minutes (default 10); changing this controls payment_expires_at.';
comment on column public.payment_timer_config.payment_grace_minutes is
  'Late-payment UTR grace period in minutes (default 5); late UTRs remain reviewable afterwards.';

create or replace function public.expire_my_payment_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  update public.orders
  set status = 'expired', payment_status = 'rejected'
  where id = p_order_id and user_id = v_user_id
    and payment_method in ('upi_qr', 'upi_app')
    and status in ('pending_payment', 'unpaid') and utr is null
    and payment_expires_at is not null and payment_expires_at <= clock_timestamp()
  returning * into v_order;
  if not found then
    select * into v_order from public.orders
    where id = p_order_id and user_id = v_user_id
      and payment_method in ('upi_qr', 'upi_app');
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Payment order was not found.');
  end if;
  if v_order.status = 'expired' and v_order.utr is null then
    update public.coupons
    set status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
        used_at = null, used_order_id = null
    where used_order_id = v_order.id;
  end if;
  return jsonb_build_object('ok', true, 'status', v_order.status);
end;
$$;

create or replace function public.get_my_pending_product_payment(p_order_id bigint, p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  update public.orders
  set status = 'expired', payment_status = 'rejected'
  where id = p_order_id and user_id = auth.uid() and product_id = p_product_id
    and payment_method in ('upi_qr', 'upi_app')
    and status in ('pending_payment', 'unpaid') and utr is null
    and payment_expires_at is not null and payment_expires_at <= clock_timestamp();
  update public.coupons
  set status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null
  where used_order_id = p_order_id
    and exists (select 1 from public.orders o where o.id = p_order_id
      and o.user_id = auth.uid() and o.status = 'expired' and o.utr is null);

  select * into v_order from public.orders
  where id = p_order_id and user_id = auth.uid() and product_id = p_product_id
    and payment_method in ('upi_qr', 'upi_app')
    and (
      (status in ('pending_payment', 'unpaid') and utr is null
        and payment_expires_at > clock_timestamp())
      or status = 'pending_verification'
    );
  if not found then
    return jsonb_build_object('ok', false, 'message', 'No active payment order was found.');
  end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'utr', v_order.utr,
    'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true),
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'original_price', v_order.original_price,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp
  );
end;
$$;

create or replace function public.get_my_pending_used_key_payment(p_order_id bigint, p_used_key_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  update public.orders
  set status = 'expired', payment_status = 'rejected'
  where id = p_order_id and user_id = auth.uid() and used_key_id = p_used_key_id
    and payment_method = 'upi_qr'
    and status in ('pending_payment', 'unpaid') and utr is null
    and payment_expires_at is not null and payment_expires_at <= clock_timestamp();
  select * into v_order from public.orders
  where id = p_order_id and user_id = auth.uid() and used_key_id = p_used_key_id
    and (
      (status in ('pending_payment', 'unpaid') and utr is null
        and payment_expires_at > clock_timestamp())
      or status = 'pending_verification'
    );
  if not found then
    return jsonb_build_object('ok', false, 'message', 'No active Used Keys payment was found.');
  end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'utr', v_order.utr,
    'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(),
    'grace_minutes', (select c.payment_grace_minutes
      from public.payment_timer_config c where c.id = true)
  );
end;
$$;

create or replace function public.get_my_expired_payment_orders(p_order_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if coalesce(cardinality(p_order_ids), 0) > 25 then
    return jsonb_build_object('ok', false, 'message', 'Too many expired orders were requested.');
  end if;
  update public.orders o
  set status = 'expired', payment_status = 'rejected'
  where o.id = any(coalesce(p_order_ids, array[]::bigint[]))
    and o.user_id = v_user_id and o.payment_method in ('upi_qr', 'upi_app')
    and o.status in ('pending_payment', 'unpaid') and o.utr is null
    and o.payment_expires_at is not null and o.payment_expires_at <= clock_timestamp();
  update public.coupons c
  set status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null
  where c.used_order_id = any(coalesce(p_order_ids, array[]::bigint[]))
    and exists (select 1 from public.orders o where o.id = c.used_order_id
      and o.user_id = v_user_id and o.status = 'expired' and o.utr is null);
  return jsonb_build_object(
    'ok', true,
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
        'order_id', o.id, 'product_id', o.product_id, 'price', o.price,
        'payment_method', o.payment_method, 'status', o.status,
        'payment_expires_at', o.payment_expires_at, 'created_at', o.created_at
      ) order by o.created_at desc)
      from public.orders o
      where o.id = any(coalesce(p_order_ids, array[]::bigint[]))
        and o.user_id = v_user_id
        and o.payment_method in ('upi_qr', 'upi_app')
        and o.status = 'expired' and o.utr is null
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.expire_pending_product_payments()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired integer;
begin
  update public.orders
  set status = 'expired', payment_status = 'rejected'
  where status in ('pending_payment', 'unpaid') and utr is null
    and payment_expires_at is not null and payment_expires_at <= clock_timestamp();
  get diagnostics v_expired = row_count;

  update public.coupons c
  set status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null
  from public.orders o
  where c.used_order_id = o.id and o.status = 'expired' and o.utr is null
    and o.payment_expires_at <= clock_timestamp();
  return v_expired;
end;
$$;

revoke all on function public.expire_my_payment_order(bigint) from public, anon;
grant execute on function public.expire_my_payment_order(bigint) to authenticated;
revoke all on function public.get_my_pending_product_payment(bigint,bigint) from public, anon;
grant execute on function public.get_my_pending_product_payment(bigint,bigint) to authenticated;
revoke all on function public.get_my_pending_used_key_payment(bigint,bigint) from public, anon;
grant execute on function public.get_my_pending_used_key_payment(bigint,bigint) to authenticated;
revoke all on function public.get_my_expired_payment_orders(bigint[]) from public, anon;
grant execute on function public.get_my_expired_payment_orders(bigint[]) to authenticated;
revoke all on function public.expire_pending_product_payments() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    if exists (select 1 from cron.job where jobname = 'expire-pending-product-payments') then
      execute 'select cron.unschedule(''expire-pending-product-payments'')';
    end if;
    execute $schedule$
      select cron.schedule(
        'expire-pending-product-payments',
        '* * * * *',
        'select public.expire_pending_product_payments()'
      )
    $schedule$;
  else
    raise notice 'pg_cron is not available; schedule public.expire_pending_product_payments() to run every minute in Supabase.';
  end if;
end
$$;

commit;
