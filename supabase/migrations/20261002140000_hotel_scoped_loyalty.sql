begin;

do $$
declare missing_relations text;
begin
  select string_agg(required.name, ', ' order by required.name) into missing_relations
  from (values
    ('public.books_organizations'), ('public.books_memberships'), ('public.books_accounts'),
    ('public.books_journal_transactions'), ('public.books_journal_lines'), ('public.books_fx_rates'),
    ('public.menu_items'), ('public.menu_orders'), ('public.menu_order_items'),
    ('public.menu_payment_attempts'), ('public.hotel_rooms'), ('public.hotel_bookings'),
    ('public.hotel_payment_attempts'), ('public.special_events'), ('public.special_event_bookings'),
    ('public.special_event_payments'), ('public.special_event_payment_refunds'), ('public.tasks'), ('public.task_reports'),
    ('public.user_profiles'), ('public.notifications'), ('public.loyalty_program_settings')
  ) required(name)
  where to_regclass(required.name) is null;
  if missing_relations is not null then
    raise exception 'Hotel loyalty migration prerequisites are missing: %', missing_relations;
  end if;
end;
$$;

update public.loyalty_program_settings
   set program_enabled = false, redemption_enabled = false, updated_at = now()
 where id = true;
do $$
begin
  if to_regprocedure('public.get_my_loyalty_summary()') is not null then
    execute 'revoke all on function public.get_my_loyalty_summary() from public, anon, authenticated';
  end if;
  if to_regprocedure('public.set_my_loyalty_enrollment(boolean)') is not null then
    execute 'revoke all on function public.set_my_loyalty_enrollment(boolean) from public, anon, authenticated';
  end if;
end;
$$;

drop trigger if exists menu_order_verified_loyalty_award on public.menu_orders;
drop trigger if exists menu_payment_attempt_verified_loyalty_award on public.menu_payment_attempts;
drop trigger if exists hotel_booking_verified_loyalty_award on public.hotel_bookings;
drop trigger if exists special_event_verified_loyalty_award on public.special_event_payments;
drop trigger if exists qualify_manager_listing_referral on public.hotel_rooms;
drop trigger if exists reverse_refunded_event_loyalty on public.special_event_payments;
drop trigger if exists activate_loyalty_awards_after_configuration on public.loyalty_program_settings;
drop trigger if exists retry_loyalty_awards_after_fx_update on public.books_fx_rates;

alter table public.menu_items add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.menu_orders add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_events add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_event_bookings add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.tasks add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

with owners as (
  select user_id, (array_agg(organization_id order by organization_id::text))[1] as organization_id
  from public.books_memberships
  where role in ('owner', 'admin', 'manager')
  group by user_id
  having count(distinct organization_id) = 1
)
update public.menu_items item
   set organization_id = owners.organization_id
  from owners
 where item.organization_id is null and owners.user_id = item.managed_by;

with owners as (
  select user_id, (array_agg(organization_id order by organization_id::text))[1] as organization_id
  from public.books_memberships
  where role in ('owner', 'admin', 'manager')
  group by user_id
  having count(distinct organization_id) = 1
)
update public.special_events event
   set organization_id = owners.organization_id
  from owners
 where event.organization_id is null
   and owners.user_id in (event.organizer_id, event.created_by)
   and (select count(distinct m.organization_id) from public.books_memberships m
         where m.user_id in (event.organizer_id, event.created_by)
           and m.role in ('owner', 'admin', 'manager')) = 1;

with owners as (
  select user_id, (array_agg(organization_id order by organization_id::text))[1] as organization_id
  from public.books_memberships
  where role in ('owner', 'admin', 'manager')
  group by user_id
  having count(distinct organization_id) = 1
)
update public.tasks task
   set organization_id = owners.organization_id
  from owners
 where task.organization_id is null and owners.user_id = task.created_by;

with order_organizations as (
  select oi.order_id, (array_agg(item.organization_id order by item.organization_id::text))[1] as organization_id
  from public.menu_order_items oi
  join public.menu_items item on item.id = oi.menu_item_id
  group by oi.order_id
  having count(distinct item.organization_id) = 1
     and count(item.organization_id) = count(*)
)
update public.menu_orders orders
   set organization_id = order_organizations.organization_id
  from order_organizations
 where orders.id = order_organizations.order_id and orders.organization_id is null;

update public.special_event_bookings booking
   set organization_id = event.organization_id
  from public.special_events event
 where booking.event_id = event.id and booking.organization_id is null and event.organization_id is not null;

create index if not exists menu_items_loyalty_org_idx on public.menu_items (organization_id) where organization_id is not null;
create index if not exists menu_orders_loyalty_org_idx on public.menu_orders (organization_id, created_at desc) where organization_id is not null;
create index if not exists special_events_loyalty_org_idx on public.special_events (organization_id) where organization_id is not null;
create index if not exists tasks_loyalty_org_idx on public.tasks (organization_id, created_at desc) where organization_id is not null;

create or replace function public.hotel_loyalty_has_manager_access(target_organization_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
    where membership.organization_id = target_organization_id
      and membership.user_id = target_user_id
      and membership.role in ('owner', 'admin', 'manager')
  );
$$;
revoke all on function public.hotel_loyalty_has_manager_access(uuid, uuid) from public, anon, authenticated;

create or replace function public.attach_menu_item_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare candidate uuid; candidate_count integer;
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Menu item hotel ownership cannot be changed';
  end if;
  if new.organization_id is null then
    select (array_agg(membership.organization_id order by membership.organization_id::text))[1], count(distinct membership.organization_id)
      into candidate, candidate_count
      from public.books_memberships membership
      where membership.user_id = auth.uid()
        and membership.role in ('owner', 'admin', 'manager');
    if candidate_count = 1 then new.organization_id := candidate; end if;
  end if;
  if new.organization_id is not null and (tg_op = 'INSERT' or old.organization_id is null)
     and not public.hotel_loyalty_has_manager_access(new.organization_id, auth.uid()) then
    raise exception 'Menu item manager is not authorized for this hotel';
  end if;
  return new;
end;
$$;
revoke all on function public.attach_menu_item_hotel_organization() from public, anon, authenticated;
drop trigger if exists menu_item_hotel_organization on public.menu_items;
create trigger menu_item_hotel_organization before insert or update of organization_id, managed_by
on public.menu_items for each row execute function public.attach_menu_item_hotel_organization();

create or replace function public.attach_special_event_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare candidate uuid; candidate_count integer;
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Event hotel ownership cannot be changed';
  end if;
  if new.organization_id is null then
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
  ) then
    raise exception 'Event organizer is not authorized for this hotel';
  end if;
  return new;
end;
$$;
revoke all on function public.attach_special_event_hotel_organization() from public, anon, authenticated;
drop trigger if exists special_event_hotel_organization on public.special_events;
create trigger special_event_hotel_organization before insert or update of organization_id, organizer_id, created_by
on public.special_events for each row execute function public.attach_special_event_hotel_organization();

