# contability-board

Painel do escritório e bot de WhatsApp da **Marta**, a assistente virtual de atendimento condominial. O bot roda no n8n com a Evolution API. O painel é uma página web que usa o próprio n8n como API, então não precisa de servidor novo.

Versão atual: **v2.0.0**

## O que tem aqui

| Pasta | Conteúdo |
|---|---|
| `database/` | `01-migracao-v2.sql`: atualiza o banco (tabelas do painel, configurações, pausas e a função `painel.api`). Também traz um banco simulado e um roteiro de testes da API. |
| `n8n/` | `workflow-bot-v2.0.0.json`: o bot da Marta. `workflow-painel-api.json`: o webhook que liga o painel ao banco. |
| `painel/` | `index.html`: o painel do escritório, num arquivo único. Também tem `Dockerfile` e `default.conf.template` (nginx) para publicar na VPS. |
| `docs/` | Guia de instalação e o prompt da Marta da versão 1.0.1. |
| `tools/` | Scripts que geraram os workflows e o painel a partir da v1. |
| `.github/workflows/deploy.yml` | CI/CD: testa, gera a imagem do painel e publica na VPS. |
| `docker-compose.easypanel.yml` | Serviço Compose do Easypanel (só o painel). |

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
5. Publique o painel na VPS pelo Easypanel (seção abaixo).
6. Entre com o admin inicial e **troque a senha no primeiro acesso**.

## Deploy na VPS (Easypanel)

Mesmo padrão do erp-bot: quem builda é o GitHub Actions, e a VPS só faz `docker pull` da imagem pronta.

```
.github/workflows/deploy.yml     # testa, builda a imagem e dispara o deploy
docker-compose.easypanel.yml     # serviço "painel" (sem ports/container_name)
painel/Dockerfile                # usado só pelo GitHub Actions, não pela VPS
painel/default.conf.template     # nginx: serve o painel e repassa /api/painel ao n8n
.env.easypanel.example           # variável a colar no Environment do Easypanel
```

O painel chama o caminho relativo `/api/painel`, e o nginx do próprio container repassa a chamada para o webhook "Painel API" do n8n. Assim não tem CORS, e a URL do n8n fica no Environment do Easypanel, não dentro do HTML.

### O que acontece a cada push na `main`

1. `test-database`: sobe um Postgres 16, roda a migração duas vezes e executa as verificações de `database/tests/asserts.sql`.
2. `validate-files`: confere os workflows do n8n (JSON válido, sem ligação para nó inexistente) e a sintaxe do JavaScript do painel.
3. `build-and-push-image`: builda a imagem, sobe o container e testa se ele responde. Só então publica `ghcr.io/ldssborges/contability-board-painel` com as tags `:latest` e `:<commit>`.
4. `deploy`: chama a Deployment Trigger URL do Easypanel (secret `EASYPANEL_DEPLOY_HOOK`). Tenta 5 vezes. Se o secret não existir, só avisa, e aí é clicar em **Implantar** no Easypanel.

Em pull requests rodam só os testes e o build. Nada é publicado.

### Configuração (uma vez só)

1. Faça um push na `main` e espere o job `build-and-push-image` passar.
2. Deixe o pacote público: perfil do GitHub → **Packages** → `contability-board-painel` → **Package settings** → **Change visibility** → **Public**. A imagem não tem nenhum segredo, porque a URL do n8n vem de variável de ambiente.
3. No Easypanel, dentro do projeto: **+ Service → Compose**.
   - **Source:** Git, `https://github.com/ldssBorges/contability-board.git`, branch `main`.
   - **Build Path:** `/`.
   - **Docker Compose File:** `docker-compose.easypanel.yml`.
4. Em **Environment**, cole o conteúdo de `.env.easypanel.example` com a URL de produção do webhook "Painel API".
5. Clique em **Implantar**.
6. Em **Domains**, adicione um domínio apontando para o serviço `painel`, porta `80`. Exemplo: `painel.seudominio.com`.
7. Para o deploy automático:
   - copie a **Deployment Trigger URL** na aba **Implantações** do serviço;
   - no GitHub, vá em **Settings → Secrets and variables → Actions → New repository secret**;
   - crie o secret `EASYPANEL_DEPLOY_HOOK` com a URL copiada.

A partir daí, cada push na `main` testa, publica e atualiza o painel sozinho, sem pesar na VPS.

### O que o CI não faz

A migração do banco e a importação dos workflows no n8n continuam manuais (veja `docs/INSTALACAO.md`). Rodar migração em produção automaticamente é arriscado demais para um passo sem revisão.

## Testar sem banco

Abra `painel/index.html` no navegador e clique em **"Ver demonstração com dados de exemplo"**. Os dados ficam só na memória do navegador.

## Segurança

- Os workflows apontam para as credenciais do n8n pelo nome. Nenhuma chave de API está neste repositório.
- A migração cria o usuário `admin@escritorio.com` com uma senha inicial conhecida. Troque essa senha logo depois de instalar.
- Se o repositório for público, lembre que os prompts da Marta e a estrutura do banco ficam visíveis.
