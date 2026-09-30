begin;

alter table public.user_profiles
  add column if not exists hotel_star_rating smallint;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'user_profiles_hotel_star_rating_check') then
    alter table public.user_profiles add constraint user_profiles_hotel_star_rating_check check (hotel_star_rating between 1 and 5);
  end if;
end $$;

create or replace function public.guard_hotel_profile_updates()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() = old.user_id and new.role is distinct from old.role then
    raise exception 'Profile role changes require an authorized administrator';
  end if;
  if new.hotel_star_rating is distinct from old.hotel_star_rating then
    if old.role <> 'manager' or new.role <> 'manager' then
      raise exception 'Only manager profiles can change hotel classification';
    end if;
    if auth.uid() is not null and auth.uid() <> old.user_id then
      raise exception 'Only the hotel manager can change this classification';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_hotel_profile_updates on public.user_profiles;
create trigger guard_hotel_profile_updates
before update of role, hotel_star_rating on public.user_profiles
for each row execute function public.guard_hotel_profile_updates();
revoke all on function public.guard_hotel_profile_updates() from public;

alter table public.books_organizations
  add column if not exists hotel_classification smallint;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'books_organizations_hotel_classification_check') then
    alter table public.books_organizations add constraint books_organizations_hotel_classification_check check (hotel_classification between 1 and 5);
  end if;
end $$;

create or replace function public.sync_hotel_classification()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.hotel_star_rating is distinct from old.hotel_star_rating
     and old.role = 'manager' and new.role = 'manager' then
    update public.books_organizations bo
       set hotel_classification = new.hotel_star_rating
      from public.books_memberships bm
     where bm.organization_id = bo.id
       and bm.user_id = bo.owner_id
       and bo.owner_id = new.user_id
       and bm.role = 'owner';
  end if;
  return new;
end;
$$;

drop trigger if exists sync_hotel_classification on public.user_profiles;
create trigger sync_hotel_classification
after update of hotel_star_rating on public.user_profiles
for each row execute function public.sync_hotel_classification();
revoke all on function public.sync_hotel_classification() from public;

create or replace function public.initialize_hotel_classification()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  manager_classification smallint;
  manager_organization_name text;
begin
  select hotel_star_rating, nullif(trim(organization_name), '')
    into manager_classification, manager_organization_name
    from public.user_profiles
   where user_id = new.owner_id and role = 'manager';
  if new.hotel_classification is null then
    new.hotel_classification := manager_classification;
  end if;
  if manager_organization_name is not null then
    new.name := manager_organization_name;
  end if;
  return new;
end;
$$;

drop trigger if exists initialize_hotel_classification on public.books_organizations;
create trigger initialize_hotel_classification before insert on public.books_organizations
for each row execute function public.initialize_hotel_classification();
revoke all on function public.initialize_hotel_classification() from public;

create or replace function public.sync_hotel_organization_name()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.role = 'manager' and new.organization_name is distinct from old.organization_name then
    if auth.uid() is not null and auth.uid() <> old.user_id then
      raise exception 'Only the hotel manager can change this organization name';
    end if;
    update public.books_organizations bo
       set name = nullif(trim(new.organization_name), '')
      from public.books_memberships bm
     where bm.organization_id = bo.id
       and bm.user_id = bo.owner_id
       and bm.role = 'owner'
       and bo.owner_id = new.user_id
       and nullif(trim(new.organization_name), '') is not null;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_hotel_organization_name on public.user_profiles;
create trigger sync_hotel_organization_name
after update of organization_name on public.user_profiles
for each row execute function public.sync_hotel_organization_name();
revoke all on function public.sync_hotel_organization_name() from public;

update public.books_organizations bo
   set hotel_classification = case when up.hotel_star_rating between 1 and 5 then up.hotel_star_rating else bo.hotel_classification end,
       name = case when bo.name = 'My business' and nullif(trim(up.organization_name), '') is not null then trim(up.organization_name) else bo.name end
  from public.books_memberships bm
  join public.user_profiles up on up.user_id = bm.user_id
 where bm.organization_id = bo.id
   and bm.user_id = bo.owner_id
   and up.user_id = bo.owner_id
   and bm.role = 'owner'
   and up.role = 'manager'
   and (bo.hotel_classification is distinct from up.hotel_star_rating or (bo.name = 'My business' and nullif(trim(up.organization_name), '') is not null));

create table if not exists public.hotel_booking_page_settings (
  id boolean primary key default true check (id),
  title text not null,
  subtitle text not null,
  updated_at timestamptz not null default now()
);

insert into public.hotel_booking_page_settings (id, title, subtitle)
values (true, 'Book Your Special Stay', 'Experience luxury, comfort, and personalized service. Every detail crafted to make your stay extraordinary.')
on conflict (id) do nothing;

