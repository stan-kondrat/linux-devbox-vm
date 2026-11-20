#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════════
# linux-devbox-vm.sh — turn an empty folder into a devbox: a linux-libre arm64 VM
# in UTM that serves Eclipse Theia (browser IDE) and OpenSSH with a simple
# user/password login.
#
#   mkdir ~/devbox && cd ~/devbox && /path/to/linux-devbox-vm.sh
#
# Writes vm.sh, devbox.env and shared/ into the current folder, then runs
# './vm.sh setup', which:
#   1. downloads the newest runner scripts (vm/utm.sh, vm/release.sh, ...)
#      from the linux-libre-vm repo (TOOLS_REF, default main)
#   2. downloads Node.js, git, less and the libraries they need (from Debian
#      trixie) and clones Theia, all into shared/
#   3. creates the VM from the latest release (vm/utm.sh create) and boots it
#   4. sets the clock, adds the devbox user, enables password login in the
#      image's OpenSSH server and installs a runit service for Theia
#   5. waits while the service builds Theia in the VM (first time only,
#      about 70 min; Ctrl-C stops waiting, not the build), then prints
#      http://localhost:<LOCAL_PORT> and the ssh command
# Afterwards './vm.sh start' boots the VM with both servers running;
# './vm.sh help' lists the other commands.
#
# Needs: Apple Silicon Mac, UTM 5.x in /Applications, python3 and git (Xcode
# Command Line Tools). The first run asks to let the terminal control UTM.
# The folder path must not contain spaces or ','.
#
# Settings (environment, stored in devbox.env):
#   NAME             VM name in UTM        (default: devbox-<folder name>)
#   DEVBOX_USER      login user            (default: dev)
#   DEVBOX_PASSWORD  its password          (default: dev)
#   MEM / CPUS       RAM in MiB / cores    (default: 8192 / 2; the Theia
#                    build needs several GB; the IDE's backend, extension
#                    host and language servers run side by side)
#   VM_RELEASE       image release tag     (default: latest)
#   IMAGE            dev: the dev image (toolchain built from source: gcc,
#                    make, perl, Python; 8 GB disk, about 3 GB of it used) or
#                    base: the base image (256 MB, no compiler)
#                                          (default: dev)
#   THEIA_VERSION    Theia git tag         (default: v1.77.0)
#   NODE_VERSION     Node.js version       (default: 24.21.0)
#   THEIA_PORT       Theia port in the VM  (default: 3000)
#   LOCAL_PORT       Mac port forwarded to Theia, http://localhost:<port>
#                    (default: a free port in 20000-29999, picked on the
#                    first start and added to devbox.env)
#   VM_REPO          GitHub owner/repo of linux-libre-vm
#                                          (default: stan-kondrat/linux-libre-vm)
#   TOOLS_REF        branch, tag or commit of the runner scripts (default: main)
# ═════════════════════════════════════════════════════════════════════════════

set -eu

die() { echo "linux-devbox-vm.sh: $*" >&2; exit 1; }

DIR=$(pwd -P)
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "needs an Apple Silicon Mac (UTM runs the arm64 image)"
[ -x /Applications/UTM.app/Contents/MacOS/utmctl ] || die "UTM not found in /Applications"
python3 -c pass 2>/dev/null || die "python3 not found (install the Xcode Command Line Tools: xcode-select --install)"
git --version >/dev/null 2>&1 || die "git not found (install the Xcode Command Line Tools: xcode-select --install)"
case $DIR in *[[:space:],]*) die "the folder path must not contain spaces or ',': $DIR" ;; esac
[ -z "$(ls -A | grep -vx '.DS_Store' || true)" ] || die "$DIR is not empty"

NAME=${NAME:-devbox-$(basename "$DIR" | tr -c 'A-Za-z0-9._-\n' '-')}
DEVBOX_USER=${DEVBOX_USER:-dev}
DEVBOX_PASSWORD=${DEVBOX_PASSWORD:-dev}
case $DEVBOX_USER in
root | [!a-z_]* | *[!a-z0-9_-]*) die "DEVBOX_USER must be a plain user name other than root (a-z, 0-9, _, -)" ;;
esac
case $DEVBOX_PASSWORD in *"'"* | *'
'*) die "DEVBOX_PASSWORD must not contain ' or a newline" ;; esac
IMAGE=${IMAGE:-dev}
case $IMAGE in dev | base) ;; *) die "IMAGE must be dev or base (got '$IMAGE')" ;; esac
if /Applications/UTM.app/Contents/MacOS/utmctl status "$NAME" >/dev/null 2>&1; then
	die "UTM already has a VM named '$NAME'; choose another one with NAME=..."
fi

# ─── devbox.env ─────────────────────────────────────────────────────────────
cat >devbox.env <<EOF
# devbox settings, read by vm.sh (written by linux-devbox-vm.sh).
# DEVBOX_USER / DEVBOX_PASSWORD / THEIA_PORT apply on the next './vm.sh start';
# MEM, CPUS, IMAGE and VM_RELEASE on './vm.sh recreate'.
NAME='$NAME'
DEVBOX_USER='$DEVBOX_USER'
DEVBOX_PASSWORD='$DEVBOX_PASSWORD'
MEM=${MEM:-8192}
CPUS=${CPUS:-2}
VM_RELEASE='${VM_RELEASE:-latest}'
IMAGE='$IMAGE'
THEIA_VERSION='${THEIA_VERSION:-v1.77.0}'
NODE_VERSION='${NODE_VERSION:-24.21.0}'
THEIA_PORT=${THEIA_PORT:-3000}
${LOCAL_PORT:+LOCAL_PORT=$LOCAL_PORT
}VM_REPO='${VM_REPO:-stan-kondrat/linux-libre-vm}'
TOOLS_REF='${TOOLS_REF:-main}'
EOF
chmod 600 devbox.env

# ─── vm.sh ──────────────────────────────────────────────────────────────────
cat >vm.sh <<'VMSH'
#!/bin/sh
# vm.sh — the devbox in this folder (made by linux-devbox-vm.sh): a linux-libre
# arm64 VM in UTM serving Eclipse Theia and OpenSSH. Settings: devbox.env.
#
#   ./vm.sh start         create the VM if needed, boot it, print the addresses
#   ./vm.sh setup         start, then wait until Theia answers (builds it first)
#   ./vm.sh status        VM state, address, Theia build progress
#   ./vm.sh ssh [ARGS]    ssh to the VM as the devbox user
#   ./vm.sh tunnel [stop] (re)start or stop the forwarder from
#                         localhost:LOCAL_PORT to Theia ('start' runs it;
#                         webviews need localhost, not the VM address)
#   ./vm.sh logs          follow the Theia build and server logs
#   ./vm.sh pause         freeze the VM in place (keeps its RAM; no CPU use)
#   ./vm.sh resume        continue a paused VM, set its clock, print the addresses
#   ./vm.sh stop | console | exec CMD...
#   ./vm.sh restart-theia restart the Theia service (also retries a failed build)
#   ./vm.sh recreate      new VM disk from the release (VM_RELEASE, IMAGE); shared/ is
#                         kept, so Theia is not built again
#   ./vm.sh delete        delete the VM (keeps shared/)
#   ./vm.sh update-tools  download the newest runner scripts (vm/utm.sh ...)
#   ./vm.sh upgrade-theia build the Theia version in devbox.env (THEIA_VERSION)
#                         in place of the installed one (about an hour)
#
# Layout:
#   devbox.env         settings
#   shared/            mounted at /mnt/shared in the VM
#     workspace/       the folder Theia opens (~/workspace in the VM)
#     home/<user>/     the devbox user's home (the root disk is 256 MB)
#     node/, theia/    Node.js, Theia
#     runtime-lib/, sysroot/   from Debian: libraries for /lib; git, less,
#                      CA certificates
#     devbox/          guest scripts, logs/, state/ (VM address ...)
#   .devbox/           runner scripts (tools/), UTM bundle, downloads

