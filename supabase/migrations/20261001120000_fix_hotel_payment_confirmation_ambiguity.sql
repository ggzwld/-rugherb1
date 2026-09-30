begin;

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
set search_path = public
as $$
declare
  attempt public.hotel_payment_attempts%rowtype;
  booking public.hotel_bookings%rowtype;
  room public.hotel_rooms%rowtype;
  target_room_id uuid;
  reserved_units integer;
  resolved_status text := 'confirmed';
begin
  select hb.room_id
    into target_room_id
    from public.hotel_payment_attempts as hpa
    join public.hotel_bookings as hb on hb.id = hpa.booking_id
   where hpa.tx_ref = target_tx_ref;

  if target_room_id is null then
    raise exception 'Hotel payment attempt was not found';
  end if;

  select *
    into room
    from public.hotel_rooms as hr
   where hr.id = target_room_id
   for update;

  if not found then
    raise exception 'Hotel room was not found';
  end if;

  select *
    into attempt
    from public.hotel_payment_attempts as hpa
   where hpa.tx_ref = target_tx_ref
   for update;

  if not found then
    raise exception 'Hotel payment attempt was not found';
  end if;

  select *
    into booking
    from public.hotel_bookings as hb
   where hb.id = attempt.booking_id
   for update;

  if not found then
    raise exception 'Hotel booking was not found';
  end if;

  if attempt.amount <> booking.total_amount
     or attempt.currency_code <> booking.currency_code then
    raise exception 'Payment attempt does not match booking amount';
  end if;

  if booking.payment_status = 'paid' then
    if attempt.transaction_id = target_transaction_id
       and attempt.status = 'completed' then
      return query
      select booking.id,
             booking.confirmation_number,
             booking.payment_status,
             booking.booking_status;
    else
      update public.hotel_payment_attempts
         set status = 'manual_review',
             transaction_id = target_transaction_id,
             completed_at = now()
       where id = attempt.id;

      return query
      select booking.id,
             booking.confirmation_number,
             'manual_review'::text,
             booking.booking_status;
    end if;
    return;
  end if;

  if booking.booking_status not in ('pending', 'expired', 'cancelled') then
    raise exception 'Hotel booking cannot be confirmed';
  end if;

  if booking.booking_status = 'cancelled' then
    resolved_status := 'manual_review';
  end if;

  update public.hotel_bookings as expired_booking
     set booking_status = 'expired',
         payment_status = 'cancelled'
   where expired_booking.room_id = booking.room_id
     and expired_booking.id <> booking.id
     and expired_booking.booking_status = 'pending'
     and expired_booking.expires_at <= now();

  select coalesce(sum(reservation.room_count), 0)
    into reserved_units
    from public.hotel_bookings as reservation
   where reservation.room_id = booking.room_id
     and reservation.id <> booking.id
     and (
       (
         reservation.booking_status in ('confirmed', 'manual_review')
         and reservation.payment_status = 'paid'
       )
       or (
         reservation.booking_status = 'pending'
         and reservation.payment_status = 'pending'
         and reservation.expires_at > now()
       )
     )
     and reservation.check_in < booking.check_out
     and reservation.check_out > booking.check_in;

  if booking.booking_status <> 'cancelled'
     and reserved_units + booking.room_count > room.available_units then
    resolved_status := 'manual_review';
  end if;

  update public.hotel_payment_attempts
     set status =
           case
             when resolved_status = 'manual_review' then 'manual_review'
             else 'completed'
           end,
         transaction_id = target_transaction_id,
         completed_at = now()
   where id = attempt.id;

  update public.hotel_bookings
     set payment_status = 'paid',
         booking_status = resolved_status,
         expires_at = null
   where id = booking.id;

  return query
  select booking.id,
         booking.confirmation_number,
         'paid'::text,
         resolved_status;
end;
$$;

revoke all on function public.confirm_hotel_booking_payment(text, text)
  from public, anon, authenticated;
grant execute on function public.confirm_hotel_booking_payment(text, text)
  to service_role;

notify pgrst, 'reload schema';
commit;
