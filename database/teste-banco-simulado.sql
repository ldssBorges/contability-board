-- Simula o banco atual (estrutura deduzida do workflow v1) para testar a migração
CREATE SCHEMA attendance_bot;
CREATE SCHEMA dashboard;
CREATE TYPE attendance_bot.event_status AS ENUM ('OPEN','IN_PROGRESS','COMPLETED','CANCELED');

CREATE TABLE attendance_bot.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text, phone_number text NOT NULL,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);
CREATE TABLE attendance_bot.condominiums (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL
);
CREATE TABLE attendance_bot.events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES attendance_bot.customers(id),
  condominium_id uuid REFERENCES attendance_bot.condominiums(id),
  request_resume text,
  status attendance_bot.event_status DEFAULT 'OPEN',
  phone_number text,
  register_date date NOT NULL,
  conclused_at timestamptz
);
CREATE TABLE dashboard.bot_metrics (
  id bigserial PRIMARY KEY, evento text, telefone text, atendimento_id text,
  criado_em timestamptz DEFAULT now()
);
CREATE TABLE dashboard.event_meta (
  event_id uuid PRIMARY KEY, service_type text
);

INSERT INTO attendance_bot.condominiums(name) VALUES ('Residencial Jardim das Flores'),('Edifício Solar Rio Preto');
INSERT INTO attendance_bot.customers(name, phone_number) VALUES ('Maria Souza','5517991112222'),('João Lima','5517988887777');
INSERT INTO attendance_bot.events(customer_id, condominium_id, request_resume, status, phone_number, register_date)
SELECT c.id, (SELECT id FROM attendance_bot.condominiums ORDER BY name LIMIT 1), '2ª via do boleto de setembro, Bloco B ap 12', 'OPEN', c.phone_number, current_date - 2
FROM attendance_bot.customers c WHERE c.name='Maria Souza';
INSERT INTO attendance_bot.events(customer_id, condominium_id, request_resume, status, phone_number, register_date, conclused_at)
SELECT c.id, (SELECT id FROM attendance_bot.condominiums ORDER BY name DESC LIMIT 1), 'Autorização de mudança (entrada) sábado', 'COMPLETED', c.phone_number, current_date - 5, now() - interval '3 days'
FROM attendance_bot.customers c WHERE c.name='João Lima';
INSERT INTO dashboard.event_meta SELECT id, CASE WHEN status='OPEN' THEN 'boleto_2via' ELSE 'autorizacao_mudanca' END FROM attendance_bot.events;
INSERT INTO dashboard.bot_metrics(evento, telefone) VALUES ('msg_recebida','5517991112222'),('msg_enviada','5517991112222');
