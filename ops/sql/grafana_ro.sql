-- Read-only role for Grafana's datasource. Idempotent: safe to rerun after a rebuild.
-- Run INSIDE the cluster, never through a public hostname:
--   PW=$(kubectl -n apps get secret grafana-secrets -o jsonpath='{.data.GRAFANA_RO_PASSWORD}' | base64 -d)
--   kubectl -n supabase exec -i supabase-supabase-db-0 -- psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v pw="$PW" < ops/sql/grafana_ro.sql
--
-- Grants only what dashboards read. Adding a table to a dashboard = add a GRANT and a policy here.
-- RLS is on for the spa_ tables, so a GRANT alone returns zero rows: each table also needs a policy.

select format('create role grafana_ro login password %L', :'pw')
  where not exists (select from pg_roles where rolname = 'grafana_ro') \gexec
select format('alter role grafana_ro login password %L', :'pw') \gexec

alter role grafana_ro set default_transaction_read_only = on;
alter role grafana_ro set statement_timeout = '10s';
alter role grafana_ro nosuperuser nocreatedb nocreaterole noinherit;

revoke all on schema public from grafana_ro;
revoke all on all tables in schema public from grafana_ro;
grant usage on schema public to grafana_ro;

-- Allowed for dashboards. Deliberately NOT granted (decided 2026-11-04): spa_spoons_entries,
-- spa_poker_packs, pab_pcs_bets, pab_lh_*, and anything holding wallets, money or health data.
-- pab_xvenue_quotes is 765 MB: dashboards will read a 5-minute view in gf, never the raw table.
grant select on public.spa_pkms_quotes to grafana_ro;
drop policy if exists "grafana_ro reads quotes" on public.spa_pkms_quotes;
create policy "grafana_ro reads quotes" on public.spa_pkms_quotes for select to grafana_ro using (true);

grant select on public.pab_collector_status to grafana_ro;
drop policy if exists "grafana_ro reads collector status" on public.pab_collector_status;
create policy "grafana_ro reads collector status" on public.pab_collector_status for select to grafana_ro using (true);

-- pab_measurements: held (2026-11-04). Its notes column carries real P&L and location remarks.
-- When a measurements dashboard is built, grant a gf view WITHOUT notes, not this table.

-- Supabase grants USAGE on schema `net` (pg_net) to PUBLIC, and PUBLIC holds ALL on its tables:
-- any login role, grafana_ro included, could read responses and queue outbound HTTP (it can
-- unset its own read-only default). Every role that needs pg_net is granted USAGE by name
-- (postgres, anon, authenticated, service_role, supabase_functions_admin), so only the PUBLIC
-- path goes. Recheck after a Supabase upgrade: an extension update can re-grant it.
revoke usage on schema net from public;