create table if not exists public.hotel_booking_offers (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null,
  display_order integer not null default 0,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  discount_percentage numeric(5,2) not null default 0 check (discount_percentage between 0 and 100),
  minimum_nights integer not null default 1 check (minimum_nights > 0),
  created_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

alter table public.hotel_booking_offers
  add column if not exists discount_percentage numeric(5,2) not null default 0 check (discount_percentage between 0 and 100),
  add column if not exists minimum_nights integer not null default 1 check (minimum_nights > 0);

insert into public.hotel_booking_offers (title, description, display_order, discount_percentage, minimum_nights)
select seed.title, seed.description, seed.display_order, seed.discount_percentage, seed.minimum_nights
from (values
  ('Extended Stay', 'Stay three or more nights and save 15% on accommodation.', 1, 15::numeric, 3)
) as seed(title, description, display_order, discount_percentage, minimum_nights)
where not exists (select 1 from public.hotel_booking_offers existing where existing.title = seed.title);

update public.hotel_booking_offers
   set discount_percentage = 15, minimum_nights = 3
 where title = 'Extended Stay'
   and description = 'Stay three or more nights and save 15% on accommodation.'
   and discount_percentage = 0;
update public.hotel_booking_offers
   set is_active = false
 where title = 'Welcome Bonus'
   and description = 'First-time guests receive complimentary spa access.';

create table if not exists public.hotel_rooms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete cascade,
  name text not null,
  room_type text not null,
  description text not null,
  image_url text,
  size_sqm numeric(8,2),
  max_guests integer not null default 2 check (max_guests between 1 and 20),
  available_units integer not null default 1 check (available_units between 1 and 500),
  nightly_rate numeric(14,2) not null check (nightly_rate > 0),
  original_nightly_rate numeric(14,2) check (original_nightly_rate is null or original_nightly_rate > nightly_rate),
  currency_code char(3) not null default 'USD' check (currency_code in ('USD', 'UGX', 'EUR', 'GBP', 'KES', 'TZS', 'RWF')),
  check (currency_code not in ('UGX', 'RWF', 'TZS') or (nightly_rate = trunc(nightly_rate) and (original_nightly_rate is null or original_nightly_rate = trunc(original_nightly_rate)))),
  amenities text[] not null default '{}',
  status text not null default 'draft' check (status in ('draft', 'published', 'unavailable')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.seed_hotel_room_listings()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from public.user_profiles where user_id = new.owner_id and role = 'manager') then
    insert into public.hotel_rooms (organization_id, name, room_type, description, size_sqm, max_guests, available_units, nightly_rate, original_nightly_rate, currency_code, amenities, status, created_by)
    values
      (new.id, 'Deluxe Suite', 'deluxe', 'Elegant suite with modern amenities and stunning city views.', 45, 3, 1, 299, 399, 'USD', array['King bed', 'City view', 'Mini bar', 'Work desk'], 'draft', new.owner_id),
      (new.id, 'Presidential Suite', 'presidential', 'Ultimate luxury with personalized service and premium amenities.', 80, 4, 1, 599, 799, 'USD', array['Master bedroom', 'Living room', 'Balcony', 'Butler service'], 'draft', new.owner_id),
      (new.id, 'Garden Villa', 'villa', 'Tranquil villa surrounded by lush gardens and natural beauty.', 60, 4, 1, 449, 599, 'USD', array['Private garden', 'Outdoor bath', 'Fireplace', 'Terrace'], 'draft', new.owner_id)
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists seed_hotel_room_listings on public.books_organizations;
create trigger seed_hotel_room_listings after insert on public.books_organizations
for each row execute function public.seed_hotel_room_listings();
revoke all on function public.seed_hotel_room_listings() from public;

insert into public.hotel_rooms (organization_id, name, room_type, description, size_sqm, max_guests, available_units, nightly_rate, original_nightly_rate, currency_code, amenities, status, created_by)
select bo.id, seed.name, seed.room_type, seed.description, seed.size_sqm, seed.max_guests, 1, seed.nightly_rate, seed.original_nightly_rate, 'USD', seed.amenities, 'draft', bo.owner_id
from public.books_organizations bo
join public.books_memberships bm on bm.organization_id = bo.id and bm.user_id = bo.owner_id and bm.role = 'owner'
join public.user_profiles up on up.user_id = bo.owner_id and up.role = 'manager'
cross join (values
  ('Deluxe Suite', 'deluxe', 'Elegant suite with modern amenities and stunning city views.', 45::numeric, 3, 299::numeric, 399::numeric, array['King bed', 'City view', 'Mini bar', 'Work desk']::text[]),
  ('Presidential Suite', 'presidential', 'Ultimate luxury with personalized service and premium amenities.', 80::numeric, 4, 599::numeric, 799::numeric, array['Master bedroom', 'Living room', 'Balcony', 'Butler service']::text[]),
  ('Garden Villa', 'villa', 'Tranquil villa surrounded by lush gardens and natural beauty.', 60::numeric, 4, 449::numeric, 599::numeric, array['Private garden', 'Outdoor bath', 'Fireplace', 'Terrace']::text[])
) as seed(name, room_type, description, size_sqm, max_guests, nightly_rate, original_nightly_rate, amenities)
where not exists (select 1 from public.hotel_rooms r where r.organization_id = bo.id and r.name = seed.name);

create or replace view public.hotel_public_room_listings with (security_barrier = true) as
select
  r.id,
  r.organization_id,
  r.name,
  r.room_type,
  r.description,
  r.image_url,
  r.size_sqm,
  r.max_guests,
  r.available_units,
  r.nightly_rate,
  r.original_nightly_rate,
  r.currency_code,
  r.amenities,
  r.status,
  bo.name as hotel_name,
  bo.city as hotel_city,
  bo.country as hotel_country,
  bo.hotel_classification
from public.hotel_rooms r
join public.books_organizations bo on bo.id = r.organization_id
where r.status = 'published'
  and bo.hotel_classification between 1 and 5;

grant select on public.hotel_public_room_listings to anon, authenticated;

create table if not exists public.hotel_bookings (
  id uuid primary key default gen_random_uuid(),
  confirmation_number text not null unique,
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  room_id uuid not null references public.hotel_rooms(id) on delete restrict,
  user_id uuid references auth.users(id) on delete set null,
  check_in date not null,
  check_out date not null,
  nights integer not null check (nights > 0),
  guest_count integer not null check (guest_count > 0),
  room_count integer not null default 1 check (room_count between 1 and 10),
  guest_first_name text not null,
  guest_last_name text not null,
  guest_email text not null,
  guest_phone text not null,
  special_requests text,
  room_preferences jsonb not null default '[]'::jsonb,
  booking_status text not null default 'pending' check (booking_status in ('pending', 'confirmed', 'cancelled', 'expired', 'manual_review')),
  payment_status text not null default 'pending' check (payment_status in ('pending', 'paid', 'failed', 'cancelled')),
  payment_method text not null default 'flutterwave' check (payment_method = 'flutterwave'),
  currency_code char(3) not null,
  nightly_subtotal numeric(14,2) not null,
  discount_amount numeric(14,2) not null default 0,
  taxable_subtotal numeric(14,2) not null,
  vat_amount numeric(14,2) not null,
  lht_amount numeric(14,2) not null,
  total_amount numeric(14,2) not null,
  hotel_classification smallint not null check (hotel_classification between 1 and 5),
  fx_rates_snapshot jsonb not null,
  expires_at timestamptz,
  idempotency_key uuid not null unique,
  access_token_hash text not null,
  books_invoice_id uuid references public.books_invoices(id) on delete set null,
  books_accounting_status text not null default 'pending' check (books_accounting_status in ('pending', 'posted', 'failed')),
  books_accounting_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (check_out > check_in),
  check (total_amount >= 0),
  check (length(access_token_hash) = 64)
);

alter table public.hotel_bookings
  add column if not exists books_accounting_status text not null default 'pending' check (books_accounting_status in ('pending', 'posted', 'failed')),
  add column if not exists books_accounting_error text;

update public.hotel_bookings
   set books_accounting_status = 'posted', books_accounting_error = null
 where books_invoice_id is not null and books_accounting_status <> 'posted';

create table if not exists public.hotel_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.hotel_bookings(id) on delete restrict,
  tx_ref text not null unique,
  transaction_id text,
  amount numeric(14,2) not null check (amount > 0),
  currency_code char(3) not null,
  status text not null default 'initiated' check (status in ('initiated', 'redirected', 'completed', 'failed', 'cancelled', 'expired', 'manual_review')),
  payment_url text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz
);

