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
#      http://<VM address>:3000 and the ssh command
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
#   MEM / CPUS       RAM in MiB / cores    (default: 8192 / 1; the Theia
#                    build needs several GB, the kernel has no SMP)
#   VM_RELEASE       image release tag     (default: latest)
#   THEIA_VERSION    Theia git tag         (default: v1.76.0)
#   NODE_VERSION     Node.js version       (default: 24.21.0)
#   THEIA_PORT       Theia port            (default: 3000)
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
if /Applications/UTM.app/Contents/MacOS/utmctl status "$NAME" >/dev/null 2>&1; then
	die "UTM already has a VM named '$NAME'; choose another one with NAME=..."
fi

# ─── devbox.env ─────────────────────────────────────────────────────────────
cat >devbox.env <<EOF
# devbox settings, read by vm.sh (written by linux-devbox-vm.sh).
# DEVBOX_USER / DEVBOX_PASSWORD / THEIA_PORT apply on the next './vm.sh start';
# MEM, CPUS and VM_RELEASE on './vm.sh recreate'.
NAME='$NAME'
DEVBOX_USER='$DEVBOX_USER'
DEVBOX_PASSWORD='$DEVBOX_PASSWORD'
MEM=${MEM:-8192}
CPUS=${CPUS:-1}
VM_RELEASE='${VM_RELEASE:-latest}'
THEIA_VERSION='${THEIA_VERSION:-v1.76.0}'
NODE_VERSION='${NODE_VERSION:-24.21.0}'
THEIA_PORT=${THEIA_PORT:-3000}
VM_REPO='${VM_REPO:-stan-kondrat/linux-libre-vm}'
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
#   ./vm.sh logs          follow the Theia build and server logs
#   ./vm.sh stop | console | exec CMD...
#   ./vm.sh restart-theia restart the Theia service (also retries a failed build)
#   ./vm.sh recreate      new VM disk from the release (VM_RELEASE); shared/ is
#                         kept, so Theia is not built again
#   ./vm.sh delete        delete the VM (keeps shared/)
#   ./vm.sh update-tools  download the newest runner scripts (vm/utm.sh ...)
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
DOT=$HERE/.devbox
TOOLS=$DOT/tools/vm
SH=$HERE/shared
D=$SH/devbox
LOGS=$D/logs
STATE=$D/state
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
STEPS="install postinstall compile bundle plugins"

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

fetch_theia() {
	[ ! -f "$SH/theia/package.json" ] || return 0
	say "cloning Theia $THEIA_VERSION"
	rm -rf "$SH/theia.part"
	git -c advice.detachedHead=false clone -q --depth 1 --branch "$THEIA_VERSION" \
		https://github.com/eclipse-theia/theia.git "$SH/theia.part" || die "git clone of Theia $THEIA_VERSION failed"
	rm -rf "$SH/theia"
	mv "$SH/theia.part" "$SH/theia"
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
	say "creating VM $NAME (release $VM_RELEASE, $MEM MiB)"
	utm create >"$DOT/create.log" || die "VM creation failed (.devbox/create.log)"
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
	cat >"$D/guest.conf" <<EOF
# Written by vm.sh on every start; read by the guest scripts
DEVBOX_USER='$DEVBOX_USER'
DEVBOX_UID=$(id -u)
DEVBOX_GID=$(id -g)
DEVBOX_HASH='$hash'
DEVBOX_HOSTNAME='$NAME'
THEIA_PORT=$THEIA_PORT
NODE_HEAP=$((MEM * 3 / 4))
EOF
	chmod 600 "$D/guest.conf"
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

show() {
	ip=$(vm_ip)
	[ -n "$ip" ] || { echo "the VM got no network address (try ./vm.sh start again)"; return 0; }
	if theia_up "$ip"; then
		echo "Theia:  http://$ip:$THEIA_PORT"
	elif [ -e "$LOGS/build/failed" ]; then
		echo "Theia:  build failed: shared/devbox/logs/build.log; retry: ./vm.sh restart-theia"
	elif [ -e "$LOGS/build/build.done" ]; then
		echo "Theia:  starting, soon at http://$ip:$THEIA_PORT"
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
	if [ "$(vm_state)" != started ]; then
		utm start >"$DOT/start.log" 2>&1 || { cat "$DOT/start.log" >&2; exit 1; }
	fi
	configure_guest
	show
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
stop)     utm stop ;;
console)  utm console "$@" ;;
exec)     utm exec "$@" ;;
restart-theia)
          utm exec "rm -f /mnt/shared/devbox/logs/build/failed" "sv restart theia" >"$DOT/exec.log" 2>&1 ||
            { cat "$DOT/exec.log" >&2; exit 1; }
          say "Theia service restarted" ;;
