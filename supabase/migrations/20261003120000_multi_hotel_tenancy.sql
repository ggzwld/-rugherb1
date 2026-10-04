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

drop function if exists public.resolve_hotel_tenant(text);
create function public.resolve_hotel_tenant(target_hostname text)
returns table (
  organization_id uuid,
  name text,
  domain text,
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
         domains.domain,
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
update public.hotel_booking_offers offers
   set organization_id = organization.id
  from public.books_organizations organization
 where lower(trim(organization.name)) = 'sheraspace'
   and offers.organization_id is null;

alter table public.menu_carts
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

with ownership_sources as (
  select cart.id as cart_id, orders.organization_id
    from public.menu_carts cart
    join public.menu_orders orders on orders.id = cart.order_id
   where orders.organization_id is not null
  union all
  select cart_item.cart_id, item.organization_id
    from public.menu_cart_items cart_item
    join public.menu_items item on item.id = cart_item.menu_item_id
   where item.organization_id is not null
), unique_ownership as (
  select cart_id, min(organization_id::text)::uuid as organization_id
    from ownership_sources
   group by cart_id
  having count(distinct organization_id) = 1
)
update public.menu_carts cart
   set organization_id = unique_ownership.organization_id
  from unique_ownership
 where cart.id = unique_ownership.cart_id and cart.organization_id is null;

drop index if exists public.menu_carts_one_active_per_user;
create unique index if not exists menu_carts_one_active_per_user_tenant
  on public.menu_carts (user_id, organization_id)
  where status = 'active' and organization_id is not null;

do $$
declare policy_row record;
begin
  for policy_row in select policyname from pg_policies where schemaname = 'public' and tablename in ('menu_carts', 'menu_cart_items')
  loop execute format('drop policy if exists %I on public.%I', policy_row.policyname, policy_row.tablename); end loop;
end;
$$;
grant select, insert, update, delete on public.menu_carts, public.menu_cart_items to authenticated;
create policy menu_carts_owner_select on public.menu_carts
  for select to authenticated using (user_id = auth.uid() and organization_id is not null);
create policy menu_carts_owner_insert on public.menu_carts
  for insert to authenticated with check (user_id = auth.uid() and organization_id is not null and exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = menu_carts.organization_id and settings.is_active
  ));
create policy menu_carts_owner_update on public.menu_carts
  for update to authenticated using (user_id = auth.uid() and organization_id is not null)
  with check (user_id = auth.uid() and organization_id is not null);
create policy menu_carts_owner_delete on public.menu_carts
  for delete to authenticated using (user_id = auth.uid() and organization_id is not null);
create policy menu_cart_items_owner_select on public.menu_cart_items
  for select to authenticated using (exists (
    select 1 from public.menu_carts cart join public.menu_items item on item.id = menu_cart_items.menu_item_id
     where cart.id = menu_cart_items.cart_id and cart.user_id = auth.uid()
       and cart.organization_id is not null and item.organization_id = cart.organization_id
  ));
create policy menu_cart_items_owner_insert on public.menu_cart_items
  for insert to authenticated with check (exists (
    select 1 from public.menu_carts cart join public.menu_items item on item.id = menu_cart_items.menu_item_id
     where cart.id = menu_cart_items.cart_id and cart.user_id = auth.uid()
       and cart.organization_id is not null and item.organization_id = cart.organization_id
  ));
create policy menu_cart_items_owner_update on public.menu_cart_items
  for update to authenticated using (exists (
    select 1 from public.menu_carts cart join public.menu_items item on item.id = menu_cart_items.menu_item_id
     where cart.id = menu_cart_items.cart_id and cart.user_id = auth.uid()
       and cart.organization_id is not null and item.organization_id = cart.organization_id
  )) with check (exists (
    select 1 from public.menu_carts cart join public.menu_items item on item.id = menu_cart_items.menu_item_id
     where cart.id = menu_cart_items.cart_id and cart.user_id = auth.uid()
       and cart.organization_id is not null and item.organization_id = cart.organization_id
  ));
