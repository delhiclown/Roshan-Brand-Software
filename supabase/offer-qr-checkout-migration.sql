begin;

alter table public.offers
  add column if not exists customer_claim_limit integer not null default 1;
alter table public.offers drop constraint if exists offers_customer_claim_limit_check;
alter table public.offers add constraint offers_customer_claim_limit_check
  check (customer_claim_limit between 1 and 100);

alter table public.orders
  add column if not exists offer_title text,
  add column if not exists offer_paid_quantity integer,
  add column if not exists offer_free_quantity integer;

update public.orders as order_row
set offer_title = coalesce(order_row.offer_title, offer_row.title),
    offer_paid_quantity = coalesce(order_row.offer_paid_quantity, offer_row.paid_quantity),
    offer_free_quantity = coalesce(order_row.offer_free_quantity, offer_row.free_quantity)
from public.offers as offer_row
where order_row.offer_id = offer_row.id
  and (order_row.offer_title is null
    or order_row.offer_paid_quantity is null
    or order_row.offer_free_quantity is null);

create or replace function public.prepare_offer_product_payment(
  p_order_id bigint,
  p_offer_id uuid,
  p_product_id bigint,
  p_plan_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_offer public.offers%rowtype;
  v_product public.products%rowtype;
  v_order public.orders%rowtype;
  v_plan_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_plan_label text;
  v_unit_price numeric(12, 2);
  v_plan_mrp numeric(12, 2);
  v_amount numeric(12, 2);
  v_timeout integer;
  v_grace integer;
  v_existing boolean := false;
  v_count bigint;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if p_offer_id is null or p_product_id is null
     or v_plan_code not in ('2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days') then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid product and Software plan for this offer.');
  end if;
  if not coalesce((
    select enable_upi_qr and length(btrim(upi_id)) > 0 and length(btrim(upi_payee_name)) > 0
    from public.settings where id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'UPI QR payments are currently unavailable.');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_offer_id::text, 0));
  select * into v_offer from public.offers
    where id = p_offer_id and claim_enabled and collection = 'software'
    for share;
  if not found or not v_offer.enabled or v_offer.starts_at > clock_timestamp()
     or v_offer.ends_at <= clock_timestamp() then
    return jsonb_build_object('ok', false, 'message', 'This offer is not currently active.');
  end if;
  if v_offer.paid_quantity + v_offer.free_quantity > 100 then
    return jsonb_build_object('ok', false, 'message', 'The total offer quantity cannot exceed 100.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and lower(category) = 'software' and in_stock = true
      and (v_offer.product_id is null or v_offer.product_id = id)
    for share;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This Software product is no longer available for the offer.');
  end if;

  v_plan_label := case v_plan_code
    when '2_pnr_30_days' then '2 PNR 30 DAYS'
    when '4_pnr_30_days' then '4 PNR 30 DAYS'
    else '6 PNR 30 DAYS'
  end;
  if v_plan_code = '2_pnr_30_days' and v_product.plan_2_pnr_enabled then
    v_unit_price := v_product.plan_2_pnr_price; v_plan_mrp := v_product.plan_2_pnr_mrp;
  elsif v_plan_code = '4_pnr_30_days' and v_product.plan_4_pnr_enabled then
    v_unit_price := v_product.plan_4_pnr_price; v_plan_mrp := v_product.plan_4_pnr_mrp;
  elsif v_plan_code = '6_pnr_30_days' and v_product.plan_6_pnr_enabled then
    v_unit_price := v_product.plan_6_pnr_price; v_plan_mrp := v_product.plan_6_pnr_mrp;
  else
    return jsonb_build_object('ok', false, 'message', 'This Software plan is not currently available.');
  end if;
  if v_unit_price is null or v_unit_price <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The selected Software plan has no valid price.');
  end if;

  if p_order_id is not null then
    select * into v_order from public.orders
      where id = p_order_id and user_id = v_user_id and offer_id = p_offer_id
        and product_id = p_product_id and software_plan_code = v_plan_code
        and status in ('unpaid', 'pending_payment', 'pending_verification', 'utr_submitted')
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This offer payment order can no longer be resumed.');
    end if;
    v_existing := true;
  else
    select * into v_order from public.orders
      where user_id = v_user_id and offer_id = p_offer_id
        and status in ('unpaid', 'pending_payment', 'pending_verification', 'utr_submitted')
        and (status in ('pending_verification', 'utr_submitted') or payment_expires_at > clock_timestamp())
      order by created_at desc limit 1
      for update;
    v_existing := found;
    if v_existing and (v_order.product_id is distinct from p_product_id
       or v_order.software_plan_code is distinct from v_plan_code) then
      return jsonb_build_object('ok', false, 'message', 'You already have an active order for this offer. Resume it from My Orders.');
    end if;
  end if;

  if not v_existing then
    update public.orders set status = 'expired', payment_status = 'rejected'
      where user_id = v_user_id and offer_id = p_offer_id
        and status in ('unpaid', 'pending_payment')
        and utr is null and payment_expires_at <= clock_timestamp();
    select
      (select count(distinct coalesce(offer_claim_id::text, 'order:' || id::text)) from public.orders
        where user_id = v_user_id and offer_id = p_offer_id
          and not is_offer_free and not (status = 'expired' and utr is null))
      +
      (select count(*) from public.offer_claims c
        where c.user_id = v_user_id and c.offer_id = p_offer_id
          and c.status not in ('rejected', 'expired')
          and not exists (
            select 1 from public.orders o where o.offer_claim_id = c.id
          ))
      into v_count;
    if v_count >= v_offer.customer_claim_limit then
      return jsonb_build_object('ok', false, 'message',
        'You have reached the claim limit for this offer (' || v_offer.customer_claim_limit || ').');
    end if;
    v_amount := round(v_unit_price * v_offer.paid_quantity, 2);
    if v_amount <= 0 then
      return jsonb_build_object('ok', false, 'message', 'The offer payment amount is invalid.');
    end if;
    select payment_timeout_minutes, payment_grace_minutes into v_timeout, v_grace
      from public.payment_timer_config where id = true;
    v_timeout := coalesce(v_timeout, 10);
    v_grace := coalesce(v_grace, 5);
    insert into public.orders(
      user_id, product_id, product_name, product_type, price, original_price,
      status, payment_method, payment_status, quantity, offer_id, offer_title,
      offer_paid_quantity, offer_free_quantity, software_plan_code,
      software_plan_label, software_plan_mrp, created_at, payment_expires_at
    ) values (
      v_user_id, v_product.id, v_product.name, 'software', v_amount, v_amount,
      'unpaid', 'upi_qr', 'pending',
      v_offer.paid_quantity + v_offer.free_quantity,
      v_offer.id, v_offer.title, v_offer.paid_quantity, v_offer.free_quantity,
      v_plan_code, v_plan_label, v_plan_mrp, clock_timestamp(),
      clock_timestamp() + make_interval(mins => v_timeout)
    ) returning * into v_order;
  else
    v_timeout := coalesce((select payment_timeout_minutes from public.payment_timer_config where id = true), 10);
    v_grace := coalesce((select payment_grace_minutes from public.payment_timer_config where id = true), 5);
  end if;

  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'original_price', v_order.original_price,
    'unit_price', v_unit_price, 'payment_method', v_order.payment_method,
    'status', v_order.status, 'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(), 'timeout_minutes', v_timeout,
    'grace_minutes', v_grace, 'offer_title', v_order.offer_title,
    'offer_paid_quantity', v_order.offer_paid_quantity,
    'offer_free_quantity', v_order.offer_free_quantity,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp
  );
