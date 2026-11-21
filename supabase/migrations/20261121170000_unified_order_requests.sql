begin;

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (
  status in ('unpaid', 'pending_payment', 'pending_verification', 'utr_submitted',
    'new', 'pending', 'completed', 'delivered', 'rejected', 'refunded', 'expired')
);

alter table public.orders
  add column if not exists utr_number text,
  add column if not exists payment_submitted_at timestamptz,
  add column if not exists amount numeric(12, 2);

update public.orders
set utr_number = coalesce(utr_number, utr),
    payment_submitted_at = coalesce(payment_submitted_at, utr_submitted_at),
    amount = round(coalesce(amount, price), 2),
    price = round(coalesce(price, amount), 2)
where coalesce(utr_number, utr) is not null;

-- Keep one canonical status for every newly submitted UTR, including older endpoints.
update public.orders
set status = 'utr_submitted'
where coalesce(utr_number, utr) is not null
  and status in ('new', 'pending_verification', 'pending');

create or replace function public.normalize_submitted_order_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(new.utr_number, new.utr) is not null
     and new.status in ('new', 'pending_verification', 'pending') then
    new.status := 'utr_submitted';
  end if;
  return new;
end;
$$;

drop trigger if exists normalize_submitted_order_status_trigger on public.orders;
create trigger normalize_submitted_order_status_trigger
before insert or update of utr, utr_number, status on public.orders
for each row execute function public.normalize_submitted_order_status();

-- Recalculate coupon PNR orders from their stored plan/original amount.
update public.orders
set price = round(original_price * greatest(100 - coalesce(discount_percent, 0), 0) / 100, 2),
    amount = round(original_price * greatest(100 - coalesce(discount_percent, 0), 0) / 100, 2)
where coupon_code is not null
  and original_price is not null
  and original_price > 0
  and coalesce(discount_percent, 0) > 0
  and software_plan_code is not null;

drop function if exists public.admin_order_request_counts();
create or replace function public.admin_order_request_counts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new bigint;
  v_completed bigint;
  v_rejected bigint;
  v_all bigint;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;

  select
    count(*) filter (where status_norm = 'utr_submitted'),
    count(*) filter (where status_norm = 'completed'),
    count(*) filter (where status_norm = 'rejected'),
    count(*)
  into v_new, v_completed, v_rejected, v_all
  from (
    select case
      when o.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
      when o.status in ('completed', 'delivered') then 'completed'
      when o.status = 'rejected' then 'rejected'
    end status_norm
    from public.orders o
    where coalesce(o.utr_number, o.utr) is not null
      and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending', 'completed', 'delivered', 'rejected')
    union all
    select case
      when t.status = 'pending' then 'utr_submitted'
      when t.status = 'approved' then 'completed'
      else 'rejected'
    end
    from public.topup_requests t
    where btrim(coalesce(t.utr, '')) <> ''
  ) all_requests;

  return jsonb_build_object(
    'new', coalesce(v_new, 0),
    'completed', coalesce(v_completed, 0),
    'rejected', coalesce(v_rejected, 0),
    'all', coalesce(v_all, 0)
  );
end;
$$;