create or replace function public.attach_special_event_booking_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare event_organization uuid;
begin
  select organization_id into event_organization from public.special_events where id = new.event_id;
  if not found then raise exception 'Event was not found'; end if;
  if new.organization_id is not null and new.organization_id is distinct from event_organization then
    raise exception 'Booking hotel must match its event';
  end if;
  new.organization_id := event_organization;
  return new;
end;
$$;
revoke all on function public.attach_special_event_booking_hotel_organization() from public, anon, authenticated;
drop trigger if exists special_event_booking_hotel_organization on public.special_event_bookings;
create trigger special_event_booking_hotel_organization before insert or update of organization_id, event_id
on public.special_event_bookings for each row execute function public.attach_special_event_booking_hotel_organization();

create or replace function public.attach_task_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare candidate uuid; candidate_count integer;
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Task hotel ownership cannot be changed';
  end if;
  if new.organization_id is null then
    select (array_agg(membership.organization_id order by membership.organization_id::text))[1], count(distinct membership.organization_id)
      into candidate, candidate_count
      from public.books_memberships membership
      where membership.user_id = auth.uid()
        and membership.role in ('owner', 'admin', 'manager');
    if candidate_count = 1 then new.organization_id := candidate; end if;
  end if;
  if new.organization_id is not null and not public.hotel_loyalty_has_manager_access(new.organization_id, auth.uid()) then
    raise exception 'Task creator is not authorized for this hotel';
  end if;
  return new;
end;
$$;
revoke all on function public.attach_task_hotel_organization() from public, anon, authenticated;
drop trigger if exists task_hotel_organization on public.tasks;
create trigger task_hotel_organization before insert or update of organization_id, created_by
on public.tasks for each row execute function public.attach_task_hotel_organization();

create or replace function public.attach_menu_order_hotel_organization()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare item_organization uuid; order_organization uuid;
begin
  select organization_id into item_organization from public.menu_items where id = new.menu_item_id;
  if not found then raise exception 'Menu item was not found'; end if;
  select organization_id into order_organization from public.menu_orders where id = new.order_id for update;
  if not found then raise exception 'Menu order was not found'; end if;
  if item_organization is null then
    if order_organization is not null then raise exception 'A hotel order cannot contain an item without hotel ownership'; end if;
    return new;
  end if;
  if order_organization is not null and order_organization <> item_organization then
    raise exception 'A menu order cannot contain items from different hotels';
  end if;
  if exists (
    select 1 from public.menu_order_items existing_line
    join public.menu_items existing_item on existing_item.id = existing_line.menu_item_id
    where existing_line.order_id = new.order_id and existing_item.organization_id is distinct from item_organization
  ) then raise exception 'A menu order cannot contain items from different hotels'; end if;
  update public.menu_orders set organization_id = item_organization where id = new.order_id;
  return new;
end;
$$;
revoke all on function public.attach_menu_order_hotel_organization() from public, anon, authenticated;
drop trigger if exists menu_order_hotel_organization on public.menu_order_items;
create trigger menu_order_hotel_organization before insert or update of order_id, menu_item_id
on public.menu_order_items for each row execute function public.attach_menu_order_hotel_organization();

create table if not exists public.hotel_loyalty_programs (
  organization_id uuid primary key references public.books_organizations(id) on delete restrict,
  program_name text not null default 'Hotel Rewards',
  points_per_1000_ugx integer not null default 1 check (points_per_1000_ugx > 0),
  guest_referral_minimum_ugx numeric(20,4) not null default 100000 check (guest_referral_minimum_ugx > 0 and guest_referral_minimum_ugx::text not in ('NaN', 'Infinity', '-Infinity')),
  referrer_bonus_points integer not null default 250 check (referrer_bonus_points > 0),
  invitee_bonus_points integer not null default 250 check (invitee_bonus_points > 0),
  task_approval_points integer not null default 50 check (task_approval_points > 0),
  monthly_task_points_cap integer not null default 500 check (monthly_task_points_cap > 0),
  ugx_value_per_point numeric(20,4) not null default 10 check (ugx_value_per_point > 0 and ugx_value_per_point::text not in ('NaN', 'Infinity', '-Infinity')),
  books_expense_account_code text,
  books_liability_account_code text,
  program_enabled boolean not null default false,
  redemption_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.hotel_loyalty_accounts (
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  referral_code text not null,
  is_enrolled boolean not null default false,
  enrolled_at timestamptz,
  available_points bigint not null default 0 check (available_points >= 0),
  debt_points bigint not null default 0 check (debt_points >= 0),
  lifetime_points_earned bigint not null default 0 check (lifetime_points_earned >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id),
  unique (organization_id, referral_code),
  check (referral_code = upper(referral_code))
);

create table if not exists public.hotel_loyalty_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  entry_type text not null check (entry_type in ('purchase_earn', 'referral_earn', 'referral_welcome', 'task_earn', 'purchase_reversal', 'referral_reversal')),
  points_delta bigint not null check (points_delta <> 0),
  source_type text not null,
  source_id uuid not null,
  description text not null,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id, source_type, source_id, entry_type)
);

create table if not exists public.hotel_loyalty_referrals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  referrer_user_id uuid not null references auth.users(id) on delete restrict,
  referred_user_id uuid not null references auth.users(id) on delete restrict,
  referral_code text not null,
  status text not null default 'pending' check (status in ('pending', 'qualified', 'cancelled')),
  qualification_type text,
  qualification_source_type text,
  qualification_source_id uuid,
  referrer_points integer not null default 0,
  invitee_points integer not null default 0,
  created_at timestamptz not null default now(),
  qualified_at timestamptz,
  unique (organization_id, referred_user_id),
  check (referrer_user_id <> referred_user_id)
);

create table if not exists public.hotel_loyalty_award_queue (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  source_type text not null check (source_type in ('menu_order', 'hotel_booking', 'special_event_payment', 'approved_task')),
  source_id uuid not null,
  eligible_amount numeric(20,4) not null check (eligible_amount >= 0 and eligible_amount::text not in ('NaN', 'Infinity', '-Infinity')),
  eligible_currency text not null check (char_length(trim(eligible_currency)) = 3),
  source_created_at timestamptz not null default now(),
  eligible_amount_ugx numeric(20,4),
  points_awarded bigint not null default 0,
  status text not null default 'pending_fx' check (status in ('pending_fx', 'posted', 'excluded', 'failed', 'refunded', 'reversed')),
  error_message text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (organization_id, source_type, source_id)
);

