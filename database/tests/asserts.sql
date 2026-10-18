-- Verificações automáticas da migração v2 (rodadas pelo CI depois de
-- teste-banco-simulado.sql + 01-migracao-v2.sql). Qualquer falha interrompe o CI.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  tok  text;
  tok2 text;
  ev   uuid;
  r    jsonb;
BEGIN
  -- login
  ASSERT painel.api('login', NULL, '{"email":"admin@escritorio.com","senha":"errada"}')->>'codigo' = 'login', 'login com senha errada deveria falhar';
  tok := painel.api('login', NULL, '{"email":"admin@escritorio.com","senha":"TroqueEstaSenha123"}')#>>'{dados,token}';
  ASSERT tok IS NOT NULL, 'login do admin inicial falhou';
  ASSERT painel.api('resumo', 'token-invalido', '{}')->>'codigo' = 'auth', 'token inválido deveria ser recusado';

  -- solicitações
  ASSERT jsonb_array_length(painel.api('solicitacoes_listar', tok, '{}')#>'{dados,itens}') = 2, 'lista de solicitações';
  SELECT id INTO ev FROM attendance_bot.events WHERE status::text = 'OPEN' LIMIT 1;
  r := painel.api('solicitacao_atualizar', tok, jsonb_build_object('id', ev, 'status', 'IN_PROGRESS', 'prioridade', 'alta'));
  ASSERT r#>>'{dados,responsavel,nome}' = 'Administrador', 'assumir deveria definir o responsável';
  ASSERT r#>>'{dados,prioridade}' = 'alta', 'prioridade';
  r := painel.api('nota_adicionar', tok, jsonb_build_object('id', ev, 'texto', 'nota de teste'));
  ASSERT jsonb_array_length(r#>'{dados,notas}') = 1, 'anotação';
  r := painel.api('solicitacao_atualizar', tok, jsonb_build_object('id', ev, 'status', 'COMPLETED'));
  ASSERT r#>>'{dados,concluido_em}' IS NOT NULL, 'concluir deveria preencher concluido_em';
  ASSERT jsonb_array_length(r#>'{dados,historico}') = 3, 'histórico deveria ter 3 eventos';
  ASSERT painel.api('solicitacao_atualizar', tok, jsonb_build_object('id', ev, 'status', 'XYZ'))->>'ok' = 'false', 'status inválido';

  -- indicadores
  r := painel.api('resumo', tok, '{"dias":7}');
  ASSERT (r->>'ok')::boolean AND jsonb_array_length(r#>'{dados,por_dia}') = 7, 'resumo com 7 dias';

  -- condomínios
  ASSERT painel.api('condominio_salvar', tok, '{"nome":"Condomínio CI"}')->>'ok' = 'true', 'cadastrar condomínio';
  ASSERT painel.api('condominio_salvar', tok, '{"nome":"condomínio ci"}')->>'ok' = 'false', 'nome duplicado deveria falhar';

  -- configurações + decisão do bot
  ASSERT painel.api('config_salvar', tok, '{"expediente":{"dias":[1],"inicio":"18:00","fim":"09:00"}}')->>'ok' = 'false', 'horário invertido';
  PERFORM painel.api('config_salvar', tok, '{"expediente":{"dias":[1,2,3,4,5,6,7],"inicio":"00:00","fim":"23:59"},"numeros_gestor":["5517991234567"]}');
  ASSERT attendance_bot.fn_decidir('5517988887777')->>'acao' = 'cliente', 'dentro do horário deveria atender';
  ASSERT attendance_bot.fn_decidir('551791234567')->>'acao' = 'gestor', 'gestor sem o 9º dígito';
  PERFORM attendance_bot.fn_pausar('5517988887777');
  ASSERT attendance_bot.fn_decidir('5517988887777')->>'motivo' = 'atendimento_humano', 'pausa por atendimento humano';
  PERFORM painel.api('pausa_retomar', tok, '{"telefone":"5517988887777"}');
  PERFORM painel.api('config_salvar', tok, jsonb_build_object('feriados',
            jsonb_build_array(to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'))));
  ASSERT attendance_bot.fn_decidir('5517988887777')->>'acao' = 'fora_horario', 'feriado deveria enviar aviso';
  ASSERT attendance_bot.fn_decidir('5517988887777')->>'motivo' = 'aviso_ja_enviado', 'aviso não deveria repetir';
  PERFORM painel.api('config_salvar', tok, '{"bot_ativo":false,"feriados":[]}');
  ASSERT attendance_bot.fn_decidir('5517900000000')->>'motivo' = 'bot_desligado', 'bot desligado';

  -- permissões
  PERFORM painel.api('usuario_salvar', tok, '{"nome":"Atendente CI","email":"ci@escritorio.com","senha":"senhaCI1234","papel":"atendente"}');
  tok2 := painel.api('login', NULL, '{"email":"ci@escritorio.com","senha":"senhaCI1234"}')#>>'{dados,token}';
  ASSERT painel.api('config_salvar', tok2, '{"bot_ativo":true}')->>'codigo' = 'permissao', 'atendente não pode alterar configurações';
  PERFORM painel.api('logout', tok2, '{}');
  ASSERT painel.api('eu', tok2, '{}')->>'codigo' = 'auth', 'logout deveria invalidar o token';

  -- bloqueio por tentativas
  FOR i IN 1..5 LOOP PERFORM painel.api('login', NULL, '{"email":"ci@escritorio.com","senha":"x"}'); END LOOP;
  ASSERT painel.api('login', NULL, '{"email":"ci@escritorio.com","senha":"senhaCI1234"}')->>'codigo' = 'bloqueado', 'bloqueio após 5 tentativas';

  RAISE NOTICE 'Todas as verificações passaram.';
END $$;
