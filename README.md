# Repository Health Framework

Framework PowerShell + GitHub Actions per monitorare la salute Git di una repository, con focus su repository Power BI `PBIP` ma riusabile anche in altri contesti testuali versionati.

## Obiettivi

- prevenire il repository bloat
- tracciare la crescita Git nel tempo
- rilevare file vietati e pattern rischiosi
- storicizzare metriche auditabili e diffabili
- fornire insight locali e in CI senza introdurre dipendenze pesanti

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

Guida operativa:

- [RUNBOOK.md](./RUNBOOK.md)

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

- `dashboard.html` è un artefatto derivato locale/CI
- la source of truth storica è nei file `JSON/CSV/MD/TXT`

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

- [config.json](./config.json)

Parametri principali:

- `data_branch_name`
- `history_root_relative_path`
- `max_blob_mb`
- `max_pack_mb`
- `max_growth_pct`
- `warn_current_file_mb`
- `top_n`
- `forbidden_extensions`
- `excluded_paths`
- `allowed_tracked_excluded_paths`

## Workflow GitHub Actions

Workflow pronti:

- [repo-health-pr.yml](../.github/workflows/repo-health-pr.yml)
- [repo-health-push.yml](../.github/workflows/repo-health-push.yml)
- [repo-health-schedule.yml](../.github/workflows/repo-health-schedule.yml)

Comportamento:

- `pull_request`: valida, commenta, non persiste storico
- `push` su `main`: aggiorna lo storico sul branch dati
- `schedule` / `workflow_dispatch`: aggiorna lo storico e prova `git-sizer`

## Self-tests del framework

Il framework include anche una batteria minima di self-tests sul prodotto stesso.

Runner locale:

```powershell
./repository-health/tests/Invoke-RepoHealthSelfTests.ps1
```

Cosa copre:

- installer e rendering dei template
- analyzer in `local`
- crescita file su run successivi
- bootstrap e publish del branch `repo-health-data`
- comportamento bloccante sui file vietati

Workflow CI dedicato:

- [repo-health-self-tests.yml](../.github/workflows/repo-health-self-tests.yml)

## Level 2 persistence

Il framework usa due branch:

- branch applicativo, per esempio `main`
- branch dati, per esempio `repo-health-data`

Nel branch dati la struttura target è:

```text
repository-health/
  history/
    latest.json
    metrics-history.csv
    top-files-history.csv
    runs/
      2026-03-18T10-00-00Z.json
      2026-03-18T10-00-00Z.md
    git-sizer/
      2026-03-18T10-00-00Z.txt
```

## File-level growth tracking

Il framework registra i `top N` file per ogni run e li confronta con il baseline precedente.

Cosa ottieni:

- trend storico leggero dei file più grandi
- insight su file nuovi entrati nel `top N`
- delta dimensionale rispetto al baseline precedente
- correlazione pratica tra commit baseline e commit corrente

Il design resta volutamente leggero:

- non storicizza l’inventario completo del repo
- persiste solo i file più rilevanti
- evita che il framework introduca bloat nel repository che monitora

## Distribuzione su altri repo

Il framework è distributibile, ma oggi il modo corretto è:

- usare l’installer in `distribution/`
- generare config e workflow dal template
- adattare `config.json` al repository target

Materiale di distribuzione:

- `distribution/Install-RepoHealthFramework.ps1`
- `distribution/templates/`

## Assunzioni correnti

- Git installato
- PowerShell disponibile
- GitHub Actions come CI target
- runner Windows per i workflow pronti

Su altri sistemi CI o runner Linux il framework resta riusabile, ma i workflow vanno adattati.

## Policy

`FAIL`

- file vietati presenti nel working tree versionabile
- file tracked in cartelle escluse
- blob storico oltre `max_blob_mb`

`WARN`

- `size-pack` oltre soglia
- crescita anomala rispetto al baseline precedente
- largest current file oltre soglia warning

## Troubleshooting

Loop automatici:

- il trigger `push` ascolta solo il branch applicativo
- i job escludono esplicitamente il branch dati
- nessun workflow scrive mai su `main`

Failure di persistenza:

- il summary runtime resta disponibile
- l’artifact resta disponibile
- la failure di persistenza non maschera il risultato dell’analisi

Migrazione schema storico:

- se un CSV storico ha schema legacy, il framework lo ruota automaticamente in `*.legacy-<timestamp>.csv`
