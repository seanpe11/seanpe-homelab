-- Host heartbeats + collector cadence for the Pipeline health dashboard. Idempotent.
-- Run AFTER grafana_ro.sql and grafana_views.sql:
--   kubectl -n supabase exec -i supabase-supabase-db-0 -c supabase-db -- psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < ops/sql/host_beat.sql
--
-- Write path (decided 2026-11-04): hosts call PostgREST RPC  POST https://db.seanpe.io/rest/v1/rpc/host_beat
-- with  apikey: <anon key>  and  Authorization: Bearer <per-host JWT, role=host_beat, host=<name>>.
-- host_beat is NOLOGIN: nothing can log in as it, PostgREST only switches into it for a valid JWT.
-- It can INSERT rows into gf.host_samples through this one function, for the host its token names. No SELECT anywhere.

-- ---------------------------------------------------------------- role
select 'create role host_beat nologin noinherit'
  where not exists (select from pg_roles where rolname = 'host_beat') \gexec
grant host_beat to authenticator;   -- lets PostgREST SET ROLE host_beat for a JWT with role=host_beat

-- ---------------------------------------------------------------- tables (schema gf: not served by PostgREST)
create table if not exists gf.hosts (
  host                text primary key,
  expected_interval_s integer not null default 60,
  added_at            timestamptz not null default now()   -- start of the reachability window before a first beat
);
insert into gf.hosts (host) values ('rocinante'), ('donnager'), ('pegasus') on conflict do nothing;

create table if not exists gf.host_samples (
  host          text not null references gf.hosts (host),
  sampled_at    timestamptz not null default now(),   -- server clock, not the host's
  boot_time     timestamptz,                          -- /proc/stat btime: stable across beats, changes on reboot
  uptime_s      bigint,
  load1         real,
  mem_used_pct  real,
  disk_root_pct real,
  agent_version text,
  primary key (host, sampled_at)
);
create index if not exists host_samples_sampled_at on gf.host_samples (sampled_at);

create or replace view gf.host_status as
  select h.host, h.expected_interval_s, s.sampled_at as last_beat, s.boot_time, s.uptime_s,
         s.load1, s.mem_used_pct, s.disk_root_pct, s.agent_version
  from gf.hosts h
  left join lateral (select * from gf.host_samples x where x.host = h.host
                     order by sampled_at desc limit 1) s on true;

-- Cadence lives here, not in prediction-arbitrage's pab_collector_status.
-- Measured 2026-11-04 from gf.collector_samples (median gap between distinct last_beat values).
create table if not exists gf.collector_expectations (
  instance            text primary key,
  expected_interval_s integer not null
);
insert into gf.collector_expectations values
  ('kalshi_wx', 300), ('pcs_rounds', 300),
  ('lock_hedge', 60), ('pcs_poly', 60), ('xvenue', 60), ('xvenue_universal', 60)
  on conflict (instance) do update set expected_interval_s = excluded.expected_interval_s;

-- ---------------------------------------------------------------- the one write path
create or replace function public.host_beat(
  p_host text, p_boot_time timestamptz, p_uptime_s bigint, p_load1 real,
  p_mem_used_pct real, p_disk_root_pct real, p_agent_version text
) returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  -- a token is minted for one host; it cannot beat for another
  if p_host is distinct from (current_setting('request.jwt.claims', true)::json ->> 'host') then
    raise exception 'token is not for host %', p_host using errcode = '42501';
  end if;
  insert into gf.host_samples (host, boot_time, uptime_s, load1, mem_used_pct, disk_root_pct, agent_version)
  values (p_host, p_boot_time, p_uptime_s, p_load1, p_mem_used_pct, p_disk_root_pct, left(p_agent_version, 32));
end $$;

-- Supabase default-grants EXECUTE on new public functions to anon/authenticated/service_role: take it all back.
revoke all on function public.host_beat(text, timestamptz, bigint, real, real, real, text) from public, anon, authenticated, service_role;
grant execute on function public.host_beat(text, timestamptz, bigint, real, real, real, text) to host_beat;

grant usage on schema gf to host_beat;
revoke all on gf.host_samples, gf.hosts, gf.host_status, gf.collector_expectations from host_beat;
grant insert on gf.host_samples to host_beat;
grant select (host) on gf.hosts to host_beat;   -- the FK check needs to see the key; nothing else

-- "95" → "95s", "3700" → "1h": tile labels on the dashboard.
create or replace function gf.ago(s double precision) returns text
language sql immutable as $$
  select case when s is null then 'never'
              when s < 120    then round(s)::int || 's'
              when s < 7200   then floor(s / 60)::int || 'm'
              when s < 172800 then floor(s / 3600)::int || 'h'
              else floor(s / 86400)::int || 'd' end $$;
revoke all on function gf.ago(double precision) from public;
grant execute on function gf.ago(double precision) to grafana_ro;

-- ---------------------------------------------------------------- readers + retention
revoke all on gf.hosts, gf.host_samples, gf.host_status, gf.collector_expectations from public;
grant select on gf.hosts, gf.host_samples, gf.host_status, gf.collector_expectations to grafana_ro;

select cron.schedule('gf-host-prune', '19 3 * * *', $$
  delete from gf.host_samples where sampled_at < now() - interval '30 days' $$);

notify pgrst, 'reload schema';
