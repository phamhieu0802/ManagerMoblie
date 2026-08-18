-- Add commission_rate column to profiles (used for technician commission calculations)
alter table public.profiles
  add column if not exists commission_rate numeric(5,2) default 0;
