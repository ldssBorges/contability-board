# contability-board

Painel do escritório e bot de WhatsApp da **Marta**, a assistente virtual de atendimento condominial. O bot roda no n8n com a Evolution API. O painel é uma página web que usa o próprio n8n como API, então não precisa de servidor novo.

Versão atual: **v2.0.0**

## O que tem aqui

| Pasta | Conteúdo |
|---|---|
| `database/` | `01-migracao-v2.sql`: atualiza o banco (tabelas do painel, configurações, pausas e a função `painel.api`). Também traz um banco simulado e um roteiro de testes da API. |
| `n8n/` | `workflow-bot-v2.0.0.json`: o bot da Marta. `workflow-painel-api.json`: o webhook que liga o painel ao banco. |
| `painel/` | `index.html`: o painel do escritório, num arquivo único. |
| `docs/` | Guia de instalação e o prompt da Marta da versão 1.0.1. |
| `tools/` | Scripts que geraram os workflows e o painel a partir da v1. |

## Funcionalidades

- **Solicitações:** quadro com as colunas Abertas, Em andamento e Encerradas.
  - Cada solicitação tem responsável, prioridade, anotações internas, histórico e alerta de prazo.
  - O quadro se atualiza sozinho a cada minuto.
- **Indicadores:** volume por dia, por tipo de serviço e por condomínio, tempo médio até concluir e solicitações fora do prazo.
- **Condomínios:** cadastro e edição. A Marta usa só a lista de condomínios ativos.
- **Atendimento humano:** mostra os contatos em que a Marta está pausada e permite devolvê-los para ela.
- **Configurações:** horário de atendimento, feriados, mensagens, prazo de atendimento, tempo de pausa, números do gestor e liga/desliga da Marta.
- **Usuários:** login por pessoa, com papel de administrador ou atendente.

## Instalação

O passo a passo completo está em [`docs/INSTALACAO.md`](docs/INSTALACAO.md). Em resumo:

1. Faça backup do banco e rode `database/01-migracao-v2.sql`.
2. Importe os dois workflows de `n8n/` e selecione as suas credenciais.
3. Ative o workflow da API e copie a URL de produção do webhook.
4. Ative o workflow do bot no lugar do da v1.
5. Preencha `PAINEL_API_URL` em `painel/index.html` e hospede o arquivo em qualquer servidor com HTTPS.
6. Entre com o admin inicial e **troque a senha no primeiro acesso**.

## Testar sem banco

Abra `painel/index.html` no navegador e clique em **"Ver demonstração com dados de exemplo"**. Os dados ficam só na memória do navegador.

## Segurança

- Os workflows apontam para as credenciais do n8n pelo nome. Nenhuma chave de API está neste repositório.
- A migração cria o usuário `admin@escritorio.com` com uma senha inicial conhecida. Troque essa senha logo depois de instalar.
- Se o repositório for público, lembre que os prompts da Marta e a estrutura do banco ficam visíveis.
