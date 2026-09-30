-- Hospitality events general-admission MVP schema.

create table if not exists public.hospitality_events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  category text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  timezone text not null default 'UTC',
  location text not null,
  price numeric(12, 2) not null default 0 check (price >= 0),
  currency text not null default 'UGX' check (char_length(currency) = 3),
  capacity integer not null check (capacity > 0),
  attendees_count integer not null default 0 check (attendees_count >= 0),
  featured boolean not null default false,
  rating numeric(3, 2) not null default 0 check (rating >= 0 and rating <= 5),
  host_name text,
  image_url text,
  status text not null default 'draft'
    check (status in ('draft', 'published', 'cancelled', 'completed')),
  organizer_id uuid not null references auth.users(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.hospitality_event_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.hospitality_events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

create table if not exists public.hospitality_event_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  event_date date not null,
  location text not null,
  expected_guests integer not null default 1 check (expected_guests > 0),
  description text,
  is_private boolean not null default false,
  status text not null default 'draft'
    check (status in ('draft', 'submitted', 'approved', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hospitality_event_bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  event_id uuid not null references public.hospitality_events(id) on delete restrict,
  order_number text not null unique,
  guest_first_name text not null,
  guest_last_name text not null,
  guest_email text not null,
  guest_phone text,
  special_requests text,
  quantity integer not null check (quantity > 0),
  subtotal numeric(12, 2) not null check (subtotal >= 0),
  service_fee numeric(12, 2) not null default 0 check (service_fee >= 0),
  tax_amount numeric(12, 2) not null default 0 check (tax_amount >= 0),
  discount_amount numeric(12, 2) not null default 0 check (discount_amount >= 0),
  total_amount numeric(12, 2) not null check (total_amount >= 0),
  currency text not null check (char_length(currency) = 3),
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'cancelled', 'refunded')),
  payment_status text not null default 'pending'
    check (payment_status in ('pending', 'paid', 'failed', 'cancelled')),
  confirmation_number text not null unique,
  ticket_code text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hospitality_event_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.hospitality_event_bookings(id) on delete cascade,
  tx_ref text not null unique,
  transaction_id text,
  amount numeric(12, 2) not null check (amount >= 0),
  currency text not null check (char_length(currency) = 3),
  status text not null default 'initiated'
    check (status in ('initiated', 'redirected', 'completed', 'failed', 'cancelled')),
  payment_url text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz
);

create unique index if not exists hospitality_event_payment_attempts_transaction_id_key
  on public.hospitality_event_payment_attempts (transaction_id)
  where transaction_id is not null;

create index if not exists hospitality_events_public_listing_idx
  on public.hospitality_events (status, starts_at);
create index if not exists hospitality_events_category_idx
  on public.hospitality_events (category, starts_at);
create index if not exists hospitality_events_organizer_idx
  on public.hospitality_events (organizer_id, starts_at desc);
create index if not exists hospitality_event_favorites_event_idx
  on public.hospitality_event_favorites (event_id);
create index if not exists hospitality_event_plans_owner_idx
  on public.hospitality_event_plans (user_id, event_date desc);
create index if not exists hospitality_event_bookings_event_idx
  on public.hospitality_event_bookings (event_id, status);
create index if not exists hospitality_event_bookings_owner_idx
  on public.hospitality_event_bookings (user_id, created_at desc);
create index if not exists hospitality_event_payment_attempts_booking_idx
  on public.hospitality_event_payment_attempts (booking_id, created_at desc);

alter table public.hospitality_events enable row level security;
alter table public.hospitality_event_favorites enable row level security;
alter table public.hospitality_event_plans enable row level security;
alter table public.hospitality_event_bookings enable row level security;
alter table public.hospitality_event_payment_attempts enable row level security;

drop policy if exists hospitality_events_public_select on public.hospitality_events;
create policy hospitality_events_public_select
  on public.hospitality_events for select
  to anon, authenticated
  using (
    status = 'published'
    or exists (
      select 1
      from public.hospitality_event_bookings b
      where b.event_id = hospitality_events.id
        and b.user_id = auth.uid()
    )
  );

drop policy if exists hospitality_events_owner_select on public.hospitality_events;
create policy hospitality_events_owner_select
  on public.hospitality_events for select
  to authenticated
  using (organizer_id = auth.uid() or created_by = auth.uid());

drop policy if exists hospitality_events_owner_insert on public.hospitality_events;
create policy hospitality_events_owner_insert
  on public.hospitality_events for insert
  to authenticated
  with check (organizer_id = auth.uid() or created_by = auth.uid());

drop policy if exists hospitality_events_owner_update on public.hospitality_events;
create policy hospitality_events_owner_update
  on public.hospitality_events for update
  to authenticated
  using (organizer_id = auth.uid() or created_by = auth.uid())
  with check (organizer_id = auth.uid() or created_by = auth.uid());

drop policy if exists hospitality_events_owner_delete on public.hospitality_events;
create policy hospitality_events_owner_delete
  on public.hospitality_events for delete
  to authenticated
  using (organizer_id = auth.uid() or created_by = auth.uid());

drop policy if exists hospitality_event_favorites_owner_select on public.hospitality_event_favorites;
create policy hospitality_event_favorites_owner_select
  on public.hospitality_event_favorites for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists hospitality_event_favorites_owner_insert on public.hospitality_event_favorites;
create policy hospitality_event_favorites_owner_insert
  on public.hospitality_event_favorites for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists hospitality_event_favorites_owner_update on public.hospitality_event_favorites;
create policy hospitality_event_favorites_owner_update
  on public.hospitality_event_favorites for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists hospitality_event_favorites_owner_delete on public.hospitality_event_favorites;
