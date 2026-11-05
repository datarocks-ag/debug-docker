#!/usr/bin/env bash
# Smoke test: every advertised tool is on PATH and the helpers run.
# Usage: test/smoke.sh [image]   (default: netdebug:latest)
set -euo pipefail

image=${1:-netdebug:latest}

docker run --rm -i "$image" bash -s <<'EOF'
set -euo pipefail
tools=(
  openssl testssl.sh sslscan gnutls-cli curl wget http grpcurl websocat
  ip ss ping arping tracepath traceroute tcptraceroute mtr nc ncat socat nmap
  tcpdump iperf3 ethtool conntrack iptables nft ipcalc whois
  dig nslookup host kdig drill
  telnet ssh sshpass rsync lftp ftp smbclient
  neomutt swaks mailcheck checkssl
  jq yq xq tomlq python3
  zip unzip xz bzip2 zstd lz4 lzop brotli pigz 7z cpio
  psql mariadb mysql sqlite3 sqlcmd redis-cli kcat ldapsearch
  s3fs sshfs rclone mount.nfs mount.cifs fusermount3
  kubectl vim tmux htop lsof strace iostat ncdu git
)
case ${NETDEBUG_VARIANT:-} in
  full) tools+=(tshark) ;;
  slim) ! command -v tshark >/dev/null || { echo "slim image contains tshark" >&2; exit 1; } ;;
  *) echo "NETDEBUG_VARIANT not set in image" >&2; exit 1 ;;
esac
missing=()
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if (( ${#missing[@]} )); then
  echo "missing tools: ${missing[*]}" >&2
  exit 1
fi

[[ $(echo '<a><b>1</b></a>' | xq -r .a.b) == 1 ]]
[[ $(echo 'a: {b: 2}' | yq .a.b) == 2 ]]
python3 -c 'import requests, yaml'
mailcheck --help >/dev/null
{ checkssl --help || true; } | grep -q Usage || { echo "checkssl --help broken" >&2; exit 1; }
echo "smoke test passed: $NETDEBUG_VARIANT variant, ${#tools[@]} tools"
EOF
