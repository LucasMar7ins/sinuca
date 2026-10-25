// Sinuca de Bar: o Mercado Pago avisa aqui quando um Pix muda de situação.
// A função NÃO confia no aviso: busca o pagamento direto no Mercado Pago antes de liberar o Passe.
// Deixe "Verify JWT" DESLIGADO nesta função (o Mercado Pago não manda login).
const SB = Deno.env.get('SUPABASE_URL') ?? '';
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const MP = Deno.env.get('MP_ACCESS_TOKEN') ?? '';
const MPAPI = Deno.env.get('MP_API') ?? 'https://api.mercadopago.com';

export async function handler(req: Request): Promise<Response> {
  if (req.method !== 'POST') return new Response('ok');
  const url = new URL(req.url);
  const body: any = await req.json().catch(() => ({}));
  const tipo = body?.type ?? url.searchParams.get('type') ?? url.searchParams.get('topic');
  const id = String(body?.data?.id ?? url.searchParams.get('data.id') ?? url.searchParams.get('id') ?? '');
  if (tipo !== 'payment' || !/^\d+$/.test(id) || !MP) return new Response('ignorado');

  const r = await fetch(`${MPAPI}/v1/payments/${id}`, { headers: { Authorization: `Bearer ${MP}` } });
  if (r.status === 404) return new Response('pagamento não existe');
  if (!r.ok) return new Response('mp fora', { status: 500 }); // o Mercado Pago tenta de novo
  const pay = await r.json();
  if (!pay.external_reference) return new Response('sem referência');

  const c = await fetch(`${SB}/rest/v1/rpc/passe_confirmar`, {
    method: 'POST',
    headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ compra: pay.external_reference, mp: id, pago: Number(pay.transaction_amount ?? 0), situacao: String(pay.status) }),
  });
  if (c.status >= 500) return new Response('banco fora', { status: 500 });
  if (!c.ok) return new Response('referência inválida');
  return new Response(await c.text());
}

if ((globalThis as any).Deno?.serve) Deno.serve(handler);
