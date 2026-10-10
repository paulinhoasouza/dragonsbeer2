# Dragons Beer — versão 2

QR Code **fixo por mesa**, cadastro permanente do cliente e contas individuais/compartilhadas simultâneas. Mantém o visual, cardápio e a operação da versão anterior.

## Atualizar o app já instalado

Abra **ATUALIZACAO-V2.html**. A ordem é: finalizar atendimentos anônimos → executar apenas `supabase/04-qr-fixo-clientes.sql` → configurar Supabase Auth → atualizar os arquivos no GitHub → publicar → imprimir os QR Codes fixos.

**Não execute 01-schema.sql novamente no banco existente.** A migração 04 é transacional e pode ser repetida sem alterar os QR Codes ou apagar registros.

## Arquitetura e comportamento

- Cloudflare Worker serve arquivos e `/api/config`; a configuração pública inclui flags dos provedores sociais. `keep_vars: true` preserva variáveis cadastradas no painel em novos deploys.
- Supabase Auth: login permanente por e-mail/senha, Google ou Facebook. Confirmação de e-mail e recuperação por e-mail precisam de SMTP configurado para clientes reais. Provedores sociais precisam das credenciais do proprietário no Supabase.
- O cliente cria o acesso, depois completa nome, CPF e celular. CPF recebe verificação de formato e dígitos no frontend e no banco, sem consulta à Receita Federal nem prova de titularidade. Celular recebe verificação de formato brasileiro; não há SMS de verificação.
- CPF é único por conta e não pode ser trocado pelo cliente depois do cadastro. Nome e celular podem ser corrigidos em Meu cadastro. CPF não é senha nem identificador de login. Não se guarda CPF/celular em metadados de Auth ou auditoria; os dados ficam no schema privado dragons.
- QR contém token aleatório persistente da mesa: `/cliente?mesa=TOKEN`. Não depende do atendimento. O domínio do app deve permanecer igual para os impressos continuarem funcionando.
- Primeiro cliente a escolher a comanda abre um atendimento automaticamente. Caixa também pode abri-lo antes. Cada pessoa escolhe entre sua conta individual e a única conta compartilhada do atendimento; ambas coexistem na mesa.
- A escolha vale durante esse atendimento. Quem escolhe compartilhada vê pedidos e nomes dos demais participantes dessa conta, mas não das individuais. Qualquer participante pode solicitar a conta compartilhada; isso não fecha contas individuais.
- Cada login possui no máximo uma comanda por atendimento. Entrar com a mesma conta em outro aparelho recupera essa comanda. Entrar com outro login corresponde a outra identidade; CPF duplicado é recusado.
- Ao pagar todas as contas, o caixa libera a mesa. Um novo atendimento usa o mesmo QR, sem reaproveitar consumo nem adesões antigas. O histórico permanece armazenado. Mudar ou trocar a escolha após adesão, transferir itens e criar vários grupos compartilhados na mesma mesa não fazem parte desta versão.
- QR fixo é um link compartilhável. Sua posse não comprova presença física na mesa; a versão não implementa confirmação de presença ou aprovação de adesão pelo caixa.

## Operação preservada

Telas `/admin`, `/caixa`, `/cozinha`, `/bar`, `/cliente`. Perfil de equipe validado no servidor a cada operação. Clientes não recebem dados de outras comandas individuais. CPF e celular não são enviados a caixa, cozinha, bar, outros clientes ou ao estado administrativo do app. A equipe administrativa do banco continua tendo acesso pelo Supabase.

Atualização a cada 4 segundos com a tela aberta; aviso persistente e som ativável para conta solicitada. Notificação do sistema depende do navegador e da permissão; não é push com o app fechado. Dados offline não são aceitos como confirmação de pedido.

Pedidos idempotentes por UUID; preços e totais em centavos no servidor; validação de preços desatualizados. Itens percorrem recebido → preparo → pronto → entregue. Pagamento apenas após entrega/cancelamento de todos os itens e conferência do total. Pagamento idempotente e auditado. Relatórios por horário de recebimento em America/Cuiaba.

Pagamento continua presencial: o app registra a confirmação do caixa, não cobra cartões ou Pix. Sem emissão fiscal, estoque de ingredientes, impressoras de produção, estorno financeiro ou taxa de serviço automática.

## Segurança do banco

As tabelas ficam no schema privado `dragons`, com RLS ativada e permissões diretas revogadas para `anon` e `authenticated`. Não exponha esse schema na API.

`public.db_action(op,args)` verifica autenticação, perfil e propriedade. A versão anterior da função é mantida em `dragons.db_action_v1`, sem acesso direto pela API. `public.table_context(token)` é a única leitura pública e retorna somente o nome de uma mesa ativa cujo token foi informado.

Bloqueios de mesa/atendimento serializam adesões e abertura. Comandas são bloqueadas nas operações de consumo/recebimento. O QR não muda ao repetir a migração. Atendimentos antigos são mantidos; finalize os anônimos antes da atualização para evitar clientes presos no fluxo antigo.

## Desenvolvimento e testes

Node.js 22+:

```sh
npm ci
npm test
npm run test:ui
npm run build
npm run dev
```

Para executar localmente, copie `.dev.vars.example` para `.dev.vars`. Para publicar, `npm run deploy`. Não envie `.dev.vars` ao GitHub. `wrangler.jsonc` já usa o nome do Worker existente `dragonsbeer2`.

`npm test`: 26 cenários da base v1 e 23 cenários de migração/fluxos v2 em PostgreSQL embarcado (PGlite). `npm run test:ui`: 15 cenários de interface em DOM simulado. Os dados dos testes são sintéticos, isolados e nunca enviados ao Supabase do usuário.

Esses testes não validam as credenciais Google/Facebook, SMTP, o projeto Supabase real ou a renderização em um navegador real. Faça a homologação indicada no guia antes de atender clientes.

## Instalação do zero (somente projeto novo)

Execute 01-schema.sql, 02-cardapio.sql, crie o usuário de equipe em Auth, edite/execute 03-primeiro-admin.sql e execute 04-qr-fixo-clientes.sql. Para o app já instalado, execute apenas 04.

## Documentação oficial

- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/auth/social-login/auth-facebook
- https://supabase.com/docs/guides/auth/redirect-urls
- https://supabase.com/docs/guides/auth/auth-smtp
- https://developers.cloudflare.com/workers/wrangler/configuration/
