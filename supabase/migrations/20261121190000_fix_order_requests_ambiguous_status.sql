begin;

-- Normalize orders delivered by older flows before they are listed as requests.
update public.orders as o
set status = 'completed'
where o.status = 'delivered'
   or o.delivered_at is not null
   or nullif(btrim(coalesce(o.delivery_text, '')), '') is not null
   or nullif(btrim(coalesce(o.delivery_link, '')), '') is not null
   or nullif(btrim(coalesce(o.delivery_note, '')), '') is not null
   or exists (
     select 1
     from public.order_delivery as d
     where d.order_id = o.id
       and (
         nullif(btrim(coalesce(d.software_name, '')), '') is not null
         or d.license_key_encrypted is not null
         or nullif(btrim(coalesce(d.download_link, '')), '') is not null
         or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
         or d.vps_port is not null
         or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
         or d.vps_password_encrypted is not null
         or d.vps_storage_gb is not null
       )
   );

create or replace function public.admin_order_request_counts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_new bigint;
  v_completed bigint;
  v_rejected bigint;
  v_all bigint;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;

  with requests as (
    select case
      when o.status in ('completed', 'delivered')
        or o.delivered_at is not null
        or nullif(btrim(coalesce(o.delivery_text, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_link, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_note, '')), '') is not null
        or exists (
          select 1
          from public.order_delivery as d
          where d.order_id = o.id
            and (
              nullif(btrim(coalesce(d.software_name, '')), '') is not null
              or d.license_key_encrypted is not null
              or nullif(btrim(coalesce(d.download_link, '')), '') is not null
              or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
              or d.vps_port is not null
              or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
              or d.vps_password_encrypted is not null
              or d.vps_storage_gb is not null
            )
        ) then 'completed'
      when o.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
      when o.status = 'rejected' then 'rejected'
    end as request_status
    from public.orders as o
    where coalesce(o.utr_number, o.utr) is not null
      and (
        o.status in ('utr_submitted', 'pending_verification', 'new', 'pending', 'completed', 'delivered', 'rejected')
        or o.delivered_at is not null
        or nullif(btrim(coalesce(o.delivery_text, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_link, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_note, '')), '') is not null
        or exists (
          select 1
          from public.order_delivery as d
          where d.order_id = o.id
            and (
              nullif(btrim(coalesce(d.software_name, '')), '') is not null
              or d.license_key_encrypted is not null
              or nullif(btrim(coalesce(d.download_link, '')), '') is not null
              or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
              or d.vps_port is not null
              or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
              or d.vps_password_encrypted is not null
              or d.vps_storage_gb is not null
            )
        )
      )
    union all
    select case
      when t.status = 'pending' then 'utr_submitted'
      when t.status = 'approved' then 'completed'
      else 'rejected'
    end as request_status
    from public.topup_requests as t
    where btrim(coalesce(t.utr, '')) <> ''
  )
  select
    count(*) filter (where r.request_status = 'utr_submitted'),
    count(*) filter (where r.request_status = 'completed'),
    count(*) filter (where r.request_status = 'rejected'),
    count(*)
  into v_new, v_completed, v_rejected, v_all
  from requests as r;

  return jsonb_build_object(
    'new', coalesce(v_new, 0),
    'completed', coalesce(v_completed, 0),
    'rejected', coalesce(v_rejected, 0),
    'all', coalesce(v_all, 0)
  );
