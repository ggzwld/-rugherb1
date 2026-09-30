create or replace function public.confirm_special_event_payment(
  target_booking_id uuid,
  target_transaction_id text
)
returns table (booking_id uuid, confirmation_number text, ticket_code text, order_number text, payment_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_payment public.special_event_payment_attempts%rowtype;
  v_event public.special_events%rowtype;
  v_confirmation text;
  v_ticket text;
  v_remaining bigint;
  v_type_remaining bigint;
  v_review boolean := false;
begin
  select b.event_id into v_event.id
  from public.special_event_bookings b
  where b.id = target_booking_id;
  if not found then raise exception 'Special event booking not found'; end if;
  select * into v_event from public.special_events where id = v_event.id for update;
  select * into v_booking from public.special_event_bookings where id = target_booking_id for update;

  if v_booking.payment_status = 'paid' and v_booking.status = 'confirmed' then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code, v_booking.order_number, v_booking.payment_status;
    return;
  end if;
  if not (
    (v_booking.status = 'pending' and v_booking.payment_status = 'pending')
    or (v_booking.status = 'expired' and v_booking.payment_status = 'expired')
    or (v_booking.status = 'manual_review' and v_booking.payment_status = 'manual_review')
  ) then raise exception 'Special event booking is not awaiting payment'; end if;

  select p.* into v_payment
  from public.special_event_payment_attempts p
  where p.booking_id = v_booking.id and p.transaction_id = target_transaction_id and p.status in ('verified', 'manual_review')
  for update;
  if not found then raise exception 'Verified payment attempt not found'; end if;
  if v_payment.amount <> v_booking.total_amount or upper(v_payment.currency) <> upper(v_booking.currency) then
    raise exception 'Verified payment amount does not match booking';
  end if;

  select v_event.capacity - coalesce(sum(b.quantity), 0) into v_remaining
  from public.special_event_bookings b
  where b.event_id = v_event.id and b.id <> v_booking.id
    and (b.status = 'confirmed' or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()));
  select v_type.capacity - coalesce(sum(b.quantity), 0) into v_type_remaining
  from public.special_event_ticket_types v_type
  left join public.special_event_bookings b on b.ticket_type_id = v_type.id and b.id <> v_booking.id
    and (b.status = 'confirmed' or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))
  where v_type.id = v_booking.ticket_type_id
  group by v_type.capacity;
  v_review := v_remaining < v_booking.quantity
    or (v_type_remaining is not null and v_type_remaining < v_booking.quantity);

  if v_review then
    update public.special_event_bookings
    set status = 'manual_review', payment_status = 'manual_review', payment_verified_at = now(), updated_at = now()
    where id = v_booking.id;
    update public.special_event_payment_attempts
    set status = 'manual_review', updated_at = now()
    where id = v_payment.id;
    insert into public.special_event_payments (
      event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
    ) values (
      v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
      v_payment.amount, v_payment.currency, 'manual_review', now()
    ) on conflict on constraint special_event_payments_booking_id_key do update set
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
  on conflict on constraint special_event_tickets_booking_id_ticket_number_key do nothing;
  select t.ticket_token into v_ticket from public.special_event_tickets t
  where t.booking_id = v_booking.id and t.ticket_number = 1;

  update public.special_event_bookings
  set status = 'confirmed', payment_status = 'paid', payment_verified_at = now(),
      confirmation_number = v_confirmation, ticket_code = v_ticket, updated_at = now()
  where id = v_booking.id;
  update public.special_event_payment_attempts
  set status = 'successful', updated_at = now()
  where id = v_payment.id;
  update public.special_events
  set attendees_count = attendees_count + v_booking.quantity, updated_at = now()
  where id = v_event.id;
  insert into public.special_event_payments (
    event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
  ) values (
    v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
    v_payment.amount, v_payment.currency, 'successful', now()
  ) on conflict on constraint special_event_payments_booking_id_key do update set
    status = 'successful', payment_attempt_id = excluded.payment_attempt_id,
    transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
    amount = excluded.amount, currency = excluded.currency, paid_at = excluded.paid_at, updated_at = now();
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.order_number, 'paid'::text;
end;
$$;

notify pgrst, 'reload schema';
