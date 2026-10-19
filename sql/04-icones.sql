-- Sinuca de Bar: compra de ícones com pontos
-- Cole tudo no Supabase em SQL Editor > New query e clique em Run. Pode rodar mais de uma vez.

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

-- ícones comprados (para não perder se o aparelho for trocado)
create or replace function public.meus_icones() returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce(ctl->'icones','[]'::jsonb) from perfis where id = auth.uid();
$$;
grant execute on function public.meus_icones() to authenticated;
