# Como ligar a venda do Passe do Bar (Pix pelo Mercado Pago)

Só faça isso depois de ter o CNPJ, a conta do Mercado Pago no nome da empresa e a conversa com o advogado.
Até lá a venda fica desligada e o jogo mostra "Em breve".

1. **Mercado Pago:** entre em https://www.mercadopago.com.br/developers, crie uma aplicação ("Pagamentos online", produto "Checkout Transparente") e copie o **Access Token de produção** (começa com `APP_USR-`). Ele é secreto: não mande pra ninguém, nem pra mim.
2. **Supabase > Edge Functions > Secrets:** crie o segredo `MP_ACCESS_TOKEN` com esse token.
3. **Supabase > Edge Functions > Deploy a new function > Via Editor:**
   - nome `passe-pix`, cole o conteúdo de `supabase/functions/passe-pix/index.ts`, deixe **Verify JWT ligado**;
   - nome `mp-webhook`, cole o conteúdo de `supabase/functions/mp-webhook/index.ts`, e **desligue Verify JWT** (o Mercado Pago não manda login).
4. **Teste com o token de teste primeiro:** use o Access Token de *teste* no passo 2, ligue a venda no Painel do dono e compre com um usuário de teste do Mercado Pago. Quando o Passe aparecer, troque pelo token de produção.
5. **Painel do dono > Dinheiro:** marque "Venda do Passe ligada", confira o preço e salve.

Para desligar: desmarque no painel. Estorno: devolva pelo Mercado Pago; o aviso chega sozinho e o Passe é retirado (os itens já entregues ficam).
