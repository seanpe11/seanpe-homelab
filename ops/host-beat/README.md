# host-beat

A once-a-minute heartbeat from each host, read by the **Hosts** row of the Pipeline health
Grafana dashboard. There's no Prometheus, by choice. This is the same pattern as the collector heartbeats.

```
host-beat.timer (60 s) → host-beat.sh → POST https://db.seanpe.io/rest/v1/rpc/host_beat
                                       → PostgREST, SET ROLE host_beat → gf.host_samples
```

- **Credential:** a per-host JWT (`role=host_beat`, `host=<name>`, 1-year expiry), signed with
  Supabase's JWT secret. `host_beat` is NOLOGIN and can only *insert* a sample, through
  `public.host_beat()`, for the host its token names. It can't read anything. A leaked token can
  fake one host's heartbeat and nothing more. SQL: `ops/sql/host_beat.sql`.
- **Why this path:** it reuses the public API host that already exists. Rejected: a tailnet
  NodePort for Postgres, which would make every password role, superusers included, reachable from
  the tailnet; and the MCP endpoint, which is superuser SQL with no auth.
- **Runtime:** bash, curl, `/proc`. Nothing to install on a normal Linux host. Optional:
  `nvidia-smi` (GPU name and utilisation), else an amdgpu's `gpu_busy_percent` in sysfs, else
  `lspci` (GPU name only). A host with none of them still beats, with no GPU in its line.
- **What leaves the host (v2, 2026-11-05):** boot time, uptime, load, memory and root-disk use,
  plus the hardware line: CPU and GPU **model names**, their utilisation, and total RAM. These
  show on public dashboards, and Sean cleared exactly these. **Don't add** kernel, OS or package
  versions, usernames, IPs, MACs, serials, PCI addresses, disk paths or mount names, or process
  names: anything that narrows a CVE hunt. Ask first. Each run takes about 1 s (two `/proc/stat`
  reads for CPU use). A v1 agent keeps working: the new RPC parameters have defaults.
- **Hosts the dashboard expects:** rows in `gf.hosts`. A host with no beats shows red. That's on
  purpose, so pegasus is red until it comes back.

## Files

| File | Installs to |
| :--- | :--- |
| `host-beat.sh` | `~/.local/bin/host-beat` (mode 755) |
| `host-beat.service`, `host-beat.timer` | `~/.config/systemd/user/` (mode 644) |
| env file from `mint-token.sh` | `~/.config/host-beat/env` (mode **600**, never in git) |

The units use `%h`, so the same files work for any user. Lingering must be on
(`loginctl enable-linger <user>`) or the timer stops when the user logs out.

## Install on a host

From rocinante, which has the cluster kubeconfig:

```sh
ops/host-beat/mint-token.sh <host> /tmp/host-beat.env        # writes mode 600, prints nothing secret
scp /tmp/host-beat.env <user>@<host>:.config/host-beat/env && rm /tmp/host-beat.env
scp ops/host-beat/host-beat.sh <user>@<host>:.local/bin/host-beat
scp ops/host-beat/host-beat.{service,timer} <user>@<host>:.config/systemd/user/
ssh <user>@<host> 'chmod 600 ~/.config/host-beat/env; chmod 755 ~/.local/bin/host-beat;
  systemctl --user daemon-reload && systemctl --user enable --now host-beat.timer &&
  systemctl --user start host-beat.service && systemctl --user show host-beat.service -p Result'
```

(Create `~/.config/host-beat`, `~/.local/bin` and `~/.config/systemd/user` on the host first if
they don't exist.) `Result=success` means the beat landed. The tile turns green within a minute.

- **rocinante:** installed 2026-11-05.
- **pegasus:** offline right now. Run the block above when it's back. Nothing changes on the
  cluster side, because `gf.hosts` already lists it.
- **donnager:** don't install by hand. Its host layer is Ansible in `pemily-homelab`. A role there
  should do the following (all four files copy as-is):
  - `copy` `host-beat.sh` → `~/.local/bin/host-beat`, mode 0755
  - `copy` the two units → `~/.config/systemd/user/`, mode 0644
  - `template`/`copy` the env file from a SOPS- or vault-encrypted variable → `~/.config/host-beat/env`, mode 0600
  - `ansible.builtin.systemd_service: name=host-beat.timer scope=user enabled=true state=started daemon_reload=true`
  - linger is already on for `pemily`

  Mint donnager's env file with `mint-token.sh donnager <file>` and encrypt it into that repo.
  Don't commit it in plaintext.

## Add a host / rotate a token

- New host: `insert into gf.hosts (host) values ('<name>') on conflict do nothing;` (add it to
  `ops/sql/host_beat.sql` too), then install as above.
- Tokens expire 1 year after minting. When a tile goes red with the host still up, check
  `journalctl --user -u host-beat` for `HTTP 401 … JWT expired`, then re-mint and copy the env file.
- Revoke one host's beats: `delete from gf.hosts …` breaks its inserts (FK). Revoke everyone's:
  `revoke execute on function public.host_beat(…) from host_beat`.