create table if not exists public.books_fx_rates (
  base_currency char(3) not null,
  quote_currency char(3) not null,
  rate numeric(24,12) not null check (rate > 0),
  provider text not null,
  fetched_at timestamptz not null,
  stored_at timestamptz not null default now(),
  primary key (base_currency, quote_currency),
  check (base_currency <> quote_currency)
);

create table if not exists public.hotel_booking_rate_limits (
  rate_key text not null check (length(rate_key) = 64),
  window_started_at timestamptz not null,
  attempt_count integer not null default 0 check (attempt_count between 1 and 10),
  primary key (rate_key, window_started_at)
);

create index if not exists hotel_rooms_public_idx on public.hotel_rooms (status, organization_id, created_at desc);
create index if not exists hotel_bookings_room_dates_idx on public.hotel_bookings (room_id, check_in, check_out, booking_status, expires_at);
create index if not exists hotel_bookings_org_created_idx on public.hotel_bookings (organization_id, created_at desc);
create index if not exists hotel_payment_attempts_booking_idx on public.hotel_payment_attempts (booking_id, created_at desc);
create unique index if not exists hotel_payment_attempts_one_active_per_booking_idx on public.hotel_payment_attempts (booking_id) where status in ('initiated', 'redirected');
create unique index if not exists hotel_payment_attempts_transaction_id_idx on public.hotel_payment_attempts (transaction_id) where transaction_id is not null;

create or replace function public.get_hotel_room_availability(target_check_in date, target_check_out date)
returns table (room_id uuid, remaining_units integer)
language plpgsql stable security definer set search_path = public
as $$
begin
  if target_check_in < current_date or target_check_out <= target_check_in or target_check_out > current_date + 365 then
    raise exception 'Select valid check-in and check-out dates';
  end if;
  return query
  select r.id,
    greatest(r.available_units - coalesce(sum(b.room_count) filter (
      where ((b.booking_status in ('confirmed', 'manual_review') and b.payment_status = 'paid')
        or (b.booking_status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))
        and b.check_in < target_check_out and b.check_out > target_check_in
    ), 0), 0)::integer
  from public.hotel_rooms r
  left join public.hotel_bookings b on b.room_id = r.id
  where r.status = 'published'
  group by r.id, r.available_units;
end;
$$;
revoke all on function public.get_hotel_room_availability(date, date) from public;
grant execute on function public.get_hotel_room_availability(date, date) to anon, authenticated;

create or replace function public.set_hotel_updated_at()
returns trigger language plpgsql set search_path = public
as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists hotel_rooms_updated_at on public.hotel_rooms;
create trigger hotel_rooms_updated_at before update on public.hotel_rooms for each row execute function public.set_hotel_updated_at();
drop trigger if exists hotel_bookings_updated_at on public.hotel_bookings;
create trigger hotel_bookings_updated_at before update on public.hotel_bookings for each row execute function public.set_hotel_updated_at();
drop trigger if exists hotel_payment_attempts_updated_at on public.hotel_payment_attempts;
create trigger hotel_payment_attempts_updated_at before update on public.hotel_payment_attempts for each row execute function public.set_hotel_updated_at();

alter table public.hotel_booking_page_settings enable row level security;
alter table public.hotel_booking_offers enable row level security;
alter table public.hotel_rooms enable row level security;
alter table public.hotel_bookings enable row level security;
alter table public.hotel_payment_attempts enable row level security;
alter table public.books_fx_rates enable row level security;
alter table public.hotel_booking_rate_limits enable row level security;

