# Grok Build auf OpenBSD

Dieses Verzeichnis enthaelt den lokalen OpenBSD-Port. Das Skript
`scripts/openbsd-mkpackage.sh` baut daraus ein Paket, optional installiert es
das Paket und kann die erzeugten Port-Metadaten auf den eigenen Fork pushen.

## Remotes

Die erwartete Zuordnung ist:

- `origin`: der eigene Fork
- `upstream`: `https://github.com/xai-org/grok-build.git`

Vor dem ersten Release die Zuordnung kontrollieren:

```sh
git remote -v
```

Fehlt `upstream`, kann er explizit ergänzt werden. `--check` erledigt dies
ebenfalls automatisch:

```sh
git remote add upstream https://github.com/xai-org/grok-build.git
```

Wenn kein `origin` vorhanden ist, kann dessen URL vor einem Push gesetzt werden:

```sh
git remote add origin git@github.com:DEIN-NAME/grok-build.git
```

Alternativ akzeptiert das Paket-Skript `FORK_URL` und `UPSTREAM_URL` als
Umgebungsvariablen. `FORK_URL` muss nicht bei jedem Aufruf angegeben werden:
Wenn `origin` bereits auf den eigenen Fork zeigt, verwendet das Skript diese
gespeicherte URL automatisch.

## Neuer xAI-Stand

`--check` holt lediglich den aktuellen Stand von `upstream/main` und zeigt an,
ob neue Commits vorhanden sind. Es veraendert den lokalen Branch nicht.

```sh
./scripts/openbsd-mkpackage.sh --check
```

Vor dem Rebase muss der Arbeitsbaum sauber sein. Lokale Aenderungen daher
zuerst committen oder staschen. Anschliessend den xAI-Stand uebernehmen:

```sh
git fetch upstream
git rebase upstream/main
```

Bei Konflikten die betroffenen Dateien korrigieren, mit `git add` markieren und
das Rebase fortsetzen:

```sh
git rebase --continue
```

Danach sollte `--check` melden, dass `upstream/main` bereits in `HEAD` steckt:

```sh
./scripts/openbsd-mkpackage.sh --check
```

## Paket bauen

Das Skript baut immer den aktuellen lokalen Stand. Es synchronisiert den Branch
nicht automatisch.

```sh
DRY_RUN=1 ./scripts/openbsd-mkpackage.sh  # Ablauf ohne Paketbau pruefen
./scripts/openbsd-mkpackage.sh            # nur bauen
./scripts/openbsd-mkpackage.sh -i         # bauen und installieren
./scripts/openbsd-mkpackage.sh -p         # bauen, committen und zum Fork pushen
./scripts/openbsd-mkpackage.sh -ip        # bauen, installieren und pushen
```

Nur die Installation mit `pkg_add` benoetigt `doas`. Build-Dateien und Pakete
landen standardmaessig unter `$HOME/.grok-ports`; der Port selbst liegt unter
`openbsd-port/devel/grok-build`. Die Pfade lassen sich unter anderem mit
`GROK_PORTS_BASE`, `DISTDIR`, `WRKOBJDIR`, `PACKAGE_REPOSITORY`, `PORTTREE` und
`PORTSDIR` ueberschreiben. Eine vollstaendige Liste zeigt:

```sh
./scripts/openbsd-mkpackage.sh --help
```