create policy menu_cart_items_owner_delete on public.menu_cart_items
  for delete to authenticated using (exists (
    select 1 from public.menu_carts cart join public.menu_items item on item.id = menu_cart_items.menu_item_id
     where cart.id = menu_cart_items.cart_id and cart.user_id = auth.uid()
       and cart.organization_id is not null and item.organization_id = cart.organization_id
  ));

alter table public.special_event_plans
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

update public.special_event_plans plans
   set organization_id = event.organization_id
  from public.special_events event
 where plans.organization_id is null
   and plans.special_event_id = event.id
   and event.organization_id is not null;

with unique_membership as (
  select user_id, min(organization_id::text)::uuid as organization_id
    from public.books_memberships
   where role in ('owner', 'admin', 'manager')
   group by user_id
  having count(distinct organization_id) = 1
)
update public.special_event_plans plans
   set organization_id = membership.organization_id
  from unique_membership membership
 where plans.organization_id is null
   and plans.user_id = membership.user_id;

create index if not exists special_event_plans_tenant_status_idx
  on public.special_event_plans (organization_id, status, created_at)
  where organization_id is not null;

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
       and membership.role in ('owner', 'admin', 'manager')
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
  loop
    execute format('drop policy if exists %I on public.menu_items', policy_row.policyname);
  end loop;
end;
$$;
create or replace function public.can_manage_hotel_menu(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ) or exists (
    select 1
      from public.books_memberships membership
      join public.user_profiles profile on profile.user_id = membership.user_id
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role = 'provider'
       and profile.role = 'service_provider'
       and profile.menu_access_approved
       and profile.menu_access_role in ('chef', 'food_beverage_manager')
  );
$$;
revoke all on function public.can_manage_hotel_menu(uuid) from public, anon;
grant execute on function public.can_manage_hotel_menu(uuid) to authenticated, service_role;

create or replace function public.attach_menu_item_hotel_organization()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Menu item hotel ownership cannot be changed';
  end if;
  if new.organization_id is null then
    raise exception 'Menu item hotel ownership is required';
  end if;
  if not public.can_manage_hotel_menu(new.organization_id) then
    raise exception 'Menu manager is not authorized for this hotel';
  end if;
  return new;
end;
$$;
revoke all on function public.attach_menu_item_hotel_organization() from public, anon, authenticated;

create policy menu_items_hotel_member_access on public.menu_items
  for all to authenticated
  using (organization_id is not null and public.can_manage_hotel_menu(organization_id))
  with check (organization_id is not null and public.can_manage_hotel_menu(organization_id));

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
declare item_count integer; tenant_item_count integer; tenant_count integer; existing_organization_id uuid; cart_organization_id uuid;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  if target_cart_id is not null then
    select organization_id into cart_organization_id
      from public.menu_carts
     where id = target_cart_id and user_id = target_user_id and status = 'active';
    if cart_organization_id is distinct from target_organization_id then
      raise exception 'Saved menu cart belongs to a different hotel';
    end if;
  end if;
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

create or replace function public.menu_capture_visible_to_current_user(target_order_id uuid)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.menu_orders orders
    join public.books_memberships membership on membership.organization_id = orders.organization_id
    where orders.id = target_order_id
      and orders.organization_id is not null
      and membership.user_id = auth.uid()
      and membership.role in ('owner', 'admin', 'manager')
  );
$$;
revoke all on function public.menu_capture_visible_to_current_user(uuid) from public, anon;
grant execute on function public.menu_capture_visible_to_current_user(uuid) to authenticated;

do $$
declare policy_row record;
begin
  for policy_row in
    select policyname from pg_policies
     where schemaname = 'public' and tablename = 'special_events'
  loop
    execute format('drop policy if exists %I on public.special_events', policy_row.policyname);
  end loop;
end;
$$;
revoke select on public.special_events from public, anon;
grant select, insert, update, delete on public.special_events to authenticated, service_role;
create policy special_events_hotel_member_or_booking_read on public.special_events
  for select to authenticated
  using (
    (organization_id is not null and exists (
      select 1 from public.books_memberships membership
       where membership.organization_id = special_events.organization_id
         and membership.user_id = auth.uid()
         and membership.role in ('owner', 'admin', 'manager')
    ))
    or exists (
      select 1 from public.special_event_bookings booking
       where booking.event_id = special_events.id and booking.user_id = auth.uid()
    )
  );
