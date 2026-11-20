-- Scratch-database integration test. Do not run against production.
-- Before running this file in the same SQL session, set:
--   SET app.guest_refund_test = 'enabled';
-- The test inserts temporary auth/users/orders data and rolls it all back.

begin;

do $$
declare
  v_admin_id uuid := gen_random_uuid();
  v_user_id uuid := gen_random_uuid();
  v_admin_email text := 'guest-refund-admin-' || gen_random_uuid()::text || '@example.test';
  v_user_email text := 'guest-refund-user-' || gen_random_uuid()::text || '@example.test';
  v_guest_email text := 'guest-refund-customer-' || gen_random_uuid()::text || '@example.test';
  v_guest_refund_id bigint;
  v_user_refund_id bigint;
  v_unpaid_id bigint;
  v_pending_payment_id bigint;
  v_new_id bigint;
  v_paid_new_id bigint;
  v_software_id bigint;
  v_vps_id bigint;
  v_unsupported_id bigint;
  v_guest_reject_id bigint;
  v_user_reject_id bigint;
  v_result jsonb;
  v_customer text;
  v_count integer;
  v_statuses text[];
  v_balance numeric(12, 2);
  v_utr text;
begin
  if current_setting('app.guest_refund_test', true) is distinct from 'enabled' then
    raise exception 'Refusing to run: enable app.guest_refund_test in this scratch-database session first.';
  end if;

  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (v_admin_id, 'authenticated', 'authenticated', v_admin_email, '', clock_timestamp(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"SQL test admin"}'::jsonb,
      clock_timestamp(), clock_timestamp()),
    (v_user_id, 'authenticated', 'authenticated', v_user_email, '', clock_timestamp(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"SQL test user"}'::jsonb,
      clock_timestamp(), clock_timestamp());

  insert into public.admin_users (id, email) values (v_admin_id, v_admin_email);
  perform set_config('request.jwt.claim.sub', v_admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.wallets (user_id, balance) values (v_user_id, 25.00);

  insert into public.orders (
    user_id, guest_email, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_name, product_type, price, amount, status, payment_method, payment_status
  ) values (
    null, v_guest_email, repeat(md5(gen_random_uuid()::text), 2),
    repeat(md5(gen_random_uuid()::text), 2), repeat(md5(gen_random_uuid()::text), 2),
    'Guest refund test', 'software', 55.00, 55.00, 'completed', 'upi_qr', 'paid'
  ) returning id into v_guest_refund_id;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status
  ) values (
    v_user_id, 'Registered refund test', 'software', 42.50, 42.50,
    'completed', 'upi_qr', 'paid'
  ) returning id into v_user_refund_id;

  v_result := public.admin_refund_order(v_guest_refund_id);
  if v_result ->> 'ok' is distinct from 'false'
     or position('Guest orders cannot be refunded to a wallet' in coalesce(v_result ->> 'message', '')) = 0 then
    raise exception 'Guest refund was not blocked with the expected message: %', v_result;
  end if;
  if (select status from public.orders where id = v_guest_refund_id) is distinct from 'completed'
     or exists (select 1 from public.wallet_transactions where order_id = v_guest_refund_id) then
    raise exception 'Blocked guest refund changed the order or created a wallet transaction.';
  end if;

  v_result := public.admin_refund_order(v_user_refund_id);
  if v_result ->> 'ok' is distinct from 'true'
     or (v_result ->> 'balance')::numeric is distinct from 67.50 then
    raise exception 'Registered refund returned an unexpected result: %', v_result;
  end if;
  select balance into v_balance from public.wallets where user_id = v_user_id;
  if v_balance <> 67.50
     or not exists (
       select 1 from public.wallet_transactions
       where order_id = v_user_refund_id and user_id = v_user_id
         and type = 'refund' and amount = 42.50
     ) then
    raise exception 'Registered refund did not credit the wallet and record its transaction.';
  end if;

  v_utr := left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12);
  insert into public.orders (
    user_id, guest_email, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    null, v_guest_email, repeat(md5(gen_random_uuid()::text), 2),
    repeat(md5(gen_random_uuid()::text), 2), repeat(md5(gen_random_uuid()::text), 2),
    'Guest new request test', 'software', 10.00, 10.00, 'new', 'upi_qr', 'pending',
    v_utr, clock_timestamp()
  ) returning id into v_new_id;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    v_user_id, 'Paid new request test', 'software', 13.00, 13.00, 'new', 'upi_qr', 'paid',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  ) returning id into v_paid_new_id;

  insert into public.orders (
    user_id, guest_email, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_name, product_type, price, amount, status, payment_method, payment_status
  ) values
    (null, v_guest_email, repeat(md5(gen_random_uuid()::text), 2),
      repeat(md5(gen_random_uuid()::text), 2), repeat(md5(gen_random_uuid()::text), 2),
      'Guest unpaid request test', 'software', 11.00, 11.00, 'unpaid', 'upi_qr', 'pending')
  returning id into v_unpaid_id;

  insert into public.orders (
    user_id, guest_email, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_name, product_type, price, amount, status, payment_method, payment_status
  ) values (
    null, v_guest_email, repeat(md5(gen_random_uuid()::text), 2),
    repeat(md5(gen_random_uuid()::text), 2), repeat(md5(gen_random_uuid()::text), 2),
    'Guest pending-payment request test', 'software', 12.00, 12.00, 'pending_payment', 'upi_qr', 'pending'
  )
  returning id into v_pending_payment_id;

  select customer into v_customer
  from public.admin_list_order_requests('all', v_guest_email, 1, 50)
  where id = v_new_id;
  if v_customer is distinct from v_guest_email then
    raise exception 'Guest order list did not return the guest email; got %.', v_customer;
  end if;

  select array_agg(distinct status) into v_statuses
  from public.admin_list_order_requests('all', v_guest_email, 1, 50)
  where id in (v_new_id, v_unpaid_id, v_pending_payment_id);
  if not ('new' = any(coalesce(v_statuses, array[]::text[])))
     or 'unpaid' = any(coalesce(v_statuses, array[]::text[]))
     or 'pending_payment' = any(coalesce(v_statuses, array[]::text[])) then
    raise exception 'Order request list returned unexpected statuses: %', v_statuses;
  end if;

  select count(*) into v_count
  from public.admin_list_order_requests('all', v_guest_email, 1, 50)
  where id in (v_unpaid_id, v_pending_payment_id);
  if v_count <> 0 then raise exception 'Unpaid or pending-payment orders were returned: % rows.', v_count; end if;

  select count(*) into v_count
  from public.admin_list_order_requests('new', v_guest_email, 1, 50)
  where id = v_new_id;
  if v_count <> 1 then raise exception 'New status filter did not return the guest order.'; end if;

  select count(*) into v_count
  from public.admin_list_order_requests('all', v_paid_new_id::text, 1, 50)
  where id = v_paid_new_id and status = 'new';
  if v_count <> 1 then raise exception 'Paid/new request was not returned.'; end if;

  if exists (
    select 1 from public.admin_list_orders()
    where id in (v_new_id, v_paid_new_id, v_unpaid_id, v_pending_payment_id)
  ) then
    raise exception 'Legacy admin order list unexpectedly included an unpaid, pending-payment, or new order.';
  end if;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    v_user_id, 'Software completion test', 'software', 20.00, 20.00, 'new', 'upi_qr', 'pending',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  )
  returning id into v_software_id;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    v_user_id, 'VPS completion test', 'vps', 30.00, 30.00, 'new', 'upi_qr', 'pending',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  ) returning id into v_vps_id;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    v_user_id, 'Unsupported completion test', 'proxy', 40.00, 40.00, 'new', 'upi_qr', 'pending',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  ) returning id into v_unsupported_id;

  insert into private.order_delivery_secrets (id, encryption_key)
  values (true, 'guest-refund-test-key')
  on conflict (id) do nothing;

  v_result := public.admin_complete_order(v_software_id, jsonb_build_object(
    'software_name', 'Test software', 'license_key', 'test-license',
    'download_link', 'https://example.test/download'
  ));
  if v_result ->> 'ok' is distinct from 'true'
     or (select status from public.orders where id = v_software_id) is distinct from 'completed' then
    raise exception 'Software completion failed: %', v_result;
  end if;

  v_result := public.admin_complete_order(v_vps_id, jsonb_build_object(
    'vps_ip', '192.0.2.10', 'vps_port', 22, 'vps_username', 'test-user',
    'vps_password', 'test-password', 'vps_storage_gb', 100
  ));
  if v_result ->> 'ok' is distinct from 'true'
     or (select status from public.orders where id = v_vps_id) is distinct from 'completed' then
    raise exception 'VPS completion failed: %', v_result;
  end if;

  v_result := public.admin_complete_order(v_unsupported_id, '{}'::jsonb);
  if v_result ->> 'ok' is distinct from 'false'
     or (select status from public.orders where id = v_unsupported_id) is distinct from 'new' then
    raise exception 'Unsupported product type was completed: %', v_result;
  end if;

  insert into public.orders (
    user_id, guest_email, guest_access_hash, guest_device_hash, guest_ip_hash,
    product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    null, v_guest_email, repeat(md5(gen_random_uuid()::text), 2),
    repeat(md5(gen_random_uuid()::text), 2), repeat(md5(gen_random_uuid()::text), 2),
    'Guest rejection test', 'software', 15.00, 15.00, 'new', 'upi_qr', 'pending',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  ) returning id into v_guest_reject_id;

  insert into public.orders (
    user_id, product_name, product_type, price, amount, status, payment_method, payment_status,
    utr_number, payment_submitted_at
  ) values (
    v_user_id, 'Registered rejection test', 'software', 16.00, 16.00, 'new', 'upi_qr', 'pending',
    left(translate(replace(gen_random_uuid()::text, '-', ''), 'abcdef', '123456'), 12), clock_timestamp()
  ) returning id into v_user_reject_id;

  v_result := public.admin_reject_order_request(v_guest_reject_id, 'Guest rejection test');
  if v_result ->> 'ok' is distinct from 'true'
     or (select status from public.orders where id = v_guest_reject_id) is distinct from 'rejected' then
    raise exception 'Guest order rejection failed: %', v_result;
  end if;

  v_result := public.admin_reject_order_request(v_user_reject_id, 'Registered rejection test');
  if v_result ->> 'ok' is distinct from 'true'
     or (select status from public.orders where id = v_user_reject_id) is distinct from 'rejected' then
    raise exception 'Registered order rejection failed: %', v_result;
  end if;
end;
$$;

rollback;
