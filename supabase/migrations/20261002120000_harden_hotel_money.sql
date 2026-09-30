begin;

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
commit;