set -eu
HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/devbox.env"
IMAGE=${IMAGE:-base}  # a devbox.env from before IMAGE existed: the base image
DOT=$HERE/.devbox
TOOLS=$DOT/tools/vm
SH=$HERE/shared
D=$SH/devbox
LOGS=$D/logs
STATE=$D/state
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
STEPS="install configure postinstall compile bundle plugins"

die() { echo "vm.sh: $*" >&2; exit 1; }
say() { echo "vm.sh: $*"; }

utm() {
	VM_DIR=$DOT NAME=$NAME SHARE=$SH MEM=$MEM CPUS=$CPUS VM_REPO=$VM_REPO \
		VM_RELEASE=$VM_RELEASE "$TOOLS/utm.sh" "$@"
}
vm_state() { "$UTMCTL" status "$NAME" 2>/dev/null || echo "not found"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ─── downloads (on the Mac) ─────────────────────────────────────────────────

# Runner scripts from the linux-libre-vm repo, at the commit TOOLS_REF points
# to now
fetch_tools() {
	[ "${1:-}" = force ] || [ ! -x "$TOOLS/utm.sh" ] || return 0
	ref=$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
		"https://api.github.com/repos/$VM_REPO/commits/$TOOLS_REF" 2>/dev/null || true)
	case $ref in *[!0-9a-f]* | "") ref=$TOOLS_REF ;; esac
	say "runner scripts: $VM_REPO vm/ at $ref"
	tmp=$DOT/tools.part
	rm -rf "$tmp"
	mkdir -p "$tmp/vm"
	for f in utm.sh release.sh write-vm-sh.sh serial-exec.py VERSION; do
		curl -fsSL -o "$tmp/vm/$f" "https://raw.githubusercontent.com/$VM_REPO/$ref/vm/$f" ||
			die "download failed: $VM_REPO vm/$f ($ref)"
	done
	chmod 755 "$tmp/vm/utm.sh" "$tmp/vm/release.sh" "$tmp/vm/write-vm-sh.sh" "$tmp/vm/serial-exec.py"
	echo "$ref" >"$tmp/REF"
	# Keep the release cache: the VM boots its kernel from there
	[ ! -d "$TOOLS/cache" ] || mv "$TOOLS/cache" "$tmp/vm/cache"
	rm -rf "$DOT/tools"
	mv "$tmp" "$DOT/tools"
}

# Official Node.js linux-arm64 build, checked against the release's SHASUMS256
fetch_node() {
	[ ! -x "$SH/node/bin/node" ] || return 0
	f=node-v$NODE_VERSION-linux-arm64.tar.gz
	url=https://nodejs.org/dist/v$NODE_VERSION
	mkdir -p "$DOT/downloads"
	curl -fsSL -o "$DOT/downloads/SHASUMS256-node.txt" "$url/SHASUMS256.txt" ||
		die "Node.js $NODE_VERSION not found at $url"
	want=$(awk -v f="$f" '$2 == f { print $1 }' "$DOT/downloads/SHASUMS256-node.txt")
	[ -n "$want" ] || die "$f is not in $url/SHASUMS256.txt"
	if [ ! -f "$DOT/downloads/$f" ] || [ "$(sha256 "$DOT/downloads/$f")" != "$want" ]; then
		say "downloading $f"
		curl -fL --progress-bar -o "$DOT/downloads/$f.part" "$url/$f" || die "download failed: $url/$f"
		[ "$(sha256 "$DOT/downloads/$f.part")" = "$want" ] || die "checksum mismatch: $f"
		mv "$DOT/downloads/$f.part" "$DOT/downloads/$f"
	fi
	rm -rf "$SH/node.part"
	mkdir -p "$SH/node.part"
	tar -xzf "$DOT/downloads/$f" -C "$SH/node.part" --strip-components 1
	rm -rf "$SH/node"
	mv "$SH/node.part" "$SH/node"
}

