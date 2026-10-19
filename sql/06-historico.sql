-- Sinuca de Bar: histórico de partidas guardado no servidor
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.
-- Precisa ter rodado antes o 05-ranking.sql.

alter table public.perfis add column if not exists hist jsonb not null default '{"cpu":{"j":0,"v":0,"b":0},"net":{"j":0,"v":0,"b":0}}'::jsonb;
alter table public.perfis add column if not exists hist_migrado boolean not null default false;
alter table public.partidas add column if not exists bolas1 smallint;
alter table public.partidas add column if not exists bolas2 smallint;

-- traz o histórico que já estava no aparelho (uma vez só por conta)
update public.perfis set hist = jsonb_build_object(
    'cpu', jsonb_build_object('j', least(greatest(coalesce((dados#>>'{hist,cpu,j}')::int,0),0),5000),
                              'v', least(greatest(coalesce((dados#>>'{hist,cpu,v}')::int,0),0),5000),
                              'b', least(greatest(coalesce((dados#>>'{hist,cpu,b}')::int,0),0),40000)),
    'net', jsonb_build_object('j', least(greatest(coalesce((dados#>>'{hist,net,j}')::int,0),0),5000),
                              'v', least(greatest(coalesce((dados#>>'{hist,net,v}')::int,0),0),5000),
                              'b', least(greatest(coalesce((dados#>>'{hist,net,b}')::int,0),0),40000))),
       hist_migrado = true
 where not hist_migrado;

-- soma no histórico de alguém (modo 'cpu' ou 'net')
create or replace function public._hist(quem uuid, modo text, j int, v int, b int) returns void
language plpgsql security definer set search_path = public as $$
begin
  update perfis set hist = jsonb_set(hist, array[modo], jsonb_build_object(
      'j', coalesce((hist#>>array[modo,'j'])::int, 0) + j,
      'v', coalesce((hist#>>array[modo,'v'])::int, 0) + v,
      'b', coalesce((hist#>>array[modo,'b'])::int, 0) + b))
   where id = quem;
end $$;

-- pagamento da partida: agora também conta no histórico
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
  if perdedor is not null then
    perform _dar_xp(perdedor, 10);
    perform _hist(perdedor, 'net', 1, 0, 0);
  end if;
  perform _ranquear(pid);
end $$;

-- bolas que cada um matou na partida online (uma vez por partida, no máximo 8)
create or replace function public.bolas(pid uuid, n integer) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m partidas%rowtype; k int := least(greatest(coalesce(n,0),0),8);
begin
  select * into m from partidas where id = pid for update;
  if not found or (m.j1 <> me and m.j2 is distinct from me) or m.status not in ('jogando','fim') then return; end if;
  if m.j1 = me then
    if m.bolas1 is not null then return; end if;
    update partidas set bolas1 = k where id = pid;
  else
    if m.bolas2 is not null then return; end if;
    update partidas set bolas2 = k where id = pid;
  end if;
  perform _hist(me, 'net', 0, 0, k);
end $$;
grant execute on function public.bolas(uuid, integer) to authenticated;

-- XP do treino: agora também conta a partida e as bolas no histórico
drop function if exists public.xp_treino(integer, boolean, boolean);
create or replace function public.xp_treino(nivel integer, venceu boolean, limpa boolean default false, bolas integer default 0)
returns integer language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p perfis%rowtype; c jsonb; n int; usado int;
begin
  if me is null then raise exception 'sem login'; end if;
  if nivel not between 0 and 2 then raise exception 'nível inválido'; end if;
  select * into p from perfis where id = me for update;
  c := _ctl_dia(p.ctl);
  if (c ? 'xp_em') and now() - (c->>'xp_em')::timestamptz < interval '30 seconds' then return p.xp; end if;
  update perfis set ctl = c || jsonb_build_object('xp_em', now()) where id = me;
  perform _hist(me, 'cpu', 1, case when venceu then 1 else 0 end, least(greatest(coalesce(bolas,0),0),8));
  n := case when venceu then (array[20,35,50])[nivel + 1] + case when limpa then 10 else 0 end else 10 end;
  usado := coalesce((c->>'xp_treino')::int, 0);
  if usado + n > 1200 then return p.xp; end if;          -- teto diário de XP do treino
  update perfis set ctl = ctl || jsonb_build_object('xp_treino', usado + n) where id = me;
  return _dar_xp(me, n);
end $$;
grant execute on function public.xp_treino(integer, boolean, boolean, integer) to authenticated;

-- meu histórico
create or replace function public.meu_historico() returns jsonb
language sql security definer set search_path = public stable as $$
  select hist from perfis where id = auth.uid();
$$;
grant execute on function public.meu_historico() to authenticated;