end;
$$;

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
#variable_conflict use_column
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
      o.id as id,
      o.user_id as user_id,
      coalesce(u.email::text, o.guest_email, 'Customer') as customer,
      coalesce(u.email::text, o.guest_email, '') as customer_email,
      o.product_id as product_id,
      coalesce(o.product_name, p.name, 'Software') as product_name,
      case when o.used_key_id is not null then 'used_key'
           else coalesce(o.product_type, p.category, 'software') end as product_type,
      'software'::text as type,
      o.used_key_id as used_key_id,
      o.used_key_remaining_days as used_key_remaining_days,
      round(coalesce(o.amount, o.price), 2) as amount,
      coalesce(o.utr_number, o.utr) as utr_number,
      coalesce(o.payment_submitted_at, o.utr_submitted_at, o.created_at) as payment_submitted_at,
      coalesce(o.payment_submitted_at, o.utr_submitted_at, o.created_at) as payment_time,
      o.created_at as created_at,
      case
        when o.status in ('completed', 'delivered')
          or o.delivered_at is not null
          or nullif(btrim(coalesce(o.delivery_text, '')), '') is not null
          or nullif(btrim(coalesce(o.delivery_link, '')), '') is not null
          or nullif(btrim(coalesce(o.delivery_note, '')), '') is not null
          or exists (
            select 1
            from public.order_delivery as d
            where d.order_id = o.id
              and (
                nullif(btrim(coalesce(d.software_name, '')), '') is not null
                or d.license_key_encrypted is not null
                or nullif(btrim(coalesce(d.download_link, '')), '') is not null
                or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
                or d.vps_port is not null
                or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
                or d.vps_password_encrypted is not null
                or d.vps_storage_gb is not null
              )
          ) then 'completed'
        when o.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
        when o.status = 'rejected' then 'rejected'
        else o.status
      end as status,
      o.software_plan_label as software_plan_label
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    left join public.products as p on p.id = o.product_id
    where coalesce(o.utr_number, o.utr) is not null
      and (
        o.status in ('utr_submitted', 'pending_verification', 'new', 'pending', 'completed', 'delivered', 'rejected')
        or o.delivered_at is not null
        or nullif(btrim(coalesce(o.delivery_text, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_link, '')), '') is not null
        or nullif(btrim(coalesce(o.delivery_note, '')), '') is not null
        or exists (
          select 1
          from public.order_delivery as d
          where d.order_id = o.id
            and (
              nullif(btrim(coalesce(d.software_name, '')), '') is not null
              or d.license_key_encrypted is not null
              or nullif(btrim(coalesce(d.download_link, '')), '') is not null
              or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
              or d.vps_port is not null
              or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
              or d.vps_password_encrypted is not null
              or d.vps_storage_gb is not null
            )
        )
      )
    union all
    select
      t.id as id,
      t.user_id as user_id,
      coalesce(u.email::text, 'Customer') as customer,
      coalesce(u.email::text, '') as customer_email,
      null::bigint as product_id,
      'Wallet Top-up'::text as product_name,
      'topup'::text as product_type,
      'topup'::text as type,
      null::bigint as used_key_id,
      null::integer as used_key_remaining_days,
      round(t.amount, 2) as amount,
      t.utr as utr_number,
      t.created_at as payment_submitted_at,
      t.created_at as payment_time,
      t.created_at as created_at,
      case when t.status = 'pending' then 'utr_submitted'
           when t.status = 'approved' then 'completed'
           else 'rejected' end as status,
      null::text as software_plan_label
    from public.topup_requests as t
    left join auth.users as u on u.id = t.user_id
    where btrim(coalesce(t.utr, '')) <> ''
  ),
  counted as (
    select
      count(*) filter (where b.status = 'utr_submitted') as count_new,
      count(*) filter (where b.status = 'completed') as count_completed,
      count(*) filter (where b.status = 'rejected') as count_rejected,
      count(*) as count_all
    from base as b
  ),
  filtered as (
    select b.*
    from base as b
    where (p_status = 'all'
           or (p_status in ('new', 'utr_submitted') and b.status = 'utr_submitted')
           or b.status = p_status)
      and (v_search = ''
           or b.id::text ilike '%' || v_search || '%'
           or coalesce(b.customer_email, '') ilike '%' || v_search || '%'
           or coalesce(b.utr_number, '') ilike '%' || v_search || '%')
  )
  select f.id, f.user_id, f.customer, f.customer_email, f.product_id, f.product_name,
    f.product_type, f.type, f.used_key_id, f.used_key_remaining_days, f.amount,
    f.utr_number, f.payment_submitted_at, f.payment_time, f.created_at, f.status,
    count(*) over() as total_count, f.software_plan_label,
    c.count_new, c.count_completed, c.count_rejected, c.count_all
  from filtered as f
  cross join counted as c
  order by f.payment_time desc nulls last, f.id desc
  offset (p_page - 1) * p_page_size limit p_page_size;
