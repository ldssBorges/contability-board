"""Gera o workflow do bot v2.0.0 a partir do v1.0.0."""
import json, sys, uuid

src, dst = sys.argv[1], sys.argv[2]
wf = json.load(open(src))
N = {n['name']: n for n in wf['nodes']}
C = wf['connections']
PG = N['create_event1']['credentials']
EVO = N['Enviar texto7']['credentials']
REDIS = N['Redis1']['credentials']


def nid():
    return str(uuid.uuid4())


def remove(name):
    wf['nodes'] = [n for n in wf['nodes'] if n['name'] != name]
    N.pop(name, None)
    C.pop(name, None)
    for src_conns in C.values():
        for typ in src_conns.values():
            for out in typ:
                out[:] = [x for x in out if x['node'] != name]


def add(node):
    node.setdefault('id', nid())
    wf['nodes'].append(node)
    N[node['name']] = node
    return node


def main(*targets):
    return [[{"node": t, "type": "main", "index": 0} for t in out] for out in targets]


def must_replace(text, old, new):
    assert old in text, f'trecho não encontrado: {old[:60]!r}'
    return text.replace(old, new, 1)


PHONE = "{{ $('Configuração global').first().json.phoneNumber }}"
INSTANCE = "={{ $('Webhook').first().json.body.instance }}"

# ---------------------------------------------------------------- metadados
wf['name'] = 'Contability-Robot-v2.0.0'
wf['active'] = False
wf.pop('id', None)
wf.pop('versionId', None)
wf['settings']['timezone'] = 'America/Sao_Paulo'

# ---------------------------------------------------------------- 1. Pausa e decisão vão para o Postgres
remove('Agente BLOCKED')
remove('Redis')
remove('If_blocked')

add({
    "parameters": {
        "operation": "executeQuery",
        "query": "SELECT attendance_bot.fn_pausar($1) AS pausa",
        "options": {"queryReplacement": "=" + PHONE}
    },
    "type": "n8n-nodes-base.postgres", "typeVersion": 2.6, "position": [976, 464],
    "name": "Bot - Pausar (humano respondeu)", "credentials": PG,
    "notes": "Quando alguém do escritório responde pelo WhatsApp, a Marta sai da conversa pelo tempo configurado no painel."
})
add({
    "parameters": {
        "operation": "executeQuery",
        "query": "SELECT attendance_bot.fn_decidir($1) AS decisao",
        "options": {"queryReplacement": "=" + PHONE}
    },
    "type": "n8n-nodes-base.postgres", "typeVersion": 2.6, "position": [928, 688],
    "name": "Bot - Decidir ação", "credentials": PG,
    "notes": "Lê as configurações do painel: bot ligado, pausa por atendimento humano, horário/feriados e números do gestor."
})


def rule(key, values, left):
    return {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
            "conditions": [{
                "id": nid(), "leftValue": left, "rightValue": v,
                "operator": {"type": "string", "operation": "equals"}
            } for v in values],
            "combinator": "or"
        },
        "renameOutput": True, "outputKey": key
    }


add({
    "parameters": {
        "rules": {"values": [
            rule("Atender", ["cliente", "gestor"], "={{ $json.decisao.acao }}"),
            rule("ForaDoHorario", ["fora_horario"], "={{ $json.decisao.acao }}"),
        ]},
        "options": {"fallbackOutput": "extra", "renameFallbackOutput": "Silenciar"}
    },
    "type": "n8n-nodes-base.switch", "typeVersion": 3.2, "position": [1088, 688],
    "name": "Bot - Ação"
})
add({
    "parameters": {
        "resource": "messages-api", "instanceName": INSTANCE,
        "remoteJid": "=" + PHONE,
        "messageText": "={{ $('Bot - Decidir ação').first().json.decisao.mensagem }}",
        "options_message": {"delay": 1200}
    },
    "type": "n8n-nodes-evolution-api.evolutionApi", "typeVersion": 1, "position": [1264, 944],
    "name": "Bot - Aviso fora do horário", "credentials": EVO
})
add({
    "parameters": {
        "resource": "messages-api", "instanceName": INSTANCE,
        "remoteJid": "=" + PHONE,
        "messageText": "={{ $('Bot - Decidir ação').first().json.decisao.mensagem_midia }}",
        "options_message": {"delay": 1200}
    },
    "type": "n8n-nodes-evolution-api.evolutionApi", "typeVersion": 1, "position": [1488, 528],
    "name": "Bot - Responder mídia", "credentials": EVO,
    "notes": "Áudio, imagem, vídeo e documento: pede para o cliente escrever (texto configurável no painel)."
})

