# Contability Robot v2.0.0

## O que vem neste pacote

| Arquivo | O que é |
|---|---|
| `database/01-migracao-v2.sql` | Atualiza o banco: tabelas do painel, configurações, pausas e a função que responde ao painel. |
| `n8n/workflow-bot-v2.0.0.json` | O bot da Marta atualizado. Ele lê horário, pausas e números do gestor das configurações do painel. |
| `n8n/workflow-painel-api.json` | Workflow pequeno que liga o painel ao banco. É um webhook, então não precisa de servidor novo. |
| `painel/index.html` | O painel do escritório. É um arquivo único. |

## O que mudou

### Painel do escritório
- **Solicitações:** quadro com as colunas Abertas, Em andamento e Encerradas.
  - Você pode arrastar os cartões entre as colunas.
  - Cada solicitação tem responsável, prioridade, anotações internas, histórico e link direto para a conversa no WhatsApp.
  - Há filtros por condomínio, tipo, responsável e atraso.
  - O quadro se atualiza sozinho a cada minuto e avisa quando chega solicitação nova.
- **Indicadores:**
  - abertas, em andamento, fora do prazo e sem responsável;
  - concluídas e tempo médio até concluir;
  - gráfico de solicitações por dia;
  - ranking por tipo de serviço e por condomínio.
- **Condomínios:** cadastro e edição com endereço, cidade, CNPJ, síndico e observações. Um condomínio inativo some da lista que a Marta usa.
- **Atendimento humano:** mostra os contatos em que a Marta está pausada. Dali você devolve o contato para ela com um clique ou pausa um número manualmente.
- **Configurações:**
  - Marta ligada ou desligada;
  - dias e horário de atendimento, feriados e mensagem de fora do horário;
  - prazo de atendimento (SLA);
  - tempo de pausa quando a equipe responde;
  - resposta para áudio, foto ou documento;
  - números do gestor.
- **Usuários:** cada pessoa tem login próprio, com papel de administrador ou atendente.
  - Depois de 5 senhas erradas, o login fica bloqueado por 15 minutos.

### Bot da Marta
- **Horário de atendimento:** quem decide agora é o banco, não a IA. Fora do expediente ou em feriado, a Marta envia só o aviso, uma vez a cada 4 horas por contato (esse intervalo é configurável).
- **Pausa por atendimento humano:** antes ficava no Redis, agora fica no banco, e por isso aparece no painel.
- **Números do gestor:** saem do painel. Antes ficavam fixos no fluxo, e por isso não funcionavam.
- **Áudio, imagem, vídeo e documento:** a Marta pede para o cliente escrever. Antes ela ficava muda.
- **Correções da v1:**
  - a busca de solicitações em aberto usava o id no lugar do telefone;
  - o cliente novo não conseguia abrir chamado;
  - o buffer repetia mensagens antigas;
  - o `search_condominio` trazia só 20 condomínios.
- **Contexto de solicitações em aberto:** a Marta passa a ver as solicitações em aberto do cliente e pergunta se o contato é sobre elas antes de registrar outra.

## Instalação (cerca de 20 minutos)

1. **Faça backup do banco** (o mesmo da credencial `Sandro_banco`).

2. **Rode `database/01-migracao-v2.sql` nesse banco.** Pode ser pelo pgAdmin, pelo DBeaver ou pelo `psql`.
   - A migração só acrescenta coisas: nada da v1 é apagado.
   - Pode ser executada de novo sem problema.
   - Se aparecer erro de permissão no `CREATE EXTENSION pgcrypto`, peça para o administrador do banco habilitar essa extensão.

3. **Importe no n8n o `n8n/workflow-painel-api.json`.**
   - No nó "Painel - Executar ação", selecione a credencial Postgres `Sandro_banco`.
   - Ative o workflow.
   - Abra o nó "Painel - Webhook" e copie a **Production URL**. Ela termina em `/webhook/painel-api`.

4. **Importe o `n8n/workflow-bot-v2.0.0.json`.**
   - Confira se todos os nós ficaram com as credenciais certas: Postgres, Redis, Evolution, OpenAI e Gemini.
   - **Desative o workflow da v1** e depois **ative o da v2**. Os dois usam o mesmo endereço de webhook, então a Evolution não precisa de nenhuma mudança.

5. **Publique o painel.** O jeito recomendado é pelo Easypanel com deploy automático: siga a seção "Deploy na VPS (Easypanel)" do `README.md`.
   - Alternativa sem Docker: abra `painel/index.html` num editor, preencha `const PAINEL_API_URL = '...'` com a URL copiada no passo 3 e hospede o arquivo em qualquer servidor com HTTPS.

6. **Primeiro acesso:** entre com `admin@escritorio.com` e a senha `TroqueEstaSenha123`.
   - **Troque a senha na hora** (menu "Minha senha").
   - Em **Configurações**, confira o horário e cadastre os **números do gestor**.
   - Em **Usuários**, crie um login para cada pessoa da equipe.
   - Em **Condomínios**, complete os cadastros.

## Teste rápido depois de instalar

- [ ] Mande uma mensagem de um número de cliente dentro do horário. A Marta deve responder com o menu.
- [ ] No painel, mude o término do expediente para um horário que já passou e mande outra mensagem. Deve chegar só o aviso de fora do horário. Depois volte o horário.
- [ ] Responda um cliente pelo celular do WhatsApp. O contato deve aparecer em "Atendimento humano".
- [ ] Mande um áudio. A Marta deve pedir para você escrever.
- [ ] Mande mensagem de um número do gestor. Deve responder a assistente do gestor.
- [ ] Conclua uma solicitação pelo painel e confira os indicadores.

## Para voltar à v1

Desative o workflow v2 e ative de novo o da v1. A migração não interfere no funcionamento da v1.

## Pontos para acompanhar

- **Pausas do Redis:** as pausas de atendimento humano que estavam ativas no Redis no momento da troca não são migradas. Esses contatos voltam a ser atendidos pela Marta.
- **Mensagens enviadas pelo próprio bot:** se a sua Evolution reenviar ao webhook as mensagens que o bot manda (com `fromMe = true`), o bot vai se pausar sozinho. Se os contatos aparecerem em "Atendimento humano" sem ninguém ter respondido, é isso. Me avise que eu ajusto o filtro.
- **Execuções da API:** o workflow da API não guarda o histórico de execuções bem-sucedidas no n8n, para que senhas de login não fiquem registradas lá.
