-- Apply first: software-pnr-plans-migration.sql, then guest-checkout-migration.sql.
begin;

alter table public.products
  add column if not exists plan_2_pnr_price numeric(12, 2),
  add column if not exists plan_2_pnr_mrp numeric(12, 2),
  add column if not exists plan_2_pnr_enabled boolean not null default true,
  add column if not exists plan_4_pnr_price numeric(12, 2),
  add column if not exists plan_4_pnr_mrp numeric(12, 2),
  add column if not exists plan_4_pnr_enabled boolean not null default true,
  add column if not exists plan_6_pnr_price numeric(12, 2),
  add column if not exists plan_6_pnr_mrp numeric(12, 2),
  add column if not exists plan_6_pnr_enabled boolean not null default true;

select count(*) as products_to_backfill
from public.products
where lower(category) = 'software'
  and (plan_2_pnr_price is null or plan_4_pnr_price is null or plan_6_pnr_price is null);

update public.products
set plan_2_pnr_price = coalesce(plan_2_pnr_price, selling_price, price),
    plan_4_pnr_price = coalesce(plan_4_pnr_price, selling_price, price),
    plan_6_pnr_price = coalesce(plan_6_pnr_price, selling_price, price),
    plan_2_pnr_mrp = coalesce(plan_2_pnr_mrp,
      case when original_price > coalesce(selling_price, price) then original_price end),
    plan_4_pnr_mrp = coalesce(plan_4_pnr_mrp,
      case when original_price > coalesce(selling_price, price) then original_price end),
    plan_6_pnr_mrp = coalesce(plan_6_pnr_mrp,
      case when original_price > coalesce(selling_price, price) then original_price end)
where lower(category) = 'software'
  and (plan_2_pnr_price is null or plan_4_pnr_price is null or plan_6_pnr_price is null);

alter table public.products drop constraint if exists products_plan_2_pnr_price_check;
alter table public.products add constraint products_plan_2_pnr_price_check
  check (plan_2_pnr_price is null or plan_2_pnr_price > 0);
alter table public.products drop constraint if exists products_plan_2_pnr_mrp_check;
alter table public.products add constraint products_plan_2_pnr_mrp_check
  check (plan_2_pnr_mrp is null or (plan_2_pnr_price is not null and plan_2_pnr_mrp > plan_2_pnr_price));
alter table public.products drop constraint if exists products_plan_4_pnr_price_check;
alter table public.products add constraint products_plan_4_pnr_price_check
  check (plan_4_pnr_price is null or plan_4_pnr_price > 0);
alter table public.products drop constraint if exists products_plan_4_pnr_mrp_check;
alter table public.products add constraint products_plan_4_pnr_mrp_check
  check (plan_4_pnr_mrp is null or (plan_4_pnr_price is not null and plan_4_pnr_mrp > plan_4_pnr_price));
alter table public.products drop constraint if exists products_plan_6_pnr_price_check;
alter table public.products add constraint products_plan_6_pnr_price_check
  check (plan_6_pnr_price is null or plan_6_pnr_price > 0);
alter table public.products drop constraint if exists products_plan_6_pnr_mrp_check;
alter table public.products add constraint products_plan_6_pnr_mrp_check
  check (plan_6_pnr_mrp is null or (plan_6_pnr_price is not null and plan_6_pnr_mrp > plan_6_pnr_price));

alter table public.orders add column if not exists software_plan_code text;
alter table public.orders add column if not exists software_plan_label text;
alter table public.orders add column if not exists software_plan_mrp numeric(12, 2);
alter table public.orders drop constraint if exists orders_software_plan_code_check;
alter table public.orders add constraint orders_software_plan_code_check
  check (software_plan_code is null or software_plan_code in ('2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days'));
alter table public.orders drop constraint if exists orders_software_plan_data_check;
alter table public.orders add constraint orders_software_plan_data_check
  check (
    (software_plan_code is null and software_plan_label is null and software_plan_mrp is null)
    or (software_plan_code is not null and software_plan_label is not null
      and (software_plan_mrp is null or software_plan_mrp > 0))
  );

