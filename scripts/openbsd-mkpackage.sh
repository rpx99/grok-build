#!/bin/sh
#
# Baut das OpenBSD-Paket grok-build-X.Y.Z.tgz aus dem lokalen Repo-Stand -
# komplett OHNE root (alles Landet unter ~/.grok-ports und openbsd-port/
# im Repo). Nur die optionale Installation mit pkg_add braucht doas.
#
# Aufruf bei einem neuen Release:
#   ./scripts/openbsd-mkpackage.sh --check    # neuer Commit auf xai-org/grok-build?
#   git fetch upstream && git rebase upstream/main   # xAI-Sync holen (nicht git pull)
#   ./scripts/openbsd-mkpackage.sh            # nur bauen
#   ./scripts/openbsd-mkpackage.sh -i         # bauen + installieren
#   ./scripts/openbsd-mkpackage.sh -p         # bauen + committen + auf Fork pushen
#   ./scripts/openbsd-mkpackage.sh -ip        # alles zusammen
#   ./scripts/openbsd-mkpackage.sh -i 1.0.9   # Version explizit vorgeben
#
# Ueberschreibbar per Env: GROK_PORTS_BASE, DISTDIR, WRKOBJDIR,
# PACKAGE_REPOSITORY (oder historisch PACKAGES), PLIST_REPOSITORY, PORTTREE,
# PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL, DRY_RUN=1
set -eu

DRY=${DRY_RUN:-0}
MAINTAINER=${MAINTAINER:-Your Name <you@example.invalid>}
INSTALL_AFTER=0
PUSH_AFTER=0
FORK_URL=${FORK_URL:-}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/xai-org/grok-build.git}

run() {
	if [ "$DRY" = 1 ]; then echo "[dry] $*"; else "$@"; fi
}

usage() {
	cat <<EOF
usage: $(basename "$0") [-h] [--check] [-i] [-p] [-ip] [VERSION]

Baut grok-build-VERSION.tgz aus dem lokalen Repo-Stand - ohne root.
Nur die optionale Installation mit pkg_add braucht doas.

Optionen:
  -h, --help   diese Hilfe
  --check      neuen xAI-Sync pruefen (upstream/main, nicht der Fork)
  -i           nach dem Bau mit pkg_add installieren
  -p           nach dem Bau committen und auf den Fork pushen
  -ip, -pi     -i und -p zusammen
  VERSION      z.B. 1.0.10 (sonst aus Cargo.toml)

Umgebung:
  DRY_RUN=1              nur anzeigen, nichts schreiben
  REVISION=0             Ports-REVISION (Paket 1.0.10p0). Leer = erste
                         Ausgabe dieser Cargo-Version. Ungesetzt = auto
                         (naechstes pN wenn Tag vVERSION-openbsd existiert)
  GROK_PORTS_BASE        Default: ~/.grok-ports
  DISTDIR, WRKOBJDIR, PACKAGE_REPOSITORY, PLIST_REPOSITORY
  PORTTREE, PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL

Beispiele:
  $0                 nur bauen
  $0 -i              bauen und installieren
  $0 --check
  $0 -i 1.0.8
EOF
}

ver_of() {
	awk '/^version/ {gsub(/"/, "", $3); print $3; exit}' "$1"
}

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
	|| { echo "FEHLER: nicht in einem Git-Repository"; exit 1; }

BASE=${GROK_PORTS_BASE:-$HOME/.grok-ports}
DISTDIR=${DISTDIR:-$BASE/distfiles}
WRKOBJDIR=${WRKOBJDIR:-$BASE/wrk}
PACKAGE_REPOSITORY=${PACKAGE_REPOSITORY:-${PACKAGES:-$BASE/packages}}
PLIST_REPOSITORY=${PLIST_REPOSITORY:-$BASE/plist}
PORTSDIR=${PORTSDIR:-/usr/ports}
# User-eigener Ports-Baum im "mystuff"-Stil: <tree>/devel/grok-build,
# wird per PORTSDIR_PATH vor /usr/ports durchsucht.
PORTTREE=${PORTTREE:-$REPO/openbsd-port}

