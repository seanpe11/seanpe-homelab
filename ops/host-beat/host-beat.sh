#!/usr/bin/env bash
# host-beat: one heartbeat per run → PostgREST RPC public.host_beat → gf.host_samples.
# Needs bash, curl and /proc (Linux). Config: HOST_BEAT_{NAME,URL,APIKEY,TOKEN} from the env file
# the systemd unit loads (mode 600, never in git; see README). Exit non-zero on failure so
# `systemctl --user status host-beat` shows it, but a failed beat is otherwise harmless.
set -euo pipefail
VERSION=1
: "${HOST_BEAT_NAME:?}" "${HOST_BEAT_URL:?}" "${HOST_BEAT_APIKEY:?}" "${HOST_BEAT_TOKEN:?}"

btime=$(awk '/^btime/ {print $2}' /proc/stat)             # boot time, epoch s: stable until reboot
uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)
load1=$(awk '{print $1}' /proc/loadavg)
mem_used_pct=$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%.1f", (t-a)*100/t}' /proc/meminfo)
disk_root_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
boot_iso=$(date -u -d "@$btime" +%Y-%m-%dT%H:%M:%SZ)

body=$(printf '{"p_host":"%s","p_boot_time":"%s","p_uptime_s":%s,"p_load1":%s,"p_mem_used_pct":%s,"p_disk_root_pct":%s,"p_agent_version":"host-beat/%s"}' \
  "$HOST_BEAT_NAME" "$boot_iso" "$uptime_s" "$load1" "$mem_used_pct" "$disk_root_pct" "$VERSION")

resp=$(curl -sS -w '\n%{http_code}' --max-time 20 -X POST "$HOST_BEAT_URL" \
  -H "apikey: $HOST_BEAT_APIKEY" -H "Authorization: Bearer $HOST_BEAT_TOKEN" \
  -H 'Content-Type: application/json' --data "$body")
code=${resp##*$'\n'}
[ "$code" = 204 ] || [ "$code" = 200 ] || { echo "host-beat: HTTP $code ${resp%$'\n'*}" >&2; exit 1; }