create policy special_events_hotel_member_insert on public.special_events
  for insert to authenticated
  with check (
    organizer_id = auth.uid() and created_by = auth.uid() and organization_id is not null
    and exists (
      select 1 from public.books_memberships membership
       where membership.organization_id = special_events.organization_id
         and membership.user_id = auth.uid()
         and membership.role in ('owner', 'admin', 'manager')
    )
  );
create policy special_events_hotel_member_update on public.special_events
  for update to authenticated
  using (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = special_events.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ))
  with check (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = special_events.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ));
create policy special_events_hotel_member_delete on public.special_events
  for delete to authenticated
  using (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = special_events.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ));

do $$
declare policy_row record;
begin
  for policy_row in select policyname from pg_policies where schemaname = 'public' and tablename = 'special_event_ticket_types'
  loop execute format('drop policy if exists %I on public.special_event_ticket_types', policy_row.policyname); end loop;
end;
$$;
revoke select on public.special_event_ticket_types from public, anon;
grant select on public.special_event_ticket_types to authenticated, service_role;
create policy special_event_ticket_types_hotel_member_select on public.special_event_ticket_types
  for select to authenticated
  using (exists (
    select 1 from public.special_events event
    join public.books_memberships membership on membership.organization_id = event.organization_id
    where event.id = special_event_ticket_types.event_id
      and membership.user_id = auth.uid()
      and membership.role in ('owner', 'admin', 'manager')
  ));

create or replace function public.is_special_event_manager(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.special_events event
    join public.books_memberships membership on membership.organization_id = event.organization_id
   where event.id = target_event_id
     and membership.user_id = auth.uid()
     and membership.role in ('owner', 'admin', 'manager')
  );
$$;
revoke all on function public.is_special_event_manager(uuid) from public, anon;
grant execute on function public.is_special_event_manager(uuid) to authenticated;

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

alter table public.special_event_plans enable row level security;
do $$
declare policy_row record;
begin
  for policy_row in
    select policyname from pg_policies
     where schemaname = 'public' and tablename = 'special_event_plans'
  loop
    execute format('drop policy if exists %I on public.special_event_plans', policy_row.policyname);
  end loop;
end;
$$;
revoke all on public.special_event_plans from public, anon, authenticated;
grant select, delete on public.special_event_plans to authenticated;
create policy special_event_plans_owner_read on public.special_event_plans
  for select to authenticated using (user_id = auth.uid());
create policy special_event_plans_hotel_manager_read on public.special_event_plans
  for select to authenticated using (organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = special_event_plans.organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ));
create policy special_event_plans_owner_delete on public.special_event_plans
  for delete to authenticated using (user_id = auth.uid() and status = 'submitted');

create or replace function public.is_special_event_platform_manager(target_event_id uuid default null)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.books_memberships membership
     where membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
       and membership.organization_id = coalesce(
         (select event.organization_id from public.special_events event where event.id = target_event_id),
         nullif(current_setting('app.hotel_organization_id', true), '')::uuid
       )
  );
$$;
revoke all on function public.is_special_event_platform_manager(uuid) from public, anon;
grant execute on function public.is_special_event_platform_manager(uuid) to authenticated;

create or replace function public.is_special_event_manager(target_event_id uuid)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.special_events event
    join public.books_memberships membership on membership.organization_id = event.organization_id
    where event.id = target_event_id and membership.user_id = auth.uid()
      and membership.role in ('owner', 'admin', 'manager')
  ) or exists (
    select 1 from public.special_events event
    where event.id = target_event_id and event.created_by = auth.uid() and event.source_plan_id is not null
  ) or exists (
    select 1 from public.special_event_staff staff
    where staff.event_id = target_event_id and staff.user_id = auth.uid()
      and staff.status = 'active' and staff.role = 'manager'
  );
$$;
revoke all on function public.is_special_event_manager(uuid) from public, anon;
grant execute on function public.is_special_event_manager(uuid) to authenticated;

