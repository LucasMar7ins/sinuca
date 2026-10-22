-- Sinuca de Bar: Loja do Seu Zé (sem sorteio), panos, Temporada 1 com giz e fim das caixas
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.
-- Precisa ter rodado antes do 01 ao 09.

-- ---------- preços da loja (só o servidor decide) ----------
create or replace function public._preco_taco(t text) returns integer language sql immutable as $$
  select case
    when t in ('madeira','azul','pinho','vermelho','preto','praia','laranja','garrafa','gelo','cafe','couro','asfalto','vinho') then 100
    when t in ('cromado','marmore','carbono','azulejo','neon','perola','cobre','ebano','caipirinha') then 250
    when t in ('brasil','lendario','carnaval','jabuticaba','macico') then 500
    else null end;
$$;
create or replace function public._preco_pano(t text) returns integer language sql immutable as $$
  select case
    when t in ('laranja','grafite','petroleo','mostarda') then 100
    when t in ('roxo','xadrez','rosa','noite') then 250
    when t in ('chita','dourado') then 500
    when t in ('t_br','t_ar','t_pt','t_it','t_es','t_jp','t_de','t_fr','t_us','t_mx','t_uy','t_co') then 250
    else null end;
$$;

-- itens que o servidor sabe que cada um tem (comprados, de patente e da temporada)
create or replace function public._dar_item(quem uuid, tipo text, ref text) returns void
language plpgsql security definer set search_path = public as $$
declare k text := case tipo when 'taco' then 'tacos' when 'pano' then 'panos' when 'icone' then 'icones' end;
begin
  if k is null then return; end if;
  update perfis set ctl = ctl || jsonb_build_object(k, coalesce(ctl->k,'[]'::jsonb) || to_jsonb(ref))
   where id = quem and not (coalesce(ctl->k,'[]'::jsonb) ? ref);
end $$;

create or replace function public.meus_itens() returns jsonb
language sql security definer set search_path = public stable as $$
  select jsonb_build_object('tacos', coalesce(ctl->'tacos','[]'::jsonb), 'panos', coalesce(ctl->'panos','[]'::jsonb), 'icones', coalesce(ctl->'icones','[]'::jsonb))
    from perfis where id = auth.uid();
$$;
grant execute on function public.meus_itens() to authenticated;

-- ---------- Temporada ----------
create or replace function public._temporada() returns table (id int, nome text, ini timestamptz, fim timestamptz)
language sql stable as $$
  select * from (values
    (1, 'Abertura do Bar', '2026-10-22 00:00:00-03'::timestamptz, '2026-11-20 00:00:00-03'::timestamptz)
  ) t(id, nome, ini, fim) where now() >= t.ini and now() < t.fim;
$$;

-- a trilha: o que cada nível dá na trilha grátis e no Passe do Bar
create or replace function public._trilha() returns table (n int, g_tipo text, g_ref text, g_val int, p_tipo text, p_ref text, p_val int)
language sql immutable as $$
  select * from (values
    (1,'pts',null,20,'pts',null,40),        (2,'icone','chope',0,'pano','petroleo',0),   (3,'pts',null,30,'taco','cromado',0),
    (4,'pano','laranja',0,'icone','jukebox',0),(5,'taco','praia',0,'pts',null,80),       (6,'pts',null,40,'taco','neon',0),
    (7,'icone','tampinha',0,'pano','dourado',0),(8,'pts',null,50,'taco','carbono',0),    (9,'taco','cafe',0,'icone','seuze',0),
    (10,'pano','grafite',0,'taco','carnaval',0),(11,'pts',null,60,'pts',null,100),       (12,'icone','tacada',0,'pano','chita',0),
    (13,'taco','azulejo',0,'pts',null,100),  (14,'pts',null,60,'taco','caipirinha',0),   (15,'pano','xadrez',0,'pts',null,100),
    (16,'pts',null,70,'pts',null,120),       (17,'icone','triangulo',0,'taco','macico',0),(18,'taco','cobre',0,'pts',null,120),
    (19,'pts',null,80,'pano','rosa',0),      (20,'pano','roxo',0,'taco','brasil',0),     (21,'pts',null,80,'pts',null,150),
    (22,'icone','domino',0,'taco','lendario',0),(23,'taco','ebano',0,'pts',null,150),    (24,'pts',null,90,'pano','noite',0),
    (25,'icone','espeto',0,'pts',null,200),  (26,'pts',null,100,'taco','marmore',0),     (27,'taco','perola',0,'pts',null,200),
    (28,'pts',null,120,'pano','mostarda',0), (29,'icone','neon',0,'pts',null,250),       (30,'taco','jabuticaba',0,'taco','abertura',0)
  ) t(n, g_tipo, g_ref, g_val, p_tipo, p_ref, p_val);