create table if not exists public.hotel_loyalty_books_postings (
  ledger_entry_id uuid primary key references public.hotel_loyalty_ledger_entries(id) on delete restrict,
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  amount_ugx numeric(20,4) not null check (amount_ugx > 0 and amount_ugx::text not in ('NaN', 'Infinity', '-Infinity')),
  status text not null default 'pending' check (status in ('pending', 'posted', 'failed')),
  journal_transaction_id uuid references public.books_journal_transactions(id) on delete restrict,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists hotel_loyalty_referral_code_global_uidx on public.hotel_loyalty_accounts (referral_code);
create index if not exists hotel_loyalty_accounts_user_idx on public.hotel_loyalty_accounts (user_id, organization_id);
create index if not exists hotel_loyalty_ledger_recent_idx on public.hotel_loyalty_ledger_entries (organization_id, user_id, created_at desc);
create index if not exists hotel_loyalty_queue_pending_idx on public.hotel_loyalty_award_queue (created_at) where status in ('pending_fx', 'failed');

alter table public.hotel_loyalty_programs enable row level security;
alter table public.hotel_loyalty_accounts enable row level security;
alter table public.hotel_loyalty_ledger_entries enable row level security;
alter table public.hotel_loyalty_referrals enable row level security;
alter table public.hotel_loyalty_award_queue enable row level security;
alter table public.hotel_loyalty_books_postings enable row level security;
revoke all on public.hotel_loyalty_programs, public.hotel_loyalty_accounts, public.hotel_loyalty_ledger_entries,
  public.hotel_loyalty_referrals, public.hotel_loyalty_award_queue, public.hotel_loyalty_books_postings
  from public, anon, authenticated;
grant select on public.hotel_loyalty_accounts, public.hotel_loyalty_ledger_entries, public.hotel_loyalty_referrals,
  public.hotel_loyalty_books_postings to authenticated;
drop policy if exists hotel_loyalty_accounts_owner_read on public.hotel_loyalty_accounts;
create policy hotel_loyalty_accounts_owner_read on public.hotel_loyalty_accounts for select to authenticated using (user_id = auth.uid());
drop policy if exists hotel_loyalty_ledger_owner_read on public.hotel_loyalty_ledger_entries;
create policy hotel_loyalty_ledger_owner_read on public.hotel_loyalty_ledger_entries for select to authenticated using (user_id = auth.uid());
drop policy if exists hotel_loyalty_referrals_owner_read on public.hotel_loyalty_referrals;
create policy hotel_loyalty_referrals_owner_read on public.hotel_loyalty_referrals for select to authenticated using (referrer_user_id = auth.uid() or referred_user_id = auth.uid());
drop policy if exists hotel_loyalty_books_member_read on public.hotel_loyalty_books_postings;
create policy hotel_loyalty_books_member_read on public.hotel_loyalty_books_postings for select to authenticated using (exists (select 1 from public.books_memberships membership where membership.organization_id = hotel_loyalty_books_postings.organization_id and membership.user_id = auth.uid()));

create or replace function public.hotel_loyalty_make_account(target_organization_id uuid, target_user_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare generated_code text;
begin
  if target_user_id is null then raise exception 'A member is required'; end if;
  if exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = target_user_id) then return; end if;
  loop
    generated_code := 'HT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    insert into public.hotel_loyalty_accounts (organization_id, user_id, referral_code)
    values (target_organization_id, target_user_id, generated_code)
    on conflict do nothing;
    if exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = target_user_id) then exit; end if;
  end loop;
end;
$$;
revoke all on function public.hotel_loyalty_make_account(uuid, uuid) from public, anon, authenticated;

