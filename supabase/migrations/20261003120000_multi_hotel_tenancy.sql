begin;

create table if not exists public.hotel_tenant_settings (
  organization_id uuid primary key references public.books_organizations(id) on delete restrict,
  display_name text not null,
  logo_url text,
  primary_color text,
  accent_color text,
  booking_title text not null,
  booking_subtitle text not null,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (primary_color is null or primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  check (accent_color is null or accent_color ~ '^#[0-9A-Fa-f]{6}$')
);

create table if not exists public.hotel_tenant_domains (
  domain text primary key,
  organization_id uuid not null references public.hotel_tenant_settings(organization_id) on delete cascade,
  created_at timestamptz not null default now(),
  check (domain = lower(domain)),
  check (domain !~ '[^a-z0-9.-]' and domain !~ '\.\.' and domain !~ '(^\.|\.$)')
);

alter table public.hotel_tenant_settings enable row level security;
alter table public.hotel_tenant_domains enable row level security;
revoke all on public.hotel_tenant_settings, public.hotel_tenant_domains from public, anon, authenticated;
grant select on public.hotel_tenant_settings, public.hotel_tenant_domains to service_role;

create or replace function public.resolve_hotel_tenant(target_hostname text)
returns table (
  organization_id uuid,
  name text,
  logo_url text,
  primary_color text,
  accent_color text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select settings.organization_id,
         settings.display_name,
         settings.logo_url,
         settings.primary_color,
         settings.accent_color
    from public.hotel_tenant_domains domains
    join public.hotel_tenant_settings settings using (organization_id)
   where domains.domain = lower(trim(target_hostname))
     and settings.is_active;
$$;
revoke all on function public.resolve_hotel_tenant(text) from public, anon, authenticated;
grant execute on function public.resolve_hotel_tenant(text) to service_role;

do $$
declare tenant_count integer;
begin
  select count(*) into tenant_count
    from public.books_organizations
   where lower(trim(name)) = 'sheraspace';
  if tenant_count <> 1 then
    raise exception 'Expected exactly one books_organizations row named Sheraspace; found %', tenant_count;
  end if;

  insert into public.hotel_tenant_settings (
    organization_id, display_name, booking_title, booking_subtitle, is_active
  )
  select id, 'Sheraspace', 'Book Your Stay at Sheraspace',
         'Enjoy a comfortable stay with thoughtful service and convenient amenities.', false
    from public.books_organizations
   where lower(trim(name)) = 'sheraspace'
  on conflict (organization_id) do nothing;
end;
$$;

alter table public.hotel_booking_offers
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
create index if not exists hotel_booking_offers_tenant_active_idx
  on public.hotel_booking_offers (organization_id, display_order)
  where organization_id is not null and is_active;

revoke all on public.hotel_booking_page_settings, public.hotel_booking_offers from public, anon, authenticated;
grant select on public.hotel_booking_page_settings, public.hotel_booking_offers to service_role;

revoke select on public.hotel_public_room_listings from public, anon, authenticated;
grant select on public.hotel_public_room_listings to service_role;
revoke select on public.hotel_rooms from anon;
grant select on public.hotel_rooms to authenticated, service_role;
drop policy if exists hotel_rooms_public_read on public.hotel_rooms;
create policy hotel_rooms_member_read on public.hotel_rooms
  for select to authenticated
  using (exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = hotel_rooms.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ));

create or replace function public.get_hotel_room_availability_for_tenant(
  target_organization_id uuid,
  target_check_in date,
  target_check_out date
)
returns table (room_id uuid, remaining_units integer)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if target_organization_id is null
     or target_check_in < current_date
     or target_check_out <= target_check_in
     or target_check_out > current_date + 365 then
    raise exception 'Select valid check-in and check-out dates';
  end if;
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then
    raise exception 'Hotel domain is not configured';
  end if;
  return query
  select room.id,
    greatest(room.available_units - coalesce(sum(booking.room_count) filter (
      where ((booking.booking_status in ('confirmed', 'manual_review') and booking.payment_status = 'paid')
        or (booking.booking_status = 'pending' and booking.payment_status = 'pending' and booking.expires_at > now()))
        and booking.check_in < target_check_out and booking.check_out > target_check_in
    ), 0), 0)::integer
  from public.hotel_rooms room
  left join public.hotel_bookings booking on booking.room_id = room.id
  where room.organization_id = target_organization_id and room.status = 'published'
  group by room.id, room.available_units;
end;
$$;
revoke all on function public.get_hotel_room_availability(date, date) from public, anon, authenticated;
revoke all on function public.get_hotel_room_availability_for_tenant(uuid, date, date) from public, anon, authenticated;
grant execute on function public.get_hotel_room_availability_for_tenant(uuid, date, date) to service_role;

create or replace function public.create_hotel_booking_for_tenant(
  target_organization_id uuid,
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
declare existing_organization_id uuid; existing_room_id uuid; room_organization_id uuid;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;

  select organization_id, room_id into existing_organization_id, existing_room_id
    from public.hotel_bookings where idempotency_key = target_idempotency_key;
  if found then
    if existing_organization_id is distinct from target_organization_id
       or existing_room_id is distinct from target_room_id then
      raise exception 'Reservation belongs to a different or unmapped hotel';
    end if;
  else
    select organization_id into room_organization_id
      from public.hotel_rooms where id = target_room_id and status = 'published';
    if room_organization_id is distinct from target_organization_id then
      raise exception 'This room is not available for this hotel';
    end if;
  end if;

  return query select * from public.create_hotel_booking(
    target_room_id, target_guest, target_check_in, target_check_out,
    target_guest_count, target_room_count, target_special_requests,
    target_preferences, target_user_id, target_idempotency_key,
    target_access_token_hash, target_fx_rates
  );
end;
$$;
revoke all on function public.create_hotel_booking_for_tenant(uuid, uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_hotel_booking_for_tenant(uuid, uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) to service_role;

do $$
declare function_source text; replacement_source text;
begin
  function_source := pg_get_functiondef('public.create_hotel_booking(uuid,jsonb,date,date,integer,integer,text,jsonb,uuid,uuid,text,jsonb)'::regprocedure);
  replacement_source := regexp_replace(
    function_source,
    'from public\.hotel_booking_offers[[:space:]]+where is_active',
    'from public.hotel_booking_offers where organization_id = selected_room.organization_id and is_active'
  );
  if replacement_source = function_source then
    raise exception 'Could not scope the existing hotel booking offer calculation';
  end if;
  execute replacement_source;
end;
$$;

alter table public.menu_items enable row level security;
revoke select on public.menu_items from anon;
grant select, insert, update, delete on public.menu_items to authenticated, service_role;
do $$
declare policy_row record;
begin
  for policy_row in
    select policyname from pg_policies
     where schemaname = 'public' and tablename = 'menu_items'
       and cmd in ('SELECT', 'ALL')
  loop
    execute format('drop policy if exists %I on public.menu_items', policy_row.policyname);
  end loop;
end;
$$;
create policy menu_items_hotel_member_access on public.menu_items
  for all to authenticated
  using (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = menu_items.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ))
  with check (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = menu_items.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ));

create or replace function public.create_menu_order_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
  target_items jsonb,
  target_order_type text,
  target_payment_method text,
  target_tip_amount numeric,
  target_customer jsonb,
  target_cart_id uuid,
  target_idempotency_key uuid
)
returns table (
  order_id uuid,
  order_number text,
  currency text,
  subtotal numeric,
  tax_amount numeric,
  service_fee numeric,
  tip_amount numeric,
  points_discount numeric,
  total_amount numeric
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare item_count integer; tenant_item_count integer; tenant_count integer; existing_organization_id uuid;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  if target_items is null or jsonb_typeof(target_items) is distinct from 'array'
     or jsonb_array_length(target_items) = 0 then
    raise exception 'Select at least one menu item';
  end if;
  if exists (
    select 1 from jsonb_array_elements(target_items) requested(value)
     where coalesce(requested.value->>'menuItemId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then raise exception 'A menu item is invalid'; end if;

  select count(*), count(item.id), count(distinct item.organization_id)
    into item_count, tenant_item_count, tenant_count
    from jsonb_array_elements(target_items) requested(value)
    left join public.menu_items item
      on item.id = (requested.value->>'menuItemId')::uuid
     and item.is_published;
  if item_count <> tenant_item_count or tenant_count <> 1
     or not exists (
       select 1 from jsonb_array_elements(target_items) requested(value)
       join public.menu_items item on item.id = (requested.value->>'menuItemId')::uuid
       where item.is_published and item.organization_id = target_organization_id
     )
     or exists (
       select 1 from jsonb_array_elements(target_items) requested(value)
       left join public.menu_items item on item.id = (requested.value->>'menuItemId')::uuid and item.is_published
       where item.id is null or item.organization_id is distinct from target_organization_id
     ) then
    raise exception 'A selected menu item is unavailable for this hotel';
  end if;

  select organization_id into existing_organization_id
    from public.menu_orders
   where user_id = target_user_id and checkout_idempotency_key = target_idempotency_key;
  if found and existing_organization_id is distinct from target_organization_id then
    raise exception 'Checkout belongs to a different or unmapped hotel';
  end if;

  return query select * from public.create_menu_order(
    target_user_id, target_items, target_order_type, target_payment_method,
    target_tip_amount, target_customer, target_cart_id, target_idempotency_key
  );
end;
$$;
revoke all on function public.create_menu_order_for_tenant(uuid, uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_menu_order_for_tenant(uuid, uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) to service_role;

drop policy if exists special_events_public_select on public.special_events;
drop policy if exists special_events_manager_select on public.special_events;
revoke select on public.special_events from anon;
grant select on public.special_events to authenticated, service_role;
create policy special_events_hotel_member_or_booking_read on public.special_events
  for select to authenticated
  using (
    (organization_id is not null and exists (
      select 1 from public.books_memberships membership
       where membership.organization_id = special_events.organization_id
         and membership.user_id = auth.uid()
         and membership.role in ('owner', 'admin')
    ))
    or exists (
      select 1 from public.special_event_bookings booking
       where booking.event_id = special_events.id and booking.user_id = auth.uid()
    )
  );

drop policy if exists special_event_ticket_types_public_select on public.special_event_ticket_types;
revoke select on public.special_event_ticket_types from anon;
grant select on public.special_event_ticket_types to authenticated, service_role;

create or replace function public.create_special_event_booking_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
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
declare event_organization_id uuid;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  select organization_id into event_organization_id
    from public.special_events where id = target_event_id;
  if event_organization_id is distinct from target_organization_id then
    raise exception 'This event is not available for this hotel';
  end if;

  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  return query select * from public.create_special_event_booking(
    target_event_id, target_quantity, guest_first_name, guest_last_name,
    guest_email, guest_phone, special_requests, target_ticket_type_id,
    target_idempotency_key, target_attendee_names, target_invitation_id,
    target_share_token
  );
end;
$$;
revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_special_event_booking_for_tenant(uuid, uuid, uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_special_event_booking_for_tenant(uuid, uuid, uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) to service_role;

create or replace function public.confirm_free_special_event_booking_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
  target_booking_id uuid
)
returns table (booking_id uuid, confirmation_number text, ticket_code text, ticket_count integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare booking_organization_id uuid;
begin
  select organization_id into booking_organization_id
    from public.special_event_bookings
   where id = target_booking_id and user_id = target_user_id;
  if booking_organization_id is distinct from target_organization_id then
    raise exception 'This event booking is not available for this hotel';
  end if;
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  return query select * from public.confirm_free_special_event_booking(target_booking_id);
end;
$$;
revoke all on function public.confirm_free_special_event_booking(uuid) from public, anon, authenticated;
revoke all on function public.confirm_free_special_event_booking_for_tenant(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.confirm_free_special_event_booking_for_tenant(uuid, uuid, uuid) to service_role;

do $$
declare function_source text; replacement_source text; start_at integer; end_at integer;
begin
  function_source := pg_get_functiondef('public.post_paid_menu_order_to_books_v2()'::regprocedure);
  start_at := strpos(function_source, '  select organization_id' || E'\n' || '    into seller_organization_id' || E'\n' || '    from public.books_menu_sales_settings');
  end_at := strpos(function_source, '  if seller_organization_id is null then' || E'\n' || '    update public.menu_orders', start_at);
  if start_at = 0 or end_at = 0 then
    raise exception 'Could not scope menu accounting to the order tenant';
  end if;
  replacement_source := substr(function_source, 1, start_at - 1)
    || '  seller_organization_id := new.organization_id;' || E'\n\n'
    || substr(function_source, end_at);
  execute replacement_source;

  function_source := pg_get_functiondef('public.post_special_event_payment_to_books()'::regprocedure);
  start_at := strpos(function_source, '  select organization_id into seller_organization_id from public.books_menu_sales_settings');
  end_at := strpos(function_source, '  if seller_organization_id is null then' || E'\n' || '    update public.special_event_payments', start_at);
  if start_at = 0 or end_at = 0 then
    raise exception 'Could not scope event accounting to the event tenant';
  end if;
  replacement_source := substr(function_source, 1, start_at - 1)
    || '  seller_organization_id := event_row.organization_id;' || E'\n'
    || substr(function_source, end_at);
  execute replacement_source;
end;
$$;

notify pgrst, 'reload schema';
commit;