delete)   utm delete; rm -f "$DOT/known_hosts" "$STATE/ip" ;;
recreate) [ "$(vm_state)" = "not found" ] || utm delete
          rm -f "$DOT/known_hosts"
          cmd_start ;;
update-tools) fetch_tools force ;;
help | -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
*)        sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
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

# The user has the Mac user's uid/gid: files in shared/ are its own
awk -F: -v g="$DEVBOX_GID" '$3 == g { f = 1 } END { exit !f }' /etc/group ||
	echo "$U:x:$DEVBOX_GID:" >>/etc/group
# Home in the shared folder: the root disk is 256 MB, and tools install
# themselves under ~ (Claude Code's and VS Code's ssh servers, npm -g).
# /home/$U links to it; a home left on the root disk is moved over.
H=/mnt/shared/home/$U
sed -i "/^$U:/d" /etc/passwd /etc/shadow
echo "$U:x:$DEVBOX_UID:$DEVBOX_GID:devbox:$H:/bin/bash" >>/etc/passwd
echo "$U:$DEVBOX_HASH:20000:0:99999:7:::" >>/etc/shadow
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
# The share cannot hold Unix sockets: a runtime dir on tmpfs, and Claude
# Code's remote server (socket in ~/.claude/remote/run) pointed at it
R=/run/user/$DEVBOX_UID
mkdir -p $R/claude-remote
chown -R $DEVBOX_UID:$DEVBOX_GID $R
chmod 700 $R
mkdir -p $H/.claude/remote
[ -L $H/.claude/remote/run ] || rm -rf $H/.claude/remote/run
ln -sfn $R/claude-remote $H/.claude/remote/run

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

# RAM disk for the Theia IDE and Node.js (theia.sh copies them there): the
# share answers every file access with a round trip to the Mac, hundreds of
# times slower than tmpfs for the IDE's thousands of small files. Unlike
# /dev/shm it allows running programs.
mkdir -p /opt/devbox
mountpoint -q /opt/devbox || mount -t tmpfs -o size=2g,mode=755 tmpfs /opt/devbox
chown $DEVBOX_UID:$DEVBOX_GID /opt/devbox

# Theia: runit service, run as the user. Defined in /etc/sv and linked into
# /etc/service, so runsvdir never sees a half-written service
mkdir -p /etc/sv/theia
cat >/etc/sv/theia/run.new <<RUN
#!/bin/sh
# Eclipse Theia (written by /mnt/shared/devbox/boot.sh)
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

# Address from UTM's DHCP
i=0
until ip -4 -o addr show dev eth0 2>/dev/null | grep -q ' inet '; do
	i=$((i + 1)); [ $i -lt 60 ] || break
	sleep 1
done
ip -4 -o addr show dev eth0 | awk '{ sub("/.*", "", $4); print $4; exit }' >$S/ip
touch $S/boot.ok
EOF

cat >shared/devbox/env.sh <<'EOF'
# Environment of the devbox user: Theia's build and server, login shells
# (~/.bash_profile, ~/.bashrc, $BASH_ENV for ssh). Node.js comes from its RAM
# copy (theia.sh), until that exists from the shared folder; the libraries it
# needs are copied to /lib by boot.sh. npm cache and temp files live in the
# shared folder (the root disk is 256 MB).
SH=/mnt/shared
. $SH/devbox/guest.conf
export PATH=/opt/devbox/node/bin:$SH/node/bin:/bin
export HOME=$SH/home/$DEVBOX_USER USER=$DEVBOX_USER LOGNAME=$DEVBOX_USER SHELL=/bin/bash
# Sockets cannot live on the share; boot.sh creates this tmpfs dir
export XDG_RUNTIME_DIR=/run/user/$DEVBOX_UID
export npm_config_cache=$SH/.cache/npm TMPDIR=$SH/.cache/tmp
export NODE_OPTIONS=--max-old-space-size=$NODE_HEAP
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
# Wait for vm.sh start: it sets the clock (the VM boots at 1970, and HTTPS
# needs the right time), then boot.sh mounts the RAM disk
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
# Node.js. Copied again after a rebuild; node_modules stays in the share (at
# run time the server only loads @parcel/watcher's addon from it).
stamp="$(stat -c %Y "$L/build/build.done" "$SH/node/bin/node" | tr '\n' ' ')"
if [ "$(cat $R/.stamp 2>/dev/null)" != "$stamp" ]; then
	echo "copying the Theia IDE and Node.js to RAM ($R)"
	rm -rf $R/node $R/theia $R/.stamp
	mkdir -p $R/theia/sample-plugins
	(cd $SH && tar -cf - node) | tar -xf - -C $R
	(cd $SH/theia && tar -cf - plugins examples/browser examples/ovsx-router-config.json) | tar -xf - -C $R/theia
	ln -s $SH/theia/node_modules $R/theia/node_modules
	echo "$stamp" >$R/.stamp
fi >"$L/theia.log" 2>&1
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
