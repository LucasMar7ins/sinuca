-- Sinuca de Bar: bar patrocinador, convite com prêmio e Passe do Bar pago (desligado até você ligar)
-- Rode inteiro no SQL Editor do Supabase. Pode rodar de novo sem problema.

-- =====================================================================
-- 1) BAR PATROCINADOR
-- Um bar de verdade "dá o nome" a uma das mesas do lobby por um período.
-- Aparece o logo no card do lobby, no pano da mesa e na tela de espera.
-- =====================================================================
create table if not exists public.patrocinios (
  id bigint generated always as identity primary key,
  bar text not null check (bar in ('calcada','boteco','esquina','centro')),
  nome text not null check (char_length(nome) between 2 and 40),
  frase text check (frase is null or char_length(frase) <= 70),
  link text check (link is null or link ~ '^https://[^ ]+$'),
  cor text not null default '#3d2112' check (cor ~ '^#[0-9a-fA-F]{6}$'),
  logo text check (logo is null or (logo ~ '^data:image/(png|jpeg|webp);base64,' and char_length(logo) < 150000)),
  ini date not null,
  fim date not null,
  valor numeric(10,2),                 -- quanto o bar pagou (só você vê)
  criado_em timestamptz not null default now(),
  check (fim >= ini)
);
alter table public.patrocinios enable row level security;
revoke all on public.patrocinios from anon, authenticated;

-- quem viu e quem clicou (uma linha por pessoa por dia, sem dado pessoal além do id da conta)
create table if not exists public.patro_vistas (
  pid bigint not null references public.patrocinios (id) on delete cascade,
  dia date not null,
  jogador uuid not null references auth.users (id) on delete cascade,
  viu boolean not null default false,
  clicou boolean not null default false,
  primary key (pid, dia, jogador)
);
alter table public.patro_vistas enable row level security;
revoke all on public.patro_vistas from anon, authenticated;

create or replace function public._dia_sp() returns date language sql stable as $$
  select (now() at time zone 'America/Sao_Paulo')::date;
$$;

create or replace function public._eh_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from admins where id = auth.uid());
$$;

-- patrocínios valendo hoje (um por mesa: o mais recente)
create or replace function public.patrocinios_ativos() returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'bar', bar, 'nome', nome, 'frase', frase, 'link', link, 'cor', cor, 'logo', logo)), '[]'::jsonb)
    from (select distinct on (bar) * from patrocinios
           where _dia_sp() between ini and fim order by bar, id desc) p;
$$;
grant execute on function public.patrocinios_ativos() to authenticated;