end;
$$;
revoke all on function public.prepare_offer_product_payment(bigint, uuid, bigint, text) from public, anon;
grant execute on function public.prepare_offer_product_payment(bigint, uuid, bigint, text) to authenticated;

create or replace function public.my_offer_order_details()
returns table(
  order_id bigint, offer_id uuid, offer_title text,
  offer_paid_quantity integer, offer_free_quantity integer,
  status text, counts_toward_limit boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  return query select o.id, o.offer_id, o.offer_title,
      o.offer_paid_quantity, o.offer_free_quantity, o.status,
      not o.is_offer_free and not (o.status = 'expired' and o.utr is null)
    from public.orders o
    where o.user_id = auth.uid() and o.offer_id is not null
    order by o.created_at desc limit 100;
end;
$$;

create or replace function public.admin_list_offer_order_details(p_order_ids bigint[])
returns table(
  order_id bigint, offer_id uuid, offer_title text,
  offer_paid_quantity integer, offer_free_quantity integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query select o.id, o.offer_id, o.offer_title,
      o.offer_paid_quantity, o.offer_free_quantity
    from public.orders o
    where o.id = any(coalesce(p_order_ids, array[]::bigint[]))
      and o.offer_id is not null;
end;
$$;

revoke all on function public.my_offer_order_details() from public, anon;
revoke all on function public.admin_list_offer_order_details(bigint[]) from public, anon;
grant execute on function public.my_offer_order_details() to authenticated;
grant execute on function public.admin_list_offer_order_details(bigint[]) to authenticated;

commit;