create or replace function public.configure_hotel_loyalty_program(
  target_organization_id uuid,
  target_program_name text,
  target_points_per_1000_ugx integer,
  target_guest_referral_minimum_ugx numeric,
  target_referrer_bonus_points integer,
  target_invitee_bonus_points integer,
  target_task_approval_points integer,
  target_monthly_task_points_cap integer,
  target_ugx_value_per_point numeric,
  target_expense_account_code text,
  target_liability_account_code text,
  target_enable boolean default false
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare expense_type text; liability_type text;
begin
  if auth.uid() is null or not public.hotel_loyalty_has_manager_access(target_organization_id) then
    raise exception 'Only this hotel''s finance manager can configure rewards';
  end if;
  if target_points_per_1000_ugx <= 0 or target_guest_referral_minimum_ugx <= 0
     or target_referrer_bonus_points <= 0 or target_invitee_bonus_points <= 0
     or target_task_approval_points <= 0 or target_monthly_task_points_cap <= 0
     or target_ugx_value_per_point <= 0
     or target_guest_referral_minimum_ugx::text in ('NaN', 'Infinity', '-Infinity')
     or target_ugx_value_per_point::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'Rewards values must be finite and positive';
  end if;
  if target_enable then
    if nullif(trim(target_expense_account_code), '') is null or nullif(trim(target_liability_account_code), '') is null
       or trim(target_expense_account_code) = trim(target_liability_account_code) then
      raise exception 'Distinct expense and liability Books account codes are required before activation';
    end if;
    select type into expense_type from public.books_accounts where organization_id = target_organization_id and code = trim(target_expense_account_code);
    select type into liability_type from public.books_accounts where organization_id = target_organization_id and code = trim(target_liability_account_code);
    if expense_type is distinct from 'expense' or liability_type is distinct from 'liability' then raise exception 'Books account types do not match the rewards posting requirements'; end if;
    if (select base_currency from public.books_organizations where id = target_organization_id) <> 'UGX' then
      raise exception 'Hotel loyalty Books organization must use UGX';
    end if;
  end if;
  insert into public.hotel_loyalty_programs (
    organization_id, program_name, points_per_1000_ugx, guest_referral_minimum_ugx,
    referrer_bonus_points, invitee_bonus_points, task_approval_points, monthly_task_points_cap,
    ugx_value_per_point, books_expense_account_code, books_liability_account_code, program_enabled, redemption_enabled, updated_at
  ) values (
    target_organization_id, coalesce(nullif(trim(target_program_name), ''), 'Hotel Rewards'),
    target_points_per_1000_ugx, target_guest_referral_minimum_ugx, target_referrer_bonus_points,
    target_invitee_bonus_points, target_task_approval_points, target_monthly_task_points_cap,
    target_ugx_value_per_point, nullif(trim(target_expense_account_code), ''),
    nullif(trim(target_liability_account_code), ''), target_enable, false, now()
  ) on conflict (organization_id) do update set
    program_name = excluded.program_name, points_per_1000_ugx = excluded.points_per_1000_ugx,
    guest_referral_minimum_ugx = excluded.guest_referral_minimum_ugx,
    referrer_bonus_points = excluded.referrer_bonus_points, invitee_bonus_points = excluded.invitee_bonus_points,
    task_approval_points = excluded.task_approval_points, monthly_task_points_cap = excluded.monthly_task_points_cap,
    ugx_value_per_point = excluded.ugx_value_per_point,
    books_expense_account_code = excluded.books_expense_account_code,
    books_liability_account_code = excluded.books_liability_account_code,
    program_enabled = excluded.program_enabled, redemption_enabled = false, updated_at = now();
end;
$$;
revoke all on function public.configure_hotel_loyalty_program(uuid, text, integer, numeric, integer, integer, integer, integer, numeric, text, text, boolean) from public, anon;
grant execute on function public.configure_hotel_loyalty_program(uuid, text, integer, numeric, integer, integer, integer, integer, numeric, text, text, boolean) to authenticated;

create or replace function public.set_my_hotel_loyalty_enrollment(target_organization_id uuid, target_enrolled boolean)
returns boolean language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in to manage rewards enrollment'; end if;
  if target_enrolled and not exists (select 1 from public.hotel_loyalty_programs where organization_id = target_organization_id and program_enabled) then
    raise exception 'This hotel rewards program is not active';
  end if;
  perform public.hotel_loyalty_make_account(target_organization_id, auth.uid());
  update public.hotel_loyalty_accounts set is_enrolled = target_enrolled,
    enrolled_at = case when target_enrolled and not is_enrolled then now() when not target_enrolled then null else enrolled_at end,
    updated_at = now()
  where organization_id = target_organization_id and user_id = auth.uid();
  return target_enrolled;
end;
$$;
revoke all on function public.set_my_hotel_loyalty_enrollment(uuid, boolean) from public, anon;
grant execute on function public.set_my_hotel_loyalty_enrollment(uuid, boolean) to authenticated;

create or replace function public.get_my_hotel_loyalty_programs()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public
as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to view hotel rewards'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'organizationId', program.organization_id, 'organizationName', organization.name,
    'programName', program.program_name, 'availablePoints', coalesce(account.available_points, 0),
    'lifetimePoints', coalesce(account.lifetime_points_earned, 0), 'debtPoints', coalesce(account.debt_points, 0),
    'enrolled', coalesce(account.is_enrolled, false), 'referralCode', account.referral_code,
    'programEnabled', program.program_enabled, 'redemptionEnabled', false,
    'referrals', jsonb_build_object(
      'total', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = auth.uid()),
      'qualified', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = auth.uid() and referral.status = 'qualified'),
      'pending', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = auth.uid() and referral.status = 'pending'),
      'pointsEarned', coalesce((select sum(points_delta) from public.hotel_loyalty_ledger_entries where organization_id = program.organization_id and user_id = auth.uid() and entry_type = 'referral_earn'), 0)
    ),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', recent.id, 'entryType', recent.entry_type, 'pointsDelta', recent.points_delta, 'description', recent.description, 'createdAt', recent.created_at) order by recent.created_at desc) from (select id, entry_type, points_delta, description, created_at from public.hotel_loyalty_ledger_entries where organization_id = program.organization_id and user_id = auth.uid() order by created_at desc limit 30) recent), '[]'::jsonb),
    'policy', jsonb_build_object('pointsPer1000Ugx', program.points_per_1000_ugx, 'guestReferralMinimumUgx', program.guest_referral_minimum_ugx, 'referrerBonusPoints', program.referrer_bonus_points, 'inviteeBonusPoints', program.invitee_bonus_points, 'taskApprovalPoints', program.task_approval_points, 'monthlyTaskPointsCap', program.monthly_task_points_cap, 'ugxValuePerPoint', program.ugx_value_per_point, 'programEnabled', program.program_enabled, 'redemptionEnabled', false, 'pointsExpire', false)
  ) order by organization.name), '[]'::jsonb) into result
  from public.hotel_loyalty_programs program
  join public.books_organizations organization on organization.id = program.organization_id
  left join public.hotel_loyalty_accounts account on account.organization_id = program.organization_id and account.user_id = auth.uid()
  where program.program_enabled or account.user_id is not null;
  return result;
end;
$$;
revoke all on function public.get_my_hotel_loyalty_programs() from public, anon;
grant execute on function public.get_my_hotel_loyalty_programs() to authenticated;