end;
$$;

create or replace function public.admin_get_request(p_type text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_topup public.topup_requests%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_type = 'topup' then
    select t.* into v_topup
    from public.topup_requests as t
    where t.id = p_id;
    if not found then return jsonb_build_object('ok', false, 'message', 'Top-up request not found.'); end if;
    return jsonb_build_object(
      'ok', true, 'id', v_topup.id, 'type', 'topup',
      'customer', coalesce((
        select u.email::text from auth.users as u where u.id = v_topup.user_id
      ), 'Customer'),
      'product_name', 'Wallet Top-up', 'product_type', 'topup',
      'amount', round(v_topup.amount, 2), 'utr_number', v_topup.utr,
      'payment_time', v_topup.created_at,
      'status', case when v_topup.status = 'pending' then 'utr_submitted'
                     when v_topup.status = 'approved' then 'completed'
                     else 'rejected' end
    );
  end if;

  select o.* into v_order
  from public.orders as o
  where o.id = p_id
    and coalesce(o.utr_number, o.utr) is not null;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order request not found.'); end if;
  return jsonb_build_object(
    'ok', true, 'id', v_order.id, 'type', 'software',
    'customer', coalesce((
      select u.email::text from auth.users as u where u.id = v_order.user_id
    ), v_order.guest_email, 'Customer'),
    'product_name', v_order.product_name, 'product_type', v_order.product_type,
    'amount', round(coalesce(v_order.amount, v_order.price), 2),
    'utr_number', coalesce(v_order.utr_number, v_order.utr),
    'payment_time', coalesce(v_order.payment_submitted_at, v_order.utr_submitted_at, v_order.created_at),
    'status', case
      when v_order.status in ('completed', 'delivered')
        or v_order.delivered_at is not null
        or nullif(btrim(coalesce(v_order.delivery_text, '')), '') is not null
        or nullif(btrim(coalesce(v_order.delivery_link, '')), '') is not null
        or nullif(btrim(coalesce(v_order.delivery_note, '')), '') is not null
        or exists (
          select 1
          from public.order_delivery as d
          where d.order_id = v_order.id
            and (
              nullif(btrim(coalesce(d.software_name, '')), '') is not null
              or d.license_key_encrypted is not null
              or nullif(btrim(coalesce(d.download_link, '')), '') is not null
              or nullif(btrim(coalesce(d.vps_ip, '')), '') is not null
              or d.vps_port is not null
              or nullif(btrim(coalesce(d.vps_username, '')), '') is not null
              or d.vps_password_encrypted is not null
              or d.vps_storage_gb is not null
            )
        ) then 'completed'
      when v_order.status in ('utr_submitted', 'pending_verification', 'new', 'pending') then 'utr_submitted'
      else v_order.status
    end,
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
#variable_conflict use_column
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
      update public.orders as o
      set status = 'rejected',
          payment_status = 'rejected',
          reject_reason = nullif(left(btrim(coalesce(p_reason, '')), 1000), '')
      where o.id = p_id
        and coalesce(o.utr_number, o.utr) is not null
        and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending');
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
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_delivery public.order_delivery%rowtype;
  v_key text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order
  from public.orders as o
  where o.id = p_order_id
    and coalesce(o.utr_number, o.utr) is not null
    and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending')
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Only submitted order requests can be completed.');
  end if;

  select d.* into v_delivery
  from public.order_delivery as d
  where d.order_id = p_order_id;
  select s.encryption_key into v_key
  from private.order_delivery_secrets as s
  where s.id = true;
  if v_order.product_type = 'software'
     and p_details is not null
     and jsonb_typeof(p_details) = 'object'
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
    select d.* into v_delivery
    from public.order_delivery as d
    where d.order_id = p_order_id;
  end if;

  update public.orders as o
  set status = 'completed',
      payment_status = 'paid',
      completed_at = clock_timestamp(),
      delivered_at = clock_timestamp()
  where o.id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'completed');
end;
$$;

create or replace function public.admin_reject_order_request(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  update public.orders as o
  set status = 'rejected',
      payment_status = 'rejected',
      reject_reason = nullif(left(btrim(coalesce(p_reason, '')), 1000), '')
  where o.id = p_order_id
    and coalesce(o.utr_number, o.utr) is not null
    and o.status in ('utr_submitted', 'pending_verification', 'new', 'pending');
  if not found then
    return jsonb_build_object('ok', false, 'message', 'This order is no longer awaiting review.');
  end if;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

-- Preserve the legacy delivery RPC while ensuring its delivered state is canonical.
create or replace function public.admin_save_order_delivery(
  p_order_id bigint, p_text text, p_link text, p_note text, p_deliver boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_link text := trim(coalesce(p_link, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(coalesce(p_text, '')) > 100000 or length(v_link) > 2048
     or length(coalesce(p_note, '')) > 4000 then
    return jsonb_build_object('ok', false, 'message', 'Delivery details exceed the allowed length.');
  end if;
  if v_link <> '' and v_link !~* '^https?://[^[:space:]]+$' then
    return jsonb_build_object('ok', false, 'message', 'Download links must start with http:// or https://.');
  end if;
  select o.* into v_order
  from public.orders as o
  where o.id = p_order_id
  for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.payment_status = 'pending' then
    return jsonb_build_object('ok', false, 'message', 'Approve the UPI payment before delivering this order.');
  end if;
  if v_order.status in ('refunded', 'rejected') then
    return jsonb_build_object('ok', false, 'message', 'This order cannot be updated.');
  end if;
  if p_deliver and length(coalesce(p_text, '')) = 0 and v_link = '' then
    return jsonb_build_object('ok', false, 'message', 'Add delivery details or a download link before delivering.');
  end if;
  update public.orders as o
  set delivery_text = coalesce(p_text, ''),
      delivery_link = nullif(v_link, ''),
      delivery_note = nullif(trim(coalesce(p_note, '')), ''),
      status = case when p_deliver then 'completed' else o.status end,
      delivered_at = case when p_deliver then now() else o.delivered_at end
  where o.id = p_order_id;
  return jsonb_build_object(
    'ok', true,
    'status', case when p_deliver then 'completed' else v_order.status end
  );
end;
$$;

create or replace function public.admin_approve_product_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order public.orders%rowtype;
  v_download_url text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order
  from public.orders as o
  where o.id = p_order_id
  for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status <> 'pending_verification' or v_order.payment_status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'This payment is no longer awaiting verification.');
  end if;
  select d.download_url into v_download_url
  from public.product_download_links as d
  where d.product_id = v_order.product_id;
  update public.orders as o
  set payment_status = 'paid',
      status = case when v_download_url is null then 'pending' else 'completed' end,
      delivery_link = v_download_url,
      delivered_at = case when v_download_url is null then null else now() end
  where o.id = p_order_id;
  if v_order.offer_claim_id is not null then
    insert into public.offer_audit_events(actor_id, action, offer_id, claim_id, order_id, details)
    values (
      auth.uid(), 'offer_payment_approved', v_order.offer_id, v_order.offer_claim_id, v_order.id,
      jsonb_build_object('utr', v_order.utr, 'amount', v_order.price)
    );
  end if;
  return jsonb_build_object(
    'ok', true,
    'status', case when v_download_url is null then 'pending' else 'completed' end,
    'delivered', v_download_url is not null
  );
end;
$$;

revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_request(text, bigint) from public, anon;
revoke all on function public.admin_review_request(text, bigint, text, text) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_reject_order_request(bigint, text) from public, anon;
revoke all on function public.admin_save_order_delivery(bigint, text, text, text, boolean) from public, anon;
revoke all on function public.admin_approve_product_order(bigint) from public, anon;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_request(text, bigint) to authenticated;
grant execute on function public.admin_review_request(text, bigint, text, text) to authenticated;
grant execute on function public.admin_complete_order(bigint, jsonb) to authenticated;
grant execute on function public.admin_reject_order_request(bigint, text) to authenticated;
grant execute on function public.admin_save_order_delivery(bigint, text, text, text, boolean) to authenticated;
grant execute on function public.admin_approve_product_order(bigint) to authenticated;

commit;