# What the image lacks, from Debian trixie arm64: the packages in DEBS and
# their dependencies (Depends, first alternative), each .deb checked against
# the archive's Packages index.
#  - shared libraries -> shared/runtime-lib/, which boot.sh copies to /lib:
#    libstdc++/libgcc_s (node; the image has no C++ programs), the libraries
#    git needs, and from libc6 only libdl, libpthread, libutil and librt
#    (empty stubs since glibc 2.34 that binaries built for older glibc link:
#    node, Nx, Claude Code's CLI). glibc itself is the image's.
#  - git and less: their files -> shared/sysroot/ (boot.sh links them into place)
#  - ca-certificates: one bundle, shared/sysroot/etc/ssl/certs/ca-certificates.crt
DEBS="libstdc++6 libgcc-s1 libc6 git less ca-certificates"
# Not taken: perl (git's perl commands: send-email, svn ...), man pages,
# package tools
DEBS_SKIP="libc-bin perl perl-base liberror-perl git-man debconf dpkg base-files openssl"
fetch_debs() {
	[ "$(cat "$SH/runtime-lib/.debs" 2>/dev/null)" != "$DEBS" ] || return 0
	mirror=https://deb.debian.org/debian
	dl=$DOT/downloads
	mkdir -p "$dl"
	say "downloading $DEBS and dependencies (Debian trixie arm64)"
	curl -fsSL -o "$dl/Packages.xz" "$mirror/dists/trixie/main/binary-arm64/Packages.xz" ||
		die "download failed: Debian Packages index"
	python3 - "$dl/Packages.xz" "$DEBS_SKIP" $DEBS >"$dl/debs.txt" <<'PY' || die "resolving packages failed"
import lzma, re, sys
idx, provides = {}, {}
for para in lzma.open(sys.argv[1], "rt").read().split("\n\n"):
    f = dict(l.split(": ", 1) for l in para.splitlines() if ": " in l and l[0] not in " \t")
    if "Package" in f:
        idx[f["Package"]] = f
        for p in f.get("Provides", "").split(","):
            if p.strip():
                provides.setdefault(p.split()[0], f["Package"])
skip, todo, done = set(sys.argv[2].split()), sys.argv[3:], []
while todo:
    name = todo.pop(0)
    name = name if name in idx else provides.get(name)
    if name is None or name in skip or name in done:
        continue
    done.append(name)
    deps = idx[name].get("Pre-Depends", "") + "," + idx[name].get("Depends", "")
    for dep in deps.split(","):
        alts = [re.sub(r"[ (:].*", "", a.strip()) for a in dep.split("|") if a.strip()]
        todo += [a for a in alts if a in idx or a in provides][:1]
for name in done:
    print(name, idx[name]["Filename"], idx[name]["SHA256"])
PY
	rm -rf "$SH/runtime-lib.part" "$SH/sysroot.part"
	mkdir -p "$SH/runtime-lib.part" "$SH/sysroot.part"
	set --
	while read -r pkg path sum; do
		deb=$dl/$(basename "$path")
		if [ ! -f "$deb" ] || [ "$(sha256 "$deb")" != "$sum" ]; then
			curl -fsSL -o "$deb" "$mirror/$path" || die "download failed: $mirror/$path"
			[ "$(sha256 "$deb")" = "$sum" ] || die "checksum mismatch: $(basename "$path")"
		fi
		set -- "$@" "$pkg=$deb"
	done <"$dl/debs.txt"
	python3 - "$SH/runtime-lib.part" "$SH/sysroot.part" "$@" <<'PY' || die "unpacking packages failed"
import io, os, posixpath, re, sys, tarfile
libdir, sysroot = sys.argv[1:3]
GLIBC = {"libdl.so.2", "libpthread.so.0", "libutil.so.1", "librt.so.1", "libresolv.so.2"}
# OpenSSL apart from /lib: the image's libcrypto (built for OpenSSH, used by
# sshd and ssh) lacks parts Debian's libssl needs
OPENSSL = {"libssl.so.3", "libcrypto.so.3"}
ssldir = os.path.join(sysroot, "usr/lib/devbox-openssl")
os.makedirs(ssldir)
LIBDIRS = {"usr/lib/aarch64-linux-gnu", "lib/aarch64-linux-gnu"}
SONAME = re.compile(r"lib[^/]*\.so\.[0-9]+$")
TREE = {"git", "less"}
TREE_SKIP = ("usr/share/doc/", "usr/share/man/", "usr/share/locale/", "usr/share/lintian/")
bundle = []

def data_tar(path):
    data = open(path, "rb").read()
    assert data[:8] == b"!<arch>\n", path + ": not a .deb"
    pos = 8
    while pos < len(data):
        name = data[pos:pos + 16].decode().strip().rstrip("/")
        size = int(data[pos + 48:pos + 58])
        if name.startswith("data.tar"):
            return tarfile.open(fileobj=io.BytesIO(data[pos + 60:pos + 60 + size]), mode="r:*")
        pos += 60 + size + (size & 1)
    raise SystemExit(path + ": no data.tar")

for arg in sys.argv[3:]:
    pkg, path = arg.split("=", 1)
    tar = data_tar(path)
    members = {posixpath.normpath(m.name): m for m in tar.getmembers()}
    if pkg in TREE:
        sel = [m for n, m in members.items() if n != "." and not n.startswith(TREE_SKIP)]
        tar.extractall(sysroot, members=sel)
    elif pkg == "ca-certificates":
        bundle += [tar.extractfile(m).read() for n, m in sorted(members.items())
                   if n.startswith("usr/share/ca-certificates/") and n.endswith(".crt")]
    for name, m in members.items():
        d, base = posixpath.split(name)
        if d not in LIBDIRS or not SONAME.match(base) or (pkg == "libc6" and base not in GLIBC):
            continue
        while m.issym() or m.islnk():  # the soname is usually a link to the versioned file
            target = m.linkname if m.islnk() else posixpath.join(posixpath.dirname(m.name), m.linkname)
            m = members[posixpath.normpath(target)]
        with open(os.path.join(ssldir if base in OPENSSL else libdir, base), "wb") as f:
            f.write(tar.extractfile(m).read())
# git's curl helper (git-remote-http, and its links for https, ftp, ftps)
# loads libssl through libssh2: run it with Debian's OpenSSL. --library-path
# applies to this process only, not to the programs it starts.
core = os.path.join(sysroot, "usr/lib/git-core")
os.rename(os.path.join(core, "git-remote-http"), os.path.join(core, "git-remote-http.bin"))
for proto in ("http", "https", "ftp", "ftps"):
    helper = os.path.join(core, "git-remote-" + proto)
    if os.path.lexists(helper):
        os.remove(helper)
    with open(helper, "w") as f:
        f.write('#!/bin/sh\nexec /lib/ld-linux-aarch64.so.1 --library-path /mnt/shared/sysroot/usr/lib/devbox-openssl'
                ' --argv0 "$0" /mnt/shared/sysroot/usr/lib/git-core/git-remote-http.bin "$@"\n')
    os.chmod(helper, 0o755)
os.makedirs(os.path.join(sysroot, "etc/ssl/certs"), exist_ok=True)
with open(os.path.join(sysroot, "etc/ssl/certs/ca-certificates.crt"), "wb") as f:
    f.write(b"\n".join(c.strip() + b"\n" for c in bundle))
PY
	for l in libstdc++.so.6 libgcc_s.so.1 libdl.so.2 libpthread.so.0 libutil.so.1 librt.so.1 libcurl-gnutls.so.4; do
		[ -f "$SH/runtime-lib.part/$l" ] || die "$l not found in the Debian packages"
	done
	[ -x "$SH/sysroot.part/usr/bin/git" ] || die "git not found in the Debian packages"
	echo "$DEBS" >"$SH/runtime-lib.part/.debs"
	rm -rf "$SH/runtime-lib" "$SH/sysroot"
	mv "$SH/runtime-lib.part" "$SH/runtime-lib"
	mv "$SH/sysroot.part" "$SH/sysroot"
}

clone_theia() {
	rm -rf "$SH/theia.part"
	git -c advice.detachedHead=false clone -q --depth 1 --branch "$THEIA_VERSION" \
		https://github.com/eclipse-theia/theia.git "$SH/theia.part" || die "git clone of Theia $THEIA_VERSION failed"
}
fetch_theia() {
	[ ! -f "$SH/theia/package.json" ] || return 0
	say "cloning Theia $THEIA_VERSION"
	clone_theia
	rm -rf "$SH/theia"
	mv "$SH/theia.part" "$SH/theia"
}
# The installed Theia: the tag of its checkout
theia_version() { git -C "$SH/theia" describe --tags --exact-match 2>/dev/null || true; }
check_theia_version() {
	have=$(theia_version)
	[ -z "$have" ] || [ "$have" = "$THEIA_VERSION" ] ||
		say "Theia $have is installed, THEIA_VERSION is $THEIA_VERSION: ./vm.sh upgrade-theia builds it"
}
# Replace the installed Theia by THEIA_VERSION: a clean build, as for a new
# devbox. The new checkout is cloned first, so a failed clone changes nothing;
# the running server is stopped before its checkout goes (it loads native
# addons from node_modules there). Settings, home and workspace stay.
cmd_upgrade_theia() {
	have=$(theia_version)
	[ -n "$have" ] || die "no Theia checkout in shared/theia; ./vm.sh start clones $THEIA_VERSION"
	[ "$have" != "$THEIA_VERSION" ] || die "Theia $have is installed; set THEIA_VERSION in devbox.env to the version to build"
	say "replacing Theia $have by $THEIA_VERSION: a new build, about an hour, with the IDE down meanwhile"
	clone_theia
	running=
	[ "$(vm_state)" != started ] || running=1
	[ -z "$running" ] || utm exec "sv stop theia" >"$DOT/exec.log" 2>&1 || die "stopping the Theia service failed (.devbox/exec.log)"
	rm -rf "$SH/theia"
	mv "$SH/theia.part" "$SH/theia"
	rm -f "$LOGS/build/"*.done "$LOGS/build/failed"
	: >"$LOGS/build.log"
	[ -n "$running" ] || { say "the build starts with the next ./vm.sh start"; return 0; }
	utm exec "sv restart theia" >"$DOT/exec.log" 2>&1 || { cat "$DOT/exec.log" >&2; exit 1; }
	cmd_wait
}

# ─── VM ─────────────────────────────────────────────────────────────────────

