begin;

create table if not exists public.special_event_facilities (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_active boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into public.special_event_facilities (name, display_order)
values
  ('Conference Hall', 1),
  ('Meeting Room', 2),
  ('Poolside', 3),
  ('Outdoor / Garden Space', 4),
  ('Restaurant / Private Dining', 5),
  ('Other / To be discussed', 6)
on conflict (name) do nothing;

alter table public.special_event_plans
  add column if not exists category text not null default 'Social Gathering',
  add column if not exists starts_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists timezone text not null default 'Africa/Kampala',
  add column if not exists facility_id uuid references public.special_event_facilities(id) on delete set null,
  add column if not exists contact_name text,
  add column if not exists contact_email text,
  add column if not exists contact_phone text,
  add column if not exists share_manager_operations boolean not null default false,
  add column if not exists manager_note text,
  add column if not exists suggested_title text,
  add column if not exists suggested_description text,
  add column if not exists suggested_category text,
  add column if not exists suggested_starts_at timestamptz,
  add column if not exists suggested_ends_at timestamptz,
  add column if not exists suggested_facility_id uuid references public.special_event_facilities(id) on delete set null,
  add column if not exists suggested_expected_guests integer,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists published_at timestamptz,
  add column if not exists special_event_id uuid references public.special_events(id) on delete set null;

alter table public.special_event_plans drop constraint if exists special_event_plans_status_check;
update public.special_event_plans set status = 'submitted' where status = 'approved';
alter table public.special_event_plans
  add constraint special_event_plans_status_check
  check (status in ('draft', 'submitted', 'changes_requested', 'scheduled', 'declined', 'cancelled'));

alter table public.special_events
  add column if not exists is_private boolean not null default false,
  add column if not exists facility_id uuid references public.special_event_facilities(id) on delete set null,
  add column if not exists source_plan_id uuid references public.special_event_plans(id) on delete set null;

alter table public.special_events drop constraint if exists special_events_private_unpublished_check;
alter table public.special_events add constraint special_events_private_unpublished_check
  check (not (is_private and status = 'published'));

grant select on public.special_event_facilities to authenticated;

update public.special_event_plans
set starts_at = (event_date + time '09:00') at time zone timezone,
    ends_at = (event_date + time '12:00') at time zone timezone
where starts_at is null;

update public.special_events e
set facility_id = f.id
from public.special_event_facilities f
where e.facility_id is null and lower(e.location) = lower(f.name);

create unique index if not exists special_events_source_plan_id_key
  on public.special_events (source_plan_id) where source_plan_id is not null;

alter table public.notifications
  add column if not exists event_proposal_id uuid references public.special_event_plans(id) on delete cascade;

create index if not exists special_event_plans_review_queue_idx
  on public.special_event_plans (status, event_date, created_at);
create index if not exists notifications_event_proposal_idx
  on public.notifications (event_proposal_id) where event_proposal_id is not null;

alter table public.special_event_facilities enable row level security;
drop policy if exists special_event_facilities_active_select on public.special_event_facilities;
create policy special_event_facilities_active_select
  on public.special_event_facilities for select to authenticated
  using (is_active);

create or replace function public.is_special_event_platform_manager(target_event_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  ) or (target_event_id is not null and exists (
    select 1 from public.special_events e
    where e.id = target_event_id
      and (e.organizer_id = auth.uid() or e.created_by = auth.uid())
  ) and exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid() and p.role = 'manager'
  )) or (target_event_id is not null and exists (
    select 1 from public.special_event_staff s
    where s.event_id = target_event_id and s.user_id = auth.uid()
      and s.status = 'active' and s.role = 'manager'
  )) or (target_event_id is null and exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid() and p.role in ('manager', 'admin')
  ));
$$;