MODE=build
V_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)	usage; exit 0 ;;
	--check)	MODE=check ;;
	-i)		INSTALL_AFTER=1 ;;
	-p)		PUSH_AFTER=1 ;;
	-ip|-pi)	INSTALL_AFTER=1; PUSH_AFTER=1 ;;
	-.*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	-*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	*)		V_OVERRIDE=$1 ;;
	esac
	shift
done

V=${V_OVERRIDE:-$(ver_of "$REPO/crates/codegen/xai-grok-pager-bin/Cargo.toml")}
[ -n "$V" ] || { echo "FEHLER: Version nicht ermittelbar (Parameter angeben)"; exit 1; }

# Same Cargo version, new xAI dump: OpenBSD REVISION (1.0.10 -> 1.0.10p0).
# Tag vX.Y.Z-openbsd is the first package; vX.Y.Z-openbsd.1 is p0, .2 is p1.
PKG_REVISION=""
if [ "${REVISION+x}" = x ]; then
	PKG_REVISION=$REVISION
else
	git -C "$REPO" fetch origin --tags >/dev/null 2>&1 || true
	if git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd" >/dev/null 2>&1; then
		n=0
		while git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd.$((n + 1))" >/dev/null 2>&1; do
			n=$((n + 1))
		done
		PKG_REVISION=$n
	fi
fi
if [ -z "$PKG_REVISION" ]; then
	FULLPKG="grok-build-$V"
	GH_TAG="v${V}-openbsd"
else
	FULLPKG="grok-build-${V}p${PKG_REVISION}"
	GH_TAG="v${V}-openbsd.$((PKG_REVISION + 1))"
fi

if [ "$MODE" = check ]; then
	# origin is the fork. New xAI syncs land on upstream/main.
	if ! git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
		git -C "$REPO" remote add upstream "$UPSTREAM_URL"
	fi
	git -C "$REPO" fetch upstream main >/dev/null 2>&1 \
		|| { echo "FEHLER: git fetch upstream fehlgeschlagen (Netz?)"; exit 1; }
	CARGO=crates/codegen/xai-grok-pager-bin/Cargo.toml
	LV=$(ver_of "$REPO/$CARGO")
	RV=$(git -C "$REPO" show "upstream/main:$CARGO" \
		| awk '/^version/ {gsub(/"/, "", $3); print $3; exit}')
	HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
	UP_SHA=$(git -C "$REPO" rev-parse upstream/main)
	BASE_SHA=$(git -C "$REPO" merge-base HEAD upstream/main)
	echo "lokal    : $LV ($(git -C "$REPO" rev-parse --short HEAD))"
	echo "xAI/main : $RV ($(git -C "$REPO" rev-parse --short upstream/main))"
	O=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null || true)
	if [ -n "$O" ]; then
		echo "Fork     : $O (origin, nicht die Sync-Quelle)"
	fi
	if [ "$UP_SHA" = "$BASE_SHA" ]; then
		echo "==> kein neuer xAI-Sync: upstream/main steckt bereits in HEAD."
	else
		N=$(git -C "$REPO" rev-list --count "$BASE_SHA".."$UP_SHA")
		echo "==> $N neuer xAI-Commit(s) auf upstream/main (nicht in HEAD):"
		git -C "$REPO" --no-pager log --oneline -15 "$BASE_SHA".."$UP_SHA"
		if [ "$N" -gt 15 ]; then
			echo "    ... ($N insgesamt)"
		fi
		if [ "$LV" = "$RV" ]; then
			echo "==> Cargo-Version bleibt $RV (xAI bumpt nicht bei jedem Sync)."
			LSR=$(git -C "$REPO" show HEAD:SOURCE_REV 2>/dev/null | tr -d '\n' || true)
			USR=$(git -C "$REPO" show upstream/main:SOURCE_REV 2>/dev/null | tr -d '\n' || true)
			if [ -n "$LSR" ] && [ -n "$USR" ] && [ "$LSR" != "$USR" ]; then
				echo "    SOURCE_REV lokal    : $LSR"
				echo "    SOURCE_REV xAI/main : $USR"
			fi
		else
			echo "==> Cargo-Version $LV -> $RV"
		fi
		echo "Dann (nicht git pull — origin ist der Fork):"
		echo "    git fetch upstream && git rebase upstream/main"
		echo "    $0"
	fi
	exit 0