ensure_vm() {
	fetch_tools
	fetch_node
	fetch_debs
	fetch_theia
	mkdir -p "$SH/workspace" "$LOGS/build" "$STATE"
	[ "$(vm_state)" = "not found" ] || return 0
	if [ -d "$DOT/$NAME.utm" ]; then
		# The bundle is here but UTM forgot it: register it again
		open -g -a UTM "$DOT/$NAME.utm"
		i=0
		until [ "$(vm_state)" != "not found" ]; do
			i=$((i + 1)); [ $i -le 30 ] || die "UTM did not register $DOT/$NAME.utm"
			sleep 1
		done
		return 0
	fi
	say "creating VM $NAME ($IMAGE image, release $VM_RELEASE, $MEM MiB)"
	rm -f "$DOT/dev-disk.img"
	if [ "$IMAGE" = dev ]; then
		fetch_dev_image
		(export KERNEL DISK; utm create) >"$DOT/create.log" || { rm -f "$DISK"; die "VM creation failed (.devbox/create.log)"; }
		rm -f "$DISK"
	else
		utm create >"$DOT/create.log" || die "VM creation failed (.devbox/create.log)"
		TAG=$(VM_REPO=$VM_REPO VM_RELEASE=$VM_RELEASE "$TOOLS/release.sh" tag)
	fi
	echo "$IMAGE $TAG" >"$DOT/image"
}

# The dev image: release.sh fetches only the base image, so the dev kernel
# and disk are downloaded here into release.sh's cache, checked against the
# release's SHA256SUMS-dev. The 8 GB disk is published compressed (.img.xz)
# and unpacked sparse (empty blocks not written) for 'utm create' alone, which
# imports it into the VM bundle; sets TAG, KERNEL and DISK.
fetch_dev_image() {
	TAG=$(VM_REPO=$VM_REPO VM_RELEASE=$VM_RELEASE "$TOOLS/release.sh" tag) || exit 1
	cache=$TOOLS/cache/release/$TAG
	url=https://github.com/$VM_REPO/releases/download/$TAG
	mkdir -p "$cache"
	# edge is replaced on every push to main: refresh its checksums
	if [ "$TAG" = edge ] || [ ! -f "$cache/SHA256SUMS-dev" ]; then
		curl -fsSL -o "$cache/SHA256SUMS-dev.part" "$url/SHA256SUMS-dev" ||
			die "release $TAG has no dev image ($url/SHA256SUMS-dev); IMAGE=base uses the base image"
		mv "$cache/SHA256SUMS-dev.part" "$cache/SHA256SUMS-dev"
	fi
	for f in linux-libre-vmlinuz-dev-arm64 linux-libre-vm-dev-arm64.img.xz; do
		want=$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1 }' "$cache/SHA256SUMS-dev")
		[ -n "$want" ] || die "$f is not in SHA256SUMS-dev of $TAG"
		[ ! -f "$cache/$f" ] || [ "$(sha256 "$cache/$f")" != "$want" ] || continue
		say "downloading $f ($TAG)"
		curl -fL --progress-bar -o "$cache/$f.part" "$url/$f" || die "download failed: $url/$f"
		[ "$(sha256 "$cache/$f.part")" = "$want" ] || { rm -f "$cache/$f.part"; die "checksum mismatch: $f"; }
		mv "$cache/$f.part" "$cache/$f"
	done
	say "unpacking the dev disk image"
	KERNEL=$cache/linux-libre-vmlinuz-dev-arm64
	DISK=$DOT/dev-disk.img
	python3 - "$cache/linux-libre-vm-dev-arm64.img.xz" "$DISK" <<'PY' || { rm -f "$DISK"; die "unpacking the dev disk image failed"; }
import lzma, sys
zero = bytes(1 << 20)
with lzma.open(sys.argv[1]) as src, open(sys.argv[2], "wb") as dst:
    while True:
        b = src.read(1 << 20)
        if not b:
            break
        if b == zero:
            dst.seek(len(b), 1)
        else:
            dst.write(b)
    dst.truncate(dst.tell())
PY
}

