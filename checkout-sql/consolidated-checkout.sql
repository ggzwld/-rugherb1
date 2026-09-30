begin;

create or replace function public.checkout_currency_minor_units(target_currency text)
returns smallint
language sql
immutable
set search_path = pg_catalog
as $$
  select case upper(btrim(target_currency))
    when 'BIF' then 0
    when 'CLP' then 0
    when 'DJF' then 0
    when 'GNF' then 0
    when 'JPY' then 0
    when 'KMF' then 0
    when 'KRW' then 0
    when 'PYG' then 0
    when 'RWF' then 0
    when 'UGX' then 0
    when 'VND' then 0
    when 'VUV' then 0
    when 'XAF' then 0
    when 'XOF' then 0
    when 'XPF' then 0
    when 'USD' then 2
    when 'EUR' then 2
    when 'GBP' then 2
    when 'CAD' then 2
    when 'AUD' then 2
    when 'CHF' then 2
    when 'CNY' then 2
    when 'INR' then 2
    when 'KES' then 2
    when 'TZS' then 2
    when 'CDF' then 2
    when 'ZAR' then 2
    when 'AED' then 2
    when 'SGD' then 2
    else null
  end::smallint;
$$;

revoke all on function public.checkout_currency_minor_units(text) from public, anon, authenticated;
grant execute on function public.checkout_currency_minor_units(text) to authenticated, service_role;

create or replace function public.validate_menu_item_checkout_price()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  minor_units integer;
begin
  minor_units := public.checkout_currency_minor_units(new.currency);
  if minor_units is null then raise exception 'Menu item currency is not supported for checkout'; end if;
  if new.price::text in ('NaN', 'Infinity', '-Infinity') or new.price < 0
     or new.price <> round(new.price, minor_units) then
    raise exception 'Menu item price does not match its currency precision';
  end if;
  if new.original_price is not null and (
    new.original_price::text in ('NaN', 'Infinity', '-Infinity')
    or new.original_price < new.price
    or new.original_price <> round(new.original_price, minor_units)
  ) then
    raise exception 'Menu item original price is invalid';
  end if;
  return new;
end;
$$;
revoke all on function public.validate_menu_item_checkout_price() from public, anon, authenticated;
drop trigger if exists menu_item_checkout_price_validation on public.menu_items;
create trigger menu_item_checkout_price_validation
before insert or update of currency, price, original_price on public.menu_items
for each row execute function public.validate_menu_item_checkout_price();

alter table public.menu_orders
  add column if not exists pricing_version smallint not null default 0,
  add column if not exists checkout_idempotency_key uuid,
  add column if not exists checkout_request jsonb;

create unique index if not exists menu_orders_checkout_idempotency_key
  on public.menu_orders (user_id, checkout_idempotency_key)
  where checkout_idempotency_key is not null;

alter table public.menu_orders
  drop constraint if exists menu_orders_secure_total_check;
alter table public.menu_orders
  add constraint menu_orders_secure_total_check
  check (
    pricing_version <> 1 or (
      public.checkout_currency_minor_units(currency) is not null
      and subtotal::text not in ('NaN', 'Infinity', '-Infinity')
      and tax_amount::text not in ('NaN', 'Infinity', '-Infinity')
      and service_fee::text not in ('NaN', 'Infinity', '-Infinity')
      and tip_amount::text not in ('NaN', 'Infinity', '-Infinity')
      and total_amount::text not in ('NaN', 'Infinity', '-Infinity')
      and subtotal >= 0 and tax_amount >= 0 and service_fee >= 0 and tip_amount >= 0
      and points_discount = 0
      and subtotal = round(subtotal, public.checkout_currency_minor_units(currency))
      and tax_amount = round(tax_amount, public.checkout_currency_minor_units(currency))
      and service_fee = round(service_fee, public.checkout_currency_minor_units(currency))
      and tip_amount = round(tip_amount, public.checkout_currency_minor_units(currency))
      and total_amount = round(total_amount, public.checkout_currency_minor_units(currency))
      and total_amount = round(subtotal + tax_amount + service_fee + tip_amount - points_discount,
        public.checkout_currency_minor_units(currency))
    )
  ) not valid;

alter table public.menu_order_items
  drop constraint if exists menu_order_items_secure_line_total_check;
alter table public.menu_order_items
  add constraint menu_order_items_secure_line_total_check
  check (quantity > 0) not valid;

create or replace function public.validate_menu_order_item_checkout_amount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
  minor_units integer;
begin
  select * into selected_order from public.menu_orders where id = new.order_id;
  if not found or new.quantity <= 0
     or new.unit_price::text in ('NaN', 'Infinity', '-Infinity')
     or new.line_total::text in ('NaN', 'Infinity', '-Infinity')
     or new.unit_price < 0
     or new.line_total <> new.unit_price * new.quantity then
    raise exception 'Menu order line amount is invalid';
  end if;
  if selected_order.pricing_version = 1 then
    minor_units := public.checkout_currency_minor_units(selected_order.currency);
    if minor_units is null
       or new.unit_price <> round(new.unit_price, minor_units)
       or new.line_total <> round(new.line_total, minor_units) then
      raise exception 'Menu order line does not match currency precision';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.validate_menu_order_item_checkout_amount() from public, anon, authenticated;
drop trigger if exists menu_order_item_checkout_amount_validation on public.menu_order_items;
create trigger menu_order_item_checkout_amount_validation
before insert or update of order_id, unit_price, quantity, line_total on public.menu_order_items
for each row execute function public.validate_menu_order_item_checkout_amount();

create or replace function public.validate_menu_payment_attempt_total()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
begin
  select * into selected_order from public.menu_orders where id = new.order_id;
  if not found or selected_order.pricing_version <> 1
     or new.amount::text in ('NaN', 'Infinity', '-Infinity')
     or new.amount <> selected_order.total_amount
     or upper(new.currency) <> upper(selected_order.currency)
     or public.checkout_currency_minor_units(new.currency) is null
     or new.amount <> round(new.amount, public.checkout_currency_minor_units(new.currency))
     or new.amount <= 0 then
    raise exception 'Menu payment attempt does not match a secure order total';
  end if;
  return new;
end;
$$;
revoke all on function public.validate_menu_payment_attempt_total() from public, anon, authenticated;
drop trigger if exists menu_payment_attempt_total_validation on public.menu_payment_attempts;
create trigger menu_payment_attempt_total_validation
before insert or update of order_id, amount, currency on public.menu_payment_attempts
for each row execute function public.validate_menu_payment_attempt_total();

