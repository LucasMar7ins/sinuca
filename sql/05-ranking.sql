-- Sinuca de Bar: ranking semanal ("Moral no bar"), XP no servidor e fiscal de tacada
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.

-- ---------- XP guardado no servidor ----------
alter table public.perfis add column if not exists xp integer not null default 0;
alter table public.perfis add column if not exists xp_migrado boolean not null default false;

-- traz a XP que já estava salva no aparelho (uma vez só por conta)
update public.perfis
   set xp = least(greatest(coalesce((dados->>'xp')::int, 0), 0), 11000), xp_migrado = true
 where not xp_migrado;

-- contadores diários: agora inclui a XP do treino
create or replace function public._ctl_dia(c jsonb) returns jsonb language sql stable as $$
  select case when coalesce(c->>'dia','') = public._hoje() then c
              else (c - 'cpu' - 'desafio' - 'caixa_gratis' - 'calcada' - 'xp_treino') || jsonb_build_object('dia', public._hoje()) end;
$$;

-- XP mínima de cada patente (igual ao jogo)
create or replace function public._patente(x integer) returns integer language sql immutable as $$
  select count(*)::int - 1 from unnest(array[0,100,250,450,700,1000,1400,1900,2500,3200,4000,5000,6500,8500,11000]) v where x >= v;
$$;

-- soma XP e entrega os pontos de patente que o jogador alcançou
create or replace function public._dar_xp(quem uuid, n integer) returns integer
language plpgsql security definer set search_path = public as $$
declare p perfis%rowtype; antes int; depois int; k int; c jsonb; premio int; ganho int := 0;
begin
  select * into p from perfis where id = quem for update;
  if not found then return 0; end if;
  antes := _patente(p.xp); depois := _patente(p.xp + n);
  c := p.ctl;
  for k in antes + 1 .. depois loop
    premio := case k when 2 then 20 when 4 then 50 when 8 then 100 when 13 then 200 when 14 then 300 else 0 end;
    if premio > 0 and not (coalesce(c->'patentes','[]'::jsonb) ? k::text) then
      c := c || jsonb_build_object('patentes', coalesce(c->'patentes','[]'::jsonb) || to_jsonb(k::text));
      ganho := ganho + premio;
    end if;
  end loop;
  update perfis set xp = xp + n, saldo = saldo + ganho, ctl = c where id = quem returning xp into depois;
  return depois;
end $$;

-- XP do treino contra o Seu Zé: o servidor decide quanto vale
create or replace function public.xp_treino(nivel integer, venceu boolean, limpa boolean default false)
returns integer language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p perfis%rowtype; c jsonb; n int; usado int;
begin
  if me is null then raise exception 'sem login'; end if;
  if nivel not between 0 and 2 then raise exception 'nível inválido'; end if;
  select * into p from perfis where id = me for update;
  c := _ctl_dia(p.ctl);
  if (c ? 'xp_em') and now() - (c->>'xp_em')::timestamptz < interval '30 seconds' then return p.xp; end if;
  n := case when venceu then (array[20,35,50])[nivel + 1] + case when limpa then 10 else 0 end else 10 end;
  usado := coalesce((c->>'xp_treino')::int, 0);
  if usado + n > 1200 then return p.xp; end if;          -- teto diário do treino
  update perfis set ctl = c || jsonb_build_object('xp_treino', usado + n, 'xp_em', now()) where id = me;
  return _dar_xp(me, n);
end $$;
grant execute on function public.xp_treino(integer, boolean, boolean) to authenticated;

-- pontos: a patente agora é entregue pelo servidor; aqui só aceita se a XP já chegou lá
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
    if _patente(p.xp) < ref::int then raise exception 'patente ainda não alcançada'; end if;
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
  elsif motivo = 'icone' then
    preco := case ref when 'chope' then 60 when 'tampinha' then 60 when 'tacada' then 80 when 'triangulo' then 100
                      when 'domino' then 100 when 'espeto' then 120 when 'neon' then 150 when 'jukebox' then 150
                      when 'seuze' then 300 else null end;
    if preco is null or valor <> -preco then raise exception 'valor inválido'; end if;
    if coalesce(c->'icones','[]'::jsonb) ? ref then raise exception 'já comprado'; end if;
    c := c || jsonb_build_object('icones', coalesce(c->'icones','[]'::jsonb) || to_jsonb(ref));
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
grant execute on function public.pontos(text, integer, text) to authenticated;

-- ---------- ranking semanal ----------
alter table public.partidas add column if not exists suspeita smallint;      -- quem avisou que a mesa não bateu (0 = j1, 1 = j2)
alter table public.partidas add column if not exists ranqueada boolean;
alter table public.partidas add column if not exists moral1 integer;         -- quanto cada um ganhou ou perdeu de moral
alter table public.partidas add column if not exists moral2 integer;

create table if not exists public.ranking (
  semana date not null,
  jogador uuid not null references auth.users (id) on delete cascade,
  moral integer not null default 1000,
  j integer not null default 0,
  v integer not null default 0,
  atualizado timestamptz not null default now(),
  primary key (semana, jogador)
);
create index if not exists ranking_ordem on public.ranking (semana, moral desc);
alter table public.ranking enable row level security;
revoke insert, update, delete on public.ranking from anon, authenticated;
grant select on public.ranking to authenticated;
drop policy if exists "ver ranking" on public.ranking;
create policy "ver ranking" on public.ranking for select to authenticated using (true);

-- a semana começa segunda 0h, horário de Brasília
create or replace function public._semana() returns date language sql stable as $$
  select date_trunc('week', now() at time zone 'America/Sao_Paulo')::date;
$$;

