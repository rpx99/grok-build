#!/bin/sh
#
# Baut das OpenBSD-Paket grok-build-X.Y.Z.tgz aus dem lokalen Repo-Stand -
# komplett OHNE root (alles Landet unter ~/.grok-ports und openbsd-port/
# im Repo). Nur die optionale Installation mit pkg_add braucht doas.
#
# Aufruf bei einem neuen Release:
#   ./scripts/openbsd-mkpackage.sh --check    # ist ein neuer xAI-Sync da?
#   git pull                                  # dann holen
#   ./scripts/openbsd-mkpackage.sh            # nur bauen
#   ./scripts/openbsd-mkpackage.sh -i         # bauen + installieren
#   ./scripts/openbsd-mkpackage.sh -p         # bauen + committen + auf Fork pushen
#   ./scripts/openbsd-mkpackage.sh -ip        # alles zusammen
#   ./scripts/openbsd-mkpackage.sh -i 1.0.9   # Version explizit vorgeben
#
# Ueberschreibbar per Env: GROK_PORTS_BASE, DISTDIR, WRKOBJDIR, PACKAGES,
# PORTDIR, PORTSDIR, MAINTAINER, DRY_RUN=1
set -eu

DRY=${DRY_RUN:-0}
MAINTAINER=${MAINTAINER:-Your Name <you@example.invalid>}
INSTALL_AFTER=0
PUSH_AFTER=0
FORK_URL=https://github.com/rpx99/grok-build.git
UPSTREAM_URL=https://github.com/xai-org/grok-build.git

run() {
	if [ "$DRY" = 1 ]; then echo "[dry] $*"; else "$@"; fi
}

ver_of() {
	awk '/^version/ {gsub(/"/, "", $3); print $3; exit}' "$1"
}

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
	|| { echo "FEHLER: nicht in einem Git-Repository"; exit 1; }

BASE=${GROK_PORTS_BASE:-$HOME/.grok-ports}
DISTDIR=${DISTDIR:-$BASE/distfiles}
WRKOBJDIR=${WRKOBJDIR:-$BASE/wrk}
PACKAGES=${PACKAGES:-$BASE/packages}
PORTSDIR=${PORTSDIR:-/usr/ports}
# User-eigener Ports-Baum im "mystuff"-Stil: <tree>/devel/grok-build,
# wird per PORTSDIR_PATH vor /usr/ports durchsucht.
PORTTREE=${PORTTREE:-$REPO/openbsd-port}

MODE=build
V_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--check)	MODE=check ;;
	-i)		INSTALL_AFTER=1 ;;
	-p)		PUSH_AFTER=1 ;;
	-ip|-pi)	INSTALL_AFTER=1; PUSH_AFTER=1 ;;
	-.*)		echo "FEHLER: unbekannte Option '$1'"; exit 1 ;;
	-*)		echo "FEHLER: unbekannte Option '$1'"; exit 1 ;;
	*)		V_OVERRIDE=$1 ;;
	esac
	shift
done

V=${1:-$(ver_of "$REPO/crates/codegen/xai-grok-pager-bin/Cargo.toml")}
[ -n "$V" ] || { echo "FEHLER: Version nicht ermittelbar (Parameter angeben)"; exit 1; }

for tool in git rustc protoc pkg-config make awk grep pax; do
	command -v "$tool" >/dev/null || { echo "FEHLER: '$tool' fehlt"; exit 1; }
done
[ -d "$PORTSDIR" ] || { echo "FEHLER: $PORTSDIR existiert nicht (ports(7))"; exit 1; }

if [ "$MODE" = check ]; then
	git -C "$REPO" fetch origin main >/dev/null 2>&1 \
		|| { echo "FEHLER: git fetch fehlgeschlagen (Netz?)"; exit 1; }
	LV=$(ver_of "$REPO/crates/codegen/xai-grok-pager-bin/Cargo.toml")
	RV=$(git -C "$REPO" show origin/main:crates/codegen/xai-grok-pager-bin/Cargo.toml \
		| awk '/^version/ {gsub(/"/, "", $3); print $3; exit}')
	echo "lokal : $LV ($(git -C "$REPO" rev-parse --short HEAD))"
	echo "remote: $RV ($(git -C "$REPO" rev-parse --short origin/main))"
	if [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ]; then
		echo "==> auf neuestem Sync-Stand, nichts zu tun."
	else
		echo "==> neuer xAI-Sync verfuegbar! Dann:"
		echo "    git pull && $0 -i"
	fi
	exit 0
fi

echo "==> Version: $V"
echo "==> Verzeichnisse: PORTTREE=$PORTTREE DISTDIR=$DISTDIR"

