create table if not exists public.special_event_ticket_types (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete cascade,
  name text not null default 'General Admission',
  description text,
  price numeric(12, 2) not null check (price >= 0),
  capacity integer check (capacity > 0),
  max_per_order integer not null default 10 check (max_per_order > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, name)
);

alter table public.special_events
  add column if not exists default_ticket_type_id uuid,
  add column if not exists ticket_type_capacity integer,
  add column if not exists max_tickets_per_order integer not null default 10,
  add column if not exists books_accounting_status text not null default 'pending',
  add column if not exists books_accounting_error text;

alter table public.special_event_bookings
  add column if not exists ticket_type_id uuid,
  add column if not exists attendee_names text[] not null default '{}',
  add column if not exists idempotency_key uuid,
  add column if not exists payment_verified_at timestamptz,
  add column if not exists books_invoice_id uuid,
  add column if not exists books_accounting_status text not null default 'pending',
  add column if not exists books_accounting_error text;

insert into public.special_event_ticket_types (event_id, name, price, capacity, max_per_order)
select id, 'General Admission', price, null, 10
from public.special_events
on conflict (event_id, name) do nothing;

update public.special_events e
set default_ticket_type_id = t.id,
    ticket_type_capacity = t.capacity
from public.special_event_ticket_types t
where t.event_id = e.id
  and t.name = 'General Admission'
  and e.default_ticket_type_id is null;

update public.special_event_bookings b
set ticket_type_id = e.default_ticket_type_id,
    attendee_names = array_fill(concat_ws(' ', b.guest_first_name, b.guest_last_name), array[b.quantity])
from public.special_events e
where e.id = b.event_id
  and b.ticket_type_id is null;

alter table public.special_event_bookings
  alter column ticket_type_id set not null;

alter table public.special_events
  add constraint special_events_default_ticket_type_fk
  foreign key (default_ticket_type_id) references public.special_event_ticket_types(id) on delete restrict;
alter table public.special_event_bookings
  add constraint special_event_bookings_ticket_type_fk
  foreign key (ticket_type_id) references public.special_event_ticket_types(id) on delete restrict;

create table if not exists public.special_event_tickets (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete restrict,
  booking_id uuid not null references public.special_event_bookings(id) on delete cascade,
  ticket_type_id uuid not null references public.special_event_ticket_types(id) on delete restrict,
  ticket_number integer not null check (ticket_number > 0),
  ticket_token text not null unique,
  attendee_name text not null,
  attendee_email text not null,
  status text not null default 'valid' check (status in ('valid', 'checked_in', 'void', 'refunded')),
  issued_at timestamptz not null default now(),
  checked_in_at timestamptz,
  checked_in_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_id, ticket_number),
  check ((status = 'checked_in') = (checked_in_at is not null))
);

insert into public.special_event_tickets (
  event_id, booking_id, ticket_type_id, ticket_number, ticket_token, attendee_name, attendee_email, status
)
select b.event_id, b.id, b.ticket_type_id, seq,
       case when seq = 1 and nullif(b.ticket_code, '') is not null then b.ticket_code
            else replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') end,
       concat_ws(' ', b.guest_first_name, b.guest_last_name), b.guest_email, 'valid'
from public.special_event_bookings b
cross join lateral generate_series(1, b.quantity) seq
where b.status = 'confirmed'
  and b.payment_status = 'paid'
on conflict (booking_id, ticket_number) do nothing;

update public.special_event_bookings b
set ticket_code = t.ticket_token
from public.special_event_tickets t
where t.booking_id = b.id
  and t.ticket_number = 1
  and b.status = 'confirmed'
  and b.payment_status = 'paid';

create table if not exists public.special_event_staff (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('manager', 'scanner')),
  status text not null default 'active' check (status in ('active', 'revoked')),
  added_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, user_id)
);

create table if not exists public.special_event_checkin_attempts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete cascade,
  ticket_id uuid references public.special_event_tickets(id) on delete set null,
  checked_by uuid not null references auth.users(id) on delete restrict,
  result text not null check (result in ('checked_in', 'already_checked_in', 'invalid', 'wrong_event', 'void', 'refunded')),
  created_at timestamptz not null default now()
);