drop policy if exists hotel_booking_settings_read on public.hotel_booking_page_settings;
create policy hotel_booking_settings_read on public.hotel_booking_page_settings for select to anon, authenticated using (true);
drop policy if exists hotel_booking_offers_read on public.hotel_booking_offers;
create policy hotel_booking_offers_read on public.hotel_booking_offers for select to anon, authenticated using (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()));
drop policy if exists hotel_rooms_public_read on public.hotel_rooms;
create policy hotel_rooms_public_read on public.hotel_rooms for select to anon, authenticated using (status = 'published' or exists (select 1 from public.books_memberships bm where bm.organization_id = hotel_rooms.organization_id and bm.user_id = auth.uid() and bm.role in ('owner', 'admin')));
drop policy if exists hotel_rooms_manager_insert on public.hotel_rooms;
create policy hotel_rooms_manager_insert on public.hotel_rooms for insert to authenticated with check (created_by = auth.uid() and exists (select 1 from public.user_profiles up join public.books_memberships bm on bm.user_id = up.user_id where up.user_id = auth.uid() and up.role = 'manager' and bm.organization_id = hotel_rooms.organization_id and bm.role in ('owner', 'admin')));
drop policy if exists hotel_rooms_manager_update on public.hotel_rooms;
create policy hotel_rooms_manager_update on public.hotel_rooms for update to authenticated using (exists (select 1 from public.user_profiles up join public.books_memberships bm on bm.user_id = up.user_id where up.user_id = auth.uid() and up.role = 'manager' and bm.organization_id = hotel_rooms.organization_id and bm.role in ('owner', 'admin'))) with check (exists (select 1 from public.user_profiles up join public.books_memberships bm on bm.user_id = up.user_id where up.user_id = auth.uid() and up.role = 'manager' and bm.organization_id = hotel_rooms.organization_id and bm.role in ('owner', 'admin')));
drop policy if exists hotel_rooms_manager_delete on public.hotel_rooms;
create policy hotel_rooms_manager_delete on public.hotel_rooms for delete to authenticated using (exists (select 1 from public.user_profiles up join public.books_memberships bm on bm.user_id = up.user_id where up.user_id = auth.uid() and up.role = 'manager' and bm.organization_id = hotel_rooms.organization_id and bm.role in ('owner', 'admin')));
drop policy if exists hotel_bookings_owner_read on public.hotel_bookings;
create policy hotel_bookings_owner_read on public.hotel_bookings for select to authenticated using (user_id = auth.uid() or exists (select 1 from public.user_profiles up join public.books_memberships bm on bm.user_id = up.user_id where up.user_id = auth.uid() and up.role = 'manager' and bm.organization_id = hotel_bookings.organization_id and bm.role in ('owner', 'admin')));
drop policy if exists hotel_payment_attempts_manager_read on public.hotel_payment_attempts;
create policy hotel_payment_attempts_manager_read on public.hotel_payment_attempts for select to authenticated using (exists (select 1 from public.hotel_bookings hb join public.user_profiles up on up.user_id = auth.uid() and up.role = 'manager' join public.books_memberships bm on bm.user_id = up.user_id and bm.organization_id = hb.organization_id and bm.role in ('owner', 'admin') where hb.id = hotel_payment_attempts.booking_id));
drop policy if exists books_fx_rates_read on public.books_fx_rates;
create policy books_fx_rates_read on public.books_fx_rates for select to anon, authenticated using (true);

drop function if exists public.create_hotel_booking(uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, text, jsonb);
drop function if exists public.create_hotel_booking(uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, text, text, jsonb);
drop function if exists public.create_hotel_booking(uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, text, jsonb);

