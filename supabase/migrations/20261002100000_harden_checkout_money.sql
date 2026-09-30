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
      and subtotal >= 0 and tax_amount >= 0 and service_fee >= 0 and tip_amount >= 0
      and points_discount = 0
      and total_amount = round(subtotal + tax_amount + service_fee + tip_amount - points_discount,
        public.checkout_currency_minor_units(currency))
    )
  ) not valid;

alter table public.menu_order_items
  drop constraint if exists menu_order_items_secure_line_total_check;
alter table public.menu_order_items
  add constraint menu_order_items_secure_line_total_check
  check (quantity > 0 and unit_price >= 0 and line_total = unit_price * quantity) not valid;

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
     or new.amount <> selected_order.total_amount
     or upper(new.currency) <> upper(selected_order.currency)
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
commit;
