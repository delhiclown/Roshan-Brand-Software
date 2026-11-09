begin;

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
        and payment_expires_at > clock_timestamp()
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
      and status = 'pending_payment'
      and utr is null and offer_claim_id is null
      and payment_expires_at > clock_timestamp();
  if not found then return jsonb_build_object('ok', false, 'message', 'No active payment order was found.'); end if;
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

revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, text, text)
  from public, anon, authenticated;
revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, numeric, text, text)
  from public, anon;
grant execute on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, numeric, text, text)
  to authenticated;

create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code text not null,
  discount_percent integer not null check (discount_percent between 1 and 100),
  max_discount_amount numeric(12, 2) not null default 0 check (max_discount_amount >= 0),
  status text not null default 'unused' check (status in ('unused', 'used', 'expired')),
  source text not null default 'spin',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_order_id bigint references public.orders(id)
);

create unique index if not exists coupons_code_normalized_uidx
  on public.coupons (upper(btrim(code)));
create index if not exists coupons_user_status_expiry_idx
  on public.coupons (user_id, status, expires_at);
create index if not exists coupons_used_order_idx
  on public.coupons (used_order_id) where used_order_id is not null;

alter table public.coupons enable row level security;
revoke all on public.coupons from public, anon, authenticated;
grant select on public.coupons to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'coupons'
      and policyname = 'Customers and admins can read coupons'
  ) then
    create policy "Customers and admins can read coupons" on public.coupons
      for select to authenticated
      using (user_id = (select auth.uid()) or (select public.is_store_admin()));
  end if;
end
$$;

create table if not exists public.spin_prize_config (
  id boolean primary key default true check (id),
  prizes jsonb not null
);
revoke all on public.spin_prize_config from public, anon, authenticated;
alter table public.spin_prize_config enable row level security;

insert into public.spin_prize_config (id, prizes)
values (true, '[
  {"code":"SAVE20","label":"20%","type":"percent","value":20,"color":"#e11d48","maxDiscountAmount":500,"weight":15},
  {"code":"SAVE50","label":"50%","type":"percent","value":50,"color":"#2f3fb8","maxDiscountAmount":500,"weight":10},
  {"code":"SAVE100","label":"100%","type":"percent","value":100,"color":"#f5c04a","maxDiscountAmount":500,"weight":4},
  {"code":"BONUS100","label":"100%","type":"percent","value":100,"color":"#e11d48","maxDiscountAmount":500,"weight":1},
  {"code":"TRY_AGAIN","label":"TRY AGAIN","type":"tryAgain","value":0,"color":"#2a2f3a","maxDiscountAmount":0,"weight":45},
  {"code":"SAVE10","label":"10%","type":"percent","value":10,"color":"#2f3fb8","maxDiscountAmount":500,"weight":25}
]')
on conflict (id) do nothing;

