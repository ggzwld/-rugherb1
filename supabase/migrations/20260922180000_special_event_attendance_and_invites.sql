begin;

alter table public.special_event_plans
  add column if not exists entry_type text not null default 'free',
  add column if not exists entry_fee numeric(12, 2) not null default 0,
  add column if not exists entry_currency text not null default 'UGX',
  add column if not exists share_token uuid not null default gen_random_uuid();

alter table public.special_events
  add column if not exists share_token uuid not null default gen_random_uuid();

alter table public.special_event_bookings
  add column if not exists event_invitation_id uuid;

alter table public.special_event_plans
  drop constraint if exists special_event_plans_entry_details_check;
alter table public.special_event_plans
  add constraint special_event_plans_entry_details_check
  check (
    (entry_type = 'free' and entry_fee = 0)
    or (entry_type = 'paid' and entry_fee > 0)
  );

alter table public.special_events
  drop constraint if exists special_events_unique_share_token_key;
create unique index if not exists special_events_share_token_key
  on public.special_events (share_token);
create unique index if not exists special_event_plans_share_token_key
  on public.special_event_plans (share_token);

update public.special_events e
set price = p.entry_fee, currency = p.entry_currency
from public.special_event_plans p
where e.source_plan_id = p.id
  and (e.price is distinct from p.entry_fee or e.currency is distinct from p.entry_currency);

create or replace function public.prevent_special_event_plan_price_changes()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  plan_fee numeric(12, 2);
  plan_currency text;
begin
  if tg_op = 'INSERT' and new.source_plan_id is not null then
    select entry_fee, entry_currency into plan_fee, plan_currency
    from public.special_event_plans where id = new.source_plan_id;
    if not found then raise exception 'Source event proposal was not found'; end if;
    new.price := plan_fee;
    new.currency := plan_currency;
  elsif tg_op = 'UPDATE' and (
    new.source_plan_id is distinct from old.source_plan_id
    or (old.source_plan_id is not null and (
      new.price is distinct from old.price or new.currency is distinct from old.currency
    ))
  ) then
    raise exception 'The event creator sets the entry fee for creator-organized events';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_special_event_plan_price_changes on public.special_events;
create trigger prevent_special_event_plan_price_changes
  before insert or update of source_plan_id, price, currency on public.special_events
  for each row execute function public.prevent_special_event_plan_price_changes();

