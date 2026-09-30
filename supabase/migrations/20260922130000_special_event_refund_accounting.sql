alter table public.special_event_payment_refunds
  add column if not exists books_accounting_status text not null default 'pending',
  add column if not exists books_accounting_error text,
  add column if not exists books_journal_transaction_id uuid references public.books_journal_transactions(id) on delete restrict;

create or replace function public.post_special_event_refund_to_books(target_refund_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  refund_row public.special_event_payment_refunds%rowtype;
  payment_row public.special_event_payments%rowtype;
  booking_row public.special_event_bookings%rowtype;
  invoice_row public.books_invoices%rowtype;
  original_transaction_id uuid;
  refund_transaction_id uuid;
  seller_organization_id uuid;
  reversed_line_count integer;
begin
  select * into refund_row
  from public.special_event_payment_refunds
  where id = target_refund_id
  for update;
  if not found then raise exception 'Special event refund not found'; end if;

  select * into payment_row
  from public.special_event_payments
  where id = refund_row.payment_id
  for update;
  if not found or not public.is_special_event_manager(payment_row.event_id) then
    raise exception 'Only the event manager can post refund accounting';
  end if;
  if refund_row.books_accounting_status = 'posted' then return 'posted'; end if;

  begin
    select * into booking_row from public.special_event_bookings where id = payment_row.booking_id;
    if payment_row.books_invoice_id is null then raise exception 'The paid event invoice is not available'; end if;
    select * into invoice_row from public.books_invoices where id = payment_row.books_invoice_id for update;
    if not found then raise exception 'The paid event invoice is not available'; end if;
    select organization_id into seller_organization_id from public.books_invoices where id = invoice_row.id;

    select id into refund_transaction_id
    from public.books_journal_transactions
    where organization_id = seller_organization_id
      and source_type = 'special_event_refund'
      and source_id = refund_row.id;

    if refund_transaction_id is null then
      select id into original_transaction_id
      from public.books_journal_transactions
      where organization_id = seller_organization_id
        and source_type = 'invoice_payment'
        and source_id = invoice_row.id
      for update;
      if original_transaction_id is null then raise exception 'The original Books payment journal entry is not available'; end if;

      insert into public.books_journal_transactions (
        organization_id, source_type, source_id, transaction_date, description, created_by
      ) values (
        seller_organization_id, 'special_event_refund', refund_row.id, current_date,
        'Refund for event order ' || booking_row.order_number,
        auth.uid()
      ) returning id into refund_transaction_id;

      insert into public.books_journal_lines (
        transaction_id, account_id, debit, credit, currency_code, exchange_rate
      )
      select refund_transaction_id, account_id, credit, debit, currency_code, exchange_rate
      from public.books_journal_lines
      where transaction_id = original_transaction_id;
      get diagnostics reversed_line_count = row_count;
      if reversed_line_count = 0 then raise exception 'The original Books payment journal has no lines'; end if;
    end if;

    update public.books_invoices
    set status = 'void'
    where id = invoice_row.id and status in ('paid', 'void');

    update public.special_event_payment_refunds
    set books_accounting_status = 'posted', books_accounting_error = null,
        books_journal_transaction_id = refund_transaction_id
    where id = refund_row.id;
    update public.special_event_payments
    set books_accounting_status = 'refunded', books_accounting_error = null
    where id = payment_row.id;
    update public.special_event_bookings
    set books_accounting_status = 'refunded', books_accounting_error = null
    where id = booking_row.id;
    return 'posted';
  exception when others then
    update public.special_event_payment_refunds
    set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000)
    where id = refund_row.id;
    update public.special_event_payments
    set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000)
    where id = payment_row.id;
    update public.special_event_bookings
    set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000)
    where id = payment_row.booking_id;
    return 'failed';
  end;
end;
$$;