create table if not exists public.spin_attempts (
  id bigint generated by default as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  spin_date date not null,
  prize_code text not null,
  coupon_id uuid references public.coupons(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint spin_attempts_one_per_user_utc_day unique (user_id, spin_date)
);
create index if not exists spin_attempts_user_created_idx
  on public.spin_attempts (user_id, created_at desc);
alter table public.spin_attempts enable row level security;
revoke all on public.spin_attempts from public, anon, authenticated;

create table if not exists public.coupon_validation_attempts (
  id bigint generated by default as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default clock_timestamp()
);
create index if not exists coupon_validation_attempts_user_time_idx
  on public.coupon_validation_attempts (user_id, attempted_at desc);
alter table public.coupon_validation_attempts enable row level security;
revoke all on public.coupon_validation_attempts from public, anon, authenticated;

create or replace function public.public_spin_prizes()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select prizes from public.spin_prize_config where id = true;
$$;
revoke all on function public.public_spin_prizes() from public;
grant execute on function public.public_spin_prizes() to anon, authenticated;

create or replace function public.admin_save_spin_prizes(p_prizes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_code text;
  v_label text;
  v_type text;
  v_value integer;
  v_color text;
  v_max_discount numeric;
  v_weight numeric;
  v_total_weight numeric := 0;
  v_codes text[] := array[]::text[];
  v_normalized jsonb := '[]'::jsonb;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_prizes) <> 'array'
     or jsonb_array_length(p_prizes) not between 1 and 16 then
    raise exception 'Provide between 1 and 16 spin prizes.';
  end if;
  for v_item in select value from jsonb_array_elements(p_prizes)
  loop
    v_code := upper(btrim(coalesce(v_item->>'code', '')));
    v_type := coalesce(v_item->>'type', 'percent');
    v_value := coalesce((v_item->>'value')::integer, 0);
    v_label := btrim(coalesce(v_item->>'label', ''));
    v_color := lower(coalesce(v_item->>'color', ''));
    v_max_discount := coalesce((v_item->>'maxDiscountAmount')::numeric, 0);
    v_weight := coalesce((v_item->>'weight')::numeric, 0);
    if v_code = '' or v_code = any(v_codes) or v_type not in ('percent', 'tryAgain')
       or v_label = '' or v_color !~ '^#[0-9a-f]{6}$'
       or v_max_discount < 0 or v_weight < 0
       or (v_type = 'percent' and v_value not between 1 and 100)
       or (v_type = 'tryAgain' and v_value <> 0) then
      raise exception 'A spin prize contains invalid or duplicate values.';
    end if;
    v_codes := array_append(v_codes, v_code);
    v_total_weight := v_total_weight + v_weight;
    v_normalized := v_normalized || jsonb_build_array(jsonb_build_object(
      'code', v_code, 'label', case when v_type = 'tryAgain' then v_label else v_value::text || '%' end,
      'type', v_type, 'value', v_value, 'color', v_color,
      'maxDiscountAmount', case when v_type = 'tryAgain' then 0 else v_max_discount end,
      'weight', v_weight
    ));
  end loop;
  if v_total_weight <= 0 then raise exception 'At least one spin prize must have a positive weight.'; end if;
  insert into public.spin_prize_config (id, prizes) values (true, v_normalized)
  on conflict (id) do update set prizes = excluded.prizes;
  return jsonb_build_object('ok', true, 'prizes', v_normalized);
end;
$$;
revoke all on function public.admin_save_spin_prizes(jsonb) from public, anon;
grant execute on function public.admin_save_spin_prizes(jsonb) to authenticated;

create or replace function public.spin_wheel()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := (clock_timestamp() at time zone 'UTC')::date;
  v_prizes jsonb;
  v_item jsonb;
  v_prize jsonb;
  v_total_weight numeric := 0;
  v_target numeric;
  v_running numeric := 0;
  v_value integer;
  v_coupon_id uuid;
  v_coupon_code text;
  v_suffix text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_attempt_id bigint;
  v_index integer;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  if exists (
    select 1 from public.spin_attempts
    where user_id = v_user_id and spin_date = v_today
  ) then
    return jsonb_build_object('ok', false, 'message', 'You have already used your spin today.');
  end if;
  select prizes into v_prizes from public.spin_prize_config where id = true;
  if jsonb_typeof(v_prizes) <> 'array' then raise exception 'Spin prizes are not configured.'; end if;
  for v_item in select value from jsonb_array_elements(v_prizes)
  loop
    v_total_weight := v_total_weight + greatest(coalesce((v_item->>'weight')::numeric, 0), 0);
  end loop;
  if v_total_weight <= 0 then raise exception 'Spin prizes have no positive weight.'; end if;
  v_target := random() * v_total_weight;
  for v_item in select value from jsonb_array_elements(v_prizes)
  loop
    v_running := v_running + greatest(coalesce((v_item->>'weight')::numeric, 0), 0);
    if v_target < v_running then
      v_prize := v_item;
      exit;
    end if;
  end loop;
  if v_prize is null then v_prize := v_prizes->(jsonb_array_length(v_prizes)-1); end if;
  insert into public.spin_attempts (user_id, spin_date, prize_code)
    values (v_user_id, v_today, v_prize->>'code')
    returning id into v_attempt_id;
  if v_prize->>'type' = 'tryAgain' then
    return jsonb_build_object('ok', true, 'prize', v_prize, 'prizes', v_prizes);
  end if;
  v_value := (v_prize->>'value')::integer;
  loop
    v_suffix := '';
    for v_index in 1..8 loop
      v_suffix := v_suffix || substr(v_alphabet, floor(random() * length(v_alphabet))::integer + 1, 1);
    end loop;
    v_coupon_code := 'RB' || v_value::text || '-' || v_suffix;
    v_coupon_id := null;
    insert into public.coupons (
      user_id, code, discount_percent, max_discount_amount, source, expires_at
    ) values (
      v_user_id, v_coupon_code, v_value,
      coalesce((v_prize->>'maxDiscountAmount')::numeric, 0),
      'spin', clock_timestamp() + interval '30 days'
    ) on conflict do nothing
    returning id into v_coupon_id;
    exit when v_coupon_id is not null;
  end loop;
  update public.spin_attempts set coupon_id = v_coupon_id where id = v_attempt_id;
  return jsonb_build_object(
    'ok', true, 'prize', v_prize, 'prizes', v_prizes,
    'coupon_code', v_coupon_code, 'discount_percent', v_value,
    'expires_at', (select expires_at from public.coupons where id = v_coupon_id)
  );
end;
$$;
revoke all on function public.spin_wheel() from public, anon;
grant execute on function public.spin_wheel() to authenticated;

create or replace function public.validate_coupon(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_coupon public.coupons%rowtype;
  v_failures integer;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select count(*) into v_failures from public.coupon_validation_attempts
    where user_id = v_user_id and attempted_at > clock_timestamp() - interval '1 hour';
  if v_failures >= 10 then
    return jsonb_build_object('ok', false, 'message', 'Too many failed attempts. Try again later.');
  end if;
  if v_code !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' then
    insert into public.coupon_validation_attempts (user_id) values (v_user_id);
    return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
  end if;
  select * into v_coupon from public.coupons
    where user_id = v_user_id and upper(btrim(code)) = v_code
    for update;
  if not found then
    insert into public.coupon_validation_attempts (user_id) values (v_user_id);
    return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
  end if;
  if v_coupon.expires_at <= clock_timestamp() or v_coupon.status = 'expired' then
    update public.coupons set status = 'expired'
      where id = v_coupon.id and status = 'unused';
    insert into public.coupon_validation_attempts (user_id) values (v_user_id);
    return jsonb_build_object('ok', false, 'message', 'Coupon expired');
  end if;
  if v_coupon.status <> 'unused' then
    insert into public.coupon_validation_attempts (user_id) values (v_user_id);
    return jsonb_build_object('ok', false, 'message', 'Coupon already used');
  end if;
  return jsonb_build_object(
    'ok', true, 'code', v_coupon.code,
    'discount_percent', v_coupon.discount_percent,
    'max_discount_amount', v_coupon.max_discount_amount,
    'expires_at', v_coupon.expires_at
  );
end;
$$;
revoke all on function public.validate_coupon(text) from public, anon;
grant execute on function public.validate_coupon(text) to authenticated;

create or replace function public.admin_list_coupons()
returns table(
  id uuid, user_id uuid, user_email text, code text, discount_percent integer,
  status text, source text, created_at timestamptz, expires_at timestamptz,
  used_at timestamptz, used_order_id bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select c.id, c.user_id, coalesce(u.email::text, ''), c.code,
      c.discount_percent, c.status, c.source, c.created_at, c.expires_at,
      c.used_at, c.used_order_id
    from public.coupons c
    left join auth.users u on u.id = c.user_id
    order by c.created_at desc;
end;
$$;
revoke all on function public.admin_list_coupons() from public, anon;
grant execute on function public.admin_list_coupons() to authenticated;

create or replace function public.prepare_product_payment(
  p_order_id bigint,
  p_product_id bigint,
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
  v_coupon_code text := upper(nullif(btrim(coalesce(p_coupon_code, '')), ''));
  v_timeout integer;
  v_grace integer;
  v_created_at timestamptz;
  v_discount numeric(12, 2) := 0;
  v_final numeric(12, 2);
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
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
    where id = p_product_id and in_stock = true for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Product is unavailable.'); end if;
  if p_order_id is not null then
    select * into v_order from public.orders
      where id = p_order_id and user_id = v_user_id and product_id = p_product_id
        and status = 'pending_payment' and utr is null and offer_claim_id is null
        and payment_expires_at > clock_timestamp()
      for update;
    if not found then
      return jsonb_build_object('ok', false, 'message', 'This payment order can no longer be changed.');
    end if;
  end if;
  if v_coupon_code is not null then
    if v_coupon_code !~ '^RB(100|[1-9][0-9]?)-[A-HJ-NP-Z2-9]{8}$' then
      return jsonb_build_object('ok', false, 'message', 'Invalid coupon');
    end if;
    select * into v_coupon from public.coupons
      where user_id = v_user_id and upper(btrim(code)) = v_coupon_code
      for update;
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
      v_product.price * v_coupon.discount_percent / 100,
      case when v_coupon.max_discount_amount > 0 then v_coupon.max_discount_amount else v_product.price end
    ), 2);
  end if;
  v_final := round(greatest(v_product.price - v_discount, 0), 2);
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
      user_id, product_id, product_name, product_type, price, status,
      payment_method, payment_status, coupon_code, discount_percent,
      original_price, created_at, payment_expires_at
    ) values (
      v_user_id, v_product.id, v_product.name, v_product.category, v_final,
      'pending_payment', p_payment_method, 'pending', v_coupon.code,
      coalesce(v_coupon.discount_percent, 0), v_product.price, v_created_at,
      v_created_at + make_interval(mins => v_timeout)
    ) returning * into v_order;
  else
    update public.orders set
      product_name = v_product.name, product_type = v_product.category,
      price = v_final, payment_method = p_payment_method,
      coupon_code = v_coupon.code, discount_percent = coalesce(v_coupon.discount_percent, 0),
      original_price = v_product.price
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
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at,
    'server_now', clock_timestamp(), 'timeout_minutes', v_timeout, 'grace_minutes', v_grace
  );