$$;

create table if not exists public.temporada_prog (
  jogador uuid not null references auth.users (id) on delete cascade,
  temp int not null,
  giz int not null default 0,
  nivel int not null default 0,
  passe boolean not null default false,
  primary key (jogador, temp)
);
alter table public.temporada_prog enable row level security;
revoke all on public.temporada_prog from anon, authenticated;

-- soma giz e entrega os prêmios dos níveis alcançados (200 de giz por nível, até o 30)
create or replace function public._dar_giz(quem uuid, n integer) returns void
language plpgsql security definer set search_path = public as $$
declare t record; p temporada_prog%rowtype; novo int; k int; r record;
begin
  if quem is null or n <= 0 then return; end if;
  select * into t from _temporada(); if t.id is null then return; end if;
  insert into temporada_prog (jogador, temp) values (quem, t.id) on conflict do nothing;
  select * into p from temporada_prog where jogador = quem and temp = t.id for update;
  novo := least(30, (p.giz + n) / 200);
  update temporada_prog set giz = least(giz + n, 6000), nivel = greatest(nivel, novo) where jogador = quem and temp = t.id;
  for k in p.nivel + 1 .. novo loop
    select * into r from _trilha() where _trilha.n = k;
    if r.g_tipo = 'pts' then update perfis set saldo = saldo + r.g_val where id = quem;
    else perform _dar_item(quem, r.g_tipo, r.g_ref); end if;
    if p.passe then
      if r.p_tipo = 'pts' then update perfis set saldo = saldo + r.p_val where id = quem;
      else perform _dar_item(quem, r.p_tipo, r.p_ref); end if;
    end if;
  end loop;
end $$;

create or replace function public.temporada() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare me uuid := auth.uid(); t record; p temporada_prog%rowtype;
begin
  select * into t from _temporada();
  if t.id is null then return jsonb_build_object('ativa', false); end if;
  select * into p from temporada_prog where jogador = me and temp = t.id;
  return jsonb_build_object('ativa', true, 'id', t.id, 'nome', t.nome, 'fim', t.fim, 'agora', now(),
    'giz', coalesce(p.giz, 0), 'nivel', coalesce(p.nivel, 0), 'passe', coalesce(p.passe, false), 'por_nivel', 200,
    'trilha', (select jsonb_agg(jsonb_build_object('n', n, 'g', jsonb_build_object('tipo', g_tipo, 'ref', g_ref, 'val', g_val),
                                                   'p', jsonb_build_object('tipo', p_tipo, 'ref', p_ref, 'val', p_val)) order by n) from _trilha()));
end $$;
grant execute on function public.temporada() to authenticated;

