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
Theia:  http://localhost:24894  (http://192.168.65.34:3000 works without webviews)
SSH:    ssh dev@192.168.65.34  (password in devbox.env), or ./vm.sh ssh
```

From then on, `./vm.sh start` in that folder boots the VM with both servers
running. Open the Theia IDE at the `localhost` address: see
[Webviews and the localhost port](#webviews-and-the-localhost-port).

## What it adds to linux-libre-vm

The VM boots a linux-libre-vm release (kernel and disk image, `VM_RELEASE`,
default the latest) as it is, created and driven by linux-libre-vm's own
runner, `vm/utm.sh`. `IMAGE` picks the image: `dev` (the default) is the
**dev image**, with a toolchain built from source (gcc, binutils, make, perl,
Python) on an 8 GB disk; `base` is the **base image**, 256 MB without a
compiler. Everything below is added by the devbox: files in the shared
folder on the Mac, and settings that the boot script (`shared/devbox/boot.sh`)
writes to the VM's disk on every `./vm.sh start`. The image itself is not
modified, and `./vm.sh recreate` (a fresh disk from the release) gets
everything back on the next start. Once that has run, the VM also comes up
with the Theia IDE and OpenSSH when it is started from the UTM app or
rebooted inside: the `theia` service sets up the RAM disk and the runtime
directory (`shared/devbox/runtime.sh`) at every boot.

| Added | Version | From | In the VM |
|-------|---------|------|-----------|
| Theia IDE (browser example app), with about 100 VS Code extensions | v1.77.0 | source from GitHub, built in the VM; npm packages; Open VSX | runit service `theia` on port 3000, run as the devbox user; built in `/mnt/shared/theia`, run from its RAM copy in `/opt/devbox` |
| Node.js and npm | 24.21.0 | nodejs.org official linux-arm64 build | `/mnt/shared/node` on the devbox user's `PATH`; the `node` binary runs from its RAM copy in `/opt/devbox/node/bin` |
| RAM disk | | | `/opt/devbox` (tmpfs, 2 GB limit, about 550 MB used): the Theia IDE and the `node` binary, copied at every boot |
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
| clock | | | set from the Mac on every start; the runit service `clock` resets it from the RTC (which follows the Mac's clock) when it is more than 2 s off, checked every 30 s, as it stands still while the Mac sleeps |

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
| `MEM` / `CPUS` | `8192` / `2` | RAM in MiB / cores; the Theia IDE build needs several GB. The cores are used on demand: an idle VM takes almost no CPU on the Mac |
| `IMAGE` | `dev` | `dev`: the dev image (toolchain, 8 GB disk); `base`: the base image (256 MB, no compiler) |
| `VM_RELEASE` | `latest` | linux-libre-vm release the VM disk comes from |
| `THEIA_VERSION` | `v1.77.0` | Theia IDE git tag; a changed value is built by `./vm.sh upgrade-theia` |
| `NODE_VERSION` | `24.21.0` | Node.js version |
| `THEIA_PORT` | `3000` | Theia IDE port in the VM |
| `LOCAL_PORT` | a free port in 20000–29999 | Mac port forwarded to the Theia IDE (`http://localhost:<port>`); picked on the first start and added to `devbox.env` |
| `VM_REPO` | `stan-kondrat/linux-libre-vm` | where the image and runner scripts come from |
| `TOOLS_REF` | `main` | branch, tag or commit of the runner scripts |

`DEVBOX_USER`, `DEVBOX_PASSWORD`, `THEIA_PORT` and `LOCAL_PORT` take effect
on the next `./vm.sh start`; `MEM`, `CPUS`, `IMAGE` and `VM_RELEASE` on `./vm.sh recreate`. A `devbox.env`
without `IMAGE` uses the base image.

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
| `./vm.sh start` | create the VM if needed (`utm.sh create`), boot it (`utm.sh start`), configure it, start the localhost forwarder, wait until the Theia IDE answers (once it is built), print the addresses | devbox |
| `./vm.sh setup` | `start`, then wait until the Theia IDE answers | devbox |
| `./vm.sh status` | VM state, address, Theia IDE build progress | devbox |
| `./vm.sh ssh [ARGS]` | ssh to the VM as the devbox user | devbox |
| `./vm.sh tunnel [stop]` | (re)start or stop the forwarder from `localhost:LOCAL_PORT` to the Theia IDE | devbox |
| `./vm.sh logs` | follow the Theia IDE build and server logs | devbox |
| `./vm.sh pause` | freeze the VM in place: it keeps its RAM (the Theia IDE stays loaded) and uses no CPU | devbox |
| `./vm.sh resume` | continue a paused VM, set its clock, start the forwarder, print the addresses | devbox |
| `./vm.sh stop` | stop the forwarder, write the VM's pending disk writes (`sync`), then stop the VM, which cuts its power | linux-libre-vm |
| `./vm.sh console` | serial console, logged in as root (Ctrl-] quits) | linux-libre-vm |
| `./vm.sh exec CMD...` | run commands as root over the serial console | linux-libre-vm |
| `./vm.sh restart-theia` | restart the Theia IDE service; retries a failed build | devbox |
| `./vm.sh upgrade-theia` | replace the installed Theia IDE by the `THEIA_VERSION` in `devbox.env`: a new build of about an hour, with the IDE down meanwhile; settings, home and workspace stay | devbox |
| `./vm.sh recreate` | new VM disk from the release (`IMAGE`, `VM_RELEASE`); `shared/` is kept, so the Theia IDE is not built again | devbox |
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
│   ├── .vm-boot/         the VM's kernel, read from here by QEMU (utm.sh)
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
own disk (256 MB for the base image, 8 GB for the dev image) holds only the
image and a few small files, so
`./vm.sh recreate` replaces it without losing work. Files in `shared/` are
owned by your Mac user on both sides: the devbox user has your uid and gid.

