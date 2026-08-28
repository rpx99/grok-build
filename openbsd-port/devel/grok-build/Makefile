COMMENT =	SpaceXAI terminal AI coding agent (grok)
V =		1.0.10
REVISION =	0
DISTNAME =	grok-build-${V}
DISTFILES =	${DISTNAME}${EXTRACT_SUFX}
PKGNAME =	grok-build-${V}
CATEGORIES =	devel
HOMEPAGE =	https://github.com/xai-org/grok-build
MAINTAINER =	Your Name <you@example.invalid>

# Apache-2.0
PERMIT_PACKAGE =	Yes

WANTLIB +=	${COMPILER_LIBCXX} c crypto git2 llhttp m onig pcre2-8
WANTLIB +=	pthread sqlite3 ssh2 ssl util z zstd
COMPILER =	base-clang

BUILD_DEPENDS +=	textproc/ripgrep
RUN_DEPENDS +=	x11/xclip
LIB_DEPENDS +=	archivers/zstd 		databases/sqlite3 		devel/libgit2/libgit2 		devel/pcre2 		security/libssh2 		textproc/oniguruma 		www/llhttp
MAKE_ENV +=	GROK_TOOLS_BUNDLE_RG_PATH=${LOCALBASE}/bin/rg 		GROK_SHELL_BUNDLE_RG_PATH=${LOCALBASE}/bin/rg 		GROK_VERSION=${V} 		LIBGIT2_NO_VENDOR=1

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
MODCARGO_BUILD_ARGS =	--bin xai-grok-pager
.include "crates.inc"

do-install:
	${INSTALL_PROGRAM} ${MODCARGO_TARGET_DIR}/release/xai-grok-pager ${PREFIX}/bin/grok
	perl ${FILESDIR}/fix-execonly.pl ${PREFIX}/bin/grok

# aws-lc-sys / s2n-bignum stores constants in .text. OpenBSD amd64 maps
# .text execute-only, which SIGSEGVs in curve25519_x25519base. rustc
# goes through cc(1), so the flag must be -Wl,--no-execute-only.
# AWS_LC_SYS_NO_ASM is not usable here: it forces the cmake builder and
# panics on release (OPT_LEVEL != 0). Same workaround as devel/codex.
.if ${MACHINE_ARCH} == "amd64"
USE_NOEXECONLY =	Yes
.endif
MODCARGO_RUSTFLAGS +=	-Clink-arg=-Wl,--no-execute-only
.include <bsd.port.mk>
