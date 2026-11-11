begin;

alter table public.products
  add column if not exists demo_only boolean not null default false;

create or replace function public.admin_save_demo_key_with_link(
  p_product_id bigint,
  p_download_url text,
  p_license_key text,
  p_validity_days integer default null
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
  if p_download_url is null or length(p_download_url) > 2048
    or p_download_url !~* '^https?://[^[:space:]]+$' then
    raise exception 'Enter a valid HTTP or HTTPS download link';
  end if;

  insert into public.product_download_links (product_id, download_url)
  values (p_product_id, btrim(p_download_url))
  on conflict (product_id) do update set
    download_url = excluded.download_url,
    updated_at = clock_timestamp();

  select public.admin_save_demo_key(p_product_id, p_license_key, p_validity_days)
  into v_result;
  return v_result;
end;
$$;

create or replace function public.admin_save_custom_demo_key(
  p_software_name text,
  p_download_url text,
  p_license_key text,
  p_validity_days integer default null,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product_id bigint;
  v_existing_demo_only boolean;
  v_result jsonb;
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if p_software_name is null or length(btrim(p_software_name)) not between 1 and 120 then
    raise exception 'Software name must contain 1 to 120 characters';
  end if;
  if p_image_url is not null and (
    length(p_image_url) > 2048 or p_image_url !~* '^https?://[^[:space:]]+$'
  ) then
    raise exception 'Enter a valid HTTP or HTTPS software photo URL';
  end if;

  select p.id, p.demo_only
  into v_product_id, v_existing_demo_only
  from public.products as p
  where p.category = 'software' and lower(p.name) = lower(btrim(p_software_name))
  order by p.id
  limit 1;

  if found and not v_existing_demo_only then
    raise exception 'A Software product with this name already exists; choose it from the list';
  end if;

  if not found then
    insert into public.products (
      category, name, description, price, selling_price, in_stock,
      sort_order, show_stats, demo_only
    )
    values (
      'software', btrim(p_software_name), 'Demo-only software', 0, 0, true,
      coalesce((select max(p.sort_order) + 1 from public.products as p where p.category = 'software'), 0),
      false, true
    )
    returning id into v_product_id;
  end if;

  if p_image_url is not null then
    update public.products
    set image_url = p_image_url
    where id = v_product_id;
  end if;

  select public.admin_save_demo_key_with_link(
    v_product_id, p_download_url, p_license_key, p_validity_days
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_save_demo_key_with_link(bigint, text, text, integer) from public, anon;
revoke all on function public.admin_save_custom_demo_key(text, text, text, integer, text) from public, anon;
grant execute on function public.admin_save_demo_key_with_link(bigint, text, text, integer) to authenticated;
grant execute on function public.admin_save_custom_demo_key(text, text, text, integer, text) to authenticated;

commit;