# What the guest's boot.sh needs: the user with the Mac user's uid/gid (so
# files in shared/ belong to it on both sides), its password as a SHA-512
# crypt hash, the Node heap size for the build
write_guest_conf() {
	hash=$(DEVBOX_PASSWORD=$DEVBOX_PASSWORD python3 - <<'PY'
import hashlib, os, secrets
def sha512_crypt(key, salt):
    h = hashlib.sha512
    b = h(key + salt + key).digest()
    a = h(key + salt)
    n = len(key)
    while n > 64:
        a.update(b); n -= 64
    a.update(b[:n])
    n = len(key)
    while n:
        a.update(b if n & 1 else key); n >>= 1
    c = a.digest()
    p = (h(key * len(key)).digest() * (len(key) // 64 + 1))[:len(key)]
    s = (h(salt * (16 + c[0])).digest() * (len(salt) // 64 + 1))[:len(salt)]
    for i in range(5000):
        r = h(p if i & 1 else c)
        if i % 3: r.update(s)
        if i % 7: r.update(p)
        r.update(c if i & 1 else p)
        c = r.digest()
    abc = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    out = ""
    for i in range(21):
        x, y, z = (i * 22) % 63, (i * 22 + 21) % 63, (i * 22 + 42) % 63
        w = c[x] << 16 | c[y] << 8 | c[z]
        for _ in range(4):
            out += abc[w & 63]; w >>= 6
    w = c[63]
    out += abc[w & 63] + abc[w >> 6]
    return "$6$%s$%s" % (salt.decode(), out)
salt = "".join(secrets.choice("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") for _ in range(16))
print(sha512_crypt(os.environ["DEVBOX_PASSWORD"].encode(), salt.encode()))
PY
	)
	# A new file renamed over the old one: a VM that is already running (its
	# Theia service reads this at boot) never sees it half written
	cat >"$D/guest.conf.new" <<EOF
# Written by vm.sh on every start; read by the guest scripts
DEVBOX_USER='$DEVBOX_USER'
DEVBOX_UID=$(id -u)
DEVBOX_GID=$(id -g)
DEVBOX_HASH='$hash'
DEVBOX_HOSTNAME='$NAME'
THEIA_PORT=$THEIA_PORT
NODE_HEAP=$((MEM * 3 / 4))
EOF
	chmod 600 "$D/guest.conf.new"
	mv "$D/guest.conf.new" "$D/guest.conf"
}

# On every start, over the serial console as root: set the clock (the guest
# has no RTC and boots at 1970) and run boot.sh
configure_guest() {
	write_guest_conf
	rm -f "$STATE/ip" "$STATE/boot.ok" "$STATE/sshd"
	say "configuring the VM (clock, user, sshd, Theia service)"
	TIMEOUT=180 utm exec "date -u -s @$(date +%s) >/dev/null" "sh /mnt/shared/devbox/boot.sh" \
		>"$DOT/exec.log" 2>&1 || true
	[ -f "$STATE/boot.ok" ] || { tail -20 "$DOT/exec.log" >&2; die "configuring the VM failed (.devbox/exec.log)"; }
}

vm_ip() { cat "$STATE/ip" 2>/dev/null || true; }

theia_up() {
	[ -n "$1" ] && [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$1:$THEIA_PORT/" 2>/dev/null)" = 200 ]
}

build_step() {
	for s in $STEPS; do [ -e "$LOGS/build/$s.done" ] || { echo "$s"; return; }; done
	echo done
}

# LOCAL_PORT: picked once per devbox and appended to devbox.env, so devboxes
# running side by side get different localhost ports
ensure_local_port() {
	[ -z "${LOCAL_PORT:-}" ] || return 0
	LOCAL_PORT=$(python3 -I -c '
import random, socket
for _ in range(200):
    p = random.randint(20000, 29999)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        print(p)
        break
    except OSError:
        pass
    finally:
        s.close()')
	[ -n "$LOCAL_PORT" ] || die "found no free localhost port; set LOCAL_PORT in devbox.env"
	printf '# Mac port forwarded to Theia (picked by vm.sh)\nLOCAL_PORT=%s\n' "$LOCAL_PORT" >>"$HERE/devbox.env"
}

tunnel_pid() {
	p=$(cat "$DOT/tunnel.pid" 2>/dev/null) || return 1
	ps -p "$p" -o command= 2>/dev/null | grep -qi python || return 1
	echo "$p"
}

tunnel_stop() {
	if p=$(tunnel_pid); then kill "$p" 2>/dev/null || true; fi
	rm -f "$DOT/tunnel.pid"
}

# Plain TCP forwarder localhost:LOCAL_PORT -> <VM address>:THEIA_PORT, in the
# background. Webviews need a secure context (service workers) and
# <uuid>.webview.<host> names, which http://localhost gives and an IP does not.
# The VM address is read per connection, so a new address needs no restart.
tunnel_start() {
	ensure_local_port
	tunnel_stop
	nohup python3 -I - "$LOCAL_PORT" "$STATE/ip" "$THEIA_PORT" >"$DOT/tunnel.log" 2>&1 <<-'PY' &
	import asyncio, sys
	port, ipfile, theia_port = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])

	async def pipe(r, w):
	    try:
	        while True:
	            b = await r.read(65536)
	            if not b:
	                break
	            w.write(b)
	            await w.drain()
	        if w.can_write_eof():
	            w.write_eof()
	    except Exception:
	        w.close()

	async def handle(cr, cw):
	    ip = "?"
	    try:
	        ip = open(ipfile).read().strip()
	        ur, uw = await asyncio.wait_for(asyncio.open_connection(ip, theia_port), 10)
	    except Exception as e:
	        # Say why instead of dropping the connection: the browser shows this
	        # ("No route to host" from a running VM: macOS Local Network
	        # privacy, see the README)
	        msg = "vm.sh forwarder: cannot reach Theia at %s:%d: %s\n" % (ip, theia_port, str(e) or "timed out")
	        print(msg, end="", file=sys.stderr, flush=True)
	        cw.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n"
	                 b"Connection: close\r\n\r\n" + msg.encode())
	        try:
	            await cw.drain()
	        finally:
	            cw.close()
	        return
	    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
	    uw.close()
	    cw.close()

	async def main():
	    srv = await asyncio.start_server(handle, "127.0.0.1", port)
	    async with srv:
	        await srv.serve_forever()

	asyncio.run(main())
	PY
	echo $! >"$DOT/tunnel.pid"
	sleep 1
	tunnel_pid >/dev/null || { cat "$DOT/tunnel.log" >&2; die "the localhost forwarder did not start (port $LOCAL_PORT in use? set LOCAL_PORT in devbox.env)"; }
}

show() {
	ip=$(vm_ip)
	[ -n "$ip" ] || { echo "the VM got no network address (try ./vm.sh start again)"; return 0; }
	if theia_up "$ip"; then
		if tunnel_pid >/dev/null; then
			echo "Theia:  http://localhost:$LOCAL_PORT  (http://$ip:$THEIA_PORT works without webviews)"
		else
			echo "Theia:  http://$ip:$THEIA_PORT  (no webviews; for http://localhost: ./vm.sh tunnel)"
		fi
	elif [ -e "$LOGS/build/failed" ]; then
		echo "Theia:  build failed: shared/devbox/logs/build.log; retry: ./vm.sh restart-theia"
	elif [ -e "$LOGS/build/build.done" ]; then
		if tunnel_pid >/dev/null; then url=http://localhost:$LOCAL_PORT; else url=http://$ip:$THEIA_PORT; fi
		echo "Theia:  starting, soon at $url"
	else
		echo "Theia:  building, step '$(build_step)' of: $STEPS (./vm.sh logs; ./vm.sh setup waits)"
	fi
	if [ "$(cat "$STATE/sshd" 2>/dev/null)" = ok ]; then
		echo "SSH:    ssh $DEVBOX_USER@$ip  (password in devbox.env), or ./vm.sh ssh"
	else
		echo "SSH:    not available: release $(ls "$TOOLS/cache/release" 2>/dev/null | tail -1) has no OpenSSH server;"
		echo "        a newer release has it: ./vm.sh recreate"
	fi
}

cmd_start() {
	ensure_vm
	check_theia_version
	if [ "$(vm_state)" != started ]; then
		utm start >"$DOT/start.log" 2>&1 || { cat "$DOT/start.log" >&2; exit 1; }
	fi
	configure_guest
	tunnel_start
	wait_ready
	show
}

# Once Theia is built, it answers about a minute after boot (theia.sh copies
# it to RAM first); wait for that, so the printed address works
wait_ready() {
	[ -e "$LOGS/build/build.done" ] && [ ! -e "$LOGS/build/failed" ] || return 0
	ip=$(vm_ip)
	theia_up "$ip" && return 0
	say "waiting for the Theia IDE to start (about a minute; Ctrl-C stops waiting)"
	trap 'echo; n=60' INT
	n=0
	until theia_up "$ip" || [ $n -ge 60 ]; do sleep 3; n=$((n + 1)); done
	trap - INT
}

cmd_wait() {
	ip=$(vm_ip)
	[ -n "$ip" ] || die "no VM address; run ./vm.sh start"
	trap 'echo; say "stopped waiting; the build goes on in the VM (./vm.sh status)"; exit 130' INT
	n=0
	until theia_up "$ip"; do
		[ ! -e "$LOGS/build/failed" ] ||
			{ tail -5 "$LOGS/build.log" >&2; die "Theia build failed: shared/devbox/logs/; retry: ./vm.sh restart-theia"; }
		if [ -f "$LOGS/build.log" ]; then
			m=$(wc -l <"$LOGS/build.log")
			[ "$m" -le "$n" ] || sed -n "$((n + 1)),${m}p" "$LOGS/build.log"
			n=$m
		fi
		sleep 10
	done
	trap - INT
	show
}

cmd_status() {
	echo "VM:     $NAME, $(vm_state)"
	kind=$IMAGE tag=
	[ ! -f "$DOT/image" ] || read -r kind tag <"$DOT/image" || true
	echo "Image:  $kind${tag:+, release $tag}"
	have=$(theia_version)
	[ -z "$have" ] || echo "IDE:    Theia $have"
	[ "$(vm_state)" = started ] && show || true
}

cmd_ssh() {
	ip=$(vm_ip)
	[ -n "$ip" ] || die "no VM address; run ./vm.sh start"
	exec ssh -o UserKnownHostsFile="$DOT/known_hosts" -o StrictHostKeyChecking=accept-new \
		"$DEVBOX_USER@$ip" "$@"
}

cmd=${1:-help}
[ $# -gt 0 ] && shift
case $cmd in
start)    cmd_start ;;
setup)    cmd_start; cmd_wait ;;
wait)     cmd_wait ;;
status)   cmd_status ;;
ip)       vm_ip ;;
ssh)      cmd_ssh "$@" ;;
logs)     touch "$LOGS/build.log" "$LOGS/theia.log"; exec tail -F "$LOGS/build.log" "$LOGS/theia.log" ;;
tunnel)   if [ "${1:-}" = stop ]; then tunnel_stop
          else
            [ "$(vm_state)" = started ] || die "the VM is $(vm_state); ./vm.sh start boots it and starts the forwarder"
            tunnel_start; show
          fi ;;