create or replace function private.guard_software_plan_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expected_label text;
begin
  if lower(coalesce(new.product_type, '')) <> 'software'
     or new.payment_status is distinct from 'paid'
     or new.used_key_id is not null
     or new.rental_product_id is not null
     or new.offer_claim_id is not null
     or coalesce(new.is_offer_free, false)
     or coalesce(new.payment_method, '') = 'free' then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.software_plan_code is null then
      return new;
    end if;
  end if;

  if new.software_plan_code is null then
    raise exception 'Choose a Software PNR plan before completing this paid Software order.';
  end if;

  v_expected_label := case new.software_plan_code
    when '2_pnr_30_days' then '2 PNR 30 DAYS'
    when '4_pnr_30_days' then '4 PNR 30 DAYS'
    when '6_pnr_30_days' then '6 PNR 30 DAYS'
  end;
  if lower(coalesce(new.product_type, '')) <> 'software'
     or new.used_key_id is not null or new.rental_product_id is not null
     or new.software_plan_label is distinct from v_expected_label then
    raise exception 'The selected Software PNR plan is invalid.';
  end if;
  if tg_op = 'UPDATE' and old.software_plan_code is not null
     and (new.software_plan_code is distinct from old.software_plan_code
       or new.software_plan_label is distinct from old.software_plan_label
       or new.software_plan_mrp is distinct from old.software_plan_mrp) then
    raise exception 'A Software PNR plan cannot be changed after checkout.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_software_plan_order on public.orders;
create trigger guard_software_plan_order
  before insert or update on public.orders
  for each row
  when (
    lower(coalesce(new.product_type, '')) = 'software'
    and new.payment_status = 'paid'
    and new.used_key_id is null
    and new.rental_product_id is null
    and new.offer_claim_id is null
    and not coalesce(new.is_offer_free, false)
    and coalesce(new.payment_method, '') <> 'free'
  )
  execute function private.guard_software_plan_order();
revoke all on function private.guard_software_plan_order() from public, anon, authenticated;

create or replace function public.prepare_software_plan_payment(
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
  v_label text;
  v_plan_price numeric(12, 2);
  v_plan_mrp numeric(12, 2);
  v_coupon_code text := upper(nullif(btrim(coalesce(p_coupon_code, '')), ''));
  v_timeout integer;
  v_grace integer;
  v_discount numeric(12, 2) := 0;
  v_final numeric(12, 2);
  v_created_at timestamptz;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if v_code not in ('2_pnr_30_days', '4_pnr_30_days', '6_pnr_30_days') then
    return jsonb_build_object('ok', false, 'message', 'Choose a valid 30-day Software PNR plan.');
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
    where id = p_product_id and lower(category) = 'software' and in_stock = true
    for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'Software product is unavailable.'); end if;

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
      return jsonb_build_object('ok', false, 'message', 'This order belongs to a different PNR plan. Start a new checkout.');
    end if;
    if v_order.software_plan_code = v_code then
      v_plan_price := coalesce(v_order.original_price, v_order.price);
      v_plan_mrp := v_order.software_plan_mrp;
    end if;
  end if;

  v_label := case v_code
    when '2_pnr_30_days' then '2 PNR 30 DAYS'
    when '4_pnr_30_days' then '4 PNR 30 DAYS'
    when '6_pnr_30_days' then '6 PNR 30 DAYS'
  end;
  if v_plan_price is null then
    if v_code = '2_pnr_30_days' then
      if not v_product.plan_2_pnr_enabled then
        return jsonb_build_object('ok', false, 'message', 'This PNR plan is not currently available.');
      end if;
      v_plan_price := v_product.plan_2_pnr_price;
      v_plan_mrp := v_product.plan_2_pnr_mrp;
    elsif v_code = '4_pnr_30_days' then
      if not v_product.plan_4_pnr_enabled then
        return jsonb_build_object('ok', false, 'message', 'This PNR plan is not currently available.');
      end if;
      v_plan_price := v_product.plan_4_pnr_price;
      v_plan_mrp := v_product.plan_4_pnr_mrp;
    else
      if not v_product.plan_6_pnr_enabled then
        return jsonb_build_object('ok', false, 'message', 'This PNR plan is not currently available.');
      end if;
      v_plan_price := v_product.plan_6_pnr_price;
      v_plan_mrp := v_product.plan_6_pnr_mrp;
    end if;
  end if;
  if v_plan_price is null or v_plan_price <= 0 then
    return jsonb_build_object('ok', false, 'message', 'The selected PNR plan has no valid price.');
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
      v_created_at + make_interval(mins => v_timeout), v_code, v_label, v_plan_mrp
    ) returning * into v_order;
  else
    update public.orders set
      product_name = v_product.name, product_type = v_product.category,
      price = v_final, amount = v_final, payment_method = p_payment_method,
      coupon_code = v_coupon.code, discount_percent = coalesce(v_coupon.discount_percent, 0),
      original_price = v_plan_price,
      software_plan_code = v_code, software_plan_label = v_label, software_plan_mrp = v_plan_mrp
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
revoke all on function public.prepare_software_plan_payment(bigint, bigint, text, text, text) from public, anon;
grant execute on function public.prepare_software_plan_payment(bigint, bigint, text, text, text) to authenticated;