fi

for tool in git rustc protoc pkg-config make awk grep pax; do
	command -v "$tool" >/dev/null || { echo "FEHLER: '$tool' fehlt"; exit 1; }
done
[ -d "$PORTSDIR" ] || { echo "FEHLER: $PORTSDIR existiert nicht (ports(7))"; exit 1; }

echo "==> Version: $V${PKG_REVISION:+p$PKG_REVISION}  (GitHub-Tag $GH_TAG)"
echo "==> Verzeichnisse: PORTTREE=$PORTTREE DISTDIR=$DISTDIR"

# 1. Quell-Tarball aus dem lokalen Stand (inkl. uncommitteter Aenderungen;
#    Kern-Dumps und Paket-Metadaten-Reste ausschliessen)
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT INT TERM
(cd "$REPO" && git ls-files -co --exclude-standard \
	| grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$' \
	| while IFS= read -r file; do
		if [ -e "$file" ] || [ -L "$file" ]; then
			printf '%s\n' "$file"
		fi
	done) >"$LIST"

# Ein Dry-Run darf weder den Workdir loeschen noch die eingecheckten
# Port-Metadaten ueberschreiben oder leeren.
if [ "$DRY" = 1 ]; then
	echo "[dry] pax -w -z -f $DISTDIR/grok-build-$V.tar.gz  (< Dateiliste, Prefix grok-build-$V/)"
	echo "[dry] Port-Skelett unter $PORTTREE/devel/grok-build erzeugen"
	echo "[dry] modcargo-gen-crates, makesum und package ausfuehren"
	exit 0
fi

# Alte Build-Reste wegwerfen: Extraktion muss IMMER dem aktuellen Tarball
# entsprechen (Cookie-Timestamps truegen sonst bei geaendertem Inhalt).
rm -rf "${WRKOBJDIR:?}/grok-build-$V"

mkdir -p "$DISTDIR"
if [ "$DRY" = 1 ]; then
	echo "[dry] pax -w -z -f $DISTDIR/grok-build-$V.tar.gz  (< Dateiliste, Prefix grok-build-$V/)"
else
	(cd "$REPO" && pax -w -z -x ustar -s ",^,grok-build-$V/," -f "$DISTDIR/grok-build-$V.tar.gz" <"$LIST")
fi

# 2. Port-Skelett schreiben (im Repo, user-eigen, Kategorie-Layout)
PORTDIR="$PORTTREE/devel/grok-build"
mkdir -p "$PORTDIR/pkg" "$PORTDIR/files"

cat >"$PORTDIR/files/fix-execonly.pl" <<'EOF'
#!/usr/bin/perl
# Mark execute-only PT_LOAD segments as readable (PF_R|PF_X).
# rustc/lld on OpenBSD amd64 emit PF_X-only .text; aws-lc-sys s2n-bignum
# stores constants there, so a load SIGSEGVs. No-op if already R+E.
use strict;
use warnings;

