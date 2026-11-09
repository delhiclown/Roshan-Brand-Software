begin;

alter table public.orders add column if not exists payment_expires_at timestamptz;
alter table public.orders add column if not exists utr_submitted_at timestamptz;
alter table public.orders add column if not exists late_payment boolean not null default false;
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('pending_payment', 'pending', 'pending_verification', 'completed', 'delivered', 'rejected', 'refunded', 'expired'));
update public.orders
set utr_submitted_at = created_at
where utr is not null and utr_submitted_at is null;

create table if not exists public.payment_timer_config (
  id boolean primary key default true check (id),
  payment_timeout_minutes integer not null default 10 check (payment_timeout_minutes between 1 and 120),
  payment_grace_minutes integer not null default 5 check (payment_grace_minutes between 0 and 1440)
);
insert into public.payment_timer_config (id, payment_timeout_minutes, payment_grace_minutes)
values (true, 10, 5)
on conflict (id) do nothing;
alter table public.payment_timer_config enable row level security;
revoke all on public.payment_timer_config from public, anon, authenticated;

create index if not exists orders_unsubmitted_payment_expiry_idx
  on public.orders (payment_expires_at)
  where status = 'pending_payment' and utr is null;

create or replace function public.prepare_product_payment(
  p_order_id bigint,
  p_product_id bigint,
  p_expected_price numeric,
  p_original_price numeric,
  p_discount_percent numeric,
  p_coupon_code text,
  p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_product public.products%rowtype;
  v_order public.orders%rowtype;
  v_coupon text := upper(nullif(trim(coalesce(p_coupon_code, '')), ''));
  v_timeout integer;
  v_grace integer;
  v_created_at timestamptz;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if p_payment_method not in ('upi_qr', 'upi_app') then
    return jsonb_build_object('ok', false, 'message', 'Choose a supported UPI payment method.');
  end if;
  if not coalesce((
    select case p_payment_method
      when 'upi_qr' then enable_upi_qr
      when 'upi_app' then enable_upi_app
      else false
    end and length(trim(upi_id)) > 0 and length(trim(upi_payee_name)) > 0
    from public.settings where id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'This payment method is currently unavailable.');
  end if;
  if p_expected_price is null or p_original_price is null or p_expected_price <= 0
     or p_original_price <= 0 or p_expected_price > p_original_price
     or p_discount_percent is null or p_discount_percent < 0 or p_discount_percent > 100 then
    return jsonb_build_object('ok', false, 'message', 'The submitted payment amount is invalid.');
  end if;
  if (v_coupon is null and (p_discount_percent <> 0 or p_expected_price <> p_original_price))
     or (v_coupon is not null and (v_coupon !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' or p_discount_percent <= 0)) then
    return jsonb_build_object('ok', false, 'message', 'Coupon details do not match the payment amount.');
  end if;

  select * into v_product from public.products
    where id = p_product_id and in_stock = true for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Product is unavailable.'); end if;
  if v_product.price <> p_original_price then
    return jsonb_build_object('ok', false, 'reason', 'price_changed', 'price', v_product.price);
  end if;

  select payment_timeout_minutes,payment_grace_minutes into v_timeout,v_grace
    from public.payment_timer_config where id = true;
  v_timeout := coalesce(v_timeout, 10);
  v_grace := coalesce(v_grace, 5);

  if p_order_id is null then
    v_created_at := clock_timestamp();
    insert into public.orders (
      user_id, product_id, product_name, product_type, price, status,
      payment_method, payment_status, coupon_code, discount_percent,
      original_price, created_at, payment_expires_at
    ) values (
      v_user_id, v_product.id, v_product.name, v_product.category,
      p_expected_price, 'pending_payment', p_payment_method, 'pending',
      v_coupon, p_discount_percent, p_original_price,v_created_at,
      v_created_at + make_interval(mins => v_timeout)
    ) returning * into v_order;
  else
    select * into v_order
      from public.orders
      where id = p_order_id and user_id = v_user_id
        and product_id = p_product_id and status = 'pending_payment'
        and utr is null and offer_claim_id is null
        and payment_expires_at is not null
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This payment order can no longer be changed.');
    end if;
    update public.orders set
      product_name = v_product.name,
      product_type = v_product.category,
      price = p_expected_price,
      payment_method = p_payment_method,
      coupon_code = v_coupon,
      discount_percent = p_discount_percent,
      original_price = p_original_price
    where id = v_order.id
    returning * into v_order;
  end if;

  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(), 'timeout_minutes', v_timeout,
    'grace_minutes', v_grace
  );
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
  select * into v_order from public.orders
    where id = p_order_id and user_id = auth.uid() and product_id = p_product_id
      and payment_method in ('upi_qr', 'upi_app')
      and status in ('pending_payment', 'expired')
      and utr is null and offer_claim_id is null
      and payment_expires_at is not null;
  if not found then return jsonb_build_object('ok', false, 'message', 'No resumable payment order was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true),
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'original_price', v_order.original_price
  );
end;
$$;

create or replace function public.submit_product_payment_utr(p_order_id bigint, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_utr text := trim(coalesce(p_utr, ''));
  v_normalized_utr text := lower(trim(coalesce(p_utr, '')));
  v_late boolean;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if v_utr !~ '^[0-9]{12}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid 12-digit UTR / transaction ID.');
  end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = auth.uid()
      and payment_method in ('upi_qr', 'upi_app')
      and status in ('pending_payment', 'expired')
      and utr is null and offer_claim_id is null
      and payment_expires_at is not null
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This payment order can no longer accept a UTR.');
  end if;
  if exists (select 1 from public.payment_utr_claims where utr_normalized = v_normalized_utr)
     or exists (select 1 from public.topup_requests where lower(utr) = v_normalized_utr)
     or exists (select 1 from public.orders where lower(utr) = v_normalized_utr) then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_normalized_utr, 'product_order') on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  v_late := v_order.status = 'expired'
    or clock_timestamp() > v_order.payment_expires_at;
  update public.orders set
    utr = v_utr,
    utr_submitted_at = clock_timestamp(),
    late_payment = v_late,
    status = 'pending_verification',
    payment_status = 'pending'
  where id = v_order.id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'status', 'pending_verification',
    'late_payment', v_late, 'utr_submitted_at', clock_timestamp()
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
  v_grace integer;
  v_expired integer;
begin
  select payment_grace_minutes into v_grace
    from public.payment_timer_config where id = true;
  v_grace := coalesce(v_grace, 5);
  update public.orders set status = 'expired', payment_status = 'rejected'
    where status = 'pending_payment' and utr is null
      and payment_expires_at + make_interval(mins => v_grace) <= clock_timestamp();
  get diagnostics v_expired = row_count;
  return v_expired;
end;
$$;

drop function if exists public.admin_list_orders();
create function public.admin_list_orders()
returns table(
  id bigint, user_id uuid, user_email text, product_name text, product_type text,
  price numeric, status text, created_at timestamptz, delivery_text text,
  delivery_link text, delivery_note text, delivered_at timestamptz,
  payment_method text, payment_status text, utr text, coupon_code text,
  discount_percent numeric, original_price numeric, reject_reason text,
  quantity integer, offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query select o.id,o.user_id,coalesce(u.email::text,''),o.product_name,
      coalesce(o.product_type,p.category,''),o.price,o.status,o.created_at,
      o.delivery_text,o.delivery_link,o.delivery_note,o.delivered_at,
      o.payment_method,o.payment_status,o.utr,o.coupon_code,o.discount_percent,o.original_price,o.reject_reason,
      o.quantity,o.offer_id,o.offer_claim_id,o.is_offer_free,o.expires_at,
      o.payment_expires_at,o.utr_submitted_at,o.late_payment
    from public.orders o join auth.users u on u.id=o.user_id
      left join public.products p on p.id=o.product_id
    order by case when o.late_payment then 0 when o.status='pending_verification' then 1
      when o.status='pending_payment' then 2 else 3 end,o.created_at desc;
end;
$$;

drop function if exists public.my_orders();
create function public.my_orders()
returns table(
  id bigint, product_id bigint, product_name text, product_type text, price numeric, status text,
  created_at timestamptz, delivery_text text, delivery_link text,
  delivery_note text, delivered_at timestamptz, payment_method text, payment_status text,
  coupon_code text, discount_percent numeric, original_price numeric, reject_reason text,
  quantity integer, offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  return query select o.id,o.product_id,o.product_name,coalesce(o.product_type,p.category,''),o.price,
      o.status,o.created_at,
      case when o.status='delivered' then o.delivery_text else null end,
      case when o.status='delivered' then o.delivery_link else null end,
      case when o.status='delivered' then o.delivery_note else null end,
      case when o.status='delivered' then o.delivered_at else null end,
      o.payment_method,o.payment_status,o.coupon_code,o.discount_percent,o.original_price,o.reject_reason,
      o.quantity,o.offer_id,o.offer_claim_id,o.is_offer_free,o.expires_at,
      o.payment_expires_at,o.utr_submitted_at,o.late_payment
    from public.orders o left join public.products p on p.id=o.product_id
    where o.user_id=v_user_id order by o.created_at desc limit 50;
end;
$$;

revoke all on function public.create_upi_product_order(bigint, numeric, numeric, numeric, text, text, text) from public, anon, authenticated;
revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, text, text) from public, anon;
revoke all on function public.get_my_pending_product_payment(bigint, bigint) from public, anon;
revoke all on function public.submit_product_payment_utr(bigint, text) from public, anon;
revoke all on function public.expire_pending_product_payments() from public, anon, authenticated;
revoke all on function public.admin_list_orders() from public, anon;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, text, text) to authenticated;
grant execute on function public.get_my_pending_product_payment(bigint, bigint) to authenticated;
grant execute on function public.submit_product_payment_utr(bigint, text) to authenticated;
grant execute on function public.admin_list_orders() to authenticated;
grant execute on function public.my_orders() to authenticated;

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