create table if not exists public.special_event_payments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.special_events(id) on delete restrict,
  booking_id uuid not null unique references public.special_event_bookings(id) on delete restrict,
  payment_attempt_id uuid references public.special_event_payment_attempts(id) on delete restrict,
  provider text not null default 'flutterwave',
  transaction_id text,
  tx_ref text not null,
  amount numeric(12, 2) not null check (amount >= 0),
  currency text not null check (char_length(currency) = 3),
  status text not null check (status in ('successful', 'manual_review', 'refunded', 'chargeback')),
  paid_at timestamptz,
  books_invoice_id uuid,
  books_accounting_status text not null default 'pending',
  books_accounting_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists special_event_payments_transaction_id_key
  on public.special_event_payments (transaction_id) where transaction_id is not null;
create index if not exists special_event_tickets_event_status_idx
  on public.special_event_tickets (event_id, status, issued_at);
create index if not exists special_event_tickets_booking_idx
  on public.special_event_tickets (booking_id, ticket_number);
create index if not exists special_event_tickets_attendee_email_idx
  on public.special_event_tickets (event_id, attendee_email);
create index if not exists special_event_checkin_attempts_event_created_idx
  on public.special_event_checkin_attempts (event_id, created_at desc);
create index if not exists special_event_staff_event_status_idx
  on public.special_event_staff (event_id, status, role);
with ranked_attempts as (
  select id, row_number() over (partition by booking_id order by created_at desc) as attempt_rank
  from public.special_event_payment_attempts
  where status in ('initiated', 'redirected', 'verified')
)
update public.special_event_payment_attempts p
set status = 'expired', updated_at = now()
from ranked_attempts r
where r.id = p.id and r.attempt_rank > 1;

create unique index if not exists special_event_payment_attempts_one_active_per_booking
  on public.special_event_payment_attempts (booking_id)
  where status in ('initiated', 'redirected', 'verified');

alter table public.special_event_payment_attempts
  drop constraint if exists special_event_payment_attempts_status_check;
alter table public.special_event_payment_attempts
  add constraint special_event_payment_attempts_status_check
  check (status in ('initiated', 'redirected', 'verified', 'successful', 'failed', 'cancelled', 'expired', 'manual_review', 'refunded', 'chargeback')) not valid;

alter table public.special_event_bookings
  drop constraint if exists special_event_bookings_status_check;
alter table public.special_event_bookings
  add constraint special_event_bookings_status_check
  check (status in ('pending', 'confirmed', 'cancelled', 'refunded', 'manual_review', 'expired')) not valid;
alter table public.special_event_bookings
  drop constraint if exists special_event_bookings_payment_status_check;
alter table public.special_event_bookings
  add constraint special_event_bookings_payment_status_check
  check (payment_status in ('pending', 'paid', 'failed', 'cancelled', 'refunded', 'partially_refunded', 'chargeback', 'expired', 'manual_review')) not valid;

create unique index if not exists special_event_bookings_idempotency_key
  on public.special_event_bookings (user_id, idempotency_key) where idempotency_key is not null;

create or replace function public.sync_special_event_default_ticket_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ticket_type_id uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.special_event_ticket_types (event_id, name, price, capacity, max_per_order)
    values (new.id, 'General Admission', new.price, new.ticket_type_capacity, new.max_tickets_per_order)
    on conflict (event_id, name) do update
      set price = excluded.price, capacity = excluded.capacity,
          max_per_order = excluded.max_per_order, updated_at = now()
    returning id into ticket_type_id;
    update public.special_events set default_ticket_type_id = ticket_type_id where id = new.id;
    return new;
  end if;

  update public.special_event_ticket_types
  set price = new.price,
      capacity = new.ticket_type_capacity,
      max_per_order = new.max_tickets_per_order,
      updated_at = now()
  where id = new.default_ticket_type_id;
  return new;
end;
$$;

drop trigger if exists special_event_default_ticket_type_insert on public.special_events;
create trigger special_event_default_ticket_type_insert
after insert on public.special_events
for each row execute function public.sync_special_event_default_ticket_type();
drop trigger if exists special_event_default_ticket_type_update on public.special_events;
create trigger special_event_default_ticket_type_update
after update of price, ticket_type_capacity, max_tickets_per_order on public.special_events
for each row execute function public.sync_special_event_default_ticket_type();