stop)     tunnel_stop
          # utm stop cuts the power: flush the VM's disk first
          [ "$(vm_state)" != started ] || TIMEOUT=20 utm exec sync >/dev/null 2>&1 || true
          utm stop ;;
pause)    [ "$(vm_state)" = started ] || die "the VM is $(vm_state), not running"
          "$UTMCTL" suspend "$NAME" >/dev/null
          say "paused (./vm.sh resume continues it)" ;;
resume)   [ "$(vm_state)" = paused ] || die "the VM is $(vm_state), not paused"
          "$UTMCTL" start "$NAME" >/dev/null
          # The guest clock stood still while paused
          TIMEOUT=20 utm exec "date -u -s @$(date +%s) >/dev/null" >"$DOT/exec.log" 2>&1 || true
          tunnel_start; show ;;
console)  utm console "$@" ;;
exec)     utm exec "$@" ;;
restart-theia)
          utm exec "rm -f /mnt/shared/devbox/logs/build/failed" "sv restart theia" >"$DOT/exec.log" 2>&1 ||
            { cat "$DOT/exec.log" >&2; exit 1; }
          say "Theia service restarted" ;;
delete)   tunnel_stop; utm delete; rm -f "$DOT/known_hosts" "$STATE/ip" ;;
recreate) [ "$(vm_state)" = "not found" ] || utm delete
          rm -f "$DOT/known_hosts"
          cmd_start ;;
update-tools) fetch_tools force ;;
upgrade-theia) cmd_upgrade_theia ;;
help | -h | --help) sed -n '/^set -eu/q;2,$p' "$0" | sed 's/^# \{0,1\}//' ;;
*)        sed -n '/^set -eu/q;2,$p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
VMSH
chmod 755 vm.sh

# ─── guest scripts (shared/devbox) ──────────────────────────────────────────
mkdir -p shared/devbox shared/workspace

cat >shared/devbox/boot.sh <<'EOF'
#!/bin/sh
# Run as root by vm.sh on every start (serial console), after it set the
# clock: hostname, the devbox user, password login for OpenSSH and the runit
# service for Theia. Idempotent; reports to /mnt/shared/devbox/state/.
set -eu
PATH=/bin
D=/mnt/shared/devbox
. $D/guest.conf
U=$DEVBOX_USER
S=$D/state
mkdir -p $S

echo "$DEVBOX_HOSTNAME" >/etc/hostname
echo "$DEVBOX_HOSTNAME" >/proc/sys/kernel/hostname
sed -i "s/^127\.0\.1\.1 .*/127.0.1.1  $DEVBOX_HOSTNAME/" /etc/hosts

# npm scripts start with #!/usr/bin/env node; the image has /bin/env only
mkdir -p /usr/bin
[ -e /usr/bin/env ] || ln -s /bin/env /usr/bin/env

# Libraries the image lacks (vm.sh fetch_debs) into /lib, so every program
# finds them: node, git, and prebuilt binaries tools install over ssh
# (Claude Code's CLI links librt, libpthread, libdl)
for l in /mnt/shared/runtime-lib/*; do
	[ -e /lib/${l##*/} ] || cp $l /lib/
done

# git and less (vm.sh fetch_debs) stay in the share: their programs linked
# into /bin, git's helpers and templates where it looks for them. CA bundle
# for HTTPS (git's libcurl-gnutls reads /etc/ssl/certs/ca-certificates.crt)
X=/mnt/shared/sysroot
for f in $X/usr/bin/*; do
	b=/bin/${f##*/}
	[ -e $b ] && [ ! -L $b ] || ln -sfn $f $b