-- ---------- prêmios de patente: tacos certos no lugar das caixas ----------
create or replace function public._dar_xp(quem uuid, n integer) returns integer
language plpgsql security definer set search_path = public as $$
declare p perfis%rowtype; antes int; depois int; k int; c jsonb; premio int; ganho int := 0; taco text;
begin
  select * into p from perfis where id = quem for update;
  if not found then return 0; end if;
  antes := _patente(p.xp); depois := _patente(p.xp + n);
  c := p.ctl;
  for k in antes + 1 .. depois loop
    premio := case k when 2 then 20 when 4 then 50 when 8 then 100 when 13 then 200 when 14 then 300 else 0 end;
    taco := case k when 1 then 'madeira' when 3 then 'garrafa' when 5 then 'azulejo' when 6 then 'couro' when 7 then 'cobre'
                   when 9 then 'seuze' when 10 then 'ebano' when 11 then 'carnaval' when 12 then 'jabuticaba' when 13 then 'macico' when 14 then 'donodobar' else null end;
    if not (coalesce(c->'patentes','[]'::jsonb) ? k::text) then
      c := c || jsonb_build_object('patentes', coalesce(c->'patentes','[]'::jsonb) || to_jsonb(k::text));
      ganho := ganho + premio;
      if taco is not null and not (coalesce(c->'tacos','[]'::jsonb) ? taco) then
        c := c || jsonb_build_object('tacos', coalesce(c->'tacos','[]'::jsonb) || to_jsonb(taco));
      end if;
    end if;
  end loop;
  update perfis set xp = xp + n, saldo = saldo + ganho, ctl = c where id = quem returning xp into depois;
  return depois;
end $$;