create or replace function public.patro_ev(patro bigint, tipo text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or tipo not in ('vista','clique') then return; end if;
  if not exists (select 1 from patrocinios p where p.id = patro and _dia_sp() between p.ini and p.fim) then return; end if;
  insert into patro_vistas as v (pid, dia, jogador, viu, clicou)
  values (patro, _dia_sp(), me, true, tipo = 'clique')
  on conflict on constraint patro_vistas_pkey do update set viu = true, clicou = v.clicou or excluded.clicou;
end $$;
grant execute on function public.patro_ev(bigint, text) to authenticated;

-- painel: criar ou editar (com id) um patrocínio
create or replace function public.patro_salvar(dados jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare novo bigint; b text := dados->>'bar'; i date := (dados->>'ini')::date; f date := (dados->>'fim')::date; pid bigint := nullif(dados->>'id','')::bigint;
begin
  if not _eh_admin() then raise exception 'só o dono do bar'; end if;
  if exists (select 1 from patrocinios p where p.bar = b and p.id is distinct from pid and p.ini <= f and p.fim >= i) then
    raise exception 'Essa mesa já tem patrocinador nesse período';
  end if;
  if pid is null then
    insert into patrocinios (bar, nome, frase, link, cor, logo, ini, fim, valor)
    values (b, trim(dados->>'nome'), nullif(trim(dados->>'frase'),''), nullif(trim(dados->>'link'),''), coalesce(nullif(dados->>'cor',''),'#3d2112'),
            nullif(dados->>'logo',''), i, f, nullif(dados->>'valor','')::numeric)
    returning id into novo;
  else
    update patrocinios set bar = b, nome = trim(dados->>'nome'), frase = nullif(trim(dados->>'frase'),''), link = nullif(trim(dados->>'link'),''),
           cor = coalesce(nullif(dados->>'cor',''),'#3d2112'), logo = coalesce(nullif(dados->>'logo',''), logo), ini = i, fim = f,
           valor = nullif(dados->>'valor','')::numeric
     where id = pid returning id into novo;
  end if;
  return novo;
end $$;
grant execute on function public.patro_salvar(jsonb) to authenticated;

create or replace function public.patro_apagar(patro bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _eh_admin() then raise exception 'só o dono do bar'; end if;
  delete from patrocinios where id = patro;
end $$;
grant execute on function public.patro_apagar(bigint) to authenticated;

-- painel: relatório de cada patrocínio (pessoas que viram, cliques, partidas na mesa dele)
create or replace function public.patro_relatorio() returns jsonb
language plpgsql security definer set search_path = public stable as $$
begin
  if not _eh_admin() then raise exception 'só o dono do bar'; end if;
  return coalesce((select jsonb_agg(x order by x->>'ini' desc) from (
    select jsonb_build_object(
      'id', p.id, 'bar', p.bar, 'nome', p.nome, 'frase', p.frase, 'link', p.link, 'cor', p.cor, 'logo', p.logo,
      'ini', p.ini, 'fim', p.fim, 'valor', p.valor, 'ativo', _dia_sp() between p.ini and p.fim,
      'pessoas', (select count(distinct jogador) from patro_vistas v where v.pid = p.id and v.viu),
      'vistas', (select count(*) from patro_vistas v where v.pid = p.id and v.viu),
      'cliques', (select count(*) from patro_vistas v where v.pid = p.id and v.clicou),
      'partidas', (select count(*) from partidas m where m.bar = p.bar and m.status = 'fim'
                     and (m.terminada_em at time zone 'America/Sao_Paulo')::date between p.ini and p.fim),
      'jogadores', (select count(distinct j) from partidas m, lateral (values (m.j1), (m.j2)) t(j)
                     where m.bar = p.bar and m.status = 'fim' and j is not null
                       and (m.terminada_em at time zone 'America/Sao_Paulo')::date between p.ini and p.fim)
    ) x from patrocinios p) s), '[]'::jsonb);
end $$;
grant execute on function public.patro_relatorio() to authenticated;

-- =====================================================================
-- 2) CONVITE COM PRÊMIO
-- Cada conta tem um código. Quem entra pelo link ganha 50 pontos.
-- Quem convidou ganha 100 pontos + 50 de giz quando o amigo joga 3 partidas,
-- e o Taco Padrinho no 3º amigo. Até 20 amigos pagos por conta.
-- =====================================================================
alter table public.perfis add column if not exists convite text;
alter table public.perfis add column if not exists convidado_por uuid references auth.users (id) on delete set null;
alter table public.perfis add column if not exists convite_pago boolean not null default false;
create unique index if not exists perfis_convite on public.perfis (convite) where convite is not null;
create index if not exists perfis_convidado_por on public.perfis (convidado_por) where convidado_por is not null;

create or replace function public._meu_codigo(quem uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text; tent int := 0;
begin
  select convite into c from perfis where id = quem;
  if c is not null then return c; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text || quem::text), 1, 6));
    begin
      if char_length(c) = 6 then update perfis set convite = c where id = quem; return c; end if;
    exception when unique_violation then null; end;
    tent := tent + 1; if tent > 20 then raise exception 'tente de novo'; end if;
  end loop;
end $$;