done
# Debian's git runs 'pager' (Debian's alternatives name) unless told otherwise
[ -e /bin/pager ] && [ ! -L /bin/pager ] || ln -sfn less /bin/pager
mkdir -p /usr/lib /usr/share /etc/ssl/certs
ln -sfn $X/usr/lib/git-core /usr/lib/git-core
ln -sfn $X/usr/share/git-core /usr/share/git-core
cp $X/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# put FILE MODE: replace FILE with FILE.new, renamed into place and only when
# it differs, so a power-off never leaves a half-written FILE
put() {
	if cmp -s $1.new $1; then rm $1.new; else chmod $2 $1.new; mv $1.new $1; fi
}
# A power-off right after an earlier write can leave NUL bytes in these
# files; in front of the user's line they hide the user (chpst, sshd: unknown
# user). Drop them; 'awk 1' also ends the last line.
for f in passwd:644 shadow:600 group:644; do
	tr -d '\000' </etc/${f%:*} | awk 1 >/etc/${f%:*}.new
	put /etc/${f%:*} ${f#*:}
done
# The user has the Mac user's uid/gid: files in shared/ are its own
if ! awk -F: -v g="$DEVBOX_GID" '$3 == g { f = 1 } END { exit !f }' /etc/group; then
	{ cat /etc/group; echo "$U:x:$DEVBOX_GID:"; } >/etc/group.new
	put /etc/group 644
fi
# Home in the shared folder: the root disk is 256 MB, and tools install
# themselves under ~ (Claude Code's and VS Code's ssh servers, npm -g).
# /home/$U links to it; a home left on the root disk is moved over.
H=/mnt/shared/home/$U
{ grep -v "^$U:" /etc/passwd; echo "$U:x:$DEVBOX_UID:$DEVBOX_GID:devbox:$H:/bin/bash"; } >/etc/passwd.new
put /etc/passwd 644
{ grep -v "^$U:" /etc/shadow; echo "$U:$DEVBOX_HASH:20000:0:99999:7:::"; } >/etc/shadow.new
put /etc/shadow 600
mkdir -p $H
if [ -d /home/$U ] && [ ! -L /home/$U ]; then
	# -P: absolute symlinks as they are; otherwise tar first writes a mode 000
	# placeholder, which the share cannot open again
	(cd /home/$U && tar -cf - .) | (cd $H && tar -xPf - --no-same-owner)
	rm -rf /home/$U
fi
ln -sfn $H /home/$U
# Login shells read .bash_profile; non-login ones (Theia's terminal) read
# .bashrc, 'ssh host CMD' reads $BASH_ENV (see sshd below)
[ -e $H/.bashrc ] || echo ". /mnt/shared/devbox/env.sh" >$H/.bashrc
[ -e $H/.bash_profile ] || echo ". ~/.bashrc" >$H/.bash_profile
ln -sfn /mnt/shared/workspace $H/workspace
# The share cannot hold Unix sockets: Claude Code's remote server (socket in
# ~/.claude/remote/run) pointed at the runtime dir on tmpfs (runtime.sh)
sh $D/runtime.sh
mkdir -p $H/.claude/remote
[ -L $H/.claude/remote/run ] || rm -rf $H/.claude/remote/run
ln -sfn /run/user/$DEVBOX_UID/claude-remote $H/.claude/remote/run
# Theia watches ~/.theia recursively (settings.json) while its plugin host
# deletes old session folders in ~/.theia/logs; a folder vanishing during the
# watcher's crawl fails the whole watch ("Unable to watch for file changes in
# this large workspace"). The watcher does not follow symlinks, so the logs
# live in the runtime dir.
mkdir -p $H/.theia
[ -L $H/.theia/logs ] || rm -rf $H/.theia/logs
ln -sfn /run/user/$DEVBOX_UID/theia-logs $H/.theia/logs

# OpenSSH: password login (root stays key-only)
if [ -x /bin/sshd ] && [ -f /etc/ssh/sshd_config ]; then
	sed -i 's/^#\{0,1\}PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
	grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config ||
		echo 'PasswordAuthentication yes' >>/etc/ssh/sshd_config
	# 'ssh host CMD' runs a non-interactive bash, which reads no startup file
	# but $BASH_ENV. A Match block must come last: drop ours, append it again
	sed -i '/^# devbox begin$/,/^# devbox end$/d' /etc/ssh/sshd_config
	printf '# devbox begin\nMatch User %s\n\tSetEnv BASH_ENV=/mnt/shared/devbox/env.sh\n# devbox end\n' \
		"$U" >>/etc/ssh/sshd_config
	sv restart sshd >/dev/null 2>&1 || true
	echo ok >$S/sshd
else
	echo missing >$S/sshd
fi

# Theia: runit service, run as the user. Defined in /etc/sv and linked into
# /etc/service, so runsvdir never sees a half-written service. It runs
# runtime.sh as root first: runit starts it on every boot, also one that
# vm.sh did not start (the UTM app, a reboot in the VM)
mkdir -p /etc/sv/theia
cat >/etc/sv/theia/run.new <<RUN
#!/bin/sh
# Eclipse Theia (written by /mnt/shared/devbox/boot.sh)
/bin/sh /mnt/shared/devbox/runtime.sh
exec /bin/chpst -u $U /bin/sh /mnt/shared/devbox/theia.sh
RUN
chmod 755 /etc/sv/theia/run.new
if cmp -s /etc/sv/theia/run.new /etc/sv/theia/run; then
	rm /etc/sv/theia/run.new
else
	mv /etc/sv/theia/run.new /etc/sv/theia/run
	[ ! -d /etc/sv/theia/supervise ] || sv restart theia >/dev/null 2>&1 || true
fi
[ -e /etc/service/theia ] || ln -s /etc/sv/theia /etc/service/theia

# Clock: the system clock stands still while the Mac sleeps or the VM is
# paused; the RTC (QEMU's PL031) follows the Mac's clock. Set the system
# clock from it when they are more than 2 s apart (the RTC counts whole
# seconds, so a smaller step could set the clock back)
mkdir -p /etc/sv/clock
cat >/etc/sv/clock/run.new <<'RUN'
#!/bin/sh
# Keeps the system clock at the RTC (written by /mnt/shared/devbox/boot.sh)
while :; do
	r=$(cat /sys/class/rtc/rtc0/since_epoch) && d=$((r - $(date +%s))) &&
		{ [ $d -ge -2 ] && [ $d -le 2 ] || date -u -s @$r >/dev/null; }
	sleep 30
done
RUN
chmod 755 /etc/sv/clock/run.new
if cmp -s /etc/sv/clock/run.new /etc/sv/clock/run; then
	rm /etc/sv/clock/run.new
else
	mv /etc/sv/clock/run.new /etc/sv/clock/run
	[ ! -d /etc/sv/clock/supervise ] || sv restart clock >/dev/null 2>&1 || true
fi
[ -e /etc/service/clock ] || ln -s /etc/sv/clock /etc/service/clock

# Address from UTM's DHCP
i=0
until ip -4 -o addr show dev eth0 2>/dev/null | grep -q ' inet '; do
	i=$((i + 1)); [ $i -lt 60 ] || break
	sleep 1
done
ip -4 -o addr show dev eth0 | awk '{ sub("/.*", "", $4); print $4; exit }' >$S/ip
# './vm.sh stop' and UTM's stop button cut the power: write it all to disk now
sync
touch $S/boot.ok
EOF

cat >shared/devbox/runtime.sh <<'EOF'
#!/bin/sh
# Run as root on every boot (the theia service's run script) and by boot.sh:
# the tmpfs parts of the devbox, which a reboot empties. Idempotent.
PATH=/bin
. /mnt/shared/devbox/guest.conf

# RAM disk for the Theia IDE and Node.js (theia.sh copies them there): the
# share answers every file access with a round trip to the Mac, hundreds of
# times slower than tmpfs for the IDE's thousands of small files. Unlike
# /dev/shm it allows running programs.
mkdir -p /opt/devbox
mountpoint -q /opt/devbox || mount -t tmpfs -o size=2g,mode=755 tmpfs /opt/devbox
chown $DEVBOX_UID:$DEVBOX_GID /opt/devbox

# Runtime dir ($XDG_RUNTIME_DIR) for sockets, which the share cannot hold;
# claude-remote and theia-logs are the targets of ~/.claude/remote/run and
# ~/.theia/logs (boot.sh)
R=/run/user/$DEVBOX_UID
mkdir -p $R/claude-remote $R/theia-logs
chown -R $DEVBOX_UID:$DEVBOX_GID $R
chmod 700 $R
EOF

cat >shared/devbox/env.sh <<'EOF'
# Environment of the devbox user: Theia's build and server, login shells
# (~/.bash_profile, ~/.bashrc, $BASH_ENV for ssh). Node.js comes from its RAM
# copy (theia.sh), until that exists from the shared folder; the libraries it
# needs are copied to /lib by boot.sh. npm cache and temp files live in the
# shared folder (the base image's root disk is 256 MB). No Node heap size
# here: every Node process (the IDE, its extension host, language servers,
# the user's tools) keeps V8's default; only build.sh raises it.
SH=/mnt/shared
. $SH/devbox/guest.conf
# /usr/bin last: the dev image's toolchain (gcc, make, perl, Python) and its
# own Node.js, behind the devbox's
export PATH=/opt/devbox/node/bin:$SH/node/bin:/bin:/usr/bin
export HOME=$SH/home/$DEVBOX_USER USER=$DEVBOX_USER LOGNAME=$DEVBOX_USER SHELL=/bin/bash
# Sockets cannot live on the share; boot.sh creates this tmpfs dir
export XDG_RUNTIME_DIR=/run/user/$DEVBOX_UID
export npm_config_cache=$SH/.cache/npm TMPDIR=$SH/.cache/tmp
# No Chrome download for puppeteer (Theia's tests only)
export PUPPETEER_SKIP_DOWNLOAD=1
# Nx (inside lerna) keeps a SQLite DB, whose locking fails on 9p
export NX_DISABLE_DB=true NX_DAEMON=false NX_WORKSPACE_DATA_DIRECTORY=/dev/shm/nx
mkdir -p "$npm_config_cache" "$TMPDIR"
EOF

cat >shared/devbox/theia.sh <<'EOF'
#!/bin/sh
# Eclipse Theia server, run as the devbox user by the runit service "theia"
# (boot.sh). Builds Theia first when that is not done yet (build.sh), then
# runs it from a RAM copy.
. /mnt/shared/devbox/env.sh
L=$SH/devbox/logs
R=/opt/devbox
mkdir -p "$L/build" "$SH/workspace"
# A sane clock (HTTPS for the build needs it; the kernel reads the VM's RTC,
# and vm.sh start sets it too) and the RAM disk (runtime.sh)
until [ "$(date +%s)" -gt 1700000000 ] && mountpoint -q $R; do sleep 5; done
if [ ! -e "$L/build/build.done" ]; then
	if ! sh "$SH/devbox/build.sh" >>"$L/build.log" 2>&1; then
		# Keep runit from restarting the build in a loop; vm.sh restart-theia retries
		touch "$L/build/failed"
		exec sleep infinity
	fi
fi
# node-pty ships a prebuilt linux-arm64 addon; the bundle's loader looks for
# it next to lib/backend
B=$SH/theia/examples/browser/lib/backend/prebuilds/linux-arm64
[ -e "$B/pty.node" ] ||
	{ mkdir -p "$B"; cp "$SH/theia/node_modules/node-pty/prebuilds/linux-arm64/pty.node" "$B/"; }
# RAM copy of what the server reads: its bundled code (lib/), the plugins and
# the node binary. Copied again after a rebuild; node_modules stays in the
# share (at run time the server only loads @parcel/watcher's addon from it).
# The share costs about 25 ms per file but reads large files at about
# 16 MB/s, so the plugins (4,600 files) are packed once into plugins.tar.
P=$SH/theia/plugins.tar
stamp="$(stat -c %Y "$L/build/build.done" "$SH/node/bin/node" | tr '\n' ' ')"
if [ "$(cat $R/.stamp 2>/dev/null)" != "$stamp" ]; then
	s=$(date +%s)
	if [ ! "$P" -nt "$L/build/build.done" ]; then
		echo "packing the plugins into $P (once after a build)"
		tar -cf "$P.new" -C $SH/theia plugins
		mv "$P.new" "$P"
	fi
	echo "copying the Theia IDE and Node.js to RAM ($R)"
	rm -rf $R/node $R/theia $R/.stamp
	mkdir -p $R/node/bin $R/theia/sample-plugins
	cp $SH/node/bin/node $R/node/bin/
	tar -xf "$P" -C $R/theia
	(cd $SH/theia && tar -cf - examples/browser examples/ovsx-router-config.json) | tar -xf - -C $R/theia
	ln -s $SH/theia/node_modules $R/theia/node_modules
	echo "$stamp" >$R/.stamp
	echo "copied in $(($(date +%s) - s)) s"
fi >"$L/theia.log" 2>&1
# Extensions built on Volar (Astro, Vue, MDX) look for TypeScript where VS
# Code ships it, <appRoot>/extensions/node_modules/typescript; Theia's appRoot
# is examples/browser. Link the copy the built-in TypeScript plugin bundles
X=$R/theia/examples/browser/extensions/node_modules
[ -e $X/typescript ] || { mkdir -p $X &&
	ln -sfn $R/theia/plugins/vscode.typescript-language-features/extension/deps/typescript $X/typescript; }
cd $R/theia/examples/browser
exec $R/node/bin/node -r "$SH/devbox/native-stubs.js" lib/backend/main.js "$SH/workspace" \
	--hostname=0.0.0.0 --port="$THEIA_PORT" --log-config=log-config.json \
	--plugins=local-dir:$R/theia/plugins --ovsx-router-config=../ovsx-router-config.json \
	>>"$L/theia.log" 2>&1
EOF

cat >shared/devbox/build.sh <<'EOF'
#!/bin/sh
# Build Theia's browser example and download its extensions, without native
# addons (the image has no compiler). Run by theia.sh. Each finished step
# leaves logs/build/<step>.done, so a rerun resumes; delete one to redo that
# step. Step output: logs/build/<step>.log
set -eu
. /mnt/shared/devbox/env.sh
# tsc on the ~90 @theia/* packages and webpack need a large heap: 3/4 of the
# VM's RAM, for this build only (the IDE runs with V8's default)
export NODE_OPTIONS=--max-old-space-size=$NODE_HEAP
L=$SH/devbox/logs/build
mkdir -p "$L"
rm -f "$L/failed"
cd "$SH/theia"

step() {
	name=$1; shift
	[ ! -e "$L/$name.done" ] || return 0
	echo "== $name: started $(date -u +%T)"
	start=$(date +%s)
	if "$@" >"$L/$name.log" 2>&1; then
		touch "$L/$name.done"
		echo "== $name: ok in $(( $(date +%s) - start ))s"
	else
		echo "== $name: FAILED after $(( $(date +%s) - start ))s, see shared/devbox/logs/build/$name.log"
		tail -30 "$L/$name.log"
		exit 1
	fi
}

# --ignore-scripts: no node-gyp, so node-pty, drivelist and keytar stay
# unbuilt (node-pty has a prebuilt addon, the others are stubbed in
# native-stubs.js). Prebuilt platform packages (esbuild, @parcel/watcher,
# ripgrep, nx) need no scripts.
step install npm ci --ignore-scripts --no-audit --no-fund
# The devbox's defaults (AI features, telemetry, Java extension off), set in
# the checkout before the bundle and the extensions are built
step configure node "$SH/devbox/theia-config.js"
# The root postinstall that --ignore-scripts skipped: pure JS
step postinstall npm run postinstall
step compile npx lerna run compile --concurrency 1
# 'npm run build' would also run 'theia rebuild:browser' (native modules)
step bundle sh -c 'cd examples/browser && npx theia build --mode production'
# Extensions from Open VSX into theia/plugins
step plugins npm run download:plugins
touch "$L/build.done"
echo "== build done $(date -u +%T)"
EOF

cat >shared/devbox/theia-config.js <<'EOF'
// The devbox's defaults for the Theia IDE, applied by build.sh (step
// "configure") in the Theia checkout, before the bundle and the extensions
// are built:
//  - AI features off: the AI chat, agents and completion stay inert until
//    "ai-features.AiEnable.enableAI" is turned on in the settings
//  - telemetry off: Theia's own and the telemetry API of extensions
//  - no Java extension: Java syntax highlighting (vscode.java), the only Java
//    extension of the IDE, is not installed
// The preferences are defaults: the user's settings.json overrides them.
const fs = require('fs');

function edit(file, change) {
    const json = JSON.parse(fs.readFileSync(file, 'utf8'));
    change(json);
    fs.writeFileSync(file, JSON.stringify(json, null, 2) + '\n');
}

edit('examples/browser/package.json', json => {
    Object.assign(json.theia.frontend.config.preferences, {
        'ai-features.AiEnable.enableAI': false,
        'telemetry.telemetryLevel': 'off'
    });
});

edit('package.json', json => {
    const excluded = json.theiaPluginsExcludeIds;
    for (const id of ['vscode.java']) {
        if (!excluded.includes(id)) {
            excluded.push(id);
        }
    }
});
EOF
cat >shared/devbox/native-stubs.js <<'EOF'
// Preloaded with `node -r`: stand-ins for native addons that were not built
// (npm ci --ignore-scripts, no compiler in the image).
//  - drivelist: on Linux it lists drives with lsblk; the addon is only used
//    on macOS/Windows, so an empty list is enough.
//  - keytar: credential store, kept in memory (secrets are lost on restart).
const Module = require('module');

const drivelist = { list: cb => cb(null, []) };

const store = new Map();
const key = (service, account) => service + '\0' + account;
const keytar = {
    getPassword: async (s, a) => store.get(key(s, a)) ?? null,
    setPassword: async (s, a, p) => { store.set(key(s, a), p); },
    deletePassword: async (s, a) => store.delete(key(s, a)),
    findPassword: async s => {
        for (const [k, p] of store) { if (k.startsWith(s + '\0')) { return p; } }
        return null;
    },
    findCredentials: async s => [...store]
        .filter(([k]) => k.startsWith(s + '\0'))
        .map(([k, password]) => ({ account: k.slice(s.length + 1), password }))
};

const stubs = { 'drivelist.node': drivelist, 'keytar.node': keytar };
const load = Module._load;
Module._load = function (request, ...rest) {
    const stub = stubs[request.split('/').pop()];
    return stub ?? load.call(this, request, ...rest);
};
EOF

echo "linux-devbox-vm.sh: wrote vm.sh, devbox.env and shared/ in $DIR"
exec ./vm.sh setup
