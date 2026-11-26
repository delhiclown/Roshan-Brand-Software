begin;

create or replace function public.prevent_paid_order_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.payment_status = 'paid'
     and not (
       public.is_store_admin()
       and old.used_key_id is not null
       and coalesce(current_setting('app.admin_used_key_delete', true), '') = old.used_key_id::text
     ) then
    raise exception 'Paid orders cannot be deleted';
  end if;
  return old;
end;
$$;
revoke all on function public.prevent_paid_order_delete() from public, anon, authenticated;

create or replace function public.admin_delete_used_key(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item private.used_key_inventory%rowtype;
  v_deleted_orders integer := 0;
  v_previous_delete_scope text := current_setting('app.admin_used_key_delete', true);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;

  select k.* into v_item
  from private.used_key_inventory as k
  where k.id = p_id
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Used Key not found.');
  end if;

  delete from private.used_key_payment_recovery_audit as a
  where a.used_key_id = p_id;

  if v_item.status = 'reserved' then
    update public.orders as o
    set status = 'rejected',
        payment_status = 'rejected',
        reject_reason = 'Order rejected because its reserved Used Key was deleted by an admin.'
    where (v_item.reserved_order_id is null or o.id = v_item.reserved_order_id)
      and o.used_key_id = p_id
      and o.status not in ('completed', 'delivered', 'rejected', 'refunded', 'expired');
  elsif v_item.status = 'sold' then
    perform set_config('app.admin_used_key_delete', p_id::text, true);
    delete from public.orders as o where o.used_key_id = p_id;
    get diagnostics v_deleted_orders = row_count;
    perform set_config('app.admin_used_key_delete', coalesce(v_previous_delete_scope, ''), true);
  end if;

  delete from private.used_key_inventory as k where k.id = p_id;
  return jsonb_build_object('ok', true, 'deleted_orders', v_deleted_orders);
end;
$$;

revoke all on function public.admin_delete_used_key(bigint) from public, anon;
grant execute on function public.admin_delete_used_key(bigint) to authenticated;

commit;
