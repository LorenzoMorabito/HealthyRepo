# Repository Health Framework

Framework PowerShell + GitHub Actions per monitorare la salute Git di una repository, con focus su repository Power BI `PBIP` ma riusabile anche in altri contesti testuali versionati.

## Obiettivi

- prevenire il repository bloat
- tracciare la crescita Git nel tempo
- rilevare file vietati e pattern rischiosi
- storicizzare metriche auditabili e diffabili
- fornire insight locali e in CI senza introdurre dipendenze pesanti

## Modello di prodotto

`HealthyRepo` e sia la repo sorgente del framework sia la sorgente dei package distribuiti.

Il modello supportato e:

- repo sorgente `HealthyRepo`
- release versionate `vX.Y.Z`
- package zip del runtime/install kit
- installer che puo installare da source, da zip o da `-Version`
- consumer che installa una versione precisa e la committa nella propria repo

## Quick start locale

In repo standalone, dalla root di `repository-health`:

```powershell
./analyzer.ps1 -Mode local
```

Per analizzare una repo esterna in modo esplicito:

```powershell
./analyzer.ps1 `
  -Mode local `
  -RepoRootPath C:\path\to\target-repo
```

Check bloccante:

```powershell
./analyzer.ps1 `
  -Mode local `
  -FailOnThresholdBreach
```

Audit completo:

```powershell
./analyzer.ps1 `
  -Mode schedule `
  -EnableGitSizer
```

## Distribuzione del prodotto

Build del package:

```powershell
./distribution/Build-RepoHealthPackage.ps1
```

Installazione del framework in una repo target da source:

```powershell
./distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo
```

Installazione di una versione precisa:

```powershell
./distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo `
  -Version 0.4.0
```

Guida operativa:

- [RUNBOOK.md](./RUNBOOK.md)
- [distribution/README.md](./distribution/README.md)

## Output

Output runtime locali:

- `outputs/current/metrics.json`
- `outputs/current/summary.md`
- `outputs/current/dashboard.html`
- `outputs/current/git-sizer.txt` quando abilitato e disponibile

Storico runtime locale:

- `outputs/history/latest.json`
- `outputs/history/metrics-history.csv`
- `outputs/history/top-files-history.csv`
- `outputs/history/runs/*.json`
- `outputs/history/runs/*.md`

Nota:

- `dashboard.html` e un artefatto derivato locale/CI
- la source of truth storica e nei file `JSON/CSV/MD/TXT`

## Cosa monitora

- `size-pack`
- oggetti Git totali
- numero pack
- dimensione `.git`
- file tracciati
- numero commit
- largest blob storico
- blob sopra `1 MB` e `5 MB`
- largest current file
- file vietati nel working tree
- crescita dei `top N` file rispetto al baseline precedente

## Configurazione

Configurazione in:

- `config.json`
- `manifest.json`

## Test

Self-tests del prodotto:

```powershell
./tests/Invoke-RepoHealthSelfTests.ps1
```
