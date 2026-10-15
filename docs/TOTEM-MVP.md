# Dragons Beer — Totem, pagamento imediato e retirada centralizada

## Entrega 1 — Fundação de dados (proposta de alteração)

Esta entrega adiciona `supabase/06-totem-foundation.sql`. **Não altera o aplicativo publicado nem conecta o Mercado Pago**. A migração só deve ser executada depois de revisão e homologação no banco de testes; nunca reaplicar `01-schema.sql` na produção existente.

### Operação definida
1. O cliente monta o carrinho no totem, sem conta, CPF ou QR de mesa.
2. O backend registra pedido `awaiting_payment`, com preços calculados **no banco**.
3. O backend solicita cobrança no provedor, que envia o cartão à Point ou fornece QR de Pix.
4. O backend recebe notificação, **valida com o provedor**, compara valores, estado, referência, loja e moeda, e só depois chama `kiosk_approve_verified_payment`.
5. A aprovação transacional gera senha do dia, registros de seção e **um ticket por setor** com código exclusivo; o mini-PC imprime.
6. O funcionário leva produtos ao balcão único e lê o código impresso por setor. Leituras repetidas não alteram contadores.
7. Quando todas as seções são recebidas, o pedido passa a `ready` e entra na fila de chamada. Um controlador compatível chama a senha no painel LED e registra confirmação.
8. A confirmação de entrega ao cliente será implementada em próxima entrega.

### Principais tabelas
- `kiosk_orders`: pedidos, estados, senha diária e totais.
- `kiosk_items`: cópia histórica de preço, setor e produto.
- `kiosk_payment_attempts`: identificador do provedor e estado financeiro.
- `kiosk_daily_counters`: atribuição atômica de número.
- `kiosk_sections`: tickets de bar/cozinha e códigos de leitura independentes.
- `kiosk_print_jobs`: fila com tentativa, lease e confirmação.
- `kiosk_calls`: fila de anúncio de senhas no letreiro.

### Segurança
- Todas as tabelas em `dragons`, com RLS e acesso direto revogado.
- Funções RPC só acessíveis ao `service_role` no servidor, nunca no JavaScript enviado ao totem.
- **Não exponha RPCs de aprovação/scan/ack por rotas públicas.** Rotas futuras exigirão autenticação de dispositivos, autorização por operação e rate limiting.
- A função de aprovação **não valida o pagamento por conta própria**; ela exige verificação externa no backend. Não a acione por callback de cliente ou webhook não verificado.
- Aprovado não significa liquidado para fins de conciliação. Reembolsos e chargebacks precisarão de reconciliação.
- A fila de impressão pode reenviar em caso de falha. Para exatamente uma impressão física, serão necessários deduplicação local, confirmação e regras de reimpressão.

### Pendências antes de instalar
- Implementar endpoints Workers autenticados para criação, status e integração de pagamento.
- Escolher o modelo exato do Point, obter conta comercial, credenciais e autenticação.
- Testar opção Pix sem cadastro/CPF e contingência, conforme APIs/contrato da conta.
- Implementar mini-PC/agent com impressão ESC/POS e scanner USB.
- Escolher painel LED com protocolo aberto e escrever adaptador.
- Implementar interface `/totem`, recibo/senha, disponibilidade e tratamento de falhas.
- Adicionar rotina de cancelamento/expiração de cobranças, restituição, reimpressão e conclusão de retirada.
- Criar testes SQL e de integração antes de rodar a migração em produção.

### Observação
O banco existente (mesas, comandas e pagamentos manuais) é preservado. Esta migração inaugura um novo caminho; **não deve ser tratada como sistema pronto para operar ao público**.
