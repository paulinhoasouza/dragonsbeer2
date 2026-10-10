# Dragons Beer — Supabase + Cloudflare

Aplicação para um estabelecimento, com telas `/cliente`, `/caixa`, `/cozinha`, `/bar` e `/admin`. Mantém marca, imagens e os 41 produtos do HTML enviado. O cardápio foi importado como estava: confira preços e disponibilidade antes de atender.

**Abra LEIA-ME.html para a instalação guiada.**

## Arquitetura

- Cloudflare Worker entrega a interface e `/api/config` com a URL e chave **pública** do Supabase.
- Supabase Auth autentica equipe com e-mail/senha e clientes com sessão anônima.
- PostgreSQL mantém produtos, mesas, atendimentos, comandas, membros, pedidos, itens, pagamentos e auditoria.
- Único ponto de entrada: RPC `public.db_action(op, args)`. Cada operação valida identidade, vínculo e perfil no servidor.
- Tabelas no schema privado `dragons`, RLS habilitada e sem concessões de acesso direto a `anon`/`authenticated`. Schema privado não deve ser adicionado aos schemas expostos pela API.
- Atualização automática a cada 4 segundos enquanto a tela está aberta, mais recuperação ao voltar para a aba ou reconectar. Sem dependência de Supabase Realtime. Não é push com a aplicação fechada.

## Comandos

Requer Node.js 22 ou superior.

```sh
npm ci
npm test
npm run test:ui
npm run build
npm run dev
npm run deploy
```

Para uso local, copie `.dev.vars.example` para `.dev.vars` e configure as chaves públicas. Nunca envie `.dev.vars` ao GitHub. No Cloudflare, use as variáveis de runtime.

## Instalação resumida

1. Crie um projeto Supabase novo e exclusivo para este bar.
2. Execute `supabase/01-schema.sql` UMA VEZ e depois `supabase/02-cardapio.sql` no SQL Editor. Não há apagamento de tabelas. A primeira migração é transacional e falha se já estiver instalada.
3. Ative anonymous sign-ins em Authentication. Mantenha o cadastro público por email desativado; funcionários são criados pelo administrador.
4. Crie o usuário administrador em Authentication > Users > Add user, com Auto Confirm User. Edite e execute `supabase/03-primeiro-admin.sql` com o mesmo e-mail.
5. Suba o conteúdo desta pasta para um repositório GitHub. `package.json` e `wrangler.jsonc` precisam ficar na raiz selecionada no Cloudflare.
6. Cloudflare Workers & Pages > Create > Import repository. Build: `npm run build`. Deploy: `npx wrangler deploy`. Se o assistente perguntar instalação: `npm ci`.
7. Configure `SUPABASE_URL` e `SUPABASE_PUBLISHABLE_KEY` em Settings > Variables and Secrets do Worker, usando a URL do projeto e a chave publishable (ou legacy anon). **Nunca use service_role, secret key ou senha do banco.**
8. Publique novamente após configurar as variáveis. Abra `/admin`, cadastre as mesas e vincule a equipe. Teste o atendimento completo em vários dispositivos antes do uso real.

## Modelo operacional

O caixa abre uma mesa e escolhe conta compartilhada ou individual. O QR Code/link contém um token aleatório do atendimento e expira quando a mesa é liberada. Precisa ser exibido ou impresso de novo a cada atendimento. Não é um QR Code permanente colado na mesa.

Em modo compartilhado, todos os clientes admitidos na mesa veem os pedidos, nomes informados e total da mesma conta; qualquer membro pode solicitar o fechamento da conta inteira. Em modo individual, cada identidade anônima de navegador possui uma comanda distinta. Não há cadastro de cliente com senha. Trocar de aparelho ou apagar dados do navegador não recupera automaticamente a mesma comanda; o caixa continua podendo encerrá-la. Duas pessoas no mesmo navegador compartilham a identidade. Use um celular por comanda individual.

Os itens passam por recebido → em preparo → pronto → entregue. Bar e cozinha só leem e avançam seus próprios itens; caixa/admin podem operar ambos. Pedido de conta não interrompe o preparo já iniciado. O caixa assume a solicitação, registra a forma realmente recebida e confirma o recebimento. Não é integrado com Pix, adquirentes ou maquininha. O servidor bloqueia pagamento se existir item não entregue/não cancelado. Itens cancelados conservam motivo e histórico. Comandas vazias podem ser encerradas com valor zero. Mesa só é liberada quando todas as comandas estiverem pagas.

## Confiabilidade e segurança

- Preços, setor e nomes dos itens são copiados do banco no momento do pedido; totais são calculados em centavos no servidor.
- Pedido inclui UUID persistido antes do envio. Reenvio usa o mesmo UUID; duplicados retornam o pedido existente. Falha de rede conserva o envio pendente.
- Operações transacionais bloqueiam a comanda antes de alterar itens, fechar ou pagar. Pagamento tem unicidade por comanda e confere o total mostrado ao caixa.
- Abertura de mesa e adesão de clientes são serializadas por mesa/atendimento. Novo atendimento não reutiliza saldo nem token.
- Regras de acesso verificadas a cada chamada; revogar acesso da equipe bloqueia próximas operações mesmo com sessão ainda válida.
- HTML dinâmico escapa texto. O token de mesa não é enviado como referrer; QR Codes são gerados localmente, sem serviço externo.
- Os arquivos do frontend não contêm service_role nem credenciais administrativas. Chave publishable é pública por definição; não dá acesso direto às tabelas.
- Ative CAPTCHA no Supabase Auth para a entrada anônima em ambiente público; Turnstile suportado via `TURNSTILE_SITE_KEY` e configuração do segredo no Supabase. Reveja limites de autenticação para o volume de clientes usando o mesmo Wi-Fi.

## Limites desta entrega

Sem emissão fiscal, estoque por ingredientes, integração com impressoras, delivery, pagamentos online, múltiplos estabelecimentos, transferência entre comandas, divisão parcial de uma conta compartilhada ou estorno de pagamento confirmado. Comandas individuais atendem à cobrança separada por cliente. Taxa de serviço não é adicionada automaticamente. Para um erro em pagamento já confirmado, preserve a auditoria e trate a correção antes de alterar o banco; não apague registros manualmente.

Alertas: banner persistente, contador na aba e som após clicar em “Ativar som”. Notificações do sistema são opcionais, sujeitas a permissão/suporte do navegador, com a página aberta. Aba suspensa ou aparelho bloqueado pode atrasar sincronização; mantenha os terminais da operação ativos. A interface sinaliza falha de conexão; pedidos só são confirmados após resposta do backend.

Relatórios consideram somente comandas pagas no intervalo, pelo horário de recebimento em `America/Cuiaba`. Valores por produto excluem cancelamentos. CSV de pagamentos usa ponto e vírgula e protege células de texto contra fórmulas.

## Validação

`tests/backend.mjs` executa a migração completa e cenários de autorização, estado e consistência em PostgreSQL embarcado (PGlite), com usuários exclusivamente de teste. `tests/ui.mjs` verifica navegação e interações de interface em DOM simulado. Não substituem teste no projeto real nem QA visual de navegador. Os testes não enviam pedidos nem criam dados no Supabase do usuário.

## Documentação oficial consultada

- https://supabase.com/docs/guides/auth/auth-anonymous
- https://supabase.com/docs/guides/database/functions
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://developers.cloudflare.com/workers/static-assets/
