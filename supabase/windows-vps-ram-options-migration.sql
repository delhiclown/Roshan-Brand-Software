begin;

alter table public.products
  add column if not exists windows_vps_options jsonb not null default '[]'::jsonb;

alter table public.products
  drop constraint if exists products_windows_vps_options_array_check;
alter table public.products
  add constraint products_windows_vps_options_array_check
  check (jsonb_typeof(windows_vps_options) = 'array');

alter table public.orders
  drop constraint if exists orders_software_plan_code_check;
alter table public.orders
  add constraint orders_software_plan_code_check
  check (software_plan_code is null or software_plan_code in (
    '2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days',
    'windows_vps_4gb', 'windows_vps_8gb', 'windows_vps_16gb', 'windows_vps_32gb'
  ));

create or replace function public.prepare_windows_vps_payment(
  p_order_id bigint,
  p_product_id bigint,
  p_plan_code text,
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
  v_coupon public.coupons%rowtype;
  v_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_ram_gb integer;
  v_label text;
  v_option jsonb;
  v_plan_price numeric(12, 2);
  v_coupon_code text := upper(nullif(btrim(coalesce(p_coupon_code, '')), ''));
  v_timeout integer;
  v_grace integer;
  v_discount numeric(12, 2) := 0;
  v_final numeric(12, 2);
  v_created_at timestamptz;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  v_ram_gb := case v_code
    when 'windows_vps_4gb' then 4
    when 'windows_vps_8gb' then 8
    when 'windows_vps_16gb' then 16
    when 'windows_vps_32gb' then 32
  end;
  if v_ram_gb is null then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid Windows VPS RAM option.');
  end if;
  if p_payment_method not in ('upi_qr', 'upi_app') then
    return jsonb_build_object('ok', false, 'message', 'Choose a supported UPI payment method.');
  end if;
  if not coalesce((
    select case p_payment_method when 'upi_qr' then enable_upi_qr when 'upi_app' then enable_upi_app end
      and length(trim(upi_id)) > 0 and length(trim(upi_payee_name)) > 0
    from public.settings where id = true
  ), false) then
    return jsonb_build_object('ok', false, 'message', 'This payment method is currently unavailable.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and lower(category) in ('vps', 'windows-vps')
      and lower(coalesce(os_type, '')) = 'windows'
      and in_stock = true and coalesce(stock_status, 'available') = 'available'
    for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Windows VPS product is unavailable.'); end if;

  if p_order_id is not null then
    select * into v_order from public.orders
      where id = p_order_id and user_id = v_user_id and product_id = p_product_id
        and status in ('pending_payment', 'unpaid') and utr is null and offer_claim_id is null
        and payment_expires_at > clock_timestamp()
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This payment order can no longer be changed.');
    end if;
    if v_order.software_plan_code is not null
       and v_order.software_plan_code is distinct from v_code then
      return jsonb_build_object('ok', false, 'message', 'This order belongs to a different Windows VPS option. Start a new checkout.');
    end if;
    if v_order.software_plan_code = v_code then
      v_plan_price := coalesce(v_order.original_price, v_order.price);
    end if;
  end if;

  v_label := v_ram_gb::text || 'GB RAM';
  if v_plan_price is null then
    select config into v_option
    from jsonb_array_elements(coalesce(v_product.windows_vps_options, '[]'::jsonb)) as item(config)
    where config->>'ram_gb' = v_ram_gb::text and config->>'enabled' = 'true'
    limit 1;
    if v_option is null then
      return jsonb_build_object('ok', false, 'message', 'This Windows VPS RAM option is not currently available.');
    end if;
    if coalesce(v_option->>'price', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
      return jsonb_build_object('ok', false, 'message', 'The selected Windows VPS option has no valid price.');
    end if;
    v_plan_price := (v_option->>'price')::numeric(12, 2);
  end if;
  if v_plan_price is null or v_plan_price <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The selected Windows VPS option has no valid price.');
  end if;

  if v_coupon_code is not null then
    if v_coupon_code !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' then
      return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
    end if;
    select * into v_coupon from public.coupons
      where user_id = v_user_id and upper(btrim(code)) = v_coupon_code for update;
    if not found then return jsonb_build_object('ok', false, 'message', 'Invalid coupon'); end if;
    if v_coupon.expires_at <= clock_timestamp() or v_coupon.status = 'expired' then
      update public.coupons set status = 'expired'
        where id = v_coupon.id and status = 'unused';
      return jsonb_build_object('ok', false, 'message', 'Coupon expired');
    end if;
    if v_coupon.status = 'used'
       and (v_order.id is null or v_coupon.used_order_id is distinct from v_order.id) then
      return jsonb_build_object('ok', false, 'message', 'Coupon already used');
    end if;
    if v_coupon.status not in ('unused', 'used') then
      return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
    end if;
    v_discount := round(least(
      v_plan_price * v_coupon.discount_percent / 100,
      case when v_coupon.max_discount_amount > 0 then v_coupon.max_discount_amount else v_plan_price end
    ), 2);
  end if;
  v_final := round(greatest(v_plan_price - v_discount, 0), 2);
  if v_final <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The calculated payment amount is invalid.');
  end if;
  if v_order.id is not null and v_order.coupon_code is not null
     and upper(btrim(v_order.coupon_code)) is distinct from v_coupon_code then
    update public.coupons set
      status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null
    where used_order_id = v_order.id;
  end if;
  select payment_timeout_minutes, payment_grace_minutes into v_timeout, v_grace
    from public.payment_timer_config where id = true;
  v_timeout := coalesce(v_timeout, 10);
  v_grace := coalesce(v_grace, 5);
  if v_order.id is null then
    v_created_at := clock_timestamp();
    insert into public.orders (
      user_id, product_id, product_name, product_type, price, amount, status,
      payment_method, payment_status, coupon_code, discount_percent,
      original_price, created_at, payment_expires_at,
      software_plan_code, software_plan_label, software_plan_mrp
    ) values (
      v_user_id, v_product.id, v_product.name, v_product.category, v_final, v_final,
      'pending_payment', p_payment_method, 'pending', v_coupon.code,
      coalesce(v_coupon.discount_percent, 0), v_plan_price, v_created_at,
      v_created_at + make_interval(mins => v_timeout), v_code, v_label, null
    ) returning * into v_order;
  else
    update public.orders set
      product_name = v_product.name, product_type = v_product.category,
      price = v_final, amount = v_final, payment_method = p_payment_method,
      coupon_code = v_coupon.code, discount_percent = coalesce(v_coupon.discount_percent, 0),
      original_price = v_plan_price,
      software_plan_code = v_code, software_plan_label = v_label, software_plan_mrp = null
    where id = v_order.id returning * into v_order;
  end if;
  if v_coupon.id is not null then
    update public.coupons set status = 'used',
      used_at = coalesce(used_at, clock_timestamp()), used_order_id = v_order.id
    where id = v_coupon.id;
  end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'original_price', v_order.original_price,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp,
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', clock_timestamp(),
    'timeout_minutes', v_timeout, 'grace_minutes', v_grace
  );
end;
$$;
revoke all on function public.prepare_windows_vps_payment(bigint, bigint, text, text, text) from public, anon;
grant execute on function public.prepare_windows_vps_payment(bigint, bigint, text, text, text) to authenticated;

create or replace function public.purchase_windows_vps(p_product_id bigint, p_plan_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_product public.products%rowtype;
  v_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_ram_gb integer;
  v_label text;
  v_option jsonb;
  v_plan_price numeric(12, 2);
  v_balance numeric(12, 2);
  v_order public.orders%rowtype;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if not coalesce((select enable_wallet_payments from public.settings where id = true), false) then
    return jsonb_build_object('ok', false, 'reason', 'payment_disabled', 'message', 'Wallet payments are currently unavailable.');
  end if;
  v_ram_gb := case v_code
    when 'windows_vps_4gb' then 4
    when 'windows_vps_8gb' then 8
    when 'windows_vps_16gb' then 16
    when 'windows_vps_32gb' then 32
  end;
  if v_ram_gb is null then
    return jsonb_build_object('ok', false, 'reason', 'plan_unavailable', 'message', 'Choose a valid Windows VPS RAM option.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and lower(category) in ('vps', 'windows-vps')
      and lower(coalesce(os_type, '')) = 'windows'
      and in_stock = true and coalesce(stock_status, 'available') = 'available'
    for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'unavailable', 'message', 'Windows VPS product is unavailable.');
  end if;
  select config into v_option
  from jsonb_array_elements(coalesce(v_product.windows_vps_options, '[]'::jsonb)) as item(config)
  where config->>'ram_gb' = v_ram_gb::text and config->>'enabled' = 'true'
  limit 1;
  if v_option is null or coalesce(v_option->>'price', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
    return jsonb_build_object('ok', false, 'reason', 'plan_unavailable', 'message', 'This Windows VPS RAM option is not currently available.');
  end if;
  v_plan_price := (v_option->>'price')::numeric(12, 2);
  if v_plan_price <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'plan_unavailable', 'message', 'The selected Windows VPS option has no valid price.');
  end if;
  v_label := v_ram_gb::text || 'GB RAM';
  insert into public.wallets (user_id) values (v_user_id) on conflict (user_id) do nothing;
  select balance into v_balance from public.wallets where user_id = v_user_id for update;
  if v_balance < v_plan_price then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_balance', 'balance', v_balance);
  end if;
  update public.wallets set balance = balance - v_plan_price, updated_at = now()
    where user_id = v_user_id returning balance into v_balance;
  insert into public.orders (
    user_id, product_id, product_name, product_type, price, amount, original_price,
    status, payment_method, payment_status,
    software_plan_code, software_plan_label, software_plan_mrp
  ) values (
    v_user_id, v_product.id, v_product.name, v_product.category, v_plan_price, v_plan_price, v_plan_price,
    'pending', 'wallet', 'paid', v_code, v_label, null
  ) returning * into v_order;
  insert into public.wallet_transactions (user_id, type, amount, note, order_id)
    values (v_user_id, 'purchase', v_plan_price, 'Purchase: ' || v_product.name || ' · ' || v_label, v_order.id);
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_name', v_order.product_name,
    'software_plan_label', v_order.software_plan_label, 'price', v_order.price,
    'balance', v_balance, 'created_at', v_order.created_at, 'download_ready', false
  );
end;
$$;
revoke all on function public.purchase_windows_vps(bigint, text) from public, anon;
grant execute on function public.purchase_windows_vps(bigint, text) to authenticated;

create or replace function public.guest_create_windows_vps_order(
  p_product_id bigint,
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
  v_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_ram_gb integer;
  v_label text;
  v_option jsonb;
  v_price numeric(12, 2);
  v_product public.products%rowtype;
  v_order public.orders%rowtype;
  v_timeout integer;
  v_now timestamptz := clock_timestamp();
begin
  v_ram_gb := case v_code
    when 'windows_vps_4gb' then 4
    when 'windows_vps_8gb' then 8
    when 'windows_vps_16gb' then 16
    when 'windows_vps_32gb' then 32
  end;
  if v_ram_gb is null then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid Windows VPS RAM option.');
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]{2,}$' or length(v_email) > 254 then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid email address.');
  end if;
  if length(coalesce(v_whatsapp, '')) > 24 or v_whatsapp !~ '^[0-9]{10,15}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid WhatsApp number.');
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
  select * into v_product from public.products
    where id = p_product_id and lower(category) in ('vps', 'windows-vps')
      and lower(coalesce(os_type, '')) = 'windows'
      and in_stock = true and coalesce(stock_status, 'available') = 'available'
    for share;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Windows VPS product is no longer available.');
  end if;
  select option into v_option
  from jsonb_array_elements(coalesce(v_product.windows_vps_options, '[]'::jsonb)) as item(option)
  where option->>'ram_gb' = v_ram_gb::text and option->>'enabled' = 'true'
  limit 1;
  if v_option is null or coalesce(v_option->>'price', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
    return jsonb_build_object('ok', false, 'message', 'This Windows VPS RAM option is not currently available.');
  end if;
  v_price := (v_option->>'price')::numeric(12, 2);
  if v_price <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The selected Windows VPS option has no valid price.');
  end if;
  v_label := v_ram_gb::text || 'GB RAM';
  select payment_timeout_minutes into v_timeout from public.payment_timer_config where id = true;
  v_timeout := coalesce(v_timeout, 10);
  insert into public.orders (
    user_id, guest_email, guest_whatsapp, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_id, product_name, product_type, price, amount, status,
    payment_method, payment_status, quantity, coupon_code, discount_percent,
    original_price, created_at, payment_expires_at,
    software_plan_code, software_plan_label, software_plan_mrp
  ) values (
    null, v_email, v_whatsapp, p_access_hash, p_device_hash, p_ip_hash,
    v_product.id, v_product.name, lower(v_product.category), v_price, v_price,
    'unpaid', 'upi_qr', 'pending', 1, null, 0, v_price,
    v_now, v_now + make_interval(mins => v_timeout),
    v_code, v_label, null
  ) returning * into v_order;
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
revoke all on function public.guest_create_windows_vps_order(bigint, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.guest_create_windows_vps_order(bigint, text, text, text, text, text, text)
  to service_role;

commit;
