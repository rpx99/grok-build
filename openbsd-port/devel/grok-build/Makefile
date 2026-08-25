COMMENT =	SpaceXAI terminal AI coding agent (grok)
V =		1.0.8
DISTNAME =	grok-build-${V}
PKGNAME =	grok-build-${V}
CATEGORIES =	devel
HOMEPAGE =	https://github.com/xai-org/grok-build
MAINTAINER =	Your Name <you@example.invalid>

# Apache-2.0
PERMIT_PACKAGE =	Yes

# Tarball enthaelt keinen Top-Level-Ordner -> direkt im WRKDIR bauen
WRKSRC =	${WRKDIR}

WANTLIB +=	${COMPILER_LIBCXX} c m pthread util z
COMPILER =	base-clang

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
MODCARGO_BUILD_ARGS =	--bin xai-grok-pager
.include "crates.inc"

do-install:
	${INSTALL_PROGRAM} ${MODCARGO_TARGET_DIR}/release/xai-grok-pager ${PREFIX}/bin/grok

.include <bsd.port.mk>