create or replace function public.is_special_event_manager(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_special_event_platform_manager(target_event_id) or exists (
    select 1 from public.special_events e
    where e.id = target_event_id and e.created_by = auth.uid() and e.source_plan_id is not null
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

revoke all on function public.is_special_event_platform_manager(uuid) from public, anon;
grant execute on function public.is_special_event_platform_manager(uuid) to authenticated;
revoke all on function public.is_special_event_manager(uuid) from public, anon;
grant execute on function public.is_special_event_manager(uuid) to authenticated;
revoke all on function public.can_operate_special_event(uuid) from public, anon;
grant execute on function public.can_operate_special_event(uuid) to authenticated;

drop policy if exists special_event_facilities_manager_insert on public.special_event_facilities;
drop policy if exists special_event_facilities_manager_update on public.special_event_facilities;
drop policy if exists special_event_facilities_manager_delete on public.special_event_facilities;
create policy special_event_facilities_manager_insert
  on public.special_event_facilities for insert to authenticated
  with check (public.is_special_event_platform_manager());
create policy special_event_facilities_manager_update
  on public.special_event_facilities for update to authenticated
  using (public.is_special_event_platform_manager())
  with check (public.is_special_event_platform_manager());
create policy special_event_facilities_manager_delete
  on public.special_event_facilities for delete to authenticated
  using (public.is_special_event_platform_manager());

drop policy if exists special_event_plans_owner_select on public.special_event_plans;
create policy special_event_plans_owner_select
  on public.special_event_plans for select to authenticated
  using (user_id = auth.uid());
drop policy if exists special_event_plans_manager_select on public.special_event_plans;
create policy special_event_plans_manager_select
  on public.special_event_plans for select to authenticated
  using (public.is_special_event_platform_manager());
drop policy if exists special_event_plans_owner_insert on public.special_event_plans;
drop policy if exists special_event_plans_owner_update on public.special_event_plans;
drop policy if exists special_event_plans_owner_delete on public.special_event_plans;
create policy special_event_plans_owner_delete
  on public.special_event_plans for delete to authenticated
  using (user_id = auth.uid() and status = 'submitted');

create or replace function public.submit_special_event_proposal(
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
  proposal_share_manager_operations boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_plan_id uuid;
  v_facility_name text;
  manager_row record;
begin
  if v_user_id is null then raise exception 'Authentication is required'; end if;
  if nullif(trim(proposal_title), '') is null or nullif(trim(proposal_category), '') is null
     or proposal_starts_at is null or proposal_ends_at is null or proposal_ends_at <= proposal_starts_at
     or proposal_starts_at <= now()
     or proposal_expected_guests is null or proposal_expected_guests < 1
     or nullif(trim(proposal_contact_name), '') is null
     or nullif(trim(proposal_contact_email), '') is null then
    raise exception 'Complete the required event and contact details';
  end if;
  select name into v_facility_name from public.special_event_facilities
  where id = proposal_facility_id and is_active;
  if v_facility_name is null then raise exception 'Choose an available hotel facility'; end if;

  if target_plan_id is null then
    insert into public.special_event_plans (
      user_id, title, event_date, starts_at, ends_at, timezone, location, facility_id,
      expected_guests, description, category, image_url, is_private,
      contact_name, contact_email, contact_phone, share_manager_operations, status
    ) values (
      v_user_id, trim(proposal_title), (proposal_starts_at at time zone coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala'))::date, proposal_starts_at,
      proposal_ends_at, coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala'),
      v_facility_name, proposal_facility_id, proposal_expected_guests,
      nullif(trim(proposal_description), ''), trim(proposal_category),
      nullif(trim(proposal_image_url), ''), coalesce(proposal_is_private, false),
      trim(proposal_contact_name), lower(trim(proposal_contact_email)),
      nullif(trim(proposal_contact_phone), ''), coalesce(proposal_share_manager_operations, false), 'submitted'
    ) returning id into v_plan_id;
  else
    update public.special_event_plans set
      title = trim(proposal_title), event_date = (proposal_starts_at at time zone coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala'))::date,
      starts_at = proposal_starts_at, ends_at = proposal_ends_at,
      timezone = coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala'),
      location = v_facility_name, facility_id = proposal_facility_id,
      expected_guests = proposal_expected_guests,
      description = nullif(trim(proposal_description), ''),
      category = trim(proposal_category), image_url = nullif(trim(proposal_image_url), ''),
      is_private = coalesce(proposal_is_private, false),
      contact_name = trim(proposal_contact_name),
      contact_email = lower(trim(proposal_contact_email)),
      contact_phone = nullif(trim(proposal_contact_phone), ''),
      share_manager_operations = coalesce(proposal_share_manager_operations, false),
      manager_note = null, reviewed_by = null, reviewed_at = null,
      status = 'submitted', updated_at = now()
    where id = target_plan_id and user_id = v_user_id and status = 'submitted'
    returning id into v_plan_id;
    if v_plan_id is null then raise exception 'This event proposal can no longer be edited'; end if;
  end if;

  for manager_row in
    select user_id from public.user_profiles where role in ('manager', 'admin')
  loop
    insert into public.notifications (user_id, event_proposal_id, type, message)
    values (manager_row.user_id, v_plan_id, 'event_proposal_submitted',
      'A new event proposal, “' || trim(proposal_title) || '”, is ready for review.');
  end loop;
  return v_plan_id;
end;
$$;

create or replace function public.review_special_event_proposal(
  target_plan_id uuid,
  review_action text,
  suggested_values jsonb default null,
  review_message text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.special_event_plans%rowtype;
  v_suggested_facility_id uuid;
  v_suggested_facility_name text;
  v_suggested_starts_at timestamptz;
  v_suggested_ends_at timestamptz;
  v_suggested_title text;
  v_suggested_description text;
  v_suggested_category text;
  v_suggested_guests integer;
  v_event_id uuid;
begin
  if not public.is_special_event_platform_manager() then raise exception 'Only a hotel manager can review event proposals'; end if;
  select * into v_plan from public.special_event_plans where id = target_plan_id for update;
  if not found or v_plan.status <> 'submitted' then raise exception 'This event proposal is not awaiting review'; end if;
  if v_plan.starts_at is null or v_plan.starts_at <= now() or v_plan.ends_at <= v_plan.starts_at then
    raise exception 'This proposal no longer has a valid future event time';
  end if;

  if review_action = 'decline' then
    update public.special_event_plans set status = 'declined',
      manager_note = nullif(trim(review_message), ''), reviewed_by = auth.uid(),
      reviewed_at = now(), updated_at = now()
    where id = v_plan.id;
    insert into public.notifications (user_id, event_proposal_id, type, message)
    values (v_plan.user_id, v_plan.id, 'event_proposal_declined',
      'The hotel team declined your event proposal “' || v_plan.title || '”.' ||
      case when nullif(trim(review_message), '') is null then '' else ' ' || trim(review_message) end);
    return;
  elsif review_action = 'suggest_changes' then
    v_suggested_title := coalesce(nullif(trim(suggested_values->>'title'), ''), v_plan.title);
    v_suggested_description := nullif(trim(coalesce(suggested_values->>'description', v_plan.description, '')), '');
    v_suggested_category := coalesce(nullif(trim(suggested_values->>'category'), ''), v_plan.category);
    v_suggested_starts_at := coalesce(nullif(suggested_values->>'starts_at', '')::timestamptz, v_plan.starts_at);
    v_suggested_ends_at := coalesce(nullif(suggested_values->>'ends_at', '')::timestamptz, v_plan.ends_at);
    v_suggested_facility_id := coalesce(nullif(suggested_values->>'facility_id', '')::uuid, v_plan.facility_id);
    v_suggested_guests := coalesce(nullif(suggested_values->>'expected_guests', '')::integer, v_plan.expected_guests);
    if v_suggested_starts_at is null or v_suggested_starts_at <= now() or v_suggested_ends_at <= v_suggested_starts_at or v_suggested_guests < 1 then
      raise exception 'Suggested event dates and capacity are invalid';
    end if;
    select name into v_suggested_facility_name from public.special_event_facilities
    where id = v_suggested_facility_id and is_active;
    if v_suggested_facility_name is null then raise exception 'Choose an available hotel facility'; end if;
    update public.special_event_plans set status = 'changes_requested',
      manager_note = nullif(trim(review_message), ''), reviewed_by = auth.uid(), reviewed_at = now(),
      suggested_title = v_suggested_title, suggested_description = v_suggested_description,
      suggested_category = v_suggested_category, suggested_starts_at = v_suggested_starts_at,
      suggested_ends_at = v_suggested_ends_at, suggested_facility_id = v_suggested_facility_id,
      suggested_expected_guests = v_suggested_guests, updated_at = now()
    where id = v_plan.id;
    insert into public.notifications (user_id, event_proposal_id, type, message)
    values (v_plan.user_id, v_plan.id, 'event_proposal_updated',
      'The hotel team suggested changes to your event proposal “' || v_plan.title || '”. Review them in My Events.');
    return;
  elsif review_action <> 'approve' then
    raise exception 'The review action is invalid';
  end if;

  update public.special_event_plans set status = 'scheduled',
    manager_note = nullif(trim(review_message), ''), reviewed_by = auth.uid(), reviewed_at = now(),
    suggested_title = null, suggested_description = null, suggested_category = null,
    suggested_starts_at = null, suggested_ends_at = null,
    suggested_facility_id = null, suggested_expected_guests = null, updated_at = now()
  where id = v_plan.id;

  insert into public.special_events (
    title, description, category, starts_at, ends_at, timezone, location, facility_id,
    price, currency, capacity, ticket_type_capacity, max_tickets_per_order,
    attendees_count, featured, rating, host_name, image_url, status, organizer_id,
    created_by, is_private, source_plan_id
  ) values (
    v_plan.title, v_plan.description, v_plan.category, v_plan.starts_at, v_plan.ends_at,
    v_plan.timezone, v_plan.location, v_plan.facility_id, 0, 'UGX', v_plan.expected_guests,
    v_plan.expected_guests, 10, 0, false, 0, v_plan.contact_name, v_plan.image_url,
    'draft', auth.uid(), v_plan.user_id, v_plan.is_private, v_plan.id
  ) returning id into v_event_id;
  if v_plan.share_manager_operations then
    insert into public.special_event_staff (event_id, user_id, role, added_by)
    values (v_event_id, auth.uid(), 'manager', auth.uid())
    on conflict (event_id, user_id) do update set status = 'active', role = 'manager', updated_at = now();
  end if;
  update public.special_event_plans set special_event_id = v_event_id where id = v_plan.id;

  insert into public.notifications (user_id, event_proposal_id, type, message)
  values (v_plan.user_id, v_plan.id, 'event_proposal_scheduled',
    case when v_plan.is_private
      then 'Your private event proposal “' || v_plan.title || '” has been approved and scheduled.'
      else 'Your event proposal “' || v_plan.title || '” has been approved and scheduled. The hotel team will decide whether to publish it.'
    end);
end;
$$;

create or replace function public.respond_to_special_event_proposal(target_plan_id uuid, accept_suggestions boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.special_event_plans%rowtype;
  v_facility_name text;
  v_event_id uuid;
begin
  select * into v_plan from public.special_event_plans
  where id = target_plan_id and user_id = auth.uid() for update;
  if not found or v_plan.status <> 'changes_requested' then raise exception 'This proposal has no suggested changes to respond to'; end if;

  if not accept_suggestions then
    update public.special_event_plans set status = 'declined', updated_at = now()
    where id = v_plan.id;
    insert into public.notifications (user_id, event_proposal_id, type, message)
    select p.user_id, v_plan.id, 'event_proposal_updated',
      'The proposer declined the suggested changes for “' || v_plan.title || '”.'
    from public.user_profiles p where p.role in ('manager', 'admin');
    return;
  end if;

  if v_plan.suggested_starts_at is null or v_plan.suggested_starts_at <= now()
     or v_plan.suggested_ends_at <= v_plan.suggested_starts_at then
    raise exception 'The suggested event time is no longer valid';
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
  where id = v_plan.id;

  insert into public.special_events (
    title, description, category, starts_at, ends_at, timezone, location, facility_id,
    price, currency, capacity, ticket_type_capacity, max_tickets_per_order,
    attendees_count, featured, rating, host_name, image_url, status, organizer_id,
    created_by, is_private, source_plan_id
  ) values (
    v_plan.suggested_title, v_plan.suggested_description, v_plan.suggested_category,
    v_plan.suggested_starts_at, v_plan.suggested_ends_at, v_plan.timezone, v_facility_name,
    v_plan.suggested_facility_id, 0, 'UGX', v_plan.suggested_expected_guests,
    v_plan.suggested_expected_guests, 10, 0, false, 0, v_plan.contact_name,
    v_plan.image_url, 'draft', v_plan.reviewed_by, v_plan.user_id, v_plan.is_private, v_plan.id
  ) returning id into v_event_id;
  if v_plan.share_manager_operations then
    insert into public.special_event_staff (event_id, user_id, role, added_by)
    values (v_event_id, v_plan.reviewed_by, 'manager', v_plan.reviewed_by)
    on conflict (event_id, user_id) do update set status = 'active', role = 'manager', updated_at = now();
  end if;
  update public.special_event_plans set special_event_id = v_event_id where id = v_plan.id;

  insert into public.notifications (user_id, event_proposal_id, type, message)
  select p.user_id, v_plan.id, 'event_proposal_updated',
    'The proposer accepted the suggested changes for “' || v_plan.title || '”.'
  from public.user_profiles p where p.role in ('manager', 'admin');
  insert into public.notifications (user_id, event_proposal_id, type, message)
  values (v_plan.user_id, v_plan.id, 'event_proposal_scheduled',
    case when v_plan.is_private
      then 'Your private event proposal has been scheduled.'
      else 'Your updated event proposal has been scheduled. The hotel team will decide whether to publish it.'
    end);
end;
$$;

create or replace function public.publish_special_event_proposal(
  target_plan_id uuid,
  ticket_price numeric default 0,
  ticket_currency text default 'UGX'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.special_event_plans%rowtype;
begin
  if not public.is_special_event_platform_manager() then raise exception 'Only a hotel manager can publish proposed events'; end if;
  select * into v_plan from public.special_event_plans where id = target_plan_id for update;
  if not found or v_plan.status <> 'scheduled' or v_plan.is_private or v_plan.published_at is not null or v_plan.special_event_id is null then
    raise exception 'This proposal is not eligible for public event listing';
  end if;
  if ticket_price is null or ticket_price < 0 or ticket_currency is null or char_length(upper(ticket_currency)) <> 3 then
    raise exception 'Ticket price or currency is invalid';
  end if;
  update public.special_events set status = 'published', price = ticket_price,
    currency = upper(ticket_currency), updated_at = now()
  where id = v_plan.special_event_id and source_plan_id = v_plan.id
    and is_private = false and starts_at > now();
  if not found then raise exception 'This event cannot be published'; end if;
  update public.special_event_plans set published_at = now(), updated_at = now() where id = v_plan.id;
  insert into public.notifications (user_id, event_proposal_id, type, message)
  values (v_plan.user_id, v_plan.id, 'event_published',
    'The hotel team published “' || v_plan.title || '” in Browse Events.');
end;
$$;

revoke all on function public.submit_special_event_proposal(uuid, text, text, text, timestamptz, timestamptz, text, uuid, integer, text, text, text, text, boolean, boolean) from public, anon;
grant execute on function public.submit_special_event_proposal(uuid, text, text, text, timestamptz, timestamptz, text, uuid, integer, text, text, text, text, boolean, boolean) to authenticated;
revoke all on function public.review_special_event_proposal(uuid, text, jsonb, text) from public, anon;
grant execute on function public.review_special_event_proposal(uuid, text, jsonb, text) to authenticated;
revoke all on function public.respond_to_special_event_proposal(uuid, boolean) from public, anon;
grant execute on function public.respond_to_special_event_proposal(uuid, boolean) to authenticated;
revoke all on function public.publish_special_event_proposal(uuid, numeric, text) from public, anon;
grant execute on function public.publish_special_event_proposal(uuid, numeric, text) to authenticated;

drop policy if exists special_events_public_select on public.special_events;
create policy special_events_public_select
  on public.special_events for select to anon, authenticated
  using (status = 'published' and is_private = false or exists (
    select 1 from public.special_event_bookings b
    where b.event_id = special_events.id and b.user_id = auth.uid()
  ));
drop policy if exists special_events_manager_update on public.special_events;
drop policy if exists special_events_manager_select on public.special_events;
create policy special_events_manager_select
  on public.special_events for select to authenticated
  using (public.is_special_event_manager(id));
create policy special_events_manager_update
  on public.special_events for update to authenticated
  using (public.is_special_event_manager(id))
  with check (
    public.is_special_event_platform_manager()
    or (status <> 'published' and public.is_special_event_manager(id))
  );
drop policy if exists special_events_manager_delete on public.special_events;
create policy special_events_manager_delete
  on public.special_events for delete to authenticated
  using (public.is_special_event_platform_manager(id));

do $$
declare constraint_row record;
begin
  for constraint_row in
    select conname from pg_constraint
    where conrelid = 'public.notifications'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%type%'
  loop
    execute format('alter table public.notifications drop constraint %I', constraint_row.conname);
  end loop;
end;
$$;

alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'complaint_filed', 'complaint_acknowledged', 'task_created', 'task_updated',
    'task_assigned', 'task_accepted', 'task_declined', 'task_proposed',
    'proposal_accepted', 'proposal_declined', 'proposal_updated', 'todo_created',
    'task_message', 'report_submitted', 'evidence_approved', 'issue_raised', 'issue_resolved',
    'task_flagged', 'task_approval_ready',
    'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
    'event_proposal_declined', 'event_published'
  ));

drop policy if exists notifications_event_proposal_insert_rpc_only on public.notifications;
create policy notifications_event_proposal_insert_rpc_only
  on public.notifications as restrictive for insert to public
  with check (type not in (
    'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
    'event_proposal_declined', 'event_published'
  ));

create or replace function public.protect_event_proposal_notifications()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (old.type in (
        'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
        'event_proposal_declined', 'event_published'
      ) or new.type in (
        'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
        'event_proposal_declined', 'event_published'
      ))
     and (to_jsonb(new) - 'is_read') is distinct from (to_jsonb(old) - 'is_read') then
    raise exception 'Event proposal notifications are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_event_proposal_notifications on public.notifications;
create trigger protect_event_proposal_notifications
  before update on public.notifications
  for each row execute function public.protect_event_proposal_notifications();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'special_event_plans'
  ) then
    alter publication supabase_realtime add table public.special_event_plans;
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