create table if not exists public.special_event_invitations (
  id uuid primary key default gen_random_uuid(),
  event_plan_id uuid not null references public.special_event_plans(id) on delete cascade,
  event_id uuid not null references public.special_events(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict,
  invitee_email text not null,
  invitee_user_id uuid references auth.users(id) on delete set null,
  token uuid not null default gen_random_uuid(),
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique (event_plan_id, invitee_email),
  unique (token)
);

alter table public.special_event_bookings
  drop constraint if exists special_event_bookings_event_invitation_fk;
alter table public.special_event_bookings
  add constraint special_event_bookings_event_invitation_fk
  foreign key (event_invitation_id) references public.special_event_invitations(id) on delete set null;

drop index if exists public.special_event_bookings_invitation_key;
create unique index special_event_bookings_invitation_key
  on public.special_event_bookings (event_invitation_id)
  where event_invitation_id is not null and status in ('pending', 'confirmed', 'manual_review');
create index if not exists special_event_invitations_owner_idx
  on public.special_event_invitations (event_plan_id, created_at desc);
create index if not exists special_event_invitations_invitee_idx
  on public.special_event_invitations (invitee_user_id, status);

alter table public.notifications
  add column if not exists event_invitation_id uuid references public.special_event_invitations(id) on delete cascade;

create index if not exists notifications_event_invitation_idx
  on public.notifications (event_invitation_id)
  where event_invitation_id is not null;

grant select on public.special_event_invitations to authenticated;
alter table public.special_event_invitations enable row level security;
drop policy if exists special_event_invitations_related_select on public.special_event_invitations;
create policy special_event_invitations_related_select
  on public.special_event_invitations for select to authenticated
  using (
    invitee_user_id = auth.uid()
    or lower(invitee_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or exists (
      select 1 from public.special_event_plans p
      where p.id = event_plan_id and p.user_id = auth.uid()
    )
  );

create or replace function public.get_special_event_by_share_token(target_share_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', e.id, 'title', e.title, 'description', e.description, 'category', e.category,
    'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'location', e.location,
    'facility_id', e.facility_id, 'is_private', e.is_private, 'source_plan_id', e.source_plan_id,
    'share_token', e.share_token, 'price', e.price, 'currency', e.currency, 'capacity', e.capacity,
    'ticket_type_capacity', e.ticket_type_capacity, 'max_tickets_per_order', e.max_tickets_per_order,
    'default_ticket_type_id', e.default_ticket_type_id, 'attendees_count', e.attendees_count,
    'featured', e.featured, 'rating', e.rating, 'host_name', e.host_name, 'image_url', e.image_url,
    'status', e.status, 'organizer_id', e.organizer_id, 'created_by', e.created_by,
    'created_at', e.created_at, 'updated_at', e.updated_at
  )
  from public.special_events e
  where e.share_token = target_share_token
    and e.is_private = false
    and e.status in ('draft', 'published')
    and e.starts_at > now();
$$;

create or replace function public.get_special_event_invitation_by_token(target_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', i.id,
    'event_id', i.event_id,
    'invitee_email', i.invitee_email,
    'invitation_status', i.status,
    'event', jsonb_build_object(
      'id', e.id, 'title', e.title, 'description', e.description, 'category', e.category,
      'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'location', e.location,
      'facility_id', e.facility_id, 'is_private', e.is_private, 'source_plan_id', e.source_plan_id,
      'share_token', e.share_token, 'price', e.price, 'currency', e.currency, 'capacity', e.capacity,
      'ticket_type_capacity', e.ticket_type_capacity, 'max_tickets_per_order', e.max_tickets_per_order,
      'default_ticket_type_id', e.default_ticket_type_id, 'attendees_count', e.attendees_count,
      'featured', e.featured, 'rating', e.rating, 'host_name', e.host_name, 'image_url', e.image_url,
      'status', e.status, 'organizer_id', e.organizer_id, 'created_by', e.created_by,
      'created_at', e.created_at, 'updated_at', e.updated_at
    )
  )
  from public.special_event_invitations i
  join public.special_event_plans p on p.id = i.event_plan_id
  join public.special_events e on e.id = i.event_id
  where i.token = target_token
    and i.status in ('pending', 'accepted')
    and p.status = 'scheduled'
    and e.is_private = true
    and e.status = 'draft'
    and e.starts_at > now();
$$;

create or replace function public.get_special_event_invitation_by_id(target_invitation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'id', i.id,
    'event_id', i.event_id,
    'invitee_email', i.invitee_email,
    'invitation_status', i.status,
    'event', jsonb_build_object(
      'id', e.id, 'title', e.title, 'description', e.description, 'category', e.category,
      'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'location', e.location,
      'facility_id', e.facility_id, 'is_private', e.is_private, 'source_plan_id', e.source_plan_id,
      'share_token', e.share_token, 'price', e.price, 'currency', e.currency, 'capacity', e.capacity,
      'ticket_type_capacity', e.ticket_type_capacity, 'max_tickets_per_order', e.max_tickets_per_order,
      'default_ticket_type_id', e.default_ticket_type_id, 'attendees_count', e.attendees_count,
      'featured', e.featured, 'rating', e.rating, 'host_name', e.host_name, 'image_url', e.image_url,
      'status', e.status, 'organizer_id', e.organizer_id, 'created_by', e.created_by,
      'created_at', e.created_at, 'updated_at', e.updated_at
    )
  ) into result
  from public.special_event_invitations i
  join public.special_event_plans p on p.id = i.event_plan_id
  join public.special_events e on e.id = i.event_id
  where i.id = target_invitation_id
    and (i.invitee_user_id = auth.uid()
      or lower(i.invitee_email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    and i.status in ('pending', 'accepted')
    and p.status = 'scheduled'
    and e.is_private = true
    and e.status = 'draft'
    and e.starts_at > now();
  return result;
end;
$$;

create or replace function public.get_my_special_event_invitations()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'event_id', i.event_id,
    'invitee_email', i.invitee_email,
    'invitation_status', i.status,
    'event', jsonb_build_object(
      'id', e.id, 'title', e.title, 'description', e.description, 'category', e.category,
      'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'location', e.location,
      'facility_id', e.facility_id, 'is_private', e.is_private, 'source_plan_id', e.source_plan_id,
      'share_token', e.share_token, 'price', e.price, 'currency', e.currency, 'capacity', e.capacity,
      'ticket_type_capacity', e.ticket_type_capacity, 'max_tickets_per_order', e.max_tickets_per_order,
      'default_ticket_type_id', e.default_ticket_type_id, 'attendees_count', e.attendees_count,
      'featured', e.featured, 'rating', e.rating, 'host_name', e.host_name, 'image_url', e.image_url,
      'status', e.status, 'organizer_id', e.organizer_id, 'created_by', e.created_by,
      'created_at', e.created_at, 'updated_at', e.updated_at
    )
  ) order by i.created_at desc), '[]'::jsonb)
  from public.special_event_invitations i
  join public.special_event_plans p on p.id = i.event_plan_id
  join public.special_events e on e.id = i.event_id
  where auth.uid() is not null
    and (i.invitee_user_id = auth.uid()
      or lower(i.invitee_email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    and i.status in ('pending', 'accepted')
    and p.status = 'scheduled'
    and e.is_private = true
    and e.status = 'draft'
    and e.starts_at > now();
$$;

create or replace function public.create_special_event_invitation(
  target_plan_id uuid,
  invited_email text
)
returns table (invitation_id uuid, invitation_token uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.special_event_plans%rowtype;
  v_event public.special_events%rowtype;
  v_email text := lower(trim(invited_email));
  v_invitee_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if nullif(v_email, '') is null or position('@' in v_email) < 2 then
    raise exception 'Enter a valid invitation email';
  end if;

  select * into v_plan
  from public.special_event_plans
  where id = target_plan_id and user_id = auth.uid()
  for update;
  if not found or v_plan.status <> 'scheduled' or not v_plan.is_private or v_plan.special_event_id is null then
    raise exception 'Only the creator of a scheduled private event can invite guests';
  end if;
  select * into v_event from public.special_events where id = v_plan.special_event_id;
  if not found or not v_event.is_private or v_event.source_plan_id is distinct from v_plan.id
     or v_event.status <> 'draft' or v_event.starts_at <= now() then
    raise exception 'This private event is no longer open for invitations';
  end if;

  select p.user_id into v_invitee_user_id
  from public.user_profiles p
  where lower(p.email) = v_email
  limit 1;
  if v_invitee_user_id = auth.uid() then raise exception 'You cannot invite yourself'; end if;

  insert into public.special_event_invitations (
    event_plan_id, event_id, created_by, invitee_email, invitee_user_id, token, status, responded_at
  ) values (
    v_plan.id, v_plan.special_event_id, auth.uid(), v_email, v_invitee_user_id,
    gen_random_uuid(), 'pending', null
  )
  on conflict (event_plan_id, invitee_email) do update set
    created_by = excluded.created_by,
    invitee_user_id = excluded.invitee_user_id,
    token = gen_random_uuid(),
    status = 'pending',
    responded_at = null,
    created_at = now()
  returning id, token into invitation_id, invitation_token;

  if v_invitee_user_id is not null then
    insert into public.notifications (user_id, event_invitation_id, type, message)
    values (
      v_invitee_user_id,
      invitation_id,
      'event_invitation_received',
      'You are invited to the private event “' || v_plan.title || '”. Open My Events to respond.'
    );
  end if;
  return next;
end;
$$;

create or replace function public.respond_to_special_event_invitation(
  target_invitation_id uuid,
  accept_invitation boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invitation public.special_event_invitations%rowtype;
  v_plan public.special_event_plans%rowtype;
  v_event public.special_events%rowtype;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select * into v_invitation
  from public.special_event_invitations
  where id = target_invitation_id
    and (invitee_user_id = auth.uid() or lower(invitee_email) = v_email)
  for update;
  if not found or v_invitation.status <> 'pending' then
    raise exception 'This invitation is no longer awaiting a response';
  end if;

  select * into v_plan from public.special_event_plans where id = v_invitation.event_plan_id;
  select * into v_event from public.special_events where id = v_invitation.event_id;
  if v_plan.status <> 'scheduled' or not v_plan.is_private or not v_event.is_private
     or v_event.source_plan_id is distinct from v_plan.id
     or v_event.status <> 'draft' or v_event.starts_at <= now() then
    raise exception 'This event invitation is no longer valid';
  end if;

  update public.special_event_invitations set
    status = case when accept_invitation then 'accepted' else 'declined' end,
    invitee_user_id = auth.uid(),
    responded_at = now()
  where id = v_invitation.id
  returning * into v_invitation;

  insert into public.notifications (user_id, event_invitation_id, type, message)
  values (
    v_invitation.created_by,
    v_invitation.id,
    'event_invitation_responded',
    case when accept_invitation
      then 'An invited guest accepted “' || v_plan.title || '”.'
      else 'An invited guest declined “' || v_plan.title || '”.'
    end
  );

  return jsonb_build_object(
    'id', v_invitation.id,
    'event_id', v_invitation.event_id,
    'invitee_email', v_invitation.invitee_email,
    'invitation_status', v_invitation.status,
    'event', to_jsonb(v_event)
  );
end;
$$;

drop function if exists public.submit_special_event_proposal(uuid, text, text, text, timestamptz, timestamptz, text, uuid, integer, text, text, text, text, boolean, boolean);
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
  proposal_entry_type text,
  proposal_entry_fee numeric,
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
  v_timezone text := coalesce(nullif(trim(proposal_timezone), ''), 'Africa/Kampala');
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
  if proposal_entry_type is null or proposal_entry_type not in ('free', 'paid')
     or proposal_entry_fee is null
     or (proposal_entry_type = 'free' and proposal_entry_fee <> 0)
     or (proposal_entry_type = 'paid' and proposal_entry_fee <= 0) then
    raise exception 'Choose free entry or enter a positive paid entry fee';
  end if;
  select name into v_facility_name from public.special_event_facilities
  where id = proposal_facility_id and is_active;
  if v_facility_name is null then raise exception 'Choose an available hotel facility'; end if;

  if target_plan_id is null then
    insert into public.special_event_plans (
      user_id, title, event_date, starts_at, ends_at, timezone, location, facility_id,
      expected_guests, description, category, image_url, is_private,
      contact_name, contact_email, contact_phone, share_manager_operations,
      entry_type, entry_fee, entry_currency, status
    ) values (
      v_user_id, trim(proposal_title), (proposal_starts_at at time zone v_timezone)::date,
      proposal_starts_at, proposal_ends_at, v_timezone, v_facility_name, proposal_facility_id,
      proposal_expected_guests, nullif(trim(proposal_description), ''), trim(proposal_category),
      nullif(trim(proposal_image_url), ''), coalesce(proposal_is_private, false),
      trim(proposal_contact_name), lower(trim(proposal_contact_email)),
      nullif(trim(proposal_contact_phone), ''), coalesce(proposal_share_manager_operations, false),
      proposal_entry_type, proposal_entry_fee, 'UGX', 'submitted'
    ) returning id into v_plan_id;
  else
    update public.special_event_plans set
      title = trim(proposal_title),
      event_date = (proposal_starts_at at time zone v_timezone)::date,
      starts_at = proposal_starts_at, ends_at = proposal_ends_at, timezone = v_timezone,
      location = v_facility_name, facility_id = proposal_facility_id,
      expected_guests = proposal_expected_guests,
      description = nullif(trim(proposal_description), ''), category = trim(proposal_category),
      image_url = nullif(trim(proposal_image_url), ''),
      is_private = coalesce(proposal_is_private, false),
      contact_name = trim(proposal_contact_name), contact_email = lower(trim(proposal_contact_email)),
      contact_phone = nullif(trim(proposal_contact_phone), ''),
      share_manager_operations = coalesce(proposal_share_manager_operations, false),
      entry_type = proposal_entry_type, entry_fee = proposal_entry_fee, entry_currency = 'UGX',
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
    if v_suggested_starts_at is null or v_suggested_starts_at <= now()
       or v_suggested_ends_at <= v_suggested_starts_at or v_suggested_guests < 1 then
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
    created_by, is_private, source_plan_id, share_token
  ) values (
    v_plan.title, v_plan.description, v_plan.category, v_plan.starts_at, v_plan.ends_at,
    v_plan.timezone, v_plan.location, v_plan.facility_id, v_plan.entry_fee, v_plan.entry_currency,
    v_plan.expected_guests, v_plan.expected_guests, 10, 0, false, 0, v_plan.contact_name,
    v_plan.image_url, 'draft', auth.uid(), v_plan.user_id, v_plan.is_private, v_plan.id, v_plan.share_token
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
      else 'Your event proposal “' || v_plan.title || '” has been approved and scheduled. The hotel team will decide whether to list it in Hotel Events.'
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
  if not found or v_plan.status <> 'changes_requested' then
    raise exception 'This proposal has no suggested changes to respond to';
  end if;

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
     or v_plan.suggested_ends_at <= v_plan.suggested_starts_at
     or v_plan.suggested_expected_guests < 1 then
    raise exception 'The suggested event details are no longer valid';
  end if;
  select name into v_facility_name from public.special_event_facilities
  where id = v_plan.suggested_facility_id and is_active;
  if v_facility_name is null then raise exception 'The suggested hotel facility is no longer available'; end if;

  update public.special_event_plans set
    title = v_plan.suggested_title,
    description = v_plan.suggested_description,
    category = v_plan.suggested_category,
    starts_at = v_plan.suggested_starts_at,
    ends_at = v_plan.suggested_ends_at,
    event_date = (v_plan.suggested_starts_at at time zone v_plan.timezone)::date,
    facility_id = v_plan.suggested_facility_id,
    location = v_facility_name,
    expected_guests = v_plan.suggested_expected_guests,
    status = 'scheduled', updated_at = now(),
    suggested_title = null, suggested_description = null, suggested_category = null,
    suggested_starts_at = null, suggested_ends_at = null,
    suggested_facility_id = null, suggested_expected_guests = null
  where id = v_plan.id
  returning * into v_plan;

  insert into public.special_events (
    title, description, category, starts_at, ends_at, timezone, location, facility_id,
    price, currency, capacity, ticket_type_capacity, max_tickets_per_order,
    attendees_count, featured, rating, host_name, image_url, status, organizer_id,
    created_by, is_private, source_plan_id, share_token
  ) values (
    v_plan.title, v_plan.description, v_plan.category, v_plan.starts_at, v_plan.ends_at,
    v_plan.timezone, v_plan.location, v_plan.facility_id, v_plan.entry_fee, v_plan.entry_currency,
    v_plan.expected_guests, v_plan.expected_guests, 10, 0, false, 0, v_plan.contact_name,
    v_plan.image_url, 'draft', v_plan.reviewed_by, v_plan.user_id, v_plan.is_private, v_plan.id, v_plan.share_token
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
      then 'Your private event proposal has been scheduled with the updated details.'
      else 'Your updated event proposal has been scheduled with the accepted details. The hotel team will decide whether to list it in Hotel Events.'
    end);
end;
$$;

drop function if exists public.publish_special_event_proposal(uuid, numeric, text);
create or replace function public.publish_special_event_proposal(target_plan_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.special_event_plans%rowtype;
begin
  if not public.is_special_event_platform_manager() then
    raise exception 'Only a hotel manager can publish proposed events';
  end if;
  select * into v_plan from public.special_event_plans where id = target_plan_id for update;
  if not found or v_plan.status <> 'scheduled' or v_plan.is_private
     or v_plan.published_at is not null or v_plan.special_event_id is null then
    raise exception 'This proposal is not eligible for Hotel Events';
  end if;
  update public.special_events set status = 'published', updated_at = now()
  where id = v_plan.special_event_id and source_plan_id = v_plan.id
    and is_private = false and starts_at > now();
  if not found then raise exception 'This event cannot be published'; end if;
  update public.special_event_plans set published_at = now(), updated_at = now() where id = v_plan.id;
  insert into public.notifications (user_id, event_proposal_id, type, message)
  values (v_plan.user_id, v_plan.id, 'event_published',
    'The hotel team published “' || v_plan.title || '” in Hotel Events.');
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
  v_invitation_valid boolean := false;
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
  if v_event.is_private then
    select exists (
      select 1 from public.special_event_invitations i
      join public.special_event_plans p on p.id = i.event_plan_id
      where i.id = v_booking.event_invitation_id and i.event_id = v_event.id
        and i.event_plan_id = v_event.source_plan_id and i.invitee_user_id = auth.uid()
        and i.status = 'accepted' and p.status = 'scheduled' and p.is_private
    ) into v_invitation_valid;
    if v_event.status <> 'draft' or v_event.starts_at <= now() or not v_invitation_valid then
      raise exception 'The private invitation is no longer valid';
    end if;
  elsif v_event.status not in ('draft', 'published') or v_event.starts_at <= now() then
    raise exception 'This event is no longer open for registration';
  end if;
  select v_event.capacity - coalesce(sum(quantity), 0) into v_remaining
  from public.special_event_bookings
  where event_id = v_event.id and id <> v_booking.id
    and (status = 'confirmed' or (status = 'pending' and payment_status = 'pending' and expires_at > now()));
  select t.capacity - coalesce(sum(b.quantity), 0) into v_type_remaining
  from public.special_event_ticket_types t
  left join public.special_event_bookings b on b.ticket_type_id = t.id and b.id <> v_booking.id
    and (b.status = 'confirmed' or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))
  where t.id = v_booking.ticket_type_id group by t.capacity;
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
  update public.special_event_bookings set status = 'confirmed', payment_status = 'paid',
    payment_verified_at = now(), confirmation_number = v_confirmation, ticket_code = v_ticket, updated_at = now()
  where id = v_booking.id;
  update public.special_events set attendees_count = attendees_count + v_booking.quantity, updated_at = now()
  where id = v_event.id;
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.quantity;
end;
$$;

revoke all on function public.confirm_free_special_event_booking(uuid) from public, anon;
grant execute on function public.confirm_free_special_event_booking(uuid) to authenticated;

drop function if exists public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[]);
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
  target_attendee_names text[] default null,
  target_invitation_id uuid default null,
  target_share_token uuid default null
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
  v_invitation_valid boolean := false;
  v_share_valid boolean := false;
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

  if v_event.is_private then
    select exists (
      select 1 from public.special_event_invitations i
      where i.id = target_invitation_id and i.event_id = v_event.id
        and i.event_plan_id = v_event.source_plan_id
        and i.invitee_user_id = v_user_id and i.status = 'accepted'
        and exists (
          select 1 from public.special_event_plans p
          where p.id = i.event_plan_id and p.status = 'scheduled' and p.is_private
        )
    ) into v_invitation_valid;
    if v_event.status <> 'draft' or not v_invitation_valid or target_quantity <> 1 then
      raise exception 'An accepted private invitation is required for one attendee';
    end if;
  elsif v_event.status <> 'published' then
    select exists (
      select 1 from public.special_events e
      where e.id = v_event.id and e.share_token = target_share_token
        and e.is_private = false and e.status = 'draft'
    ) into v_share_valid;
    if not v_share_valid then raise exception 'This event is not open for registration'; end if;
  end if;
  if v_event.starts_at <= now() then raise exception 'This event is no longer upcoming'; end if;

  select * into v_type
  from public.special_event_ticket_types
  where id = coalesce(target_ticket_type_id, v_event.default_ticket_type_id)
    and event_id = target_event_id and is_active
  for update;
  if not found then raise exception 'Ticket type is not available'; end if;

  select b.id, b.order_number into v_booking_id, v_order_number
  from public.special_event_bookings b
  where b.user_id = v_user_id and b.idempotency_key = target_idempotency_key;
  if found then
    return query select b.id, b.order_number, b.total_amount, b.currency
    from public.special_event_bookings b where b.id = v_booking_id;
    return;
  end if;

  if v_event.is_private then
    select b.id, b.order_number into v_booking_id, v_order_number
    from public.special_event_bookings b
    join public.special_event_invitations i on i.id = b.event_invitation_id
    where b.event_invitation_id = target_invitation_id
      and b.user_id = v_user_id and i.invitee_user_id = v_user_id
      and i.event_id = v_event.id and b.status in ('pending', 'confirmed', 'manual_review');
    if found then
      return query select b.id, b.order_number, b.total_amount, b.currency
      from public.special_event_bookings b where b.id = v_booking_id;
      return;
    end if;
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
    id, user_id, event_id, ticket_type_id, event_invitation_id, attendee_names, order_number,
    guest_first_name, guest_last_name, guest_email, guest_phone, special_requests,
    quantity, subtotal, service_fee, tax_amount, discount_amount, total_amount, currency,
    status, payment_status, confirmation_number, expires_at, idempotency_key
  ) values (
    v_booking_id, v_user_id, target_event_id, v_type.id,
    case when v_event.is_private then target_invitation_id else null end,
    coalesce(target_attendee_names, array_fill(concat_ws(' ', btrim(guest_first_name), btrim(guest_last_name)), array[target_quantity])),
    v_order_number,
    btrim(guest_first_name), btrim(guest_last_name), btrim(guest_email), nullif(btrim(guest_phone), ''), special_requests,
    target_quantity, v_subtotal, 0, 0, 0, v_subtotal, v_event.currency,
    'pending', 'pending', 'PENDING-' || v_order_number, now() + interval '15 minutes', target_idempotency_key
  );
  return query select v_booking_id, v_order_number, v_subtotal, v_event.currency;
end;
$$;

revoke all on function public.get_special_event_by_share_token(uuid) from public;
grant execute on function public.get_special_event_by_share_token(uuid) to anon, authenticated;
revoke all on function public.get_special_event_invitation_by_token(uuid) from public;
grant execute on function public.get_special_event_invitation_by_token(uuid) to anon, authenticated;
revoke all on function public.get_special_event_invitation_by_id(uuid) from public, anon;
grant execute on function public.get_special_event_invitation_by_id(uuid) to authenticated;
revoke all on function public.get_my_special_event_invitations() from public, anon;
grant execute on function public.get_my_special_event_invitations() to authenticated;
revoke all on function public.create_special_event_invitation(uuid, text) from public, anon;
grant execute on function public.create_special_event_invitation(uuid, text) to authenticated;
revoke all on function public.respond_to_special_event_invitation(uuid, boolean) from public, anon;
grant execute on function public.respond_to_special_event_invitation(uuid, boolean) to authenticated;
revoke all on function public.submit_special_event_proposal(uuid, text, text, text, timestamptz, timestamptz, text, uuid, integer, text, text, text, text, boolean, text, numeric, boolean) from public, anon;
grant execute on function public.submit_special_event_proposal(uuid, text, text, text, timestamptz, timestamptz, text, uuid, integer, text, text, text, text, boolean, text, numeric, boolean) to authenticated;
revoke all on function public.publish_special_event_proposal(uuid) from public, anon;
grant execute on function public.publish_special_event_proposal(uuid) to authenticated;
revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) from public, anon;
grant execute on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) to authenticated;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'complaint_filed', 'complaint_acknowledged', 'task_created', 'task_updated',
    'task_assigned', 'task_accepted', 'task_declined', 'task_proposed',
    'proposal_accepted', 'proposal_declined', 'proposal_updated', 'todo_created',
    'task_message', 'report_submitted', 'evidence_approved', 'issue_raised', 'issue_resolved',
    'task_flagged', 'task_approval_ready',
    'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
    'event_proposal_declined', 'event_published',
    'event_invitation_received', 'event_invitation_responded'
  ));

