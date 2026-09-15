#!/usr/bin/env python3
"""Generate the seanpe-homelab app secrets and SOPS-encrypt them with the recipient in .sops.yaml.

Writes:
  infrastructure/base/supabase/secrets.sops.yaml  Supabase JWT/API keys, DB, dashboard, realtime, meta, S3,
                                                  and the seanpe_api role password (read by the first-boot migration)
  apps/base/seanpe-api/secret.sops.yaml           DATABASE_URL + API_KEY for seanpe-api

Refuses to overwrite: Supabase bakes the DB password and JWT secret into the database on first
boot, so regenerating them afterwards locks the services out of their own database.

  scripts/gen-secrets.py                                   # encrypt in place in the repo
  scripts/gen-secrets.py --no-encrypt --out-dir /tmp/x     # plaintext, for inspection only
"""
import argparse
import base64
import hashlib
import hmac
import json
import secrets
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUPABASE_NS = "supabase"
DB_HOST = f"supabase-supabase-db.{SUPABASE_NS}.svc.cluster.local"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def jwt_hs256(payload: dict, key: str) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(key.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{b64url(sig)}"


def secret(name: str, namespace: str, data: dict) -> str:
    lines = ["apiVersion: v1", "kind: Secret", "metadata:", f"  name: {name}", f"  namespace: {namespace}",
             "type: Opaque", "stringData:"]
    lines += [f"  {k}: {json.dumps(v)}" for k, v in data.items()]  # JSON strings are valid YAML scalars
    return "\n".join(lines)


def generate() -> dict[str, str]:
    now = int(time.time())
    ten_years = now + 10 * 365 * 24 * 3600
    jwt_secret = secrets.token_urlsafe(48)
    db_password = secrets.token_hex(24)          # hex: safe unescaped in a connection URL
    api_db_password = secrets.token_hex(24)

    supabase = [
        secret("sb-jwt", SUPABASE_NS, {
            "secret": jwt_secret,
            "anonKey": jwt_hs256({"role": "anon", "iss": "supabase", "iat": now, "exp": ten_years}, jwt_secret),
            "serviceKey": jwt_hs256({"role": "service_role", "iss": "supabase", "iat": now, "exp": ten_years}, jwt_secret),
        }),
        secret("sb-db", SUPABASE_NS, {"password": db_password, "password_encoded": db_password, "database": "postgres"}),
        secret("sb-dashboard", SUPABASE_NS, {"username": "sean", "password": secrets.token_urlsafe(24), "openAiApiKey": ""}),
        secret("sb-realtime", SUPABASE_NS, {"secretKeyBase": base64.b64encode(secrets.token_bytes(64)).decode(),
                                            "dbEncKey": secrets.token_hex(8)}),   # exactly 16 chars
        secret("sb-meta", SUPABASE_NS, {"cryptoKey": secrets.token_hex(32)}),
        secret("sb-s3", SUPABASE_NS, {"keyId": secrets.token_hex(16), "accessKey": secrets.token_hex(32)}),
        secret("seanpe-api-db-password", SUPABASE_NS, {"SEANPE_API_DB_PASSWORD": api_db_password}),
    ]
    seanpe_api = [
        secret("seanpe-api", "apps", {
            "DATABASE_URL": f"postgres://seanpe_api:{api_db_password}@{DB_HOST}:5432/postgres?sslmode=disable",
            "API_KEY": secrets.token_urlsafe(32),
        }),
    ]
    return {
        "infrastructure/base/supabase/secrets.sops.yaml": "\n---\n".join(supabase) + "\n",
        "apps/base/seanpe-api/secret.sops.yaml": "\n---\n".join(seanpe_api) + "\n",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-encrypt", action="store_true", help="write plaintext (requires --out-dir)")
    parser.add_argument("--out-dir", type=Path, help="write under this directory instead of the repo")
    args = parser.parse_args()
    if args.no_encrypt and not args.out_dir:
        parser.error("--no-encrypt needs --out-dir, so plaintext never lands in the repo")
    if not args.no_encrypt and not (REPO / ".sops.yaml").exists():
        sys.exit(".sops.yaml not found — it names the age recipient these secrets are encrypted to")

    root = args.out_dir or REPO
    files = generate()
    existing = [p for p in files if (root / p).exists()]
    if existing:
        sys.exit("refusing to overwrite (the database already holds these):\n  " + "\n  ".join(existing))

    for rel, content in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if args.no_encrypt:
            path.write_text(content)
        else:
            # Encrypt from stdin so plaintext never touches the repo; --filename-override matches .sops.yaml.
            enc = subprocess.run(["sops", "--encrypt", "--filename-override", rel, "/dev/stdin"],
                                 input=content, cwd=REPO, check=True, capture_output=True, text=True).stdout
            path.write_text(enc)
        path.chmod(0o600)
        print(f"wrote {path}")

    print("\nStudio login: user 'sean'; password is in the sb-dashboard document:\n"
          "  sops -d infrastructure/base/supabase/secrets.sops.yaml | grep -A4 'name: sb-dashboard'")


if __name__ == "__main__":
    main()
