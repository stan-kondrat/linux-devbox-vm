# linux-devbox-vm: a devbox based on linux-libre-vm

One script that turns an empty folder on an Apple Silicon Mac into a
development VM. The VM runs the
[linux-libre-vm](https://github.com/stan-kondrat/linux-libre-vm) arm64 image
in UTM and serves the **Theia IDE** (Eclipse Theia, a VS Code–like IDE in the
browser) and **OpenSSH** with a user/password login.

```bash
mkdir ~/devbox && cd ~/devbox && /path/to/linux-devbox-vm.sh
```

When it finishes:

```
Theia:  http://192.168.65.34:3000
SSH:    ssh dev@192.168.65.34  (password in devbox.env), or ./vm.sh ssh
```

From then on, `./vm.sh start` in that folder boots the VM with both servers
running.

## What it adds to linux-libre-vm

The VM boots a linux-libre-vm release (kernel and disk image, `VM_RELEASE`,
default the latest) as it is, created and driven by linux-libre-vm's own
runner, `vm/utm.sh`. It is the **base image**, not the dev image, so the VM
has no compiler. Everything below is added by the devbox: files in the shared
folder on the Mac, and settings that the boot script (`shared/devbox/boot.sh`)
writes to the VM's disk on every `./vm.sh start`. The image itself is not
modified, and `./vm.sh recreate` (a fresh disk from the release) gets
everything back on the next start.

| Added | Version | From | In the VM |
|-------|---------|------|-----------|
| Theia IDE (browser example app), with about 100 VS Code extensions | v1.76.0 | source from GitHub, built in the VM; npm packages; Open VSX | runit service `theia` on port 3000, run as the devbox user; `/mnt/shared/theia` |
| Node.js and npm | 24.21.0 | nodejs.org official linux-arm64 build | `/mnt/shared/node/bin` on the devbox user's `PATH` |
| git (without its perl commands and man pages) | 2.47.3 | Debian trixie | `/bin/git`, `/usr/lib/git-core`, `/usr/share/git-core`, linked to `/mnt/shared/sysroot` |
| less | 668 | Debian trixie | `/bin/less`, linked to `/mnt/shared/sysroot` |
| CA certificates | 20250419 | Debian trixie | `/etc/ssl/certs/ca-certificates.crt` |
| libstdc++, libgcc_s | gcc 14.2 | Debian trixie | `/lib` |
| glibc's `libdl`, `libpthread`, `libutil`, `librt`, `libresolv` | glibc 2.41 | Debian trixie | `/lib` |
| git's HTTPS libraries (libcurl-gnutls, gnutls, nghttp2, libssh2, krb5, …) | | Debian trixie | `/lib` |
| OpenSSL `libssl`/`libcrypto` | 3.5 | Debian trixie | `/mnt/shared/sysroot/usr/lib/devbox-openssl`, loaded only by git's HTTPS helper |
| devbox user, with your Mac user's uid/gid | | | `/etc/passwd`, `/etc/shadow`; home `/mnt/shared/home/<user>` |
| password login in OpenSSH | | | `/etc/ssh/sshd_config`; root stays key-only |
| `/usr/bin/env` | | | link to `/bin/env` (npm's `#!/usr/bin/env node`) |
| runtime directory | | | `/run/user/<uid>` on tmpfs, `$XDG_RUNTIME_DIR` |
| hostname | | | the VM name (`NAME`) |
| clock | | | set from the Mac on every start |

Libraries are copied into `/lib` only when the image does not have them, so
the image's own glibc, zlib and OpenSSL stay in use. Debian's OpenSSL is kept
apart because the image's `libcrypto` is a minimal build for OpenSSH, which
lacks parts Debian's `libssl` needs; `ssh` and `sshd` use the image's own.
The glibc libraries are ones the image leaves out: `libdl`, `libpthread`,
`libutil` and `librt` are empty stubs since glibc 2.34, which Node.js, Nx and
Claude Code's CLI still link, and git's HTTPS helper needs `libresolv`.

Debian packages are resolved with their dependencies from the archive's
`Packages` index, and each `.deb` is checked against the SHA-256 listed
there. Node.js is checked against its release's `SHASUMS256.txt`.

## Requirements

- Apple Silicon Mac (the image is arm64; UTM runs it with hardware virtualization)
- [UTM](https://mac.getutm.app) 5.x in `/Applications`
- `python3` and `git` from the Xcode Command Line Tools (`xcode-select --install`)
- About 3 GB of disk space per devbox, and 8 GB of free RAM while it runs

The first run asks to let the terminal control UTM (macOS Automation
permission). The folder path must not contain spaces or `,`.

## Setting up a devbox

Run `linux-devbox-vm.sh` from inside an empty folder. Each folder is a separate
devbox with its own VM. Settings are taken from the environment on the first
run and stored in `devbox.env`:

```bash
mkdir -p ~/work/mybox && cd ~/work/mybox
NAME=mybox DEVBOX_USER=user DEVBOX_PASSWORD=secret /path/to/linux-devbox-vm.sh
```

| Setting | Default | Meaning |
|---------|---------|---------|
| `NAME` | `devbox-<folder name>` | VM name in UTM; must be unique |
| `DEVBOX_USER` / `DEVBOX_PASSWORD` | `dev` / `dev` | login for SSH (the Theia IDE has no login) |
| `MEM` / `CPUS` | `8192` / `1` | RAM in MiB / cores; the Theia IDE build needs several GB |
| `VM_RELEASE` | `latest` | linux-libre-vm release the VM disk comes from |
| `THEIA_VERSION` | `v1.76.0` | Theia IDE git tag |
| `NODE_VERSION` | `24.21.0` | Node.js version |
| `THEIA_PORT` | `3000` | Theia IDE port |
| `VM_REPO` | `stan-kondrat/linux-libre-vm` | where the image and runner scripts come from |
| `TOOLS_REF` | `main` | branch, tag or commit of the runner scripts |

`DEVBOX_USER`, `DEVBOX_PASSWORD` and `THEIA_PORT` take effect on the next
`./vm.sh start`; `MEM`, `CPUS` and `VM_RELEASE` on `./vm.sh recreate`.

The first run takes about 45 minutes, most of it building the Theia IDE inside
the VM (see below). SSH works a few minutes in, while the build is still
running.

## Commands

`vm.sh` drives the VM with linux-libre-vm's runner: `vm/utm.sh`, with
`vm/release.sh` and `vm/serial-exec.py`, downloaded from the linux-libre-vm
repository (`VM_REPO`, at `TOOLS_REF`) into `.devbox/tools/vm/`. The
commands marked *linux-libre-vm* are that runner's commands, run for this
devbox's VM; the others are the devbox's own, built on them. Run in the
devbox folder:

| Command | What it does | From |
|---------|--------------|------|
| `./vm.sh start` | create the VM if needed (`utm.sh create`), boot it (`utm.sh start`), configure it, print the addresses | devbox |
| `./vm.sh setup` | `start`, then wait until the Theia IDE answers | devbox |
| `./vm.sh status` | VM state, address, Theia IDE build progress | devbox |
| `./vm.sh ssh [ARGS]` | ssh to the VM as the devbox user | devbox |
| `./vm.sh logs` | follow the Theia IDE build and server logs | devbox |
| `./vm.sh stop` | stop the VM | linux-libre-vm |
| `./vm.sh console` | serial console, logged in as root (Ctrl-] quits) | linux-libre-vm |
| `./vm.sh exec CMD...` | run commands as root over the serial console | linux-libre-vm |
| `./vm.sh restart-theia` | restart the Theia IDE service; retries a failed build | devbox |
| `./vm.sh recreate` | new VM disk from the release; `shared/` is kept, so the Theia IDE is not built again | devbox |
| `./vm.sh delete` | delete the VM; `shared/` is kept | linux-libre-vm |
| `./vm.sh update-tools` | download the newest linux-libre-vm runner scripts | devbox |

The VM gets its address from UTM's DHCP, and it can change between boots;
`./vm.sh status` shows the current one.

## Folder layout

```
devbox/
├── vm.sh                 the commands above
├── devbox.env            settings, including the password (mode 600)
├── shared/               shared with the VM, mounted at /mnt/shared
│   ├── workspace/        the folder the Theia IDE opens; ~/workspace in the VM
│   ├── home/<user>/      the devbox user's home directory
│   ├── node/             Node.js
│   ├── theia/            the Theia IDE: source, build output, extensions
│   ├── runtime-lib/      libraries copied into the VM's /lib
│   ├── sysroot/          git, less, CA certificates, Debian's OpenSSL
│   └── devbox/           scripts the VM runs, logs/, state/
└── .devbox/              runner scripts, UTM bundle, downloads
```

Everything the VM needs to keep is in `shared/`, on the Mac's disk. The VM's
own disk (256 MB) holds only the image and a few small files, so
`./vm.sh recreate` replaces it without losing work. Files in `shared/` are
owned by your Mac user on both sides: the devbox user has your uid and gid.

## The Theia IDE build

The Theia IDE is built from source inside the VM, the first time its service
starts. Each step leaves a marker in `shared/devbox/logs/build/`, so an
interrupted build resumes where it stopped.

| Step | What it does | Time |
|------|--------------|------|
| `install` | `npm ci --ignore-scripts`: about 2,250 npm packages | 3–4 min |
| `postinstall` | Theia's own setup: patches, TypeScript project references | 3 min |
| `compile` | `tsc` on the ~90 `@theia/*` packages | 27–34 min |
| `bundle` | webpack production bundle of the browser front end | 1–1.5 min |
| `plugins` | about 100 VS Code extensions from Open VSX | 2 min |

The image has no C compiler, so native npm addons are not built: node-pty
ships a prebuilt linux-arm64 binary (the terminal works), and drivelist and
keytar are replaced by small JavaScript stand-ins (`native-stubs.js`).

## Home directory and sockets

The devbox user's home is `shared/home/<user>` (in the VM,
`/mnt/shared/home/<user>`, also reachable as `/home/<user>`), because tools
install themselves under `~`: Claude Code's and VS Code's SSH servers,
`npm -g`, caches. The shared folder cannot hold Unix sockets, so
`$XDG_RUNTIME_DIR` is `/run/user/<uid>` on tmpfs, and Claude Code's
`~/.claude/remote/run` points there.

## Security

- The Theia IDE has no login. Anyone who can reach port 3000 gets a shell as
  the devbox user. With UTM's shared network the VM is reachable from the Mac
  only.
- The password is stored in plain text in `devbox.env`, and as a SHA-512
  crypt hash in `shared/devbox/guest.conf`.
- Secrets saved in the Theia IDE are kept in memory only (keytar stand-in)
  and are lost when it restarts.

## Troubleshooting

- **Theia IDE build failed**: the step's log is in `shared/devbox/logs/build/`;
  `./vm.sh restart-theia` retries from the failed step.
- **`ls -l` prints "Too many levels of symbolic links"** for a symlink in
  `shared/`: `ls` asks for extended attributes, which the shared folder
  refuses on symlinks. The link itself works.
- **"console … is already in use"**: another `./vm.sh console` or `exec`
  has the serial console. Close it, or pass `--force`.
- **No address after start**: run `./vm.sh start` again; it waits up to a
  minute for DHCP.

## Related

- [linux-libre-vm](https://github.com/stan-kondrat/linux-libre-vm): the
  image, and the `vm/utm.sh` runner that `vm.sh` uses.
