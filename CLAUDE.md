# seanpe-homelab — context for Claude

**This repo is Sean's personal cluster**: k3s inside the Incus VM `seanpe-homelab-1` (10.77.0.10)
on donnager. Household services (Immich, Jellyfin, books, Deluge) belong to the **family** cluster
in `~/Documents/projects/pemily-homelab`, not here.

| Name | Is | Repo |
| :--- | :--- | :--- |
| **donnager** | the machine (OptiPlex 7070, one 1 TB SSD, Ubuntu 26.04) | host layer in pemily-homelab/ansible |
| **pemily-homelab** | family cluster, k3s on donnager's host | `~/Documents/projects/pemily-homelab` |
| **seanpe-homelab** | personal cluster, k3s in the VM | **this repo** (public) |

History and reasoning: vault `03-Library/Homelab Revival Report 2026-09-15.md` and
`02-Projects/HomeLab Project.md` in `~/Documents/PepeVault`.

## What runs here

| Thing | Where | Public at |
| :--- | :--- | :--- |
| Supabase (Postgres 17, Kong, Studio…) | `infrastructure/base/supabase` | `db.seanpe.io` (API paths only), `supabase.seanpe.io` (behind Cloudflare Access) |
| seanpe-api | `apps/base/seanpe-api` | `api.seanpe.io` (writes need `X-API-Key`) |
| portfolio (seanpe-com) | `apps/base/seanpe-com` | `portfolio.seanpe.io` |
| cloudflared, tunnel `seanpe-homelab-cluster` | `infrastructure/base/cloudflared` | all of the above |

Flux order: `infrastructure-core` → `infrastructure-db` (Supabase, `wait: true`) → `apps`; `utils`
after core. Flux reads the repo anonymously over HTTPS because it's public. Making it private breaks
`gotk-sync.yaml`.

## Reaching it

```sh
systemctl --user status seanpe-homelab-api       # ssh tunnel 127.0.0.1:6444 → VM:6443
export KUBECONFIG=~/.kube/seanpe-homelab.yaml
flux get kustomizations
ssh -J pemily@donnager ubuntu@10.77.0.10          # VM shell
```
Sean often works through **ttyd from another machine**, so a `kubectl port-forward` to localhost
does not reach his browser. Give him a URL instead.

Storage is `local-path` only: a PVC is a directory on the VM's 60 GiB disk. Its size is a label,
not a quota, and it can't expand. Check `df -h /` in the VM before sizing anything.

## Traps that already cost time

- **cloudflared: credentials file, never a token.** A token, or any tunnel that ever had dashboard
  config, pulls remote config and silently ignores the ConfigMap's ingress rules. This tunnel was
  CLI-created for that reason.
- **cloudflared doesn't reload its ConfigMap.** After changing ingress rules, Flux applies the
  ConfigMap but the pods keep the old rules. Run `kubectl -n networking rollout restart deploy`.
- **`cloudflared tunnel route dns` on donnager** reads `~/.cloudflared/config.yml` and routes to the
  *host's* tunnel. Always run `cloudflared tunnel --config /dev/null route dns <UUID> <host>`
  (from rocinante too; it works there).
- **SOPS:** age key at `~/Documents/explore/age.key`, public half in `.sops.yaml`. **In fish, `~` is
  not expanded after `=`**, so use `env SOPS_AGE_KEY_FILE=$HOME/Documents/explore/age.key sops …`.
  Otherwise sops silently tries another key and reports "no master key was able to decrypt". Every
  Kustomization that touches a `*.sops.yaml` needs a `decryption:` block.
- **Supabase's MCP endpoint is superuser SQL with no auth.** It's reachable on the tailnet only
  (NodePort 30300), never on a public hostname. See `ops/rocinante/README.md`.
- **Flux prune leaves a StatefulSet's `volumeClaimTemplates` PVCs behind.** Delete them by hand when
  removing a StatefulSet.
- **Upstream compose `depends_on: service_healthy`** has no k8s equivalent. Add an initContainer that
  waits for the database, or the app crash-loops on first deploy.
- `ops/rocinante/pg-dump-pull` backs up **Supabase only**. Anything else with a database here needs
  its own dump.

## Conventions

- Commits: `type(scope): subject`. Pin image tags in the overlay's `images:` (`apps/production`),
  not in base manifests.
- A Secret goes in a file named `*.sops.yaml`, generated with `openssl rand`. Check `git diff`
  before pushing: this repo is public.
