# netdebug

Debug toolbox image for networks, TLS, mail, databases and storage in
Kubernetes and Linux PaaS. Based on `debian:trixie-slim`, for amd64 and arm64.

## Variants

| Tag | Target | Contents |
|---|---|---|
| `latest`, `sha-…`, `1.2.3` | `full` | everything |
| `latest-slim`, `sha-…-slim`, `1.2.3-slim` | `slim` | everything except `tshark` (use `tcpdump -w` and open the capture elsewhere) |

## Build

```bash
docker build -t netdebug:latest .                       # full
docker build --target slim -t netdebug:slim .           # slim
docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/datarocks-ag/debug-docker:latest --push .
```

Versions of the upstream binaries (yq, sqlcmd, grpcurl, websocat, kubectl) are `ARG`s in the Dockerfile.

Check that every tool is present:

```bash
test/smoke.sh netdebug:latest
test/smoke.sh netdebug:slim
```

CI ([.github/workflows/image.yml](.github/workflows/image.yml)) runs the smoke test for both variants on every PR.
Pushes to `main` publish `latest`/`latest-slim` and `sha-<sha>`/`sha-<sha>-slim` for amd64 and arm64.
`v*` tags also publish semver tags (`1.2.3`, `1.2.3-slim`, …).

## Run

```bash
# local
docker run --rm -it netdebug bash
docker run --rm -it --privileged netdebug bash          # FUSE / mounts / capture

# ephemeral pod in a namespace
kubectl run netdebug -it --rm --image=ghcr.io/datarocks-ag/debug-docker -- bash

# attach to an existing pod's network + process namespace (no restart)
kubectl debug -it <pod> --image=ghcr.io/datarocks-ag/debug-docker --target=<container> -- bash

# on a node (host network, host fs under /host)
kubectl debug node/<node> -it --image=ghcr.io/datarocks-ag/debug-docker -- bash

# long-lived pods (unprivileged + privileged variants)
kubectl apply -f k8s/netdebug.yaml
```

## Helpers

| Command | Purpose |
|---|---|
| `checkssl host[:port] [-s smtp\|imap\|pop3\|postgres\|…] [-n sni] [-c ca.pem]` | Chain, SANs, expiry/days left, hostname match, protocol/cipher. Exit code 1 on a problem. |
| `checkssl cert.pem\|.der\|.p12` | Same for a local file. |
| `mailcheck imap\|pop3 host -u user [-f INBOX] [-n 20] [--read ID]` | Lists folders and counts, recent headers, or prints one message. Read-only. Takes the password from `$MAIL_PASSWORD` or a prompt. |
| `tools` | Lists the installed tools. |

## Cheat sheet

```bash
# TLS
testssl.sh --fast https://host                     # protocols, ciphers, vulns
openssl s_client -connect host:993 -servername host </dev/null
openssl x509 -in c.der -inform der -out c.pem      # DER -> PEM
openssl pkcs12 -in c.pfx -out c.pem -nodes         # PFX -> PEM (cert + key)
openssl pkcs12 -export -in c.pem -inkey k.pem -out c.pfx
openssl rsa -in k.pem -check -noout                # key sanity
diff <(openssl x509 -in c.pem -noout -pubkey) <(openssl pkey -in k.pem -pubout)  # cert/key match

# Mail
curl -v --url imaps://host/INBOX -u user           # raw IMAP over curl
curl -v --url pop3s://host/ -u user
swaks --to a@b.c --server host --port 587 --tls --auth-user user
neomutt -f imaps://user@host/

# DNS
dig +short svc.ns.svc.cluster.local; dig @1.1.1.1 example.com AAAA +trace
kdig -d @1.1.1.1 +tls example.com                  # DNS over TLS
cat /etc/resolv.conf                               # ndots / search domains

# Connectivity
nc -vz host 5432; ncat --ssl host 443; socat - TCP:host:port
mtr -rwc 20 host; tcptraceroute host 443
curl -sv -o /dev/null -w '%{time_connect} %{time_starttransfer}\n' https://host
grpcurl -plaintext svc:9090 list
websocat wss://host/ws
tcpdump -i any -nn port 53 -w /tmp/dns.pcap        # kubectl cp it out, open in Wireshark
tshark -i any -f 'tcp port 443' -Y tls.handshake

# Databases
psql 'postgresql://user@host:5432/db?sslmode=require'
mariadb -h host -u user -p --ssl
sqlcmd -S host,1433 -U sa -C                       # -C = trust server cert
redis-cli -h host --tls ping
kcat -b broker:9092 -L

# Storage (needs --privileged / privileged pod)
s3fs bucket /mnt -o url=https://s3.endpoint,use_path_request_style,passwd_file=~/.passwd-s3fs
rclone mount remote:bucket /mnt --daemon           # S3, SFTP, FTP, SMB, WebDAV, ...
sshfs user@host:/path /mnt
mount -t nfs4 server:/export /mnt
mount -t cifs //server/share /mnt -o username=user
lftp sftp://user@host; smbclient //server/share -U user
```

## Mount permissions

A FUSE mount needs two things that containers don't get by default:

1. **The `/dev/fuse` device.** It isn't in the container, and the device cgroup blocks access to it.
2. **`CAP_SYS_ADMIN`** to call `mount(2)`. On AppArmor hosts (Ubuntu and similar), the `docker-default`
   profile also blocks mounts.

NFS and CIFS are kernel mounts. They need only `CAP_SYS_ADMIN`, but they don't work in a user namespace.

Docker can grant these narrowly without `--privileged`:

```bash
docker run --rm -it --cap-add SYS_ADMIN --device /dev/fuse \
  --security-opt apparmor=unconfined netdebug bash   # apparmor flag only on AppArmor hosts
```

A Kubernetes pod spec has no field for devices, so `privileged: true` is the practical choice there.
The alternative is a device plugin that exposes `/dev/fuse` as a resource (for example
smarter-device-manager), plus `capabilities.add: [SYS_ADMIN]` and an unconfined AppArmor profile.

If you only need to read or copy data, you don't need a mount at all, and the client tools work
unprivileged: `rclone ls|copy|cat`, `lftp`, `smbclient`, `sftp`.

## Notes

- **`yq` vs `xq`:** `yq` on PATH is mikefarah/yq (`/usr/local/bin`). The jq-wrapper
  variant from Debian stays available as `/usr/bin/yq` and also provides `xq` (XML)
  and `tomlq`. mikefarah's version reads XML too: `yq -p xml`.
- **MSSQL:** `sqlcmd` is Microsoft's Go version (go-sqlcmd). It needs no ODBC driver
  and is mostly compatible with the classic `sqlcmd` flags.
- **Root user:** the image runs as root so capture and mount tools work. On clusters
  that enforce `runAsNonRoot`, most of the tools still work as an arbitrary UID.
- **Image size:** `full` is about 970 MB and `slim` about 820 MB; tshark alone adds about 150 MB.
  Most of the rest is the DB clients, rclone and kubectl.
