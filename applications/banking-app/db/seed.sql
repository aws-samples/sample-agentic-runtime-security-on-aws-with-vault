-- ===========================================================================
-- Banking Schema — OscarVault International (OVI) Workshop Seed Data
--
-- Creates banking schema with accounts + transactions tables, Row-Level
-- Security (RLS) policies keyed on app.current_user_sub, and test data
-- for Oscar and Jaime.
--
-- Usage: psql -U vault_root -d workshop -f seed.sql
-- Idempotent: uses IF NOT EXISTS + ON CONFLICT DO NOTHING throughout.
--
-- RLS design:
--   The MCP server sets app.current_user_sub = '<ivia_sub>' before issuing
--   any SELECT. RLS policies filter rows so each user sees only their own
--   accounts and transactions. Vault-vended credentials have SELECT only on
--   this schema (ENFC-02 Layer 2 enforcement).
-- ===========================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS banking;

-- ---------------------------------------------------------------------------
-- Accounts table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS banking.accounts (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_sub       VARCHAR(255) NOT NULL,         -- matches IVIA JWT sub claim
  user_name      VARCHAR(100) NOT NULL,
  account_number VARCHAR(20)  UNIQUE NOT NULL,
  account_type   VARCHAR(20)  NOT NULL,          -- checking, savings
  balance        DECIMAL(12,2) NOT NULL DEFAULT 0.00,
  currency       VARCHAR(3)   NOT NULL DEFAULT 'USD',
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Transactions table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS banking.transactions (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       UUID         NOT NULL REFERENCES banking.accounts(id),
  transaction_type VARCHAR(20)  NOT NULL,        -- debit, credit, transfer
  amount           DECIMAL(12,2) NOT NULL,
  description      VARCHAR(255),
  merchant         VARCHAR(100),
  category         VARCHAR(50),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Row-Level Security (RLS)
--
-- Policies filter rows by user_sub = current_setting('app.current_user_sub').
-- The MCP server calls SET LOCAL "app.current_user_sub" = '<sub>' on each
-- connection before executing queries, which activates the RLS filter.
-- ---------------------------------------------------------------------------

ALTER TABLE banking.accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_accounts ON banking.accounts;
CREATE POLICY user_accounts ON banking.accounts
  FOR SELECT
  USING (user_sub = current_setting('app.current_user_sub', true));

ALTER TABLE banking.transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_transactions ON banking.transactions;
CREATE POLICY user_transactions ON banking.transactions
  FOR SELECT
  USING (
    account_id IN (
      SELECT id FROM banking.accounts
      WHERE user_sub = current_setting('app.current_user_sub', true)
    )
  );

-- ---------------------------------------------------------------------------
-- Test users: Oscar and Jaime
-- user_sub values match IVIA JWT sub claims used in ivia-configure.sh.
-- ---------------------------------------------------------------------------

INSERT INTO banking.accounts (id, user_sub, user_name, account_number, account_type, balance, currency)
VALUES
  -- Oscar
  ('a1000000-0000-0000-0000-000000000001', 'oscar', 'Oscar Goldman', 'OVI-CHK-100001', 'checking', 4250.00, 'USD'),
  ('a1000000-0000-0000-0000-000000000002', 'oscar', 'Oscar Goldman', 'OVI-SAV-100002', 'savings',  18750.50, 'USD'),
  -- Jaime
  ('a2000000-0000-0000-0000-000000000001', 'jaime', 'Jaime Sommers', 'OVI-CHK-200001', 'checking', 7830.25, 'USD'),
  ('a2000000-0000-0000-0000-000000000002', 'jaime', 'Jaime Sommers', 'OVI-SAV-200002', 'savings',  32100.00, 'USD')
ON CONFLICT (account_number) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Test transactions — Oscar (checking: a1000000-…-01, savings: a1000000-…-02)
-- ---------------------------------------------------------------------------

INSERT INTO banking.transactions (account_id, transaction_type, amount, description, merchant, category)
VALUES
  -- Oscar checking
  ('a1000000-0000-0000-0000-000000000001', 'debit',  -52.40, 'Grocery run',           'Whole Foods Market',     'groceries'),
  ('a1000000-0000-0000-0000-000000000001', 'debit',  -18.99, 'Streaming subscription', 'Netflix',                'entertainment'),
  ('a1000000-0000-0000-0000-000000000001', 'credit', 3500.00, 'Payroll deposit',        'OscarVault Payroll',     'income'),
  ('a1000000-0000-0000-0000-000000000001', 'debit',  -120.00, 'Electric bill',          'Pacific Gas & Electric', 'utilities'),
  ('a1000000-0000-0000-0000-000000000001', 'debit',  -45.00, 'Restaurant dinner',      'The Slanted Door',       'dining'),
  -- Oscar savings
  ('a1000000-0000-0000-0000-000000000002', 'credit', 500.00,  'Transfer from checking', 'Internal Transfer',      'transfer'),
  ('a1000000-0000-0000-0000-000000000002', 'credit', 12.50,   'Interest earned',        'OscarVault',             'interest'),
  ('a1000000-0000-0000-0000-000000000002', 'credit', 1000.00, 'Year-end bonus deposit', 'OscarVault Payroll',     'income')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Test transactions — Jaime (checking: a2000000-…-01, savings: a2000000-…-02)
-- ---------------------------------------------------------------------------

INSERT INTO banking.transactions (account_id, transaction_type, amount, description, merchant, category)
VALUES
  -- Jaime checking
  ('a2000000-0000-0000-0000-000000000001', 'debit',  -88.30, 'Pharmacy',               'CVS Pharmacy',           'health'),
  ('a2000000-0000-0000-0000-000000000001', 'credit', 4200.00, 'Payroll deposit',        'OscarVault Payroll',     'income'),
  ('a2000000-0000-0000-0000-000000000001', 'debit',  -65.00, 'Monthly gym membership', 'Equinox',                'fitness'),
  ('a2000000-0000-0000-0000-000000000001', 'debit',  -210.00, 'Airfare booking',        'United Airlines',        'travel'),
  ('a2000000-0000-0000-0000-000000000001', 'debit',  -34.99, 'Books',                  'Amazon',                 'shopping'),
  -- Jaime savings
  ('a2000000-0000-0000-0000-000000000002', 'credit', 800.00,  'Transfer from checking', 'Internal Transfer',      'transfer'),
  ('a2000000-0000-0000-0000-000000000002', 'credit', 24.75,   'Interest earned',        'OscarVault',             'interest'),
  ('a2000000-0000-0000-0000-000000000002', 'credit', 2000.00, 'Savings goal deposit',   'OscarVault',             'savings'),
  ('a2000000-0000-0000-0000-000000000002', 'debit',  -500.00, 'Emergency fund draw',    'Internal Transfer',      'transfer')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Refunds table (UC3 — CIBA privileged write)
--
-- The UC3 agent (privileged actor) writes approved refund records here.
-- Vault uc3-refund-writer role grants SELECT on banking.transactions and
-- SELECT + INSERT + UPDATE on banking.refunds (no DELETE — audit preservation).
-- approved_by holds the Vault entity alias (agent service account) so the
-- write is attributable in the three-plane audit JOIN.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS banking.refunds (
  refund_id      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     UUID          NOT NULL REFERENCES banking.accounts(id),
  transaction_id UUID          NOT NULL REFERENCES banking.transactions(id),
  amount      DECIMAL(12,2) NOT NULL,
  currency    VARCHAR(3)    NOT NULL DEFAULT 'USD',
  approved_by VARCHAR(255)  NOT NULL,
  request_id  UUID          NOT NULL,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Self-healing migration: add transaction_id to refunds tables created before
-- this column existed (CREATE TABLE IF NOT EXISTS above is a no-op on those).
ALTER TABLE banking.refunds
  ADD COLUMN IF NOT EXISTS transaction_id UUID REFERENCES banking.transactions(id);
