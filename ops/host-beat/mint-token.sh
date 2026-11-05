#!/usr/bin/env bash
# Mint a host_beat env file for one host. Prints NOTHING secret; writes the file mode 600.
#   ops/host-beat/mint-token.sh <host> <output-env-file>
# Needs KUBECONFIG for the seanpe-homelab cluster. The token expires in 1 year: the host's tile
# goes red when it does, which is the reminder to re-mint.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/seanpe-homelab.yaml}   # the default context is not this cluster
host=${1:?host}; out=${2:?output file}
jwt_secret=$(kubectl -n supabase get secret sb-jwt -o jsonpath='{.data.secret}' | base64 -d)
anon=$(kubectl -n supabase get secret sb-jwt -o jsonpath='{.data.anonKey}' | base64 -d)
token=$(JWT_SECRET="$jwt_secret" HOST_NAME="$host" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b64(json.dumps({"role": "host_beat", "host": os.environ["HOST_NAME"], "iss": "seanpe-homelab",
                       "iat": now, "exp": now + 365 * 86400}).encode())
sig = b64(hmac.new(os.environ["JWT_SECRET"].encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
print(f"{head}.{body}.{sig}")
PY
)
umask 077; mkdir -p "$(dirname "$out")"
cat > "$out" <<ENV
HOST_BEAT_NAME=$host
HOST_BEAT_URL=https://db.seanpe.io/rest/v1/rpc/host_beat
HOST_BEAT_APIKEY=$anon
HOST_BEAT_TOKEN=$token
ENV
chmod 600 "$out"; echo "wrote $out (mode $(stat -c %a "$out")) for host=$host"
