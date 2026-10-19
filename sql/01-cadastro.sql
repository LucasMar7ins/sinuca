-- Sinuca de Bar: banco de dados dos jogadores
-- Cole tudo isto no Supabase em SQL Editor > New query e clique em Run.

create table if not exists public.perfis (
  id uuid primary key references auth.users (id) on delete cascade,
  apelido text not null,
  dados jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint apelido_tamanho check (char_length(apelido) between 3 and 16)
);

-- apelido único sem diferenciar maiúscula de minúscula
create unique index if not exists perfis_apelido_unico on public.perfis (lower(apelido));

-- cada jogador só enxerga e altera o próprio perfil
grant select, insert, update on public.perfis to authenticated;
alter table public.perfis enable row level security;

drop policy if exists "ver o proprio perfil" on public.perfis;
create policy "ver o proprio perfil" on public.perfis
  for select using (auth.uid() = id);

drop policy if exists "criar o proprio perfil" on public.perfis;
create policy "criar o proprio perfil" on public.perfis
  for insert with check (auth.uid() = id);

drop policy if exists "atualizar o proprio perfil" on public.perfis;
create policy "atualizar o proprio perfil" on public.perfis
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- cria o perfil sozinho quando alguém se cadastra
create or replace function public.novo_jogador()
returns trigger language plpgsql security definer set search_path = public as $$
declare ap text := coalesce(nullif(trim(new.raw_user_meta_data->>'apelido'), ''),
                            'Jogador' || substr(new.id::text, 1, 4));
begin
  if exists (select 1 from public.perfis where lower(apelido) = lower(ap)) then
    ap := left(ap, 11) || substr(new.id::text, 1, 4);
  end if;
  insert into public.perfis (id, apelido) values (new.id, ap)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists ao_criar_conta on auth.users;
create trigger ao_criar_conta after insert on auth.users
  for each row execute function public.novo_jogador();

-- a tela de cadastro pergunta se o apelido está livre antes de criar a conta
create or replace function public.apelido_livre(nome text)
returns boolean language sql security definer set search_path = public stable as $$
  select not exists (select 1 from public.perfis where lower(apelido) = lower(trim(nome)));
$$;
grant execute on function public.apelido_livre(text) to anon, authenticated;
