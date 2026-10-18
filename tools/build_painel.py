"""Gera as duas versões do painel a partir de painel/index.html (fragmento):
- painel-v2.0.0.html: documento completo para hospedar (servidor, Netlify, pasta do n8n...)
- painel-demo.html: fragmento que abre direto na demonstração (para visualizar como artifact)
Uso: build_painel.py <saida_completo> <saida_demo> [url_api]
"""
import sys

src = open('/home/claude/v2/painel/index.html', encoding='utf-8').read()
full_out, demo_out = sys.argv[1], sys.argv[2]
api_url = sys.argv[3] if len(sys.argv) > 3 else ''

full = src.replace("const PAINEL_API_URL = '';", f"const PAINEL_API_URL = '{api_url}';")
full = ('<!doctype html>\n<html lang="pt-BR">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        '<meta name="robots" content="noindex">\n'
        + full.replace('<style>', '<style>\nbody { margin: 0; }', 1).replace('<div id="login"', '</head>\n<body>\n<div id="login"', 1)
        + '\n</body>\n</html>\n')
open(full_out, 'w', encoding='utf-8').write(full)

demo = src.replace("const INICIAR_EM_DEMO = false;", "const INICIAR_EM_DEMO = true;")
open(demo_out, 'w', encoding='utf-8').write(demo)
print('ok')