create or replace function public.attach_special_event_plan_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare target_organization uuid;
begin
  target_organization := nullif(current_setting('app.hotel_organization_id', true), '')::uuid;
  if target_organization is null or new.organization_id is distinct from target_organization then
    raise exception 'Event proposal hotel ownership is required';
  end if;
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  if tg_op = 'UPDATE' and old.organization_id is distinct from new.organization_id then
    raise exception 'Event proposal hotel ownership cannot be changed';
  end if;
  return new;
end;
$$;
revoke all on function public.attach_special_event_plan_hotel_organization() from public, anon, authenticated;
drop trigger if exists special_event_plan_hotel_organization on public.special_event_plans;
create trigger special_event_plan_hotel_organization
  before insert or update of organization_id on public.special_event_plans
  for each row execute function public.attach_special_event_plan_hotel_organization();

create or replace function public.attach_special_event_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare candidate uuid; candidate_count integer; plan_organization uuid;
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Event hotel ownership cannot be changed';
  end if;
  if new.source_plan_id is not null then
    select organization_id into plan_organization
      from public.special_event_plans where id = new.source_plan_id;
    if plan_organization is null then raise exception 'Source event proposal has no hotel ownership'; end if;
    if new.organization_id is not null and new.organization_id is distinct from plan_organization then
      raise exception 'Event hotel must match its proposal';
    end if;
    new.organization_id := plan_organization;
  elsif new.organization_id is null then
    select (array_agg(membership.organization_id order by membership.organization_id::text))[1], count(distinct membership.organization_id)
      into candidate, candidate_count
      from public.books_memberships membership
      where membership.user_id in (new.organizer_id, new.created_by)
        and membership.role in ('owner', 'admin', 'manager');
    if candidate_count = 1 then new.organization_id := candidate; end if;
  end if;
  if new.organization_id is not null and not (
    public.hotel_loyalty_has_manager_access(new.organization_id, new.organizer_id)
    or public.hotel_loyalty_has_manager_access(new.organization_id, new.created_by)
  ) then raise exception 'Event organizer is not authorized for this hotel'; end if;
  return new;
end;
$$;

create or replace function public.submit_special_event_proposal_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
  target_plan_id uuid,
  proposal_title text,
  proposal_description text,
  proposal_category text,
  proposal_starts_at timestamptz,
  proposal_ends_at timestamptz,
  proposal_timezone text,
  proposal_facility_id uuid,
  proposal_expected_guests integer,
  proposal_contact_name text,
  proposal_contact_email text,
  proposal_contact_phone text,
  proposal_image_url text,
  proposal_is_private boolean,
  proposal_entry_type text,
  proposal_entry_fee numeric,
  proposal_share_manager_operations boolean
)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  result_plan_id uuid;
  facility_name text;
  timezone_name text := coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala');
  manager_user_id uuid;
