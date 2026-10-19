-- Sinuca de Bar: amigos, mesa particular e revanche
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.

-- ---------- mesa particular e revanche ----------
alter table public.partidas add column if not exists privada boolean not null default false;
alter table public.partidas add column if not exists codigo text;
alter table public.partidas add column if not exists rev_pedido smallint;
alter table public.partidas add column if not exists revanche uuid;
create index if not exists partidas_codigo on public.partidas (codigo) where status = 'esperando';

-- Jogar agora: não entra em mesa particular
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
              where partidas.bar = sentar.bar and status = 'esperando' and j1 <> me and not privada
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

-- entrar numa mesa pública específica
create or replace function public.entrar(pid uuid, patente text default null)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; ap text;
begin
  if me is null then raise exception 'sem login'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then raise exception 'você já está numa mesa'; end if;
  select * into m from partidas where id = pid for update;
  if not found or m.status <> 'esperando' or m.j1 = me or m.privada then raise exception 'mesa não está mais livre'; end if;
  select apelido into ap from perfis where id = me;
  m := _comecar(pid, me, ap, patente);
  if m.id is null then raise exception 'mesa não está mais livre'; end if;
  return m;
end $$;

-- abre uma mesa só para quem tiver o código
create or replace function public.abrir_particular(bar text, patente text default null)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); f int := ficha_do_bar(bar); ap text; sal int; m partidas%rowtype; cod text; letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if me is null then raise exception 'sem login'; end if;
  if f is null then raise exception 'bar inválido'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then return m; end if;
  select apelido, saldo into ap, sal from perfis where id = me;
  if sal < f then raise exception 'saldo insuficiente'; end if;
  loop
    cod := '';
    for i in 1..5 loop cod := cod || substr(letras, 1 + floor(random() * length(letras))::int, 1); end loop;
    exit when not exists (select 1 from partidas where codigo = cod and status = 'esperando');
  end loop;
  insert into partidas (bar, ficha, j1, apelido1, patente1, privada, codigo)
  values (bar, f, me, ap, patente, true, cod) returning * into m;
  return m;
end $$;

-- entra na mesa particular pelo código
create or replace function public.entrar_codigo(cod text, patente text default null)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; ap text;
begin
  if me is null then raise exception 'sem login'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then raise exception 'você já está numa mesa'; end if;
  select * into m from partidas where codigo = upper(trim(cod)) and status = 'esperando' order by criada_em desc limit 1 for update;
  if not found then raise exception 'código não encontrado'; end if;
  if m.j1 = me then raise exception 'essa mesa é sua'; end if;
  select apelido into ap from perfis where id = me;
  m := _comecar(m.id, me, ap, patente);
  if m.id is null then raise exception 'código não encontrado'; end if;
  return m;
end $$;

-- revanche: os dois pedem; no segundo pedido a nova partida começa (quem perdeu a vez de abrir, abre)
create or replace function public.revanche(pid uuid)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; n partidas%rowtype; eu smallint; s1 int; s2 int;
begin
  select * into m from partidas where id = pid for update;
  if not found or (m.j1 <> me and m.j2 is distinct from me) then raise exception 'mesa inválida'; end if;
  if m.revanche is not null then select * into n from partidas where id = m.revanche; return n; end if;
  if m.status <> 'fim' or m.terminada_em < now() - interval '5 minutes' then raise exception 'revanche expirou'; end if;
  if exists (select 1 from partidas where (j1 = me or j2 = me) and status in ('esperando','jogando')) then raise exception 'você já está numa mesa'; end if;
  eu := case when m.j1 = me then 0 else 1 end;
  if m.rev_pedido is null or m.rev_pedido = eu then
    update partidas set rev_pedido = eu where id = pid returning * into m;
    return m;
  end if;
  if m.ficha > 0 then
    select saldo into s1 from perfis where id = m.j1 for update;
    select saldo into s2 from perfis where id = m.j2 for update;
    if s1 < m.ficha or s2 < m.ficha then raise exception 'saldo insuficiente'; end if;
    update perfis set saldo = saldo - m.ficha where id in (m.j1, m.j2);
  end if;
  insert into partidas (bar, ficha, j1, j2, apelido1, apelido2, patente1, patente2, privada, status, iniciada_em, sinal1, sinal2)
  values (m.bar, m.ficha, m.j2, m.j1, m.apelido2, m.apelido1, m.patente2, m.patente1, true, 'jogando', now(), now(), now())
  returning * into n;
  update partidas set revanche = n.id where id = pid;
  return n;
end $$;

-- lobby sem as mesas particulares
create or replace function public.lobby() returns jsonb
language plpgsql security definer set search_path = public as $$
declare mesas jsonb; feed jsonb;
begin
  perform _limpar();
  select coalesce(jsonb_agg(to_jsonb(x) order by x.criada_em), '[]'::jsonb) into mesas from (
    select id, bar, ficha, status, apelido1, apelido2, patente1, patente2, criada_em
      from partidas where status in ('esperando','jogando') and not (privada and status = 'esperando')) x;
  select coalesce(jsonb_agg(to_jsonb(y) order by y.terminada_em desc), '[]'::jsonb) into feed from (
    select bar, ficha, premio, vencedor, apelido1, apelido2, terminada_em
      from partidas where status = 'fim' order by terminada_em desc limit 6) y;
  return jsonb_build_object('mesas', mesas, 'feed', feed, 'agora', now());
end $$;

-- ---------- amigos ----------
create table if not exists public.amigos (
  dono uuid not null references auth.users (id) on delete cascade,
  amigo uuid not null references auth.users (id) on delete cascade,
  criado_em timestamptz not null default now(),
  primary key (dono, amigo)
);
alter table public.amigos enable row level security;
revoke all on public.amigos from anon, authenticated;

create or replace function public.adicionar_amigo(apelido text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a perfis%rowtype; n int;
begin
  if me is null then raise exception 'sem login'; end if;
  select * into a from perfis where lower(perfis.apelido) = lower(trim(adicionar_amigo.apelido));
  if not found then raise exception 'apelido não encontrado'; end if;
  if a.id = me then raise exception 'esse é você'; end if;
  select count(*) into n from amigos where dono = me;
  if n >= 100 then raise exception 'limite de amigos'; end if;
  insert into amigos (dono, amigo) values (me, a.id) on conflict do nothing;
  return jsonb_build_object('id', a.id, 'apelido', a.apelido, 'xp', coalesce((a.dados->>'xp')::int, 0));
end $$;

create or replace function public.remover_amigo(amigo uuid) returns void
language sql security definer set search_path = public as $$
  delete from amigos where dono = auth.uid() and amigos.amigo = remover_amigo.amigo;
$$;

-- meus amigos e quem me adicionou
create or replace function public.meus_amigos() returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'apelido', p.apelido, 'xp', coalesce((p.dados->>'xp')::int, 0),
           'meu', exists (select 1 from amigos x where x.dono = auth.uid() and x.amigo = p.id)) order by lower(p.apelido)), '[]'::jsonb)
    from perfis p
   where p.id in (select amigo from amigos where dono = auth.uid()
                  union select dono from amigos where amigo = auth.uid());
$$;

grant execute on function public.abrir_particular(text, text) to authenticated;
grant execute on function public.entrar_codigo(text, text) to authenticated;
grant execute on function public.revanche(uuid) to authenticated;
grant execute on function public.adicionar_amigo(text) to authenticated;
grant execute on function public.remover_amigo(uuid) to authenticated;
grant execute on function public.meus_amigos() to authenticated;