drop policy if exists notifications_event_proposal_insert_rpc_only on public.notifications;
create policy notifications_event_proposal_insert_rpc_only
  on public.notifications as restrictive for insert to public
  with check (type not in (
    'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
    'event_proposal_declined', 'event_published',
    'event_invitation_received', 'event_invitation_responded'
  ));

create or replace function public.protect_event_proposal_notifications()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (old.type in (
        'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
        'event_proposal_declined', 'event_published',
        'event_invitation_received', 'event_invitation_responded'
      ) or new.type in (
        'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
        'event_proposal_declined', 'event_published',
        'event_invitation_received', 'event_invitation_responded'
      ))
     and (to_jsonb(new) - 'is_read') is distinct from (to_jsonb(old) - 'is_read')
     and not (
       (to_jsonb(new) - 'is_read' - 'message') = (to_jsonb(old) - 'is_read' - 'message')
       and old.message like '%Browse Events%'
       and new.message = replace(old.message, 'Browse Events', 'Hotel Events')
     ) then
    raise exception 'Event notifications are immutable';
  end if;
  return new;
end;
$$;

update public.notifications
set message = replace(message, 'Browse Events', 'Hotel Events')
where message like '%Browse Events%';

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'special_event_invitations'
     ) then
    alter publication supabase_realtime add table public.special_event_invitations;
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