create or replace function public.consume_hotel_booking_rate_limit(target_rate_limit_key text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare limit_count integer;
begin
  if target_rate_limit_key is null or length(target_rate_limit_key) <> 64 then
    raise exception 'Booking request is invalid';
  end if;
  insert into public.hotel_booking_rate_limits (rate_key, window_started_at, attempt_count)
  values (target_rate_limit_key, date_trunc('hour', now()), 1)
  on conflict (rate_key, window_started_at) do update
    set attempt_count = public.hotel_booking_rate_limits.attempt_count + 1
    where public.hotel_booking_rate_limits.attempt_count < 10
  returning attempt_count into limit_count;
  delete from public.hotel_booking_rate_limits where window_started_at < date_trunc('hour', now()) - interval '48 hours';
  return limit_count is not null;
end;
$$;
revoke all on function public.consume_hotel_booking_rate_limit(text) from public, anon, authenticated;
grant execute on function public.consume_hotel_booking_rate_limit(text) to service_role;

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
returns table (booking_id uuid, confirmation_number text, currency_code char(3), nights integer, nightly_subtotal numeric, discount_amount numeric, taxable_subtotal numeric, vat_amount numeric, lht_amount numeric, total_amount numeric, hotel_classification smallint, expires_at timestamptz)
language plpgsql security definer set search_path = public
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
begin
  if target_idempotency_key is null then raise exception 'Booking request is invalid'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_idempotency_key::text, 0));
  if target_check_in < current_date or target_check_out <= target_check_in or target_check_out > current_date + 365 then
    raise exception 'Select valid check-in and check-out dates';
  end if;
  if target_guest_count < 1 or target_room_count < 1 or target_room_count > 10 then
    raise exception 'Guest or room count is invalid';
  end if;
  if coalesce(length(trim(target_guest->>'first_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'last_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'email')), 0) = 0
     or coalesce(length(trim(target_guest->>'phone')), 0) = 0 then
    raise exception 'Guest name, email, and phone are required';
  end if;
  if target_access_token_hash is null or length(target_access_token_hash) <> 64 then
    raise exception 'Booking access credential is invalid';
  end if;
  if target_preferences is null or jsonb_typeof(target_preferences) <> 'array' then
    raise exception 'Room preferences must be an array';
  end if;
  if jsonb_array_length(target_preferences) > 10 then raise exception 'Too many room preferences were selected'; end if;

  select * into existing_booking from public.hotel_bookings where idempotency_key = target_idempotency_key;
  if found then
    if existing_booking.access_token_hash <> target_access_token_hash or (existing_booking.user_id is not null and existing_booking.user_id is distinct from target_user_id) then raise exception 'Idempotency key does not match booking access credential'; end if;
    return query select existing_booking.id, existing_booking.confirmation_number, existing_booking.currency_code, existing_booking.nights, existing_booking.nightly_subtotal, existing_booking.discount_amount, existing_booking.taxable_subtotal, existing_booking.vat_amount, existing_booking.lht_amount, existing_booking.total_amount, existing_booking.hotel_classification, existing_booking.expires_at;
    return;
  end if;

  select * into selected_room from public.hotel_rooms where id = target_room_id and status = 'published' for update;
  if not found then raise exception 'This room is not available for booking'; end if;
  select bo.hotel_classification
    into selected_classification
    from public.books_organizations as bo
   where bo.id = selected_room.organization_id;
  if selected_classification is null or selected_classification not between 1 and 5 then raise exception 'The hotel must set its star classification before accepting bookings'; end if;
  if target_guest_count > selected_room.max_guests * target_room_count then raise exception 'Guest count exceeds the selected room capacity'; end if;

  update public.hotel_bookings as hb
     set booking_status = 'expired', payment_status = 'cancelled'
   where hb.room_id = selected_room.id
     and hb.booking_status = 'pending'
     and hb.expires_at <= now();

  select coalesce(sum(hb.room_count), 0) into reserved_units
    from public.hotel_bookings as hb
   where hb.room_id = selected_room.id
     and ((hb.booking_status in ('confirmed', 'manual_review') and hb.payment_status = 'paid')
       or (hb.booking_status = 'pending' and hb.payment_status = 'pending' and hb.expires_at > now()))
     and hb.check_in < target_check_out
     and hb.check_out > target_check_in;
  if reserved_units + target_room_count > selected_room.available_units then
    raise exception 'The selected room is no longer available for these dates';
  end if;

  nights_count := target_check_out - target_check_in;
  currency_decimals := case when trim(selected_room.currency_code) in ('UGX', 'RWF', 'TZS') then 0 else 2 end;
  room_subtotal := round(selected_room.nightly_rate * nights_count * target_room_count, currency_decimals);
  select coalesce(max(discount_percentage), 0) into discount_rate
    from public.hotel_booking_offers
   where is_active and minimum_nights <= nights_count
     and (starts_at is null or starts_at <= now())
     and (ends_at is null or ends_at > now());
  discount_value := round(room_subtotal * discount_rate / 100, currency_decimals);
  taxable_value := room_subtotal - discount_value;

  room_currency_per_ugx := (target_fx_rates->>trim(selected_room.currency_code))::numeric;
  usd_per_ugx := (target_fx_rates->>'USD')::numeric;
  if room_currency_per_ugx is null or room_currency_per_ugx <= 0 or usd_per_ugx is null or usd_per_ugx <= 0 then
    raise exception 'A current exchange-rate snapshot is required to calculate hotel levies';
  end if;
  room_rate_in_ugx := (selected_room.nightly_rate * (1 - discount_rate / 100)) / room_currency_per_ugx;
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
  lht_value := round(local_hotel_tax_per_room * nights_count * target_room_count, currency_decimals);
  total_value := taxable_value + vat_value + lht_value;
  new_confirmation := 'ST-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  hold_expires := now() + interval '20 minutes';

  insert into public.hotel_bookings (
    confirmation_number, organization_id, room_id, user_id, check_in, check_out, nights, guest_count, room_count,
    guest_first_name, guest_last_name, guest_email, guest_phone, special_requests, room_preferences,
    currency_code, nightly_subtotal, discount_amount, taxable_subtotal, vat_amount, lht_amount, total_amount,
    hotel_classification, fx_rates_snapshot, expires_at, idempotency_key, access_token_hash
  ) values (
    new_confirmation, selected_room.organization_id, selected_room.id, target_user_id, target_check_in, target_check_out, nights_count, target_guest_count, target_room_count,
    trim(target_guest->>'first_name'), trim(target_guest->>'last_name'), lower(trim(target_guest->>'email')), trim(target_guest->>'phone'),
    nullif(trim(target_special_requests), ''), target_preferences,
    selected_room.currency_code, room_subtotal, discount_value, taxable_value, vat_value, lht_value, total_value,
    selected_classification, target_fx_rates, hold_expires, target_idempotency_key, target_access_token_hash
  ) on conflict (idempotency_key) do nothing returning id into new_booking_id;

  if new_booking_id is null then
    select * into existing_booking from public.hotel_bookings where idempotency_key = target_idempotency_key;
    if existing_booking.access_token_hash <> target_access_token_hash then raise exception 'Idempotency key does not match booking access credential'; end if;
    return query select existing_booking.id, existing_booking.confirmation_number, existing_booking.currency_code, existing_booking.nights, existing_booking.nightly_subtotal, existing_booking.discount_amount, existing_booking.taxable_subtotal, existing_booking.vat_amount, existing_booking.lht_amount, existing_booking.total_amount, existing_booking.hotel_classification, existing_booking.expires_at;
    return;
  end if;

  return query select new_booking_id, new_confirmation, selected_room.currency_code, nights_count, room_subtotal, discount_value, taxable_value, vat_value, lht_value, total_value, selected_classification, hold_expires;
end;
$$;