## The Theia IDE build

The Theia IDE is built from source inside the VM, the first time its service
starts. Each step leaves a marker in `shared/devbox/logs/build/`, so an
interrupted build resumes where it stopped.

| Step | What it does | Time |
|------|--------------|------|
| `install` | `npm ci --ignore-scripts`: about 2,250 npm packages | 3–4 min |
| `configure` | the devbox's defaults, below | under 1 s |
| `postinstall` | Theia's own setup: patches, TypeScript project references | 3 min |
| `compile` | `tsc` on the ~90 `@theia/*` packages | 27–34 min |
| `bundle` | webpack production bundle of the browser front end | 1–1.5 min |
| `plugins` | about 100 VS Code extensions from Open VSX | 2 min |

Native npm addons are not built (`npm ci --ignore-scripts`; the base image
has no C compiler, and the dev image's is not used): node-pty ships a
prebuilt linux-arm64 binary (the terminal works), and drivelist and keytar
are replaced by small JavaScript stand-ins (`native-stubs.js`).

### Defaults of the Theia IDE

The `configure` step (`shared/devbox/theia-config.js`) changes the Theia
checkout before the bundle and the extensions are built:

| Off by default | How | To turn it on |
|----------------|-----|---------------|
| AI features | the default preference `ai-features.AiEnable.enableAI` is `false`: the AI chat, agents and completion do nothing and send nothing | set `ai-features.AiEnable.enableAI` to `true` in the settings, then add a model provider |
| Telemetry | the default preference `telemetry.telemetryLevel` is `off`, which extensions see too (Python, Jupyter ...) | set `telemetry.telemetryLevel` in the settings |
| Java extension | `vscode.java` (Java syntax highlighting), the only Java extension, is left out of the extensions (`theiaPluginsExcludeIds`) | install a Java extension from the Extensions view (Open VSX); it is kept in `~/.theia/deployedPlugins`, also across upgrades |

The preferences are defaults, so `settings.json` overrides them. The AI code
is still part of the IDE (its plugin system depends on `@theia/ai-core` and
`@theia/ai-mcp`); the preference only switches it off.

An installed Theia IDE keeps its version until `./vm.sh upgrade-theia`
replaces it: `./vm.sh start` says when `THEIA_VERSION` differs from it, and
`./vm.sh status` shows the installed one.

## Running from RAM

The shared folder is mounted without caching, so every file access is a round
trip to the Mac: listing the 4,656 plugin files takes 5.6 s there and 0.006 s
in RAM, reading them 20 s and 0.06 s. The Theia IDE reads thousands of small
files, so it runs from a RAM copy: at every boot `theia.sh` copies its bundled
code (`examples/browser/lib`), the plugins and the `node` binary (about
550 MB) to `/opt/devbox`, and again after a rebuild. From RAM the backend is
ready in about 1.2 s instead of 3 s. The workspace and the home directory stay
in the shared folder.

Copying costs about 25 ms per file but reads large files at about 16 MB/s, so
the plugins are packed once after a build into `shared/theia/plugins.tar`
(about 2.5 min) and unpacked from there. The copy takes about 40 s, and
`./vm.sh start` returns with the Theia IDE answering about 50 s after the VM
boots.

## Webviews and the localhost port

Extension webviews (Markdown preview, extension pages) need two things the
VM's address cannot give:

- a secure context, because each webview registers a service worker, and
  browsers allow that only on HTTPS or `localhost`
- its own host name, `<uuid>.webview.<host>` (Theia's default
  `THEIA_WEBVIEW_EXTERNAL_ENDPOINT`), which does not exist under an IP
  address

`http://localhost:<LOCAL_PORT>` gives both: `localhost` is a secure context,
and Chrome and Firefox resolve every `*.localhost` name to the Mac itself. No
certificate is needed. `./vm.sh start` runs a small TCP forwarder (Python, in
the background, listening on 127.0.0.1 only) from that port to the Theia IDE
in the VM. It reads the VM's address on every connection, so a new address
after a reboot needs no restart. Each devbox picks its own `LOCAL_PORT` once,
so several devboxes run side by side. The forwarder does not outlive the
Mac's session: after a Mac restart, `./vm.sh start` or `./vm.sh tunnel`
starts it again.

## Home directory and sockets

The devbox user's home is `shared/home/<user>` (in the VM,
`/mnt/shared/home/<user>`, also reachable as `/home/<user>`), because tools
install themselves under `~`: Claude Code's and VS Code's SSH servers,
`npm -g`, caches. The shared folder cannot hold Unix sockets, so
`$XDG_RUNTIME_DIR` is `/run/user/<uid>` on tmpfs, and Claude Code's
`~/.claude/remote/run` points there.

