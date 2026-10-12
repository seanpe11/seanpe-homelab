#!/usr/bin/env bash
# Add books to Calibre-Web Automated's ingest folder from rocinante.
#
#   scripts/books-add.sh ~/Downloads/*.epub
#   scripts/books-add.sh https://www.gutenberg.org/ebooks/2701.epub3.images
#   scripts/books-add.sh --gutenberg 84 1342 2701
#
# Everything is fetched completely into a local temp dir first, then streamed into the pod as
# CWA's own user (abc). CWA warns that downloading straight into the ingest folder causes
# duplicate imports, and that root-owned files there fail to import. It deletes each file once
# imported; results show up in the web UI.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/seanpe-homelab.yaml}"
target=(-n apps deploy/calibre-web-automated)

[[ $# -gt 0 ]] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

fetch() {   # url [filename]
  local name=${2:-$(basename "${1%%\?*}")}
  curl -fsSL --retry 2 -A 'seanpe-homelab books-add' -o "$stage/$name" "$1"
  echo "fetched  $name"
}

gutenberg=false
for arg in "$@"; do
  case $arg in
    --gutenberg) gutenberg=true ;;
    http://*|https://*) fetch "$arg" ;;
    *)
      if $gutenberg; then
        [[ $arg =~ ^[0-9]+$ ]] || { echo "not a Gutenberg id: $arg" >&2; exit 1; }
        fetch "https://www.gutenberg.org/ebooks/$arg.epub3.images" "pg$arg.epub"
      else
        [[ -f $arg ]] || { echo "no such file: $arg" >&2; exit 1; }
        cp -- "$arg" "$stage/"
        echo "staged   $(basename "$arg")"
      fi ;;
  esac
done

n=$(find "$stage" -type f | wc -l)
tar -C "$stage" -cf - . | kubectl exec -i "${target[@]}" -- s6-setuidgid abc tar -xf - -C /cwa-book-ingest
echo "sent $n file(s) to /cwa-book-ingest. Watch: kubectl -n apps logs deploy/calibre-web-automated -f | grep -i ingest"