create or replace function public.is_special_event_manager(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  ) or (exists (
    select 1 from public.special_events e
    where e.id = target_event_id
      and (e.organizer_id = auth.uid() or e.created_by = auth.uid())
  ) and exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid() and p.role = 'manager'
  )) or exists (
    select 1 from public.special_event_staff s
    where s.event_id = target_event_id and s.user_id = auth.uid()
      and s.status = 'active' and s.role = 'manager'
  );
$$;

create or replace function public.can_operate_special_event(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_special_event_manager(target_event_id) or exists (
    select 1 from public.special_event_staff s
    where s.event_id = target_event_id and s.user_id = auth.uid()
      and s.status = 'active' and s.role in ('manager', 'scanner')
  );
$$;

alter table public.special_event_ticket_types enable row level security;
alter table public.special_event_tickets enable row level security;
alter table public.special_event_staff enable row level security;
alter table public.special_event_checkin_attempts enable row level security;
alter table public.special_event_payments enable row level security;

create policy special_event_ticket_types_public_select
  on public.special_event_ticket_types for select to anon, authenticated
  using (is_active and exists (select 1 from public.special_events e where e.id = event_id and e.status = 'published'));
create policy special_event_ticket_types_manager_select
  on public.special_event_ticket_types for select to authenticated
  using (public.is_special_event_manager(event_id));
drop policy if exists special_events_owner_insert on public.special_events;
drop policy if exists special_events_owner_update on public.special_events;
drop policy if exists special_events_owner_delete on public.special_events;
create policy special_events_manager_insert
  on public.special_events for insert to authenticated
  with check (
    organizer_id = auth.uid() and created_by = auth.uid()
    and exists (select 1 from public.user_profiles p where p.user_id = auth.uid() and p.role in ('manager', 'admin'))
  );
create policy special_events_manager_update
  on public.special_events for update to authenticated
  using (public.is_special_event_manager(id))
  with check (public.is_special_event_manager(id));
create policy special_events_manager_delete
  on public.special_events for delete to authenticated
  using (public.is_special_event_manager(id));
create policy special_event_tickets_owner_select
  on public.special_event_tickets for select to authenticated
  using (exists (
    select 1 from public.special_event_bookings b
    where b.id = booking_id and b.user_id = auth.uid()
  ));
create policy special_event_staff_manager_select
  on public.special_event_staff for select to authenticated
  using (public.is_special_event_manager(event_id) or user_id = auth.uid());
create policy special_event_payments_owner_select
  on public.special_event_payments for select to authenticated
  using (exists (
    select 1 from public.special_event_bookings b
    where b.id = booking_id and b.user_id = auth.uid()
  ));

create table if not exists public.special_event_payment_refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.special_event_payments(id) on delete restrict,
  amount numeric(12, 2) not null check (amount > 0),
  currency text not null check (char_length(currency) = 3),
  provider_refund_reference text not null,
  reason text not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (payment_id)
);
alter table public.special_event_payment_refunds enable row level security;

create table if not exists public.special_event_ticket_email_deliveries (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.special_event_bookings(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'skipped')),
  attempt_count integer not null default 1,
  pg_net_request_id bigint,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (booking_id)
);
alter table public.special_event_ticket_email_deliveries enable row level security;

