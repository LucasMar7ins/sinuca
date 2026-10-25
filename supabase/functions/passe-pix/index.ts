// Sinuca de Bar: gera o Pix do Passe do Bar no Mercado Pago.
// Segredos (Edge Functions > Secrets): MP_ACCESS_TOKEN. SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm prontos.
// Deixe "Verify JWT" LIGADO nesta função.
const SB = Deno.env.get('SUPABASE_URL') ?? '';
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const MP = Deno.env.get('MP_ACCESS_TOKEN') ?? '';
const MPAPI = Deno.env.get('MP_API') ?? 'https://api.mercadopago.com';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const resp = (code: number, body: unknown) =>
  new Response(JSON.stringify(body), { status: code, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  let d: any = null; try { d = t ? JSON.parse(t) : null; } catch (_) { d = t; }
  if (!r.ok) throw new Error((d && d.message) || 'erro no banco');
  return d;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return resp(405, { erro: 'use POST' });

  const u = await fetch(`${SB}/auth/v1/user`, { headers: { Authorization: req.headers.get('authorization') ?? '', apikey: SR } });
  if (!u.ok) return resp(401, { erro: 'Entre na sua conta de novo.' });
  const user = await u.json();
  if (!MP) return resp(503, { erro: 'A venda ainda não foi ligada.' });

  let c: any;
  try { c = await rpc('passe_criar_compra', { quem: user.id }); }
  catch (e) {
    const m = String((e as Error).message);
    return resp(400, { erro: /já tem/.test(m) ? 'Você já tem o Passe desta temporada.' : /desligada/.test(m) ? 'A venda ainda não foi ligada.' : 'Não deu pra gerar o Pix agora.' });
  }

  const expira = new Date(Date.now() + 30 * 60 * 1000);
  const p = await fetch(`${MPAPI}/v1/payments`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${MP}`, 'Content-Type': 'application/json', 'X-Idempotency-Key': c.id },
    body: JSON.stringify({
      transaction_amount: Number(c.valor),
      description: `Passe do Bar - ${c.nome}`,
      payment_method_id: 'pix',
      payer: { email: user.email },
      external_reference: c.id,
      notification_url: `${SB}/functions/v1/mp-webhook`,
      date_of_expiration: expira.toISOString().replace('Z', '+00:00'),
    }),
  });
  const pay = await p.json().catch(() => ({}));
  const td = pay?.point_of_interaction?.transaction_data;
  if (!p.ok || !td?.qr_code) return resp(502, { erro: 'O Mercado Pago não respondeu. Tente de novo em instantes.' });
  await rpc('passe_guardar_mp', { compra: c.id, mp: String(pay.id) }).catch(() => null);
  return resp(200, { compra: c.id, valor: c.valor, qr: td.qr_code, img: td.qr_code_base64, expira: expira.toISOString() });
}

if ((globalThis as any).Deno?.serve) Deno.serve(handler);
