-- Sinuca de Bar: pontos no servidor e mesas online
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.

-- ---------- saldo protegido ----------
alter table public.perfis add column if not exists saldo integer not null default 0;
alter table public.perfis add column if not exists ctl jsonb not null default '{}'::jsonb;
alter table public.perfis add column if not exists saldo_migrado boolean not null default false;

-- o navegador só pode mexer no "dados" (tacos, XP, ajustes); saldo e controles só pelas funções abaixo
revoke insert, update, delete on public.perfis from anon, authenticated;
grant insert (id, apelido, dados) on public.perfis to authenticated;
grant update (dados, atualizado_em) on public.perfis to authenticated;

-- traz os pontos que já estavam salvos (uma vez só por conta)
update public.perfis
   set saldo = least(greatest(coalesce((dados->>'pts')::int, 0), 0), 5000), saldo_migrado = true
 where not saldo_migrado;

create or replace function public._hoje() returns text language sql stable as $$
  select to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
$$;

-- zera os contadores diários quando muda o dia
create or replace function public._ctl_dia(c jsonb) returns jsonb language sql stable as $$
  select case when coalesce(c->>'dia','') = public._hoje() then c
              else (c - 'cpu' - 'desafio' - 'caixa_gratis' - 'calcada') || jsonb_build_object('dia', public._hoje()) end;
$$;

create or replace function public.meu_saldo() returns integer
language sql security definer set search_path = public stable as $$
  select saldo from perfis where id = auth.uid();
$$;

-- ganhos e gastos fora do online, com limites para ninguém inventar pontos
create or replace function public.pontos(motivo text, valor integer, ref text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p perfis%rowtype;
  c jsonb;
  usado int;
  preco int;
  premio int;
begin
  if me is null then raise exception 'sem login'; end if;
  select * into p from perfis where id = me for update;
  if not found then raise exception 'perfil não encontrado'; end if;
  c := _ctl_dia(p.ctl);

  if motivo = 'cpu' then
    if valor not in (5,10,15,20) then raise exception 'valor inválido'; end if;
    if (c ? 'cpu_em') and now() - (c->>'cpu_em')::timestamptz < interval '40 seconds' then raise exception 'rápido demais'; end if;
    usado := coalesce((c->>'cpu')::int, 0);
    if usado + valor > 400 then raise exception 'limite do dia'; end if;
    c := c || jsonb_build_object('cpu', usado + valor, 'cpu_em', now());
  elsif motivo = 'desafio' then
    if valor not in (5,10,15) then raise exception 'valor inválido'; end if;
    usado := coalesce((c->>'desafio')::int, 0);
    if usado + valor > 55 then raise exception 'limite do dia'; end if;
    c := c || jsonb_build_object('desafio', usado + valor);
  elsif motivo = 'patente' then
    premio := case ref when '2' then 20 when '4' then 50 when '8' then 100 when '13' then 200 when '14' then 300 else 0 end;
    if premio = 0 or valor <> premio then raise exception 'valor inválido'; end if;
    if coalesce(c->'patentes','[]'::jsonb) ? ref then raise exception 'já recebido'; end if;
    c := c || jsonb_build_object('patentes', coalesce(c->'patentes','[]'::jsonb) || to_jsonb(ref));
  elsif motivo = 'caixa' then
    preco := case ref when 'boteco' then 100 when 'prata' then 250 when 'ouro' then 500 when 'gratis' then 0 else null end;
    if preco is null then raise exception 'caixa inválida'; end if;
    if valor not in (-preco, -preco+5, -preco+15, -preco+40) then raise exception 'valor inválido'; end if;
    if preco = 0 then
      usado := coalesce((c->>'caixa_gratis')::int, 0);
      if usado + valor > 120 then raise exception 'limite do dia'; end if;
      c := c || jsonb_build_object('caixa_gratis', usado + valor);
    end if;
  elsif motivo = 'fiado' then
    if p.saldo >= 10 then raise exception 'ainda tem ficha'; end if;
    if coalesce(c->>'fiado','') = _hoje() then raise exception 'fiado já usado hoje'; end if;
    valor := 10;
    c := c || jsonb_build_object('fiado', _hoje());
  else
    raise exception 'motivo inválido';
  end if;

  if p.saldo + valor < 0 then raise exception 'saldo insuficiente'; end if;
  update perfis set saldo = saldo + valor, ctl = c where id = me returning saldo into usado;
  return usado;
end $$;

-- ---------- bares e partidas ----------
create or replace function public.ficha_do_bar(bar text) returns integer language sql immutable as $$
  select case bar when 'calcada' then 0 when 'boteco' then 10 when 'esquina' then 25 when 'centro' then 50 else null end;
$$;

create table if not exists public.partidas (
  id uuid primary key default gen_random_uuid(),
  bar text not null,
  ficha integer not null,
  status text not null default 'esperando',     -- esperando, jogando, fim, cancelada
  j1 uuid not null references auth.users (id) on delete cascade,
  j2 uuid references auth.users (id) on delete cascade,
  apelido1 text not null,
  apelido2 text,
  patente1 text,
  patente2 text,
  vencedor smallint,                             -- 0 = j1, 1 = j2
  premio integer,
  pedido smallint,                               -- quem disse que ganhou e espera confirmação
  sinal1 timestamptz not null default now(),
  sinal2 timestamptz,
  criada_em timestamptz not null default now(),
  iniciada_em timestamptz,
  terminada_em timestamptz
);
create index if not exists partidas_abertas on public.partidas (bar, status) where status in ('esperando','jogando');
create index if not exists partidas_fim on public.partidas (terminada_em desc) where status = 'fim';

alter table public.partidas enable row level security;
revoke insert, update, delete on public.partidas from anon, authenticated;
grant select on public.partidas to authenticated;
drop policy if exists "ver mesas" on public.partidas;
create policy "ver mesas" on public.partidas for select to authenticated using (true);

-- avisa o navegador quando uma mesa muda
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'partidas') then
    execute 'alter publication supabase_realtime add table public.partidas';
  end if;
