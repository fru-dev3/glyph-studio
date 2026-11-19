#!/bin/zsh
# The one personal-data scan every public release passes.
# Usage: public-scan.sh <.app | .dmg | folder>     (a .dmg is mounted read-only and unmounted after)
#        public-scan.sh --self-test
# Fails (exit 1) and names each offending file with the class of string and a masked form of it, when any
# file inside holds: this Mac's user name as a path (/Users/<name>, -Users-<name>-), the home folder, the
# vault folder's name, a Claude scratch path, this Mac's computer and host names, the tailnet and the vault
# host from ~/.config/glyph/env, or a gmail address. Every Mach-O is read with `strings -a`, every other
# file as raw bytes (in a git clone: the files a commit could carry). The one exception: the code signature's certificate name ("Developer ID Application").
# The patterns are read from this machine when it runs; this file holds nothing personal.
setopt null_glob
if [[ ${1:-} == --self-test ]]; then
  self=${0:A}; t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir "$t/bad" "$t/good"
  print -r -- "path: /Users/$USER/x" > "$t/bad/a.txt"; print -r -- "nothing here" > "$t/good/a.txt"
  if "$self" "$t/bad" >/dev/null 2>&1; then echo "self-test FAILED: planted name not found"; exit 1; fi
  "$self" "$t/good" >/dev/null 2>&1 || { echo "self-test FAILED: clean folder rejected"; exit 1; }
  echo "self-test ok: planted name fails, clean folder passes"; exit 0
fi
target=${1:?usage: public-scan.sh <.app|.dmg|folder> | --self-test}
[[ -e $target ]] || { echo "no such path: $target"; exit 2; }

typeset -A cls   # lowercased pattern -> class
add() { local c=$1 p=${2:l}; (( ${#p} >= 4 )) && [[ -z ${cls[$p]:-} ]] && cls[$p]=$c; return 0 }
u=${USER:-$(id -un)}
add "user-name path" "/Users/$u"; add "user-name path" "-Users-$u-"; add "home folder" "$HOME"
cfg=~/.prevail/config.json
if [[ -f $cfg ]]; then
  vp=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("vaultPath",""))' "$cfg" 2>/dev/null)
  [[ -n $vp ]] && add "vault folder name" "${vp:t}"
fi
add "scratch path" "/private/tmp/""claude-"   # split so this file does not match itself
add "computer name" "$(scutil --get ComputerName 2>/dev/null)"
add "host name" "$(scutil --get LocalHostName 2>/dev/null)"
add "host name" "$(hostname -s 2>/dev/null)"
env=~/.config/glyph/env
if [[ -f $env ]]; then
  tn=$(awk -F= '/^GLYPH_TAILNET=/{gsub(/["'"'"' ]/,"",$2); print $2}' "$env")
  vh=$(awk -F= '/^GLYPH_VAULT_URL=/{sub(/^[^=]*=/,""); gsub(/["'"'"' ]/,""); sub(/^[a-z]+:\/\//,""); sub(/[\/:].*/,""); print}' "$env")
  add "tailnet" "$tn"; add "vault host" "$vh"
fi
add "email address" "@gm""ail.com"

pats=$(mktemp); for p in ${(k)cls}; do print -r -- "$p" >> $pats; done
mnt=""; root=$target
cleanup() { [[ -n $mnt ]] && hdiutil detach "$mnt" -quiet -force >/dev/null 2>&1; rm -f $pats; [[ -n $mnt ]] && rmdir "$mnt" 2>/dev/null; return 0 }
trap cleanup EXIT
if [[ $target == *.dmg ]]; then
  mnt=$(mktemp -d)
  hdiutil attach "$target" -readonly -nobrowse -noverify -mountpoint "$mnt" -quiet >/dev/null || { echo "could not mount $target"; exit 2; }
  root=$mnt
fi

mask() { local s=$1; print -r -- "${s[1,2]}$(printf '*%.0s' {1..6}) (${#s} chars)" }
fail=0; n=0
prune=()
[[ -d $root && $root != *.app && $root != $mnt ]] && prune=( \( -name .git -o -name .build -o -name .swiftpm -o -name dist -o -name build \) -prune -o )
while IFS= read -r -d '' f; do
  n=$((n+1))
  if [[ $(file -b "$f") == *Mach-O* ]]; then
    # the code signature's certificate name is the one allowed place
    hits=$(strings -a "$f" | grep -v 'Developer ID Application' | grep -aoiF -f $pats)
  else
    hits=$(grep -aoiF -f $pats "$f" 2>/dev/null)
  fi
  [[ -z $hits ]] && continue
  fail=1; echo "PERSONAL DETAIL in ${f#$root/}:"
  for h in ${(u)${(f)hits}}; do echo "    ${cls[${h:l}]:-?}: $(mask $h)"; done
done < <(if [[ -d $root/.git ]]; then (cd "$root" && git ls-files -z -co --exclude-standard | while IFS= read -r -d '' x; do [[ -f $x ]] && printf '%s\0' "$root/$x"; done)  # a mirror: what a commit could carry
         else find "$root" "${prune[@]}" -type f -print0; fi)
echo "public-scan: $n files, ${#cls} patterns from this machine"
(( fail )) && { echo "public-scan FAILED"; exit 1; }
echo "public-scan passed"
