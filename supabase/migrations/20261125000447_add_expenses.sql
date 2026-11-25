create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  amount numeric(14, 0) not null check (amount > 0 and amount <= 99999999999999),
  date timestamptz not null default now()
);

create index expenses_user_date_idx on public.expenses (user_id, date);
alter table public.expenses enable row level security;
grant select, insert on table public.expenses to authenticated;

create policy "Owners can view their expenses"
  on public.expenses for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Owners can add their expenses"
  on public.expenses for insert to authenticated
  with check ((select auth.uid()) = user_id);
