create or replace function public.create_special_event_booking(
  target_event_id uuid,
  target_quantity integer,
  guest_first_name text,
  guest_last_name text,
  guest_email text,
  guest_phone text,
  special_requests text default null,
  target_ticket_type_id uuid default null,
  target_idempotency_key uuid default null,
  target_attendee_names text[] default null
)
returns table (booking_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_event public.special_events%rowtype;
  v_type public.special_event_ticket_types%rowtype;
  v_reserved_event bigint;
  v_reserved_type bigint;
  v_booking_id uuid;
  v_order_number text;
  v_subtotal numeric(12, 2);
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

  select * into v_event from public.special_events where id = target_event_id for update;
  if not found then raise exception 'Special event not found'; end if;
  perform public.expire_special_event_holds(target_event_id);

  select * into v_type
  from public.special_event_ticket_types
  where id = coalesce(target_ticket_type_id, v_event.default_ticket_type_id)
    and event_id = target_event_id and is_active
  for update;
  if not found then raise exception 'Ticket type is not available'; end if;
  if v_event.status <> 'published' or v_event.starts_at <= now() then raise exception 'Special event is not published and upcoming'; end if;

  select b.id, b.order_number into v_booking_id, v_order_number
  from public.special_event_bookings b
  where b.user_id = v_user_id and b.idempotency_key = target_idempotency_key;
  if found then
    return query select b.id, b.order_number, b.total_amount, b.currency
    from public.special_event_bookings b where b.id = v_booking_id;
    return;
  end if;

  if target_quantity > v_type.max_per_order then raise exception 'Ticket quantity exceeds the per-order limit'; end if;
  select coalesce(sum(quantity), 0) into v_reserved_event
  from public.special_event_bookings
  where event_id = target_event_id
    and (status = 'confirmed' or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
  if v_reserved_event + target_quantity > v_event.capacity then raise exception 'Special event capacity exceeded'; end if;

  if v_type.capacity is not null then
    select coalesce(sum(quantity), 0) into v_reserved_type
    from public.special_event_bookings
    where ticket_type_id = v_type.id
      and (status = 'confirmed' or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
    if v_reserved_type + target_quantity > v_type.capacity then raise exception 'Ticket type capacity exceeded'; end if;
  end if;

  v_booking_id := gen_random_uuid();
  v_order_number := 'SE-' || upper(substr(replace(v_booking_id::text, '-', ''), 1, 16));
  v_subtotal := round(v_type.price * target_quantity, 2);
  insert into public.special_event_bookings (
    id, user_id, event_id, ticket_type_id, attendee_names, order_number,
    guest_first_name, guest_last_name, guest_email, guest_phone, special_requests,
    quantity, subtotal, service_fee, tax_amount, discount_amount, total_amount, currency,
    status, payment_status, confirmation_number, expires_at, idempotency_key
  ) values (
    v_booking_id, v_user_id, target_event_id, v_type.id,
    coalesce(target_attendee_names, array_fill(concat_ws(' ', btrim(guest_first_name), btrim(guest_last_name)), array[target_quantity])),
    v_order_number,
    btrim(guest_first_name), btrim(guest_last_name), btrim(guest_email), nullif(btrim(guest_phone), ''), special_requests,
    target_quantity, v_subtotal, 0, 0, 0, v_subtotal, v_event.currency,
    'pending', 'pending', 'PENDING-' || v_order_number, now() + interval '15 minutes', target_idempotency_key
  );
  return query select v_booking_id, v_order_number, v_subtotal, v_event.currency;
end;
$$;

notify pgrst, 'reload schema';