create or replace function public.queue_special_event_ticket_email(target_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  delivery_id uuid;
  request_id bigint;
  webhook_secret text;
begin
  select decrypted_secret into webhook_secret
  from vault.decrypted_secrets
  where name = 'supabase_webhook_secret'
  limit 1;
  if webhook_secret is null or webhook_secret = '' then
    raise exception 'Vault secret supabase_webhook_secret is not configured';
  end if;

  insert into public.special_event_ticket_email_deliveries (booking_id, status, attempt_count)
  values (target_booking_id, 'queued', 1)
  on conflict (booking_id) do update
    set status = 'queued', attempt_count = special_event_ticket_email_deliveries.attempt_count + 1,
        error_message = null, updated_at = now()
    where special_event_ticket_email_deliveries.status in ('failed', 'skipped')
  returning id into delivery_id;

  if delivery_id is null then
    select id into delivery_id from public.special_event_ticket_email_deliveries where booking_id = target_booking_id;
    return delivery_id;
  end if;

  select net.http_post(
    url := 'https://us-central1-speshio.cloudfunctions.net/generateAndSendSpecialEventTickets',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Webhook-Secret', webhook_secret),
    body := jsonb_build_object('deliveryId', delivery_id),
    timeout_milliseconds := 10000
  ) into request_id;

  update public.special_event_ticket_email_deliveries
  set pg_net_request_id = request_id, updated_at = now()
  where id = delivery_id;
  return delivery_id;
end;
$$;

create or replace function public.on_special_event_booking_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'confirmed' and new.payment_status = 'paid'
     and (tg_op = 'INSERT' or old.status is distinct from 'confirmed' or old.payment_status is distinct from 'paid') then
    perform public.queue_special_event_ticket_email(new.id);
  end if;
  return new;
exception when others then
  insert into public.special_event_ticket_email_deliveries (booking_id, status, attempt_count, error_message)
  values (new.id, 'failed', 1, left(sqlerrm, 2000))
  on conflict (booking_id) do update set
    status = 'failed', error_message = left(sqlerrm, 2000), updated_at = now();
  return new;
end;
$$;
drop trigger if exists special_event_ticket_email_paid on public.special_event_bookings;
create trigger special_event_ticket_email_paid
after insert or update of status, payment_status on public.special_event_bookings
for each row execute function public.on_special_event_booking_paid();

create or replace function public.retry_special_event_ticket_email(target_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare event_id uuid;
begin
  select b.event_id into event_id from public.special_event_bookings b where b.id = target_booking_id;
  if event_id is null or not public.is_special_event_manager(event_id) then
    raise exception 'Only the event manager can retry ticket email delivery';
  end if;
  if not exists (select 1 from public.special_event_bookings where id = target_booking_id and status = 'confirmed' and payment_status = 'paid') then
    raise exception 'Only confirmed tickets can be emailed';
  end if;
  return public.queue_special_event_ticket_email(target_booking_id);
end;
$$;

create or replace function public.expire_special_event_holds(target_event_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare affected integer;
begin
  update public.special_event_bookings
  set status = 'expired', payment_status = 'expired', updated_at = now()
  where status = 'pending' and payment_status = 'pending'
    and expires_at is not null and expires_at <= now()
    and (target_event_id is null or event_id = target_event_id);
  get diagnostics affected = row_count;
  update public.special_event_payment_attempts p
  set status = 'expired', updated_at = now()
  from public.special_event_bookings b
  where b.id = p.booking_id and b.status = 'expired'
    and p.status in ('initiated', 'redirected');
  return affected;
end;
$$;

drop function if exists public.create_special_event_booking(uuid, integer, text, text, text, text, text);
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

  select id, order_number into v_booking_id, v_order_number
  from public.special_event_bookings
  where user_id = v_user_id and idempotency_key = target_idempotency_key;
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

drop function if exists public.create_special_event_booking(uuid, integer, text, text, text, text, text);

drop function if exists public.confirm_special_event_payment(uuid, text);
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
  select event_id into v_event.id from public.special_event_bookings where id = target_booking_id;
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

  select * into v_payment from public.special_event_payment_attempts
  where booking_id = v_booking.id and transaction_id = target_transaction_id and status in ('verified', 'manual_review')
  for update;
  if not found then raise exception 'Verified payment attempt not found'; end if;
  if v_payment.amount <> v_booking.total_amount or upper(v_payment.currency) <> upper(v_booking.currency) then
    raise exception 'Verified payment amount does not match booking';
  end if;

  select v_event.capacity - coalesce(sum(quantity), 0) into v_remaining
  from public.special_event_bookings
  where event_id = v_event.id and id <> v_booking.id
    and (status = 'confirmed' or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
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
  select ticket_token into v_ticket from public.special_event_tickets
  where booking_id = v_booking.id and ticket_number = 1;

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
  ) on conflict (booking_id) do update set
    status = 'successful', payment_attempt_id = excluded.payment_attempt_id,
    transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
    amount = excluded.amount, currency = excluded.currency, paid_at = excluded.paid_at, updated_at = now();
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.order_number, 'paid'::text;
end;
$$;

drop function if exists public.confirm_free_special_event_booking(uuid);
create or replace function public.confirm_free_special_event_booking(target_booking_id uuid)
returns table (booking_id uuid, confirmation_number text, ticket_code text, ticket_count integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_event public.special_events%rowtype;
  v_confirmation text;
  v_ticket text;
  v_remaining bigint;
  v_type_remaining bigint;
begin
  select event_id into v_event.id from public.special_event_bookings
  where id = target_booking_id and user_id = auth.uid();
  if not found then raise exception 'Special event booking not found'; end if;
  select * into v_event from public.special_events where id = v_event.id for update;
  perform public.expire_special_event_holds(v_event.id);
  select * into v_booking from public.special_event_bookings
  where id = target_booking_id and user_id = auth.uid() for update;
  if v_booking.total_amount <> 0 then raise exception 'Only free bookings can be confirmed this way'; end if;
  if v_booking.status = 'confirmed' and v_booking.payment_status = 'paid' then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code, v_booking.quantity;
    return;
  end if;
  if v_booking.status <> 'pending' or v_booking.payment_status <> 'pending' or v_booking.expires_at <= now() then
    raise exception 'Special event booking hold has expired';
  end if;
  select v_event.capacity - coalesce(sum(quantity), 0) into v_remaining
  from public.special_event_bookings
  where event_id = v_event.id and id <> v_booking.id and status = 'confirmed';
  select v_type.capacity - coalesce(sum(b.quantity), 0) into v_type_remaining
  from public.special_event_ticket_types v_type
  left join public.special_event_bookings b on b.ticket_type_id = v_type.id and b.id <> v_booking.id and b.status = 'confirmed'
  where v_type.id = v_booking.ticket_type_id group by v_type.capacity;
  if v_remaining < v_booking.quantity or (v_type_remaining is not null and v_type_remaining < v_booking.quantity) then
    raise exception 'Special event capacity exceeded';
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
  update public.special_events set attendees_count = attendees_count + v_booking.quantity, updated_at = now()
  where id = v_event.id;
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.quantity;
end;
$$;

create or replace function public.check_in_special_event_ticket(target_event_id uuid, target_ticket_token text)
returns table (
  result text,
  ticket_id uuid,
  attendee_name text,
  ticket_type text,
  checked_in_at timestamptz,
  checked_in_by_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket public.special_event_tickets%rowtype;
  v_result text;
  v_name text;
begin
  if auth.uid() is null or not public.can_operate_special_event(target_event_id) then
    raise exception 'You are not authorized to check in this event';
  end if;
  select * into v_ticket from public.special_event_tickets
  where ticket_token = target_ticket_token for update;
  if not found then
    insert into public.special_event_checkin_attempts (event_id, checked_by, result)
    values (target_event_id, auth.uid(), 'invalid');
    return query select 'invalid'::text, null::uuid, null::text, null::text, null::timestamptz, null::text;
    return;
  end if;
  if v_ticket.event_id <> target_event_id then
    v_result := 'wrong_event';
  elsif v_ticket.status = 'checked_in' then
    v_result := 'already_checked_in';
  elsif v_ticket.status = 'void' then
    v_result := 'void';
  elsif v_ticket.status = 'refunded' then
    v_result := 'refunded';
  else
    update public.special_event_tickets
    set status = 'checked_in', checked_in_at = now(), checked_in_by = auth.uid(), updated_at = now()
    where id = v_ticket.id returning * into v_ticket;
    v_result := 'checked_in';
  end if;
  insert into public.special_event_checkin_attempts (event_id, ticket_id, checked_by, result)
  values (target_event_id, v_ticket.id, auth.uid(), v_result);
  select nullif(trim(concat_ws(' ', first_name, last_name)), '') into v_name
  from public.user_profiles where user_id = v_ticket.checked_in_by;
  return query select v_result, v_ticket.id, v_ticket.attendee_name, t.name,
    v_ticket.checked_in_at, v_name
  from public.special_event_ticket_types t where t.id = v_ticket.ticket_type_id;
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
    ) else jsonb_build_object(
      'capacity', e.capacity,
      'checked_in', coalesce((select count(*) from public.special_event_tickets t where t.event_id = e.id and t.status = 'checked_in'), 0)
    ) end,
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
        'books_accounting_status', b.books_accounting_status,
        'ticket_email_status', (select d.status from public.special_event_ticket_email_deliveries d where d.booking_id = b.id),
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

create or replace function public.assign_special_event_staff(target_event_id uuid, staff_email text, staff_role text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare staff_user_id uuid;
begin
  if not public.is_special_event_manager(target_event_id) then raise exception 'Only the event manager can assign staff'; end if;
  if staff_role not in ('manager', 'scanner') then raise exception 'Staff role is invalid'; end if;
  select user_id into staff_user_id from public.user_profiles where lower(email) = lower(trim(staff_email)) limit 1;
  if staff_user_id is null then raise exception 'A registered user with that email was not found'; end if;
  insert into public.special_event_staff (event_id, user_id, role, added_by)
  values (target_event_id, staff_user_id, staff_role, auth.uid())
  on conflict (event_id, user_id) do update set role = excluded.role, status = 'active', updated_at = now();
  return staff_user_id;
end;
$$;

create or replace function public.revoke_special_event_staff(target_staff_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare target_event_id uuid;
begin
  select event_id into target_event_id from public.special_event_staff where id = target_staff_id;
  if target_event_id is null or not public.is_special_event_manager(target_event_id) then raise exception 'Only the event manager can revoke staff'; end if;
  update public.special_event_staff set status = 'revoked', updated_at = now() where id = target_staff_id;
end;
$$;

create or replace function public.resolve_special_event_payment_review(
  target_booking_id uuid,
  resolution text,
  provider_refund_reference text default null,
  refund_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id uuid;
  transaction_reference text;
  resolution_result text;
begin
  select b.event_id into event_id from public.special_event_bookings b where b.id = target_booking_id;
  if event_id is null or not public.is_special_event_manager(event_id) then
    raise exception 'Only the event manager can resolve payment review';
  end if;
  if resolution = 'issue_tickets' then
    if exists (select 1 from public.special_event_tickets where booking_id = target_booking_id) then
      raise exception 'Tickets have already been issued for this booking';
    end if;
    select transaction_id into transaction_reference
    from public.special_event_payments where booking_id = target_booking_id and status = 'manual_review';
    if transaction_reference is null then raise exception 'Verified payment record not found'; end if;
    update public.special_event_payment_attempts set status = 'verified', updated_at = now()
    where booking_id = target_booking_id and transaction_id = transaction_reference;
    select payment_status into resolution_result
    from public.confirm_special_event_payment(target_booking_id, transaction_reference);
    return resolution_result;
  elsif resolution = 'refund' then
    perform public.record_special_event_full_refund(target_booking_id, provider_refund_reference, refund_reason);
    return 'refunded';
  end if;
  raise exception 'Payment review resolution is invalid';
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
begin
  select event_id into v_booking.event_id from public.special_event_bookings where id = target_booking_id;
  if not found or not public.is_special_event_manager(v_booking.event_id) then raise exception 'Only the event manager can record a refund'; end if;
  select * into v_payment from public.special_event_payments where booking_id = target_booking_id for update;
  if not found or v_payment.status not in ('successful', 'manual_review') then raise exception 'Only a verified payment can be refunded'; end if;
  if exists (select 1 from public.special_event_tickets where booking_id = target_booking_id and status = 'checked_in') then
    raise exception 'A checked-in booking cannot be refunded through this workflow';
  end if;
  if nullif(trim(provider_refund_reference), '') is null or nullif(trim(refund_reason), '') is null then
    raise exception 'A provider refund reference and reason are required';
  end if;
  insert into public.special_event_payment_refunds (payment_id, amount, currency, provider_refund_reference, reason, recorded_by)
  values (v_payment.id, v_payment.amount, v_payment.currency, trim(provider_refund_reference), trim(refund_reason), auth.uid());
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
end;
$$;

create or replace function public.post_special_event_payment_to_books()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  seller_organization_id uuid;
  customer_contact_id uuid;
  invoice_uuid uuid;
  customer_name text;
  customer_email text;
  customer_phone text;
  booking_row public.special_event_bookings%rowtype;
  event_row public.special_events%rowtype;
begin
  if new.status <> 'successful' then return new; end if;
  select * into booking_row from public.special_event_bookings where id = new.booking_id;
  select * into event_row from public.special_events where id = new.event_id;
  select organization_id into seller_organization_id from public.books_menu_sales_settings where id = true;
  if seller_organization_id is null then
    select organization_id into seller_organization_id from public.books_memberships
    where user_id = event_row.organizer_id order by created_at limit 1;
  end if;
  if seller_organization_id is null then
    update public.special_event_payments set books_accounting_status = 'failed', books_accounting_error = 'Configure a Books organization for special event sales' where id = new.id;
    update public.special_event_bookings set books_accounting_status = 'failed', books_accounting_error = 'Configure a Books organization for special event sales' where id = new.booking_id;
    return new;
  end if;

  customer_name := nullif(trim(concat_ws(' ', booking_row.guest_first_name, booking_row.guest_last_name)), '');
  customer_email := nullif(trim(booking_row.guest_email), '');
  customer_phone := nullif(trim(booking_row.guest_phone), '');
  if customer_email is not null then
    select id into customer_contact_id from public.books_contacts
    where organization_id = seller_organization_id and lower(email) = lower(customer_email)
      and type in ('customer', 'both') order by created_at limit 1;
  end if;
  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (seller_organization_id, coalesce(customer_name, customer_email, 'Event attendee'), 'customer', customer_email, customer_phone)
    returning id into customer_contact_id;
  end if;

  select id into invoice_uuid from public.books_invoices
  where organization_id = seller_organization_id and invoice_number = 'EVENT-' || booking_row.order_number;
  if invoice_uuid is null then
    insert into public.books_invoices (
      organization_id, contact_id, invoice_number, issue_date, due_date,
      currency_code, subtotal, tax_amount, status, notes
    ) values (
      seller_organization_id, customer_contact_id, 'EVENT-' || booking_row.order_number,
      coalesce(new.paid_at::date, current_date), coalesce(new.paid_at::date, current_date),
      upper(new.currency)::char(3), new.amount, 0, 'paid',
      'Verified special event payment ' || coalesce(new.transaction_id, new.tx_ref)
    ) returning id into invoice_uuid;
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    values (invoice_uuid, seller_organization_id, event_row.title || ' - ' || booking_row.quantity || ' admission(s)', 1, new.amount);
  end if;
  update public.special_event_payments set books_invoice_id = invoice_uuid, books_accounting_status = 'posted', books_accounting_error = null where id = new.id;
  update public.special_event_bookings set books_invoice_id = invoice_uuid, books_accounting_status = 'posted', books_accounting_error = null where id = new.booking_id;
  return new;
exception when others then
  update public.special_event_payments set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000) where id = new.id;
  update public.special_event_bookings set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000) where id = new.booking_id;
  return new;
end;
$$;
drop trigger if exists special_event_payment_books_accounting on public.special_event_payments;
create trigger special_event_payment_books_accounting
after insert or update of status on public.special_event_payments
for each row execute function public.post_special_event_payment_to_books();

drop function if exists public.create_special_event_booking(uuid, integer, text, text, text, text, text);
drop function if exists public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid);
revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[]) from public;
grant execute on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[]) to authenticated;
revoke all on function public.confirm_special_event_payment(uuid, text) from public, anon, authenticated;
grant execute on function public.confirm_special_event_payment(uuid, text) to service_role;
revoke all on function public.confirm_free_special_event_booking(uuid) from public;
grant execute on function public.confirm_free_special_event_booking(uuid) to authenticated;
revoke all on function public.check_in_special_event_ticket(uuid, text) from public, anon;
grant execute on function public.check_in_special_event_ticket(uuid, text) to authenticated;
revoke all on function public.get_special_event_operations(uuid) from public, anon;
grant execute on function public.get_special_event_operations(uuid) to authenticated;
revoke all on function public.assign_special_event_staff(uuid, text, text) from public, anon;
grant execute on function public.assign_special_event_staff(uuid, text, text) to authenticated;
revoke all on function public.revoke_special_event_staff(uuid) from public, anon;
grant execute on function public.revoke_special_event_staff(uuid) to authenticated;
revoke all on function public.record_special_event_full_refund(uuid, text, text) from public, anon;
grant execute on function public.record_special_event_full_refund(uuid, text, text) to authenticated;
revoke all on function public.queue_special_event_ticket_email(uuid) from public, anon, authenticated;
revoke all on function public.retry_special_event_ticket_email(uuid) from public, anon;
grant execute on function public.retry_special_event_ticket_email(uuid) to authenticated;
revoke all on function public.resolve_special_event_payment_review(uuid, text, text, text) from public, anon;
grant execute on function public.resolve_special_event_payment_review(uuid, text, text, text) to authenticated;
revoke all on function public.expire_special_event_holds(uuid) from public, anon, authenticated;
revoke all on function public.post_special_event_payment_to_books() from public, anon, authenticated;