begin
  if target_organization_id is null or target_user_id is null or not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  if proposal_entry_type not in ('free', 'paid') or proposal_entry_fee is null
     or (proposal_entry_type = 'free' and proposal_entry_fee <> 0)
     or (proposal_entry_type = 'paid' and proposal_entry_fee <= 0) then
    raise exception 'Choose free entry or enter a positive paid entry fee';
  end if;
  if nullif(trim(proposal_title), '') is null or nullif(trim(proposal_category), '') is null
     or proposal_starts_at is null or proposal_ends_at <= proposal_starts_at
     or proposal_starts_at <= now() or proposal_expected_guests is null or proposal_expected_guests < 1
     or nullif(trim(proposal_contact_name), '') is null
     or nullif(trim(proposal_contact_email), '') is null then
    raise exception 'Complete the required event and contact details';
  end if;
  select name into facility_name from public.special_event_facilities
   where id = proposal_facility_id and is_active;
  if facility_name is null then raise exception 'Choose an available hotel facility'; end if;

  perform set_config('app.hotel_organization_id', target_organization_id::text, true);
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);

  if target_plan_id is null then
    insert into public.special_event_plans (
      user_id, organization_id, title, event_date, starts_at, ends_at, timezone, location, facility_id,
      expected_guests, description, category, image_url, is_private, contact_name, contact_email,
      contact_phone, share_manager_operations, entry_type, entry_fee, entry_currency, status
    ) values (
      target_user_id, target_organization_id, trim(proposal_title),
      (proposal_starts_at at time zone timezone_name)::date, proposal_starts_at, proposal_ends_at,
      timezone_name, facility_name, proposal_facility_id, proposal_expected_guests,
      nullif(trim(proposal_description), ''), trim(proposal_category), nullif(trim(proposal_image_url), ''),
      coalesce(proposal_is_private, false), trim(proposal_contact_name), lower(trim(proposal_contact_email)),
      nullif(trim(proposal_contact_phone), ''), coalesce(proposal_share_manager_operations, false),
      proposal_entry_type, proposal_entry_fee, 'UGX', 'submitted'
    ) returning id into result_plan_id;
  else
    update public.special_event_plans set
      title = trim(proposal_title),
      event_date = (proposal_starts_at at time zone timezone_name)::date,
      starts_at = proposal_starts_at, ends_at = proposal_ends_at, timezone = timezone_name,
      location = facility_name, facility_id = proposal_facility_id,
      expected_guests = proposal_expected_guests, description = nullif(trim(proposal_description), ''),
      category = trim(proposal_category), image_url = nullif(trim(proposal_image_url), ''),
      is_private = coalesce(proposal_is_private, false), contact_name = trim(proposal_contact_name),
      contact_email = lower(trim(proposal_contact_email)), contact_phone = nullif(trim(proposal_contact_phone), ''),
      share_manager_operations = coalesce(proposal_share_manager_operations, false),
      entry_type = proposal_entry_type, entry_fee = proposal_entry_fee, entry_currency = 'UGX',
      manager_note = null, reviewed_by = null, reviewed_at = null, status = 'submitted', updated_at = now()
     where id = target_plan_id and user_id = target_user_id
       and organization_id = target_organization_id and status = 'submitted'
     returning id into result_plan_id;
    if result_plan_id is null then raise exception 'This event proposal can no longer be edited'; end if;
  end if;

  for manager_user_id in
    select distinct membership.user_id from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.role in ('owner', 'admin', 'manager')
  loop
    insert into public.notifications (user_id, event_proposal_id, type, message)
    values (manager_user_id, result_plan_id, 'event_proposal_submitted',
      'A new event proposal, “' || trim(proposal_title) || '”, is ready for review.');
  end loop;
  return result_plan_id;
end;
$$;
revoke all on function public.submit_special_event_proposal(uuid,text,text,text,timestamptz,timestamptz,text,uuid,integer,text,text,text,text,boolean,text,numeric,boolean) from public, anon, authenticated;
revoke all on function public.submit_special_event_proposal_for_tenant(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,text,uuid,integer,text,text,text,text,boolean,text,numeric,boolean) from public, anon, authenticated;
grant execute on function public.submit_special_event_proposal_for_tenant(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,text,uuid,integer,text,text,text,text,boolean,text,numeric,boolean) to service_role;