create or replace function public.usar_convite(codigo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p perfis%rowtype; quem uuid; criado timestamptz;
begin
  if me is null then return jsonb_build_object('ok', false); end if;
  select * into p from perfis where id = me for update;
  if p.convidado_por is not null then return jsonb_build_object('ok', false, 'motivo', 'ja'); end if;
  select created_at into criado from auth.users where id = me;
  if criado < now() - interval '7 days' then return jsonb_build_object('ok', false, 'motivo', 'antiga'); end if;
  select id into quem from perfis where convite = upper(trim(codigo));
  if quem is null or quem = me then return jsonb_build_object('ok', false, 'motivo', 'codigo'); end if;
  update perfis set convidado_por = quem, saldo = saldo + 50 where id = me;
  return jsonb_build_object('ok', true, 'bonus', 50, 'de', (select apelido from perfis where id = quem));
end $$;
grant execute on function public.usar_convite(text) to authenticated;

-- mostra meus convites e paga os amigos que já jogaram 3 partidas
create or replace function public.meus_convites() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r record; pagos int; novos int := 0; cod text;
begin
  if me is null then return null; end if;
  cod := _meu_codigo(me);
  select count(*) into pagos from perfis where convidado_por = me and convite_pago;
  for r in select id, (coalesce((hist->'cpu'->>'j')::int,0) + coalesce((hist->'net'->>'j')::int,0)) as jogos
             from perfis where convidado_por = me and not convite_pago order by criado_em for update loop
    exit when pagos >= 20;
    if r.jogos >= 3 then
      update perfis set convite_pago = true where id = r.id;
      update perfis set saldo = saldo + 100 where id = me;
      perform _dar_giz(me, 50);
      pagos := pagos + 1; novos := novos + 1;
      if pagos = 3 then perform _dar_item(me, 'taco', 'padrinho'); end if;
    end if;
  end loop;
  return jsonb_build_object('codigo', cod, 'pagos', pagos, 'novos', novos, 'limite', 20,
    'amigos', coalesce((select jsonb_agg(jsonb_build_object('apelido', apelido, 'jogos',
                 least(3, coalesce((hist->'cpu'->>'j')::int,0) + coalesce((hist->'net'->>'j')::int,0)), 'pago', convite_pago) order by criado_em desc)
               from perfis where convidado_por = me), '[]'::jsonb));
end $$;
grant execute on function public.meus_convites() to authenticated;

-- =====================================================================
-- 3) PASSE DO BAR PAGO (Pix pelo Mercado Pago) — começa DESLIGADO
-- Para ligar depois: update public.config set valor = jsonb_set(valor,'{venda}','true') where chave = 'passe';
-- =====================================================================
create table if not exists public.config (chave text primary key, valor jsonb not null);
alter table public.config enable row level security;
revoke all on public.config from anon, authenticated;
insert into public.config (chave, valor) values ('passe', '{"venda": false, "preco": 9.90}') on conflict (chave) do nothing;

create table if not exists public.compras (
  id uuid primary key default gen_random_uuid(),
  jogador uuid not null references auth.users (id) on delete cascade,
  item text not null default 'passe',
  temp int not null,
  valor numeric(10,2) not null,
  status text not null default 'pendente' check (status in ('pendente','pago','cancelado','estornado')),
  mp_id text,
  criado_em timestamptz not null default now(),
  pago_em timestamptz
);
alter table public.compras enable row level security;
revoke all on public.compras from anon, authenticated;
create index if not exists compras_jogador on public.compras (jogador, criado_em desc);

create or replace function public.passe_info() returns jsonb
language sql security definer set search_path = public stable as $$
  select valor from config where chave = 'passe';
$$;
grant execute on function public.passe_info() to authenticated;

-- liga o passe e entrega na hora os prêmios dourados dos níveis que a pessoa já passou
create or replace function public._ativar_passe(quem uuid, t int) returns void
language plpgsql security definer set search_path = public as $$
declare p temporada_prog%rowtype; r record;
begin
  insert into temporada_prog (jogador, temp) values (quem, t) on conflict do nothing;
  select * into p from temporada_prog where jogador = quem and temp = t for update;
  if p.passe then return; end if;
  update temporada_prog set passe = true where jogador = quem and temp = t;
  for r in select * from _trilha() where _trilha.n <= p.nivel loop
    if r.p_tipo = 'pts' then update perfis set saldo = saldo + r.p_val where id = quem;
    else perform _dar_item(quem, r.p_tipo, r.p_ref); end if;
  end loop;
end $$;