create or replace function public.post_hotel_loyalty_ledger_entry(target_entry_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  entry_row public.hotel_loyalty_ledger_entries%rowtype;
  program_row public.hotel_loyalty_programs%rowtype;
  owner_uuid uuid;
  debit_account uuid;
  credit_account uuid;
  journal_uuid uuid;
  posting_amount numeric(20,4);
  debit_code text;
  credit_code text;
begin
  select * into entry_row from public.hotel_loyalty_ledger_entries where id = target_entry_id;
  if not found then raise exception 'Hotel loyalty ledger entry not found'; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = entry_row.organization_id for update;
  if not found then raise exception 'Hotel loyalty program configuration is missing'; end if;
  select owner_id into owner_uuid from public.books_organizations where id = entry_row.organization_id and base_currency = 'UGX';
  if owner_uuid is null then raise exception 'Hotel Books organization must exist and use UGX'; end if;
  posting_amount := abs(entry_row.points_delta) * program_row.ugx_value_per_point;
  debit_code := case when entry_row.points_delta > 0 then program_row.books_expense_account_code else program_row.books_liability_account_code end;
  credit_code := case when entry_row.points_delta > 0 then program_row.books_liability_account_code else program_row.books_expense_account_code end;
  select id into debit_account from public.books_accounts where organization_id = entry_row.organization_id and code = debit_code and type = case when entry_row.points_delta > 0 then 'expense' else 'liability' end;
  select id into credit_account from public.books_accounts where organization_id = entry_row.organization_id and code = credit_code and type = case when entry_row.points_delta > 0 then 'liability' else 'expense' end;
  if debit_account is null or credit_account is null then raise exception 'Hotel loyalty Books accounts are missing or have invalid types'; end if;
  insert into public.hotel_loyalty_books_postings (ledger_entry_id, organization_id, amount_ugx, status)
  values (entry_row.id, entry_row.organization_id, posting_amount, 'pending') on conflict (ledger_entry_id) do nothing;
  select id into journal_uuid from public.books_journal_transactions
   where organization_id = entry_row.organization_id and source_type = 'hotel_loyalty_points' and source_id = entry_row.id;
  if journal_uuid is null then
    insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
    values (entry_row.organization_id, 'hotel_loyalty_points', entry_row.id, entry_row.created_at::date, entry_row.description, owner_uuid)
    on conflict (organization_id, source_type, source_id) where source_id is not null do nothing
    returning id into journal_uuid;
    if journal_uuid is not null then
      insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
      values (journal_uuid, debit_account, posting_amount, 0, 'UGX', 1), (journal_uuid, credit_account, 0, posting_amount, 'UGX', 1);
    else
      select id into journal_uuid from public.books_journal_transactions
       where organization_id = entry_row.organization_id and source_type = 'hotel_loyalty_points' and source_id = entry_row.id;
    end if;
  end if;
  update public.hotel_loyalty_books_postings set status = 'posted', journal_transaction_id = journal_uuid, error_message = null, updated_at = now()
  where ledger_entry_id = entry_row.id;
end;
$$;
revoke all on function public.post_hotel_loyalty_ledger_entry(uuid) from public, anon, authenticated;

create or replace function public.apply_hotel_loyalty_delta(
  target_organization_id uuid, target_user_id uuid, target_entry_type text, target_points_delta bigint,
  target_source_type text, target_source_id uuid, target_description text
)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  account_row public.hotel_loyalty_accounts%rowtype;
  entry_uuid uuid;
  applied_positive bigint;
  applied_negative bigint;
begin
  if target_points_delta = 0 or target_source_id is null then raise exception 'A valid hotel loyalty entry is required'; end if;
  select * into account_row from public.hotel_loyalty_accounts
   where organization_id = target_organization_id and user_id = target_user_id for update;
  if not found then
    perform public.hotel_loyalty_make_account(target_organization_id, target_user_id);
    select * into account_row from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = target_user_id for update;
  end if;
  if target_points_delta > 0 and not account_row.is_enrolled then return null; end if;
  insert into public.hotel_loyalty_ledger_entries (organization_id, user_id, entry_type, points_delta, source_type, source_id, description)
  values (target_organization_id, target_user_id, target_entry_type, target_points_delta, target_source_type, target_source_id, target_description)
  on conflict (organization_id, user_id, source_type, source_id, entry_type) do nothing returning id into entry_uuid;
  if entry_uuid is null then return null; end if;
  if target_points_delta > 0 then
    applied_negative := least(account_row.debt_points, target_points_delta);
    applied_positive := target_points_delta - applied_negative;
    update public.hotel_loyalty_accounts set available_points = available_points + applied_positive,
      debt_points = debt_points - applied_negative, lifetime_points_earned = lifetime_points_earned + target_points_delta, updated_at = now()
    where organization_id = target_organization_id and user_id = target_user_id;
  else
    applied_positive := least(account_row.available_points, abs(target_points_delta));
    applied_negative := abs(target_points_delta) - applied_positive;
    update public.hotel_loyalty_accounts set available_points = available_points - applied_positive,
      debt_points = debt_points + applied_negative, updated_at = now()
    where organization_id = target_organization_id and user_id = target_user_id;
  end if;
  perform public.post_hotel_loyalty_ledger_entry(entry_uuid);
  return entry_uuid;
end;
$$;
revoke all on function public.apply_hotel_loyalty_delta(uuid, uuid, text, bigint, text, uuid, text) from public, anon, authenticated;

create or replace function public.process_hotel_loyalty_award(target_queue_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  queue_row public.hotel_loyalty_award_queue%rowtype;
  program_row public.hotel_loyalty_programs%rowtype;
  exchange_rate numeric;
  ugx_amount numeric(20,4);
  points bigint;
begin
  select * into queue_row from public.hotel_loyalty_award_queue where id = target_queue_id for update;
  if not found or queue_row.status not in ('pending_fx', 'failed') then return; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = queue_row.organization_id;
  if not found or not program_row.program_enabled then return; end if;
  if not exists (select 1 from public.hotel_loyalty_accounts where organization_id = queue_row.organization_id and user_id = queue_row.user_id and is_enrolled and enrolled_at <= queue_row.source_created_at) then
    update public.hotel_loyalty_award_queue set status = 'excluded', error_message = 'Member was not enrolled when the purchase occurred', processed_at = now() where id = target_queue_id;
    return;
  end if;
  if upper(queue_row.eligible_currency) = 'UGX' then exchange_rate := 1;
  else
    select rate into exchange_rate from public.books_fx_rates
    where base_currency = 'UGX' and quote_currency = upper(queue_row.eligible_currency)::char(3)
      and stored_at >= now() - interval '36 hours' order by stored_at desc limit 1;
  end if;
  if exchange_rate is null or exchange_rate <= 0 then
    update public.hotel_loyalty_award_queue set status = 'pending_fx', error_message = 'Awaiting a current UGX exchange rate' where id = target_queue_id;
    return;
  end if;
  ugx_amount := round(queue_row.eligible_amount / exchange_rate, 4);
  points := floor(ugx_amount / 1000) * program_row.points_per_1000_ugx;
  update public.hotel_loyalty_award_queue set eligible_amount_ugx = ugx_amount, points_awarded = points where id = target_queue_id;
  if points < 1 then
    update public.hotel_loyalty_award_queue set status = 'excluded', processed_at = now(), error_message = null where id = target_queue_id;
    return;
  end if;
  perform public.apply_hotel_loyalty_delta(queue_row.organization_id, queue_row.user_id, 'purchase_earn', points,
    queue_row.source_type, queue_row.source_id, 'Eligible verified hotel purchase reward');
  update public.hotel_loyalty_award_queue set status = 'posted', processed_at = now(), error_message = null where id = target_queue_id;
  perform public.qualify_hotel_loyalty_referral(queue_row.organization_id, queue_row.user_id, 'purchase', queue_row.source_type, queue_row.source_id, ugx_amount);
exception when others then
  update public.hotel_loyalty_award_queue set status = 'failed', error_message = left(sqlerrm, 1000), processed_at = now() where id = target_queue_id;
end;
$$;
revoke all on function public.process_hotel_loyalty_award(uuid) from public, anon, authenticated;

create or replace function public.retry_hotel_loyalty_awards_after_fx()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if auth.role() = 'service_role' then perform public.process_hotel_loyalty_awards(); end if;
  return new;
end;
$$;
revoke all on function public.retry_hotel_loyalty_awards_after_fx() from public, anon, authenticated;
drop trigger if exists retry_hotel_loyalty_awards_after_fx on public.books_fx_rates;
create trigger retry_hotel_loyalty_awards_after_fx after insert or update on public.books_fx_rates
for each row execute function public.retry_hotel_loyalty_awards_after_fx();

create or replace function public.qualify_hotel_manager_listing_referral()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published')
     and new.organization_id is not null then
    perform public.qualify_hotel_loyalty_referral(new.organization_id, new.created_by, 'manager_listing', 'hotel_room', new.id, null);
  end if;
  return new;
end;
$$;
revoke all on function public.qualify_hotel_manager_listing_referral() from public, anon, authenticated;
drop trigger if exists qualify_hotel_manager_listing_referral on public.hotel_rooms;
create trigger qualify_hotel_manager_listing_referral after insert or update of status on public.hotel_rooms
for each row execute function public.qualify_hotel_manager_listing_referral();

create or replace function public.process_hotel_loyalty_awards()
returns integer language plpgsql security definer set search_path = pg_catalog, public
as $$
declare queue_row record; processed integer := 0;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the service role may process hotel loyalty awards'; end if;
  for queue_row in select id from public.hotel_loyalty_award_queue where status in ('pending_fx', 'failed') order by created_at for update skip locked loop
    perform public.process_hotel_loyalty_award(queue_row.id);
    processed := processed + 1;
  end loop;
  return processed;
end;
$$;
revoke all on function public.process_hotel_loyalty_awards() from public, anon, authenticated;
grant execute on function public.process_hotel_loyalty_awards() to service_role;

create or replace function public.enqueue_hotel_loyalty_purchase()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  tenant_id uuid;
  member_id uuid;
  source_id uuid;
  amount_value numeric;
  currency_value text;
  source_created_at_value timestamptz;
  confirmed boolean := false;
  booking public.special_event_bookings%rowtype;
  menu_order public.menu_orders%rowtype;
  hotel_booking public.hotel_bookings%rowtype;
begin
  if tg_table_name = 'menu_payment_attempts' then
    if new.status <> 'completed' or new.transaction_id is null then return new; end if;
    select * into menu_order from public.menu_orders where id = new.order_id;
    if not found or menu_order.payment_status <> 'paid' or menu_order.flutterwave_transaction_id is distinct from new.transaction_id or menu_order.organization_id is null then return new; end if;
    tenant_id := menu_order.organization_id; member_id := menu_order.user_id; source_id := menu_order.id;
    amount_value := greatest(menu_order.subtotal, 0); currency_value := menu_order.currency; source_created_at_value := menu_order.created_at;
  elsif tg_table_name = 'hotel_payment_attempts' then
    if new.status <> 'completed' or new.transaction_id is null then return new; end if;
    select * into hotel_booking from public.hotel_bookings where id = new.booking_id;
    if not found or hotel_booking.payment_status <> 'paid' or hotel_booking.user_id is null then return new; end if;
    tenant_id := hotel_booking.organization_id; member_id := hotel_booking.user_id; source_id := hotel_booking.id;
    amount_value := greatest(hotel_booking.taxable_subtotal, 0); currency_value := trim(hotel_booking.currency_code); source_created_at_value := hotel_booking.created_at;
  elsif tg_table_name = 'menu_orders' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') then return new; end if;
    if new.organization_id is null or new.payment_method not in ('card', 'mobile-money') or new.flutterwave_transaction_id is null then return new; end if;
    select exists (select 1 from public.menu_payment_attempts attempt where attempt.order_id = new.id and attempt.status = 'completed' and attempt.transaction_id = new.flutterwave_transaction_id) into confirmed;
    if not confirmed then return new; end if;
    tenant_id := new.organization_id; member_id := new.user_id; source_id := new.id;
    amount_value := greatest(coalesce(new.subtotal, 0), 0); currency_value := new.currency; source_created_at_value := new.created_at;
  elsif tg_table_name = 'hotel_bookings' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') or new.user_id is null then return new; end if;
    select exists (select 1 from public.hotel_payment_attempts attempt where attempt.booking_id = new.id and attempt.status = 'completed' and attempt.transaction_id is not null) into confirmed;
    if not confirmed then return new; end if;
    tenant_id := new.organization_id; member_id := new.user_id; source_id := new.id;
    amount_value := greatest(new.taxable_subtotal, 0); currency_value := trim(new.currency_code); source_created_at_value := new.created_at;
  elsif tg_table_name = 'special_event_payments' then
    if new.status <> 'successful' or (tg_op = 'UPDATE' and old.status = 'successful') then return new; end if;
    select * into booking from public.special_event_bookings where id = new.booking_id;
    if not found or booking.user_id is null or booking.organization_id is null then return new; end if;
    tenant_id := booking.organization_id; member_id := booking.user_id; source_id := new.id;
    amount_value := greatest(coalesce(booking.subtotal, 0) - coalesce(booking.discount_amount, 0), 0); currency_value := new.currency; source_created_at_value := booking.created_at;
  else return new;
  end if;
  if not exists (select 1 from public.hotel_loyalty_programs where organization_id = tenant_id and program_enabled) then return new; end if;
  insert into public.hotel_loyalty_award_queue (organization_id, user_id, source_type, source_id, eligible_amount, eligible_currency, source_created_at)
  values (tenant_id, member_id, case when tg_table_name = 'special_event_payments' then 'special_event_payment' else case when tg_table_name = 'hotel_bookings' then 'hotel_booking' else 'menu_order' end end,
    source_id, amount_value, upper(currency_value), source_created_at_value) on conflict (organization_id, source_type, source_id) do nothing;
  if auth.role() = 'service_role' then perform public.process_hotel_loyalty_awards(); end if;
  return new;
end;
$$;
revoke all on function public.enqueue_hotel_loyalty_purchase() from public, anon, authenticated;
drop trigger if exists menu_order_hotel_loyalty_award on public.menu_orders;
create trigger menu_order_hotel_loyalty_award after insert or update of payment_status on public.menu_orders for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists menu_payment_attempt_hotel_loyalty_award on public.menu_payment_attempts;
create trigger menu_payment_attempt_hotel_loyalty_award after insert or update of status on public.menu_payment_attempts for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists hotel_booking_hotel_loyalty_award on public.hotel_bookings;
create trigger hotel_booking_hotel_loyalty_award after insert or update of payment_status on public.hotel_bookings for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists hotel_payment_attempt_hotel_loyalty_award on public.hotel_payment_attempts;
create trigger hotel_payment_attempt_hotel_loyalty_award after insert or update of status on public.hotel_payment_attempts for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists special_event_hotel_loyalty_award on public.special_event_payments;
create trigger special_event_hotel_loyalty_award after insert or update of status on public.special_event_payments for each row execute function public.enqueue_hotel_loyalty_purchase();

create or replace function public.qualify_hotel_loyalty_referral(
  target_organization_id uuid, target_user_id uuid, target_qualification_type text,
  target_source_type text, target_source_id uuid, target_purchase_ugx numeric default null
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare referral_row public.hotel_loyalty_referrals%rowtype; program_row public.hotel_loyalty_programs%rowtype;
begin
  select * into program_row from public.hotel_loyalty_programs where organization_id = target_organization_id and program_enabled;
  if not found then return; end if;
  if target_qualification_type = 'purchase' then
    if target_purchase_ugx < program_row.guest_referral_minimum_ugx
       or not exists (select 1 from public.user_profiles where user_id = target_user_id and role = 'guest') then return; end if;
    if exists (
      select 1 from public.hotel_loyalty_award_queue prior
      where prior.organization_id = target_organization_id and prior.user_id = target_user_id
        and (prior.source_created_at, prior.id) < (
          select current.source_created_at, current.id from public.hotel_loyalty_award_queue current
          where current.organization_id = target_organization_id and current.source_type = target_source_type and current.source_id = target_source_id
        )
    ) then return; end if;
  elsif target_qualification_type = 'task' then
    if not exists (
      select 1 from public.task_reports report join public.tasks task on task.id = report.task_id
      join public.user_profiles provider on provider.id = report.provider_id
      where report.task_id = target_source_id and report.status = 'approved' and task.status = 'completed'
        and task.organization_id = target_organization_id and provider.user_id = target_user_id
    ) or exists (
      select 1 from public.task_reports prior_report join public.tasks prior_task on prior_task.id = prior_report.task_id
      join public.user_profiles provider on provider.id = prior_report.provider_id
      where prior_report.status = 'approved' and prior_task.status = 'completed'
        and prior_task.organization_id = target_organization_id and provider.user_id = target_user_id
        and prior_task.id <> target_source_id
    ) then return; end if;
  elsif target_qualification_type = 'manager_listing' then
    if not exists (select 1 from public.hotel_rooms room where room.id = target_source_id
      and room.organization_id = target_organization_id and room.status = 'published' and room.created_by = target_user_id)
       or exists (select 1 from public.hotel_rooms prior_room where prior_room.organization_id = target_organization_id
        and prior_room.created_by = target_user_id and prior_room.status = 'published' and prior_room.id <> target_source_id) then return; end if;
  else return;
  end if;
  select * into referral_row from public.hotel_loyalty_referrals
   where organization_id = target_organization_id and referred_user_id = target_user_id and status = 'pending' for update;
  if not found
     or not exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = referral_row.referrer_user_id and is_enrolled)
     or not exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = target_user_id and is_enrolled) then return; end if;
  update public.hotel_loyalty_referrals set status = 'qualified', qualification_type = target_qualification_type,
    qualification_source_type = target_source_type, qualification_source_id = target_source_id,
    referrer_points = program_row.referrer_bonus_points, invitee_points = program_row.invitee_bonus_points,
    qualified_at = now() where id = referral_row.id;
  perform public.apply_hotel_loyalty_delta(target_organization_id, referral_row.referrer_user_id, 'referral_earn',
    program_row.referrer_bonus_points, 'hotel_referral', referral_row.id, 'Qualified hotel referral reward');
  perform public.apply_hotel_loyalty_delta(target_organization_id, target_user_id, 'referral_welcome',
    program_row.invitee_bonus_points, 'hotel_referral', referral_row.id, 'Hotel referral welcome reward');
end;
$$;
revoke all on function public.qualify_hotel_loyalty_referral(uuid, uuid, text, text, uuid, numeric) from public, anon, authenticated;

create or replace function public.initialize_hotel_loyalty_referral()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare tenant_id uuid; supplied_code text; inviter uuid;
begin
  supplied_code := nullif(upper(trim(new.raw_user_meta_data->>'referral_code')), '');
  if supplied_code is null then return new; end if;
  select account.organization_id, account.user_id into tenant_id, inviter
  from public.hotel_loyalty_accounts account
  join public.hotel_loyalty_programs program on program.organization_id = account.organization_id and program.program_enabled
  where account.referral_code = supplied_code
    and (new.raw_user_meta_data->>'loyalty_organization_id' is null
      or account.organization_id::text = new.raw_user_meta_data->>'loyalty_organization_id')
  order by account.organization_id limit 1;
  if tenant_id is null or inviter = new.id then return new; end if;
  perform public.hotel_loyalty_make_account(tenant_id, new.id);
  insert into public.hotel_loyalty_referrals (organization_id, referrer_user_id, referred_user_id, referral_code)
  values (tenant_id, inviter, new.id, supplied_code)
  on conflict (organization_id, referred_user_id) do nothing;
  return new;
end;
$$;
revoke all on function public.initialize_hotel_loyalty_referral() from public, anon, authenticated;
drop trigger if exists initialize_loyalty_account_after_signup on auth.users;
drop trigger if exists initialize_hotel_loyalty_referral_after_signup on auth.users;
create trigger initialize_hotel_loyalty_referral_after_signup after insert on auth.users
for each row execute function public.initialize_hotel_loyalty_referral();

create or replace function public.submit_task_report_for_approval(target_report_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare report_row public.task_reports%rowtype; provider_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to submit work for approval'; end if;
  select id into provider_profile_id from public.user_profiles where user_id = auth.uid() and role = 'service_provider';
  if provider_profile_id is null then raise exception 'Only the assigned service provider can submit this report'; end if;
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found or report_row.provider_id <> provider_profile_id then raise exception 'Task report was not found'; end if;
  if report_row.status <> 'in_progress' or report_row.percentage_complete < 100 then raise exception 'Complete the report before requesting approval'; end if;
  update public.task_reports set status = 'completed_pending_approval', last_updated_by = auth.uid(), updated_at = now() where id = target_report_id;
end;
$$;
revoke all on function public.submit_task_report_for_approval(uuid) from public, anon;
grant execute on function public.submit_task_report_for_approval(uuid) to authenticated;

revoke insert, update, delete on public.task_reports from public, anon, authenticated;
grant select on public.task_reports to authenticated;
grant insert (task_id, provider_id, description, percentage_complete, last_updated_by) on public.task_reports to authenticated;
grant update (description, percentage_complete, last_updated_by, updated_at) on public.task_reports to authenticated;
drop policy if exists task_reports_insert on public.task_reports;
create policy task_reports_insert on public.task_reports for insert to authenticated with check (
  provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider') and status = 'in_progress'
);
drop policy if exists task_reports_update on public.task_reports;
create policy task_reports_update on public.task_reports for update to authenticated
using (status <> 'approved' and provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider'))
with check (provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider'));

create or replace function public.approve_task_report_and_award_points(target_report_id uuid)
returns integer language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype; task_row public.tasks%rowtype;
  provider_user_id uuid; actor_role text; points_this_month bigint; reward_points integer;
  program_row public.hotel_loyalty_programs%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  select role into actor_role from public.user_profiles where user_id = auth.uid();
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id = report_row.task_id for update;
  if not found or task_row.created_by <> auth.uid() or actor_role <> 'manager' then raise exception 'Only the task manager can approve this report'; end if;
  if task_row.assigned_to is distinct from report_row.provider_id or report_row.status <> 'completed_pending_approval' then
    raise exception 'This task report is not ready for approval';
  end if;
  select user_id into provider_user_id from public.user_profiles where id = report_row.provider_id and role = 'service_provider';
  if provider_user_id is null then raise exception 'Assigned service provider account was not found'; end if;
  update public.task_reports set status = 'approved', last_updated_by = auth.uid(), updated_at = now() where id = report_row.id;
  update public.tasks set status = 'completed', updated_at = now() where id = task_row.id;
  insert into public.notifications (user_id, task_id, type, message)
  values (provider_user_id, task_row.id, 'task_updated', 'Your task "' || task_row.title || '" has been approved and marked complete.');
  if task_row.organization_id is null then return 0; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id and program_enabled;
  if not found then return 0; end if;
  perform public.hotel_loyalty_make_account(task_row.organization_id, provider_user_id);
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id;
  select coalesce(sum(points_delta), 0) into points_this_month from public.hotel_loyalty_ledger_entries
  where organization_id = task_row.organization_id and user_id = provider_user_id and entry_type = 'task_earn'
    and created_at >= date_trunc('month', now());
  reward_points := least(program_row.task_approval_points, greatest(program_row.monthly_task_points_cap - points_this_month, 0)::integer);
  if reward_points > 0 and exists (select 1 from public.hotel_loyalty_accounts where organization_id = task_row.organization_id and user_id = provider_user_id and is_enrolled) then
    if public.apply_hotel_loyalty_delta(task_row.organization_id, provider_user_id, 'task_earn', reward_points,
      'approved_task', task_row.id, 'Manager-approved hotel task reward') is null then reward_points := 0; end if;
  else reward_points := 0; end if;
  perform public.qualify_hotel_loyalty_referral(task_row.organization_id, provider_user_id, 'task', 'approved_task', task_row.id, null);
  return reward_points;
end;
$$;
revoke all on function public.approve_task_report_and_award_points(uuid) from public, anon;
grant execute on function public.approve_task_report_and_award_points(uuid) to authenticated;

create or replace function public.reverse_hotel_loyalty_purchase(
  target_organization_id uuid, target_source_type text, target_source_id uuid
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare queue_row public.hotel_loyalty_award_queue%rowtype; referral_row public.hotel_loyalty_referrals%rowtype;
begin
  select * into queue_row from public.hotel_loyalty_award_queue
  where organization_id = target_organization_id and source_type = target_source_type and source_id = target_source_id for update;
  if not found or queue_row.status in ('refunded', 'reversed') then return; end if;
  if queue_row.status = 'posted' and queue_row.points_awarded > 0 then
    perform public.apply_hotel_loyalty_delta(target_organization_id, queue_row.user_id, 'purchase_reversal',
      -queue_row.points_awarded, 'hotel_purchase_reversal', queue_row.id, 'Reversal of refunded hotel purchase reward');
  end if;
  update public.hotel_loyalty_award_queue set status = 'refunded', processed_at = now(), error_message = 'Purchase refunded' where id = queue_row.id;
  for referral_row in select * from public.hotel_loyalty_referrals
    where organization_id = target_organization_id and status = 'qualified'
      and qualification_source_type = target_source_type and qualification_source_id = target_source_id for update
  loop
    perform public.apply_hotel_loyalty_delta(target_organization_id, referral_row.referrer_user_id, 'referral_reversal',
      -referral_row.referrer_points, 'hotel_referral_reversal', referral_row.id, 'Reversal of refunded hotel referral reward');
    perform public.apply_hotel_loyalty_delta(target_organization_id, referral_row.referred_user_id, 'referral_reversal',
      -referral_row.invitee_points, 'hotel_referral_reversal', referral_row.id, 'Reversal of refunded hotel referral welcome reward');
    update public.hotel_loyalty_referrals set status = 'cancelled' where id = referral_row.id;
  end loop;
end;
$$;
revoke all on function public.reverse_hotel_loyalty_purchase(uuid, text, uuid) from public, anon, authenticated;

create or replace function public.reverse_hotel_loyalty_on_order_refund()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status in ('refunded', 'chargeback') and old.payment_status is distinct from new.payment_status
     and new.organization_id is not null then
    perform public.reverse_hotel_loyalty_purchase(new.organization_id, 'menu_order', new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_hotel_loyalty_on_order_refund() from public, anon, authenticated;
drop trigger if exists reverse_hotel_loyalty_order_refund on public.menu_orders;
create trigger reverse_hotel_loyalty_order_refund after update of payment_status on public.menu_orders
for each row execute function public.reverse_hotel_loyalty_on_order_refund();

create or replace function public.reverse_hotel_loyalty_on_booking_refund()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status in ('refunded', 'chargeback') and old.payment_status is distinct from new.payment_status then
    perform public.reverse_hotel_loyalty_purchase(new.organization_id, 'hotel_booking', new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_hotel_loyalty_on_booking_refund() from public, anon, authenticated;
drop trigger if exists reverse_hotel_loyalty_booking_refund on public.hotel_bookings;
create trigger reverse_hotel_loyalty_booking_refund after update of payment_status on public.hotel_bookings
for each row execute function public.reverse_hotel_loyalty_on_booking_refund();

create or replace function public.reverse_hotel_loyalty_on_event_refund()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare booking public.special_event_bookings%rowtype;
begin
  if new.status = 'refunded' and old.status is distinct from new.status then
    select * into booking from public.special_event_bookings where id = new.booking_id;
    if found and booking.organization_id is not null then
      perform public.reverse_hotel_loyalty_purchase(booking.organization_id, 'special_event_payment', new.id);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_hotel_loyalty_on_event_refund() from public, anon, authenticated;
drop trigger if exists reverse_hotel_loyalty_event_refund on public.special_event_payments;
create trigger reverse_hotel_loyalty_event_refund after update of status on public.special_event_payments
for each row execute function public.reverse_hotel_loyalty_on_event_refund();

create or replace function public.reverse_hotel_loyalty_on_event_refund_record()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare payment_row public.special_event_payments%rowtype; total_refunded numeric;
begin
  select * into payment_row from public.special_event_payments where id = new.payment_id;
  if not found then return new; end if;
  select coalesce(sum(amount), 0) into total_refunded from public.special_event_payment_refunds where payment_id = new.payment_id;
  if total_refunded >= payment_row.amount then
    update public.special_event_payments set status = 'refunded', updated_at = now() where id = payment_row.id and status <> 'refunded';
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_hotel_loyalty_on_event_refund_record() from public, anon, authenticated;
drop trigger if exists reverse_hotel_loyalty_event_refund_record on public.special_event_payment_refunds;
create trigger reverse_hotel_loyalty_event_refund_record after insert on public.special_event_payment_refunds
for each row execute function public.reverse_hotel_loyalty_on_event_refund_record();

create or replace function public.retry_hotel_loyalty_books_posting(target_ledger_entry_id uuid)
returns text language plpgsql security definer set search_path = pg_catalog, public
as $$
declare current_status text;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the service role may retry hotel loyalty accounting'; end if;
  perform public.post_hotel_loyalty_ledger_entry(target_ledger_entry_id);
  select status into current_status from public.hotel_loyalty_books_postings where ledger_entry_id = target_ledger_entry_id;
  return coalesce(current_status, 'missing');
end;
$$;
revoke all on function public.retry_hotel_loyalty_books_posting(uuid) from public, anon, authenticated;
grant execute on function public.retry_hotel_loyalty_books_posting(uuid) to service_role;

-- Preserve historical global tables as inactive data. Redemption remains disabled until
-- payment-attempt, verification, invoice, and settlement code all consume amount_due.
notify pgrst, 'reload schema';
commit;
