-- Apply order: run software-pnr-plans-migration.sql first, then these files in order.
-- 1/4 - tables, columns, constraints, and reservation trigger. Run this file once, after backup and explicit approval.

begin;

alter table public.orders alter column user_id drop not null;
alter table public.orders add column if not exists guest_email text;
alter table public.orders add column if not exists guest_whatsapp text;
alter table public.orders add column if not exists guest_access_hash text;
alter table public.orders add column if not exists guest_device_hash text;
alter table public.orders add column if not exists guest_ip_hash text;
alter table public.orders add column if not exists guest_email_sent_at timestamptz;

alter table public.orders drop constraint if exists orders_guest_identity_check;
alter table public.orders add constraint orders_guest_identity_check check (
  (guest_email is not null
    and guest_access_hash is not null and guest_access_hash ~ '^[0-9a-f]{64}$'
    and ((user_id is null
      and guest_device_hash is not null and guest_device_hash ~ '^[0-9a-f]{64}$'
      and guest_ip_hash is not null and guest_ip_hash ~ '^[0-9a-f]{64}$')
      or (user_id is not null and guest_device_hash is null and guest_ip_hash is null)))
  or (user_id is not null and guest_email is null and guest_access_hash is null
    and guest_device_hash is null and guest_ip_hash is null)
);
alter table public.orders drop constraint if exists orders_guest_email_check;
alter table public.orders add constraint orders_guest_email_check check (
  guest_email is null or (length(guest_email) between 3 and 254 and guest_email = lower(btrim(guest_email)))
);
alter table public.orders drop constraint if exists orders_guest_whatsapp_check;
alter table public.orders add constraint orders_guest_whatsapp_check check (
  guest_whatsapp is null or length(guest_whatsapp) between 8 and 24
);
create index if not exists orders_guest_email_created_idx
  on public.orders (guest_email, created_at desc) where guest_email is not null;

create table if not exists private.guest_demo_claims (
  id bigint generated always as identity primary key,
  product_id bigint not null references private.demo_key_inventory(product_id) on delete restrict,
  email_hash text not null check (email_hash ~ '^[0-9a-f]{64}$'),
  device_hash text not null check (device_hash ~ '^[0-9a-f]{64}$'),
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  claim_day date not null,
  claimed_at timestamptz not null default clock_timestamp(),
  unique (email_hash, claim_day),
  unique (device_hash, claim_day),
  unique (ip_hash, claim_day)
);
alter table private.guest_demo_claims enable row level security;
revoke all on private.guest_demo_claims from public, anon, authenticated;

create table if not exists private.guest_utr_attempts (
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  attempted_at timestamptz not null default clock_timestamp()
);
create index if not exists guest_utr_attempts_ip_time_idx
  on private.guest_utr_attempts (ip_hash, attempted_at desc);
alter table private.guest_utr_attempts enable row level security;
revoke all on private.guest_utr_attempts from public, anon, authenticated;

create or replace function private.release_guest_used_key_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.used_key_inventory as k
  set status = 'available', reserved_order_id = null, updated_at = clock_timestamp()
  where k.id = old.used_key_id and k.status = 'reserved'
    and k.reserved_order_id = old.id;
  return new;
end;
$$;
drop trigger if exists release_guest_used_key_reservation on public.orders;
create trigger release_guest_used_key_reservation
  after update of status on public.orders
  for each row
  when (
    old.used_key_id is not null
    and new.status in ('expired', 'rejected', 'cancelled')
  )
  execute function private.release_guest_used_key_reservation();

commit;
