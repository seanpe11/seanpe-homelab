#!/usr/bin/env python3
"""Sync the vault's Mindset Quotes note into seanpe_api.spa_pkms_quotes.

The vault markdown is the source of truth (decided 2026-09-17); Notion is a
read-only archive. Headings become `category`; a trailing " - Author" becomes
`author`. Rows are keyed by `source_hash` (sha256 of the normalised body), so
re-running updates in place instead of duplicating all 77 quotes.

Editing a quote's *text* changes its hash, which inserts a new row and leaves the
old one behind — `--prune` removes rows whose hash is no longer in the file.
Anything you tag by hand in Studio survives a re-run, because `tags` is never
written after the first insert.

    ops/rocinante/sync-quotes.py --dry-run     # show what would change
    ops/rocinante/sync-quotes.py               # insert/update
    ops/rocinante/sync-quotes.py --prune       # also delete quotes removed from the note
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

NOTE = Path.home() / "Documents/PepeVault/01-Journal/Mindset/Mindset Quotes.md"
NAMESPACE = os.environ.get("NAMESPACE", "supabase")
POD = os.environ.get("POD", "supabase-supabase-db-0")
CONTAINER = os.environ.get("CONTAINER", "supabase-db")
DB_USER = os.environ.get("DB_USER", "supabase_admin")
DATABASE = os.environ.get("DATABASE", "postgres")
TABLE = "seanpe_api.spa_pkms_quotes"
SOURCE = "Mindset Quotes (vault)"

ATTRIB = re.compile(r"[\s\"”]*[-–—]\s*([A-Z][^,\n]{1,60}?)\s*$")
EMPHASIS = re.compile(r"\*{1,2}|_{1,2}|`")


def psql(sql: str) -> str:
    """Run SQL in the cluster's Postgres. Uses kubectl exec so nothing listens on a port."""
    proc = subprocess.run(
        ["kubectl", "-n", NAMESPACE, "exec", "-i", POD, "-c", CONTAINER, "--",
         "psql", "-U", DB_USER, "-h", "localhost", "-d", DATABASE, "-tA", "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"psql failed:\n{proc.stderr.strip()}")
    return proc.stdout


def normalise(text: str) -> str:
    """Identity of a quote: letters and digits only, so formatting edits don't orphan a row."""
    return re.sub(r"[^a-z0-9 ]", "", re.sub(r"\s+", " ", text.lower())).strip()


def parse(path: Path) -> list[dict]:
    category, chunks, buf = None, [], []

    def flush() -> None:
        nonlocal buf
        if buf:
            raw = " ".join(x.strip() for x in buf).strip()
            if len(raw) > 7:
                chunks.append((category, raw))
        buf = []

    in_frontmatter = False
    for i, raw_line in enumerate(path.read_text(errors="replace").splitlines()):
        line = raw_line.rstrip()
        if i == 0 and line.strip() == "---":
            in_frontmatter = True
            continue
        if in_frontmatter:
            if line.strip() == "---":
                in_frontmatter = False
            continue
        if line.startswith("#"):
            flush()
            category = re.sub(r"^#+\s*", "", line).replace("*", "").strip()
            continue
        if not line.strip():
            flush()
            continue
        buf.append(re.sub(r"^>\s?", "", line))
    flush()

    out = []
    for category, raw in chunks:
        m = ATTRIB.search(raw)
        author = m.group(1).strip() if m else "Unknown"
        body = ATTRIB.sub("", raw).strip() if m else raw
        plain = EMPHASIS.sub("", body).strip().strip('"“”')
        if not plain:
            continue
        out.append({
            "quote": plain,
            "markdown_formatted": body,
            "author": author,
            "source": SOURCE,
            "category": category,
            "source_hash": hashlib.sha256(normalise(plain).encode()).hexdigest(),
        })
    # a note can repeat a line; keep the first occurrence so the hash stays unique
    seen, unique = set(), []
    for q in out:
        if q["source_hash"] in seen:
            continue
        seen.add(q["source_hash"])
        unique.append(q)
    return unique


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="report changes without writing")
    ap.add_argument("--prune", action="store_true", help="delete rows whose hash is gone from the note")
    ap.add_argument("--note", type=Path, default=NOTE)
    args = ap.parse_args()

    if not args.note.exists():
        sys.exit(f"note not found: {args.note}")
    quotes = parse(args.note)
    if not quotes:
        sys.exit("parsed 0 quotes — refusing to touch the table")

    existing = {}
    for row in psql(f"select source_hash, quote from {TABLE} where source_hash is not null;").splitlines():
        if "|" in row:
            h, q = row.split("|", 1)
            existing[h] = q
    new = [q for q in quotes if q["source_hash"] not in existing]
    same = [q for q in quotes if q["source_hash"] in existing]
    gone = [h for h in existing if h not in {q["source_hash"] for q in quotes}]

    print(f"note:     {args.note}")
    print(f"parsed:   {len(quotes)} quotes")
    print(f"  new:    {len(new)}")
    print(f"  known:  {len(same)} (re-synced in place)")
    print(f"  orphan: {len(gone)} rows in the table with no matching quote"
          f"{' — will be deleted' if args.prune else ' — left alone (use --prune)'}")
    for q in new[:10]:
        print(f"    + [{q['category']}] {q['quote'][:70]}")

    if args.dry_run:
        print("\ndry run: nothing written")
        return

    payload = json.dumps(quotes).replace("'", "''")
    sql = f"""
insert into {TABLE} (quote, markdown_formatted, author, source, category, source_hash)
select x.quote, x.markdown_formatted, x.author, x.source, x.category, x.source_hash
from jsonb_to_recordset('{payload}'::jsonb)
  as x(quote text, markdown_formatted text, author text, source text, category text, source_hash text)
on conflict (source_hash) do update set
  quote = excluded.quote,
  markdown_formatted = excluded.markdown_formatted,
  author = excluded.author,
  source = excluded.source,
  category = excluded.category;
"""
    if args.prune and gone:
        hashes = ",".join(f"'{h}'" for h in gone)
        sql += f"delete from {TABLE} where source_hash in ({hashes});\n"
    sql += f"select 'total: '||count(*) from {TABLE};"
    print()
    print(psql(sql).strip())


if __name__ == "__main__":
    main()
