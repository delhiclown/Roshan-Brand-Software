begin;

create table if not exists public.telegram_order_alerts (
  order_id bigint primary key references public.orders(id) on delete cascade,
  attempted_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);

alter table public.telegram_order_alerts enable row level security;
revoke all on public.telegram_order_alerts from public, anon, authenticated;
grant all on public.telegram_order_alerts to service_role;

commit;