drop function if exists public.admin_list_order_requests(text, text, integer, integer);
create or replace function public.admin_list_order_requests(
  p_status text default 'all',
  p_search text default '',
  p_page integer default 1,
  p_page_size integer default 20
)
returns table(
  id bigint,
  user_id uuid,
  customer text,
  customer_email text,
  product_id bigint,
  product_name text,
  product_type text,
  type text,
  used_key_id bigint,
  used_key_remaining_days integer,
  amount numeric,
  utr_number text,
  payment_submitted_at timestamptz,
  payment_time timestamptz,
  created_at timestamptz,
  status text,
  total_count bigint,
  software_plan_label text,
  count_new bigint,
  count_completed bigint,
  count_rejected bigint,
  count_all bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_search text := left(btrim(coalesce(p_search, '')), 120);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('all', 'new', 'utr_submitted', 'completed', 'rejected') then
    raise exception 'Invalid order request status.';
  end if;
  if p_page < 1 or p_page_size < 1 or p_page_size > 50 then
    raise exception 'Invalid pagination parameters.';
  end if;

  return query
  with base as (
    select
      o.id,
      o.user_id,
      coalesce(u.email::text, o.guest_email, 'Customer') customer,
      coalesce(u.email::text, o.guest_email, '') customer_email,
      o.product_id,
      coalesce(o.product_name, p.name, 'Software') product_name,
      case when o.used_key_id is not null then 'used_key'
           else coalesce(o.product_type, p.category, 'software') end product_type,
      'software'::text type,
      o.used_key_id,
      o.used_key_remaining_days,
      round(coalesce(o.amount, o.price), 2) amount,
      coalesce(o.utr_number, o.utr) utr_number,
      coalesce(o.payment_submitted_at, o.utr_submitted_at, o.created_at) payment_submitted_at,
      coalesce(o.payment_submitted_at, o.utr_submitted_at, o.created_at) payment_time,
      o.created_at,
      case
        when o.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
        when o.status in ('completed', 'delivered') then 'completed'
        when o.status = 'rejected' then 'rejected'
        else o.status
      end status,
      o.software_plan_label
    from public.orders o
    left join auth.users u on u.id = o.user_id
    left join public.products p on p.id = o.product_id
    where coalesce(o.utr_number, o.utr) is not null
      and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending', 'completed', 'delivered', 'rejected')
    union all
    select
      t.id,
      t.user_id,
      coalesce(u.email::text, 'Customer') customer,
      coalesce(u.email::text, '') customer_email,
      null::bigint product_id,
      'Wallet Top-up'::text product_name,
      'topup'::text product_type,
      'topup'::text type,
      null::bigint used_key_id,
      null::integer used_key_remaining_days,
      round(t.amount, 2) amount,
      t.utr utr_number,
      t.created_at payment_submitted_at,
      t.created_at payment_time,
      t.created_at created_at,
      case when t.status = 'pending' then 'utr_submitted'
           when t.status = 'approved' then 'completed'
           else 'rejected' end status,
      null::text software_plan_label
    from public.topup_requests t
    join auth.users u on u.id = t.user_id
    where btrim(coalesce(t.utr, '')) <> ''
  ),
  counted as (
    select
      count(*) filter (where status = 'utr_submitted') count_new,
      count(*) filter (where status = 'completed') count_completed,
      count(*) filter (where status = 'rejected') count_rejected,
      count(*) count_all
    from base
  ),
  filtered as (
    select b.*
    from base b
    where (p_status = 'all'
           or (p_status = 'new' and b.status = 'utr_submitted')
           or (p_status = 'utr_submitted' and b.status = 'utr_submitted')
           or b.status = p_status)
      and (v_search = ''
           or b.id::text ilike '%' || v_search || '%'
           or coalesce(b.customer_email, '') ilike '%' || v_search || '%'
           or coalesce(b.utr_number, '') ilike '%' || v_search || '%')
  )
  select f.id, f.user_id, f.customer, f.customer_email, f.product_id, f.product_name,
    f.product_type, f.type, f.used_key_id, f.used_key_remaining_days, f.amount,
    f.utr_number, f.payment_submitted_at, f.payment_time, f.created_at, f.status,
    count(*) over() total_count, f.software_plan_label,
    c.count_new, c.count_completed, c.count_rejected, c.count_all
  from filtered f cross join counted c
  order by f.payment_time desc nulls last, f.id desc
  offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;

drop function if exists public.admin_get_request(text, bigint);
create or replace function public.admin_get_request(p_type text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_topup public.topup_requests%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_type = 'topup' then
    select * into v_topup from public.topup_requests where id = p_id;
    if not found then return jsonb_build_object('ok', false, 'message', 'Top-up request not found.'); end if;
    return jsonb_build_object(
      'ok', true, 'id', v_topup.id, 'type', 'topup',
      'customer', coalesce((select email::text from auth.users where id = v_topup.user_id), 'Customer'),
      'product_name', 'Wallet Top-up', 'product_type', 'topup',
      'amount', round(v_topup.amount, 2), 'utr_number', v_topup.utr,
      'payment_time', v_topup.created_at,
      'status', case when v_topup.status = 'pending' then 'utr_submitted'
                     when v_topup.status = 'approved' then 'completed'
                     else 'rejected' end
    );
  end if;
  select * into v_order from public.orders where id = p_id
    and coalesce(utr_number, utr) is not null;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'type', 'software',
    'customer', coalesce((select email::text from auth.users where id = v_order.user_id), v_order.guest_email, 'Customer'),
    'product_name', v_order.product_name, 'product_type', v_order.product_type,
    'amount', round(coalesce(v_order.amount, v_order.price), 2),
    'utr_number', coalesce(v_order.utr_number, v_order.utr),
    'payment_time', coalesce(v_order.payment_submitted_at, v_order.utr_submitted_at, v_order.created_at),
    'status', case when v_order.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
                   when v_order.status in ('completed', 'delivered') then 'completed'
                   else v_order.status end,
    'software_plan_label', v_order.software_plan_label,
    'reject_reason', v_order.reject_reason
  );
end;
$$;

create or replace function public.admin_review_request(
  p_type text,
  p_id bigint,
  p_action text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_type = 'topup' then
    select public.admin_review_topup(p_id, p_action = 'approve') into v_result;
    return v_result;
  end if;
  if p_type = 'software' then
    if p_action = 'approve' then
      select public.admin_complete_order(p_id, '{}'::jsonb) into v_result;
    elsif p_action = 'reject' then
      update public.orders
      set status = 'rejected', payment_status = 'rejected',
          reject_reason = nullif(left(btrim(coalesce(p_reason, '')), 1000), '')
      where id = p_id
        and coalesce(utr_number, utr) is not null
        and status in ('utr_submitted', 'pending_verification', 'new', 'pending');
      if not found then
        return jsonb_build_object('ok', false, 'message', 'This order is no longer awaiting review.');
      end if;
      v_result := jsonb_build_object('ok', true, 'status', 'rejected');
    else
      return jsonb_build_object('ok', false, 'message', 'Invalid review action.');
    end if;
    return v_result;
  end if;
  return jsonb_build_object('ok', false, 'message', 'Invalid request type.');
end;
$$;

create or replace function public.admin_complete_order(p_order_id bigint, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select * into v_order
  from public.orders
  where id = p_order_id
    and coalesce(utr_number, utr) is not null
    and status in ('utr_submitted', 'pending_verification', 'new')
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Only submitted order requests can be completed.');
  end if;

  select * into v_delivery from public.order_delivery where order_id = p_order_id;
  select encryption_key into v_key from private.order_delivery_secrets where id = true;
  if v_order.product_type = 'software' then
    if p_details is not null and jsonb_typeof(p_details) = 'object'
       and coalesce(p_details ->> 'software_name', '') <> '' then
      insert into public.order_delivery (
        order_id, software_name, license_key_encrypted, download_link
      ) values (
        p_order_id,
        nullif(trim(p_details ->> 'software_name'), ''),
        case when btrim(coalesce(p_details ->> 'license_key', '')) = '' then null
             else extensions.pgp_sym_encrypt(p_details ->> 'license_key', v_key) end,
        nullif(trim(p_details ->> 'download_link'), '')
      )
      on conflict (order_id) do update set
        software_name = excluded.software_name,
        license_key_encrypted = excluded.license_key_encrypted,
        download_link = excluded.download_link;
      select * into v_delivery from public.order_delivery where order_id = p_order_id;
    end if;
  end if;

  update public.orders
  set status = 'completed',
      payment_status = 'paid',
      completed_at = clock_timestamp(),
      delivered_at = clock_timestamp()
  where id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'completed');
end;
$$;

drop function if exists public.admin_reject_order_request(bigint, text);
create or replace function public.admin_reject_order_request(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  update public.orders
  set status = 'rejected',
      payment_status = 'rejected',
      reject_reason = nullif(left(btrim(coalesce(p_reason, '')), 1000), '')
  where id = p_order_id
    and coalesce(utr_number, utr) is not null
    and status in ('utr_submitted', 'pending_verification', 'new');
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This order is no longer awaiting review.');
  end if;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_request(text, bigint) from public, anon;
revoke all on function public.admin_review_request(text, bigint, text, text) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_reject_order_request(bigint, text) from public, anon;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_request(text, bigint) to authenticated;
grant execute on function public.admin_review_request(text, bigint, text, text) to authenticated;
grant execute on function public.admin_complete_order(bigint, jsonb) to authenticated;
grant execute on function public.admin_reject_order_request(bigint, text) to authenticated;

commit;
