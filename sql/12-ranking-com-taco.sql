-- Sinuca de Bar: ranking mostra o taco de cada jogador. Rode inteiro no SQL Editor.
create or replace function public.ranking_semana() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare s date := _semana(); me uuid := auth.uid(); camp uuid := _campeao(_semana() - 7); lista jsonb; eu jsonb;
begin
  with t as (
    select r.jogador, r.moral, r.j, r.v, p.apelido, p.xp, coalesce(p.dados->>'ico', 'oito') as ico, coalesce(p.dados->>'eq', 'casa') as taco,
           row_number() over (order by r.moral desc, r.v desc, r.atualizado asc) as pos
      from ranking r join perfis p on p.id = r.jogador where r.semana = s)
  select coalesce(jsonb_agg(jsonb_build_object('pos', pos, 'id', jogador, 'apelido', apelido, 'moral', moral, 'j', j, 'v', v, 'xp', xp, 'ico', ico, 'taco', taco) order by pos) filter (where pos <= 50), '[]'::jsonb),
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
