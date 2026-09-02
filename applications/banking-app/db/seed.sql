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
-- Refunds table (UC3 — CIBA privileged write)
--
-- Created here (BEFORE the RLS block below) so that ALTER TABLE / CREATE
-- POLICY statements that reference banking.refunds can resolve on first run.
-- Detail commentary on Vault role + approved_by attribution lives with the
-- self-healing migration further down (search for "Self-healing migration").
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

-- ---------------------------------------------------------------------------
-- Row-Level Security (RLS)
--
-- Policies filter rows by user_sub = current_setting('app.current_user_sub').
-- The MCP server calls SET LOCAL "app.current_user_sub" = '<sub>' on each
-- connection before executing queries, which activates the RLS filter.
--
-- Idempotency prelude: disable FORCE on all three tables before INSERTs run.
-- pg_class persists the FORCE flag across re-runs, so the owner's seed INSERTs
-- would be blocked by RLS if FORCE were already set and the GUC is unset during
-- seeding. The epilogue at the bottom of this file re-enables FORCE after all
-- INSERTs have completed.
-- ---------------------------------------------------------------------------

ALTER TABLE IF EXISTS banking.accounts NO FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS banking.transactions NO FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS banking.refunds NO FORCE ROW LEVEL SECURITY;

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

ALTER TABLE banking.refunds ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS refund_select_own ON banking.refunds;
CREATE POLICY refund_select_own ON banking.refunds
  FOR SELECT
  USING (
    account_id IN (
      SELECT id FROM banking.accounts
      WHERE user_sub = current_setting('app.current_user_sub', true)
    )
  );

DROP POLICY IF EXISTS refund_insert_own ON banking.refunds;
CREATE POLICY refund_insert_own ON banking.refunds
  FOR INSERT
  WITH CHECK (
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

-- id values are explicit UUID literals (matching the account-id pattern) so
-- ON CONFLICT (id) DO NOTHING makes this INSERT idempotent across re-runs.
INSERT INTO banking.transactions (id, account_id, transaction_type, amount, description, merchant, category)
VALUES
  -- Oscar checking
  ('b1000001-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'debit',  -52.40, 'Grocery run',           'Whole Foods Market',     'groceries'),
  ('b1000001-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'debit',  -18.99, 'Streaming subscription', 'Netflix',                'entertainment'),
  ('b1000001-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'credit', 3500.00, 'Payroll deposit',        'OscarVault Payroll',     'income'),
  ('b1000001-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'debit',  -120.00, 'Electric bill',          'Pacific Gas & Electric', 'utilities'),
  ('b1000001-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'debit',  -45.00, 'Restaurant dinner',      'The Slanted Door',       'dining'),
  -- Oscar savings
  ('b1000002-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'credit', 500.00,  'Transfer from checking', 'Internal Transfer',      'transfer'),
  ('b1000002-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000002', 'credit', 12.50,   'Interest earned',        'OscarVault',             'interest'),
  ('b1000002-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000002', 'credit', 1000.00, 'Year-end bonus deposit', 'OscarVault Payroll',     'income')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Test transactions — Jaime (checking: a2000000-…-01, savings: a2000000-…-02)
-- ---------------------------------------------------------------------------

INSERT INTO banking.transactions (id, account_id, transaction_type, amount, description, merchant, category)
VALUES
  -- Jaime checking
  ('b2000001-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'debit',  -88.30, 'Pharmacy',               'CVS Pharmacy',           'health'),
  ('b2000001-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000001', 'credit', 4200.00, 'Payroll deposit',        'OscarVault Payroll',     'income'),
  ('b2000001-0000-0000-0000-000000000003', 'a2000000-0000-0000-0000-000000000001', 'debit',  -65.00, 'Monthly gym membership', 'Equinox',                'fitness'),
  ('b2000001-0000-0000-0000-000000000004', 'a2000000-0000-0000-0000-000000000001', 'debit',  -210.00, 'Airfare booking',        'United Airlines',        'travel'),
  ('b2000001-0000-0000-0000-000000000005', 'a2000000-0000-0000-0000-000000000001', 'debit',  -34.99, 'Books',                  'Amazon',                 'shopping'),
  -- Jaime savings
  ('b2000002-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'credit', 800.00,  'Transfer from checking', 'Internal Transfer',      'transfer'),
  ('b2000002-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000002', 'credit', 24.75,   'Interest earned',        'OscarVault',             'interest'),
  ('b2000002-0000-0000-0000-000000000003', 'a2000000-0000-0000-0000-000000000002', 'credit', 2000.00, 'Savings goal deposit',   'OscarVault',             'savings'),
  ('b2000002-0000-0000-0000-000000000004', 'a2000000-0000-0000-0000-000000000002', 'debit',  -500.00, 'Emergency fund draw',    'Internal Transfer',      'transfer')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Refunds table — Vault role + approved_by attribution
--
-- The UC3 agent (privileged actor) writes approved refund records to
-- banking.refunds (CREATE TABLE is up-front, near the transactions table, so
-- the RLS block can reference it on first run).
-- Vault uc3-refund-writer role grants SELECT on banking.transactions and
-- SELECT + INSERT + UPDATE on banking.refunds (no DELETE — audit preservation).
-- approved_by holds the authenticated user's sub (set by the uc3-agent from the
-- CIBA-validated authenticated_sub, established in 07.6) so the write is
-- attributable in the three-plane audit JOIN.
--
-- Self-healing migration: add transaction_id to refunds tables created before
-- this column existed (CREATE TABLE IF NOT EXISTS up-front is a no-op there).
-- ---------------------------------------------------------------------------

ALTER TABLE banking.refunds
  ADD COLUMN IF NOT EXISTS transaction_id UUID REFERENCES banking.transactions(id);

-- ---------------------------------------------------------------------------
-- One refund per approval — enforced by the database, not by application code.
--
-- request_id is the id of the human approval the refund was granted under. The
-- agent obtains a Vault credential per approval, but a credential can be used
-- for as many INSERTs as its TTL allows: without this constraint one phone
-- approval could be redeemed repeatedly, and was (issue #31).
--
-- Deliberately NOT self-healing: if the table already holds two rows for one
-- request_id, this CREATE fails and names the duplicate key. That failure is the
-- truth — the data contradicts the invariant — and the rows are audit records
-- the uc3-refund-writer role is intentionally not permitted to DELETE. Resolve
-- it by inspecting the duplicates, never by dropping the constraint:
--   SELECT request_id, count(*), sum(amount) FROM banking.refunds
--    GROUP BY 1 HAVING count(*) > 1;
-- ---------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS refunds_request_id_key
  ON banking.refunds (request_id);

-- ---------------------------------------------------------------------------
-- Owner-bound RLS epilogue
--
-- Binds the table owner (vault_root) to the same RLS policies as any other
-- role. Without this flag the table owner bypasses RLS entirely, defeating
-- the tenant-isolation guarantee even when RLS is enabled.
--
-- MUST be placed here — AFTER all INSERT statements and self-healing DDL —
-- because pg_class persists this flag: on a re-run the owner's INSERTs at
-- seed-time would be blocked if FORCE were already set and app.current_user_sub
-- is unset during seeding. The NO FORCE prelude at the top of this file
-- guarantees safe re-entry; this epilogue restores the defence after seeding.
-- ---------------------------------------------------------------------------

ALTER TABLE banking.accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE banking.transactions FORCE ROW LEVEL SECURITY;
ALTER TABLE banking.refunds FORCE ROW LEVEL SECURITY;
