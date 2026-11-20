begin;

do $$
begin
  if pg_catalog.to_regclass('public.channel_settings') is not null then
    raise exception 'public.channel_settings already exists; refusing to modify an existing table.';
  end if;
end;
$$;

create table if not exists public.channel_settings (
  id boolean primary key default true check (id)
);

alter table public.channel_settings
  add column if not exists whatsapp_followers integer not null check (whatsapp_followers > 0);
alter table public.channel_settings
  add column if not exists whatsapp_link text not null check (whatsapp_link ~* '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$');
alter table public.channel_settings
  add column if not exists whatsapp_followers_updated_at timestamptz not null default now();
alter table public.channel_settings
  add column if not exists telegram_followers integer not null check (telegram_followers > 0);
alter table public.channel_settings
  add column if not exists telegram_link text not null check (telegram_link ~* '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$');
alter table public.channel_settings
  add column if not exists telegram_followers_updated_at timestamptz not null default now();
alter table public.channel_settings
  add column if not exists updated_at timestamptz not null default now();

alter table public.channel_settings enable row level security;
revoke all on public.channel_settings from public, anon, authenticated;

insert into public.channel_settings (
  id,
  whatsapp_followers,
  whatsapp_link,
  telegram_followers,
  telegram_link
)
values (
  true,
  7000,
  'https://whatsapp.com/channel/0029Vb8dm4yD38CPjHRE440V',
  4500,
  'https://t.me/tatkalsoftwareservices'
)
on conflict (id) do nothing;

create function public.public_channel_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'whatsapp_followers', settings.whatsapp_followers,
    'whatsapp_link', settings.whatsapp_link,
    'telegram_followers', settings.telegram_followers,
    'telegram_link', settings.telegram_link
  )
  from public.channel_settings as settings
  where settings.id = true;
$$;

create function public.admin_get_channel_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
  declare
    settings public.channel_settings%rowtype;
  begin
    if not coalesce(public.is_store_admin(), false) then
      raise exception 'Only store admins can view channel settings.' using errcode = '42501';
    end if;

    select * into settings
    from public.channel_settings
    where id = true;

    return pg_catalog.jsonb_build_object(
      'whatsapp_followers', settings.whatsapp_followers,
      'whatsapp_link', settings.whatsapp_link,
      'whatsapp_followers_updated_at', settings.whatsapp_followers_updated_at,
      'telegram_followers', settings.telegram_followers,
      'telegram_link', settings.telegram_link,
      'telegram_followers_updated_at', settings.telegram_followers_updated_at
    );
  end;
$$;

create function public.admin_save_channel_settings(
  p_whatsapp_followers integer,
  p_whatsapp_link text,
  p_telegram_followers integer,
  p_telegram_link text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
  declare
    previous public.channel_settings%rowtype;
    saved public.channel_settings%rowtype;
    saved_at timestamptz := pg_catalog.clock_timestamp();
  begin
    if not coalesce(public.is_store_admin(), false) then
      raise exception 'Only store admins can change channel settings.' using errcode = '42501';
    end if;
    if p_whatsapp_followers is null or p_whatsapp_followers <= 0
      or p_telegram_followers is null or p_telegram_followers <= 0 then
      raise exception 'Follower counts must be positive whole numbers.' using errcode = '22023';
    end if;
    if p_whatsapp_link is null or p_whatsapp_link !~* '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
      or p_telegram_link is null or p_telegram_link !~* '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$' then
      raise exception 'Channel links must start with https://.' using errcode = '22023';
    end if;

    select * into previous
    from public.channel_settings
    where id = true
    for update;

    update public.channel_settings
    set whatsapp_followers = p_whatsapp_followers,
        whatsapp_link = pg_catalog.btrim(p_whatsapp_link),
        whatsapp_followers_updated_at = case
          when previous.whatsapp_followers is distinct from p_whatsapp_followers then saved_at
          else previous.whatsapp_followers_updated_at
        end,
        telegram_followers = p_telegram_followers,
        telegram_link = pg_catalog.btrim(p_telegram_link),
        telegram_followers_updated_at = case
          when previous.telegram_followers is distinct from p_telegram_followers then saved_at
          else previous.telegram_followers_updated_at
        end,
        updated_at = saved_at
    where id = true
    returning * into saved;

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'whatsapp_followers', saved.whatsapp_followers,
      'whatsapp_link', saved.whatsapp_link,
      'whatsapp_followers_updated_at', saved.whatsapp_followers_updated_at,
      'telegram_followers', saved.telegram_followers,
      'telegram_link', saved.telegram_link,
      'telegram_followers_updated_at', saved.telegram_followers_updated_at
    );
  end;
$$;

revoke all on function public.public_channel_stats() from public;
grant execute on function public.public_channel_stats() to anon, authenticated;
revoke all on function public.admin_get_channel_settings() from public, anon;
grant execute on function public.admin_get_channel_settings() to authenticated;
revoke all on function public.admin_save_channel_settings(integer, text, integer, text) from public, anon;
grant execute on function public.admin_save_channel_settings(integer, text, integer, text) to authenticated;

commit;
