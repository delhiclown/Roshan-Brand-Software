begin;

alter table private.used_key_inventory
  add column if not exists expiry_at timestamptz,
  add column if not exists sold_validity_days integer;

create table if not exists private.used_key_migration_log (
  migration_name text primary key,
  applied_at timestamptz not null default clock_timestamp()
);
revoke all on private.used_key_migration_log from public, anon, authenticated;

do $$
declare
  v_migration_rows integer;
  v_now_ist timestamp without time zone :=
    timezone('Asia/Kolkata', clock_timestamp());
begin
  insert into private.used_key_migration_log (migration_name)
  values ('legacy-expiry-from-current-remaining-v1')
  on conflict (migration_name) do nothing;
  get diagnostics v_migration_rows = row_count;

  if v_migration_rows = 0 then
    return;
  end if;

  update private.used_key_inventory as k
  set expiry_at =
    ((case when v_now_ist::time < time '11:00'
        then v_now_ist::date
        else v_now_ist::date + 1
      end + greatest(k.expires_on - v_now_ist::date, 0) - 1)
      + time '11:00') at time zone 'Asia/Kolkata'
  where k.status <> 'sold' or k.expiry_at is null;
end;
$$;

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

commit;