create or replace function public.review_special_event_proposal_for_tenant(
  target_organization_id uuid, target_user_id uuid, target_plan_id uuid, review_action text,
  suggested_values jsonb default null, review_message text default null
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id and membership.user_id = target_user_id
       and membership.role in ('owner', 'admin', 'manager')
  ) or not exists (
    select 1 from public.special_event_plans plans
     where plans.id = target_plan_id and plans.organization_id = target_organization_id
  ) then raise exception 'You cannot manage this hotel event proposal'; end if;
  perform set_config('app.hotel_organization_id', target_organization_id::text, true);
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  perform public.review_special_event_proposal(target_plan_id, review_action, suggested_values, review_message);
end;
$$;
revoke all on function public.review_special_event_proposal(uuid,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.review_special_event_proposal_for_tenant(uuid,uuid,uuid,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.review_special_event_proposal_for_tenant(uuid,uuid,uuid,text,jsonb,text) to service_role;

create or replace function public.publish_special_event_proposal_for_tenant(target_organization_id uuid, target_user_id uuid, target_plan_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id and membership.user_id = target_user_id
       and membership.role in ('owner', 'admin', 'manager')
  ) or not exists (
    select 1 from public.special_event_plans plans
     where plans.id = target_plan_id and plans.organization_id = target_organization_id
  ) then raise exception 'You cannot publish this hotel event proposal'; end if;
  perform set_config('app.hotel_organization_id', target_organization_id::text, true);
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  perform public.publish_special_event_proposal(target_plan_id);
end;
$$;
revoke all on function public.publish_special_event_proposal(uuid) from public, anon, authenticated;
revoke all on function public.publish_special_event_proposal_for_tenant(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.publish_special_event_proposal_for_tenant(uuid,uuid,uuid) to service_role;

create or replace function public.respond_to_special_event_proposal(target_plan_id uuid, accept_suggestions boolean)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare v_plan public.special_event_plans%rowtype; v_facility_name text; v_event_id uuid;
begin
  select * into v_plan from public.special_event_plans
   where id = target_plan_id and user_id = auth.uid() for update;
  if not found or v_plan.status <> 'changes_requested' or v_plan.organization_id is null then
    raise exception 'This proposal has no suggested changes to respond to';
  end if;
  if not accept_suggestions then
    update public.special_event_plans set status = 'declined', updated_at = now() where id = v_plan.id;
    insert into public.notifications (user_id, event_proposal_id, type, message)
    select distinct membership.user_id, v_plan.id, 'event_proposal_updated',
      'The proposer declined the suggested changes for “' || v_plan.title || '”.'
      from public.books_memberships membership
     where membership.organization_id = v_plan.organization_id
       and membership.role in ('owner', 'admin', 'manager');
    return;
  end if;
  if v_plan.suggested_starts_at is null or v_plan.suggested_starts_at <= now()
     or v_plan.suggested_ends_at <= v_plan.suggested_starts_at
     or v_plan.suggested_expected_guests < 1 then
    raise exception 'The suggested event details are no longer valid';
  end if;
  select name into v_facility_name from public.special_event_facilities
   where id = v_plan.suggested_facility_id and is_active;
  if v_facility_name is null then raise exception 'The suggested hotel facility is no longer available'; end if;
  update public.special_event_plans set
    title = v_plan.suggested_title, description = v_plan.suggested_description,
    category = v_plan.suggested_category, starts_at = v_plan.suggested_starts_at,
    ends_at = v_plan.suggested_ends_at, event_date = (v_plan.suggested_starts_at at time zone v_plan.timezone)::date,
    facility_id = v_plan.suggested_facility_id, location = v_facility_name,
    expected_guests = v_plan.suggested_expected_guests, status = 'scheduled', updated_at = now(),
    suggested_title = null, suggested_description = null, suggested_category = null,
    suggested_starts_at = null, suggested_ends_at = null,
    suggested_facility_id = null, suggested_expected_guests = null
   where id = v_plan.id returning * into v_plan;
  insert into public.special_events (
    title, description, category, starts_at, ends_at, timezone, location, facility_id,
    price, currency, capacity, ticket_type_capacity, max_tickets_per_order,
    attendees_count, featured, rating, host_name, image_url, status, organizer_id,
    created_by, is_private, source_plan_id, share_token, organization_id
  ) values (
    v_plan.title, v_plan.description, v_plan.category, v_plan.starts_at, v_plan.ends_at,
    v_plan.timezone, v_plan.location, v_plan.facility_id, v_plan.entry_fee, v_plan.entry_currency,
    v_plan.expected_guests, v_plan.expected_guests, 10, 0, false, 0, v_plan.contact_name,
    v_plan.image_url, 'draft', v_plan.reviewed_by, v_plan.user_id, v_plan.is_private,
    v_plan.id, v_plan.share_token, v_plan.organization_id
  ) returning id into v_event_id;
  if v_plan.share_manager_operations then
    insert into public.special_event_staff (event_id, user_id, role, added_by)
    values (v_event_id, v_plan.reviewed_by, 'manager', v_plan.reviewed_by)
    on conflict (event_id, user_id) do update set status = 'active', role = 'manager', updated_at = now();
  end if;
  update public.special_event_plans set special_event_id = v_event_id where id = v_plan.id;
  insert into public.notifications (user_id, event_proposal_id, type, message)
  values (v_plan.user_id, v_plan.id, 'event_proposal_scheduled',
    case when v_plan.is_private then 'Your private event proposal has been scheduled with the updated details.'
      else 'Your updated event proposal has been scheduled with the accepted details. The hotel team will decide whether to list it in Hotel Events.' end);
end;
$$;
create or replace function public.respond_to_special_event_proposal_for_tenant(
  target_organization_id uuid, target_user_id uuid, target_plan_id uuid, accept_suggestions boolean
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if target_user_id is null or not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) or not exists (
    select 1 from public.special_event_plans plans
     where plans.id = target_plan_id and plans.organization_id = target_organization_id
       and plans.user_id = target_user_id
  ) then raise exception 'This proposal is not available for this hotel'; end if;
  perform set_config('app.hotel_organization_id', target_organization_id::text, true);
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  perform public.respond_to_special_event_proposal(target_plan_id, accept_suggestions);
end;
$$;
revoke all on function public.respond_to_special_event_proposal(uuid,boolean) from public, anon, authenticated;
revoke all on function public.respond_to_special_event_proposal_for_tenant(uuid,uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.respond_to_special_event_proposal_for_tenant(uuid,uuid,uuid,boolean) to service_role;

alter table public.complaints
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
create index if not exists complaints_tenant_status_idx
  on public.complaints (organization_id, status, created_at desc)
  where organization_id is not null;

create or replace function public.notify_managers_of_complaint()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  insert into public.notifications (user_id, complaint_id, type, message)
  select distinct membership.user_id, new.id, 'complaint_filed',
    'New complaint filed by ' || new.guest_name || ' in room ' || new.room_number
    from public.books_memberships membership
   where membership.organization_id = new.organization_id
     and membership.role in ('owner', 'admin', 'manager');
  return new;
end;
$$;

create or replace function public.notify_on_task_created()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.assigned_to is not null then
    insert into public.notifications (user_id, task_id, type, message)
    select profile.user_id, new.id, 'task_assigned', 'New task assigned to you: ' || new.title
      from public.user_profiles profile where profile.id = new.assigned_to;
  end if;
  insert into public.notifications (user_id, task_id, type, message)
  select distinct membership.user_id, new.id, 'task_created', 'New task created: ' || new.title
    from public.books_memberships membership
   where membership.organization_id = new.organization_id
     and membership.role in ('owner', 'admin', 'manager')
     and membership.user_id <> new.created_by;
  return new;
end;
$$;

create or replace function public.hotel_user_manages_organization(target_organization_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select target_organization_id is not null and exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = target_user_id
       and membership.role in ('owner', 'admin', 'manager')
  );
$$;
revoke all on function public.hotel_user_manages_organization(uuid,uuid) from public, anon;
grant execute on function public.hotel_user_manages_organization(uuid,uuid) to authenticated, service_role;

create or replace function public.hotel_user_can_access_task(target_task_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.tasks task
     where task.id = target_task_id and task.organization_id is not null
       and (
         public.hotel_user_manages_organization(task.organization_id, target_user_id)
         or task.created_by = target_user_id
         or exists (select 1 from public.user_profiles profile
                     where profile.id = task.assigned_to and profile.user_id = target_user_id)
       )
  );
$$;
revoke all on function public.hotel_user_can_access_task(uuid,uuid) from public, anon;
grant execute on function public.hotel_user_can_access_task(uuid,uuid) to authenticated, service_role;

create or replace function public.attach_task_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Task hotel ownership cannot be changed';
  end if;
  if new.organization_id is null or not public.hotel_user_manages_organization(new.organization_id, auth.uid()) then
    raise exception 'Task creator is not authorized for this hotel';
  end if;
  if new.complaint_id is not null and not exists (
    select 1 from public.complaints complaint
     where complaint.id = new.complaint_id and complaint.organization_id = new.organization_id
  ) then raise exception 'Task complaint must belong to the same hotel'; end if;
  if new.assigned_to is not null and not exists (
    select 1 from public.user_profiles profile
    join public.books_memberships membership on membership.user_id = profile.user_id
     where profile.id = new.assigned_to and membership.organization_id = new.organization_id
  ) then raise exception 'Task assignee must belong to the same hotel'; end if;
  return new;
end;
$$;
revoke all on function public.attach_task_hotel_organization() from public, anon, authenticated;
drop trigger if exists task_hotel_organization on public.tasks;
create trigger task_hotel_organization before insert or update of organization_id, created_by, complaint_id
on public.tasks for each row execute function public.attach_task_hotel_organization();

alter table public.complaints enable row level security;
do $$
declare policy_row record;
begin
  for policy_row in select policyname from pg_policies where schemaname = 'public' and tablename = 'complaints'
  loop execute format('drop policy if exists %I on public.complaints', policy_row.policyname); end loop;
end;
$$;
revoke all on public.complaints from public, anon, authenticated;
grant select, update on public.complaints to authenticated;
create policy complaints_hotel_member_read on public.complaints
  for select to authenticated using (public.hotel_user_manages_organization(organization_id));
create policy complaints_owner_read on public.complaints
  for select to authenticated using (organization_id is not null and user_id = auth.uid());
create policy complaints_hotel_member_update on public.complaints
  for update to authenticated
  using (public.hotel_user_manages_organization(organization_id))
  with check (public.hotel_user_manages_organization(organization_id));

alter table public.tasks enable row level security;
do $$
declare policy_row record;
begin
  for policy_row in select policyname from pg_policies where schemaname = 'public' and tablename = 'tasks'
  loop execute format('drop policy if exists %I on public.tasks', policy_row.policyname); end loop;
end;
$$;
revoke all on public.tasks from public, anon, authenticated;
grant select, insert, update on public.tasks to authenticated;
create policy tasks_hotel_member_read on public.tasks
  for select to authenticated using (public.hotel_user_manages_organization(organization_id));
create policy tasks_assignee_read on public.tasks
  for select to authenticated using (organization_id is not null and exists (
    select 1 from public.user_profiles profile where profile.id = tasks.assigned_to and profile.user_id = auth.uid()
  ));
create policy tasks_creator_read on public.tasks
  for select to authenticated using (organization_id is not null and created_by = auth.uid());
create policy tasks_hotel_member_insert on public.tasks
  for insert to authenticated with check (
    organization_id is not null and created_by = auth.uid()
    and public.hotel_user_manages_organization(organization_id)
  );
create policy tasks_hotel_member_update on public.tasks
  for update to authenticated
  using (public.hotel_user_manages_organization(organization_id))
  with check (public.hotel_user_manages_organization(organization_id));

do $$
declare function_source text; replacement_source text; start_at integer; end_at integer;
begin
  function_source := pg_get_functiondef('public.post_paid_menu_order_to_books_v2()'::regprocedure);
  start_at := strpos(function_source, '  select organization_id into seller_organization_id' || E'\n' || '    from public.books_menu_sales_settings where id = true;');
  if start_at = 0 then
    raise exception 'Could not scope menu accounting to the order tenant';
  end if;
  end_at := strpos(substr(function_source, start_at), '  if seller_organization_id is null then' || E'\n' || '    update public.menu_orders');
  if end_at = 0 then
    raise exception 'Could not scope menu accounting to the order tenant';
  end if;
  end_at := start_at + end_at - 1;
  replacement_source := substr(function_source, 1, start_at - 1)
    || '  seller_organization_id := new.organization_id;' || E'\n\n'
    || substr(function_source, end_at);
  execute replacement_source;

  function_source := pg_get_functiondef('public.post_special_event_payment_to_books()'::regprocedure);
  start_at := strpos(function_source, '  select organization_id into seller_organization_id from public.books_menu_sales_settings');
  if start_at = 0 then
    raise exception 'Could not scope event accounting to the event tenant';
  end if;
  end_at := strpos(substr(function_source, start_at), '  if seller_organization_id is null then' || E'\n' || '    update public.special_event_payments');
  if end_at = 0 then
    raise exception 'Could not scope event accounting to the event tenant';
  end if;
  end_at := start_at + end_at - 1;
  replacement_source := substr(function_source, 1, start_at - 1)
    || '  seller_organization_id := event_row.organization_id;' || E'\n'
    || substr(function_source, end_at);
  execute replacement_source;
end;
$$;

notify pgrst, 'reload schema';
commit;
