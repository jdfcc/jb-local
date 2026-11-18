#!/usr/bin/env bash
#
# jb-local - self-hosted Linux / macOS installer
#
# Downloads a pinned release from YOUR GitHub repo, verifies its SHA256,
# installs the JVM agent, generates a local identity + power.conf on this
# machine, patches JetBrains vmoptions and writes <product>.key files.
#
#   curl -fsSL -o install.sh https://github.com/<you>/<repo>/releases/download/<tag>/install.sh
#   sha256sum install.sh          # compare with the value in the release notes
#   sudo bash install.sh --repo <you>/<repo> --tag <tag>
#
#   sudo bash install.sh --uninstall
#
set -euo pipefail

REPO_DEFAULT="jdfcc/jb-local"
TAG_DEFAULT="v1.0.0"
REPO="$REPO_DEFAULT"
TAG="$TAG_DEFAULT"
LICENSE_NAME="local"
EXPIRY="2099-12-31"
SKIP_HIDING=0
NO_VMOPTIONS=0
UNINSTALL=0
DRY_RUN=0
FROM_DIR=""
CFG_OVERRIDE=""
LOCAL_PREFIX_OVERRIDE=""

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  CFG_ROOT="$HOME/Library/Application Support/JetBrains"
  DEFAULT_PREFIX="/usr/local/share/jb-local"
else
  CFG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/JetBrains"
  DEFAULT_PREFIX="/usr/local/share/jb-local"
fi
if [ "$(id -u)" -ne 0 ]; then
  DEFAULT_PREFIX="$HOME/.local/share/jb-local"
fi
INSTALL_DIR="$DEFAULT_PREFIX"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --name) LICENSE_NAME="$2"; shift 2 ;;
    --expiry) EXPIRY="$2"; shift 2 ;;
    --skip-hiding) SKIP_HIDING=1; shift ;;
    --no-vmoptions) NO_VMOPTIONS=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --from-dir) FROM_DIR="$2"; shift 2 ;;
    --config-root) CFG_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$CFG_OVERRIDE" ]; then CFG_ROOT="$CFG_OVERRIDE"; fi

say()  { printf '[jb-local] %s\n' "$*"; }
step() { printf '[jb-local] == %s\n' "$*"; }
die()  { printf '[jb-local] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

products_map() {
  case "$1" in
    idea) echo "II,PCWMP,PSI" ;;
    clion) echo "CL,PSI,PCWMP" ;;
    phpstorm) echo "PS,PCWMP,PSI" ;;
    goland) echo "GO,PSI,PCWMP" ;;
    pycharm) echo "PC,PSI,PCWMP" ;;
    webstorm) echo "WS,PCWMP,PSI" ;;
    rider) echo "RD,PDB,PSI,PCWMP" ;;
    datagrip) echo "DB,PSI,PDB" ;;
    rubymine) echo "RM,PCWMP,PSI" ;;
    appcode) echo "AC,PCWMP,PSI" ;;
    dataspell) echo "DS,PSI,PDB,PCWMP" ;;
    rustrover) echo "RR,PSI,PCWP" ;;
    *) echo "" ;;
  esac
}

ALL_KEYS="idea clion phpstorm goland pycharm webstorm rider datagrip rubymine appcode dataspell rustrover"

match_key() {
  local name lower
  name="$1"; lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  for k in $ALL_KEYS; do
    case "$lower" in *"$k"*) echo "$k"; return 0 ;; esac
  done
  echo ""
}

