begin;

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
commit;
