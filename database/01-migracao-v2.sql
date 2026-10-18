-- =====================================================================
--  Contability Robot v2.0.0 — Migração do banco de dados
--  Pode ser executada mais de uma vez (é idempotente).
--  Rode no mesmo banco usado pelo n8n (credencial "Sandro_banco").
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS painel;

-- ---------------------------------------------------------------------
-- 1. Ajustes nas tabelas existentes
-- ---------------------------------------------------------------------

-- Condomínios: dados completos para o cadastro pelo painel
ALTER TABLE attendance_bot.condominiums
  ADD COLUMN IF NOT EXISTS address      text,
  ADD COLUMN IF NOT EXISTS city         text,
  ADD COLUMN IF NOT EXISTS cnpj         text,
  ADD COLUMN IF NOT EXISTS syndic_name  text,
  ADD COLUMN IF NOT EXISTS syndic_phone text,
  ADD COLUMN IF NOT EXISTS notes        text,
  ADD COLUMN IF NOT EXISTS active       boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_at   timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at   timestamptz NOT NULL DEFAULT now();

-- Solicitações: data/hora exata de abertura (para SLA) e de atualização
ALTER TABLE attendance_bot.events
  ADD COLUMN IF NOT EXISTS created_at   timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at   timestamptz,
  ADD COLUMN IF NOT EXISTS conclused_at timestamptz;

UPDATE attendance_bot.events
   SET created_at = (register_date::date::timestamp + time '12:00') AT TIME ZONE 'America/Sao_Paulo'
 WHERE created_at IS NULL AND register_date IS NOT NULL;
UPDATE attendance_bot.events SET created_at = now() WHERE created_at IS NULL;
UPDATE attendance_bot.events SET updated_at = coalesce(conclused_at, created_at) WHERE updated_at IS NULL;
ALTER TABLE attendance_bot.events ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE attendance_bot.events ALTER COLUMN updated_at SET DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_events_status_created ON attendance_bot.events (status, created_at);
CREATE INDEX IF NOT EXISTS idx_events_phone          ON attendance_bot.events (phone_number);
CREATE INDEX IF NOT EXISTS idx_customers_phone       ON attendance_bot.customers (phone_number);

-- Pausa do bot por contato (substitui a chave no Redis: agora o painel enxerga e controla)
CREATE TABLE IF NOT EXISTS attendance_bot.bot_pausas (
  telefone     text PRIMARY KEY,
  pausado_ate  timestamptz NOT NULL,
  motivo       text NOT NULL DEFAULT 'atendimento_humano',
  criado_por   uuid,
  criado_em    timestamptz NOT NULL DEFAULT now()
);

