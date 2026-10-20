-- Sinuca de Bar: painel de números do dono, registro de acessos e exclusão de conta
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.

-- ---------- dias em que cada jogador entrou ----------
create table if not exists public.acessos (
  jogador uuid not null references auth.users (id) on delete cascade,
  dia date not null,
  primary key (jogador, dia)
);
alter table public.acessos enable row level security;
revoke all on public.acessos from anon, authenticated;

create or replace function public.cheguei() returns void
language sql security definer set search_path = public as $$
  insert into acessos (jogador, dia) select auth.uid(), (now() at time zone 'America/Sao_Paulo')::date
   where auth.uid() is not null on conflict do nothing;
$$;
grant execute on function public.cheguei() to authenticated;

-- ---------- quem pode ver o painel ----------
create table if not exists public.admins (id uuid primary key references auth.users (id) on delete cascade);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;
-- o dono do bar: a conta com o apelido Lucas
insert into public.admins (id) select id from public.perfis where lower(apelido) = 'lucas' on conflict do nothing;

create or replace function public.sou_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from admins where id = auth.uid());
$$;
grant execute on function public.sou_admin() to authenticated;

-- ---------- os números ----------
create or replace function public.painel() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date; r jsonb;
begin
  if not exists (select 1 from admins where id = auth.uid()) then raise exception 'só o dono do bar'; end if;
  with
  cad as (select id, apelido, (criado_em at time zone 'America/Sao_Paulo')::date as dia, criado_em, xp,
                 coalesce((hist#>>'{cpu,j}')::int,0) as treinos, coalesce((hist#>>'{net,j}')::int,0) as online
            from perfis),
  pf as (select p.*, from_partidas.n as partidas_n from cad p
           left join lateral (select count(*) n from partidas x where x.status = 'fim' and (x.j1 = p.id or x.j2 = p.id)) from_partidas on true),
  -- um dia "ativo" é um dia com acesso registrado, com partida online ou o dia do cadastro
  atv as (
    select jogador, dia from acessos
    union select j1, (terminada_em at time zone 'America/Sao_Paulo')::date from partidas where status = 'fim'
    union select j2, (terminada_em at time zone 'America/Sao_Paulo')::date from partidas where status = 'fim' and j2 is not null
    union select id, dia from cad),
  dias as (select generate_series(hoje - 29, hoje, interval '1 day')::date as dia),
  coorte as (select c.id, c.dia from cad c where c.dia < hoje),
  ret as (select
      count(*) filter (where c.dia <= hoje - 1) as base1,
      count(*) filter (where c.dia <= hoje - 1 and exists (select 1 from atv a where a.jogador = c.id and a.dia = c.dia + 1)) as volta1,
      count(*) filter (where c.dia <= hoje - 7) as base7,
      count(*) filter (where c.dia <= hoje - 7 and exists (select 1 from atv a where a.jogador = c.id and a.dia between c.dia + 1 and c.dia + 7)) as volta_semana
    from coorte c)
  select jsonb_build_object(
    'hoje', hoje,
    'cadastros', (select count(*) from cad),
    'cadastros_hoje', (select count(*) from cad where dia = hoje),
    'cadastros_7d', (select count(*) from cad where dia > hoje - 7),
    'jogaram', (select count(*) from pf where xp > 0 or treinos > 0 or online > 0 or partidas_n > 0),
    'jogaram_online', (select count(*) from pf where partidas_n > 0 or online > 0),
    'ativos_hoje', (select count(distinct jogador) from atv where dia = hoje),
    'ativos_7d', (select count(distinct jogador) from atv where dia > hoje - 7),
    'ativos_30d', (select count(distinct jogador) from atv where dia > hoje - 30),
    'partidas_online', (select count(*) from partidas where status = 'fim'),
    'partidas_online_7d', (select count(*) from partidas where status = 'fim' and terminada_em > now() - interval '7 days'),
    'treinos', (select coalesce(sum(treinos),0) from cad),
    'jogando_agora', (select count(*) from partidas where status = 'jogando'),
    'esperando_agora', (select count(*) from partidas where status = 'esperando'),
    'retorno', (select jsonb_build_object('base1', base1, 'volta1', volta1, 'base7', base7, 'volta_semana', volta_semana) from ret),
    'por_dia', (select jsonb_agg(jsonb_build_object(
        'dia', d.dia,
        'cadastros', (select count(*) from cad where cad.dia = d.dia),
        'ativos', (select count(distinct jogador) from atv where atv.dia = d.dia),
        'partidas', (select count(*) from partidas where status = 'fim' and (terminada_em at time zone 'America/Sao_Paulo')::date = d.dia)
      ) order by d.dia) from dias d),
    'bares', (select coalesce(jsonb_object_agg(bar, n), '{}'::jsonb) from (select bar, count(*) n from partidas where status = 'fim' group by bar) b),
    'top', (select coalesce(jsonb_agg(x order by x.jogos desc), '[]'::jsonb) from (
        select apelido, treinos + online as jogos, treinos, online, xp from cad order by treinos + online desc, xp desc limit 10) x),
    'ultimos', (select coalesce(jsonb_agg(x order by x.criado_em desc), '[]'::jsonb) from (
        select apelido, criado_em, xp, treinos + online as jogos from cad order by criado_em desc limit 10) x)
  ) into r;
  return r;
end $$;
grant execute on function public.painel() to authenticated;

-- ---------- excluir a própria conta (LGPD) ----------
create or replace function public.excluir_conta() returns void
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); m partidas%rowtype;
begin
  if me is null then raise exception 'sem login'; end if;
  -- mesas abertas: devolve as fichas antes de sair
  for m in select * from partidas where (j1 = me or j2 = me) and status in ('esperando','jogando') loop
    perform _cancelar(m.id);
  end loop;
  delete from auth.users where id = me;
end $$;
grant execute on function public.excluir_conta() to authenticated;
