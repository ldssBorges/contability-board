# Imagem do painel: nginx servindo o index.html estático.
# Usada só pelo GitHub Actions (que builda e publica no GHCR); a VPS apenas faz
# `docker pull`, mesmo padrão do erp-bot.
FROM nginx:alpine

COPY index.html /usr/share/nginx/html/index.html

# Mesma origem: o painel chama o caminho relativo /api/painel e o nginx deste
# container repassa para o webhook "Painel API" do n8n (N8N_PAINEL_WEBHOOK_URL).
# Sem CORS e sem URL fixa dentro do HTML — a URL real fica no Environment do Easypanel.
RUN sed -i "s#^const PAINEL_API_URL = '';#const PAINEL_API_URL = '/api/painel';#" /usr/share/nginx/html/index.html \
 && grep -q "^const PAINEL_API_URL = '/api/painel';" /usr/share/nginx/html/index.html

# A imagem oficial do nginx roda envsubst em /etc/nginx/templates/*.template na
# subida do container e grava o resultado em /etc/nginx/conf.d/.
COPY default.conf.template /etc/nginx/templates/default.conf.template
RUN rm -f /etc/nginx/conf.d/default.conf

EXPOSE 80