create or replace function public.retry_special_event_payment_books(target_booking_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_id uuid;
  target_event_id uuid;
  accounting_status text;
begin
  select p.id, p.event_id into payment_id, target_event_id
  from public.special_event_payments p
  where p.booking_id = target_booking_id and p.status = 'successful'
  for update;
  if payment_id is null or not public.is_special_event_manager(target_event_id) then
    raise exception 'Only the event manager can retry payment accounting';
  end if;
  update public.special_event_payments set status = 'successful', updated_at = now() where id = payment_id;
  select books_accounting_status into accounting_status from public.special_event_payments where id = payment_id;
  return accounting_status;
end;
$$;

create or replace function public.record_special_event_full_refund(
  target_booking_id uuid,
  provider_refund_reference text,
  refund_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_payment public.special_event_payments%rowtype;
  v_refund_id uuid;
begin
  select * into v_booking
  from public.special_event_bookings
  where id = target_booking_id
  for update;
  if not found or not public.is_special_event_manager(v_booking.event_id) then
    raise exception 'Only the event manager can record a refund';
  end if;

  select * into v_payment
  from public.special_event_payments
  where booking_id = target_booking_id
  for update;
  if not found or v_payment.status not in ('successful', 'manual_review') then
    raise exception 'Only a verified payment can be refunded';
  end if;
  perform 1 from public.special_event_tickets where booking_id = target_booking_id for update;
  if exists (select 1 from public.special_event_tickets where booking_id = target_booking_id and status = 'checked_in') then
    raise exception 'A checked-in booking cannot be refunded through this workflow';
  end if;
  if nullif(trim(provider_refund_reference), '') is null or nullif(trim(refund_reason), '') is null then
    raise exception 'A provider refund reference and reason are required';
  end if;

  insert into public.special_event_payment_refunds (
    payment_id, amount, currency, provider_refund_reference, reason, recorded_by
  ) values (
    v_payment.id, v_payment.amount, v_payment.currency,
    trim(provider_refund_reference), trim(refund_reason), auth.uid()
  ) returning id into v_refund_id;

  update public.special_event_payments set status = 'refunded', updated_at = now() where id = v_payment.id;
  update public.special_event_payment_attempts set status = 'refunded', updated_at = now() where id = v_payment.payment_attempt_id;
  update public.special_event_tickets set status = 'refunded', updated_at = now()
  where booking_id = target_booking_id and status = 'valid';
  update public.special_event_bookings set status = 'refunded', payment_status = 'refunded', updated_at = now()
  where id = target_booking_id;
  if v_booking.status = 'confirmed' then
    update public.special_events set attendees_count = greatest(attendees_count - v_booking.quantity, 0), updated_at = now()
    where id = v_booking.event_id;
  end if;

  perform public.post_special_event_refund_to_books(v_refund_id);
end;
$$;

create or replace function public.get_special_event_operations(target_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.can_operate_special_event(target_event_id) then
    raise exception 'You are not authorized to manage this event';
  end if;
  perform public.expire_special_event_holds(target_event_id);
  select jsonb_build_object(
    'access_role', case when public.is_special_event_manager(e.id) then 'manager' else 'scanner' end,
    'event', to_jsonb(e),
    'stats', case when public.is_special_event_manager(e.id) then jsonb_build_object(
      'capacity', e.capacity,
      'tickets_sold', coalesce((select count(*) from public.special_event_tickets t where t.event_id = e.id and t.status in ('valid', 'checked_in')), 0),
      'tickets_remaining', greatest(e.capacity - coalesce((select sum(b.quantity) from public.special_event_bookings b where b.event_id = e.id and (b.status = 'confirmed' or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))), 0), 0),
      'pending_holds', coalesce((select sum(b.quantity) from public.special_event_bookings b where b.event_id = e.id and b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()), 0),
      'paid_orders', coalesce((select count(*) from public.special_event_bookings b where b.event_id = e.id and b.payment_status = 'paid'), 0),
      'pending_payments', coalesce((select count(*) from public.special_event_bookings b where b.event_id = e.id and b.payment_status = 'pending' and b.expires_at > now()), 0),
      'manual_review', coalesce((select count(*) from public.special_event_bookings b where b.event_id = e.id and b.payment_status = 'manual_review'), 0),
      'cancelled_refunded', coalesce((select count(*) from public.special_event_bookings b where b.event_id = e.id and b.payment_status in ('cancelled', 'refunded', 'partially_refunded')), 0),
      'checked_in', coalesce((select count(*) from public.special_event_tickets t where t.event_id = e.id and t.status = 'checked_in'), 0),
      'duplicate_scans', coalesce((select count(*) from public.special_event_checkin_attempts a where a.event_id = e.id and a.result = 'already_checked_in'), 0),
      'failed_scans', coalesce((select count(*) from public.special_event_checkin_attempts a where a.event_id = e.id and a.result in ('invalid', 'wrong_event', 'void', 'refunded')), 0)
    ) else jsonb_build_object('capacity', e.capacity, 'checked_in', coalesce((select count(*) from public.special_event_tickets t where t.event_id = e.id and t.status = 'checked_in'), 0)) end,
    'tickets', case when public.is_special_event_manager(e.id) then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'booking_id', b.id, 'ticket_number', t.ticket_number, 'status', t.status,
        'attendee_name', t.attendee_name, 'attendee_email', t.attendee_email,
        'guest_phone', b.guest_phone, 'order_number', b.order_number, 'confirmation_number', b.confirmation_number,
        'payment_status', b.payment_status, 'ticket_type', tt.name, 'checked_in_at', t.checked_in_at,
        'checked_in_by', t.checked_in_by
      ) order by t.issued_at desc)
      from public.special_event_tickets t
      join public.special_event_bookings b on b.id = t.booking_id
      join public.special_event_ticket_types tt on tt.id = t.ticket_type_id
      where t.event_id = e.id
    ), '[]'::jsonb) else '[]'::jsonb end,
    'bookings', case when public.is_special_event_manager(e.id) then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'order_number', b.order_number, 'guest_first_name', b.guest_first_name,
        'guest_last_name', b.guest_last_name, 'guest_email', b.guest_email, 'guest_phone', b.guest_phone,
        'quantity', b.quantity, 'total_amount', b.total_amount, 'currency', b.currency,
        'status', b.status, 'payment_status', b.payment_status, 'created_at', b.created_at,
        'books_accounting_status', b.books_accounting_status, 'books_accounting_error', b.books_accounting_error,
        'ticket_email_status', (select d.status from public.special_event_ticket_email_deliveries d where d.booking_id = b.id),
        'ticket_email_error', (select d.error_message from public.special_event_ticket_email_deliveries d where d.booking_id = b.id),
        'refund_id', (select r.id from public.special_event_payment_refunds r join public.special_event_payments p on p.id = r.payment_id where p.booking_id = b.id),
        'refund_accounting_status', (select r.books_accounting_status from public.special_event_payment_refunds r join public.special_event_payments p on p.id = r.payment_id where p.booking_id = b.id),
        'refund_accounting_error', (select r.books_accounting_error from public.special_event_payment_refunds r join public.special_event_payments p on p.id = r.payment_id where p.booking_id = b.id),
        'attempts', (select coalesce(jsonb_agg(jsonb_build_object('tx_ref', p.tx_ref, 'status', p.status, 'amount', p.amount, 'currency', p.currency, 'created_at', p.created_at) order by p.created_at desc), '[]'::jsonb) from public.special_event_payment_attempts p where p.booking_id = b.id)
      ) order by b.created_at desc)
      from public.special_event_bookings b where b.event_id = e.id
    ), '[]'::jsonb) else '[]'::jsonb end,
    'staff', case when public.is_special_event_manager(e.id) then coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'user_id', s.user_id, 'email', p.email, 'role', s.role, 'status', s.status))
      from public.special_event_staff s left join public.user_profiles p on p.user_id = s.user_id
      where s.event_id = e.id and s.status = 'active'
    ), '[]'::jsonb) else '[]'::jsonb end
  ) into result
  from public.special_events e where e.id = target_event_id;
  return result;
end;
$$;

revoke all on function public.post_special_event_refund_to_books(uuid) from public, anon;
grant execute on function public.post_special_event_refund_to_books(uuid) to authenticated;
revoke all on function public.retry_special_event_payment_books(uuid) from public, anon;
grant execute on function public.retry_special_event_payment_books(uuid) to authenticated;
revoke all on function public.record_special_event_full_refund(uuid, text, text) from public, anon;
grant execute on function public.record_special_event_full_refund(uuid, text, text) to authenticated;
revoke all on function public.get_special_event_operations(uuid) from public, anon;
grant execute on function public.get_special_event_operations(uuid) to authenticated;
