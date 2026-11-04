-- Grafana-owned objects: schema gf, sampled by pg_cron. Idempotent. Run AFTER grafana_ro.sql:
--   kubectl -n supabase exec -i supabase-supabase-db-0 -c supabase-db -- psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < ops/sql/grafana_views.sql
-- Not in `public` on purpose: Supabase's default privileges grant every new public table to anon,
-- which PostgREST serves on db.seanpe.io. gf is not in PostgREST's schema list and PUBLIC gets nothing.

create schema if not exists gf;
revoke all on schema gf from public;
grant usage on schema gf to grafana_ro;

-- pab_collector_status only holds the latest beat; this keeps the history the ingest chart needs.
create table if not exists gf.collector_samples (
  sampled_at timestamptz not null default date_trunc('minute', now()),
  instance   text        not null,
  total_rows bigint      not null,
  last_beat  timestamptz,
  primary key (instance, sampled_at)
);
create index if not exists collector_samples_sampled_at on gf.collector_samples (sampled_at);
revoke all on all tables in schema gf from public;
grant select on gf.collector_samples to grafana_ro;

create extension if not exists pg_cron;   -- preloaded by the Supabase image; jobs live in cron.job
-- cron.schedule with an existing name replaces that job, so reruns are clean.
select cron.schedule('gf-collector-sample', '* * * * *', $$
  insert into gf.collector_samples (instance, total_rows, last_beat)
  select instance, total_rows, last_beat from public.pab_collector_status
  on conflict do nothing $$);
select cron.schedule('gf-collector-prune', '17 3 * * *', $$
  delete from gf.collector_samples where sampled_at < now() - interval '30 days' $$);
select cron.schedule('gf-cron-history-prune', '23 3 * * *', $$
  delete from cron.job_run_details where end_time < now() - interval '7 days' $$);
