-- Sinuca de Bar: missões da semana
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.
-- Precisa ter rodado antes o 05-ranking.sql e o 06-historico.sql.

-- XP do treino: agora também conta vitórias da semana (para a missão do treino)
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
  n := case when venceu then (array[20,35,50])[nivel + 1] + case when limpa then 10 else 0 end else 10 end;
  usado := coalesce((c->>'xp_treino')::int, 0);
  if usado + n > 1200 then return p.xp; end if;          -- teto diário de XP do treino
  update perfis set ctl = ctl || jsonb_build_object('xp_treino', usado + n) where id = me;
  return _dar_xp(me, n);
end $$;
grant execute on function public.xp_treino(integer, boolean, boolean, integer) to authenticated;

-- as missões da semana: sempre a do treino + 2 do online que mudam toda segunda
create or replace function public._missoes_da_semana(s date) returns text[] language sql immutable as $$
  select array['treino8'] || (
    select array_agg(id order by md5(s::text || id)) from unnest(array['on_v5','on_j10','esquina3','bolas30','ficha3','particular2']) id
  )[1:2];
$$;

-- progresso de uma missão, calculado pelo servidor
create or replace function public._missao_prog(me uuid, mid text, s date) returns integer
language plpgsql security definer set search_path = public stable as $$
declare ini timestamptz := (s::timestamp at time zone 'America/Sao_Paulo'); r int; c jsonb;
begin
  if mid = 'treino8' then
    select ctl into c from perfis where perfis.id = me;
    return case when coalesce(c->>'sem','') = s::text then coalesce((c->>'sem_tv')::int, 0) else 0 end;
  end if;
  select case mid
      when 'on_v5'       then count(*) filter (where (vencedor = 0 and j1 = me) or (vencedor = 1 and j2 = me))
      when 'on_j10'      then count(*)
      when 'esquina3'    then count(*) filter (where bar in ('esquina','centro'))
      when 'bolas30'     then coalesce(sum(case when j1 = me then bolas1 else bolas2 end), 0)
      when 'ficha3'      then count(*) filter (where ficha > 0 and ((vencedor = 0 and j1 = me) or (vencedor = 1 and j2 = me)))
      when 'particular2' then count(*) filter (where privada)
      else 0 end
    into r
    from partidas where status = 'fim' and (j1 = me or j2 = me) and terminada_em >= ini;
  return coalesce(r, 0);
end $$;

create or replace function public.missoes() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare me uuid := auth.uid(); s date := _semana(); c jsonb; ok jsonb; lista jsonb := '[]'::jsonb; mid text; meta int; premio int; txt text; prog int;
begin
  if me is null then raise exception 'sem login'; end if;
  select ctl into c from perfis where perfis.id = me;
  ok := case when coalesce(c->>'miss_sem','') = s::text then coalesce(c->'miss_ok','[]'::jsonb) else '[]'::jsonb end;
  foreach mid in array _missoes_da_semana(s) loop
    select t.meta, t.premio, t.txt into meta, premio, txt from (values
      ('treino8', 8, 40, 'Vença 8 treinos contra o Seu Zé'),
      ('on_v5', 5, 60, 'Ganhe 5 partidas online'),
      ('on_j10', 10, 50, 'Jogue 10 partidas online'),
      ('esquina3', 3, 60, 'Jogue 3 partidas no Bar da Esquina ou no Bar do Centro'),
      ('bolas30', 30, 60, 'Mate 30 bolas no online'),
      ('ficha3', 3, 70, 'Ganhe 3 partidas valendo ficha'),
      ('particular2', 2, 50, 'Jogue 2 partidas numa mesa particular')) t(i, meta, premio, txt) where t.i = mid;
    prog := least(_missao_prog(me, mid, s), meta);
    lista := lista || jsonb_build_object('id', mid, 'txt', txt, 'meta', meta, 'prog', prog, 'premio', premio, 'resgatada', ok ? mid);
  end loop;
  return jsonb_build_object('lista', lista, 'fim', ((s + 7)::timestamp at time zone 'America/Sao_Paulo'), 'agora', now(),
    'bonus', coalesce(c->>'miss_bonus','') = s::text);
end $$;
grant execute on function public.missoes() to authenticated;

-- resgata o prêmio de uma missão concluída; as 3 feitas dão também uma Caixa Prata
create or replace function public.resgatar_missao(missao text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s date := _semana(); p perfis%rowtype; c jsonb; ok jsonb; meta int; premio int; caixa text := null;
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
    c := c || jsonb_build_object('miss_bonus', s::text); caixa := 'prata';
  end if;
  update perfis set saldo = saldo + premio, ctl = c where id = me returning saldo into meta;
  return jsonb_build_object('saldo', meta, 'premio', premio, 'caixa', caixa);
end $$;
grant execute on function public.resgatar_missao(text) to authenticated;
