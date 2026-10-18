\set ON_ERROR_STOP 1
\pset tuples_only on
-- login errado e certo
SELECT 'login_errado', painel.api('login', NULL, '{"email":"admin@escritorio.com","senha":"x"}')->>'erro';
SELECT set_config('t.tok', painel.api('login', NULL, '{"email":"Admin@Escritorio.com ","senha":"TroqueEstaSenha123"}')#>>'{dados,token}', false);
SELECT 'sem_token', painel.api('resumo', 'abc', '{}')->>'codigo';
SELECT 'eu', painel.api('eu', current_setting('t.tok'), '{}')#>>'{dados,usuario,nome}';
SELECT 'resumo', jsonb_pretty((painel.api('resumo', current_setting('t.tok'), '{"dias":7}')->'dados') - 'por_dia'::text);
SELECT 'por_dia_len', jsonb_array_length(painel.api('resumo', current_setting('t.tok'), '{"dias":7}')#>'{dados,por_dia}');
SELECT 'lista', jsonb_array_length(painel.api('solicitacoes_listar', current_setting('t.tok'), '{}')#>'{dados,itens}');
SELECT set_config('t.ev', (SELECT id::text FROM attendance_bot.events WHERE status='OPEN' LIMIT 1), false);
SELECT 'atualizar', painel.api('solicitacao_atualizar', current_setting('t.tok'),
        jsonb_build_object('id', current_setting('t.ev'), 'status','IN_PROGRESS','prioridade','alta'))#>>'{dados,responsavel,nome}';
SELECT 'nota', jsonb_array_length(painel.api('nota_adicionar', current_setting('t.tok'),
        jsonb_build_object('id', current_setting('t.ev'), 'texto','Liguei para a cliente, boleto enviado por e-mail'))#>'{dados,notas}');
SELECT 'concluir', painel.api('solicitacao_atualizar', current_setting('t.tok'),
        jsonb_build_object('id', current_setting('t.ev'), 'status','COMPLETED'))#>>'{dados,concluido_em}' IS NOT NULL;
SELECT 'historico', jsonb_pretty(painel.api('solicitacao_detalhe', current_setting('t.tok'),
        jsonb_build_object('id', current_setting('t.ev')))#>'{dados,historico}');
SELECT 'status_invalido', painel.api('solicitacao_atualizar', current_setting('t.tok'),
        jsonb_build_object('id', current_setting('t.ev'), 'status','XYZ'))->>'erro';
-- condomínios
SELECT 'cond_novo', painel.api('condominio_salvar', current_setting('t.tok'),
        '{"nome":"Condomínio Vila Nova","cidade":"São José do Rio Preto","sindico_telefone":"(17) 99111-2222"}')->>'ok';
SELECT 'cond_dup', painel.api('condominio_salvar', current_setting('t.tok'), '{"nome":"condomínio vila nova"}')->>'erro';
SELECT 'cond_lista', jsonb_array_length(painel.api('condominios_listar', current_setting('t.tok'), '{}')#>'{dados,itens}');
-- configurações e decisão do bot
SELECT 'cfg_invalida', painel.api('config_salvar', current_setting('t.tok'), '{"expediente":{"dias":[1,2],"inicio":"18:00","fim":"09:00"}}')->>'erro';
SELECT 'cfg_24h', painel.api('config_salvar', current_setting('t.tok'),
        '{"expediente":{"dias":[1,2,3,4,5,6,7],"inicio":"00:00","fim":"23:59"},"numeros_gestor":["5517991234567"]}')#>>'{dados,expediente_aberto_agora}';
SELECT 'decide_cliente', attendance_bot.fn_decidir('5517988887777')->>'acao';
SELECT 'decide_gestor_sem9', attendance_bot.fn_decidir('551791234567')->>'acao';
SELECT 'pausar', attendance_bot.fn_pausar('5517988887777')->>'ok';
SELECT 'decide_pausado', attendance_bot.fn_decidir('5517988887777')->>'motivo';
SELECT 'pausas', jsonb_array_length(painel.api('pausas_listar', current_setting('t.tok'), '{}')#>'{dados,itens}');
SELECT 'retomar', painel.api('pausa_retomar', current_setting('t.tok'), '{"telefone":"5517988887777"}')->>'ok';
SELECT 'cfg_fechado', (painel.api('config_salvar', current_setting('t.tok'),
        ('{"expediente":{"dias":[1,2,3,4,5],"inicio":"09:00","fim":"17:00"},"feriados":["' || to_char(now() AT TIME ZONE 'America/Sao_Paulo','YYYY-MM-DD') || '"]}')::jsonb))#>>'{dados,expediente_aberto_agora}';
SELECT 'decide_fora1', attendance_bot.fn_decidir('5517988887777')->>'acao';
SELECT 'decide_fora2', attendance_bot.fn_decidir('5517988887777')->>'motivo';
SELECT 'bot_off', painel.api('config_salvar', current_setting('t.tok'), '{"bot_ativo":false,"feriados":[]}')->>'ok';
SELECT 'decide_off', attendance_bot.fn_decidir('5517900000000')->>'motivo';
-- usuários
SELECT 'user_novo', painel.api('usuario_salvar', current_setting('t.tok'),
        '{"nome":"Ana Atendente","email":"ana@escritorio.com","senha":"senhaDaAna1","papel":"atendente"}')->>'ok';
SELECT set_config('t.tok2', painel.api('login', NULL, '{"email":"ana@escritorio.com","senha":"senhaDaAna1"}')#>>'{dados,token}', false);
SELECT 'ana_cfg', painel.api('config_salvar', current_setting('t.tok2'), '{"bot_ativo":true}')->>'codigo';
SELECT 'ana_resp', jsonb_array_length(painel.api('usuarios_resumo', current_setting('t.tok2'), '{}')#>'{dados,itens}');
SELECT 'acao_x', painel.api('xpto', current_setting('t.tok2'), '{}')->>'erro';
SELECT 'logout', painel.api('logout', current_setting('t.tok2'), '{}')->>'ok', painel.api('eu', current_setting('t.tok2'), '{}')->>'codigo';
-- força bruta
SELECT 'bf', painel.api('login', NULL, '{"email":"ana@escritorio.com","senha":"x"}')->>'codigo' FROM generate_series(1,6) ORDER BY 1 LIMIT 1;
SELECT 'bf_final', painel.api('login', NULL, '{"email":"ana@escritorio.com","senha":"senhaDaAna1"}')->>'codigo';
