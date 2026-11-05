# FUSE in unprivileged containers

This guide covers how to mount S3, SFTP, FTP, SMB or WebDAV with `rclone mount`, `s3fs` or `sshfs` from
netdebug without `privileged: true`.

## Summary

| Where | Works without privileged? | What you need |
|---|---|---|
| Docker | yes | `--device /dev/fuse --cap-add SYS_ADMIN` (+ `--security-opt apparmor=unconfined` on AppArmor hosts) |
| Kubernetes with user namespaces (≥ 1.33, GA in 1.36) | yes, the recommended way | a `/dev/fuse` device plugin + `hostUsers: false` + `SYS_ADMIN` + AppArmor `Unconfined` |
| Kubernetes without user namespaces | technically | same as above without `hostUsers: false`. `SYS_ADMIN` then applies to the host and is nearly as broad as privileged |
| NFS / CIFS kernel mounts | **no** | they need real `CAP_SYS_ADMIN` and don't work in a user namespace. Use a CSI driver or client tools instead |

## Why FUSE needs anything at all

A FUSE mount has four requirements. A default container meets none of them:

1. **`/dev/fuse` must exist and be openable.** The device node isn't in the container, and the
   device cgroup denies opening it. In Kubernetes, a `hostPath` volume for `/dev/fuse` is **not
   enough**: the node shows up, but `open()` still fails. Only kubelet can add the device to the
   cgroup allowlist, and it does so for privileged pods or for devices allocated by a
   **device plugin**.
2. **`CAP_SYS_ADMIN` for the `mount(2)` call.** The capability only has to be held in the user
   namespace that owns the mount namespace. The FUSE filesystem type is allowed to be mounted inside
   user namespaces (Linux ≥ 4.18). That's why user namespaces turn this from "nearly root on the node"
   into "root only inside the pod".
3. **The security profiles must allow the mount.** The runtime's default seccomp profile allows
   `mount` once `CAP_SYS_ADMIN` is present. The default AppArmor profile (Ubuntu, Debian and others
   with AppArmor enabled) denies mounts, so it must be `Unconfined` or a custom profile that allows
   them. SELinux hosts (OpenShift, RHEL) need the `container_use_fuse` boolean or an equivalent policy.
4. **Non-root needs `fusermount3`, and `fusermount3` is setuid root.** With
   `allowPrivilegeEscalation: false` (`no_new_privs`), setuid binaries don't gain privileges. So run the
   mount as **UID 0 inside the container**. With `hostUsers: false` that UID 0 is an unprivileged UID
   on the host.

## Docker

Verified with this image:

```bash
docker run --rm -it \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  ghcr.io/datarocks-ag/debug-docker:latest-slim bash
# the apparmor flag is only needed (and only accepted) on AppArmor hosts

rclone mount remote:bucket /mnt --daemon
sshfs user@host:/path /mnt
s3fs bucket /mnt -o url=https://s3.example.com,use_path_request_style,passwd_file=$HOME/.passwd-s3fs
```

| Flags | Result |
|---|---|
| none | `/dev/fuse` missing → mount fails |
| `--device /dev/fuse` only | `mount not ready` / `Operation not permitted` |
| `--device /dev/fuse --cap-add SYS_ADMIN` | works |

Rootless Podman behaves like the user-namespace case below. It needs `/etc/subuid` and `/etc/subgid`
ranges for your user.

## Kubernetes

### 1. Expose `/dev/fuse` with a device plugin (cluster admin, once)