# 1. Quell-Tarball aus dem lokalen Stand (inkl. uncommitteter Aenderungen;
#    Kern-Dumps und Paket-Metadaten-Reste ausschliessen)
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT INT TERM
(cd "$REPO" && git ls-files -co --exclude-standard \
	| grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$') >"$LIST"

# Alte Build-Reste wegwerfen: Extraktion muss IMMER dem aktuellen Tarball
# entsprechen (Cookie-Timestamps truegen sonst bei geaendertem Inhalt).
rm -rf "${WRKOBJDIR:?}/grok-build-$V"

mkdir -p "$DISTDIR"
if [ "$DRY" = 1 ]; then
	echo "[dry] pax -w -z -f $DISTDIR/grok-build-$V.tar.gz  (< Dateiliste)"
else
	(cd "$REPO" && pax -w -z -x ustar -f "$DISTDIR/grok-build-$V.tar.gz" <"$LIST")
fi

# 2. Port-Skelett schreiben (im Repo, user-eigen, Kategorie-Layout)
PORTDIR="$PORTTREE/devel/grok-build"
mkdir -p "$PORTDIR/pkg"

cat >"$PORTDIR/Makefile" <<EOF
COMMENT =	SpaceXAI terminal AI coding agent (grok)
V =		$V
DISTNAME =	grok-build-\${V}
PKGNAME =	grok-build-\${V}
CATEGORIES =	devel
HOMEPAGE =	https://github.com/xai-org/grok-build
MAINTAINER =	$MAINTAINER

# Apache-2.0
PERMIT_PACKAGE =	Yes

# Tarball enthaelt keinen Top-Level-Ordner -> direkt im WRKDIR bauen
WRKSRC =	\${WRKDIR}

WANTLIB +=	\${COMPILER_LIBCXX} c m pthread util z
COMPILER =	base-clang

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
MODCARGO_BUILD_ARGS =	--bin xai-grok-pager
.include "crates.inc"

do-install:
	\${INSTALL_PROGRAM} \${MODCARGO_TARGET_DIR}/release/xai-grok-pager \${PREFIX}/bin/grok

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
EOF

cat >"$PORTDIR/pkg/PLIST" <<'EOF'
@comment \$OpenBSD\$
@bin bin/grok
EOF

: >"$PORTDIR/crates.inc"

# 3. Port-Mechanik - alle Schreibpfade liegen beim Nutzer, kein root noetig.
#    Variablen als MAKE-ARGUMENTE: Kommandozeile schlaegt auch /etc/mk.conf.
MKVARS="PORTSDIR=$PORTSDIR PORTSDIR_PATH=$PORTTREE:$PORTSDIR:$PORTSDIR/mystuff WRKOBJDIR=$WRKOBJDIR LOCKDIR=$BASE/locks DISTDIR=$DISTDIR PACKAGES=$PACKAGES"
mkdir -p "$BASE/locks"

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
fi
run make $MKVARS makesum
# Crates sind jetzt komplett da -> Workdir verwerfen, damit das folgende
# 'package' sie frisch extrahiert (sonst leert der alte Cookie den Vendor-Dir)
rm -rf "${WRKOBJDIR:?}/grok-build-$V"
run make $MKVARS package

PKG=$(ls -t "$PACKAGES"/*/grok-build-"$V".tgz 2>/dev/null | head -1 || true)
if [ -z "$PKG" ] && [ "$DRY" != 1 ]; then
	echo "FEHLER: fertiges Paket nicht gefunden (make-Ausgabe oben pruefen)"; exit 1
fi

echo "==> Paket: ${PKG:-<dry-run>}"

# 4. Optional: Stand committen und auf den eigenen Fork pushen
if [ "$PUSH_AFTER" = 1 ] && [ "$DRY" != 1 ]; then
	cd "$REPO"
	# Remotes sicherstellen: origin=Fork, upstream=xai-org
	if git remote get-url origin >/dev/null 2>&1; then
		case "$(git remote get-url origin)" in
		*rpx99/grok-build*)	: ;;
		*)	git remote get-url upstream >/dev/null 2>&1 \
				|| git remote rename origin upstream ;;
		esac
	fi
	git remote get-url origin >/dev/null 2>&1 \
		|| git remote add origin "$FORK_URL"
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
		echo "HINWEIS: Push fehlgeschlagen. Fork existiert? Einmalig anlegen:" >&2
		echo "  https://github.com/xai-org/grok-build/fork  (Account rpx99 waehlen)" >&2
	fi
fi

# 5. Optional installieren - pkg_add ist Systemverwaltung und braucht doas
if [ "$INSTALL_AFTER" = 1 ] && [ "$DRY" != 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		pkg_add -Ur -D unsigned "$PKG"
	else
		if command -v doas >/dev/null 2>&1; then
			doas pkg_add -Ur -D unsigned "$PKG"
		else
			sudo pkg_add -Ur -D unsigned "$PKG"
		fi
	fi
fi