revoke all on function public.create_hotel_booking(uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_hotel_booking(uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) to service_role;

create or replace function public.create_hotel_payment_attempt(
  target_booking_id uuid,
  target_access_token_hash text,
  target_tx_ref text
)
returns table (attempt_id uuid, attempt_tx_ref text, attempt_status text, attempt_payment_url text)
language plpgsql security definer set search_path = public
as $$
declare
  selected_booking public.hotel_bookings%rowtype;
  active_attempt public.hotel_payment_attempts%rowtype;
  created_attempt public.hotel_payment_attempts%rowtype;
begin
  select * into selected_booking from public.hotel_bookings where id = target_booking_id for update;
  if not found or selected_booking.access_token_hash <> target_access_token_hash then
    raise exception 'Booking access could not be verified';
  end if;
  if selected_booking.booking_status <> 'pending' or selected_booking.payment_status <> 'pending'
     or selected_booking.expires_at is null or selected_booking.expires_at <= now() then
    raise exception 'This reservation hold has expired. Select the room again to start a new booking.';
  end if;
  select * into active_attempt from public.hotel_payment_attempts
   where booking_id = selected_booking.id and status in ('initiated', 'redirected')
   order by created_at desc limit 1;
  if found then
    return query select active_attempt.id, active_attempt.tx_ref, active_attempt.status, active_attempt.payment_url;
    return;
  end if;
  insert into public.hotel_payment_attempts (booking_id, tx_ref, amount, currency_code, status)
  values (selected_booking.id, target_tx_ref, selected_booking.total_amount, selected_booking.currency_code, 'initiated')
  returning * into created_attempt;
  return query select created_attempt.id, created_attempt.tx_ref, created_attempt.status, created_attempt.payment_url;
end;
$$;
revoke all on function public.create_hotel_payment_attempt(uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_hotel_payment_attempt(uuid, text, text) to service_role;

create or replace function public.cancel_hotel_booking_hold(target_booking_id uuid, target_access_token_hash text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare selected_booking public.hotel_bookings%rowtype;
begin
  select * into selected_booking from public.hotel_bookings where id = target_booking_id for update;
  if not found or selected_booking.access_token_hash <> target_access_token_hash then
    raise exception 'Booking access could not be verified';
  end if;
  if selected_booking.payment_status <> 'pending' or selected_booking.booking_status <> 'pending' or selected_booking.expires_at <= now() then
    raise exception 'This reservation hold is no longer active';
  end if;
  if exists (
    select 1 from public.hotel_payment_attempts
     where booking_id = selected_booking.id and status in ('initiated', 'redirected')
  ) then
    raise exception 'A payment is in progress; finish or retry checkout before releasing this hold';
  end if;
  update public.hotel_bookings
     set booking_status = 'cancelled', payment_status = 'cancelled', expires_at = null
   where id = selected_booking.id;
  return true;
end;
$$;
revoke all on function public.cancel_hotel_booking_hold(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_hotel_booking_hold(uuid, text) to service_role;

create or replace function public.confirm_hotel_booking_payment(target_tx_ref text, target_transaction_id text)
returns table (booking_id uuid, confirmation_number text, payment_status text, booking_status text)
language plpgsql security definer set search_path = public
as $$
declare
  attempt public.hotel_payment_attempts%rowtype;
  booking public.hotel_bookings%rowtype;
  room public.hotel_rooms%rowtype;
  target_room_id uuid;
  reserved_units integer;
  resolved_status text := 'confirmed';
begin
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
  if attempt.amount <> booking.total_amount or attempt.currency_code <> booking.currency_code then raise exception 'Payment attempt does not match booking amount'; end if;
  if booking.payment_status = 'paid' then
    if attempt.transaction_id = target_transaction_id and attempt.status = 'completed' then
      return query select booking.id, booking.confirmation_number, booking.payment_status, booking.booking_status;
    else
      update public.hotel_payment_attempts set status = 'manual_review', transaction_id = target_transaction_id, completed_at = now() where id = attempt.id;
      return query select booking.id, booking.confirmation_number, 'manual_review'::text, booking.booking_status;
    end if;
    return;
  end if;
  if booking.booking_status not in ('pending', 'expired', 'cancelled') then raise exception 'Hotel booking cannot be confirmed'; end if;
  if booking.booking_status = 'cancelled' then resolved_status := 'manual_review'; end if;
  update public.hotel_bookings as expired_booking
     set booking_status = 'expired', payment_status = 'cancelled'
   where expired_booking.room_id = booking.room_id
     and expired_booking.id <> booking.id
     and expired_booking.booking_status = 'pending'
     and expired_booking.expires_at <= now();

  select coalesce(sum(reservation.room_count), 0) into reserved_units
    from public.hotel_bookings as reservation
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
         completed_at = now()
   where id = attempt.id;
  update public.hotel_bookings set payment_status = 'paid', booking_status = resolved_status, expires_at = null where id = booking.id;
  return query select booking.id, booking.confirmation_number, 'paid'::text, resolved_status;
end;
$$;

revoke all on function public.confirm_hotel_booking_payment(text, text) from public, anon, authenticated;
grant execute on function public.confirm_hotel_booking_payment(text, text) to service_role;

alter table public.books_invoices add column if not exists other_charges numeric(20,4) not null default 0 check (other_charges >= 0);

do $$
declare total_is_generated boolean;
begin
  select attgenerated <> '' into total_is_generated
    from pg_attribute
   where attrelid = 'public.books_invoices'::regclass
     and attname = 'total'
     and not attisdropped;
  if coalesce(total_is_generated, false) then
    alter table public.books_invoices alter column total drop expression;
  end if;
end;
$$;

alter table public.books_invoices add column if not exists total_due numeric(20,4) generated always as (subtotal + tax_amount + other_charges) stored;

create or replace function public.set_books_invoice_total()
returns trigger language plpgsql set search_path = public
as $$
begin
  new.total := new.subtotal + new.tax_amount + new.other_charges;
  return new;
end;
$$;

drop trigger if exists books_invoice_total_before_write on public.books_invoices;
create trigger books_invoice_total_before_write
before insert or update on public.books_invoices
for each row execute function public.set_books_invoice_total();

alter table public.books_invoices
  alter column total type numeric(20,4)
  using (subtotal + tax_amount + other_charges);

create or replace function public.apply_books_invoice_tax()
returns trigger language plpgsql security definer set search_path = public
as $$
declare selected_rate numeric;
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
    new.tax_amount := case when new.invoice_number like 'HOTEL-%'
      then round(new.subtotal * selected_rate / 100, case when new.currency_code in ('UGX', 'RWF', 'TZS') then 0 else 2 end)
      else round(new.subtotal * selected_rate / 100, 4)
    end;
  else
    new.tax_rate_percentage := 0;
    new.tax_amount := 0;
  end if;
  return new;
end;
$$;

drop trigger if exists books_invoice_tax_before_write on public.books_invoices;
create trigger books_invoice_tax_before_write
before insert or update on public.books_invoices
for each row execute function public.apply_books_invoice_tax();

create or replace function public.post_hotel_invoice_recognition(target_invoice_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  invoice_row public.books_invoices%rowtype;
  owner_user_id uuid;
  journal_id uuid;
  cash_receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
  local_tax_payable_id uuid;
begin
  select * into invoice_row from public.books_invoices where id = target_invoice_id;
  if not found or invoice_row.status <> 'paid' or invoice_row.invoice_number not like 'HOTEL-%' then return; end if;

  select owner_id into owner_user_id from public.books_organizations where id = invoice_row.organization_id;
  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (invoice_row.organization_id, '1000', 'Cash and bank', 'asset', true),
    (invoice_row.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (invoice_row.organization_id, '2100', 'VAT payable', 'liability', true),
    (invoice_row.organization_id, '2200', 'Local hotel tax payable', 'liability', true),
    (invoice_row.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  select id into cash_receivable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '1100' and type = 'asset';
  select id into revenue_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '4000' and type = 'income';
  select id into vat_payable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '2100' and type = 'liability';
  select id into local_tax_payable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '2200' and type = 'liability';
  if cash_receivable_id is null or revenue_id is null or vat_payable_id is null or local_tax_payable_id is null then
    raise exception 'Required Books accounts are missing for the hotel invoice';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (invoice_row.organization_id, 'hotel_invoice_recognition', invoice_row.id, invoice_row.issue_date, 'Recognize hotel invoice ' || invoice_row.invoice_number, owner_user_id)
  on conflict do nothing returning id into journal_id;
  if journal_id is null then return; end if;

  insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
  values (journal_id, cash_receivable_id, invoice_row.total, invoice_row.currency_code);
  if invoice_row.subtotal > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, revenue_id, invoice_row.subtotal, invoice_row.currency_code);
  end if;
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, vat_payable_id, invoice_row.tax_amount, invoice_row.currency_code);
  end if;
  if invoice_row.other_charges > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, local_tax_payable_id, invoice_row.other_charges, invoice_row.currency_code);
  end if;
end;
$$;
revoke all on function public.post_hotel_invoice_recognition(uuid) from public, anon, authenticated;

create or replace function public.post_paid_hotel_booking_to_books()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  customer_contact_id uuid;
  invoice_uuid uuid;
  vat_rate_id uuid;
  organization_name text;
  room_name text;
begin
  if new.payment_status <> 'paid' or new.books_invoice_id is not null then
    return new;
  end if;

  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (new.organization_id, '1000', 'Cash and bank', 'asset', true),
    (new.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (new.organization_id, '2100', 'VAT payable', 'liability', true),
    (new.organization_id, '2200', 'Local hotel tax payable', 'liability', true),
    (new.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  select name into organization_name from public.books_organizations where id = new.organization_id;
  select name into room_name from public.hotel_rooms where id = new.room_id;
  select id into customer_contact_id from public.books_contacts
   where organization_id = new.organization_id and lower(email) = lower(new.guest_email) and type in ('customer', 'both')
   order by created_at limit 1;
  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (new.organization_id, trim(new.guest_first_name || ' ' || new.guest_last_name), 'customer', new.guest_email, new.guest_phone)
    returning id into customer_contact_id;
  end if;

  select id into vat_rate_id from public.books_tax_rates
   where organization_id = new.organization_id and country_code = 'UG' and rate_percentage = 18 and is_active
     and current_date >= effective_from and (effective_to is null or current_date <= effective_to)
   order by effective_from desc limit 1;
  if vat_rate_id is null then
    insert into public.books_tax_rates (organization_id, country_code, name, rate_percentage)
    values (new.organization_id, 'UG', 'Uganda VAT 18%', 18)
    on conflict (organization_id, name, effective_from) do update
      set is_active = true, effective_to = null;
    select id into vat_rate_id from public.books_tax_rates
     where organization_id = new.organization_id and country_code = 'UG' and rate_percentage = 18
       and is_active and current_date >= effective_from and (effective_to is null or current_date <= effective_to)
     order by effective_from desc limit 1;
  end if;
  if vat_rate_id is null then raise exception 'An active Uganda VAT rate could not be created'; end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code, subtotal,
    tax_rate_id, tax_rate_percentage, other_charges, status, notes
  ) values (
    new.organization_id, customer_contact_id, 'HOTEL-' || new.confirmation_number, current_date, current_date,
    new.currency_code, new.taxable_subtotal, vat_rate_id, 18, new.lht_amount, 'draft',
    'Room reservation ' || new.confirmation_number || ' at ' || coalesce(organization_name, 'Hotel') ||
    '. Room: ' || coalesce(room_name, 'Room') || '. Check-in ' || new.check_in::text ||
    ', check-out ' || new.check_out::text || '. Hotel classification: ' || new.hotel_classification || ' stars.'
  ) returning id into invoice_uuid;

  insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
  values (invoice_uuid, new.organization_id, 'Accommodation (' || new.nights || ' night(s))', 1, new.taxable_subtotal);
  update public.books_invoices set status = 'paid' where id = invoice_uuid;
  perform public.post_hotel_invoice_recognition(invoice_uuid);
  update public.hotel_bookings
     set books_invoice_id = invoice_uuid, books_accounting_status = 'posted', books_accounting_error = null
   where id = new.id;
  return new;
exception when others then
  update public.hotel_bookings
     set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000)
   where id = new.id;
  return new;
end;
$$;

revoke all on function public.post_paid_hotel_booking_to_books() from public;

create or replace function public.retry_hotel_booking_accounting(target_booking_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare selected_booking public.hotel_bookings%rowtype;
begin
  select * into selected_booking from public.hotel_bookings where id = target_booking_id for update;
  if not found then raise exception 'Hotel booking was not found'; end if;
  if not exists (
    select 1 from public.user_profiles up
    join public.books_memberships bm on bm.user_id = up.user_id
    where up.user_id = auth.uid() and up.role = 'manager'
      and bm.organization_id = selected_booking.organization_id and bm.role in ('owner', 'admin')
  ) then raise exception 'Not authorized to retry this hotel invoice'; end if;
  if selected_booking.payment_status <> 'paid' then raise exception 'Only paid reservations can be posted to Books'; end if;
  if selected_booking.books_invoice_id is not null then return 'posted'; end if;
  update public.hotel_bookings
     set payment_status = 'paid', books_accounting_status = 'pending', books_accounting_error = null
   where id = selected_booking.id;
  select books_accounting_status into selected_booking.books_accounting_status
    from public.hotel_bookings where id = selected_booking.id;
  return selected_booking.books_accounting_status;
end;
$$;
revoke all on function public.retry_hotel_booking_accounting(uuid) from public, anon;
grant execute on function public.retry_hotel_booking_accounting(uuid) to authenticated;

drop trigger if exists hotel_booking_paid_books on public.hotel_bookings;
create trigger hotel_booking_paid_books
after update of payment_status on public.hotel_bookings
for each row execute function public.post_paid_hotel_booking_to_books();

create or replace function public.post_books_paid_invoice()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    perform public.post_books_journal_entry(new.organization_id, 'invoice_payment', new.id, new.issue_date, 'Payment received for invoice ' || new.invoice_number, '1000', '1100', new.total, new.currency_code, auth.uid());
  end if;
  return new;
end;
$$;

create or replace function public.get_books_currency_totals(target_organization_id uuid)
returns table (
  currency_code char(3),
  invoice_total numeric,
  income numeric,
  expenses numeric,
  net_result numeric,
  tax_total numeric,
  receivables numeric,
  assets numeric,
  liabilities numeric,
  equity numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.books_memberships
     where organization_id = target_organization_id and user_id = auth.uid()
  ) then
    raise exception 'Not authorized for this Books organization';
  end if;
  return query
  with invoice_totals as (
    select i.currency_code::char(3) as currency_code,
      sum(i.total) filter (where i.status <> 'void') as invoice_total,
      sum(i.subtotal) filter (where i.status in ('sent', 'overdue', 'paid')) as income,
      sum(i.tax_amount + i.other_charges) filter (where i.status <> 'void') as tax_total,
      sum(i.total) filter (where i.status in ('sent', 'overdue')) as receivables
    from public.books_invoices i where i.organization_id = target_organization_id group by i.currency_code
  ), expense_totals as (
    select e.currency_code::char(3) as currency_code, sum(e.amount + e.tax_amount) as expenses
    from public.books_expenses e where e.organization_id = target_organization_id group by e.currency_code
  ), ledger_totals as (
    select jl.currency_code::char(3) as currency_code,
      sum(jl.credit - jl.debit) filter (where a.type = 'income') as income,
      sum(jl.debit - jl.credit) filter (where a.type = 'expense') as expenses,
      sum(jl.debit - jl.credit) filter (where a.type = 'asset') as assets,
      sum(jl.credit - jl.debit) filter (where a.type = 'liability') as liabilities,
      sum(jl.credit - jl.debit) filter (where a.type = 'equity') as equity
    from public.books_journal_lines jl
    join public.books_journal_transactions jt on jt.id = jl.transaction_id
    join public.books_accounts a on a.id = jl.account_id
    where jt.organization_id = target_organization_id group by jl.currency_code
  ), currencies as (
    select currency_code from invoice_totals union select currency_code from expense_totals union select currency_code from ledger_totals
  )
  select c.currency_code,
    coalesce(i.invoice_total, 0), coalesce(i.income, 0), coalesce(e.expenses, 0),
    coalesce(i.income, 0) - coalesce(e.expenses, 0), coalesce(i.tax_total, 0), coalesce(i.receivables, 0),
    coalesce(l.assets, 0), coalesce(l.liabilities, 0), coalesce(l.equity, 0) + coalesce(i.income, 0) - coalesce(e.expenses, 0)
  from currencies c
  left join invoice_totals i using (currency_code)
  left join expense_totals e using (currency_code)
  left join ledger_totals l using (currency_code)
  order by c.currency_code;
end;
$$;

revoke all on function public.get_books_currency_totals(uuid) from public, anon;
grant execute on function public.get_books_currency_totals(uuid) to authenticated;

grant select on public.hotel_booking_page_settings, public.hotel_booking_offers, public.books_fx_rates to anon, authenticated;
grant select on public.hotel_public_room_listings to anon, authenticated;
grant execute on function public.get_hotel_room_availability(date, date) to anon, authenticated;
grant select on public.hotel_bookings, public.hotel_payment_attempts to authenticated;
grant select, insert, update, delete on public.hotel_rooms to authenticated;

grant all on public.hotel_booking_page_settings, public.hotel_booking_offers, public.hotel_rooms, public.hotel_bookings, public.hotel_payment_attempts, public.books_fx_rates, public.hotel_booking_rate_limits to service_role;

notify pgrst, 'reload schema';
commit;