end;
$$;
revoke all on function public.prepare_product_payment(bigint, bigint, text, text)
  from public, anon;
grant execute on function public.prepare_product_payment(bigint, bigint, text, text)
  to authenticated;
revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, text, text)
  from public, anon, authenticated;
revoke all on function public.prepare_product_payment(bigint, bigint, numeric, numeric, numeric, numeric, text, text)
  from public, anon, authenticated;

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
      and payment_method in ('upi_qr', 'upi_app') and status = 'pending_payment'
      and utr is null and offer_claim_id is null
      and payment_expires_at > clock_timestamp();
  if not found then return jsonb_build_object('ok', false, 'message', 'No active payment order was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true),
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'original_price', v_order.original_price
  );
end;
$$;
revoke all on function public.get_my_pending_product_payment(bigint, bigint) from public, anon;
grant execute on function public.get_my_pending_product_payment(bigint, bigint) to authenticated;

create or replace function public.admin_reject_product_payment(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) > 4000 then
    return jsonb_build_object('ok', false, 'message', 'Rejection reason must be 4000 characters or fewer.');
  end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status <> 'pending_verification' or v_order.payment_status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'This payment is no longer awaiting verification.');
  end if;
  update public.orders set status = 'rejected', payment_status = 'rejected',
    reject_reason = nullif(v_reason, '') where id = p_order_id;
  update public.coupons set
    status = case when expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
    where used_order_id = p_order_id;
  if v_order.offer_claim_id is not null then
    insert into public.offer_audit_events(actor_id,action,offer_id,claim_id,order_id,details)
      values(auth.uid(),'offer_payment_rejected',v_order.offer_id,v_order.offer_claim_id,v_order.id,
        jsonb_build_object('reason',v_reason,'utr',v_order.utr));
  end if;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;
revoke all on function public.admin_reject_product_payment(bigint, text) from public, anon;
grant execute on function public.admin_reject_product_payment(bigint, text) to authenticated;

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
  update public.coupons c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
    from public.orders o
    where c.used_order_id = o.id and o.status = 'expired' and o.utr is null
      and o.payment_expires_at + make_interval(mins => v_grace) <= clock_timestamp();
  return v_expired;
end;
$$;
revoke all on function public.expire_pending_product_payments() from public, anon, authenticated;
commit;
