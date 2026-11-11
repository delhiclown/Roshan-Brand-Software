begin;

create table if not exists private.demo_key_inventory (
  product_id bigint primary key references public.products(id) on delete restrict,
  license_key_encrypted bytea not null,
  validity_days integer check (validity_days is null or validity_days between 1 and 36500),
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists private.demo_key_claims (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  email_normalized text not null,
  product_id bigint not null references private.demo_key_inventory(product_id) on delete restrict,
  claimed_at timestamptz not null default clock_timestamp(),
  constraint demo_key_claims_email_product_unique unique (email_normalized, product_id),
  constraint demo_key_claims_user_product_unique unique (user_id, product_id)
);

alter table private.demo_key_inventory enable row level security;
alter table private.demo_key_claims enable row level security;
revoke all on private.demo_key_inventory, private.demo_key_claims from anon, authenticated;

create or replace function public.admin_save_demo_key(
  p_product_id bigint,
  p_license_key text,
  p_validity_days integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_encryption_key text;
  v_product public.products%rowtype;
  v_download_url text;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_product_id is null or p_product_id <= 0 then raise exception 'Choose a valid software product'; end if;
  if p_license_key is null or length(btrim(p_license_key)) not between 1 and 4000 then
    raise exception 'Demo key must contain 1 to 4,000 characters';
  end if;
  if p_validity_days is not null and p_validity_days not between 1 and 36500 then
    raise exception 'Demo days must be between 1 and 36,500';
  end if;

  select p.* into v_product
  from public.products as p
  where p.id = p_product_id and lower(p.category) = 'software';
  if not found then raise exception 'Choose an existing Software product'; end if;
  select d.download_url into v_download_url
  from public.product_download_links as d
  where d.product_id = p_product_id;
  if coalesce(btrim(v_download_url), '') = '' then
    raise exception 'Add a download link to this software before configuring its demo key';
  end if;
  if exists(select 1 from private.demo_key_claims as c where c.product_id = p_product_id) then
    raise exception 'This demo key has already been claimed; do not replace a key that has active claims';
  end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  if coalesce(v_encryption_key, '') = '' then raise exception 'Order delivery encryption is not configured'; end if;

  insert into private.demo_key_inventory as inventory (product_id, license_key_encrypted, validity_days, updated_at)
  values (p_product_id, extensions.pgp_sym_encrypt(btrim(p_license_key), v_encryption_key), p_validity_days, clock_timestamp())
  on conflict (product_id) do update set
    license_key_encrypted = excluded.license_key_encrypted,
    validity_days = excluded.validity_days,
    updated_at = clock_timestamp();
  return jsonb_build_object('ok', true, 'product_id', p_product_id);
end;
$$;

create or replace function public.admin_list_demo_keys()
returns table(product_id bigint, software_name text, validity_days integer, claim_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select i.product_id, p.name, i.validity_days, count(c.id)
    from private.demo_key_inventory as i
    join public.products as p on p.id = i.product_id
    left join private.demo_key_claims as c on c.product_id = i.product_id
    group by i.product_id, p.name, i.validity_days
    order by p.name;
end;
$$;

create or replace function public.list_available_demo_keys()
returns table(product_id bigint, software_name text, image_url text, price numeric, validity_days integer)
language sql
security definer
set search_path = ''
as $$
  select p.id, p.name, p.image_url, p.price, i.validity_days
  from private.demo_key_inventory as i
  join public.products as p on p.id = i.product_id
  join public.product_download_links as d on d.product_id = p.id and coalesce(btrim(d.download_url), '') <> ''
  where lower(p.category) = 'software' and p.in_stock is distinct from false
  order by p.name;
$$;

create or replace function public.claim_demo_key(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_email_normalized text;
  v_encryption_key text;
  v_license_key text;
  v_software_name text;
  v_image_url text;
  v_download_url text;
  v_validity_days integer;
  v_claim_id bigint;
begin
  if v_user_id is null then raise exception 'Sign in with Google using a Gmail account to claim a demo key'; end if;
  if coalesce(auth.jwt()->'app_metadata'->>'provider', '') <> 'google' then
    raise exception 'Sign in with Google to claim a demo key';
  end if;
  select lower(btrim(u.email)) into v_email_normalized
  from auth.users as u where u.id = v_user_id;
  if v_email_normalized is null or v_email_normalized !~ '^[^@]+@gmail[.]com$' then
    raise exception 'A Gmail account is required to claim a demo key';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_email_normalized || ':' || p_product_id::text, 0));
  if exists(
    select 1 from private.demo_key_claims as c
    where c.email_normalized = v_email_normalized and c.product_id = p_product_id
  ) then
    return jsonb_build_object('ok', false, 'message', 'This Gmail account has already claimed this software demo');
  end if;
  select p.name, p.image_url, i.validity_days, d.download_url,
         extensions.pgp_sym_decrypt(i.license_key_encrypted, s.encryption_key)
  into v_software_name, v_image_url, v_validity_days, v_download_url, v_license_key
  from private.demo_key_inventory as i
  join public.products as p on p.id = i.product_id
  join public.product_download_links as d on d.product_id = p.id
  cross join private.order_delivery_secrets as s
  where i.product_id = p_product_id and s.id = true
    and lower(p.category) = 'software' and p.in_stock is distinct from false;
  if not found then return jsonb_build_object('ok', false, 'message', 'This demo key is not available'); end if;

  insert into private.demo_key_claims (user_id, email_normalized, product_id)
  values (v_user_id, v_email_normalized, p_product_id)
  returning id into v_claim_id;
  return jsonb_build_object(
    'ok', true, 'claim_id', v_claim_id, 'software_name', v_software_name,
    'image_url', v_image_url, 'license_key', v_license_key,
    'download_link', v_download_url, 'validity_days', v_validity_days
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'message', 'This Gmail account has already claimed this software demo');
end;
$$;

create or replace function public.my_demo_keys()
returns table(claim_id bigint, software_name text, license_key text, download_link text, validity_days integer, claimed_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_encryption_key text;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  select lower(btrim(u.email)) into v_email from auth.users as u where u.id = v_user_id;
  select s.encryption_key into v_encryption_key from private.order_delivery_secrets as s where s.id = true;
  return query
    select c.id, p.name,
      extensions.pgp_sym_decrypt(i.license_key_encrypted, v_encryption_key),
      d.download_url, i.validity_days, c.claimed_at
    from private.demo_key_claims as c
    join private.demo_key_inventory as i on i.product_id = c.product_id
    join public.products as p on p.id = c.product_id
    left join public.product_download_links as d on d.product_id = c.product_id
    where c.user_id = v_user_id and c.email_normalized = v_email
    order by c.claimed_at desc;
end;
$$;

revoke all on function public.admin_save_demo_key(bigint, text, integer) from public, anon;
revoke all on function public.admin_list_demo_keys() from public, anon;
revoke all on function public.list_available_demo_keys() from public;
revoke all on function public.claim_demo_key(bigint) from public, anon;
revoke all on function public.my_demo_keys() from public, anon;
grant execute on function public.admin_save_demo_key(bigint, text, integer) to authenticated;
grant execute on function public.admin_list_demo_keys() to authenticated;
grant execute on function public.list_available_demo_keys() to anon, authenticated;
grant execute on function public.claim_demo_key(bigint) to authenticated;
grant execute on function public.my_demo_keys() to authenticated;

create table if not exists public.rental_products (
  product_id bigint primary key references public.products(id) on delete restrict,
  daily_rate numeric(12, 2) not null check (daily_rate > 0 and daily_rate <= 100000),
  is_enabled boolean not null default true,
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists private.rental_accounts (
  id bigint generated always as identity primary key,
  rental_product_id bigint not null references public.rental_products(product_id) on delete restrict,
  account_encrypted bytea not null,
  lease_order_id bigint,
  lease_until timestamptz,
  is_enabled boolean not null default true,
  created_at timestamptz not null default clock_timestamp()
);

alter table public.orders
  add column if not exists rental_product_id bigint references public.rental_products(product_id) on delete restrict;
alter table public.orders
  add column if not exists rental_account_id bigint references private.rental_accounts(id) on delete restrict;
alter table public.orders
  add column if not exists rental_expires_at timestamptz;

create index if not exists rental_accounts_available_idx
  on private.rental_accounts (rental_product_id, lease_until, id)
  where is_enabled = true;
create index if not exists orders_rental_product_status_idx
  on public.orders (rental_product_id, status, created_at desc)
  where rental_product_id is not null;
alter table public.rental_products enable row level security;
alter table private.rental_accounts enable row level security;
revoke all on public.rental_products from public, anon, authenticated;
revoke all on private.rental_accounts from public, anon, authenticated;

create or replace function public.admin_save_rental_product(p_product_id bigint, p_daily_rate numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_product public.products%rowtype;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_product_id is null or p_product_id <= 0 or p_daily_rate is null
     or p_daily_rate <= 0 or p_daily_rate > 100000 then
    raise exception 'Choose software and enter a daily rate from 0.01 to 100,000';
  end if;
  select p.* into v_product from public.products as p
    where p.id = p_product_id and lower(p.category) = 'software';
  if not found then raise exception 'Choose an existing Software product'; end if;
  insert into public.rental_products as rental (product_id, daily_rate, is_enabled, updated_at)
  values (p_product_id, p_daily_rate, true, clock_timestamp())
  on conflict (product_id) do update set daily_rate = excluded.daily_rate,
    is_enabled = true, updated_at = clock_timestamp();
  return jsonb_build_object('ok', true, 'product_id', p_product_id);
end;
$$;

create or replace function public.admin_add_rental_accounts(p_product_id bigint, p_accounts text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_encryption_key text;
  v_account text;
  v_added integer := 0;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_product_id is null or p_product_id <= 0 or coalesce(array_length(p_accounts, 1), 0) not between 1 and 100 then
    raise exception 'Choose rental software and submit 1 to 100 login entries';
  end if;
  if not exists(select 1 from public.rental_products as r where r.product_id = p_product_id) then
    raise exception 'Configure a daily rental rate before adding rental IDs';
  end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  if coalesce(v_encryption_key, '') = '' then raise exception 'Order delivery encryption is not configured'; end if;
  foreach v_account in array p_accounts loop
    v_account := btrim(coalesce(v_account, ''));
    if length(v_account) not between 1 and 4000 then
      raise exception 'Each rental ID / login must contain 1 to 4,000 characters';
    end if;
    insert into private.rental_accounts (rental_product_id, account_encrypted)
    values (p_product_id, extensions.pgp_sym_encrypt(v_account, v_encryption_key, 'cipher-algo=aes256'));
    v_added := v_added + 1;
  end loop;
  return jsonb_build_object('ok', true, 'added', v_added);
end;
$$;

create or replace function public.admin_list_rental_products()
returns table(product_id bigint, software_name text, daily_rate numeric, available_count bigint, active_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select r.product_id, p.name, r.daily_rate,
      count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp())),
      count(a.id) filter(where a.is_enabled and a.lease_until > clock_timestamp())
    from public.rental_products as r
    join public.products as p on p.id = r.product_id
    left join private.rental_accounts as a on a.rental_product_id = r.product_id
    group by r.product_id, p.name, r.daily_rate
    order by p.name;
end;
$$;

create or replace function public.list_available_rental_products()
returns table(product_id bigint, software_name text, image_url text, daily_rate numeric, available_count bigint)
language sql
security definer
set search_path = ''
as $$
  select r.product_id, p.name, p.image_url, r.daily_rate,
    count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp()))
  from public.rental_products as r
  join public.products as p on p.id = r.product_id and lower(p.category) = 'software'
  join private.rental_accounts as a on a.rental_product_id = r.product_id
  where r.is_enabled and p.in_stock
  group by r.product_id, p.name, p.image_url, r.daily_rate
  having count(a.id) filter(where a.is_enabled and (a.lease_until is null or a.lease_until <= clock_timestamp())) > 0
  order by p.name;
$$;

create or replace function public.create_rental_order(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_product public.products%rowtype;
  v_rental public.rental_products%rowtype;
  v_order_id bigint;
  v_payment_timeout integer := 30;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if p_product_id is null or p_product_id <= 0 then raise exception 'Choose a valid rental product'; end if;
  select r.* into v_rental from public.rental_products as r
    where r.product_id = p_product_id and r.is_enabled for share;
  if not found then return jsonb_build_object('ok', false, 'message', 'This rental is unavailable'); end if;
  select p.* into v_product from public.products as p
    where p.id = p_product_id and lower(p.category) = 'software' and p.in_stock for share;
  if not found or not exists(
    select 1 from private.rental_accounts as a
    where a.rental_product_id = p_product_id and a.is_enabled
      and (a.lease_until is null or a.lease_until <= clock_timestamp())
  ) then return jsonb_build_object('ok', false, 'message', 'No rental IDs are currently available'); end if;

  insert into public.orders (
    user_id, product_id, product_name, product_type, price, amount, status,
    payment_method, payment_status, quantity, coupon_code, discount_percent,
    original_price, rental_product_id, payment_expires_at
  ) values (
    v_user_id, v_product.id, v_product.name, 'rental', v_rental.daily_rate, v_rental.daily_rate,
    'unpaid', 'upi_qr', 'pending', 1, null, 0, null,
    v_rental.product_id, clock_timestamp() + make_interval(mins => v_payment_timeout)
  ) returning id into v_order_id;
  return jsonb_build_object(
    'ok', true, 'order_id', v_order_id, 'product_name', v_product.name,
    'amount', v_rental.daily_rate,
    'payment_expires_at', clock_timestamp() + make_interval(mins => v_payment_timeout)
  );
end;
$$;

create or replace function public.submit_rental_payment_utr(p_order_id bigint, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_utr text := btrim(coalesce(p_utr, ''));
  v_order public.orders%rowtype;
  v_attempts integer;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select count(*) into v_attempts from private.order_utr_attempts as a
    where a.user_id = v_user_id and a.attempted_at > clock_timestamp() - interval '1 hour';
  if v_attempts >= 5 then return jsonb_build_object('ok', false, 'message', 'Too many UTR attempts. Try again in an hour.'); end if;
  insert into private.order_utr_attempts (user_id) values (v_user_id);
  if v_utr !~ '^[0-9]{12}$' then return jsonb_build_object('ok', false, 'message', 'Enter a valid 12-digit UTR / transaction ID.'); end if;
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.user_id = v_user_id
      and o.product_type = 'rental' and o.rental_product_id is not null
      and o.payment_method = 'upi_qr' and o.status in ('unpaid', 'expired') and o.utr is null
    for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'This rental order can no longer accept a UTR.'); end if;
  if exists(select 1 from public.payment_utr_claims as c where c.utr_normalized = v_utr)
     or exists(select 1 from public.topup_requests as t where lower(t.utr) = lower(v_utr))
     or exists(select 1 from public.orders as o where o.utr_number = v_utr) then
    return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.');
  end if;
  insert into public.payment_utr_claims (utr_normalized, source)
    values (v_utr, 'product_order') on conflict do nothing;
  if not found then return jsonb_build_object('ok', false, 'message', 'This UTR has already been submitted.'); end if;
  update public.orders as o set
    utr = v_utr, utr_number = v_utr, utr_submitted_at = clock_timestamp(),
    payment_submitted_at = clock_timestamp(), late_payment = (
      v_order.payment_expires_at is not null and clock_timestamp() > v_order.payment_expires_at
    ), status = 'new', payment_status = 'pending'
  where o.id = v_order.id;
  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'status', 'new');
end;
$$;

create or replace function public.admin_list_rental_requests()
returns table(order_id bigint, customer_email text, software_name text, amount numeric, utr_number text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  return query
    select o.id, u.email, o.product_name, o.amount, o.utr_number, o.payment_submitted_at
    from public.orders as o
    join auth.users as u on u.id = o.user_id
    where o.product_type = 'rental' and o.status = 'new'
      and o.utr_number is not null
    order by o.payment_submitted_at desc, o.id desc;
end;
$$;

create or replace function public.admin_review_rental_payment(
  p_order_id bigint, p_approve boolean, p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_account private.rental_accounts%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_order_id is null or p_order_id <= 0 then raise exception 'Choose a valid rental order'; end if;
  select o.* into v_order from public.orders as o
    where o.id = p_order_id and o.product_type = 'rental' and o.status = 'new'
      and o.utr_number is not null
    for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Only submitted rental payment requests can be reviewed'); end if;
  if p_approve is distinct from true then
    if length(v_reason) not between 3 and 1000 then
      return jsonb_build_object('ok', false, 'message', 'Enter a rejection reason between 3 and 1,000 characters');
    end if;
    update public.orders as o set status = 'rejected', payment_status = 'rejected',
      reject_reason = v_reason, completed_at = null, rental_account_id = null, rental_expires_at = null
    where o.id = v_order.id;
    update public.coupons as c set status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
      used_at = null, used_order_id = null where c.used_order_id = v_order.id;
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select a.* into v_account from private.rental_accounts as a
    where a.rental_product_id = v_order.rental_product_id and a.is_enabled
      and (a.lease_until is null or a.lease_until <= clock_timestamp())
    order by a.id
    for update skip locked
    limit 1;
  if not found then return jsonb_build_object('ok', false, 'message', 'No rental ID is currently available; order remains pending for review'); end if;
  update private.rental_accounts as a set
    lease_order_id = v_order.id, lease_until = clock_timestamp() + interval '1 day'
  where a.id = v_account.id;
  update public.orders as o set status = 'completed', payment_status = 'paid',
    completed_at = clock_timestamp(), delivered_at = clock_timestamp(),
    rental_account_id = v_account.id, rental_expires_at = clock_timestamp() + interval '1 day'
  where o.id = v_order.id;
  return jsonb_build_object('ok', true, 'status', 'completed', 'expires_at', clock_timestamp() + interval '1 day');
end;
$$;

create or replace function public.my_rental_orders()
returns table(
  order_id bigint, product_name text, amount numeric, status text, payment_status text,
  utr_number text, reject_reason text, created_at timestamptz,
  rental_expires_at timestamptz, access_details text, rental_active boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_encryption_key text;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  select s.encryption_key into v_encryption_key from private.order_delivery_secrets as s where s.id = true;
  return query
    select o.id, o.product_name, o.amount,
      o.status,
      o.payment_status, o.utr_number, o.reject_reason, o.created_at, o.rental_expires_at,
      case when o.status = 'completed' and a.lease_order_id = o.id and a.lease_until > clock_timestamp()
        then extensions.pgp_sym_decrypt(a.account_encrypted, v_encryption_key) end,
      o.status = 'completed' and a.lease_order_id = o.id and a.lease_until > clock_timestamp()
    from public.orders as o
    left join private.rental_accounts as a on a.id = o.rental_account_id
    where o.user_id = v_user_id and o.product_type = 'rental'
    order by o.created_at desc limit 50;
end;
$$;

revoke all on function public.admin_save_rental_product(bigint, numeric) from public, anon;
revoke all on function public.admin_add_rental_accounts(bigint, text[]) from public, anon;
revoke all on function public.admin_list_rental_products() from public, anon;
revoke all on function public.list_available_rental_products() from public;
revoke all on function public.create_rental_order(bigint) from public, anon;
revoke all on function public.submit_rental_payment_utr(bigint, text) from public, anon;
revoke all on function public.admin_list_rental_requests() from public, anon;
revoke all on function public.admin_review_rental_payment(bigint, boolean, text) from public, anon;
revoke all on function public.my_rental_orders() from public, anon;
grant execute on function public.admin_save_rental_product(bigint, numeric) to authenticated;
grant execute on function public.admin_add_rental_accounts(bigint, text[]) to authenticated;
grant execute on function public.admin_list_rental_products() to authenticated;
grant execute on function public.list_available_rental_products() to anon, authenticated;
grant execute on function public.create_rental_order(bigint) to authenticated;
grant execute on function public.submit_rental_payment_utr(bigint, text) to authenticated;
grant execute on function public.admin_list_rental_requests() to authenticated;
grant execute on function public.admin_review_rental_payment(bigint, boolean, text) to authenticated;
grant execute on function public.my_rental_orders() to authenticated;

commit;