end $$;

-- devolve as fichas e fecha a mesa
create or replace function public._cancelar(pid uuid) returns void language plpgsql security definer set search_path = public as $$
declare m partidas%rowtype;
begin
  select * into m from partidas where id = pid for update;
  if not found or m.status in ('fim','cancelada') then return; end if;
  if m.status = 'jogando' and m.ficha > 0 then
    update perfis set saldo = saldo + m.ficha where id in (m.j1, m.j2);
  end if;
  update partidas set status = 'cancelada', terminada_em = now() where id = pid;
end $$;

-- paga quem venceu: pote menos 10% do Seu Zé; na Calçada, 5 pontos da casa (até 100 por dia)
create or replace function public._pagar(pid uuid, v smallint) returns void language plpgsql security definer set search_path = public as $$
declare m partidas%rowtype; ganhador uuid; valor int := 0; c jsonb; usado int;
begin
  select * into m from partidas where id = pid for update;
  if not found or m.status <> 'jogando' then return; end if;
  ganhador := case when v = 0 then m.j1 else m.j2 end;
  if m.ficha > 0 then
    valor := m.ficha * 2 - (m.ficha * 2) / 10;
  else
    select _ctl_dia(ctl) into c from perfis where id = ganhador for update;
    usado := coalesce((c->>'calcada')::int, 0);
    if usado + 5 <= 100 then
      valor := 5;
      update perfis set ctl = c || jsonb_build_object('calcada', usado + 5) where id = ganhador;
    end if;
  end if;
  if valor > 0 then update perfis set saldo = saldo + valor where id = ganhador; end if;
  update partidas set status = 'fim', vencedor = v, premio = valor, pedido = null, terminada_em = now() where id = pid;
end $$;

-- limpeza: mesas esperando abandonadas e partidas em que os dois sumiram
create or replace function public._limpar() returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update partidas set status = 'cancelada', terminada_em = now()
   where status = 'esperando' and sinal1 < now() - interval '45 seconds';
  for r in select id from partidas
            where status = 'jogando'
              and sinal1 < now() - interval '5 minutes'
              and coalesce(sinal2, iniciada_em) < now() - interval '5 minutes' loop
    perform _cancelar(r.id);
  end loop;
end $$;

-- a mesa em que eu estou agora (para voltar depois de cair)
create or replace function public.minha_partida() returns partidas
language sql security definer set search_path = public stable as $$
  select * from partidas
   where (j1 = auth.uid() or j2 = auth.uid()) and status in ('esperando','jogando')
   order by criada_em desc limit 1;
$$;

-- começa a partida: tira a ficha dos dois
create or replace function public._comecar(pid uuid, me uuid, ap text, pat text) returns partidas
language plpgsql security definer set search_path = public as $$
declare m partidas%rowtype; s1 int; s2 int;
begin
  select * into m from partidas where id = pid for update;
  if m.ficha > 0 then
    select saldo into s1 from perfis where id = m.j1 for update;
    select saldo into s2 from perfis where id = me for update;
    if s2 < m.ficha then raise exception 'saldo insuficiente'; end if;
    if s1 < m.ficha then
      update partidas set status = 'cancelada', terminada_em = now() where id = pid;
      return null;
    end if;
    update perfis set saldo = saldo - m.ficha where id in (m.j1, me);
  end if;
  update partidas set j2 = me, apelido2 = ap, patente2 = pat, status = 'jogando',
         iniciada_em = now(), sinal1 = now(), sinal2 = now()
   where id = pid returning * into m;
  return m;
end $$;