C['If - fromMe'] = {"main": main(['Bot - Pausar (humano respondeu)'], ['Bot - Decidir ação'])}
C['Bot - Decidir ação'] = {"main": main(['Bot - Ação'])}
C['Bot - Ação'] = {"main": main(['Switch'], ['Bot - Aviso fora do horário'], ['No Operation, do nothing'])}

# Switch de tipo de mensagem: mídia ganha resposta, o resto (reações, figurinhas...) é ignorado em silêncio
sw = N['Switch']['parameters']['rules']['values']
media_rule = rule("Midia", ["audioMessage", "imageMessage", "videoMessage", "documentMessage",
                            "documentWithCaptionMessage"],
                  "={{ $('Webhook').item.json.body.data.messageType }}")
sw[0] = media_rule
C['Switch'] = {"main": main(['Bot - Responder mídia'], ['Set Text'], ['Set Text'])}

# ---------------------------------------------------------------- 2. Gestor configurável pelo painel
mc = N['Msg contratante?']['parameters']['conditions']
mc['conditions'] = [{
    "id": nid(),
    "leftValue": "={{ $('Bot - Decidir ação').first().json.decisao.acao }}",
    "rightValue": "gestor",
    "operator": {"type": "string", "operation": "equals", "name": "filter.operator.equals"}
}]
mc['combinator'] = 'and'

# ---------------------------------------------------------------- 3. Buffer: limpar o texto acumulado depois de usar
add({
    "parameters": {"operation": "delete",
                   "key": "=buffer:{{ $('Buffer - Finalizar mensagem').first().json.phoneNumber }}:text"},
    "type": "n8n-nodes-base.redis", "typeVersion": 1, "position": [3392, 848],
    "name": "Buffer - Limpar texto", "credentials": REDIS
})
C['Buffer - Finalizar mensagem'] = {"main": main(['Buffer - Limpar texto'])}
C['Buffer - Limpar texto'] = {"main": main(['Msg contratante?'])}

# ---------------------------------------------------------------- 4. Cliente e solicitações em aberto
N['verificarCliente']['parameters']['limit'] = 1

N['buscar_evento']['parameters']['query'] = """SELECT
  c.id AS customer_id,
  c.name AS customer_name,
  COUNT(e.id) AS total_abertos,
  string_agg(
    format('- Protocolo %s | %s | %s | aberto em %s | situação: %s',
           upper(left(e.id::text, 8)),
           coalesce(cond.name, 'condomínio não identificado'),
           e.request_resume,
           to_char(coalesce(e.created_at, e.register_date::timestamptz) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY'),
           CASE e.status::text WHEN 'OPEN' THEN 'aguardando a equipe' ELSE 'em andamento' END),
    E'\\n' ORDER BY e.created_at) AS resumo_abertos
FROM attendance_bot.customers c
LEFT JOIN attendance_bot.events e
       ON e.customer_id = c.id AND e.status::text IN ('OPEN', 'IN_PROGRESS')
LEFT JOIN attendance_bot.condominiums cond ON cond.id = e.condominium_id
WHERE c.phone_number = $1
GROUP BY c.id, c.name
ORDER BY c.id
LIMIT 1;"""
N['buscar_evento']['parameters']['options']['queryReplacement'] = "={{ $('Set format').first().json.phoneNumber }}"

ee = N['evento_existe']['parameters']['conditions']
ee['options']['typeValidation'] = 'loose'
ee['conditions'] = [{
    "id": nid(), "leftValue": "={{ Number($json.total_abertos || 0) }}", "rightValue": 0,
    "operator": {"type": "number", "operation": "gt"}
}]
N['evento_existe']['parameters']['looseTypeValidation'] = True

