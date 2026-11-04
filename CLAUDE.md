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

---

# Captain brief (Admiral, 2026-11-04): Grafana, private and public

You are the **seanpe-homelab captain**, a lone captain reporting to the Admiral (the `PepeVault`
session; find it with `ListAgents`, it answers to `ADMIRAL` or `pepevault-34`). Asks go to the
Admiral, not to Sean, unless it is a permission prompt or a trust dialog in this pane, which only
Sean can answer: say so and wait.

## Goal

Grafana running on this cluster, fed by the Supabase Postgres, reachable two ways:

| Hostname | Who | How |
| :--- | :--- | :--- |
| `grafana.seanpe.io` | Sean only | Whole host behind Cloudflare Access (his email), exactly like `supabase.seanpe.io` |
| `dashboards.seanpe.io` | anyone | Only Grafana's **shared (public) dashboard** paths pass; everything else 404 |

Done looks like: Sean logs in at `grafana.seanpe.io` from his phone through Access; a dashboard he
marked as shared opens in a private browser window at `dashboards.seanpe.io/public-dashboards/<token>`
with every panel rendering; `dashboards.seanpe.io/`, `/login` and `/api/` (other than the public
dashboard API) return 404; the datasource role cannot read anything outside the tables the
dashboards use. Then stop.

## Decided (don't re-open)

- **One Grafana instance, two hostnames.** Not two instances, not one hostname with path-scoped
  Access rules. Sean chose the names on 2026-11-04 so the private and public hosts never share an
  autofill prefix. The singular `dashboard.seanpe.io` is not registered.
- **Shared dashboards, not anonymous auth.** `auth.anonymous` exposes the datasource query API to
  the internet with the datasource's credentials. Shared dashboards pin queries to panels. Enable
  the public/shared dashboards feature; leave anonymous access off.
- **The public allowlist lives in cloudflared, in Git.** There is no ingress controller here. Use
  the same pattern already in `cloudflared-configmap.yaml` for `db.seanpe.io`: a `path:` regex
  rule for `dashboards.seanpe.io` that passes the shared-dashboard page path, the public dashboard
  API path, and Grafana's static asset path, followed by a catch-all `http_status:404` for that
  hostname. Allowlist, not denylist. Verify the exact paths against the Grafana version you deploy
  and against a private-window test; a panel that spins forever is a path the rule isn't passing.
- **Read-only Postgres role.** Grafana connects as a new role with `SELECT` on only the tables the
  dashboards need, nothing else, no matter what is public. Create it through the psql debug pod or
  the tailnet-only MCP endpoint, never through a public hostname. Its password is a `*.sops.yaml`
  secret like every other secret here.
- **Deployed through Flux**, as a HelmRelease from the Grafana chart under `apps/`, pinned in the
  production overlay like the other apps. A small `local-path` PVC for Grafana's own state; check
  `df -h /` in the VM first (the trap list above). Provision the datasource and the first dashboards
  as code where the chart allows it, so a rebuild of the cluster brings them back.
- **Time-box: one evening.** The job hunt is Sean's live priority and this is tooling that earns its
  place only as a line on a résumé he is submitting this week. If it is not serving a public
  dashboard after one working evening, write down where it is stuck and stop; the Admiral decides
  whether it continues.

## Open, and whose call

- **What the first public dashboard shows** — Sean's. Only data already in Supabase qualifies
  (the `seanpe_api` schema, the quotes `sync-quotes.py` writes). The F1 live-timing capture Sean
  mentioned lives as log files on rocinante, not in Postgres; importing it is a separate job for a
  different captain and is not in this brief. Build the plumbing first with one trivial panel over
  an existing table, then put the content question to the Admiral.
- **`root_url`.** Grafana generates shared-dashboard links from `root_url`. If that is the private
  host, the links Grafana shows Sean point at a host Access blocks for strangers, and he hands out
  the `dashboards.` form by hand instead. If it is the public host, check that login on the private
  host still completes. Pick whichever works in the private-window test and record the choice.
- **The root of `dashboards.seanpe.io`.** Grafana has no public index of shared dashboards. It
  returns 404 for now. A one-page static index belongs with `seanpe-com` later, not in this brief.

## Sean's own steps (cannot be relayed)

- The **Cloudflare Access application** for `grafana.seanpe.io` is created in the Zero Trust
  dashboard, as it was for `supabase.seanpe.io`. Tell him when the hostname is ready for it and
  do not route the DNS record for `grafana.seanpe.io` before Access is in front of it — the
  Supabase rollout learned that one.
- **Pushes.** Flux deploys only what is on `origin/master`, so every step here is a push, and the
  repo is public. Get Sean's word in this pane once, for pushes to `master` for this work, and
  read `git diff` for secrets before each one. The branch is already one commit ahead of origin
  (`df6f658`, seanpe-api poker routes), which goes out with the first push.
- DNS records: `cloudflared tunnel --config /dev/null route dns c61d839a-8683-4b67-8b4b-b120dfa434bc <hostname>`
  from rocinante works without him (see the trap list). Remember cloudflared doesn't reload its
  ConfigMap: `kubectl -n networking rollout restart deploy` after the rules change.

## Vault rules that apply here

- Decisions Sean settles go in `~/Documents/PepeVault/02-Projects/Donnager.md` under
  `## Architecture decisions` (add the heading if it is missing), one dated bullet each: what was
  chosen, why, what was rejected. Small exact edits, re-read the file first; it syncs over Syncthing.
- Anything transferable (a cloudflared path-allowlist pattern, a Grafana public-dashboard trap)
  goes to `03-Library/Permanent/` as its own note with `id`, `aliases: []`, `tags: []` frontmatter.
- No agentic logs, no checkboxes, no moving notes, no `*.sync-conflict-*` files. Sean writes the
  project note; you edit and link, you don't generate it.