my $path = shift or die "usage: $0 <elf>\n";
open my $f, '+<', $path or die "$path: $!\n";
binmode $f;
read($f, my $ehdr, 64) == 64 or die "$path: short ELF header\n";
my $magic = substr($ehdr, 0, 4);
die "$path: not ELF\n" unless $magic eq "\x7fELF";
my $phoff     = unpack('Q', substr($ehdr, 32, 8));
my $phentsize = unpack('v', substr($ehdr, 54, 2));
my $phnum     = unpack('v', substr($ehdr, 56, 2));
my $n = 0;
for (my $i = 0; $i < $phnum; $i++) {
	seek $f, $phoff + $i * $phentsize, 0 or die $!;
	read($f, my $ph, $phentsize) == $phentsize or die "$path: short PHDR\n";
	my ($type, $flags) = unpack('VV', $ph);
	next unless $type == 1 && $flags == 1;    # PT_LOAD && PF_X
	substr($ph, 4, 4) = pack('V', 5);         # PF_R|PF_X
	seek $f, $phoff + $i * $phentsize, 0 or die $!;
	print $f $ph;
	$n++;
}
print STDERR "$path: marked $n execute-only PT_LOAD segment(s) readable\n";
EOF


REVISION_LINE=""
if [ -n "$PKG_REVISION" ]; then
	REVISION_LINE="REVISION =	$PKG_REVISION"
fi

cat >"$PORTDIR/Makefile" <<EOF
COMMENT =	SpaceXAI terminal AI coding agent (grok)
V =		$V
$REVISION_LINE
DISTNAME =	grok-build-\${V}
DISTFILES =	\${DISTNAME}\${EXTRACT_SUFX}
PKGNAME =	grok-build-\${V}
CATEGORIES =	devel
HOMEPAGE =	https://github.com/xai-org/grok-build
MAINTAINER =	$MAINTAINER

# Apache-2.0
PERMIT_PACKAGE =	Yes

WANTLIB +=	\${COMPILER_LIBCXX} c crypto git2 llhttp m onig pcre2-8
WANTLIB +=	pthread sqlite3 ssh2 ssl util z zstd
COMPILER =	base-clang

BUILD_DEPENDS +=	textproc/ripgrep
RUN_DEPENDS +=	x11/xclip
LIB_DEPENDS +=	archivers/zstd \
		databases/sqlite3 \
		devel/libgit2/libgit2 \
		devel/pcre2 \
		security/libssh2 \
		textproc/oniguruma \
		www/llhttp
MAKE_ENV +=	GROK_TOOLS_BUNDLE_RG_PATH=\${LOCALBASE}/bin/rg \
		GROK_SHELL_BUNDLE_RG_PATH=\${LOCALBASE}/bin/rg \
		GROK_VERSION=\${V} \
		LIBGIT2_NO_VENDOR=1 \
		LIBRARY_PATH=\${LOCALBASE}/lib \
		PKG_CONFIG_PATH=\${LOCALBASE}/lib/pkgconfig

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
MODCARGO_BUILD_ARGS =	--bin xai-grok-pager
.include "crates.inc"

do-install:
	\${INSTALL_PROGRAM} \${MODCARGO_TARGET_DIR}/release/xai-grok-pager \${PREFIX}/bin/grok
	perl \${FILESDIR}/fix-execonly.pl \${PREFIX}/bin/grok

# aws-lc-sys / s2n-bignum stores constants in .text. OpenBSD amd64 maps
# .text execute-only, which SIGSEGVs in curve25519_x25519base. rustc
# goes through cc(1), so the flag must be -Wl,--no-execute-only.
# AWS_LC_SYS_NO_ASM is not usable here: it forces the cmake builder and
# panics on release (OPT_LEVEL != 0). Same workaround as devel/codex.
.if \${MACHINE_ARCH} == "amd64"
USE_NOEXECONLY =	Yes
.endif
MODCARGO_RUSTFLAGS +=	-Clink-arg=-Wl,--no-execute-only
# zstd-sys emits -lzstd without -L (pkg-config search path dropped). rustc
# then fails linking xai-grok-tools' build.rs: "unable to find library -lzstd".
MODCARGO_RUSTFLAGS +=	-Lnative=\${LOCALBASE}/lib
.include <bsd.port.mk>
EOF

