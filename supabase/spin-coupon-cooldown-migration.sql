begin;

alter table public.coupons
  add column if not exists copied_at timestamptz;

create or replace function public.spin_wheel()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := (clock_timestamp() at time zone 'UTC')::date;
  v_prizes jsonb;
  v_item jsonb;
  v_prize jsonb;
  v_total_weight numeric := 0;
  v_target numeric;
  v_running numeric := 0;
  v_value integer;
  v_coupon_id uuid;
  v_coupon_code text;
  v_suffix text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_attempt_id bigint;
  v_index integer;
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  if exists (
    select 1 from public.spin_attempts
    where user_id = v_user_id
      and created_at > clock_timestamp() - interval '24 hours'
  ) then
    return jsonb_build_object('ok', false, 'message', 'You can spin again 24 hours after your last spin.');
  end if;
  select prizes into v_prizes from public.spin_prize_config where id = true;
  if jsonb_typeof(v_prizes) <> 'array' then raise exception 'Spin prizes are not configured.'; end if;
  for v_item in select value from jsonb_array_elements(v_prizes)
  loop
    v_total_weight := v_total_weight + greatest(coalesce((v_item->>'weight')::numeric, 0), 0);
  end loop;
  if v_total_weight <= 0 then raise exception 'Spin prizes have no positive weight.'; end if;
  v_target := random() * v_total_weight;
  for v_item in select value from jsonb_array_elements(v_prizes)
  loop
    v_running := v_running + greatest(coalesce((v_item->>'weight')::numeric, 0), 0);
    if v_target < v_running then
      v_prize := v_item;
      exit;
    end if;
  end loop;
  if v_prize is null then v_prize := v_prizes->(jsonb_array_length(v_prizes)-1); end if;
  insert into public.spin_attempts (user_id, spin_date, prize_code)
    values (v_user_id, v_today, v_prize->>'code')
    returning id into v_attempt_id;
  if v_prize->>'type' = 'tryAgain' then
    return jsonb_build_object('ok', true, 'prize', v_prize, 'prizes', v_prizes);
  end if;
  v_value := (v_prize->>'value')::integer;
  loop
    v_suffix := '';
    for v_index in 1..8 loop
      v_suffix := v_suffix || substr(v_alphabet, floor(random() * length(v_alphabet))::integer + 1, 1);
    end loop;
    v_coupon_code := 'RB' || v_value::text || '-' || v_suffix;
    v_coupon_id := null;
    insert into public.coupons (
      user_id, code, discount_percent, max_discount_amount, source, expires_at
    ) values (
      v_user_id, v_coupon_code, v_value,
      coalesce((v_prize->>'maxDiscountAmount')::numeric, 0),
      'spin', clock_timestamp() + interval '30 days'
    ) on conflict do nothing
    returning id into v_coupon_id;
    exit when v_coupon_id is not null;
  end loop;
  update public.spin_attempts set coupon_id = v_coupon_id where id = v_attempt_id;
  return jsonb_build_object(
    'ok', true, 'prize', v_prize, 'prizes', v_prizes,
    'coupon_id', v_coupon_id,
    'coupon_code', v_coupon_code, 'discount_percent', v_value,
    'expires_at', (select expires_at from public.coupons where id = v_coupon_id)
  );
end;
$$;
revoke all on function public.spin_wheel() from public, anon;
grant execute on function public.spin_wheel() to authenticated;

create or replace function public.mark_spin_coupon_copied(p_coupon_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_coupon_code, '')));
begin
  if v_user_id is null then raise exception 'Sign in required'; end if;
  if v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Coupon code is required.');
  end if;
  update public.coupons
    set copied_at = coalesce(copied_at, clock_timestamp())
    where user_id = v_user_id and code = v_code;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Coupon was not found for this account.');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.mark_spin_coupon_copied(text) from public, anon;
grant execute on function public.mark_spin_coupon_copied(text) to authenticated;

commit;
