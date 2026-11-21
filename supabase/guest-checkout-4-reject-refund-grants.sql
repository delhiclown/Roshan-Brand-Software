-- Apply order: run software-pnr-plans-migration.sql first, then these files in order.
-- 4/4 - reject/refund functions and all function grants. Run this file once, after backup and explicit approval.

begin;

create or replace function public.admin_reject_order_request(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) < 3 or length(v_reason) > 1000 then
    return jsonb_build_object('ok', false, 'message', 'Enter a rejection reason between 3 and 1000 characters.');
  end if;
  update public.orders as o set status = 'rejected', payment_status = 'rejected',
    reject_reason = v_reason, completed_at = null
  where o.id = p_order_id and o.status = 'new';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only new order requests can be rejected.'); end if;
  update public.coupons as c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
  where c.used_order_id = p_order_id;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

create or replace function public.admin_reject_product_payment(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  if length(v_reason) > 4000 then
    return jsonb_build_object('ok', false, 'message', 'Rejection reason must be 4000 characters or fewer.');
  end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status <> 'pending_verification' or v_order.payment_status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'This payment is no longer awaiting verification.');
  end if;
  update public.orders as o set status = 'rejected', payment_status = 'rejected',
    reject_reason = nullif(v_reason, '') where o.id = p_order_id;
  update public.coupons as c set
    status = case when c.expires_at > clock_timestamp() then 'unused' else 'expired' end,
    used_at = null, used_order_id = null
  where c.used_order_id = p_order_id;
  if v_order.offer_claim_id is not null then
    insert into public.offer_audit_events(actor_id, action, offer_id, claim_id, order_id, details)
    values (
      auth.uid(), 'offer_payment_rejected', v_order.offer_id, v_order.offer_claim_id, v_order.id,
      jsonb_build_object('reason', v_reason, 'utr', v_order.utr)
    );
  end if;
  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

create or replace function public.admin_refund_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_balance numeric(12, 2);
begin
  if not public.is_store_admin() then raise exception 'Admin access required'; end if;
  select o.* into v_order from public.orders as o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Order not found.'); end if;
  if v_order.status = 'refunded' then
    return jsonb_build_object('ok', false, 'message', 'This order has already been refunded.');
  end if;
  if v_order.payment_status <> 'paid' then
    return jsonb_build_object('ok', false, 'message', 'Only paid orders can be refunded to a wallet.');
  end if;
  if v_order.user_id is null then
    return jsonb_build_object('ok', false, 'message', 'Guest orders cannot be refunded to a wallet. Process the refund outside the wallet.');
  end if;
  insert into public.wallets (user_id) values (v_order.user_id) on conflict (user_id) do nothing;
  select w.balance into v_balance from public.wallets as w where w.user_id = v_order.user_id for update;
  update public.wallets as w set balance = w.balance + v_order.price, updated_at = now()
    where w.user_id = v_order.user_id returning w.balance into v_balance;
  update public.orders as o set status = 'refunded' where o.id = v_order.id;
  insert into public.wallet_transactions (user_id, type, amount, note, order_id)
    values (v_order.user_id, 'refund', v_order.price, 'Refund: ' || v_order.product_name, v_order.id);
  return jsonb_build_object('ok', true, 'balance', v_balance, 'amount', v_order.price);
end;
$$;

revoke all on function public.guest_create_order(text, bigint, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_submit_order_utr(bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.guest_get_order(bigint, text) from public, anon, authenticated;
revoke all on function public.guest_claim_demo_key(bigint, text, text, text, text) from public, anon, authenticated;
grant execute on function public.guest_create_order(text, bigint, bigint, text, text, text, text, text, text) to service_role;
grant execute on function public.guest_submit_order_utr(bigint, text, text, text) to service_role;
grant execute on function public.guest_get_order(bigint, text) to service_role;
grant execute on function public.guest_claim_demo_key(bigint, text, text, text, text) to service_role;
revoke all on function public.link_guest_orders_to_user() from public, anon;
grant execute on function public.link_guest_orders_to_user() to authenticated;

revoke all on function public.admin_list_orders() from public, anon;
revoke all on function public.admin_order_request_counts() from public, anon;
revoke all on function public.admin_list_order_requests(text, text, integer, integer) from public, anon;
revoke all on function public.admin_get_order_request(bigint) from public, anon;
revoke all on function public.admin_save_order_delivery(bigint, jsonb) from public, anon;
revoke all on function public.admin_complete_order(bigint, jsonb) from public, anon;
revoke all on function public.admin_list_rental_requests() from public, anon;
revoke all on function public.admin_guest_order_delivery(bigint) from public, anon;
revoke all on function public.admin_mark_guest_order_email_sent(bigint) from public, anon;
revoke all on function public.admin_reject_order_request(bigint, text) from public, anon;
revoke all on function public.admin_reject_product_payment(bigint, text) from public, anon;
revoke all on function public.admin_refund_order(bigint) from public, anon;
grant execute on function public.admin_list_orders() to authenticated;
grant execute on function public.admin_order_request_counts() to authenticated;
grant execute on function public.admin_list_order_requests(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_request(bigint) to authenticated;
grant execute on function public.admin_save_order_delivery(bigint, jsonb) to authenticated;
grant execute on function public.admin_complete_order(bigint, jsonb) to authenticated;
grant execute on function public.admin_list_rental_requests() to authenticated;
grant execute on function public.admin_guest_order_delivery(bigint) to authenticated;
grant execute on function public.admin_mark_guest_order_email_sent(bigint) to authenticated;
grant execute on function public.admin_reject_order_request(bigint, text) to authenticated;
grant execute on function public.admin_reject_product_payment(bigint, text) to authenticated;
grant execute on function public.admin_refund_order(bigint) to authenticated;

commit;
