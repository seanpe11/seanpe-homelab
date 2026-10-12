#!/usr/bin/env bash
# Add books to BookOrbit's library from rocinante.
#
#   scripts/books-add.sh ~/Downloads/*.epub
#   scripts/books-add.sh https://www.gutenberg.org/ebooks/2701.epub3.images
#   scripts/books-add.sh --gutenberg 84 1342 2701
#
# Everything is fetched completely into a local temp dir first, streamed into a hidden folder on
# the library volume as BookOrbit's user (1000), then renamed into /books in one step, so the
# library's folder watcher only ever sees finished files (it skips dot-folders). Needs
# "Watch folders" on for the /books library; otherwise run a Scan in Settings > Libraries.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/seanpe-homelab.yaml}"
target=(-n apps deploy/bookorbit)

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
tar -C "$stage" -cf - . | kubectl exec -i "${target[@]}" -- su-exec 1000:1000 sh -c '
  set -e
  tmp=$(mktemp -d /books/.incoming.XXXXXX)
  tar -xf - -C "$tmp"
  for f in "$tmp"/*; do
    dest="/books/${f##*/}"
    if [ -e "$dest" ]; then echo "exists, skipped: ${f##*/}" >&2; else mv "$f" "$dest"; fi
  done
  rm -rf "$tmp"'
echo "sent $n file(s) to /books. Watch: kubectl -n apps logs deploy/bookorbit -f"