create or replace function public.purchase_software_plan(p_product_id bigint, p_plan_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_product public.products%rowtype;
  v_plan_price numeric(12, 2);
  v_plan_mrp numeric(12, 2);
  v_plan_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_plan_label text;
  v_balance numeric(12, 2);
  v_download_url text;
  v_order public.orders%rowtype;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if not coalesce((select enable_wallet_payments from public.settings where id = true), false) then
    return jsonb_build_object('ok', false, 'reason', 'payment_disabled', 'message', 'Wallet payments are currently unavailable.');
  end if;
  select * into v_product from public.products
    where id = p_product_id and lower(category) = 'software' and in_stock = true for share;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unavailable', 'message', 'Software product is unavailable.'); end if;
  if v_plan_code = '2_pnr_30_days' and v_product.plan_2_pnr_enabled then
    v_plan_price := v_product.plan_2_pnr_price; v_plan_mrp := v_product.plan_2_pnr_mrp; v_plan_label := '2 PNR 30 DAYS';
  elsif v_plan_code = '4_pnr_30_days' and v_product.plan_4_pnr_enabled then
    v_plan_price := v_product.plan_4_pnr_price; v_plan_mrp := v_product.plan_4_pnr_mrp; v_plan_label := '4 PNR 30 DAYS';
  elsif v_plan_code = '6_pnr_30_days' and v_product.plan_6_pnr_enabled then
    v_plan_price := v_product.plan_6_pnr_price; v_plan_mrp := v_product.plan_6_pnr_mrp; v_plan_label := '6 PNR 30 DAYS';
  else
    return jsonb_build_object('ok', false, 'reason', 'plan_unavailable', 'message', 'Choose an available Software PNR plan.');
  end if;
  if v_plan_price is null or v_plan_price <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'plan_unavailable', 'message', 'The selected PNR plan has no valid price.');
  end if;
  insert into public.wallets (user_id) values (v_user_id) on conflict (user_id) do nothing;
  select balance into v_balance from public.wallets where user_id = v_user_id for update;
  if v_balance < v_plan_price then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_balance', 'balance', v_balance);
  end if;
  select download_url into v_download_url
    from public.product_download_links where product_id = v_product.id;
  update public.wallets set balance = balance - v_plan_price, updated_at = now()
    where user_id = v_user_id returning balance into v_balance;
  insert into public.orders (
    user_id, product_id, product_name, product_type, price, amount, original_price,
    status, payment_method, payment_status, delivery_link, delivered_at,
    software_plan_code, software_plan_label, software_plan_mrp
  ) values (
    v_user_id, v_product.id, v_product.name, v_product.category, v_plan_price, v_plan_price, v_plan_price,
    case when v_download_url is null then 'pending' else 'delivered' end,
    'wallet', 'paid', v_download_url, case when v_download_url is null then null else now() end,
    v_plan_code, v_plan_label, v_plan_mrp
  ) returning * into v_order;
  insert into public.wallet_transactions (user_id, type, amount, note, order_id)
    values (v_user_id, 'purchase', v_plan_price, 'Purchase: ' || v_product.name || ' · ' || v_plan_label, v_order.id);
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_name', v_order.product_name,
    'software_plan_label', v_order.software_plan_label, 'price', v_order.price,
    'balance', v_balance, 'created_at', v_order.created_at,
    'download_ready', v_order.status = 'delivered'
  );
