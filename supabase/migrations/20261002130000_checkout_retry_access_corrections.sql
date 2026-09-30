begin;

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

notify pgrst, 'reload schema';
commit;