cat >"$PORTDIR/pkg/DESCR" <<'EOF'
Grok Build is SpaceXAI's terminal-based AI coding agent: a fullscreen TUI
that understands a codebase, edits files, runs shell commands, searches
the web and manages long-running tasks - interactively, headlessly or
embedded in editors via ACP.

Native OpenBSD source build of github.com/xai-org/grok-build.
Authenticate with "grok login" or set XAI_API_KEY. State lives under
~/.grok/.

This package is not managed by the xAI CDN auto-updater (official
stable can lag the git tag). Use this port for upgrades, not
`grok update`. Copy uses xclip(1) (RUN_DEPENDS). Default login.conf
caps open files at 1024; grok raises the process soft limit toward
that (or 8192 if the login class allows). It does not edit
login.conf. To go higher, add a login class with openfiles-cur/max=8192.
xAI may ship a new monorepo dump under the same Cargo version; those
rebuilds use REVISION (1.0.10p0) and grok --version shows SOURCE_REV.
EOF

cat >"$PORTDIR/pkg/PLIST" <<'EOF'
@comment \$OpenBSD\$
@owner root
@group bin
@bin bin/grok
EOF

: >"$PORTDIR/crates.inc"
# distinfo ebenfalls wegwerfen: es referenziert die alten Cargo-Eintraege,
# die die (noch leere) Liste bei NO_CHECKSUM als "Extra file" meldet.
rm -f "$PORTDIR/distinfo"

# 3. Port-Mechanik - alle Schreibpfade liegen beim Nutzer, kein root noetig.
#    Variablen als MAKE-ARGUMENTE: Kommandozeile schlaegt auch /etc/mk.conf.
MKVARS="PORTSDIR=$PORTSDIR PORTSDIR_PATH=$PORTTREE:$PORTSDIR:$PORTSDIR/mystuff WRKOBJDIR=$WRKOBJDIR LOCKDIR=$BASE/locks DISTDIR=$DISTDIR PACKAGE_REPOSITORY=$PACKAGE_REPOSITORY PLIST_REPOSITORY=$PLIST_REPOSITORY"
mkdir -p "$BASE/locks" "$PLIST_REPOSITORY"

# 3b. Crate-Liste aus Cargo.lock generieren (erster Lauf ohne Checksummen),
#     dann laedt makesum alle Crates und schreibt die Pruefsummen.
cd "$PORTDIR"
if [ "$DRY" = 1 ]; then
	echo "[dry] make ... modcargo-gen-crates -> crates.inc"
else
	make $MKVARS modcargo-gen-crates NO_CHECKSUM=Yes >"$LIST"
	grep '^MODCARGO_CRATES' "$LIST" >"$PORTDIR/crates.inc"
	[ -s "$PORTDIR/crates.inc" ] \
		|| { echo "FEHLER: keine Crates in Cargo.lock erkannt"; exit 1; }
	echo "==> crates.inc: $(grep -c . "$PORTDIR/crates.inc") Crates"
fi
run make $MKVARS makesum
echo "==> distinfo: $(grep -c 'SHA256' "$PORTDIR/distinfo" 2>/dev/null || echo 0) Checksummen"
# Crates sind jetzt komplett da -> Workdir verwerfen, damit das folgende
# 'package' sie frisch extrahiert (sonst leert der alte Cookie den Vendor-Dir).
# Das vorhandene .tgz IST der Ports-Cookie (_PACKAGE_COOKIE): ohne Loeschen
# macht 'make package' nur "Link to .../ftp/..." und baut nicht neu.
rm -rf "${WRKOBJDIR:?}/grok-build-$V"
if [ "$DRY" != 1 ] && [ -d "$PACKAGE_REPOSITORY" ]; then
	find "$PACKAGE_REPOSITORY" -name "$FULLPKG.tgz" -print -delete
fi
run make $MKVARS package