Use [squat/generic-device-plugin](https://github.com/squat/generic-device-plugin). It runs as a
DaemonSet and advertises `/dev/fuse` as the extended resource `squat.ai/fuse`. Its default config
already includes FUSE. To let several pods per node use it, raise the count:

```yaml
# generic-device-plugin container args
- --device
- |
  name: fuse
  groups:
    - count: 20
      paths:
        - path: /dev/fuse
```

Check that nodes advertise it:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FUSE:.status.allocatable.squat\.ai/fuse'
```

[smarter-device-manager](https://gitlab.com/arm-research/smarter/smarter-device-manager) works the same
way and calls the resource `smarter-devices/fuse`.

### 2. Allow the pod in the namespace

`SYS_ADMIN` isn't on the Pod Security **baseline** capability allowlist, so the namespace must
enforce `privileged`, even though the pod itself isn't privileged:

```bash
kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged --overwrite
```

Keep this to a dedicated debug namespace. Add an admission policy (Kyverno, Gatekeeper, VAP) if you
want to require `hostUsers: false` there.

### 3. Run the pod

[k8s/netdebug-fuse.yaml](../k8s/netdebug-fuse.yaml) contains this spec:

```yaml
spec:
  hostUsers: false                      # user namespace: UID 0 + SYS_ADMIN only inside the pod
  containers:
    - name: netdebug
      image: ghcr.io/datarocks-ag/debug-docker:latest-slim
      securityContext:
        runAsUser: 0                    # root in the pod's userns, unprivileged on the node
        allowPrivilegeEscalation: false
        capabilities:
          add: ["SYS_ADMIN"]
        appArmorProfile:
          type: Unconfined              # only matters on AppArmor nodes
        seccompProfile:
          type: RuntimeDefault          # allows mount once SYS_ADMIN is present
      resources:
        limits:
          squat.ai/fuse: 1              # makes kubelet add /dev/fuse to the cgroup allowlist
```

```bash
kubectl apply -n <ns> -f k8s/netdebug-fuse.yaml
kubectl exec -it -n <ns> netdebug-fuse -- bash
rclone mount remote:bucket /mnt --daemon && ls /mnt
```

User namespaces have these requirements:

- Kubernetes ≥ 1.33 (on by default) and GA from 1.36.
- Linux ≥ 6.3 on the nodes.
- containerd ≥ 2.0 or CRI-O ≥ 1.25.
- `hostUsers: false` can't be combined with `hostNetwork`, `hostPID` or `hostIPC`.

To check that a pod really runs in a user namespace:

```bash
cat /proc/self/uid_map    # e.g. "0 1638400 65536" = mapped; "0 0 4294967295" = host namespace
```

## NFS, CIFS and other kernel filesystems

These are not FUSE. The kernel only allows them with `CAP_SYS_ADMIN` in the **initial** user
namespace, so `hostUsers: false` doesn't help. Verified: `mount -t nfs4` returns
`Operation not permitted` inside a user namespace. A CIFS mount failed the same way, though its error
didn't name the cause.

The options:

- **CSI drivers:** the node mounts the share and the pod gets an ordinary volume, so the pod needs
  no privileges at all. Examples: [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs),
  [csi-driver-smb](https://github.com/kubernetes-csi/csi-driver-smb), and
  [Mountpoint for Amazon S3 CSI](https://github.com/awslabs/mountpoint-s3-csi-driver) for S3.
- **Client tools without a mount**, all unprivileged and included in this image: `rclone ls|copy|cat`,
  `lftp`, `smbclient //server/share`, `sftp`, `showmount -e server` and `rpcinfo -p server` (for NFS
  reachability).
- **The privileged pod** from [k8s/netdebug.yaml](../k8s/netdebug.yaml), where policy allows it.

## Troubleshooting

| Symptom | Cause | Check |
|---|---|---|
| `fuse: device not found, try 'modprobe fuse' first` | no `/dev/fuse` in the container | `ls -l /dev/fuse`; device plugin resource requested? |
| `/dev/fuse` exists but `Operation not permitted` on open | hostPath only, the cgroup still denies it | request `squat.ai/fuse` instead of hostPath |
| `fusermount3: mount failed: Operation not permitted` / rclone `mount not ready` | no `CAP_SYS_ADMIN` | `grep CapEff /proc/self/status` (bit 21 = `0x200000`) |
| same, although `SYS_ADMIN` is set | AppArmor or SELinux denies the mount | `cat /proc/self/attr/current`; `dmesg` on the node |
| works as root, fails as non-root | `fusermount3` setuid blocked by `no_new_privs` | run the mount as UID 0 (with `hostUsers: false`) |
| `allow_other` rejected | not root and `user_allow_other` not set | run as root, or add `user_allow_other` to `/etc/fuse.conf` |
| pod rejected at admission | Pod Security baseline/restricted | namespace label `enforce=privileged` |

Unmount with `fusermount3 -u /mnt` (or `umount /mnt` as root).
