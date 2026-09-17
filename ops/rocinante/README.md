# ops/rocinante

Things that run on the workstation rather than on donnager.

## Supabase MCP — how agents reach the database

Studio serves Supabase's MCP endpoint at `/api/mcp`. It runs SQL as **supabase_admin —
superuser, read-write** (verified), and has **no authentication of its own**; Supabase's docs
say not to expose it to the Internet. So it is never routed through cloudflared or Cloudflare
Access. Two ways in, both private:

| Path | URL | Notes |
| :--- | :--- | :--- |
| **Tailnet (current)** | `http://seanpe-homelab-1:30300/api/mcp` | NodePort on the VM, reachable from any machine on the tailnet. Registered with Claude at user scope. |
| Local port-forward (fallback) | `http://127.0.0.1:54323/api/mcp` | `supabase-mcp-tunnel.service`, disabled. Enable it if the VM ever drops off the tailnet. |

**Worth knowing:** anything on the tailnet can reach it — phones and pegasus included. Tighten
with a Tailscale ACL if that matters.

## seanpe-homelab-api — kubectl access

The cluster runs in an Incus VM on donnager with no exposed API. This unit keeps an SSH tunnel
`127.0.0.1:6444 → donnager → 10.77.0.10:6443`; `~/.kube/seanpe-homelab.yaml` points at it.

```sh
systemctl --user link $PWD/seanpe-homelab-api.service
systemctl --user enable --now seanpe-homelab-api.service
kubectl --kubeconfig ~/.kube/seanpe-homelab.yaml get nodes
```

## pg-dump-pull — the offline copy of the Supabase database

| Copy | Where | Job |
| :--- | :--- | :--- |
| Primary | Supabase (`supabase/postgres` 17) on the seanpe-homelab cluster, donnager | live |
| Off-site | Linode — WAL-G archive + base backups *(not built yet: needs Linode access)* | point-in-time recovery if donnager dies |
| **Offline** | **rocinante, this timer** | a portable nightly dump; survives a bad write reaching the other two |

Dumps land in `~/backups/supabase/` (`.dump` + `.roles.sql`), newest 14 kept. That directory
does **not** survive rocinante's reinstall — copy it off first.

> **Unverified until the first run:** that `pg_dump -U supabase_admin -h localhost` authenticates
> with the container's `PGPASSWORD`. Run the service by hand once and read the journal.

```sh
# needs seanpe-homelab-api.service linked first (above)
systemctl --user link $PWD/pg-dump-pull.service $PWD/pg-dump-pull.timer
systemctl --user enable --now pg-dump-pull.timer
systemctl --user start pg-dump-pull.service && journalctl --user -u pg-dump-pull -n 5   # test now
```

Restore into a fresh Postgres: `psql -f <stamp>.roles.sql` then `pg_restore --no-owner -d postgres <stamp>.dump`
(needs a local `pg_restore` at least as new as the server).
