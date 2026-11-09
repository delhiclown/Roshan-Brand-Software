create or replace function public.prepare_product_payment(
  p_order_id bigint,
  p_product_id bigint,
  p_expected_price numeric,
  p_original_price numeric,
  p_discount_percent numeric,
  p_max_discount_amount numeric,
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
  v_final_price numeric(12, 2);
  v_discount_amount numeric(12, 2);
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
  if p_expected_price is null or p_original_price is null or p_discount_percent is null
     or p_discount_percent < 0 or p_discount_percent > 100
     or p_max_discount_amount is null or p_max_discount_amount < 0 then
    return jsonb_build_object('ok', false, 'message', 'The submitted payment amount is invalid.');
  end if;
  if (v_coupon is null and (p_discount_percent <> 0 or p_max_discount_amount <> 0))
     or (v_coupon is not null and
       (v_coupon !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' or p_discount_percent <= 0)) then
    return jsonb_build_object('ok', false, 'message', 'Coupon details do not match the payment amount.');
  end if;

  select * into v_product from public.products
    where id = p_product_id and in_stock = true for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Product is unavailable.'); end if;
  if p_original_price <> v_product.price then
    return jsonb_build_object('ok', false, 'reason', 'price_changed', 'price', v_product.price);
  end if;

  v_discount_amount := round(least(
    v_product.price * (p_discount_percent / 100),
    case when p_max_discount_amount > 0 then p_max_discount_amount else v_product.price end
  ), 2);
  v_final_price := round(greatest(v_product.price - v_discount_amount, 0), 2);
  if v_final_price <= 0 or p_expected_price <> v_final_price then
    return jsonb_build_object('ok', false, 'message', 'The calculated coupon amount changed. Please review checkout.');
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
      v_final_price, 'pending_payment', p_payment_method, 'pending',
      v_coupon, p_discount_percent, v_product.price, v_created_at,
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
      price = v_final_price,
      payment_method = p_payment_method,
      coupon_code = v_coupon,
      discount_percent = p_discount_percent,
      original_price = v_product.price
    where id = v_order.id
    returning * into v_order;
  end if;

  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'original_price', v_order.original_price,
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(), 'timeout_minutes', v_timeout,
    'grace_minutes', v_grace
  );
end;
$$;

revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, text, text)
  from public, anon, authenticated;
revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, numeric, text, text)
  from public, anon;
grant execute on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, numeric, text, text)
  to authenticated;
