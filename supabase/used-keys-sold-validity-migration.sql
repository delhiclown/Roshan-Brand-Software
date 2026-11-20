begin;

alter table private.used_key_inventory
  add column if not exists expiry_at timestamptz,
  add column if not exists sold_validity_days integer;

with local_clock as (
  select timezone('Asia/Kolkata', clock_timestamp()) as now_ist
)
update private.used_key_inventory as k
set expiry_at =
  ((case when local_clock.now_ist::time < time '11:00'
      then local_clock.now_ist::date
      else local_clock.now_ist::date + 1
    end + greatest(k.expires_on - local_clock.now_ist::date, 0) - 1)
      + time '11:00') at time zone 'Asia/Kolkata'
from local_clock
where k.expiry_at is null;

update private.used_key_inventory as k
set sold_validity_days = coalesce((
  select ord.used_key_remaining_days
  from public.orders as ord
  where ord.used_key_id = k.id
  order by case when ord.status = 'completed' then 0 else 1 end, ord.created_at desc
  limit 1
), k.validity_days, 0)
where k.status = 'sold' and k.sold_validity_days is null;

alter table private.used_key_inventory
  alter column expiry_at set not null;

create index if not exists used_key_inventory_expiry_at_idx
  on private.used_key_inventory (expiry_at, created_at desc)
  where status = 'available' and is_visible;

create or replace function private.used_key_remaining_days(
  p_expiry_at timestamptz, p_now timestamptz
)
returns integer
language sql
stable
set search_path = ''
as $$
  select greatest(
    ceil(extract(epoch from (p_expiry_at - p_now)) / 86400)::integer,
    0
  );
$$;

revoke all on function private.used_key_remaining_days(timestamptz, timestamptz)
  from public, anon, authenticated;

create or replace function private.capture_used_key_sold_validity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sold_validity_days :=
    private.used_key_remaining_days(new.expiry_at, coalesce(new.updated_at, clock_timestamp()));
  return new;
end;
$$;

revoke all on function private.capture_used_key_sold_validity()
  from public, anon, authenticated;

drop trigger if exists used_key_inventory_capture_sold_validity
  on private.used_key_inventory;
create trigger used_key_inventory_capture_sold_validity
  before update of status on private.used_key_inventory
  for each row
  when (old.status is distinct from 'sold' and new.status = 'sold')
  execute function private.capture_used_key_sold_validity();

create or replace function public.admin_list_used_keys()
returns table(
  id bigint, product_id bigint, software_name text, license_key text,
  download_link text, price numeric, regular_price numeric, validity_days integer,
  status text, is_visible boolean, reserved_order_id bigint, remaining_days integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_encryption_key text;
  v_now timestamptz := clock_timestamp();
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select s.encryption_key into v_encryption_key
  from private.order_delivery_secrets as s where s.id = true;
  return query
    select k.id, k.product_id, coalesce(p.name, k.software_name),
      extensions.pgp_sym_decrypt(k.license_key_encrypted, v_encryption_key),
      coalesce(dl.download_url, ''), k.price, k.regular_price, k.validity_days,
      k.status, k.is_visible, k.reserved_order_id,
      case when k.status = 'sold'
        then coalesce(k.sold_validity_days, o.used_key_remaining_days, k.validity_days, 0)
        else private.used_key_remaining_days(k.expiry_at, v_now)
      end
    from private.used_key_inventory as k
    left join public.products as p on p.id = k.product_id
    left join public.product_download_links as dl on dl.product_id = k.product_id
    left join lateral (
      select ord.used_key_remaining_days
      from public.orders as ord
      where ord.used_key_id = k.id
      order by case when ord.status = 'completed' then 0 else 1 end, ord.created_at desc
      limit 1
    ) as o on true
    order by k.created_at desc, k.id desc;
end;
$$;

revoke all on function public.admin_list_used_keys() from public, anon;
grant execute on function public.admin_list_used_keys() to authenticated;

commit;