N['Evento existe']['parameters']['assignments']['assignments'] = [
    {"id": nid(), "name": "Evento existe", "type": "string",
     "value": "Este cliente já possui solicitação em aberto com a equipe."},
    {"id": nid(), "name": "dados do evento", "type": "string",
     "value": "={{ $('buscar_evento').first().json.resumo_abertos }}"},
    {"id": nid(), "name": "customer_id", "type": "string",
     "value": "={{ $('buscar_evento').first().json.customer_id }}"},
]

CUST = "={{ $('buscar_evento').first().json.customer_id }}"
N['create_event1']['parameters']['columns']['value']['customer_id'] = CUST
N['search_events6']['parameters']['where']['values'][0]['value'] = CUST

# Lista completa de condomínios ativos (antes só vinham 20, sem filtro)
sc = N['search_condominio']
sc['parameters'] = {
    "descriptionType": "manual",
    "toolDescription": "Lista todos os condomínios ativos atendidos pelo escritório (id, nome, cidade e endereço). "
                       "Use para validar o condomínio informado pelo cliente e obter o id (UUID) usado no create_event1.",
    "operation": "executeQuery",
    "query": "SELECT id, name, city, address FROM attendance_bot.condominiums "
             "WHERE coalesce(active, true) ORDER BY name",
    "options": {}
}

# ---------------------------------------------------------------- 5. Prompt da Marta
ag = N['Marta-AI Agent2']['parameters']['options']
p = ag['systemMessage']
a = p.index('## REGRA CRÍTICA — HORÁRIO DE ATENDIMENTO')
b = p.index('## SAUDAÇÕES - MENU DE SERVIÇOS')
p = p[:a] + p[b:]

TZ = "$now.setZone('America/Sao_Paulo')"
p = must_replace(p, "{{ $now.setLocale('pt-BR').format('cccc') }}", "{{ " + TZ + ".setLocale('pt-BR').format('cccc') }}")
p = must_replace(p, "{{ $now.format('dd/MM/yyyy  HH:mm') }}", "{{ " + TZ + ".format('dd/MM/yyyy HH:mm') }}")
SAUD_OLD = "{{ $now.format('H') < 12 ? 'Bom dia' : ($now.format('H') < 18 ? 'Boa tarde' : 'Boa noite') }}"
SAUD_NEW = "{{ " + TZ + ".hour < 12 ? 'Bom dia' : (" + TZ + ".hour < 18 ? 'Boa tarde' : 'Boa noite') }}"
assert p.count(SAUD_OLD) == 2
p = p.replace(SAUD_OLD, SAUD_NEW)
p = must_replace(p, "{{ $json.customer_phoneNumber }}", "{{ $('Set format').first().json.phoneNumber }}")
p = must_replace(
    p,
    "* **Ticket Aberto:** {{ $json['Evento existe'] ? 'SIM' : 'NÃO' }}",
    "* **Solicitação em aberto:** {{ $json['Evento existe'] ? 'SIM' : 'NÃO' }}\n\n"
    "## SOLICITAÇÕES EM ABERTO DESTE CLIENTE\n"
    "{{ $json['dados do evento'] || 'Nenhuma.' }}\n\n"
    "Se houver solicitação em aberto, depois da saudação mencione de forma breve que ela já está com a equipe "
    "(cite o protocolo) e pergunte se o contato é sobre ela ou sobre um assunto novo. "
    "Se for sobre a mesma solicitação, NÃO registre de novo: diga que ela já está registrada e que a equipe dará retorno. "
    "Se for assunto novo, siga o protocolo normalmente.")
p = must_replace(p, "Dentro do horário de atendimento 09h as 17h: ", "")
a = p.index('\n\nFora do horário de atendimento:')
b = p.index('\n\n\n---', a)
p = p[:a] + p[b:]
ag['systemMessage'] = p

# ---------------------------------------------------------------- validação de conexões
names = {n['name'] for n in wf['nodes']}
for s, conns in C.items():
    assert s in names, f'conexão de nó inexistente: {s}'
    for typ in conns.values():
        for out in typ:
            for x in out:
                assert x['node'] in names, f'{s} -> {x["node"]} (inexistente)'

json.dump(wf, open(dst, 'w'), ensure_ascii=False, indent=2)
print('ok', len(wf['nodes']), 'nós')