`~/.theia/logs` points to `/run/user/<uid>/theia-logs` as well. The Theia IDE
watches `~/.theia` recursively for its settings, while its plugin host deletes
old session folders in `~/.theia/logs`; a folder that disappears during the
watcher's first scan fails the whole watch. The watcher does not follow the
symlink. The plugin host's session logs are lost at every reboot.

## Security

- The Theia IDE has no login. Anyone who can reach port 3000, or
  `LOCAL_PORT` on the Mac, gets a shell as the devbox user. With UTM's shared network the VM is reachable from the Mac
  only.
- The password is stored in plain text in `devbox.env`, and as a SHA-512
  crypt hash in `shared/devbox/guest.conf`.
- Secrets saved in the Theia IDE are kept in memory only (keytar stand-in)
  and are lost when it restarts.

## Troubleshooting

- **"Cannot read properties of undefined (reading 'tsdk')"** when Astro, Vue
  or another Volar-based extension activates: it looks for TypeScript in
  `<appRoot>/extensions/node_modules/typescript`, where VS Code ships it.
  `theia.sh` links the copy in Theia's built-in TypeScript plugin there;
  `./vm.sh restart-theia` adds it to a Theia IDE started before.
- **Theia IDE build failed**: the step's log is in `shared/devbox/logs/build/`;
  `./vm.sh restart-theia` retries from the failed step.
- **"could not load kernel" from `./vm.sh start` or the UTM app**: UTM lost
  QEMU's access to the kernel (VMs created by a `vm/utm.sh` older than
  `shared/.vm-boot`). `./vm.sh update-tools`, then `./vm.sh start`, moves the
  kernel into `shared/.vm-boot`.
- **Started from the UTM app**: both servers come up, but the localhost
  forwarder runs on the Mac: `./vm.sh tunnel` starts it.
- **"vm.sh forwarder: cannot reach Theia" on the localhost page**: the
  forwarder could not connect to the VM; the reason follows, and it is also
  in `.devbox/tunnel.log`. "No route to host" while the VM's own address
  works means macOS Local Network privacy blocks Python for the app that
  started the forwarder (System Settings → Privacy & Security → Local
  Network). `./vm.sh tunnel` from Terminal starts a new one.
- **No Pause button in the UTM app**: UTM puts it in a VM's display window,
  and the devbox VM has no display. `./vm.sh pause` and `./vm.sh resume` do
  the same.
- **`ls -l` prints "Too many levels of symbolic links"** for a symlink in
  `shared/`: `ls` asks for extended attributes, which the shared folder
  refuses on symlinks. The link itself works.
- **"console … is already in use"**: another `./vm.sh console` or `exec`
  has the serial console. Close it, or pass `--force`.
- **Blank webviews (Markdown preview)**: open the Theia IDE at
  `http://localhost:<LOCAL_PORT>`, not the VM's address.
- **"the localhost forwarder did not start"**: another program, or another
  devbox, uses `LOCAL_PORT`; set a different one in `devbox.env`.
- **"Unable to watch for file changes in this large workspace"**: the Theia
  IDE shows this for any failure of its file watcher, not only a large
  workspace; `shared/devbox/logs/theia.log` has the cause ("Watcher failed to
  start"). `./vm.sh restart-theia` starts a new watcher.
- **"chpst: unknown user" in a loop, SSH login refused**: the VM lost power
  right after `/etc/passwd` was written (UTM's stop button cuts the power).
  `./vm.sh start` repairs the file; `boot.sh` writes it to disk right away.
- **No address after start**: run `./vm.sh start` again; it waits up to a
  minute for DHCP.

## Related

- [linux-libre-vm](https://github.com/stan-kondrat/linux-libre-vm): the
  image, and the `vm/utm.sh` runner that `vm.sh` uses.
