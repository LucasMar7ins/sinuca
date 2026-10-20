-- Sinuca de Bar: apelidos proibidos, troca de apelido pelo painel e "Jogar agora" por moral parecida
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.
-- Precisa ter rodado antes o 08-painel-e-conta.sql.

-- ---------- filtro de apelido ----------
-- normaliza (minúsculas, sem acento, 0→o 1→i 3→e 4→a 5→s 7→t @→a $→s) e junta letras repetidas
create or replace function public._apelido_proibido(nome text) returns boolean
language plpgsql immutable as $$
declare
  n text := translate(lower(coalesce(nome,'')), 'áàâãäéèêëíìîïóòôõöúùûüçñ013457@$!', 'aaaaaeeeeiiiiooooouuuucnoieastasi');
  flat text := regexp_replace(regexp_replace(n, '[^a-z]', '', 'g'), '(.)\1+', '\1', 'g');
  t text;
  sub text[] := array['caralh','buceta','boceta','arombad','xoxota','piroca','punhet','siriric','putaria','putinh','putona',
    'filhodaputa','desgracad','vagabund','cuzao','cuzinh','viadinh','viadao','baitol','boiol','sapatao','traveco','retardad',
    'mongoloid','estupr','pedofil','nazist','hitler','fuck','bitch','whore','pusy','cunt','niger','merda','bosta','porno','cacet','rapariga'];
  ini text[] := array['puta','puto','puteir','pora','fod','fud','viad','corno','cornud','otari','merd','bost','vadia','arombad'];
  exato text[] := array['cu','cus','fdp','vsf','tnc','pqp','krl','crl','pnc','vtnc','tmnc','kct','vtc','gozo','goza','bicha','bichona'];
  s text;
begin
  if flat = any(exato) then return true; end if;
  foreach s in array sub loop if position(s in flat) > 0 then return true; end if; end loop;
  foreach t in array regexp_split_to_array(n, '[^a-z]+') loop
    t := regexp_replace(t, '(.)\1+', '\1', 'g');
    if t = '' then continue; end if;
    if t = any(exato) then return true; end if;
    foreach s in array ini loop if left(t, length(s)) = s then return true; end if; end loop;
  end loop;
  return false;
end $$;

-- todo perfil novo passa pelo filtro: apelido proibido vira "Jogador1234"
create or replace function public._apelido_limpo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _apelido_proibido(new.apelido) then
    new.apelido := 'Jogador' || substr(new.id::text, 1, 4);
  end if;
  return new;
end $$;
drop trigger if exists apelido_limpo on public.perfis;
create trigger apelido_limpo before insert or update of apelido on public.perfis
  for each row execute function public._apelido_limpo();

-- a tela de cadastro pergunta antes de criar a conta
create or replace function public.apelido_permitido(nome text) returns boolean
language sql stable as $$ select not public._apelido_proibido(nome); $$;
grant execute on function public.apelido_permitido(text) to anon, authenticated;

-- ---------- painel: apelidos pra revisar e troca de apelido ----------
create or replace function public.apelidos_revisar() returns jsonb
language plpgsql security definer set search_path = public stable as $$
begin
  if not exists (select 1 from admins where id = auth.uid()) then raise exception 'só o dono do bar'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('apelido', apelido, 'criado_em', criado_em) order by criado_em desc), '[]'::jsonb)
            from perfis where _apelido_proibido(apelido));
end $$;
grant execute on function public.apelidos_revisar() to authenticated;

create or replace function public.trocar_apelido(atual text, novo text) returns text
language plpgsql security definer set search_path = public as $$
declare alvo uuid; n text := trim(novo);
begin
  if not exists (select 1 from admins where id = auth.uid()) then raise exception 'só o dono do bar'; end if;
  select id into alvo from perfis where lower(apelido) = lower(trim(atual));
  if alvo is null then raise exception 'apelido não encontrado'; end if;
  if n !~ '^[[:alpha:][:digit:] _.-]{3,16}$' then raise exception 'o novo apelido precisa de 3 a 16 letras ou números'; end if;
  if _apelido_proibido(n) then raise exception 'o novo apelido também é proibido'; end if;
  if exists (select 1 from perfis where lower(apelido) = lower(n) and id <> alvo) then raise exception 'esse apelido já tem dono'; end if;
  update perfis set apelido = n where id = alvo;
  update partidas set apelido1 = n where j1 = alvo and status in ('esperando','jogando');
  update partidas set apelido2 = n where j2 = alvo and status in ('esperando','jogando');
  return n;
end $$;
grant execute on function public.trocar_apelido(text, text) to authenticated;

-- ---------- "Jogar agora": senta primeiro com quem tem moral parecida ----------
create or replace function public.sentar(bar text, patente text default null, nova boolean default false)
returns partidas language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); f int := ficha_do_bar(bar); ap text; sal int; m partidas%rowtype; r record; minha int;
begin
  if me is null then raise exception 'sem login'; end if;
  if f is null then raise exception 'bar inválido'; end if;
  perform _limpar();
  m := minha_partida();
  if m.id is not null then return m; end if;
  select apelido, saldo into ap, sal from perfis where id = me;
  if sal < f then raise exception 'saldo insuficiente'; end if;
  select coalesce((select moral from ranking where semana = _semana() and jogador = me), 1000) into minha;
  if not nova then
    for r in select p.id from partidas p
              left join ranking rk on rk.semana = _semana() and rk.jogador = p.j1
              where p.bar = sentar.bar and p.status = 'esperando' and p.j1 <> me and not p.privada
                and p.sinal1 > now() - interval '30 seconds'
              -- faixas de 100 de moral; quem espera há mais de 1 minuto entra na frente de qualquer jeito
              order by case when p.criada_em < now() - interval '60 seconds' then 0 else abs(coalesce(rk.moral, 1000) - minha) / 100 end, p.criada_em
              for update of p skip locked loop
      m := _comecar(r.id, me, ap, patente);
      if m.id is not null then return m; end if;
    end loop;
  end if;
  insert into partidas (bar, ficha, j1, apelido1, patente1) values (bar, f, me, ap, patente) returning * into m;
  return m;
end $$;