-- Controle para não repetir o aviso de "fora do horário" a cada mensagem
CREATE TABLE IF NOT EXISTS attendance_bot.avisos_fora_horario (
  telefone   text PRIMARY KEY,
  enviado_em timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. Tabelas do painel
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS painel.usuarios (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome          text NOT NULL,
  email         text NOT NULL UNIQUE,
  senha_hash    text NOT NULL,
  papel         text NOT NULL DEFAULT 'atendente' CHECK (papel IN ('admin','atendente')),
  ativo         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  ultimo_acesso timestamptz
);

CREATE TABLE IF NOT EXISTS painel.sessoes (
  token      text PRIMARY KEY,
  usuario_id uuid NOT NULL REFERENCES painel.usuarios(id) ON DELETE CASCADE,
  criado_em  timestamptz NOT NULL DEFAULT now(),
  expira_em  timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS painel.tentativas_login (
  email     text NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tentativas_login ON painel.tentativas_login (email, criado_em);

CREATE TABLE IF NOT EXISTS painel.configuracoes (
  chave          text PRIMARY KEY,
  valor          jsonb NOT NULL,
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  atualizado_por uuid
);

CREATE TABLE IF NOT EXISTS painel.solicitacao_info (
  event_id       uuid PRIMARY KEY,
  responsavel_id uuid REFERENCES painel.usuarios(id) ON DELETE SET NULL,
  prioridade     text NOT NULL DEFAULT 'normal' CHECK (prioridade IN ('baixa','normal','alta','urgente')),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS painel.notas (
  id         bigserial PRIMARY KEY,
  event_id   uuid NOT NULL,
  usuario_id uuid REFERENCES painel.usuarios(id) ON DELETE SET NULL,
  texto      text NOT NULL,
  criado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notas_event ON painel.notas (event_id);

CREATE TABLE IF NOT EXISTS painel.historico (
  id         bigserial PRIMARY KEY,
  event_id   uuid NOT NULL,
  usuario_id uuid REFERENCES painel.usuarios(id) ON DELETE SET NULL,
  acao       text NOT NULL,
  detalhe    text,
  criado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_historico_event ON painel.historico (event_id);

-- Configurações padrão (não sobrescreve o que já existir)
INSERT INTO painel.configuracoes (chave, valor) VALUES
  ('bot_ativo',                 'true'),
  ('expediente',                '{"dias":[1,2,3,4,5],"inicio":"09:00","fim":"17:00","fuso":"America/Sao_Paulo"}'),
  ('feriados',                  '[]'),
  ('mensagem_fora_horario',     to_jsonb('Olá! Nosso horário de atendimento é de segunda à sexta-feira das 09h às 17h. Recebemos sua solicitação, um atendente do nosso time responderá assim que o expediente recomeçar.'::text)),
  ('aviso_intervalo_horas',     '4'),
  ('mensagem_midia',            to_jsonb('Por enquanto eu consigo entender apenas mensagens de texto. Pode me escrever, por favor?'::text)),
  ('pausa_humano_horas',        '24'),
  ('sla_horas',                 '8'),
  ('numeros_gestor',            '[]')
ON CONFLICT (chave) DO NOTHING;

-- ---------------------------------------------------------------------
-- 3. Funções auxiliares
-- ---------------------------------------------------------------------

-- Normaliza telefone: só dígitos e sem o 9º dígito brasileiro (o WhatsApp às vezes envia sem ele)
CREATE OR REPLACE FUNCTION painel.fn_tel(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN d ~ '^55\d{2}9\d{8}$' THEN substr(d,1,4) || substr(d,6)
    ELSE d END
  FROM (SELECT regexp_replace(coalesce(p,''), '\D', '', 'g') AS d) x
$$;

CREATE OR REPLACE FUNCTION painel.fn_config(p_chave text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT valor FROM painel.configuracoes WHERE chave = p_chave
$$;

-- O escritório está em expediente neste momento?
CREATE OR REPLACE FUNCTION painel.fn_expediente_aberto(p_momento timestamptz DEFAULT now()) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e        jsonb := coalesce(painel.fn_config('expediente'), '{}');
  v_local  timestamp := p_momento AT TIME ZONE coalesce(e->>'fuso','America/Sao_Paulo');
  v_dia    int := extract(isodow FROM v_local);   -- 1 = segunda ... 7 = domingo
  v_hora   time := v_local::time;
BEGIN
  IF coalesce(painel.fn_config('feriados'), '[]') ? to_char(v_local, 'YYYY-MM-DD') THEN
    RETURN false;
  END IF;
  IF NOT (coalesce(e->'dias', '[1,2,3,4,5]') @> to_jsonb(v_dia)) THEN
    RETURN false;
  END IF;
  RETURN v_hora >= coalesce((e->>'inicio')::time, '09:00') AND v_hora < coalesce((e->>'fim')::time, '17:00');
END $$;

-- Pausa o bot para um contato (chamada pelo n8n quando um humano responde pelo WhatsApp, ou pelo painel)
CREATE OR REPLACE FUNCTION attendance_bot.fn_pausar(
  p_telefone text, p_horas numeric DEFAULT NULL, p_motivo text DEFAULT 'atendimento_humano', p_usuario uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_tel   text := regexp_replace(coalesce(p_telefone,''), '\D', '', 'g');
  v_horas numeric := coalesce(p_horas, (painel.fn_config('pausa_humano_horas'))::text::numeric, 24);
  v_ate   timestamptz;
BEGIN
  IF v_tel = '' THEN RETURN jsonb_build_object('ok', false); END IF;
  v_ate := now() + make_interval(mins => (v_horas * 60)::int);
  INSERT INTO attendance_bot.bot_pausas (telefone, pausado_ate, motivo, criado_por)
  VALUES (v_tel, v_ate, coalesce(p_motivo,'atendimento_humano'), p_usuario)
  ON CONFLICT (telefone) DO UPDATE
    SET pausado_ate = EXCLUDED.pausado_ate, motivo = EXCLUDED.motivo,
        criado_por = EXCLUDED.criado_por, criado_em = now();
  RETURN jsonb_build_object('ok', true, 'telefone', v_tel, 'pausado_ate', v_ate);
END $$;

-- Decide o que o bot deve fazer com uma mensagem recebida.
-- acao: 'cliente' | 'gestor' | 'fora_horario' | 'silenciar'
CREATE OR REPLACE FUNCTION attendance_bot.fn_decidir(p_telefone text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_tel       text := regexp_replace(coalesce(p_telefone,''), '\D', '', 'g');
  v_midia     text := coalesce(painel.fn_config('mensagem_midia') #>> '{}', '');
  v_intervalo numeric := coalesce((painel.fn_config('aviso_intervalo_horas'))::text::numeric, 4);
  v_ultimo    timestamptz;
  v_base      jsonb;
BEGIN
  v_base := jsonb_build_object('telefone', v_tel, 'mensagem_midia', v_midia);

  IF v_tel = '' THEN
    RETURN v_base || jsonb_build_object('acao','silenciar','motivo','telefone_invalido');
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(painel.fn_config('numeros_gestor'),'[]')) g
             WHERE painel.fn_tel(g) = painel.fn_tel(v_tel)) THEN
    RETURN v_base || jsonb_build_object('acao','gestor');
  END IF;

  IF coalesce((painel.fn_config('bot_ativo'))::text::boolean, true) = false THEN
    RETURN v_base || jsonb_build_object('acao','silenciar','motivo','bot_desligado');
  END IF;

  IF EXISTS (SELECT 1 FROM attendance_bot.bot_pausas WHERE telefone = v_tel AND pausado_ate > now()) THEN
    RETURN v_base || jsonb_build_object('acao','silenciar','motivo','atendimento_humano');
  END IF;

  IF NOT painel.fn_expediente_aberto() THEN
    SELECT enviado_em INTO v_ultimo FROM attendance_bot.avisos_fora_horario WHERE telefone = v_tel;
    IF v_ultimo IS NOT NULL AND v_ultimo > now() - make_interval(mins => (v_intervalo * 60)::int) THEN
      RETURN v_base || jsonb_build_object('acao','silenciar','motivo','aviso_ja_enviado');
    END IF;
    INSERT INTO attendance_bot.avisos_fora_horario (telefone, enviado_em) VALUES (v_tel, now())
    ON CONFLICT (telefone) DO UPDATE SET enviado_em = now();
    RETURN v_base || jsonb_build_object('acao','fora_horario',
      'mensagem', painel.fn_config('mensagem_fora_horario') #>> '{}');
  END IF;

  RETURN v_base || jsonb_build_object('acao','cliente');
END $$;

-- ---------------------------------------------------------------------
-- 4. API do painel — uma única função chamada pelo webhook do n8n
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION painel._ok(p jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT jsonb_build_object('ok', true, 'dados', p) $$;

CREATE OR REPLACE FUNCTION painel._erro(p_msg text, p_codigo text DEFAULT 'erro') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT jsonb_build_object('ok', false, 'erro', p_msg, 'codigo', p_codigo) $$;

CREATE OR REPLACE FUNCTION painel._usuario_json(u painel.usuarios) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('id', u.id, 'nome', u.nome, 'email', u.email, 'papel', u.papel,
                            'ativo', u.ativo, 'ultimo_acesso', u.ultimo_acesso)
$$;

CREATE OR REPLACE FUNCTION painel.criar_usuario(p_nome text, p_email text, p_senha text, p_papel text DEFAULT 'atendente')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO painel.usuarios (nome, email, senha_hash, papel)
  VALUES (p_nome, lower(trim(p_email)), crypt(p_senha, gen_salt('bf', 10)), p_papel)
  ON CONFLICT (email) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Linha completa de uma solicitação (usada na lista e no detalhe)
CREATE OR REPLACE FUNCTION painel._solicitacoes(p_ids uuid[] DEFAULT NULL) RETURNS SETOF jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',            e.id,
    'status',        e.status::text,
    'resumo',        e.request_resume,
    'telefone',      coalesce(e.phone_number, c.phone_number),
    'cliente',       c.name,
    'cliente_id',    c.id,
    'condominio',    cond.name,
    'condominio_id', cond.id,
    'tipo',          coalesce(m.service_type, 'outros'),
    'criado_em',     e.created_at,
    'atualizado_em', e.updated_at,
    'concluido_em',  e.conclused_at,
    'prioridade',    coalesce(i.prioridade, 'normal'),
    'responsavel',   CASE WHEN u.id IS NULL THEN NULL ELSE jsonb_build_object('id', u.id, 'nome', u.nome) END,
    'horas_aberta',  round(extract(epoch FROM (coalesce(e.conclused_at, now()) - e.created_at)) / 3600.0, 1),
    'atrasada',      e.status::text IN ('OPEN','IN_PROGRESS')
                     AND e.created_at < now() - make_interval(hours => coalesce((painel.fn_config('sla_horas'))::text::int, 8)),
    'total_notas',   (SELECT count(*) FROM painel.notas n WHERE n.event_id = e.id),
    'bot_pausado',   EXISTS (SELECT 1 FROM attendance_bot.bot_pausas p
                             WHERE p.telefone = regexp_replace(coalesce(e.phone_number, c.phone_number,''), '\D','','g')
                               AND p.pausado_ate > now())
  )
  FROM attendance_bot.events e
  LEFT JOIN attendance_bot.customers    c    ON c.id = e.customer_id
  LEFT JOIN attendance_bot.condominiums cond ON cond.id = e.condominium_id
  LEFT JOIN dashboard.event_meta        m    ON m.event_id = e.id
  LEFT JOIN painel.solicitacao_info     i    ON i.event_id = e.id
  LEFT JOIN painel.usuarios             u    ON u.id = i.responsavel_id
  WHERE p_ids IS NULL OR e.id = ANY (p_ids)
$$;

CREATE OR REPLACE FUNCTION painel._detalhe(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT s INTO v FROM painel._solicitacoes(ARRAY[p_id]) s;
  IF v IS NULL THEN RETURN NULL; END IF;
  RETURN v || jsonb_build_object(
    'notas', coalesce((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'texto', n.texto, 'criado_em', n.criado_em,
                                                           'autor', coalesce(u.nome, 'Usuário removido')) ORDER BY n.criado_em, n.id)
                       FROM painel.notas n LEFT JOIN painel.usuarios u ON u.id = n.usuario_id
                       WHERE n.event_id = p_id), '[]'),
    'historico', coalesce((SELECT jsonb_agg(jsonb_build_object('acao', h.acao, 'detalhe', h.detalhe, 'criado_em', h.criado_em,
                                                               'autor', coalesce(u.nome, 'Sistema')) ORDER BY h.criado_em, h.id)
                           FROM painel.historico h LEFT JOIN painel.usuarios u ON u.id = h.usuario_id
                           WHERE h.event_id = p_id), '[]'),
    'outras', coalesce((SELECT jsonb_agg(jsonb_build_object('id', e2.id, 'status', e2.status::text,
                                                            'resumo', e2.request_resume, 'criado_em', e2.created_at)
                                         ORDER BY e2.created_at DESC)
                        FROM (SELECT * FROM attendance_bot.events e2
                              WHERE e2.customer_id = (v->>'cliente_id')::uuid AND e2.id <> p_id
                              ORDER BY e2.created_at DESC LIMIT 5) e2), '[]')
  );
END $$;

CREATE OR REPLACE FUNCTION painel.api(p_acao text, p_token text, p_dados jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  d        jsonb := coalesce(p_dados, '{}');
  me       painel.usuarios;
  v_id     uuid;
  v_txt    text;
  v_old    text;
  v_res    jsonb;
  v_dias   int;
  v_chave  text;
BEGIN
  -- ------------------------------------------------ login (sem token)
  IF p_acao = 'login' THEN
    v_txt := lower(trim(coalesce(d->>'email','')));
    IF (SELECT count(*) FROM painel.tentativas_login
        WHERE email = v_txt AND criado_em > now() - interval '15 minutes') >= 5 THEN
      RETURN painel._erro('Muitas tentativas. Aguarde 15 minutos e tente de novo.', 'bloqueado');
    END IF;
    SELECT * INTO me FROM painel.usuarios
     WHERE email = v_txt AND ativo AND senha_hash = crypt(coalesce(d->>'senha',''), senha_hash);
    IF NOT FOUND THEN
      INSERT INTO painel.tentativas_login (email) VALUES (v_txt);
      RETURN painel._erro('E-mail ou senha inválidos.', 'login');
    END IF;
    DELETE FROM painel.tentativas_login WHERE email = v_txt OR criado_em < now() - interval '1 day';
    DELETE FROM painel.sessoes WHERE expira_em < now();
    v_txt := encode(gen_random_bytes(32), 'hex');
    INSERT INTO painel.sessoes (token, usuario_id, expira_em) VALUES (v_txt, me.id, now() + interval '12 hours');
    UPDATE painel.usuarios SET ultimo_acesso = now() WHERE id = me.id;
    RETURN painel._ok(jsonb_build_object('token', v_txt, 'usuario', painel._usuario_json(me)));
  END IF;

  -- ------------------------------------------------ autenticação
  SELECT u.* INTO me FROM painel.sessoes s JOIN painel.usuarios u ON u.id = s.usuario_id
   WHERE s.token = coalesce(p_token,'') AND s.expira_em > now() AND u.ativo;
  IF NOT FOUND THEN
    RETURN painel._erro('Sua sessão expirou. Entre novamente.', 'auth');
  END IF;

  IF p_acao IN ('config_salvar','usuarios_listar','usuario_salvar') AND me.papel <> 'admin' THEN
    RETURN painel._erro('Apenas administradores podem fazer isso.', 'permissao');
  END IF;

  CASE p_acao

  -- ------------------------------------------------ sessão
  WHEN 'eu' THEN
    RETURN painel._ok(jsonb_build_object('usuario', painel._usuario_json(me)));

  WHEN 'logout' THEN
    DELETE FROM painel.sessoes WHERE token = p_token;
    RETURN painel._ok();

  WHEN 'senha_alterar' THEN
    IF me.senha_hash <> crypt(coalesce(d->>'atual',''), me.senha_hash) THEN
      RETURN painel._erro('A senha atual não confere.');
    END IF;
    IF length(coalesce(d->>'nova','')) < 8 THEN
      RETURN painel._erro('A nova senha precisa ter pelo menos 8 caracteres.');
    END IF;
    UPDATE painel.usuarios SET senha_hash = crypt(d->>'nova', gen_salt('bf', 10)) WHERE id = me.id;
    DELETE FROM painel.sessoes WHERE usuario_id = me.id AND token <> p_token;
    RETURN painel._ok();

  -- ------------------------------------------------ indicadores
  WHEN 'resumo' THEN
    v_dias := least(greatest(coalesce((d->>'dias')::int, 30), 1), 365);
    WITH ev AS (
      SELECT e.*, coalesce(m.service_type,'outros') AS tipo
      FROM attendance_bot.events e LEFT JOIN dashboard.event_meta m ON m.event_id = e.id
    ), periodo AS (
      SELECT * FROM ev WHERE created_at >= date_trunc('day', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo' - make_interval(days => v_dias - 1)
    )
    SELECT jsonb_build_object(
      'dias', v_dias,
      'abertas',        (SELECT count(*) FROM ev WHERE status::text = 'OPEN'),
      'em_andamento',   (SELECT count(*) FROM ev WHERE status::text = 'IN_PROGRESS'),
      'atrasadas',      (SELECT count(*) FROM ev WHERE status::text IN ('OPEN','IN_PROGRESS')
                          AND created_at < now() - make_interval(hours => coalesce((painel.fn_config('sla_horas'))::text::int, 8))),
      'sem_responsavel',(SELECT count(*) FROM ev LEFT JOIN painel.solicitacao_info i ON i.event_id = ev.id
                          WHERE ev.status::text IN ('OPEN','IN_PROGRESS') AND i.responsavel_id IS NULL),
      'novas_hoje',     (SELECT count(*) FROM ev WHERE (created_at AT TIME ZONE 'America/Sao_Paulo')::date = (now() AT TIME ZONE 'America/Sao_Paulo')::date),
      'recebidas_periodo',  (SELECT count(*) FROM periodo),
      'concluidas_periodo', (SELECT count(*) FROM ev WHERE status::text = 'COMPLETED'
                              AND conclused_at >= now() - make_interval(days => v_dias)),
      'tempo_medio_horas',  (SELECT round(avg(extract(epoch FROM conclused_at - created_at)) / 3600.0, 1) FROM ev
                              WHERE status::text = 'COMPLETED' AND conclused_at >= now() - make_interval(days => v_dias)),
      'sla_horas',      coalesce((painel.fn_config('sla_horas'))::text::int, 8),
      'por_dia', (SELECT coalesce(jsonb_agg(jsonb_build_object('dia', to_char(g.dia, 'YYYY-MM-DD'), 'total', coalesce(x.total,0)) ORDER BY g.dia), '[]')
                  FROM generate_series((now() AT TIME ZONE 'America/Sao_Paulo')::date - (v_dias - 1),
                                       (now() AT TIME ZONE 'America/Sao_Paulo')::date, interval '1 day') g(dia)
                  LEFT JOIN (SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia, count(*) AS total
                             FROM periodo GROUP BY 1) x ON x.dia = g.dia::date),
      'por_tipo', (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'total', total) ORDER BY total DESC), '[]')
                   FROM (SELECT tipo, count(*) AS total FROM periodo GROUP BY tipo) t),
      'por_condominio', (SELECT coalesce(jsonb_agg(jsonb_build_object('condominio', nome, 'total', total) ORDER BY total DESC), '[]')
                         FROM (SELECT coalesce(c.name, 'Não identificado') AS nome, count(*) AS total
                               FROM periodo p LEFT JOIN attendance_bot.condominiums c ON c.id = p.condominium_id
                               GROUP BY 1 ORDER BY 2 DESC LIMIT 8) t),
      'mensagens_recebidas', (SELECT count(*) FROM dashboard.bot_metrics WHERE evento = 'msg_recebida'
                               AND criado_em >= now() - make_interval(days => v_dias)),
      'atendimentos_bot',    (SELECT count(*) FROM dashboard.bot_metrics WHERE evento = 'atendimento_iniciado'
                               AND criado_em >= now() - make_interval(days => v_dias)),
      'expediente_aberto', painel.fn_expediente_aberto(),
      'bot_ativo',        coalesce((painel.fn_config('bot_ativo'))::text::boolean, true),
      'pausas_ativas',    (SELECT count(*) FROM attendance_bot.bot_pausas WHERE pausado_ate > now())
    ) INTO v_res;
    RETURN painel._ok(v_res);

  -- ------------------------------------------------ solicitações
  WHEN 'solicitacoes_listar' THEN
    v_dias := coalesce((d->>'dias_concluidas')::int, 30);
    SELECT coalesce(jsonb_agg(s ORDER BY (s->>'criado_em') DESC), '[]') INTO v_res
    FROM painel._solicitacoes() s
    WHERE (s->>'status' IN ('OPEN','IN_PROGRESS')
           OR coalesce((s->>'concluido_em')::timestamptz, (s->>'atualizado_em')::timestamptz) >= now() - make_interval(days => v_dias));
    RETURN painel._ok(jsonb_build_object('itens', v_res));

  WHEN 'solicitacao_detalhe' THEN
    v_res := painel._detalhe((d->>'id')::uuid);
    IF v_res IS NULL THEN RETURN painel._erro('Solicitação não encontrada.'); END IF;
    RETURN painel._ok(v_res);

  WHEN 'solicitacao_atualizar' THEN
    v_id := (d->>'id')::uuid;
    SELECT status::text INTO v_old FROM attendance_bot.events WHERE id = v_id;
    IF NOT FOUND THEN RETURN painel._erro('Solicitação não encontrada.'); END IF;

    IF d ? 'status' AND d->>'status' IS DISTINCT FROM v_old THEN
      IF d->>'status' NOT IN ('OPEN','IN_PROGRESS','COMPLETED','CANCELED') THEN
        RETURN painel._erro('Status inválido.');
      END IF;
      EXECUTE format(
        'UPDATE attendance_bot.events SET status = %L, updated_at = now(),
                conclused_at = CASE WHEN %L IN (''COMPLETED'',''CANCELED'') THEN now() ELSE NULL END
          WHERE id = %L', d->>'status', d->>'status', v_id);
      INSERT INTO painel.historico (event_id, usuario_id, acao, detalhe)
      VALUES (v_id, me.id, 'status', v_old || ' → ' || (d->>'status'));
      -- quem puxa para "em andamento" vira responsável, se ainda não houver um
      IF d->>'status' = 'IN_PROGRESS' AND NOT (d ? 'responsavel_id') THEN
        INSERT INTO painel.solicitacao_info (event_id, responsavel_id) VALUES (v_id, me.id)
        ON CONFLICT (event_id) DO UPDATE SET responsavel_id = coalesce(painel.solicitacao_info.responsavel_id, EXCLUDED.responsavel_id),
                                             atualizado_em = now();
      END IF;
    END IF;

    IF d ? 'responsavel_id' THEN
      INSERT INTO painel.solicitacao_info (event_id, responsavel_id)
      VALUES (v_id, nullif(d->>'responsavel_id','')::uuid)
      ON CONFLICT (event_id) DO UPDATE SET responsavel_id = EXCLUDED.responsavel_id, atualizado_em = now();
      INSERT INTO painel.historico (event_id, usuario_id, acao, detalhe)
      VALUES (v_id, me.id, 'responsavel',
              coalesce((SELECT nome FROM painel.usuarios WHERE id = nullif(d->>'responsavel_id','')::uuid), 'Sem responsável'));
      UPDATE attendance_bot.events SET updated_at = now() WHERE id = v_id;
    END IF;

    IF d ? 'prioridade' THEN
      IF d->>'prioridade' NOT IN ('baixa','normal','alta','urgente') THEN
        RETURN painel._erro('Prioridade inválida.');
      END IF;
      INSERT INTO painel.solicitacao_info (event_id, prioridade) VALUES (v_id, d->>'prioridade')
      ON CONFLICT (event_id) DO UPDATE SET prioridade = EXCLUDED.prioridade, atualizado_em = now();
      INSERT INTO painel.historico (event_id, usuario_id, acao, detalhe) VALUES (v_id, me.id, 'prioridade', d->>'prioridade');
    END IF;

    RETURN painel._ok(painel._detalhe(v_id));

  WHEN 'nota_adicionar' THEN
    v_id := (d->>'id')::uuid;
    IF length(trim(coalesce(d->>'texto',''))) = 0 THEN RETURN painel._erro('Escreva a anotação.'); END IF;
    INSERT INTO painel.notas (event_id, usuario_id, texto) VALUES (v_id, me.id, trim(d->>'texto'));
    UPDATE attendance_bot.events SET updated_at = now() WHERE id = v_id;
    RETURN painel._ok(painel._detalhe(v_id));

  -- ------------------------------------------------ condomínios
  WHEN 'condominios_listar' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'nome', c.name, 'endereco', c.address, 'cidade', c.city, 'cnpj', c.cnpj,
             'sindico_nome', c.syndic_name, 'sindico_telefone', c.syndic_phone, 'observacoes', c.notes,
             'ativo', c.active, 'criado_em', c.created_at,
             'abertas', (SELECT count(*) FROM attendance_bot.events e
                         WHERE e.condominium_id = c.id AND e.status::text IN ('OPEN','IN_PROGRESS')),
             'total', (SELECT count(*) FROM attendance_bot.events e WHERE e.condominium_id = c.id)
           ) ORDER BY c.active DESC, c.name), '[]') INTO v_res
    FROM attendance_bot.condominiums c;
    RETURN painel._ok(jsonb_build_object('itens', v_res));

  WHEN 'condominio_salvar' THEN
    v_txt := trim(coalesce(d->>'nome',''));
    IF v_txt = '' THEN RETURN painel._erro('Informe o nome do condomínio.'); END IF;
    v_id := nullif(d->>'id','')::uuid;
    IF EXISTS (SELECT 1 FROM attendance_bot.condominiums
               WHERE lower(name) = lower(v_txt) AND (v_id IS NULL OR id <> v_id)) THEN
      RETURN painel._erro('Já existe um condomínio com esse nome.');
    END IF;
    IF v_id IS NULL THEN
      INSERT INTO attendance_bot.condominiums (id, name, address, city, cnpj, syndic_name, syndic_phone, notes, active)
      VALUES (gen_random_uuid(), v_txt, nullif(trim(d->>'endereco'),''), nullif(trim(d->>'cidade'),''),
              nullif(trim(d->>'cnpj'),''), nullif(trim(d->>'sindico_nome'),''),
              nullif(regexp_replace(coalesce(d->>'sindico_telefone',''), '\D','','g'),''),
              nullif(trim(d->>'observacoes'),''), coalesce((d->>'ativo')::boolean, true))
      RETURNING id INTO v_id;
    ELSE
      UPDATE attendance_bot.condominiums SET
        name = v_txt, address = nullif(trim(d->>'endereco'),''), city = nullif(trim(d->>'cidade'),''),
        cnpj = nullif(trim(d->>'cnpj'),''), syndic_name = nullif(trim(d->>'sindico_nome'),''),
        syndic_phone = nullif(regexp_replace(coalesce(d->>'sindico_telefone',''), '\D','','g'),''),
        notes = nullif(trim(d->>'observacoes'),''), active = coalesce((d->>'ativo')::boolean, active),
        updated_at = now()
      WHERE id = v_id;
      IF NOT FOUND THEN RETURN painel._erro('Condomínio não encontrado.'); END IF;
    END IF;
    RETURN painel._ok(jsonb_build_object('id', v_id));

  -- ------------------------------------------------ atendimento humano (pausas do bot)
  WHEN 'pausas_listar' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'telefone', p.telefone, 'pausado_ate', p.pausado_ate, 'desde', p.criado_em, 'motivo', p.motivo,
             'cliente', (SELECT name FROM attendance_bot.customers c
                         WHERE regexp_replace(c.phone_number,'\D','','g') = p.telefone LIMIT 1),
             'por', (SELECT nome FROM painel.usuarios u WHERE u.id = p.criado_por),
             'ultima_solicitacao', (SELECT request_resume FROM attendance_bot.events e
                                    WHERE regexp_replace(coalesce(e.phone_number,''),'\D','','g') = p.telefone
                                    ORDER BY e.created_at DESC LIMIT 1)
           ) ORDER BY p.criado_em DESC), '[]') INTO v_res
    FROM attendance_bot.bot_pausas p WHERE p.pausado_ate > now();
    RETURN painel._ok(jsonb_build_object('itens', v_res));

  WHEN 'pausa_retomar' THEN
    DELETE FROM attendance_bot.bot_pausas WHERE telefone = regexp_replace(coalesce(d->>'telefone',''), '\D','','g');
    RETURN painel._ok();

  WHEN 'pausa_criar' THEN
    v_res := attendance_bot.fn_pausar(d->>'telefone', (d->>'horas')::numeric, 'pausado_pelo_painel', me.id);
    IF NOT (v_res->>'ok')::boolean THEN RETURN painel._erro('Telefone inválido.'); END IF;
    RETURN painel._ok(v_res);

  -- ------------------------------------------------ configurações
  WHEN 'config_obter' THEN
    SELECT jsonb_object_agg(chave, valor) INTO v_res FROM painel.configuracoes;
    RETURN painel._ok(v_res || jsonb_build_object('expediente_aberto_agora', painel.fn_expediente_aberto()));

  WHEN 'config_salvar' THEN
    IF d ? 'expediente' THEN
      IF (d#>>'{expediente,inicio}')::time >= (d#>>'{expediente,fim}')::time THEN
        RETURN painel._erro('O horário de início precisa ser antes do horário de término.');
      END IF;
      IF jsonb_typeof(d#>'{expediente,dias}') <> 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(d#>'{expediente,dias}') x WHERE x !~ '^[1-7]$') THEN
        RETURN painel._erro('Dias da semana inválidos.');
      END IF;
      d := jsonb_set(d, '{expediente,fuso}', to_jsonb(coalesce(d#>>'{expediente,fuso}', 'America/Sao_Paulo')));
    END IF;
    IF d ? 'feriados' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(d->'feriados') x
                                  WHERE x !~ '^\d{4}-\d{2}-\d{2}$') THEN
      RETURN painel._erro('Feriados devem estar no formato AAAA-MM-DD.');
    END IF;
    FOR v_chave IN SELECT jsonb_object_keys(d) LOOP
      IF v_chave IN ('bot_ativo','expediente','feriados','mensagem_fora_horario','aviso_intervalo_horas',
                     'mensagem_midia','pausa_humano_horas','sla_horas','numeros_gestor') THEN
        INSERT INTO painel.configuracoes (chave, valor, atualizado_em, atualizado_por)
        VALUES (v_chave, d->v_chave, now(), me.id)
        ON CONFLICT (chave) DO UPDATE SET valor = EXCLUDED.valor, atualizado_em = now(), atualizado_por = me.id;
      END IF;
    END LOOP;
    SELECT jsonb_object_agg(chave, valor) INTO v_res FROM painel.configuracoes;
    RETURN painel._ok(v_res || jsonb_build_object('expediente_aberto_agora', painel.fn_expediente_aberto()));

  -- ------------------------------------------------ usuários
  WHEN 'usuarios_resumo' THEN   -- lista simples para escolher responsável (qualquer usuário)
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) ORDER BY nome), '[]') INTO v_res
    FROM painel.usuarios WHERE ativo;
    RETURN painel._ok(jsonb_build_object('itens', v_res));

  WHEN 'usuarios_listar' THEN
    SELECT coalesce(jsonb_agg(painel._usuario_json(u) ORDER BY u.nome), '[]') INTO v_res FROM painel.usuarios u;
    RETURN painel._ok(jsonb_build_object('itens', v_res));

  WHEN 'usuario_salvar' THEN
    v_id := nullif(d->>'id','')::uuid;
    IF trim(coalesce(d->>'nome','')) = '' OR trim(coalesce(d->>'email','')) !~ '^[^@\s]+@[^@\s]+$' THEN
      RETURN painel._erro('Informe nome e um e-mail válido.');
    END IF;
    IF coalesce(d->>'papel','atendente') NOT IN ('admin','atendente') THEN RETURN painel._erro('Papel inválido.'); END IF;
    IF EXISTS (SELECT 1 FROM painel.usuarios WHERE email = lower(trim(d->>'email')) AND (v_id IS NULL OR id <> v_id)) THEN
      RETURN painel._erro('Já existe um usuário com esse e-mail.');
    END IF;
    IF d ? 'senha' AND length(coalesce(d->>'senha','')) > 0 AND length(d->>'senha') < 8 THEN
      RETURN painel._erro('A senha precisa ter pelo menos 8 caracteres.');
    END IF;
    IF v_id IS NULL THEN
      IF length(coalesce(d->>'senha','')) = 0 THEN RETURN painel._erro('Defina uma senha inicial.'); END IF;
      v_id := painel.criar_usuario(trim(d->>'nome'), d->>'email', d->>'senha', coalesce(d->>'papel','atendente'));
    ELSE
      IF v_id = me.id AND (coalesce(d->>'papel','admin') <> 'admin' OR coalesce((d->>'ativo')::boolean, true) = false) THEN
        RETURN painel._erro('Você não pode remover seu próprio acesso de administrador.');
      END IF;
      UPDATE painel.usuarios SET nome = trim(d->>'nome'), email = lower(trim(d->>'email')),
             papel = coalesce(d->>'papel', papel), ativo = coalesce((d->>'ativo')::boolean, ativo),
             senha_hash = CASE WHEN length(coalesce(d->>'senha','')) > 0
                               THEN crypt(d->>'senha', gen_salt('bf', 10)) ELSE senha_hash END
       WHERE id = v_id;
      IF coalesce((d->>'ativo')::boolean, true) = false THEN
        DELETE FROM painel.sessoes WHERE usuario_id = v_id;
      END IF;
    END IF;
    RETURN painel._ok(jsonb_build_object('id', v_id));

  ELSE
    RETURN painel._erro('Ação desconhecida: ' || coalesce(p_acao,'(vazia)'));
  END CASE;

EXCEPTION WHEN OTHERS THEN
  RETURN painel._erro('Erro no servidor: ' || SQLERRM, 'servidor');
END $$;

-- ---------------------------------------------------------------------
-- 5. Primeiro acesso: administrador inicial
--    TROQUE a senha logo depois do primeiro login (menu "Minha senha").
-- ---------------------------------------------------------------------
SELECT painel.criar_usuario('Administrador', 'admin@escritorio.com', 'TroqueEstaSenha123', 'admin');

COMMIT;