PKG=""
for f in "$PACKAGE_REPOSITORY"/*/all/"$FULLPKG".tgz; do
	if [ -f "$f" ]; then
		PKG=$f
		break
	fi
done
if [ -z "$PKG" ] && [ "$DRY" != 1 ]; then
	echo "FEHLER: fertiges Paket nicht gefunden (make-Ausgabe oben pruefen)"; exit 1
fi

echo "==> Paket: ${PKG:-<dry-run>}"
echo "==> GitHub-Tag: $GH_TAG"

# 4. Optional: Stand committen und auf den eigenen Fork pushen
if [ "$PUSH_AFTER" = 1 ] && [ "$DRY" != 1 ]; then
	cd "$REPO"
	# Remotes sicherstellen: origin=Fork, upstream=xai-org. Ein vorhandenes
	# origin, das nicht xai-org ist, gilt als Fork und braucht kein FORK_URL.
	if ORIGIN_URL=$(git remote get-url origin 2>/dev/null); then
		case "$ORIGIN_URL" in
		*github.com/xai-org/grok-build*)
			if git remote get-url upstream >/dev/null 2>&1; then
				[ -n "$FORK_URL" ] || {
					echo "FEHLER: origin zeigt auf xai-org; FORK_URL fuer den eigenen Fork setzen." >&2
					exit 1
				}
				git remote set-url origin "$FORK_URL"
			else
				git remote rename origin upstream
				ORIGIN_URL=""
			fi
			;;
		esac
	else
		ORIGIN_URL=""
	fi
	if ! git remote get-url origin >/dev/null 2>&1; then
		[ -n "$FORK_URL" ] || {
			echo "FEHLER: kein Fork als origin; FORK_URL setzen." >&2
			exit 1
		}
		git remote add origin "$FORK_URL"
	fi
	FORK_URL=$(git remote get-url origin)
	git remote get-url upstream >/dev/null 2>&1 \
		|| git remote add upstream "$UPSTREAM_URL"

	# Alles Uncommittete rein (ausser Kern-Dumps/Paket-Reste)
	if ! git diff --quiet HEAD || ! git diff --cached --quiet HEAD \
		|| [ -n "$(git ls-files --others --exclude-standard | grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$')" ]; then
		git add -A -- . ':(exclude)*.core' ':(exclude)+*' 2>/dev/null || git add -A
		git commit -m "OpenBSD port support (grok-build $V)

- cfg-Gates: nono-Sandbox/jemalloc auf linux|macos, audio auf linux|macos|windows
- mid-Machine-ID target-gegate mit UUIDv4-Fallback
- Git-Deps async-openai + nucleo nach third_party/ vendored
- openbsd-port/-Skeleton und Paketbau-Skript (ports(7), ohne root)"
	else
		echo "==> Keine Aenderungen zu committen."
	fi
	echo "==> Push auf $FORK_URL ..."
	if ! git push origin main; then
		echo "HINWEIS: Push fehlgeschlagen. Fork anlegen und als origin konfigurieren:" >&2
		echo "  git remote set-url origin <URL-DES-EIGENEN-FORKS>" >&2
	fi
fi

# 5. Optional installieren - pkg_add ist Systemverwaltung und braucht doas.
#    -u interpretiert Argumente als installierte PaketNAMEN, nicht als
#    Dateipfad. -r ersetzt das vorhandene Paket, -D unsigned erlaubt das
#    unsignierte Lokal-tgz, -D updatedepends toleriert Ports-Index vs.
#    installierte Abhaengigkeitsversionen (libgit2/llhttp Snapshot-Lag).
if [ "$INSTALL_AFTER" = 1 ] && [ "$DRY" != 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		pkg_add -r -D unsigned -D updatedepends "$PKG"
	else
		if command -v doas >/dev/null 2>&1; then
			doas pkg_add -r -D unsigned -D updatedepends "$PKG"
		else
			sudo pkg_add -r -D unsigned -D updatedepends "$PKG"
		fi
	fi
else
	echo "==> Installieren (nicht -u mit Dateipfad!):"
	echo "    doas pkg_add -r -D unsigned -D updatedepends $PKG"
fi