-- ---------- pontos: compra de tacos e panos; desafios dão giz ----------
create or replace function public.pontos(motivo text, valor integer, ref text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p perfis%rowtype;
  c jsonb;
  usado int;
  preco int;
  premio int;
  giz int := 0;
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
    giz := 25;
  elsif motivo = 'patente' then
    premio := case ref when '2' then 20 when '4' then 50 when '8' then 100 when '13' then 200 when '14' then 300 else 0 end;
    if premio = 0 or valor <> premio then raise exception 'valor inválido'; end if;
    if _patente(p.xp) < ref::int then raise exception 'patente ainda não alcançada'; end if;
    if coalesce(c->'patentes','[]'::jsonb) ? ref then raise exception 'já recebido'; end if;
    c := c || jsonb_build_object('patentes', coalesce(c->'patentes','[]'::jsonb) || to_jsonb(ref));
  elsif motivo = 'taco' then
    preco := _preco_taco(ref);
    if preco is null or valor <> -preco then raise exception 'valor inválido'; end if;
    if coalesce(c->'tacos','[]'::jsonb) ? ref then raise exception 'já tem esse taco'; end if;
    c := c || jsonb_build_object('tacos', coalesce(c->'tacos','[]'::jsonb) || to_jsonb(ref));
  elsif motivo = 'pano' then
    preco := _preco_pano(ref);
    if preco is null or valor <> -preco then raise exception 'valor inválido'; end if;
    if coalesce(c->'panos','[]'::jsonb) ? ref then raise exception 'já tem esse pano'; end if;
    c := c || jsonb_build_object('panos', coalesce(c->'panos','[]'::jsonb) || to_jsonb(ref));
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
  if giz > 0 then perform _dar_giz(me, giz); select saldo into usado from perfis where id = me; end if;
  return usado;
end $$;
grant execute on function public.pontos(text, integer, text) to authenticated;

-- ---------- caixas grátis guardadas viram pontos (uma vez só) ----------
create or replace function public.converter_caixas(boteco integer, prata integer, ouro integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p perfis%rowtype; pat int; mb int; mp int; mo int; v int;
begin
  if me is null then raise exception 'sem login'; end if;
  select * into p from perfis where id = me for update;
  if coalesce(p.ctl->>'caixas_ok','') = 'sim' then return jsonb_build_object('saldo', p.saldo, 'valor', 0); end if;
  pat := _patente(p.xp);
  mb := (case when pat >= 1 then 1 else 0 end) + (case when pat >= 3 then 1 else 0 end) + (case when pat >= 6 then 1 else 0 end);
  mp := 1 + (case when pat >= 5 then 1 else 0 end) + (case when pat >= 7 then 1 else 0 end) + (case when pat >= 10 then 1 else 0 end);
  mo := greatest(0, least(4, pat - 10));
  v := 100 * least(greatest(coalesce(boteco,0),0), mb) + 250 * least(greatest(coalesce(prata,0),0), mp) + 500 * least(greatest(coalesce(ouro,0),0), mo);
  update perfis set saldo = saldo + v, ctl = ctl || jsonb_build_object('caixas_ok', 'sim') where id = me returning saldo into pat;
  return jsonb_build_object('saldo', pat, 'valor', v);
end $$;
grant execute on function public.converter_caixas(integer, integer, integer) to authenticated;

-- ---------- giz nas partidas ----------
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
  perform _hist(ganhador, 'net', 1, 1, 0);
  perform _dar_giz(ganhador, 30);
  if perdedor is not null then
    perform _dar_xp(perdedor, 10);
    perform _hist(perdedor, 'net', 1, 0, 0);
    perform _dar_giz(perdedor, 15);
  end if;
  perform _ranquear(pid);
end $$;

create or replace function public.xp_treino(nivel integer, venceu boolean, limpa boolean default false, bolas integer default 0)
returns integer language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p perfis%rowtype; c jsonb; n int; usado int; sem text := _semana()::text;
begin
  if me is null then raise exception 'sem login'; end if;
  if nivel not between 0 and 2 then raise exception 'nível inválido'; end if;
  select * into p from perfis where id = me for update;
  c := _ctl_dia(p.ctl);
  if (c ? 'xp_em') and now() - (c->>'xp_em')::timestamptz < interval '30 seconds' then return p.xp; end if;
  if coalesce(c->>'sem','') <> sem then c := c || jsonb_build_object('sem', sem, 'sem_tv', 0); end if;
  if venceu then c := c || jsonb_build_object('sem_tv', coalesce((c->>'sem_tv')::int, 0) + 1); end if;
  update perfis set ctl = c || jsonb_build_object('xp_em', now()) where id = me;
  perform _hist(me, 'cpu', 1, case when venceu then 1 else 0 end, least(greatest(coalesce(bolas,0),0),8));
  perform _dar_giz(me, case when venceu then 15 else 8 end);
  n := case when venceu then (array[20,35,50])[nivel + 1] + case when limpa then 10 else 0 end else 10 end;
  usado := coalesce((c->>'xp_treino')::int, 0);
  if usado + n > 1200 then return p.xp; end if;
  update perfis set ctl = ctl || jsonb_build_object('xp_treino', usado + n) where id = me;
  return _dar_xp(me, n);
end $$;
grant execute on function public.xp_treino(integer, boolean, boolean, integer) to authenticated;

-- missões: +100 de giz cada; as 3 resgatadas dão +150 pontos (no lugar da caixa)
create or replace function public.resgatar_missao(missao text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s date := _semana(); p perfis%rowtype; c jsonb; ok jsonb; meta int; premio int; bonus int := 0;
begin
  if me is null then raise exception 'sem login'; end if;
  if not (missao = any(_missoes_da_semana(s))) then raise exception 'missão inválida'; end if;
  select * into p from perfis where id = me for update;
  c := p.ctl;
  ok := case when coalesce(c->>'miss_sem','') = s::text then coalesce(c->'miss_ok','[]'::jsonb) else '[]'::jsonb end;
  if ok ? missao then raise exception 'já resgatada'; end if;
  select t.meta, t.premio into meta, premio from (values ('treino8',8,40),('on_v5',5,60),('on_j10',10,50),('esquina3',3,60),('bolas30',30,60),('ficha3',3,70),('particular2',2,50)) t(i, meta, premio) where t.i = missao;
  if _missao_prog(me, missao, s) < meta then raise exception 'missão ainda não concluída'; end if;
  ok := ok || to_jsonb(missao);
  c := c || jsonb_build_object('miss_sem', s::text, 'miss_ok', ok);
  if jsonb_array_length(ok) = 3 and coalesce(c->>'miss_bonus','') <> s::text then
    c := c || jsonb_build_object('miss_bonus', s::text); bonus := 150;
  end if;
  update perfis set saldo = saldo + premio + bonus, ctl = c where id = me;
  perform _dar_giz(me, 100);
  select saldo into meta from perfis where id = me;
  return jsonb_build_object('saldo', meta, 'premio', premio, 'bonus', bonus);
end $$;
grant execute on function public.resgatar_missao(text) to authenticated;