end;
$$;
revoke all on function public.purchase_software_plan(bigint, text) from public, anon;
grant execute on function public.purchase_software_plan(bigint, text) to authenticated;

create or replace function public.get_my_pending_product_payment(p_order_id bigint, p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = auth.uid() and product_id = p_product_id
      and payment_method in ('upi_qr', 'upi_app') and status in ('unpaid', 'pending_payment', 'expired')
      and utr is null and offer_claim_id is null;
  if not found then return jsonb_build_object('ok', false, 'message', 'No active payment order was found.'); end if;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order.id, 'product_id', v_order.product_id,
    'price', v_order.price, 'payment_method', v_order.payment_method, 'status', v_order.status,
    'payment_expires_at', v_order.payment_expires_at, 'server_now', clock_timestamp(),
    'grace_minutes', (select payment_grace_minutes from public.payment_timer_config where id = true),
    'coupon_code', v_order.coupon_code, 'discount_percent', v_order.discount_percent,
    'original_price', v_order.original_price,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp
  );
end;
$$;
revoke all on function public.get_my_pending_product_payment(bigint, bigint) from public, anon;
grant execute on function public.get_my_pending_product_payment(bigint, bigint) to authenticated;

drop function if exists public.admin_list_orders();
create function public.admin_list_orders()
returns table(
  id bigint, user_id uuid, user_email text, product_name text, product_type text,
  price numeric, status text, created_at timestamptz, delivery_text text,
  delivery_link text, delivery_note text, delivered_at timestamptz,
  payment_method text, payment_status text, utr text, coupon_code text,
  discount_percent numeric, original_price numeric, reject_reason text,
  quantity integer, offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean,
  software_plan_label text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select o.id, o.user_id, coalesce(u.email::text, ''), o.product_name,
      coalesce(o.product_type, p.category, ''), o.price, o.status, o.created_at,
      o.delivery_text, o.delivery_link, o.delivery_note, o.delivered_at,
      o.payment_method, o.payment_status, o.utr, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at,
      o.late_payment, o.software_plan_label
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    left join public.products as p on p.id = o.product_id
    where o.status not in ('unpaid', 'pending_payment', 'new')
    order by case when o.status in ('new', 'pending_verification') then 0 else 1 end,
      o.created_at desc;
end;
$$;
revoke all on function public.admin_list_orders() from public, anon;
grant execute on function public.admin_list_orders() to authenticated;

drop function if exists public.admin_list_order_requests(text, text, integer, integer);
create function public.admin_list_order_requests(
  p_status text default 'all', p_search text default '', p_page integer default 1, p_page_size integer default 20
)
returns table(
  id bigint, user_id uuid, customer text, product_id bigint, product_name text,
  product_type text, used_key_id bigint, used_key_remaining_days integer, amount numeric, utr_number text,
  payment_submitted_at timestamptz, created_at timestamptz, status text, total_count bigint,
  software_plan_label text
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_search text := left(btrim(coalesce(p_search, '')), 120);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('all', 'new', 'completed', 'rejected') then
    raise exception 'Invalid order request status.';
  end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then
    raise exception 'Invalid pagination parameters.';
  end if;
  return query
    with filtered as (
      select o.id, o.user_id, coalesce(u.email::text, 'Customer') customer,
        o.product_id,
        case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end product_name,
        case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end product_type,
        o.used_key_id,
        case when o.used_key_id is not null
          then greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)
          end as used_key_remaining_days,
        o.amount, o.utr_number, o.payment_submitted_at, o.created_at, o.status,
        o.software_plan_label
      from public.orders as o
      left join auth.users as u on u.id = o.user_id
      left join public.products as p on p.id = o.product_id
      where o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
        and coalesce(o.product_type, p.category, '') in ('software', 'vps')
        and (p_status = 'all' or o.status = p_status)
        and (v_search = '' or o.id::text ilike '%' || v_search || '%'
          or coalesce(u.email::text, '') ilike '%' || v_search || '%'
          or coalesce(o.utr_number, '') ilike '%' || v_search || '%'
          or coalesce(o.software_plan_label, '') ilike '%' || v_search || '%')
    )
    select f.id, f.user_id, f.customer, f.product_id, f.product_name, f.product_type,
      f.used_key_id, f.used_key_remaining_days, f.amount, f.utr_number,
      f.payment_submitted_at, f.created_at, f.status, count(*) over(), f.software_plan_label
    from filtered as f
    order by case f.status when 'new' then 0 when 'completed' then 1 else 2 end,
      f.payment_submitted_at desc nulls last, f.created_at desc
    offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;

drop function if exists public.my_orders();
create function public.my_orders()
returns table(
  id bigint, product_id bigint, product_name text, product_type text, price numeric, status text,
  created_at timestamptz, delivery_text text, delivery_link text, delivery_note text,
  delivered_at timestamptz, payment_method text, payment_status text, coupon_code text,
  discount_percent numeric, original_price numeric, reject_reason text, quantity integer,
  offer_id uuid, offer_claim_id uuid, is_offer_free boolean, expires_at timestamptz,
  payment_expires_at timestamptz, utr_submitted_at timestamptz, late_payment boolean,
  amount numeric, utr_number text, payment_submitted_at timestamptz, completed_at timestamptz,
  software_name text, license_key text, download_link text, vps_ip text, vps_port integer,
  vps_username text, vps_password text, vps_storage_gb integer,
  used_key_id bigint, software_plan_code text, software_plan_label text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_key text;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  return query
    select o.id, o.product_id,
      case when o.used_key_id is not null then coalesce(p.name, o.product_name) else o.product_name end,
      case when o.used_key_id is not null then 'used_key' else coalesce(o.product_type, p.category, '') end,
      o.price, o.status, o.created_at,
      case when o.status in ('delivered', 'completed') then o.delivery_text end,
      case when o.status in ('delivered', 'completed') and o.used_key_id is not null then dl.download_url
        when o.status in ('delivered', 'completed') then coalesce(d.download_link, o.delivery_link) end,
      case when o.status in ('delivered', 'completed') and o.used_key_id is not null
        then 'Remaining validity: ' || greatest(o.used_key_expires_on - (timezone('Asia/Kolkata', clock_timestamp()))::date, 0)::text
          || ' days · Expires: ' || to_char(o.used_key_expires_on, 'YYYY-MM-DD')
        when o.status in ('delivered', 'completed') then o.delivery_note end,
      o.delivered_at, o.payment_method, o.payment_status, o.coupon_code, o.discount_percent,
      o.original_price, o.reject_reason, o.quantity, o.offer_id, o.offer_claim_id,
      o.is_offer_free, o.expires_at, o.payment_expires_at, o.utr_submitted_at, o.late_payment,
      o.amount, o.utr_number, o.payment_submitted_at, o.completed_at,
      case when o.status = 'completed' and o.used_key_id is not null then p.name
        when o.status = 'completed' then d.software_name end,
      case when o.status = 'completed' and d.license_key_encrypted is not null
        then extensions.pgp_sym_decrypt(d.license_key_encrypted, v_key) end,
      case when o.status = 'completed' and o.used_key_id is not null then dl.download_url
        when o.status = 'completed' then d.download_link end,
      case when o.status = 'completed' then d.vps_ip end,
      case when o.status = 'completed' then d.vps_port end,
      case when o.status = 'completed' then d.vps_username end,
      case when o.status = 'completed' and d.vps_password_encrypted is not null
        then extensions.pgp_sym_decrypt(d.vps_password_encrypted, v_key) end,
      case when o.status = 'completed' then d.vps_storage_gb end,
      o.used_key_id,
      o.software_plan_code, o.software_plan_label
    from public.orders o
    left join public.products p on p.id = o.product_id
    left join public.order_delivery d on d.order_id = o.id
    left join public.product_download_links dl on dl.product_id = o.product_id
    where o.user_id = v_user_id
    order by o.created_at desc limit 50;
end;
$$;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.my_orders() to authenticated;

create or replace function public.admin_get_order_request(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_used_key private.used_key_inventory%rowtype;
  v_key text;
  v_customer text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id
    and o.status in ('new', 'completed', 'rejected') and o.utr_number is not null
    and o.product_type in ('software', 'vps');
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  v_customer := 'Customer';
  if v_order.user_id is not null then
    select coalesce(u.email::text, v_customer) into v_customer
      from auth.users as u where u.id = v_order.user_id;
  end if;
  select d.* into v_delivery from public.order_delivery as d where d.order_id = p_order_id;
  select s.encryption_key into v_key from private.order_delivery_secrets as s where s.id = true;
  if v_order.used_key_id is not null then
    select k.* into v_used_key from private.used_key_inventory as k where k.id = v_order.used_key_id;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'user_id', v_order.user_id, 'customer', v_customer,
    'product_id', v_order.product_id,
    'product_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_order.product_name)
      else v_order.product_name end,
    'product_type', case when v_order.used_key_id is not null then 'used_key' else coalesce(v_order.product_type, '') end,
    'software_plan_code', v_order.software_plan_code,
    'software_plan_label', v_order.software_plan_label,
    'software_plan_mrp', v_order.software_plan_mrp,
    'used_key_id', v_order.used_key_id, 'used_key_expires_on', v_order.used_key_expires_on,
    'amount', v_order.amount, 'utr_number', v_order.utr_number,
    'payment_submitted_at', v_order.payment_submitted_at, 'created_at', v_order.created_at,
    'completed_at', v_order.completed_at, 'status', v_order.status, 'reject_reason', v_order.reject_reason,
    'software_name', case when v_order.used_key_id is not null
      then coalesce((select p.name from public.products as p where p.id = v_order.product_id), v_used_key.software_name)
      else coalesce(v_delivery.software_name, v_order.product_name) end,
    'license_key', case when v_order.used_key_id is not null
      then extensions.pgp_sym_decrypt(v_used_key.license_key_encrypted, v_key)
      when v_delivery.license_key_encrypted is not null
      then extensions.pgp_sym_decrypt(v_delivery.license_key_encrypted, v_key) else '' end,
    'download_link', case when v_order.used_key_id is not null
      then v_used_key.download_link else coalesce(v_delivery.download_link, '') end,
    'vps_ip', coalesce(v_delivery.vps_ip, ''), 'vps_port', v_delivery.vps_port,
    'vps_username', coalesce(v_delivery.vps_username, ''),
    'vps_password', case when v_delivery.vps_password_encrypted is null then ''
      else extensions.pgp_sym_decrypt(v_delivery.vps_password_encrypted, v_key) end,
    'vps_storage_gb', v_delivery.vps_storage_gb
  );
end;
$$;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
grant execute on function public.admin_get_order_request(bigint) to authenticated;

commit;
