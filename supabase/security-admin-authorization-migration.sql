begin;

create or replace function public.sanitize_email_signup_metadata()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if coalesce(new.raw_app_meta_data ->> 'provider', '') = 'email' then
    v_name := left(btrim(coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      ''
    )), 100);
    new.raw_user_meta_data := case
      when v_name = '' then '{}'::jsonb
      else jsonb_build_object('full_name', v_name)
    end;
  end if;
  return new;
end;
$$;

revoke all on function public.sanitize_email_signup_metadata() from public, anon, authenticated;
drop trigger if exists sanitize_email_signup_metadata on auth.users;
create trigger sanitize_email_signup_metadata
  before insert on auth.users
  for each row execute function public.sanitize_email_signup_metadata();

alter table public.admin_users enable row level security;
do $$
declare
  v_policy record;
begin
  for v_policy in
    select p.policyname
    from pg_policies as p
    where p.schemaname = 'public' and p.tablename = 'admin_users'
  loop
    execute format('drop policy %I on public.admin_users', v_policy.policyname);
  end loop;
end;
$$;
create policy "Admins can view own admin record" on public.admin_users
  for select to authenticated using (id = (select auth.uid()));

revoke all on public.admin_users from public, anon, authenticated;
grant select on public.admin_users to authenticated;

create or replace function public.is_store_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users as admins
    where admins.id = (select auth.uid())
  );
$$;
revoke all on function public.is_store_admin() from public, anon;
grant execute on function public.is_store_admin() to authenticated;

commit;