-- campeão de uma semana: mais moral, com pelo menos 5 partidas
create or replace function public._campeao(s date) returns uuid language sql stable security definer set search_path = public as $$
  select jogador from ranking where semana = s and j >= 5 order by moral desc, v desc, atualizado asc limit 1;
$$;

-- conta a partida no ranking (chamada quando a partida termina)
create or replace function public._ranquear(pid uuid) returns void language plpgsql security definer set search_path = public as $$
declare m partidas%rowtype; s date := _semana(); gw uuid; gl uuid; rw int; rl int; d int; jogos int;
begin
  select * into m from partidas where id = pid for update;
  if not found or m.status <> 'fim' or m.ranqueada is not null or m.j2 is null then return; end if;
  gw := case when m.vencedor = 0 then m.j1 else m.j2 end;
  gl := case when m.vencedor = 0 then m.j2 else m.j1 end;
  -- contra o mesmo adversário, só as 3 primeiras do dia contam
  select count(*) into jogos from partidas
   where ranqueada and least(j1, j2) = least(m.j1, m.j2) and greatest(j1, j2) = greatest(m.j1, m.j2)
     and (terminada_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
  if jogos >= 3 then update partidas set ranqueada = false where id = pid; return; end if;

  insert into ranking (semana, jogador) values (s, gw), (s, gl) on conflict do nothing;
  select moral into rw from ranking where semana = s and jogador = gw for update;
  select moral into rl from ranking where semana = s and jogador = gl for update;
  d := greatest(1, round(32 * (1 - 1 / (1 + power(10, (rl - rw) / 400.0))))::int);

  if m.suspeita is null then
    update ranking set moral = moral + d, j = j + 1, v = v + 1, atualizado = now() where semana = s and jogador = gw;
    update ranking set moral = moral - d, j = j + 1, atualizado = now() where semana = s and jogador = gl;
    update partidas set ranqueada = true,
      moral1 = case when m.vencedor = 0 then d else -d end,
      moral2 = case when m.vencedor = 1 then d else -d end where id = pid;
  elsif m.suspeita <> m.vencedor then
    -- quem avisou perdeu: a derrota dele conta, o vencedor não ganha nada
    update ranking set moral = moral - d, j = j + 1, atualizado = now() where semana = s and jogador = gl;
    update partidas set ranqueada = true,
      moral1 = case when m.vencedor = 0 then 0 else -d end,
      moral2 = case when m.vencedor = 1 then 0 else -d end where id = pid;
  else
    -- quem avisou ganhou: ninguém ganha nem perde moral
    update partidas set ranqueada = false, moral1 = 0, moral2 = 0 where id = pid;
  end if;
end $$;

-- pagamento da partida: agora também dá XP e conta no ranking
create or replace function public._pagar(pid uuid, v smallint) returns void language plpgsql security definer set search_path = public as $$
declare m partidas%rowtype; ganhador uuid; perdedor uuid; valor int := 0; c jsonb; usado int;
begin
  select * into m from partidas where id = pid for update;
  if not found or m.status <> 'jogando' then return; end if;
  ganhador := case when v = 0 then m.j1 else m.j2 end;
  perdedor := case when v = 0 then m.j2 else m.j1 end;
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
  perform _dar_xp(ganhador, 40);
  if perdedor is not null then perform _dar_xp(perdedor, 10); end if;
  perform _ranquear(pid);
end $$;

-- fiscal: o aparelho do adversário avisa quando a tacada recebida não bate com a que ele refez
create or replace function public.suspeita(pid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype;
begin
  select * into m from partidas where id = pid for update;
  if not found or (m.j1 <> me and m.j2 is distinct from me) or m.status <> 'jogando' or m.suspeita is not null then return; end if;
  update partidas set suspeita = case when m.j1 = me then 0 else 1 end where id = pid;
end $$;
grant execute on function public.suspeita(uuid) to authenticated;

-- minha conta: XP, se sou o campeão da semana passada
create or replace function public.minha_conta() returns jsonb
language sql security definer set search_path = public stable as $$
  select jsonb_build_object('xp', p.xp, 'saldo', p.saldo,
           'campeao', public._campeao(public._semana() - 7) = p.id)
    from perfis p where p.id = auth.uid();
$$;
grant execute on function public.minha_conta() to authenticated;

-- a tabela do ranking da semana
create or replace function public.ranking_semana() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare s date := _semana(); me uuid := auth.uid(); camp uuid := _campeao(_semana() - 7); lista jsonb; eu jsonb;
begin
  with t as (
    select r.jogador, r.moral, r.j, r.v, p.apelido, p.xp, coalesce(p.dados->>'ico', 'oito') as ico,
           row_number() over (order by r.moral desc, r.v desc, r.atualizado asc) as pos
      from ranking r join perfis p on p.id = r.jogador where r.semana = s)
  select coalesce(jsonb_agg(jsonb_build_object('pos', pos, 'id', jogador, 'apelido', apelido, 'moral', moral, 'j', j, 'v', v, 'xp', xp, 'ico', ico) order by pos) filter (where pos <= 50), '[]'::jsonb),
         (select to_jsonb(x) from (select pos, moral, j, v from t where jogador = me) x)
    into lista, eu from t;
  return jsonb_build_object(
    'semana', s,
    'fim', ((s + 7)::timestamp at time zone 'America/Sao_Paulo'),
    'agora', now(),
    'lista', lista,
    'eu', eu,
    'campeao', (select jsonb_build_object('id', p.id, 'apelido', p.apelido, 'ico', coalesce(p.dados->>'ico','oito'), 'moral', r.moral)
                  from perfis p join ranking r on r.jogador = p.id and r.semana = s - 7 where p.id = camp));
end $$;
grant execute on function public.ranking_semana() to authenticated;