-- chamado só pela função do servidor (Edge Function), nunca pelo jogo
create or replace function public.passe_criar_compra(quem uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; t record; c compras%rowtype;
begin
  select valor into cfg from config where chave = 'passe';
  if not coalesce((cfg->>'venda')::boolean, false) then raise exception 'venda desligada'; end if;
  select * into t from _temporada(); if t.id is null then raise exception 'sem temporada'; end if;
  if exists (select 1 from temporada_prog where jogador = quem and temp = t.id and passe) then raise exception 'já tem o passe'; end if;
  update compras set status = 'cancelado' where jogador = quem and status = 'pendente' and criado_em < now() - interval '40 minutes';
  insert into compras (jogador, temp, valor) values (quem, t.id, (cfg->>'preco')::numeric) returning * into c;
  return jsonb_build_object('id', c.id, 'valor', c.valor, 'temp', t.id, 'nome', t.nome);
end $$;

create or replace function public.passe_guardar_mp(compra uuid, mp text) returns void
language sql security definer set search_path = public as $$
  update compras set mp_id = mp where id = compra;
$$;

-- o webhook confere o pagamento direto no Mercado Pago e chama esta função
create or replace function public.passe_confirmar(compra uuid, mp text, pago numeric, situacao text) returns text
language plpgsql security definer set search_path = public as $$
declare c compras%rowtype;
begin
  select * into c from compras where id = compra for update;
  if not found then return 'nao_achei'; end if;
  if situacao = 'approved' then
    if c.status = 'pago' then return 'ja_pago'; end if;
    if pago < c.valor then return 'valor_errado'; end if;
    update compras set status = 'pago', pago_em = now(), mp_id = mp where id = compra;
    perform _ativar_passe(c.jogador, c.temp);
    return 'pago';
  elsif situacao in ('refunded','charged_back') and c.status = 'pago' then
    update compras set status = 'estornado' where id = compra;
    update temporada_prog set passe = false where jogador = c.jogador and temp = c.temp;
    return 'estornado';
  elsif situacao in ('cancelled','rejected') and c.status = 'pendente' then
    update compras set status = 'cancelado' where id = compra;
    return 'cancelado';
  end if;
  return c.status;
end $$;

revoke execute on function public.passe_criar_compra(uuid) from public, anon, authenticated;
revoke execute on function public.passe_guardar_mp(uuid, text) from public, anon, authenticated;
revoke execute on function public.passe_confirmar(uuid, text, numeric, text) from public, anon, authenticated;
grant execute on function public.passe_criar_compra(uuid) to service_role;
grant execute on function public.passe_guardar_mp(uuid, text) to service_role;
grant execute on function public.passe_confirmar(uuid, text, numeric, text) to service_role;

-- o jogo pergunta se o Pix já caiu
create or replace function public.compra_status(compra uuid) returns text
language sql security definer set search_path = public stable as $$
  select status from compras where id = compra and jogador = auth.uid();
$$;
grant execute on function public.compra_status(uuid) to authenticated;

-- painel: vendas
create or replace function public.vendas_resumo() returns jsonb
language plpgsql security definer set search_path = public stable as $$
begin
  if not _eh_admin() then raise exception 'só o dono do bar'; end if;
  return jsonb_build_object(
    'config', (select valor from config where chave = 'passe'),
    'pagas', (select count(*) from compras where status = 'pago'),
    'bruto', (select coalesce(sum(valor),0) from compras where status = 'pago'),
    'estornos', (select count(*) from compras where status = 'estornado'),
    'pix_gerados', (select count(*) from compras),
    'patrocinio', (select coalesce(sum(valor),0) from patrocinios),
    'convites', jsonb_build_object('entraram', (select count(*) from perfis where convidado_por is not null),
                                   'jogaram', (select count(*) from perfis where convite_pago)));
end $$;
grant execute on function public.vendas_resumo() to authenticated;

-- painel: ligar ou desligar a venda e mudar o preço
create or replace function public.passe_config(venda boolean, preco numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _eh_admin() then raise exception 'só o dono do bar'; end if;
  if preco < 1 or preco > 200 then raise exception 'preço fora do normal'; end if;
  update config set valor = jsonb_build_object('venda', venda, 'preco', round(preco, 2)) where chave = 'passe';
  return (select valor from config where chave = 'passe');
end $$;
grant execute on function public.passe_config(boolean, numeric) to authenticated;
