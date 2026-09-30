-- Rename the applied event MVP objects without touching the unrelated events tables.

alter table public.hospitality_events rename to special_events;
alter table public.hospitality_event_favorites rename to special_event_favorites;
alter table public.hospitality_event_plans rename to special_event_plans;
alter table public.hospitality_event_bookings rename to special_event_bookings;
alter table public.hospitality_event_payment_attempts rename to special_event_payment_attempts;

do $$
declare
  object_record record;
  renamed_name text;
begin
  for object_record in
    select n.nspname as schema_name, c.relname as object_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'i'
      and c.relname like 'hospitality_event%'
  loop
    renamed_name := replace(object_record.object_name, 'hospitality', 'special');
    execute format(
      'alter index %I.%I rename to %I',
      object_record.schema_name,
      object_record.object_name,
      renamed_name
    );
  end loop;

  for object_record in
    select n.nspname as schema_name, c.relname as table_name, con.conname as constraint_name
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and con.conname like 'hospitality_event%'
  loop
    renamed_name := replace(object_record.constraint_name, 'hospitality', 'special');
    execute format(
      'alter table %I.%I rename constraint %I to %I',
      object_record.schema_name,
      object_record.table_name,
      object_record.constraint_name,
      renamed_name
    );
  end loop;

  for object_record in
    select n.nspname as schema_name, c.relname as table_name, p.polname as policy_name
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and p.polname like 'hospitality_event%'
  loop
    renamed_name := replace(object_record.policy_name, 'hospitality', 'special');
    execute format(
      'alter policy %I on %I.%I rename to %I',
      object_record.policy_name,
      object_record.schema_name,
      object_record.table_name,
      renamed_name
    );
  end loop;
end;
$$;

alter function public.create_hospitality_event_booking(uuid, integer, text, text, text, text, text)
  rename to create_special_event_booking;
alter function public.confirm_hospitality_event_payment(uuid, text)
  rename to confirm_special_event_payment;
alter function public.confirm_free_hospitality_event_booking(uuid)
  rename to confirm_free_special_event_booking;

create or replace function public.create_special_event_booking(
  target_event_id uuid,
  target_quantity integer,
  guest_first_name text,
  guest_last_name text,
  guest_email text,
  guest_phone text,
  special_requests text default null
)
returns table (
  booking_id uuid,
  order_number text,
  total_amount numeric,
  currency text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_event public.special_events%rowtype;
  v_reserved_quantity bigint;
  v_booking_id uuid := gen_random_uuid();
  v_order_number text := 'HE-' || replace(v_booking_id::text, '-', '');
  v_confirmation_number text := 'PENDING-' || replace(v_booking_id::text, '-', '');
  v_subtotal numeric(12, 2);
  v_total numeric(12, 2);
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if target_quantity is null or target_quantity <= 0 then
    raise exception 'Booking quantity must be greater than zero';
  end if;

  if nullif(btrim(guest_first_name), '') is null
     or nullif(btrim(guest_last_name), '') is null
     or nullif(btrim(guest_email), '') is null then
    raise exception 'Guest first name, last name, and email are required';
  end if;

  select *
    into v_event
    from public.special_events
   where id = target_event_id
   for update;

  if not found then
    raise exception 'Special event not found';
  end if;

  if v_event.status <> 'published' or v_event.starts_at <= now() then
    raise exception 'Special event is not published and upcoming';
  end if;

  select coalesce(sum(quantity), 0)
    into v_reserved_quantity
    from public.special_event_bookings
   where event_id = target_event_id
     and (status = 'confirmed' or (status = 'pending' and (expires_at is null or expires_at > now())));

  if v_reserved_quantity + target_quantity > v_event.capacity then
    raise exception 'Special event capacity exceeded';
  end if;

  v_subtotal := round(v_event.price * target_quantity, 2);
  v_total := v_subtotal;

  insert into public.special_event_bookings (
    id,
    user_id,
    event_id,
    order_number,
    guest_first_name,
    guest_last_name,
    guest_email,
    guest_phone,
    special_requests,
    quantity,
    subtotal,
    service_fee,
    tax_amount,
    discount_amount,
    total_amount,
    currency,
    status,
    payment_status,
    confirmation_number,
    expires_at
  ) values (
    v_booking_id,
    v_user_id,
    target_event_id,
    v_order_number,
    btrim(guest_first_name),
    btrim(guest_last_name),
    btrim(guest_email),
    nullif(btrim(guest_phone), ''),
    special_requests,
    target_quantity,
    v_subtotal,
    0,
    0,
    0,
    v_total,
    v_event.currency,
    'pending',
    'pending',
    v_confirmation_number,
    now() + interval '15 minutes'
  );

  return query
  select v_booking_id, v_order_number, v_total, v_event.currency;
end;
$$;

create or replace function public.confirm_special_event_payment(
  target_booking_id uuid,
  target_transaction_id text
)
returns table (
  booking_id uuid,
  confirmation_number text,
  ticket_code text,
  order_number text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_confirmation text;
  v_ticket text;
begin
  select * into v_booking
  from public.special_event_bookings
  where id = target_booking_id
  for update;

  if not found then
    raise exception 'Special event booking not found';
  end if;
  if v_booking.payment_status = 'paid' and v_booking.status = 'confirmed' then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code, v_booking.order_number;
    return;
  end if;
  if v_booking.status <> 'pending' or v_booking.payment_status <> 'pending' then
    raise exception 'Special event booking is not pending';
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_ticket := 'TKT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

  update public.special_event_bookings
  set status = 'confirmed',
      payment_status = 'paid',
      confirmation_number = v_confirmation,
      ticket_code = v_ticket,
      updated_at = now()
  where id = target_booking_id;

  update public.special_events
  set attendees_count = attendees_count + v_booking.quantity,
      updated_at = now()
  where id = v_booking.event_id;

  return query select target_booking_id, v_confirmation, v_ticket, v_booking.order_number;
end;
$$;

create or replace function public.confirm_free_special_event_booking(target_booking_id uuid)
returns table (
  booking_id uuid,
  confirmation_number text,
  ticket_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_confirmation text;
  v_ticket text;
begin
  select * into v_booking
  from public.special_event_bookings
  where id = target_booking_id
    and user_id = auth.uid()
  for update;

  if not found then
    raise exception 'Special event booking not found';
  end if;
  if v_booking.total_amount <> 0 then
    raise exception 'Only free bookings can be confirmed this way';
  end if;
  if v_booking.status <> 'pending' or v_booking.payment_status <> 'pending' then
    raise exception 'Special event booking is not pending';
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_ticket := 'TKT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

  update public.special_event_bookings
  set status = 'confirmed',
      payment_status = 'paid',
      confirmation_number = v_confirmation,
      ticket_code = v_ticket,
      updated_at = now()
  where id = target_booking_id;

  update public.special_events
  set attendees_count = attendees_count + v_booking.quantity,
      updated_at = now()
  where id = v_booking.event_id;

  return query select target_booking_id, v_confirmation, v_ticket;
end;
$$;

revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text)
  from public;
grant execute on function public.create_special_event_booking(uuid, integer, text, text, text, text, text)
  to authenticated;
revoke all on function public.confirm_special_event_payment(uuid, text) from public, anon, authenticated;
grant execute on function public.confirm_special_event_payment(uuid, text) to service_role;
revoke all on function public.confirm_free_special_event_booking(uuid) from public;
grant execute on function public.confirm_free_special_event_booking(uuid) to authenticated;
