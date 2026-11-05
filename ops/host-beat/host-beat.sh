#!/usr/bin/env bash
# host-beat: one heartbeat per run → PostgREST RPC public.host_beat → gf.host_samples.
# Needs bash, curl and /proc (Linux). Config: HOST_BEAT_{NAME,URL,APIKEY,TOKEN} from the env file
# the systemd unit loads (mode 600, never in git; see README). Exit non-zero on failure so
# `systemctl --user status host-beat` shows it, but a failed beat is otherwise harmless.
set -euo pipefail
VERSION=2
: "${HOST_BEAT_NAME:?}" "${HOST_BEAT_URL:?}" "${HOST_BEAT_APIKEY:?}" "${HOST_BEAT_TOKEN:?}"

btime=$(awk '/^btime/ {print $2}' /proc/stat)             # boot time, epoch s: stable until reboot
uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)
load1=$(awk '{print $1}' /proc/loadavg)
mem_used_pct=$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%.1f", (t-a)*100/t}' /proc/meminfo)
disk_root_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
boot_iso=$(date -u -d "@$btime" +%Y-%m-%dT%H:%M:%SZ)
mem_total_b=$(awk '/^MemTotal/ {printf "%d", $2 * 1024}' /proc/meminfo)

# Hardware line (v2). Only model names and utilisation leave the host: no kernel, OS, serials,
# PCI addresses or paths. Everything below fails soft to null; a host with no GPU still beats.
cpu_model=$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo)
[ -n "$cpu_model" ] || cpu_model=$(LC_ALL=C lscpu 2>/dev/null | awk -F': *' '/^Model name/ {print $2; exit}') || true
cpu_ticks() { awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat; }   # total, idle+iowait
read -r t0 i0 < <(cpu_ticks); sleep 1; read -r t1 i1 < <(cpu_ticks)
cpu_pct=$(awk -v dt=$((t1 - t0)) -v di=$((i1 - i0)) 'BEGIN {if (dt > 0) printf "%.1f", (dt - di) * 100 / dt; else print "null"}')

# "GA104M [GeForce RTX 3080 Mobile / Max-Q 8GB/16GB]" → "GeForce RTX 3080 Mobile"
pci_name() { { lspci -mm -s "$1" 2>/dev/null || true; } | awk -F'" "' '{d=$3; sub(/".*/, "", d); if (match(d, /\[[^]]*\]/)) d=substr(d, RSTART+1, RLENGTH-2); sub(/ \/.*/, "", d); print d}'; }
gpu_model= gpu_pct=null
if out=$(timeout 5 nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1) && [ -n "$out" ]; then
  gpu_model=${out%%,*}; gpu_pct=${out##*, }
else
  for b in /sys/class/drm/card[0-9]/device/gpu_busy_percent; do       # amdgpu exposes utilisation in sysfs
    [ -r "$b" ] || continue
    gpu_model=$(pci_name "$(basename "$(readlink -f "${b%/gpu_busy_percent}")")"); gpu_pct=$(cat "$b"); break
  done
  if [ -z "$gpu_model" ]; then                                          # name only, utilisation unknown
    addr=$(lspci -mm 2>/dev/null | awk '/"(VGA compatible|3D) controller"/ {print $1; exit}') || true
    [ -n "$addr" ] && gpu_model=$(pci_name "$addr")
  fi
fi
[[ $gpu_pct =~ ^[0-9]+(\.[0-9]+)?$ ]] || gpu_pct=null
jstr() { [ -n "$1" ] && printf '"%s"' "$(printf '%s' "$1" | tr -d '"\\' | cut -c1-64)" || printf null; }

body=$(printf '{"p_host":"%s","p_boot_time":"%s","p_uptime_s":%s,"p_load1":%s,"p_mem_used_pct":%s,"p_disk_root_pct":%s,"p_agent_version":"host-beat/%s","p_cpu_model":%s,"p_cpu_pct":%s,"p_gpu_model":%s,"p_gpu_pct":%s,"p_mem_total_bytes":%s}' \
  "$HOST_BEAT_NAME" "$boot_iso" "$uptime_s" "$load1" "$mem_used_pct" "$disk_root_pct" "$VERSION" \
  "$(jstr "$cpu_model")" "$cpu_pct" "$(jstr "$gpu_model")" "$gpu_pct" "$mem_total_b")

resp=$(curl -sS -w '\n%{http_code}' --max-time 20 -X POST "$HOST_BEAT_URL" \
  -H "apikey: $HOST_BEAT_APIKEY" -H "Authorization: Bearer $HOST_BEAT_TOKEN" \
  -H 'Content-Type: application/json' --data "$body")
code=${resp##*$'\n'}
[ "$code" = 204 ] || [ "$code" = 200 ] || { echo "host-beat: HTTP $code ${resp%$'\n'*}" >&2; exit 1; }