create policy hospitality_event_favorites_owner_delete
  on public.hospitality_event_favorites for delete
  to authenticated
  using (user_id = auth.uid());

drop policy if exists hospitality_event_plans_owner_select on public.hospitality_event_plans;
create policy hospitality_event_plans_owner_select
  on public.hospitality_event_plans for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists hospitality_event_plans_owner_insert on public.hospitality_event_plans;
create policy hospitality_event_plans_owner_insert
  on public.hospitality_event_plans for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists hospitality_event_plans_owner_update on public.hospitality_event_plans;
create policy hospitality_event_plans_owner_update
  on public.hospitality_event_plans for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists hospitality_event_plans_owner_delete on public.hospitality_event_plans;
create policy hospitality_event_plans_owner_delete
  on public.hospitality_event_plans for delete
  to authenticated
  using (user_id = auth.uid());

drop policy if exists hospitality_event_bookings_owner_select on public.hospitality_event_bookings;
create policy hospitality_event_bookings_owner_select
  on public.hospitality_event_bookings for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists hospitality_event_bookings_owner_insert on public.hospitality_event_bookings;
drop policy if exists hospitality_event_bookings_owner_update on public.hospitality_event_bookings;
drop policy if exists hospitality_event_bookings_owner_delete on public.hospitality_event_bookings;

drop policy if exists hospitality_event_payment_attempts_owner_select on public.hospitality_event_payment_attempts;
create policy hospitality_event_payment_attempts_owner_select
  on public.hospitality_event_payment_attempts for select
  to authenticated
  using (exists (
    select 1
    from public.hospitality_event_bookings
    where hospitality_event_bookings.id = hospitality_event_payment_attempts.booking_id
      and hospitality_event_bookings.user_id = auth.uid()
  ));

create or replace function public.create_hospitality_event_booking(
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
  v_event public.hospitality_events%rowtype;
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
    from public.hospitality_events
   where id = target_event_id
   for update;

  if not found then
    raise exception 'Hospitality event not found';
  end if;

  if v_event.status <> 'published' or v_event.starts_at <= now() then
    raise exception 'Hospitality event is not published and upcoming';
  end if;

  select coalesce(sum(quantity), 0)
    into v_reserved_quantity
    from public.hospitality_event_bookings
   where event_id = target_event_id
     and (status = 'confirmed' or (status = 'pending' and (expires_at is null or expires_at > now())));

  if v_reserved_quantity + target_quantity > v_event.capacity then
    raise exception 'Hospitality event capacity exceeded';
  end if;

  v_subtotal := round(v_event.price * target_quantity, 2);
  v_total := v_subtotal;

  insert into public.hospitality_event_bookings (
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

create or replace function public.confirm_hospitality_event_payment(
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
  v_booking public.hospitality_event_bookings%rowtype;
  v_confirmation text;
  v_ticket text;
begin
  select * into v_booking
  from public.hospitality_event_bookings
  where id = target_booking_id
  for update;

  if not found then
    raise exception 'Hospitality booking not found';
  end if;
  if v_booking.payment_status = 'paid' and v_booking.status = 'confirmed' then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code, v_booking.order_number;
    return;
  end if;
  if v_booking.status <> 'pending' or v_booking.payment_status <> 'pending' then
    raise exception 'Hospitality booking is not pending';
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_ticket := 'TKT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

  update public.hospitality_event_bookings
  set status = 'confirmed',
      payment_status = 'paid',
      confirmation_number = v_confirmation,
      ticket_code = v_ticket,
      updated_at = now()
  where id = target_booking_id;

  update public.hospitality_events
  set attendees_count = attendees_count + v_booking.quantity,
      updated_at = now()
  where id = v_booking.event_id;

  return query select target_booking_id, v_confirmation, v_ticket, v_booking.order_number;
end;
$$;

create or replace function public.confirm_free_hospitality_event_booking(target_booking_id uuid)
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
  v_booking public.hospitality_event_bookings%rowtype;
  v_confirmation text;
  v_ticket text;
begin
  select * into v_booking
  from public.hospitality_event_bookings
  where id = target_booking_id
    and user_id = auth.uid()
  for update;

  if not found then
    raise exception 'Hospitality booking not found';
  end if;
  if v_booking.total_amount <> 0 then
    raise exception 'Only free bookings can be confirmed this way';
  end if;
  if v_booking.status <> 'pending' or v_booking.payment_status <> 'pending' then
    raise exception 'Hospitality booking is not pending';
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_ticket := 'TKT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

  update public.hospitality_event_bookings
  set status = 'confirmed',
      payment_status = 'paid',
      confirmation_number = v_confirmation,
      ticket_code = v_ticket,
      updated_at = now()
  where id = target_booking_id;

  update public.hospitality_events
  set attendees_count = attendees_count + v_booking.quantity,
      updated_at = now()
  where id = v_booking.event_id;

  return query select target_booking_id, v_confirmation, v_ticket;
end;
$$;

revoke all on function public.create_hospitality_event_booking(uuid, integer, text, text, text, text, text)
  from public;
grant execute on function public.create_hospitality_event_booking(uuid, integer, text, text, text, text, text)
  to authenticated;
revoke all on function public.confirm_hospitality_event_payment(uuid, text) from public, anon, authenticated;
grant execute on function public.confirm_hospitality_event_payment(uuid, text) to service_role;
revoke all on function public.confirm_free_hospitality_event_booking(uuid) from public;
grant execute on function public.confirm_free_hospitality_event_booking(uuid) to authenticated;
