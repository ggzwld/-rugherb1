alter table public.special_event_plans
  add column if not exists image_url text;

notify pgrst, 'reload schema';