find_java_for_home() {
  local home="$1"
  for c in "$home/jbr/bin/java" "$home/jbr/Contents/Home/bin/java" "$home/jre64/bin/java"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

if [ "$UNINSTALL" -eq 1 ]; then
  step uninstall
  if [ -d "$CFG_ROOT" ]; then
    for d in "$CFG_ROOT"/*; do
      [ -d "$d" ] || continue
      k="$(match_key "$(basename "$d")")"
      [ -n "$k" ] || continue
      [ -f "$d/$k.key" ] && { [ "$DRY_RUN" -eq 1 ] || rm -f "$d/$k.key"; say "removed $d/$k.key"; }
      for f in "$d"/*.vmoptions; do
        [ -f "$f" ] || continue
        if [ -f "$f.bak-jblocal" ]; then
          [ "$DRY_RUN" -eq 1 ] || mv -f "$f.bak-jblocal" "$f"
          say "restored $f"
        else
          if [ "$DRY_RUN" -eq 0 ]; then
            grep -v '^[[:space:]]*-javaagent:.*\.jar' "$f" > "$f.tmp" || true
            mv -f "$f.tmp" "$f"
          fi
          say "cleaned $f"
        fi
      done
    done
  fi
  [ -d "$INSTALL_DIR" ] && { [ "$DRY_RUN" -eq 1 ] || rm -rf "$INSTALL_DIR"; say "removed $INSTALL_DIR"; }
  say done
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step release
if [ -n "$FROM_DIR" ]; then
  [ -f "$FROM_DIR/payload.zip" ] || die "no payload.zip in $FROM_DIR"
  [ -f "$FROM_DIR/SHA256SUMS.txt" ] || die "no SHA256SUMS.txt in $FROM_DIR"
  cp -f "$FROM_DIR/payload.zip" "$WORK/payload.zip"
  cp -f "$FROM_DIR/SHA256SUMS.txt" "$WORK/SHA256SUMS.txt"
  say "local payload: $FROM_DIR"
else
  SUMS_URL="https://github.com/$REPO/releases/download/$TAG/SHA256SUMS.txt"
  ZIP_URL="https://github.com/$REPO/releases/download/$TAG/payload.zip"
  say "download $SUMS_URL"
  curl -fsSL -o "$WORK/SHA256SUMS.txt" "$SUMS_URL"
  say "download $ZIP_URL"
  curl -fsSL -o "$WORK/payload.zip" "$ZIP_URL"
fi

EXPECT="$(awk '$2=="payload.zip"{print $1}' "$WORK/SHA256SUMS.txt" | head -n1)"
[ -n "$EXPECT" ] || die "no payload.zip entry in SHA256SUMS.txt"
ACTUAL="$(sha256_of "$WORK/payload.zip")"
[ "$EXPECT" = "$ACTUAL" ] || die "SHA256 mismatch for payload.zip: expected $EXPECT got $ACTUAL"
say "sha256 ok: payload.zip $ACTUAL"

step extract
mkdir -p "$WORK/stage"
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$WORK/payload.zip" -d "$WORK/stage"
else
  python3 - "$WORK/payload.zip" "$WORK/stage" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
fi
[ -f "$WORK/stage/ja-netfilter.jar" ] || die "payload is missing ja-netfilter.jar"
[ -f "$WORK/stage/mint.jar" ] || die "payload is missing mint.jar"

step "install to $INSTALL_DIR"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/plugins" "$INSTALL_DIR/state"
  cp -f "$WORK/stage/ja-netfilter.jar" "$INSTALL_DIR/"
  cp -f "$WORK/stage/mint.jar" "$INSTALL_DIR/"
  cp -f "$WORK/stage"/config/* "$INSTALL_DIR/config/"
  rm -f "$INSTALL_DIR/config/power.conf"
  for p in "$WORK/stage"/plugins/*.jar; do
    b="$(basename "$p")"
    if [ "$SKIP_HIDING" -eq 1 ] && { [ "$b" = "privacy.jar" ] || [ "$b" = "hideme.jar" ]; }; then continue; fi
    cp -f "$p" "$INSTALL_DIR/plugins/"
  done
fi

JAVA=""
if [ -d "$CFG_ROOT" ]; then
  for d in "$CFG_ROOT"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/.home" ]; then
      h="$(tr -d '\r\n' < "$d/.home")"
      if [ -d "$h/bin" ]; then JAVA="$(find_java_for_home "$h" || true)"; fi
      if [ -z "$JAVA" ] && [ -d "$h" ]; then
        for sub in "$h"/*; do
          if [ -d "$sub/bin" ]; then JAVA="$(find_java_for_home "$sub" || true)"; [ -n "$JAVA" ] && break; fi
        done
      fi
    fi
    [ -n "$JAVA" ] && break
  done
fi
if [ -z "$JAVA" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then JAVA="$JAVA_HOME/bin/java"; fi
if [ -z "$JAVA" ] && command -v java >/dev/null 2>&1; then JAVA="$(command -v java)"; fi
if [ -z "$JAVA" ] && [ "$DRY_RUN" -eq 0 ]; then die "no java found: install a JetBrains product (its JBR is used) or set JAVA_HOME"; fi
say "java: $JAVA"

AGENT_LINE="-javaagent:$INSTALL_DIR/ja-netfilter.jar"

patch_vmoptions() {
  local f="$1"
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$f.bak-jblocal" ]; then cp -f "$f" "$f.bak-jblocal"; fi
  if [ "$DRY_RUN" -eq 0 ]; then
    { grep -v '^[[:space:]]*-javaagent:.*\.jar' "$f" || true; echo "$AGENT_LINE"; } > "$f.tmp"
    mv -f "$f.tmp" "$f"
  fi
  say "vmoptions patched: $f"
}

step licenses
COUNT=0
if [ -d "$CFG_ROOT" ]; then
  for d in "$CFG_ROOT"/*; do
    [ -d "$d" ] || continue
    k="$(match_key "$(basename "$d")")"
    [ -n "$k" ] || continue
    codes="$(products_map "$k")"
    out="$d/$k.key"
    args=( -cp "$INSTALL_DIR/mint.jar" Mint
           --dir "$INSTALL_DIR/state"
           --power-conf "$INSTALL_DIR/config/power.conf"
           --ca-modulus-file "$INSTALL_DIR/config/ca-modulus.txt"
           --license-out "$out"
           --license-name "$LICENSE_NAME" --assignee "" --expiry "$EXPIRY"
           --product-codes "$codes" --subject "$(basename "$d") helper" )
    if [ "$DRY_RUN" -eq 1 ]; then
      say "dry-run: $JAVA ${args[*]}"
    else
      "$JAVA" "${args[@]}"
    fi
    say "key written: $out"
    COUNT=$((COUNT+1))

    if [ "$NO_VMOPTIONS" -eq 0 ]; then
      if [ -f "$d/.home" ]; then
        h="$(tr -d '\r\n' < "$d/.home")"
        for f in "$h"/bin/*.vmoptions; do patch_vmoptions "$f"; done
      fi
      for f in "$d"/*.vmoptions; do patch_vmoptions "$f"; done
    fi
  done
fi

step done
say "installed: $INSTALL_DIR"
say "keys: $COUNT"
if [ -f "$0" ]; then say "installer sha256: $(sha256_of "$0")"; fi
say "start the IDE and check Help > Register"