-- Jogar agora: senta com quem está esperando ou abre uma mesa nova
create or replace function public.sentar(bar text, patente text default null, nova boolean default false)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); f int := ficha_do_bar(bar); ap text; sal int; m partidas%rowtype; r record;
begin
  if me is null then raise exception 'sem login'; end if;
  if f is null then raise exception 'bar inválido'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then return m; end if;
  select apelido, saldo into ap, sal from perfis where id = me;
  if sal < f then raise exception 'saldo insuficiente'; end if;
  if not nova then
    for r in select id from partidas
              where partidas.bar = sentar.bar and status = 'esperando' and j1 <> me
                and sinal1 > now() - interval '30 seconds'
              order by criada_em
              for update skip locked loop
      m := _comecar(r.id, me, ap, patente);
      if m.id is not null then return m; end if;
    end loop;
  end if;
  insert into partidas (bar, ficha, j1, apelido1, patente1) values (bar, f, me, ap, patente) returning * into m;
  return m;
end $$;

-- entrar numa mesa específica que tem alguém esperando
create or replace function public.entrar(pid uuid, patente text default null)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; ap text;
begin
  if me is null then raise exception 'sem login'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then raise exception 'você já está numa mesa'; end if;
  select * into m from partidas where id = pid for update;
  if not found or m.status <> 'esperando' or m.j1 = me then raise exception 'mesa não está mais livre'; end if;
  select apelido into ap from perfis where id = me;
  m := _comecar(pid, me, ap, patente);
  if m.id is null then raise exception 'mesa não está mais livre'; end if;
  return m;
end $$;

-- sair da mesa: esperando = cancela; jogando = entrega a partida
create or replace function public.levantar(pid uuid) returns partidas
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype;
begin
  select * into m from partidas where id = pid for update;
  if not found or (m.j1 <> me and m.j2 is distinct from me) then raise exception 'mesa inválida'; end if;
  if m.status = 'esperando' then perform _cancelar(pid);
  elsif m.status = 'jogando' then perform _pagar(pid, (case when m.j1 = me then 1 else 0 end)::smallint);
  end if;
  select * into m from partidas where id = pid;
  return m;
end $$;

-- "ainda estou aqui" a cada 10 segundos
create or replace function public.sinal(pid uuid) returns partidas
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype;
begin
  update partidas set sinal1 = case when j1 = me then now() else sinal1 end,
                      sinal2 = case when j2 = me then now() else sinal2 end
   where id = pid and (j1 = me or j2 = me) returning * into m;
  return m;
end $$;

-- resultado: quem admite a derrota fecha na hora; quem diz que ganhou precisa da confirmação
-- do outro, ou que o outro esteja sumido há mais de 60 segundos
drop function if exists public.resultado(uuid, smallint);
create or replace function public.resultado(pid uuid, vencedor integer) returns partidas
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; eu smallint; sinal_outro timestamptz;
begin
  select * into m from partidas where id = pid for update;
  if not found or (m.j1 <> me and m.j2 is distinct from me) then raise exception 'mesa inválida'; end if;
  if m.status <> 'jogando' then return m; end if;
  eu := case when m.j1 = me then 0 else 1 end;
  sinal_outro := case when eu = 0 then m.sinal2 else m.sinal1 end;
  if vencedor <> eu then
    perform _pagar(pid, vencedor::smallint);
  elsif m.pedido is not null and m.pedido <> eu then
    perform _cancelar(pid);                      -- os dois dizem que ganharam: devolve as fichas
  elsif sinal_outro < now() - interval '60 seconds' then
    perform _pagar(pid, eu);
  else
    update partidas set pedido = eu where id = pid;
  end if;
  select * into m from partidas where id = pid;
  return m;
end $$;

-- lista do lobby: mesas abertas e últimas partidas
create or replace function public.lobby() returns jsonb
language plpgsql security definer set search_path = public as $$
declare mesas jsonb; feed jsonb;
begin
  perform _limpar();
  select coalesce(jsonb_agg(to_jsonb(x) order by x.criada_em), '[]'::jsonb) into mesas from (
    select id, bar, ficha, status, apelido1, apelido2, patente1, patente2, criada_em
      from partidas where status in ('esperando','jogando')) x;
  select coalesce(jsonb_agg(to_jsonb(y) order by y.terminada_em desc), '[]'::jsonb) into feed from (
    select bar, ficha, premio, vencedor, apelido1, apelido2, terminada_em
      from partidas where status = 'fim' order by terminada_em desc limit 6) y;
  return jsonb_build_object('mesas', mesas, 'feed', feed, 'agora', now());
end $$;

grant execute on function public.meu_saldo() to authenticated;
grant execute on function public.pontos(text, integer, text) to authenticated;
grant execute on function public.minha_partida() to authenticated;
grant execute on function public.sentar(text, text, boolean) to authenticated;
grant execute on function public.entrar(uuid, text) to authenticated;
grant execute on function public.levantar(uuid) to authenticated;
grant execute on function public.sinal(uuid) to authenticated;
grant execute on function public.resultado(uuid, integer) to authenticated;
grant execute on function public.lobby() to authenticated;
revoke execute on function public._cancelar(uuid) from public, anon, authenticated;
revoke execute on function public._pagar(uuid, smallint) from public, anon, authenticated;
revoke execute on function public._limpar() from public, anon, authenticated;
revoke execute on function public._comecar(uuid, uuid, text, text) from public, anon, authenticated;