create or replace function public.create_menu_order(
  target_user_id uuid,
  target_items jsonb,
  target_order_type text,
  target_payment_method text,
  target_tip_amount numeric,
  target_customer jsonb,
  target_cart_id uuid,
  target_idempotency_key uuid
)
returns table (
  order_id uuid,
  order_number text,
  currency text,
  subtotal numeric,
  tax_amount numeric,
  service_fee numeric,
  tip_amount numeric,
  points_discount numeric,
  total_amount numeric
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  existing_order public.menu_orders%rowtype;
  selected_item public.menu_items%rowtype;
  requested_item jsonb;
  item_id uuid;
  item_quantity integer;
  item_unit_price numeric;
  item_currency text;
  item_decimals integer;
  item_count integer := 0;
  seen_item_ids uuid[] := '{}';
  fingerprint_items jsonb := '[]'::jsonb;
  cart_fingerprint jsonb;
  priced_items jsonb := '[]'::jsonb;
  request_fingerprint jsonb;
  customer_name text;
  customer_email text;
  customer_phone text;
  order_uuid uuid;
  generated_order_number text;
  subtotal_value numeric := 0;
  tax_value numeric := 0;
  fee_value numeric := 0;
  tip_value numeric := 0;
  total_value numeric := 0;
  affected_rows integer;
begin
  if target_user_id is null or target_idempotency_key is null then
    raise exception 'Checkout credentials are invalid';
  end if;
  if target_order_type is null or target_order_type not in ('delivery', 'take-away', 'dine-in', 'room-service') then
    raise exception 'Order type is invalid';
  end if;
  if target_payment_method is null or target_payment_method not in ('card', 'mobile-money', 'room-charge', 'cash') then
    raise exception 'Payment method is invalid';
  end if;
  if target_items is null or jsonb_typeof(target_items) is distinct from 'array' then
    raise exception 'Select between one and fifty menu items';
  end if;
  if jsonb_array_length(target_items) < 1 or jsonb_array_length(target_items) > 50 then
    raise exception 'Select between one and fifty menu items';
  end if;
  if target_customer is null or jsonb_typeof(target_customer) is distinct from 'object' then
    raise exception 'Customer details are invalid';
  end if;
  customer_name := nullif(trim(concat_ws(' ', target_customer->>'firstName', target_customer->>'lastName')), '');
  customer_email := nullif(lower(trim(target_customer->>'email')), '');
  customer_phone := nullif(trim(target_customer->>'phone'), '');
  if coalesce(length(target_customer->>'firstName'), 0) > 100
     or coalesce(length(target_customer->>'lastName'), 0) > 100
     or coalesce(length(target_customer->>'email'), 0) > 254
     or coalesce(length(target_customer->>'phone'), 0) > 40
     or coalesce(length(target_customer->>'roomNumber'), 0) > 40
     or coalesce(length(target_customer->>'deliveryAddress'), 0) > 500
     or coalesce(length(target_customer->>'specialRequests'), 0) > 2000 then
    raise exception 'Customer details are too long';
  end if;
  if target_payment_method in ('card', 'mobile-money') and (customer_email is null or customer_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'A valid email address is required for online payment';
  end if;
  if nullif(trim(target_customer->>'firstName'), '') is null
     or nullif(trim(target_customer->>'lastName'), '') is null
     or customer_name is null or customer_phone is null then
    raise exception 'Customer name and phone are required';
  end if;
  if target_order_type = 'room-service' and nullif(trim(target_customer->>'roomNumber'), '') is null then
    raise exception 'Room number is required for room service';
  end if;
  if target_order_type = 'delivery' and nullif(trim(target_customer->>'deliveryAddress'), '') is null then
    raise exception 'Delivery address is required for delivery';
  end if;
  if target_tip_amount is null or target_tip_amount::text in ('NaN', 'Infinity', '-Infinity')
     or target_tip_amount < 0 or target_tip_amount > 100000000 then
    raise exception 'Tip amount is invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_user_id::text || target_idempotency_key::text, 0));

  for requested_item in
    select value from jsonb_array_elements(target_items)
    order by value->>'menuItemId'
  loop
    if coalesce(requested_item->>'menuItemId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(requested_item->>'quantity', '') !~ '^[1-9][0-9]*$' then
      raise exception 'A menu item or quantity is invalid';
    end if;
    item_id := (requested_item->>'menuItemId')::uuid;
    item_quantity := (requested_item->>'quantity')::integer;
    if item_quantity > 1000 or item_id = any(seen_item_ids) then
      raise exception 'Menu item quantity or selection is invalid';
    end if;
    seen_item_ids := array_append(seen_item_ids, item_id);
    fingerprint_items := fingerprint_items || jsonb_build_array(jsonb_build_object('menuItemId', item_id, 'quantity', item_quantity));
    item_count := item_count + 1;
  end loop;

  request_fingerprint := jsonb_build_object(
    'items', fingerprint_items,
    'orderType', target_order_type,
    'paymentMethod', target_payment_method,
    'tipAmount', target_tip_amount,
    'customer', jsonb_build_object(
      'firstName', trim(target_customer->>'firstName'),
      'lastName', trim(target_customer->>'lastName'),
      'email', customer_email,
      'phone', customer_phone,
      'roomNumber', nullif(trim(target_customer->>'roomNumber'), ''),
      'deliveryAddress', nullif(trim(target_customer->>'deliveryAddress'), ''),
      'specialRequests', nullif(trim(target_customer->>'specialRequests'), '')
    ),
    'cartId', target_cart_id
  );

  select * into existing_order
  from public.menu_orders
  where user_id = target_user_id and checkout_idempotency_key = target_idempotency_key
  for update;
  if found then
    if existing_order.checkout_request is distinct from request_fingerprint then
      raise exception 'Checkout key was already used for different order details';
    end if;
    return query select existing_order.id, existing_order.order_number, existing_order.currency,
      existing_order.subtotal, existing_order.tax_amount, existing_order.service_fee,
      existing_order.tip_amount, existing_order.points_discount, existing_order.total_amount;
    return;
  end if;

  if target_cart_id is not null then
    perform 1 from public.menu_carts
     where id = target_cart_id and user_id = target_user_id and status = 'active'
     for update;
    if not found then raise exception 'The saved menu cart is no longer active'; end if;
    perform 1 from public.menu_cart_items
     where cart_id = target_cart_id
     order by menu_item_id
     for update;
    select coalesce(jsonb_agg(jsonb_build_object('menuItemId', menu_item_id, 'quantity', quantity) order by menu_item_id), '[]'::jsonb)
      into cart_fingerprint
      from public.menu_cart_items
     where cart_id = target_cart_id;
    if cart_fingerprint is distinct from fingerprint_items then
      raise exception 'The saved menu cart changed. Review your items and try again.';
    end if;
  end if;

  for requested_item in
    select value from jsonb_array_elements(target_items)
    order by value->>'menuItemId'
  loop
    item_id := (requested_item->>'menuItemId')::uuid;
    item_quantity := (requested_item->>'quantity')::integer;
    select * into selected_item
    from public.menu_items
    where id = item_id and is_published
    for share;
    if not found then raise exception 'A selected menu item is no longer available'; end if;
    if selected_item.price::text in ('NaN', 'Infinity', '-Infinity') or selected_item.price < 0 then
      raise exception 'A menu item has an invalid price';
    end if;
    item_currency := upper(trim(selected_item.currency));
    item_decimals := public.checkout_currency_minor_units(item_currency);
    if item_decimals is null then raise exception 'A menu item has an unsupported checkout currency'; end if;
    if selected_item.price <> round(selected_item.price, item_decimals)
       or (selected_item.original_price is not null and selected_item.original_price <> round(selected_item.original_price, item_decimals)) then
      raise exception 'A menu item price does not match its currency precision';
    end if;
    if item_count > 0 and item_currency <> (priced_items->0->>'currency') then
      raise exception 'Checkout items must use one currency';
    end if;
    item_unit_price := selected_item.price;
    subtotal_value := subtotal_value + item_unit_price * item_quantity;
    priced_items := priced_items || jsonb_build_array(jsonb_build_object(
      'id', selected_item.id,
      'name', selected_item.name,
      'quantity', item_quantity,
      'unitPrice', item_unit_price,
      'currency', item_currency
    ));
  end loop;

  item_currency := priced_items->0->>'currency';
  item_decimals := public.checkout_currency_minor_units(item_currency);
  if target_payment_method = 'mobile-money' and item_currency <> 'UGX' then
    raise exception 'Mobile Money is available only for UGX orders';
  end if;
  if target_tip_amount <> round(target_tip_amount, item_decimals) then
    raise exception 'Tip amount does not match the order currency precision';
  end if;

  subtotal_value := round(subtotal_value, item_decimals);
  tax_value := round(subtotal_value * 0.08, item_decimals);
  fee_value := case target_order_type when 'room-service' then 5 when 'delivery' then 8 else 0 end;
  fee_value := round(fee_value, item_decimals);
  tip_value := round(target_tip_amount, item_decimals);
  total_value := round(subtotal_value + tax_value + fee_value + tip_value, item_decimals);
  order_uuid := gen_random_uuid();
  generated_order_number := 'SH' || upper(substr(replace(order_uuid::text, '-', ''), 1, 12));

  insert into public.menu_orders (
    id, order_number, user_id, order_type, status, payment_method, payment_status,
    first_name, last_name, email, phone, room_number, delivery_address, special_requests,
    subtotal, tax_amount, service_fee, tip_amount, points_discount, total_amount, currency,
    checkout_idempotency_key, checkout_request, pricing_version
  ) values (
    order_uuid, generated_order_number, target_user_id, target_order_type, 'pending', target_payment_method, 'pending',
    trim(target_customer->>'firstName'), trim(target_customer->>'lastName'), customer_email, customer_phone,
    nullif(trim(target_customer->>'roomNumber'), ''), nullif(trim(target_customer->>'deliveryAddress'), ''),
    nullif(trim(target_customer->>'specialRequests'), ''), subtotal_value, tax_value, fee_value,
    tip_value, 0, total_value, item_currency, target_idempotency_key, request_fingerprint, 1
  );

  for requested_item in select value from jsonb_array_elements(priced_items)
  loop
    insert into public.menu_order_items (order_id, menu_item_id, item_name, unit_price, quantity, line_total)
    values (
      order_uuid,
      (requested_item->>'id')::uuid,
      requested_item->>'name',
      (requested_item->>'unitPrice')::numeric,
      (requested_item->>'quantity')::integer,
      (requested_item->>'unitPrice')::numeric * (requested_item->>'quantity')::integer
    );
  end loop;

  if target_cart_id is not null then
    update public.menu_carts
       set status = 'converted', order_id = order_uuid, updated_at = now()
     where id = target_cart_id and user_id = target_user_id and status = 'active';
    get diagnostics affected_rows = row_count;
    if affected_rows <> 1 then raise exception 'The saved menu cart is no longer active'; end if;
  end if;

  return query select order_uuid, generated_order_number, item_currency, subtotal_value,
    tax_value, fee_value, tip_value, 0::numeric, total_value;
end;
$$;

revoke all on function public.create_menu_order(uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_menu_order(uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) to service_role;

alter table public.menu_payment_attempts
  drop constraint if exists menu_payment_attempts_status_check;
alter table public.menu_payment_attempts
  add constraint menu_payment_attempts_status_check
  check (status in ('initiated', 'redirected', 'completed', 'failed', 'cancelled', 'manual_review')) not valid;

with ranked_attempts as (
  select id, row_number() over (partition by order_id order by created_at desc, id desc) as attempt_rank
    from public.menu_payment_attempts
   where status in ('initiated', 'redirected')
)
update public.menu_payment_attempts attempt
   set status = 'failed',
       failure_reason = coalesce(attempt.failure_reason, 'Superseded duplicate active checkout attempt'),
       updated_at = now()
  from ranked_attempts ranked
 where ranked.id = attempt.id and ranked.attempt_rank > 1;

create unique index if not exists menu_payment_attempts_one_active_per_order
  on public.menu_payment_attempts (order_id)
  where status in ('initiated', 'redirected');

create table if not exists public.menu_duplicate_payment_captures (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.menu_orders(id) on delete restrict,
  payment_attempt_id uuid not null references public.menu_payment_attempts(id) on delete restrict,
  transaction_id text not null unique,
  tx_ref text not null,
  amount numeric(20,4) not null check (amount > 0 and amount::text not in ('NaN', 'Infinity', '-Infinity')),
  currency text not null check (public.checkout_currency_minor_units(currency) is not null),
  status text not null default 'manual_review' check (status in ('manual_review', 'refunded', 'resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (amount = round(amount, public.checkout_currency_minor_units(currency)))
);

alter table public.menu_duplicate_payment_captures enable row level security;
revoke all on public.menu_duplicate_payment_captures from public, anon, authenticated;
grant select on public.menu_duplicate_payment_captures to authenticated;
grant all on public.menu_duplicate_payment_captures to service_role;
drop policy if exists menu_duplicate_payment_captures_manager_read on public.menu_duplicate_payment_captures;
create policy menu_duplicate_payment_captures_manager_read
  on public.menu_duplicate_payment_captures for select to authenticated
  using (exists (
    select 1 from public.user_profiles up
     where up.user_id = auth.uid() and up.role in ('manager', 'admin')
  ));

create or replace function public.record_menu_duplicate_payment_capture()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
begin
  if new.status <> 'manual_review' or new.transaction_id is null then return new; end if;
  select * into selected_order from public.menu_orders where id = new.order_id;
  if found and selected_order.payment_status = 'paid'
     and selected_order.flutterwave_transaction_id is distinct from new.transaction_id then
    insert into public.menu_duplicate_payment_captures (
      order_id, payment_attempt_id, transaction_id, tx_ref, amount, currency
    ) values (
      selected_order.id, new.id, new.transaction_id, new.tx_ref, new.amount, new.currency
    ) on conflict (transaction_id) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.record_menu_duplicate_payment_capture() from public, anon, authenticated;
drop trigger if exists menu_duplicate_payment_capture_record on public.menu_payment_attempts;
create trigger menu_duplicate_payment_capture_record
  after insert or update of status, transaction_id on public.menu_payment_attempts
  for each row execute function public.record_menu_duplicate_payment_capture();

create or replace function public.create_menu_payment_attempt(
  target_order_id uuid,
  target_user_id uuid,
  target_tx_ref text
)
returns table (attempt_id uuid, attempt_tx_ref text, attempt_status text, attempt_payment_url text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
  selected_attempt public.menu_payment_attempts%rowtype;
  created_attempt public.menu_payment_attempts%rowtype;
begin
  select * into selected_order
  from public.menu_orders
  where id = target_order_id
  for update;
  if not found or selected_order.user_id <> target_user_id then
    raise exception 'Payment order could not be verified';
  end if;
  if selected_order.pricing_version <> 1 then
    raise exception 'This order predates secure pricing. Recreate the order to continue.';
  end if;
  if selected_order.status <> 'pending' or selected_order.payment_status not in ('pending', 'cancelled', 'failed') then
    raise exception 'This order is no longer awaiting payment';
  end if;
  if selected_order.total_amount <= 0 then
    raise exception 'This order does not require online payment';
  end if;

  select * into selected_attempt
  from public.menu_payment_attempts
  where order_id = selected_order.id and status in ('initiated', 'redirected')
  order by created_at desc
  limit 1
  for update;
  if found then
    if selected_attempt.status = 'redirected' and selected_attempt.payment_url is not null then
      return query select selected_attempt.id, selected_attempt.tx_ref, selected_attempt.status, selected_attempt.payment_url;
      return;
    end if;
    if selected_attempt.created_at > now() - interval '2 minutes' then
      return query select selected_attempt.id, selected_attempt.tx_ref, 'preparing'::text, selected_attempt.payment_url;
      return;
    end if;
    update public.menu_payment_attempts
       set status = 'failed', failure_reason = 'Checkout preparation timed out', updated_at = now()
     where id = selected_attempt.id;
  end if;

  insert into public.menu_payment_attempts (order_id, tx_ref, amount, currency, status)
  values (selected_order.id, target_tx_ref, selected_order.total_amount, selected_order.currency, 'initiated')
  returning * into created_attempt;
  update public.menu_orders
     set payment_reference = created_attempt.tx_ref, payment_status = 'pending'
   where id = selected_order.id;
  return query select created_attempt.id, created_attempt.tx_ref, created_attempt.status, created_attempt.payment_url;
end;
$$;

revoke all on function public.create_menu_payment_attempt(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.create_menu_payment_attempt(uuid, uuid, text) to service_role;
alter table public.menu_orders enable row level security;
alter table public.menu_order_items enable row level security;
revoke all on public.menu_orders, public.menu_order_items from public, anon, authenticated;
grant select on public.menu_orders, public.menu_order_items to authenticated;
drop policy if exists menu_orders_owner_select on public.menu_orders;
create policy menu_orders_owner_select
  on public.menu_orders for select to authenticated
  using (user_id = auth.uid());
drop policy if exists menu_order_items_owner_select on public.menu_order_items;
create policy menu_order_items_owner_select
  on public.menu_order_items for select to authenticated
  using (exists (
    select 1 from public.menu_orders mo
     where mo.id = menu_order_items.order_id and mo.user_id = auth.uid()
  ));

create or replace function public.apply_menu_invoice_totals()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
  order_number_value text;
begin
  select * into selected_order
    from public.menu_orders
   where books_invoice_id = new.id and pricing_version = 1;
  if not found and left(new.invoice_number, 5) = 'MENU-' then
    order_number_value := substring(new.invoice_number from 6);
    select * into selected_order
      from public.menu_orders
     where order_number = order_number_value and pricing_version = 1;
  end if;
  if not found then return new; end if;
  if selected_order.points_discount <> 0 then
    raise exception 'This menu order has an unsupported points discount';
  end if;

  new.currency_code := upper(selected_order.currency)::char(3);
  new.subtotal := selected_order.subtotal;
  new.tax_amount := selected_order.tax_amount;
  new.other_charges := selected_order.service_fee + selected_order.tip_amount;
  new.total := new.subtotal + new.tax_amount + new.other_charges;
  if new.total <> selected_order.total_amount then
    raise exception 'Menu invoice total does not match the verified order';
  end if;
  return new;
end;
$$;

revoke all on function public.apply_menu_invoice_totals() from public, anon, authenticated;
drop trigger if exists menu_invoice_totals_before_insert on public.books_invoices;
drop trigger if exists zzz_menu_invoice_totals_before_insert on public.books_invoices;
drop trigger if exists zzz_menu_invoice_totals_before_write on public.books_invoices;
create trigger zzz_menu_invoice_totals_before_write
before insert or update on public.books_invoices
for each row execute function public.apply_menu_invoice_totals();

create or replace function public.add_menu_invoice_charge_lines()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_order public.menu_orders%rowtype;
begin
  if left(new.invoice_number, 5) <> 'MENU-' then
    return new;
  end if;
  select * into selected_order
    from public.menu_orders
   where order_number = substring(new.invoice_number from 6) and pricing_version = 1;
  if not found then return new; end if;
  insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
  select new.id, new.organization_id, item_name, quantity, unit_price
    from public.menu_order_items
   where order_id = selected_order.id;
  if selected_order.service_fee > 0 then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    values (new.id, new.organization_id, 'Service fee', 1, selected_order.service_fee);
  end if;
  if selected_order.tip_amount > 0 then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    values (new.id, new.organization_id, 'Tip', 1, selected_order.tip_amount);
  end if;
  return new;
end;
$$;

revoke all on function public.add_menu_invoice_charge_lines() from public, anon, authenticated;
drop trigger if exists menu_invoice_charge_lines_after_insert on public.books_invoices;
create trigger menu_invoice_charge_lines_after_insert
after insert on public.books_invoices
for each row execute function public.add_menu_invoice_charge_lines();

notify pgrst, 'reload schema';


alter table public.special_event_bookings
  add column if not exists checkout_request jsonb;
alter table public.special_event_bookings enable row level security;
alter table public.special_event_payment_attempts enable row level security;
revoke all on public.special_event_bookings, public.special_event_payment_attempts from public, anon, authenticated;
grant select on public.special_event_bookings to authenticated;
drop policy if exists special_event_bookings_owner_or_manager_select on public.special_event_bookings;
create policy special_event_bookings_owner_or_manager_select
  on public.special_event_bookings for select to authenticated
  using (user_id = auth.uid() or public.is_special_event_manager(event_id));

create table if not exists public.special_event_duplicate_captures (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete restrict,
  booking_id uuid not null references public.special_event_bookings(id) on delete restrict,
  payment_attempt_id uuid not null references public.special_event_payment_attempts(id) on delete restrict,
  transaction_id text not null unique,
  tx_ref text not null,
  amount numeric(12,2) not null check (amount > 0 and amount::text not in ('NaN', 'Infinity', '-Infinity')),
  currency text not null check (char_length(currency) = 3 and public.checkout_currency_minor_units(currency) is not null),
  status text not null default 'manual_review' check (status in ('manual_review', 'refunded', 'resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (amount = round(amount, public.checkout_currency_minor_units(currency)))
);

alter table public.special_event_duplicate_captures enable row level security;
revoke all on public.special_event_duplicate_captures from public, anon, authenticated;
grant select on public.special_event_duplicate_captures to authenticated;
grant all on public.special_event_duplicate_captures to service_role;
drop policy if exists special_event_duplicate_captures_manager_read on public.special_event_duplicate_captures;
create policy special_event_duplicate_captures_manager_read
  on public.special_event_duplicate_captures
  for select to authenticated
  using (public.is_special_event_manager(event_id));
grant select on public.special_event_duplicate_captures to authenticated;

alter table public.special_event_bookings
  drop constraint if exists special_event_bookings_secure_total_check;
alter table public.special_event_bookings
  add constraint special_event_bookings_secure_total_check
  check (
    public.checkout_currency_minor_units(currency) is not null
    and subtotal::text not in ('NaN', 'Infinity', '-Infinity')
    and service_fee::text not in ('NaN', 'Infinity', '-Infinity')
    and tax_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and discount_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and total_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and subtotal >= 0 and service_fee >= 0 and tax_amount >= 0
    and discount_amount >= 0 and discount_amount <= subtotal + service_fee + tax_amount
    and subtotal = round(subtotal, public.checkout_currency_minor_units(currency))
    and service_fee = round(service_fee, public.checkout_currency_minor_units(currency))
    and tax_amount = round(tax_amount, public.checkout_currency_minor_units(currency))
    and discount_amount = round(discount_amount, public.checkout_currency_minor_units(currency))
    and total_amount = round(total_amount, public.checkout_currency_minor_units(currency))
    and total_amount = round(subtotal + service_fee + tax_amount - discount_amount,
      public.checkout_currency_minor_units(currency))
  ) not valid;

create or replace function public.validate_special_event_payment_attempt_total()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_booking public.special_event_bookings%rowtype;
begin
  select * into selected_booking from public.special_event_bookings where id = new.booking_id;
  if not found or new.amount::text in ('NaN', 'Infinity', '-Infinity')
     or new.amount <> selected_booking.total_amount
     or upper(new.currency) <> upper(selected_booking.currency)
     or public.checkout_currency_minor_units(new.currency) is null
     or new.amount <> round(new.amount, public.checkout_currency_minor_units(new.currency))
     or new.amount <= 0 then
    raise exception 'Event payment attempt does not match its stored booking total';
  end if;
  return new;
end;
$$;
revoke all on function public.validate_special_event_payment_attempt_total() from public, anon, authenticated;
drop trigger if exists special_event_payment_attempt_total_validation on public.special_event_payment_attempts;
create trigger special_event_payment_attempt_total_validation
before insert or update of booking_id, amount, currency on public.special_event_payment_attempts
for each row execute function public.validate_special_event_payment_attempt_total();

drop trigger if exists special_event_ticket_price_precision on public.special_event_ticket_types;
drop function if exists public.enforce_special_event_ticket_price_precision();
create function public.enforce_special_event_ticket_price_precision()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_currency text;
begin
  select upper(trim(currency)) into selected_currency
    from public.special_events
   where id = new.event_id;
  if public.checkout_currency_minor_units(selected_currency) is null then
    raise exception 'Event currency is not supported for checkout';
  end if;
  if new.price::text in ('NaN', 'Infinity', '-Infinity') or new.price < 0 then
    raise exception 'Ticket price must be a finite non-negative amount';
  end if;
  if new.price <> round(new.price, public.checkout_currency_minor_units(selected_currency)) then
    raise exception 'Ticket price does not match the currency precision for %', selected_currency;
  end if;
  return new;
end;
$$;
create trigger special_event_ticket_price_precision
before insert or update of event_id, price on public.special_event_ticket_types
for each row execute function public.enforce_special_event_ticket_price_precision();
revoke all on function public.enforce_special_event_ticket_price_precision() from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.special_events'::regclass
       and conname = 'special_events_checkout_currency_precision_check'
  ) then
    alter table public.special_events
      add constraint special_events_checkout_currency_precision_check
      check (
        public.checkout_currency_minor_units(currency) is not null
        and price::text not in ('NaN', 'Infinity', '-Infinity')
        and price >= 0
        and price = round(price, public.checkout_currency_minor_units(currency))
      ) not valid;
  end if;
end;
$$;

create or replace function public.prevent_invalid_special_event_currency_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  minor_units integer;
begin
  minor_units := public.checkout_currency_minor_units(new.currency);
  if minor_units is null then
    raise exception 'Event currency is not supported for checkout';
  end if;
  if new.price <> round(new.price, minor_units) or exists (
    select 1
      from public.special_event_ticket_types ticket_type
     where ticket_type.event_id = new.id
       and ticket_type.price <> round(ticket_type.price, minor_units)
  ) then
    raise exception 'Event currency change would invalidate an existing ticket price';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_invalid_special_event_currency_change() from public, anon, authenticated;
drop trigger if exists special_event_currency_precision on public.special_events;
create trigger special_event_currency_precision
before update of currency on public.special_events
for each row execute function public.prevent_invalid_special_event_currency_change();

create or replace function public.create_special_event_booking(
  target_event_id uuid,
  target_quantity integer,
  guest_first_name text,
  guest_last_name text,
  guest_email text,
  guest_phone text,
  special_requests text,
  target_ticket_type_id uuid,
  target_idempotency_key uuid,
  target_attendee_names text[],
  target_invitation_id uuid,
  target_share_token uuid
)
returns table (booking_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_event public.special_events%rowtype;
  v_type public.special_event_ticket_types%rowtype;
  v_existing public.special_event_bookings%rowtype;
  v_reserved_event bigint;
  v_reserved_type bigint;
  v_booking_id uuid;
  v_order_number text;
  v_subtotal numeric(12,2);
  v_currency_decimals integer;
  v_request jsonb;
  v_invitation_valid boolean := false;
  v_share_valid boolean := false;
begin
  if v_user_id is null then raise exception 'Authentication is required'; end if;
  if target_quantity is null or target_quantity <= 0 then raise exception 'Booking quantity must be greater than zero'; end if;
  if target_idempotency_key is null then raise exception 'Checkout idempotency key is required'; end if;
  if target_attendee_names is not null and cardinality(target_attendee_names) <> target_quantity then
    raise exception 'Provide one attendee name for each ticket';
  end if;
  if target_attendee_names is not null and exists (select 1 from unnest(target_attendee_names) n where nullif(trim(n), '') is null) then
    raise exception 'Attendee names cannot be blank';
  end if;
  if nullif(btrim(guest_first_name), '') is null or nullif(btrim(guest_last_name), '') is null
     or nullif(btrim(guest_email), '') is null then
    raise exception 'Guest first name, last name, and email are required';
  end if;
  if lower(btrim(guest_email)) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Guest email address is invalid';
  end if;
  if length(guest_first_name) > 100 or length(guest_last_name) > 100
     or length(guest_email) > 254 or length(coalesce(guest_phone, '')) > 40
     or length(coalesce(special_requests, '')) > 2000 then
    raise exception 'Guest details are too long';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || target_idempotency_key::text, 0));
  select * into v_event from public.special_events where id = target_event_id for update;
  if not found then raise exception 'Special event not found'; end if;

  select * into v_existing
    from public.special_event_bookings
   where user_id = v_user_id and idempotency_key = target_idempotency_key
   for update;
  if found then
    v_request := jsonb_build_object(
      'eventId', target_event_id,
      'quantity', target_quantity,
      'ticketTypeId', coalesce(target_ticket_type_id, v_existing.ticket_type_id),
      'firstName', btrim(guest_first_name),
      'lastName', btrim(guest_last_name),
      'email', lower(btrim(guest_email)),
      'phone', nullif(btrim(guest_phone), ''),
      'specialRequests', nullif(btrim(special_requests), ''),
      'attendeeNames', coalesce(to_jsonb(target_attendee_names), 'null'::jsonb),
      'invitationId', target_invitation_id,
      'shareToken', target_share_token
    );
    if v_existing.event_id <> target_event_id
       or v_existing.quantity <> target_quantity
       or v_existing.ticket_type_id <> coalesce(target_ticket_type_id, v_existing.ticket_type_id)
       or (v_existing.checkout_request is not null and v_existing.checkout_request is distinct from v_request)
       or (v_existing.checkout_request is null and (
         lower(v_existing.guest_email) <> lower(btrim(guest_email))
         or v_existing.guest_first_name <> btrim(guest_first_name)
         or v_existing.guest_last_name <> btrim(guest_last_name)
         or v_existing.guest_phone is distinct from nullif(btrim(guest_phone), '')
         or v_existing.special_requests is distinct from nullif(btrim(special_requests), '')
         or v_existing.attendee_names is distinct from coalesce(target_attendee_names, array_fill(concat_ws(' ', btrim(guest_first_name), btrim(guest_last_name)), array[target_quantity]))
         or v_existing.event_invitation_id is distinct from case when v_event.is_private then target_invitation_id else null end
       )) then
      raise exception 'Checkout key was already used for different booking details';
    end if;
    if v_existing.checkout_request is null then
      update public.special_event_bookings set checkout_request = v_request where id = v_existing.id;
    end if;
    return query select v_existing.id, v_existing.order_number, v_existing.total_amount, v_existing.currency;
    return;
  end if;

  perform public.expire_special_event_holds(target_event_id);

  if v_event.is_private then
    select exists (
      select 1 from public.special_event_invitations i
      where i.id = target_invitation_id and i.event_id = v_event.id
        and i.event_plan_id = v_event.source_plan_id
        and i.invitee_user_id = v_user_id and i.status = 'accepted'
        and exists (select 1 from public.special_event_plans p where p.id = i.event_plan_id and p.status = 'scheduled' and p.is_private)
    ) into v_invitation_valid;
    if v_event.status <> 'draft' or not v_invitation_valid or target_quantity <> 1 then
      raise exception 'An accepted private invitation is required for one attendee';
    end if;
  elsif v_event.status <> 'published' then
    select exists (
      select 1 from public.special_events e
      where e.id = v_event.id and e.share_token = target_share_token
        and e.is_private = false and e.status = 'draft'
    ) into v_share_valid;
    if not v_share_valid then raise exception 'This event is not open for registration'; end if;
  end if;
  if v_event.starts_at <= now() then raise exception 'This event is no longer upcoming'; end if;

  select * into v_type
    from public.special_event_ticket_types
   where id = coalesce(target_ticket_type_id, v_event.default_ticket_type_id)
     and event_id = target_event_id and is_active
   for update;
  if not found then raise exception 'Ticket type is not available'; end if;
  v_currency_decimals := public.checkout_currency_minor_units(v_event.currency);
  if v_currency_decimals is null then raise exception 'Event currency is not supported for checkout'; end if;
  if v_type.price::text in ('NaN', 'Infinity', '-Infinity') or v_type.price < 0
     or v_type.price <> round(v_type.price, v_currency_decimals) then
    raise exception 'Ticket price is not valid for the event currency';
  end if;

  v_request := jsonb_build_object(
    'eventId', target_event_id,
    'quantity', target_quantity,
    'ticketTypeId', v_type.id,
    'firstName', btrim(guest_first_name),
    'lastName', btrim(guest_last_name),
    'email', lower(btrim(guest_email)),
    'phone', nullif(btrim(guest_phone), ''),
    'specialRequests', nullif(btrim(special_requests), ''),
    'attendeeNames', coalesce(to_jsonb(target_attendee_names), 'null'::jsonb),
    'invitationId', target_invitation_id,
    'shareToken', target_share_token
  );

  if v_event.is_private then
    select b.* into v_existing
      from public.special_event_bookings b
      join public.special_event_invitations i on i.id = b.event_invitation_id
     where b.event_invitation_id = target_invitation_id
       and b.user_id = v_user_id and i.invitee_user_id = v_user_id
       and i.event_id = v_event.id and b.status in ('pending', 'confirmed', 'manual_review');
    if found then
      return query select v_existing.id, v_existing.order_number, v_existing.total_amount, v_existing.currency;
      return;
    end if;
  end if;

  if target_quantity > v_type.max_per_order then raise exception 'Ticket quantity exceeds the per-order limit'; end if;
  select coalesce(sum(quantity), 0) into v_reserved_event
    from public.special_event_bookings
   where event_id = target_event_id
     and (status = 'confirmed' or (status = 'manual_review' and payment_status = 'manual_review') or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
  if v_reserved_event + target_quantity > v_event.capacity then raise exception 'Special event capacity exceeded'; end if;
  if v_type.capacity is not null then
    select coalesce(sum(quantity), 0) into v_reserved_type
      from public.special_event_bookings
     where ticket_type_id = v_type.id
       and (status = 'confirmed' or (status = 'manual_review' and payment_status = 'manual_review') or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
    if v_reserved_type + target_quantity > v_type.capacity then raise exception 'Ticket type capacity exceeded'; end if;
  end if;

  v_subtotal := round(v_type.price * target_quantity, v_currency_decimals);
  v_booking_id := gen_random_uuid();
  v_order_number := 'SE-' || upper(substr(replace(v_booking_id::text, '-', ''), 1, 16));
  insert into public.special_event_bookings (
    id, user_id, event_id, ticket_type_id, event_invitation_id, attendee_names, order_number,
    guest_first_name, guest_last_name, guest_email, guest_phone, special_requests,
    quantity, subtotal, service_fee, tax_amount, discount_amount, total_amount, currency,
    status, payment_status, confirmation_number, expires_at, idempotency_key, checkout_request
  ) values (
    v_booking_id, v_user_id, target_event_id, v_type.id,
    case when v_event.is_private then target_invitation_id else null end,
    coalesce(target_attendee_names, array_fill(concat_ws(' ', btrim(guest_first_name), btrim(guest_last_name)), array[target_quantity])),
    v_order_number, btrim(guest_first_name), btrim(guest_last_name), lower(btrim(guest_email)),
    nullif(btrim(guest_phone), ''), nullif(btrim(special_requests), ''), target_quantity,
    v_subtotal, 0, 0, 0, v_subtotal, upper(v_event.currency),
    'pending', 'pending', 'PENDING-' || v_order_number, now() + interval '15 minutes', target_idempotency_key, v_request
  );
  return query select v_booking_id, v_order_number, v_subtotal, upper(v_event.currency);
end;
$$;

revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) from public, anon;
grant execute on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) to authenticated;

create or replace function public.confirm_special_event_payment(
  target_booking_id uuid,
  target_transaction_id text
)
returns table (booking_id uuid, confirmation_number text, ticket_code text, order_number text, payment_status text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_payment public.special_event_payment_attempts%rowtype;
  v_event public.special_events%rowtype;
  existing_payment public.special_event_payments%rowtype;
  prior_payment public.special_event_payments%rowtype;
  v_confirmation text;
  v_ticket text;
  v_remaining bigint;
  v_type_remaining bigint;
  v_review boolean := false;
begin
  if target_booking_id is null or nullif(target_transaction_id, '') is null then
    raise exception 'Verified event payment details are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('special-event-payment:' || target_transaction_id, 0));
  select booking.event_id into v_event.id
    from public.special_event_bookings as booking
   where booking.id = target_booking_id;
  if not found then raise exception 'Special event booking not found'; end if;
  select * into v_event from public.special_events where id = v_event.id for update;
  select * into v_booking from public.special_event_bookings where id = target_booking_id for update;

  select * into v_payment
    from public.special_event_payment_attempts
   where booking_id = v_booking.id
     and transaction_id = target_transaction_id
     and status in ('verified', 'manual_review', 'successful')
   for update;
  if not found then raise exception 'Verified payment attempt not found'; end if;
  if v_payment.amount <> v_booking.total_amount or upper(v_payment.currency) <> upper(v_booking.currency) then
    raise exception 'Verified payment amount does not match booking';
  end if;

  select * into existing_payment
    from public.special_event_payments
   where booking_id = v_booking.id and transaction_id = target_transaction_id;
  if found and not (
    existing_payment.status = 'manual_review'
    and v_booking.status = 'manual_review'
    and v_booking.payment_status = 'manual_review'
    and v_payment.status = 'verified'
  ) then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code,
      v_booking.order_number, case when existing_payment.status = 'successful' then 'paid' else 'manual_review' end;
    return;
  end if;

  select * into prior_payment
    from public.special_event_payments
   where booking_id = v_booking.id
   for update;
  if (found and prior_payment.transaction_id is distinct from target_transaction_id)
     or exists (
       select 1 from public.special_event_payments other_payment
        where other_payment.transaction_id = target_transaction_id
          and other_payment.booking_id <> v_booking.id
     )
     or v_booking.payment_status in ('paid', 'refunded', 'partially_refunded')
     or v_booking.status in ('confirmed', 'refunded') then
    update public.special_event_payment_attempts
       set status = 'manual_review',
           transaction_id = coalesce(transaction_id, target_transaction_id),
           failure_reason = 'An additional successful payment requires reconciliation',
           updated_at = now()
     where id = v_payment.id;
    insert into public.special_event_duplicate_captures (
      event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency
    ) values (
      v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
      v_payment.amount, v_payment.currency
    ) on conflict (transaction_id) do nothing;
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code,
      v_booking.order_number, 'manual_review'::text;
    return;
  end if;

  if not (
    (v_booking.status = 'pending' and v_booking.payment_status = 'pending')
    or (v_booking.status = 'expired' and v_booking.payment_status = 'expired')
    or (v_booking.status = 'cancelled' and v_booking.payment_status = 'cancelled')
    or (v_booking.status = 'manual_review' and v_booking.payment_status = 'manual_review')
  ) then raise exception 'Special event booking is not awaiting payment'; end if;

  select v_event.capacity - coalesce(sum(quantity), 0) into v_remaining
    from public.special_event_bookings
   where event_id = v_event.id and id <> v_booking.id
     and (status = 'confirmed' or (status = 'manual_review' and payment_status = 'manual_review') or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
  select v_type.capacity - coalesce(sum(b.quantity), 0) into v_type_remaining
    from public.special_event_ticket_types v_type
    left join public.special_event_bookings b on b.ticket_type_id = v_type.id and b.id <> v_booking.id
      and (b.status = 'confirmed' or (b.status = 'manual_review' and b.payment_status = 'manual_review') or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))
   where v_type.id = v_booking.ticket_type_id
   group by v_type.capacity;
  v_review := v_booking.status = 'cancelled'
    or v_remaining < v_booking.quantity
    or (v_type_remaining is not null and v_type_remaining < v_booking.quantity);

  if v_review then
    update public.special_event_bookings
       set status = 'manual_review', payment_status = 'manual_review', payment_verified_at = now(), updated_at = now()
     where id = v_booking.id;
    update public.special_event_payment_attempts set status = 'manual_review', updated_at = now() where id = v_payment.id;
    insert into public.special_event_payments (
      event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
    ) values (
      v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
      v_payment.amount, v_payment.currency, 'manual_review', now()
    ) on conflict (booking_id) do update set
      status = 'manual_review', payment_attempt_id = excluded.payment_attempt_id,
      transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
      amount = excluded.amount, currency = excluded.currency, updated_at = now();
    return query select v_booking.id, v_booking.confirmation_number, null::text, v_booking.order_number, 'manual_review'::text;
    return;
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  insert into public.special_event_tickets (
    event_id, booking_id, ticket_type_id, ticket_number, ticket_token, attendee_name, attendee_email
  )
  select v_booking.event_id, v_booking.id, v_booking.ticket_type_id, seq,
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
    coalesce(nullif(trim(v_booking.attendee_names[seq]), ''), concat_ws(' ', v_booking.guest_first_name, v_booking.guest_last_name)), v_booking.guest_email
  from generate_series(1, v_booking.quantity) seq
  on conflict (booking_id, ticket_number) do nothing;
  select ticket_token into v_ticket from public.special_event_tickets where booking_id = v_booking.id and ticket_number = 1;

  update public.special_event_bookings
     set status = 'confirmed', payment_status = 'paid', payment_verified_at = now(),
         confirmation_number = v_confirmation, ticket_code = v_ticket, updated_at = now()
   where id = v_booking.id;
  update public.special_event_payment_attempts set status = 'successful', updated_at = now() where id = v_payment.id;
  update public.special_events set attendees_count = attendees_count + v_booking.quantity, updated_at = now() where id = v_event.id;
  insert into public.special_event_payments (
    event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
  ) values (
    v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
    v_payment.amount, v_payment.currency, 'successful', now()
  ) on conflict (booking_id) do update set
    status = 'successful', payment_attempt_id = excluded.payment_attempt_id,
    transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
    amount = excluded.amount, currency = excluded.currency, paid_at = excluded.paid_at, updated_at = now();
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.order_number, 'paid'::text;
end;
$$;

revoke all on function public.confirm_special_event_payment(uuid, text) from public, anon, authenticated;
grant execute on function public.confirm_special_event_payment(uuid, text) to service_role;

create or replace function public.normalize_event_invoice_line()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_booking public.special_event_bookings%rowtype;
  selected_invoice public.books_invoices%rowtype;
begin
  select * into selected_invoice from public.books_invoices where id = new.invoice_id;
  if not found or left(selected_invoice.invoice_number, 6) <> 'EVENT-' then return new; end if;
  select * into selected_booking
    from public.special_event_bookings
   where order_number = substring(selected_invoice.invoice_number from 7);
  if not found then return new; end if;
  if selected_invoice.subtotal <> selected_booking.total_amount then
    raise exception 'Event invoice does not match the verified booking total';
  end if;
  new.quantity := 1;
  new.unit_price := selected_booking.total_amount;
  return new;
end;
$$;
revoke all on function public.normalize_event_invoice_line() from public, anon, authenticated;
drop trigger if exists event_invoice_line_normalize on public.books_invoice_lines;
create trigger event_invoice_line_normalize
before insert or update of invoice_id, quantity, unit_price on public.books_invoice_lines
for each row execute function public.normalize_event_invoice_line();

notify pgrst, 'reload schema';


alter table public.hotel_bookings
  add column if not exists checkout_request jsonb;

alter table public.hotel_bookings
  drop constraint if exists hotel_bookings_secure_total_check;
alter table public.hotel_bookings
  add constraint hotel_bookings_secure_total_check
  check (
    public.checkout_currency_minor_units(currency_code) is not null
    and nightly_subtotal::text not in ('NaN', 'Infinity', '-Infinity')
    and discount_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and taxable_subtotal::text not in ('NaN', 'Infinity', '-Infinity')
    and vat_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and lht_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and total_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and nightly_subtotal >= 0 and discount_amount >= 0 and discount_amount <= nightly_subtotal
    and taxable_subtotal = nightly_subtotal - discount_amount
    and vat_amount >= 0 and lht_amount >= 0
    and nightly_subtotal = round(nightly_subtotal, public.checkout_currency_minor_units(currency_code))
    and discount_amount = round(discount_amount, public.checkout_currency_minor_units(currency_code))
    and taxable_subtotal = round(taxable_subtotal, public.checkout_currency_minor_units(currency_code))
    and vat_amount = round(vat_amount, public.checkout_currency_minor_units(currency_code))
    and lht_amount = round(lht_amount, public.checkout_currency_minor_units(currency_code))
    and total_amount = round(total_amount, public.checkout_currency_minor_units(currency_code))
    and total_amount = round(taxable_subtotal + vat_amount + lht_amount,
      public.checkout_currency_minor_units(currency_code))
  ) not valid;

alter table public.hotel_bookings enable row level security;
alter table public.hotel_payment_attempts enable row level security;
revoke all on public.hotel_bookings, public.hotel_payment_attempts from public, anon, authenticated;
grant select on public.hotel_bookings, public.hotel_payment_attempts to authenticated;
drop policy if exists hotel_bookings_owner_read on public.hotel_bookings;
drop policy if exists hotel_payment_attempts_manager_read on public.hotel_payment_attempts;
drop policy if exists hotel_bookings_owner_or_manager_select on public.hotel_bookings;
drop policy if exists hotel_payment_attempts_owner_or_manager_select on public.hotel_payment_attempts;
create policy hotel_bookings_owner_or_manager_select
  on public.hotel_bookings for select to authenticated
  using (user_id = auth.uid() or exists (
    select 1 from public.user_profiles up
    join public.books_memberships bm on bm.user_id = up.user_id
    where up.user_id = auth.uid() and up.role = 'manager'
      and bm.organization_id = hotel_bookings.organization_id and bm.role in ('owner', 'admin')
  ));
create policy hotel_payment_attempts_owner_or_manager_select
  on public.hotel_payment_attempts for select to authenticated
  using (exists (
    select 1 from public.hotel_bookings hb
    where hb.id = hotel_payment_attempts.booking_id
      and (hb.user_id = auth.uid() or exists (
        select 1 from public.user_profiles up
        join public.books_memberships bm on bm.user_id = up.user_id
        where up.user_id = auth.uid() and up.role = 'manager'
          and bm.organization_id = hb.organization_id and bm.role in ('owner', 'admin')
      ))
  ));

do $$
declare constraint_row record;
begin
  for constraint_row in
    select conname
      from pg_constraint
     where conrelid = 'public.hotel_rooms'::regclass
       and contype = 'c'
       and position('nightly_rate' in pg_get_constraintdef(oid)) > 0
       and position('TZS' in pg_get_constraintdef(oid)) > 0
       and position('trunc' in pg_get_constraintdef(oid)) > 0
  loop
    execute format('alter table public.hotel_rooms drop constraint %I', constraint_row.conname);
  end loop;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.hotel_rooms'::regclass
       and conname = 'hotel_rooms_currency_precision_check'
  ) then
    alter table public.hotel_rooms
      add constraint hotel_rooms_currency_precision_check
      check (
        public.checkout_currency_minor_units(currency_code) is not null
        and nightly_rate::text not in ('NaN', 'Infinity', '-Infinity')
        and nightly_rate > 0
        and nightly_rate = round(nightly_rate, public.checkout_currency_minor_units(currency_code))
        and (original_nightly_rate is null or (
          original_nightly_rate::text not in ('NaN', 'Infinity', '-Infinity')
          and original_nightly_rate >= nightly_rate
          and original_nightly_rate = round(original_nightly_rate, public.checkout_currency_minor_units(currency_code))
        ))
      ) not valid;
  end if;
end;
$$;

with ranked_attempts as (
  select id, row_number() over (partition by booking_id order by created_at desc, id desc) as attempt_rank
    from public.hotel_payment_attempts
   where status in ('initiated', 'redirected')
)
update public.hotel_payment_attempts attempt
   set status = 'failed',
       failure_reason = coalesce(attempt.failure_reason, 'Superseded duplicate active checkout attempt'),
       updated_at = now()
  from ranked_attempts ranked
 where ranked.id = attempt.id and ranked.attempt_rank > 1;

create unique index if not exists hotel_payment_attempts_one_active_per_booking
  on public.hotel_payment_attempts (booking_id)
  where status in ('initiated', 'redirected');

create or replace function public.validate_hotel_payment_attempt_total()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_booking public.hotel_bookings%rowtype;
begin
  select * into selected_booking from public.hotel_bookings where id = new.booking_id;
  if not found or new.amount::text in ('NaN', 'Infinity', '-Infinity')
     or new.amount <> selected_booking.total_amount
     or upper(new.currency_code) <> upper(selected_booking.currency_code)
     or public.checkout_currency_minor_units(new.currency_code) is null
     or new.amount <> round(new.amount, public.checkout_currency_minor_units(new.currency_code))
     or new.amount <= 0 then
    raise exception 'Hotel payment attempt does not match its stored booking total';
  end if;
  return new;
end;
$$;
revoke all on function public.validate_hotel_payment_attempt_total() from public, anon, authenticated;
drop trigger if exists hotel_payment_attempt_total_validation on public.hotel_payment_attempts;
create trigger hotel_payment_attempt_total_validation
before insert or update of booking_id, amount, currency_code on public.hotel_payment_attempts
for each row execute function public.validate_hotel_payment_attempt_total();

create table if not exists public.hotel_duplicate_payment_captures (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  booking_id uuid not null references public.hotel_bookings(id) on delete restrict,
  payment_attempt_id uuid not null references public.hotel_payment_attempts(id) on delete restrict,
  transaction_id text not null unique,
  tx_ref text not null,
  amount numeric(14,2) not null check (amount > 0 and amount::text not in ('NaN', 'Infinity', '-Infinity')),
  currency_code char(3) not null check (public.checkout_currency_minor_units(currency_code) is not null),
  status text not null default 'manual_review' check (status in ('manual_review', 'refunded', 'resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (amount = round(amount, public.checkout_currency_minor_units(currency_code)))
);

alter table public.hotel_duplicate_payment_captures enable row level security;
revoke all on public.hotel_duplicate_payment_captures from public, anon, authenticated;
grant select on public.hotel_duplicate_payment_captures to authenticated;
grant all on public.hotel_duplicate_payment_captures to service_role;
drop policy if exists hotel_duplicate_payment_captures_manager_read on public.hotel_duplicate_payment_captures;
create policy hotel_duplicate_payment_captures_manager_read
  on public.hotel_duplicate_payment_captures for select to authenticated
  using (exists (
    select 1 from public.user_profiles up
    join public.books_memberships bm on bm.user_id = up.user_id
    where up.user_id = auth.uid() and up.role = 'manager'
      and bm.organization_id = hotel_duplicate_payment_captures.organization_id and bm.role in ('owner', 'admin')
  ));

create or replace function public.create_hotel_booking(
  target_room_id uuid,
  target_guest jsonb,
  target_check_in date,
  target_check_out date,
  target_guest_count integer,
  target_room_count integer,
  target_special_requests text,
  target_preferences jsonb,
  target_user_id uuid,
  target_idempotency_key uuid,
  target_access_token_hash text,
  target_fx_rates jsonb
)
returns table (
  booking_id uuid,
  confirmation_number text,
  currency_code char(3),
  nights integer,
  nightly_subtotal numeric,
  discount_amount numeric,
  taxable_subtotal numeric,
  vat_amount numeric,
  lht_amount numeric,
  total_amount numeric,
  hotel_classification smallint,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_room public.hotel_rooms%rowtype;
  selected_classification smallint;
  room_rate_in_ugx numeric;
  usd_per_ugx numeric;
  room_currency_per_ugx numeric;
  local_hotel_tax_per_room numeric;
  discount_rate numeric := 0;
  currency_decimals integer;
  nights_count integer;
  reserved_units integer;
  room_subtotal numeric;
  discount_value numeric;
  taxable_value numeric;
  vat_value numeric;
  lht_value numeric;
  total_value numeric;
  existing_booking public.hotel_bookings%rowtype;
  new_booking_id uuid;
  new_confirmation text;
  hold_expires timestamptz;
  request_fingerprint jsonb;
begin
  if target_idempotency_key is null or target_guest is null or jsonb_typeof(target_guest) is distinct from 'object' then
    raise exception 'Booking request is invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_idempotency_key::text, 0));

  if target_check_in is null or target_check_out is null
     or target_check_in < current_date
     or target_check_out <= target_check_in
     or target_check_out > current_date + 365 then
    raise exception 'Select valid check-in and check-out dates';
  end if;

  if target_guest_count is null or target_guest_count < 1
     or target_room_count is null or target_room_count < 1
     or target_room_count > 10 then
    raise exception 'Guest or room count is invalid';
  end if;

  if coalesce(length(trim(target_guest->>'first_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'last_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'email')), 0) = 0
     or coalesce(length(trim(target_guest->>'phone')), 0) = 0 then
    raise exception 'Guest name, email, and phone are required';
  end if;
  if length(target_guest->>'first_name') > 100
     or length(target_guest->>'last_name') > 100
     or length(target_guest->>'email') > 254
     or length(target_guest->>'phone') > 40
     or coalesce(length(target_special_requests), 0) > 2000 then
    raise exception 'Guest details are too long';
  end if;
  if lower(trim(target_guest->>'email')) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Guest email address is invalid';
  end if;

  if target_access_token_hash is null
     or length(target_access_token_hash) <> 64 then
    raise exception 'Booking access credential is invalid';
  end if;

  if target_preferences is null
     or jsonb_typeof(target_preferences) is distinct from 'array' then
    raise exception 'Room preferences must be an array';
  end if;

  if jsonb_array_length(target_preferences) > 10 then
    raise exception 'Too many room preferences were selected';
  end if;

  request_fingerprint := jsonb_build_object(
    'roomId', target_room_id,
    'checkIn', target_check_in,
    'checkOut', target_check_out,
    'guestCount', target_guest_count,
    'roomCount', target_room_count,
    'guest', jsonb_build_object(
      'firstName', trim(target_guest->>'first_name'),
      'lastName', trim(target_guest->>'last_name'),
      'email', lower(trim(target_guest->>'email')),
      'phone', trim(target_guest->>'phone')
    ),
    'specialRequests', nullif(trim(target_special_requests), ''),
    'preferences', target_preferences,
    'userId', target_user_id
  );

  select *
    into existing_booking
    from public.hotel_bookings
   where idempotency_key = target_idempotency_key
   for update;

  if found then
    if existing_booking.access_token_hash <> target_access_token_hash
       or (existing_booking.user_id is not null and existing_booking.user_id is distinct from target_user_id)
       or (existing_booking.checkout_request is not null and existing_booking.checkout_request is distinct from request_fingerprint)
       or (existing_booking.checkout_request is null and (
         existing_booking.room_id <> target_room_id
         or existing_booking.check_in <> target_check_in
         or existing_booking.check_out <> target_check_out
         or existing_booking.guest_count <> target_guest_count
         or existing_booking.room_count <> target_room_count
         or existing_booking.guest_first_name <> trim(target_guest->>'first_name')
         or existing_booking.guest_last_name <> trim(target_guest->>'last_name')
         or lower(existing_booking.guest_email) <> lower(trim(target_guest->>'email'))
         or existing_booking.guest_phone <> trim(target_guest->>'phone')
         or existing_booking.special_requests is distinct from nullif(trim(target_special_requests), '')
         or existing_booking.room_preferences is distinct from target_preferences
       )) then
      raise exception 'Idempotency key was already used for different booking details';
    end if;
    if existing_booking.checkout_request is null then
      update public.hotel_bookings set checkout_request = request_fingerprint where id = existing_booking.id;
    end if;

    return query
    select existing_booking.id,
           existing_booking.confirmation_number,
           existing_booking.currency_code,
           existing_booking.nights,
           existing_booking.nightly_subtotal,
           existing_booking.discount_amount,
           existing_booking.taxable_subtotal,
           existing_booking.vat_amount,
           existing_booking.lht_amount,
           existing_booking.total_amount,
           existing_booking.hotel_classification,
           existing_booking.expires_at;
    return;
  end if;

  if target_fx_rates is null
     or nullif(target_fx_rates->>'as_of', '') is null
     or (target_fx_rates->>'as_of')::timestamptz < now() - interval '36 hours'
     or (target_fx_rates->>'as_of')::timestamptz > now() + interval '5 minutes' then
    raise exception 'A current exchange-rate snapshot is required to calculate hotel levies';
  end if;

  select *
    into selected_room
    from public.hotel_rooms
   where id = target_room_id
     and status = 'published'
   for update;

  if not found then
    raise exception 'This room is not available for booking';
  end if;
  if selected_room.nightly_rate::text in ('NaN', 'Infinity', '-Infinity') or selected_room.nightly_rate <= 0 then
    raise exception 'This room has an invalid nightly rate';
  end if;

  select bo.hotel_classification
    into selected_classification
    from public.books_organizations as bo
   where bo.id = selected_room.organization_id;

  if selected_classification is null
     or selected_classification not between 1 and 5 then
    raise exception 'The hotel must set its star classification before accepting bookings';
  end if;

  if target_guest_count > selected_room.max_guests * target_room_count then
    raise exception 'Guest count exceeds the selected room capacity';
  end if;

  update public.hotel_bookings as hb
     set booking_status = 'expired',
         payment_status = 'cancelled'
   where hb.room_id = selected_room.id
     and hb.booking_status = 'pending'
     and hb.expires_at <= now();

  select coalesce(sum(hb.room_count), 0)
    into reserved_units
    from public.hotel_bookings as hb
   where hb.room_id = selected_room.id
     and (
       (
         hb.booking_status in ('confirmed', 'manual_review')
         and hb.payment_status = 'paid'
       )
       or (
         hb.booking_status = 'pending'
         and hb.payment_status = 'pending'
         and hb.expires_at > now()
       )
     )
     and hb.check_in < target_check_out
     and hb.check_out > target_check_in;

  if reserved_units + target_room_count > selected_room.available_units then
    raise exception 'The selected room is no longer available for these dates';
  end if;

  nights_count := target_check_out - target_check_in;
  currency_decimals := public.checkout_currency_minor_units(selected_room.currency_code);
  if currency_decimals is null then raise exception 'Room currency is not supported for checkout'; end if;
  if selected_room.nightly_rate <> round(selected_room.nightly_rate, currency_decimals)
     or (selected_room.original_nightly_rate is not null and selected_room.original_nightly_rate <> round(selected_room.original_nightly_rate, currency_decimals)) then
    raise exception 'Room rate does not match the currency precision';
  end if;

  room_subtotal := round(
    selected_room.nightly_rate * nights_count * target_room_count,
    currency_decimals
  );

  select coalesce(max(discount_percentage), 0)
    into discount_rate
    from public.hotel_booking_offers
   where is_active
     and minimum_nights <= nights_count
     and (starts_at is null or starts_at <= now())
     and (ends_at is null or ends_at > now());

  discount_value := round(
    room_subtotal * discount_rate / 100,
    currency_decimals
  );
  taxable_value := room_subtotal - discount_value;

  room_currency_per_ugx :=
    (target_fx_rates->>trim(selected_room.currency_code))::numeric;
  usd_per_ugx := (target_fx_rates->>'USD')::numeric;

  if room_currency_per_ugx is null
     or room_currency_per_ugx::text in ('NaN', 'Infinity', '-Infinity')
     or room_currency_per_ugx <= 0
     or usd_per_ugx is null
     or usd_per_ugx::text in ('NaN', 'Infinity', '-Infinity')
     or usd_per_ugx <= 0 then
    raise exception 'A current exchange-rate snapshot is required to calculate hotel levies';
  end if;

  room_rate_in_ugx :=
    (selected_room.nightly_rate * (1 - discount_rate / 100))
    / room_currency_per_ugx;

  if selected_classification in (4, 5) then
    local_hotel_tax_per_room := (2 / usd_per_ugx) * room_currency_per_ugx;
  elsif selected_classification in (2, 3) or room_rate_in_ugx > 50000 then
    local_hotel_tax_per_room := 2000 * room_currency_per_ugx;
  elsif room_rate_in_ugx >= 10000 then
    local_hotel_tax_per_room := 1000 * room_currency_per_ugx;
  else
    local_hotel_tax_per_room := 500 * room_currency_per_ugx;
  end if;

  vat_value := round(taxable_value * 0.18, currency_decimals);
  lht_value := round(
    local_hotel_tax_per_room * nights_count * target_room_count,
    currency_decimals
  );
  total_value := taxable_value + vat_value + lht_value;
  new_confirmation :=
    'ST-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  hold_expires := now() + interval '20 minutes';

  insert into public.hotel_bookings (
    confirmation_number, organization_id, room_id, user_id,
    check_in, check_out, nights, guest_count, room_count,
    guest_first_name, guest_last_name, guest_email, guest_phone,
    special_requests, room_preferences, currency_code,
    nightly_subtotal, discount_amount, taxable_subtotal,
    vat_amount, lht_amount, total_amount, hotel_classification,
    fx_rates_snapshot, expires_at, idempotency_key, access_token_hash, checkout_request
  )
  values (
    new_confirmation, selected_room.organization_id, selected_room.id,
    target_user_id, target_check_in, target_check_out, nights_count,
    target_guest_count, target_room_count,
    trim(target_guest->>'first_name'), trim(target_guest->>'last_name'),
    lower(trim(target_guest->>'email')), trim(target_guest->>'phone'),
    nullif(trim(target_special_requests), ''), target_preferences,
    selected_room.currency_code, room_subtotal, discount_value,
    taxable_value, vat_value, lht_value, total_value,
    selected_classification, target_fx_rates, hold_expires,
    target_idempotency_key, target_access_token_hash, request_fingerprint
  )
  on conflict (idempotency_key) do nothing
  returning id into new_booking_id;

  if new_booking_id is null then
    select *
      into existing_booking
      from public.hotel_bookings
     where idempotency_key = target_idempotency_key;

    if existing_booking.access_token_hash <> target_access_token_hash
       or (existing_booking.user_id is not null and existing_booking.user_id is distinct from target_user_id)
       or (existing_booking.checkout_request is not null and existing_booking.checkout_request is distinct from request_fingerprint) then
      raise exception 'Idempotency key was already used for different booking details';
    end if;

    return query
    select existing_booking.id,
           existing_booking.confirmation_number,
           existing_booking.currency_code,
           existing_booking.nights,
           existing_booking.nightly_subtotal,
           existing_booking.discount_amount,
           existing_booking.taxable_subtotal,
           existing_booking.vat_amount,
           existing_booking.lht_amount,
           existing_booking.total_amount,
           existing_booking.hotel_classification,
           existing_booking.expires_at;
    return;
  end if;

  return query
  select new_booking_id,
         new_confirmation,
         selected_room.currency_code,
         nights_count,
         room_subtotal,
         discount_value,
         taxable_value,
         vat_value,
         lht_value,
         total_value,
         selected_classification,
         hold_expires;
end;
$$;

revoke all on function public.create_hotel_booking(
  uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_hotel_booking(
  uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb
) to service_role;

create or replace function public.create_hotel_payment_attempt(
  target_booking_id uuid,
  target_access_token_hash text,
  target_tx_ref text
)
returns table (attempt_id uuid, attempt_tx_ref text, attempt_status text, attempt_payment_url text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_booking public.hotel_bookings%rowtype;
  selected_attempt public.hotel_payment_attempts%rowtype;
  created_attempt public.hotel_payment_attempts%rowtype;
begin
  if target_booking_id is null or target_access_token_hash is null
     or length(target_access_token_hash) <> 64
     or nullif(target_tx_ref, '') is null or length(target_tx_ref) > 255 then
    raise exception 'Payment request is invalid';
  end if;
  select * into selected_booking
    from public.hotel_bookings
   where id = target_booking_id
   for update;
  if not found or selected_booking.access_token_hash <> target_access_token_hash then
    raise exception 'Booking access could not be verified';
  end if;
  if selected_booking.booking_status <> 'pending'
     or selected_booking.payment_status <> 'pending'
     or selected_booking.expires_at is null
     or selected_booking.expires_at <= now() then
    raise exception 'This reservation hold is no longer available';
  end if;
  select * into selected_attempt
    from public.hotel_payment_attempts
   where booking_id = selected_booking.id
     and status in ('initiated', 'redirected')
   order by created_at desc, id desc
   limit 1
   for update;
  if found then
    if selected_attempt.status = 'redirected' and selected_attempt.payment_url is not null then
      return query select selected_attempt.id, selected_attempt.tx_ref, selected_attempt.status, selected_attempt.payment_url;
      return;
    end if;
    if selected_attempt.created_at > now() - interval '2 minutes' then
      return query select selected_attempt.id, selected_attempt.tx_ref, 'preparing'::text, selected_attempt.payment_url;
      return;
    end if;
    update public.hotel_payment_attempts
       set status = 'failed', failure_reason = 'Checkout preparation timed out', updated_at = now()
     where id = selected_attempt.id;
  end if;
  insert into public.hotel_payment_attempts (booking_id, tx_ref, amount, currency_code, status)
  values (selected_booking.id, target_tx_ref, selected_booking.total_amount, selected_booking.currency_code, 'initiated')
  returning * into created_attempt;
  return query select created_attempt.id, created_attempt.tx_ref, created_attempt.status, created_attempt.payment_url;
end;
$$;

revoke all on function public.create_hotel_payment_attempt(uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_hotel_payment_attempt(uuid, text, text) to service_role;

create or replace function public.confirm_hotel_booking_payment(
  target_tx_ref text,
  target_transaction_id text
)
returns table (
  booking_id uuid,
  confirmation_number text,
  payment_status text,
  booking_status text
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  attempt public.hotel_payment_attempts%rowtype;
  booking public.hotel_bookings%rowtype;
  room public.hotel_rooms%rowtype;
  target_room_id uuid;
  reserved_units integer;
  duplicate_capture_exists boolean;
  resolved_status text := 'confirmed';
begin
  if nullif(btrim(target_tx_ref), '') is null or nullif(btrim(target_transaction_id), '') is null then
    raise exception 'Verified payment reference and transaction ID are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('hotel-payment:' || target_transaction_id, 0));
  select hb.room_id into target_room_id
    from public.hotel_payment_attempts hpa
    join public.hotel_bookings hb on hb.id = hpa.booking_id
   where hpa.tx_ref = target_tx_ref;
  if target_room_id is null then raise exception 'Hotel payment attempt was not found'; end if;
  select * into room from public.hotel_rooms where id = target_room_id for update;
  if not found then raise exception 'Hotel room was not found'; end if;
  select * into attempt from public.hotel_payment_attempts where tx_ref = target_tx_ref for update;
  if not found then raise exception 'Hotel payment attempt was not found'; end if;
  select * into booking from public.hotel_bookings where id = attempt.booking_id for update;
  if not found then raise exception 'Hotel booking was not found'; end if;
  if attempt.amount <> booking.total_amount or upper(attempt.currency_code) <> upper(booking.currency_code) then
    raise exception 'Payment attempt does not match booking amount';
  end if;

  if attempt.transaction_id = target_transaction_id
     and attempt.status in ('completed', 'manual_review', 'refunded') then
    return query select booking.id, booking.confirmation_number, booking.payment_status, booking.booking_status;
    return;
  end if;

  select exists (
    select 1 from public.hotel_payment_attempts other_attempt
     where other_attempt.transaction_id = target_transaction_id
       and other_attempt.id <> attempt.id
  ) into duplicate_capture_exists;
  if booking.payment_status in ('paid', 'refunded', 'partially_refunded')
     or duplicate_capture_exists
     or (attempt.transaction_id is not null and attempt.transaction_id <> target_transaction_id) then
    update public.hotel_payment_attempts
       set status = 'manual_review',
           transaction_id = coalesce(transaction_id, target_transaction_id),
           completed_at = coalesce(completed_at, now()),
           failure_reason = 'An additional successful payment requires reconciliation',
           updated_at = now()
     where id = attempt.id;
    insert into public.hotel_duplicate_payment_captures (
      organization_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency_code
    ) values (
      booking.organization_id, booking.id, attempt.id, target_transaction_id,
      attempt.tx_ref, attempt.amount, attempt.currency_code
    ) on conflict (transaction_id) do nothing;
    return query select booking.id, booking.confirmation_number, 'manual_review'::text, booking.booking_status;
    return;
  end if;

  if booking.booking_status not in ('pending', 'expired', 'cancelled') then
    raise exception 'Hotel booking cannot be confirmed';
  end if;
  if booking.booking_status = 'cancelled' then resolved_status := 'manual_review'; end if;
  update public.hotel_bookings expired_booking
     set booking_status = 'expired', payment_status = 'cancelled'
   where expired_booking.room_id = booking.room_id
     and expired_booking.id <> booking.id
     and expired_booking.booking_status = 'pending'
     and expired_booking.expires_at <= now();
  select coalesce(sum(reservation.room_count), 0) into reserved_units
    from public.hotel_bookings reservation
   where reservation.room_id = booking.room_id
     and reservation.id <> booking.id
     and ((reservation.booking_status in ('confirmed', 'manual_review') and reservation.payment_status = 'paid')
       or (reservation.booking_status = 'pending' and reservation.payment_status = 'pending' and reservation.expires_at > now()))
     and reservation.check_in < booking.check_out
     and reservation.check_out > booking.check_in;
  if booking.booking_status <> 'cancelled' and reserved_units + booking.room_count > room.available_units then
    resolved_status := 'manual_review';
  end if;
  update public.hotel_payment_attempts
     set status = case when resolved_status = 'manual_review' then 'manual_review' else 'completed' end,
         transaction_id = target_transaction_id,
         completed_at = now(),
         updated_at = now()
   where id = attempt.id;
  update public.hotel_bookings
     set payment_status = 'paid', booking_status = resolved_status, expires_at = null
   where id = booking.id;
  return query select booking.id, booking.confirmation_number, 'paid'::text, resolved_status;
end;
$$;

revoke all on function public.confirm_hotel_booking_payment(text, text) from public, anon, authenticated;
grant execute on function public.confirm_hotel_booking_payment(text, text) to service_role;

create or replace function public.apply_books_invoice_tax()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  selected_rate numeric;
  selected_booking public.hotel_bookings%rowtype;
begin
  if new.tax_rate_id is not null then
    select rate_percentage into selected_rate
      from public.books_tax_rates
     where id = new.tax_rate_id
       and organization_id = new.organization_id
       and is_active
       and new.issue_date >= effective_from
       and (effective_to is null or new.issue_date <= effective_to);
    if selected_rate is null then raise exception 'Selected tax rate is not active for this invoice date'; end if;
    new.tax_rate_percentage := selected_rate;
    if new.invoice_number like 'HOTEL-%' then
      if public.checkout_currency_minor_units(new.currency_code) is null then
        raise exception 'Hotel invoice currency is not supported';
      end if;
      new.tax_amount := round(
        new.subtotal * selected_rate / 100,
        public.checkout_currency_minor_units(new.currency_code)
      );
    else
      new.tax_amount := round(new.subtotal * selected_rate / 100, 4);
    end if;
  else
    new.tax_rate_percentage := 0;
    new.tax_amount := 0;
  end if;

  if new.invoice_number like 'HOTEL-%' then
    select * into selected_booking
      from public.hotel_bookings
     where 'HOTEL-' || confirmation_number = new.invoice_number;
    if found and (
      new.currency_code::text <> selected_booking.currency_code::text
      or new.subtotal <> selected_booking.taxable_subtotal
      or new.tax_amount <> selected_booking.vat_amount
      or new.other_charges <> selected_booking.lht_amount
    ) then
      raise exception 'Hotel invoice totals do not match the verified reservation';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.enforce_checkout_invoice_totals()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_menu_order public.menu_orders%rowtype;
  selected_event_booking public.special_event_bookings%rowtype;
  selected_hotel_booking public.hotel_bookings%rowtype;
begin
  select * into selected_menu_order
    from public.menu_orders
   where books_invoice_id = new.id and pricing_version = 1;
  if not found and left(new.invoice_number, 5) = 'MENU-' then
    select * into selected_menu_order
      from public.menu_orders
     where order_number = substring(new.invoice_number from 6) and pricing_version = 1;
  end if;
  if found then
    new.currency_code := upper(selected_menu_order.currency)::char(3);
    new.subtotal := selected_menu_order.subtotal;
    new.tax_amount := selected_menu_order.tax_amount;
    new.other_charges := selected_menu_order.service_fee + selected_menu_order.tip_amount;
    new.total := selected_menu_order.total_amount;
    return new;
  end if;

  select * into selected_event_booking
    from public.special_event_bookings
   where books_invoice_id = new.id;
  if not found and left(new.invoice_number, 6) = 'EVENT-' then
    select * into selected_event_booking
      from public.special_event_bookings
     where order_number = substring(new.invoice_number from 7);
  end if;
  if found then
    new.currency_code := upper(selected_event_booking.currency)::char(3);
    new.subtotal := selected_event_booking.total_amount;
    new.tax_rate_id := null;
    new.tax_rate_percentage := 0;
    new.tax_amount := 0;
    new.other_charges := 0;
    new.total := selected_event_booking.total_amount;
    return new;
  end if;

  select * into selected_hotel_booking
    from public.hotel_bookings
   where books_invoice_id = new.id;
  if not found and left(new.invoice_number, 6) = 'HOTEL-' then
    select * into selected_hotel_booking
      from public.hotel_bookings
     where 'HOTEL-' || confirmation_number = new.invoice_number;
  end if;
  if found then
    new.currency_code := selected_hotel_booking.currency_code;
    new.subtotal := selected_hotel_booking.taxable_subtotal;
    new.tax_rate_percentage := 18;
    new.tax_amount := selected_hotel_booking.vat_amount;
    new.other_charges := selected_hotel_booking.lht_amount;
    new.total := selected_hotel_booking.total_amount;
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_checkout_invoice_totals() from public, anon, authenticated;
drop trigger if exists zzzz_checkout_invoice_totals_before_write on public.books_invoices;
create trigger zzzz_checkout_invoice_totals_before_write
before insert or update on public.books_invoices
for each row execute function public.enforce_checkout_invoice_totals();

create or replace function public.normalize_hotel_invoice_line()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_invoice public.books_invoices%rowtype;
  selected_booking public.hotel_bookings%rowtype;
begin
  select * into selected_invoice from public.books_invoices where id = new.invoice_id;
  if not found then return new; end if;
  select * into selected_booking
    from public.hotel_bookings
   where books_invoice_id = selected_invoice.id;
  if not found and left(selected_invoice.invoice_number, 6) = 'HOTEL-' then
    select * into selected_booking
      from public.hotel_bookings
     where 'HOTEL-' || confirmation_number = selected_invoice.invoice_number;
  end if;
  if found then
    if new.organization_id <> selected_invoice.organization_id then
      raise exception 'Hotel invoice line organization does not match its invoice';
    end if;
    new.quantity := 1;
    new.unit_price := selected_booking.taxable_subtotal;
  end if;
  return new;
end;
$$;
revoke all on function public.normalize_hotel_invoice_line() from public, anon, authenticated;
drop trigger if exists hotel_invoice_line_normalize on public.books_invoice_lines;
create trigger hotel_invoice_line_normalize
before insert or update of invoice_id, quantity, unit_price on public.books_invoice_lines
for each row execute function public.normalize_hotel_invoice_line();

create or replace function public.protect_checkout_invoice_lines()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  invoice_ids uuid[];
begin
  if tg_op = 'UPDATE' then
    invoice_ids := array[old.invoice_id, new.invoice_id];
  else
    invoice_ids := array[old.invoice_id];
  end if;
  if exists (
    select 1 from public.books_invoices invoice_row
     where invoice_row.id = any(invoice_ids)
       and (invoice_row.invoice_number like 'MENU-%'
         or invoice_row.invoice_number like 'EVENT-%'
         or invoice_row.invoice_number like 'HOTEL-%')
  ) then
    raise exception 'Checkout invoice lines cannot be changed or deleted';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.protect_checkout_invoice_lines() from public, anon, authenticated;
drop trigger if exists checkout_invoice_lines_immutable on public.books_invoice_lines;
create trigger checkout_invoice_lines_immutable
before update or delete on public.books_invoice_lines
for each row execute function public.protect_checkout_invoice_lines();

create or replace function public.validate_checkout_invoice_line_sum()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  invoice_id_value uuid;
  selected_invoice public.books_invoices%rowtype;
  recorded_amount numeric;
  expected_amount numeric;
begin
  if tg_op = 'DELETE' then
    invoice_id_value := old.invoice_id;
  else
    invoice_id_value := new.invoice_id;
  end if;
  select * into selected_invoice from public.books_invoices where id = invoice_id_value;
  if not found or not (
    selected_invoice.invoice_number like 'MENU-%'
    or selected_invoice.invoice_number like 'EVENT-%'
    or selected_invoice.invoice_number like 'HOTEL-%'
  ) then
    return null;
  end if;
  select coalesce(sum(line_total), 0) into recorded_amount
    from public.books_invoice_lines
   where invoice_id = invoice_id_value;
  expected_amount := selected_invoice.subtotal;
  if selected_invoice.invoice_number like 'MENU-%' then
    expected_amount := expected_amount + selected_invoice.other_charges;
  end if;
  if recorded_amount <> expected_amount then
    raise exception 'Checkout invoice detail lines do not match the invoice total';
  end if;
  return null;
end;
$$;
revoke all on function public.validate_checkout_invoice_line_sum() from public, anon, authenticated;
drop trigger if exists checkout_invoice_line_sum_check on public.books_invoice_lines;
create constraint trigger checkout_invoice_line_sum_check
after insert or update or delete on public.books_invoice_lines
deferrable initially deferred
for each row execute function public.validate_checkout_invoice_line_sum();

create or replace function public.validate_checkout_invoice_header_lines()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  recorded_amount numeric;
  expected_amount numeric;
begin
  if new.invoice_number not like 'MENU-%'
     and new.invoice_number not like 'EVENT-%'
     and new.invoice_number not like 'HOTEL-%' then
    return null;
  end if;
  select coalesce(sum(line_total), 0) into recorded_amount
    from public.books_invoice_lines
   where invoice_id = new.id;
  expected_amount := new.subtotal;
  if new.invoice_number like 'MENU-%' then
    expected_amount := expected_amount + new.other_charges;
  end if;
  if recorded_amount <> expected_amount then
    raise exception 'Checkout invoice detail lines do not match the invoice total';
  end if;
  return null;
end;
$$;
revoke all on function public.validate_checkout_invoice_header_lines() from public, anon, authenticated;
drop trigger if exists checkout_invoice_header_line_sum_check on public.books_invoices;
create constraint trigger checkout_invoice_header_line_sum_check
after insert or update on public.books_invoices
deferrable initially deferred
for each row execute function public.validate_checkout_invoice_header_lines();

notify pgrst, 'reload schema';


create or replace function public.create_hotel_booking(
  target_room_id uuid,
  target_guest jsonb,
  target_check_in date,
  target_check_out date,
  target_guest_count integer,
  target_room_count integer,
  target_special_requests text,
  target_preferences jsonb,
  target_user_id uuid,
  target_idempotency_key uuid,
  target_access_token_hash text,
  target_fx_rates jsonb
)
returns table (
  booking_id uuid,
  confirmation_number text,
  currency_code char(3),
  nights integer,
  nightly_subtotal numeric,
  discount_amount numeric,
  taxable_subtotal numeric,
  vat_amount numeric,
  lht_amount numeric,
  total_amount numeric,
  hotel_classification smallint,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_room public.hotel_rooms%rowtype;
  selected_classification smallint;
  room_rate_in_ugx numeric;
  usd_per_ugx numeric;
  room_currency_per_ugx numeric;
  local_hotel_tax_per_room numeric;
  discount_rate numeric := 0;
  currency_decimals integer;
  nights_count integer;
  reserved_units integer;
  room_subtotal numeric;
  discount_value numeric;
  taxable_value numeric;
  vat_value numeric;
  lht_value numeric;
  total_value numeric;
  existing_booking public.hotel_bookings%rowtype;
  new_booking_id uuid;
  new_confirmation text;
  hold_expires timestamptz;
  request_fingerprint jsonb;
begin
  if target_idempotency_key is null or target_guest is null or jsonb_typeof(target_guest) is distinct from 'object' then
    raise exception 'Booking request is invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_idempotency_key::text, 0));


  if target_guest_count is null or target_guest_count < 1
     or target_room_count is null or target_room_count < 1
     or target_room_count > 10 then
    raise exception 'Guest or room count is invalid';
  end if;

  if coalesce(length(trim(target_guest->>'first_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'last_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'email')), 0) = 0
     or coalesce(length(trim(target_guest->>'phone')), 0) = 0 then
    raise exception 'Guest name, email, and phone are required';
  end if;
  if length(target_guest->>'first_name') > 100
     or length(target_guest->>'last_name') > 100
     or length(target_guest->>'email') > 254
     or length(target_guest->>'phone') > 40
     or coalesce(length(target_special_requests), 0) > 2000 then
    raise exception 'Guest details are too long';
  end if;
  if lower(trim(target_guest->>'email')) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Guest email address is invalid';
  end if;

  if target_access_token_hash is null
     or length(target_access_token_hash) <> 64 then
    raise exception 'Booking access credential is invalid';
  end if;

  if target_preferences is null
     or jsonb_typeof(target_preferences) is distinct from 'array' then
    raise exception 'Room preferences must be an array';
  end if;

  if jsonb_array_length(target_preferences) > 10 then
    raise exception 'Too many room preferences were selected';
  end if;

  request_fingerprint := jsonb_build_object(
    'roomId', target_room_id,
    'checkIn', target_check_in,
    'checkOut', target_check_out,
    'guestCount', target_guest_count,
    'roomCount', target_room_count,
    'guest', jsonb_build_object(
      'firstName', trim(target_guest->>'first_name'),
      'lastName', trim(target_guest->>'last_name'),
      'email', lower(trim(target_guest->>'email')),
      'phone', trim(target_guest->>'phone')
    ),
    'specialRequests', nullif(trim(target_special_requests), ''),
    'preferences', target_preferences,
    'userId', target_user_id
  );

  select *
    into existing_booking
    from public.hotel_bookings
   where idempotency_key = target_idempotency_key
   for update;

  if found then
    if existing_booking.access_token_hash <> target_access_token_hash
       or (existing_booking.user_id is not null and existing_booking.user_id is distinct from target_user_id)
       or (existing_booking.checkout_request is not null and existing_booking.checkout_request is distinct from request_fingerprint)
       or (existing_booking.checkout_request is null and (
         existing_booking.room_id <> target_room_id
         or existing_booking.check_in <> target_check_in
         or existing_booking.check_out <> target_check_out
         or existing_booking.guest_count <> target_guest_count
         or existing_booking.room_count <> target_room_count
         or existing_booking.guest_first_name <> trim(target_guest->>'first_name')
         or existing_booking.guest_last_name <> trim(target_guest->>'last_name')
         or lower(existing_booking.guest_email) <> lower(trim(target_guest->>'email'))
         or existing_booking.guest_phone <> trim(target_guest->>'phone')
         or existing_booking.special_requests is distinct from nullif(trim(target_special_requests), '')
         or existing_booking.room_preferences is distinct from target_preferences
       )) then
      raise exception 'Idempotency key was already used for different booking details';
    end if;
    if existing_booking.checkout_request is null then
      update public.hotel_bookings set checkout_request = request_fingerprint where id = existing_booking.id;
    end if;

    return query
    select existing_booking.id,
           existing_booking.confirmation_number,
           existing_booking.currency_code,
           existing_booking.nights,
           existing_booking.nightly_subtotal,
           existing_booking.discount_amount,
           existing_booking.taxable_subtotal,
           existing_booking.vat_amount,
           existing_booking.lht_amount,
           existing_booking.total_amount,
           existing_booking.hotel_classification,
           existing_booking.expires_at;
    return;
  end if;

  if target_check_in is null or target_check_out is null
     or target_check_in < current_date
     or target_check_out <= target_check_in
     or target_check_out > current_date + 365 then
    raise exception 'Select valid check-in and check-out dates';
  end if;

  if target_fx_rates is null
     or nullif(target_fx_rates->>'as_of', '') is null
     or (target_fx_rates->>'as_of')::timestamptz < now() - interval '36 hours'
     or (target_fx_rates->>'as_of')::timestamptz > now() + interval '5 minutes' then
    raise exception 'A current exchange-rate snapshot is required to calculate hotel levies';
  end if;

  select *
    into selected_room
    from public.hotel_rooms
   where id = target_room_id
     and status = 'published'
   for update;

  if not found then
    raise exception 'This room is not available for booking';
  end if;
  if selected_room.nightly_rate::text in ('NaN', 'Infinity', '-Infinity') or selected_room.nightly_rate <= 0 then
    raise exception 'This room has an invalid nightly rate';
  end if;

  select bo.hotel_classification
    into selected_classification
    from public.books_organizations as bo
   where bo.id = selected_room.organization_id;

  if selected_classification is null
     or selected_classification not between 1 and 5 then
    raise exception 'The hotel must set its star classification before accepting bookings';
  end if;

  if target_guest_count > selected_room.max_guests * target_room_count then
    raise exception 'Guest count exceeds the selected room capacity';
  end if;

  update public.hotel_bookings as hb
     set booking_status = 'expired',
         payment_status = 'cancelled'
   where hb.room_id = selected_room.id
     and hb.booking_status = 'pending'
     and hb.expires_at <= now();

  select coalesce(sum(hb.room_count), 0)
    into reserved_units
    from public.hotel_bookings as hb
   where hb.room_id = selected_room.id
     and (
       (
         hb.booking_status in ('confirmed', 'manual_review')
         and hb.payment_status = 'paid'
       )
       or (
         hb.booking_status = 'pending'
         and hb.payment_status = 'pending'
         and hb.expires_at > now()
       )
     )
     and hb.check_in < target_check_out
     and hb.check_out > target_check_in;

  if reserved_units + target_room_count > selected_room.available_units then
    raise exception 'The selected room is no longer available for these dates';
  end if;

  nights_count := target_check_out - target_check_in;
  currency_decimals := public.checkout_currency_minor_units(selected_room.currency_code);
  if currency_decimals is null then raise exception 'Room currency is not supported for checkout'; end if;
  if selected_room.nightly_rate <> round(selected_room.nightly_rate, currency_decimals)
     or (selected_room.original_nightly_rate is not null and selected_room.original_nightly_rate <> round(selected_room.original_nightly_rate, currency_decimals)) then
    raise exception 'Room rate does not match the currency precision';
  end if;

  room_subtotal := round(
    selected_room.nightly_rate * nights_count * target_room_count,
    currency_decimals
  );

  select coalesce(max(discount_percentage), 0)
    into discount_rate
    from public.hotel_booking_offers
   where is_active
     and minimum_nights <= nights_count
     and (starts_at is null or starts_at <= now())
     and (ends_at is null or ends_at > now());

  discount_value := round(
    room_subtotal * discount_rate / 100,
    currency_decimals
  );
  taxable_value := room_subtotal - discount_value;

  room_currency_per_ugx :=
    (target_fx_rates->>trim(selected_room.currency_code))::numeric;
  usd_per_ugx := (target_fx_rates->>'USD')::numeric;

  if room_currency_per_ugx is null
     or room_currency_per_ugx::text in ('NaN', 'Infinity', '-Infinity')
     or room_currency_per_ugx <= 0
     or usd_per_ugx is null
     or usd_per_ugx::text in ('NaN', 'Infinity', '-Infinity')
     or usd_per_ugx <= 0 then
    raise exception 'A current exchange-rate snapshot is required to calculate hotel levies';
  end if;

  room_rate_in_ugx :=
    (selected_room.nightly_rate * (1 - discount_rate / 100))
    / room_currency_per_ugx;

  if selected_classification in (4, 5) then
    local_hotel_tax_per_room := (2 / usd_per_ugx) * room_currency_per_ugx;
  elsif selected_classification in (2, 3) or room_rate_in_ugx > 50000 then
    local_hotel_tax_per_room := 2000 * room_currency_per_ugx;
  elsif room_rate_in_ugx >= 10000 then
    local_hotel_tax_per_room := 1000 * room_currency_per_ugx;
  else
    local_hotel_tax_per_room := 500 * room_currency_per_ugx;
  end if;

  vat_value := round(taxable_value * 0.18, currency_decimals);
  lht_value := round(
    local_hotel_tax_per_room * nights_count * target_room_count,
    currency_decimals
  );
  total_value := taxable_value + vat_value + lht_value;
  new_confirmation :=
    'ST-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  hold_expires := now() + interval '20 minutes';

  insert into public.hotel_bookings (
    confirmation_number, organization_id, room_id, user_id,
    check_in, check_out, nights, guest_count, room_count,
    guest_first_name, guest_last_name, guest_email, guest_phone,
    special_requests, room_preferences, currency_code,
    nightly_subtotal, discount_amount, taxable_subtotal,
    vat_amount, lht_amount, total_amount, hotel_classification,
    fx_rates_snapshot, expires_at, idempotency_key, access_token_hash, checkout_request
  )
  values (
    new_confirmation, selected_room.organization_id, selected_room.id,
    target_user_id, target_check_in, target_check_out, nights_count,
    target_guest_count, target_room_count,
    trim(target_guest->>'first_name'), trim(target_guest->>'last_name'),
    lower(trim(target_guest->>'email')), trim(target_guest->>'phone'),
    nullif(trim(target_special_requests), ''), target_preferences,
    selected_room.currency_code, room_subtotal, discount_value,
    taxable_value, vat_value, lht_value, total_value,
    selected_classification, target_fx_rates, hold_expires,
    target_idempotency_key, target_access_token_hash, request_fingerprint
  )
  on conflict (idempotency_key) do nothing
  returning id into new_booking_id;

  if new_booking_id is null then
    select *
      into existing_booking
      from public.hotel_bookings
     where idempotency_key = target_idempotency_key;

    if existing_booking.access_token_hash <> target_access_token_hash
       or (existing_booking.user_id is not null and existing_booking.user_id is distinct from target_user_id)
       or (existing_booking.checkout_request is not null and existing_booking.checkout_request is distinct from request_fingerprint) then
      raise exception 'Idempotency key was already used for different booking details';
    end if;

    return query
    select existing_booking.id,
           existing_booking.confirmation_number,
           existing_booking.currency_code,
           existing_booking.nights,
           existing_booking.nightly_subtotal,
           existing_booking.discount_amount,
           existing_booking.taxable_subtotal,
           existing_booking.vat_amount,
           existing_booking.lht_amount,
           existing_booking.total_amount,
           existing_booking.hotel_classification,
           existing_booking.expires_at;
    return;
  end if;

  return query
  select new_booking_id,
         new_confirmation,
         selected_room.currency_code,
         nights_count,
         room_subtotal,
         discount_value,
         taxable_value,
         vat_value,
         lht_value,
         total_value,
         selected_classification,
         hold_expires;
end;
$$;

create or replace function public.menu_capture_visible_to_current_user(target_order_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile_role text;
  order_user_id uuid;
  invoice_id uuid;
  seller_organization_id uuid;
begin
  select up.role into current_profile_role
    from public.user_profiles up
   where up.user_id = auth.uid();
  if current_profile_role = 'admin' then return true; end if;
  if current_profile_role is distinct from 'manager' then return false; end if;

  select mo.user_id, mo.books_invoice_id
    into order_user_id, invoice_id
    from public.menu_orders mo
   where mo.id = target_order_id;
  if not found then return false; end if;

  if invoice_id is not null then
    select invoice_row.organization_id into seller_organization_id
      from public.books_invoices invoice_row
     where invoice_row.id = invoice_id;
  end if;
  if seller_organization_id is null then
    select settings.organization_id into seller_organization_id
      from public.books_menu_sales_settings settings
     where settings.id = true;
  end if;
  if seller_organization_id is null then
    select bm.organization_id into seller_organization_id
      from public.menu_order_items order_item
      join public.menu_items menu_item on menu_item.id = order_item.menu_item_id
      join public.books_memberships bm on bm.user_id = menu_item.managed_by
     where order_item.order_id = target_order_id
     order by bm.created_at
     limit 1;
  end if;
  if seller_organization_id is null and order_user_id is not null then
    select bm.organization_id into seller_organization_id
      from public.books_memberships bm
     where bm.user_id = order_user_id
     order by bm.created_at
     limit 1;
  end if;

  return seller_organization_id is not null and exists (
    select 1
      from public.books_memberships bm
     where bm.user_id = auth.uid()
       and bm.organization_id = seller_organization_id
       and bm.role in ('owner', 'admin')
  );
end;
$$;
revoke all on function public.menu_capture_visible_to_current_user(uuid) from public, anon;
grant execute on function public.menu_capture_visible_to_current_user(uuid) to authenticated;

drop policy if exists menu_duplicate_payment_captures_manager_read on public.menu_duplicate_payment_captures;
create policy menu_duplicate_payment_captures_manager_read
  on public.menu_duplicate_payment_captures for select to authenticated
  using (public.menu_capture_visible_to_current_user(order_id));

grant select on public.special_event_payment_attempts to authenticated;

create or replace function public.calculate_books_invoice_line_total()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  line_total_is_generated boolean;
begin
  select attgenerated <> '' into line_total_is_generated
    from pg_attribute
   where attrelid = 'public.books_invoice_lines'::regclass
     and attname = 'line_total'
     and not attisdropped;
  if not coalesce(line_total_is_generated, false) then
    new.line_total := new.quantity * new.unit_price;
  end if;
  return new;
end;
$$;
revoke all on function public.calculate_books_invoice_line_total() from public, anon, authenticated;
drop trigger if exists zzz_checkout_invoice_line_total on public.books_invoice_lines;
create trigger zzz_checkout_invoice_line_total
before insert or update on public.books_invoice_lines
for each row execute function public.calculate_books_invoice_line_total();

notify pgrst, 'reload schema';
commit;
