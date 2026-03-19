# Repository Health Runbook

## Scopo

Questo runbook serve per usare rapidamente il framework `repository-health` in locale e capire come leggere i risultati.

## 1. Check veloce locale

```powershell
./repository-health/analyzer.ps1 -Mode local
```

Usalo:

- prima di un push importante
- dopo un refactor della repo
- quando vuoi aggiornare la dashboard locale

Output principali:

- `repository-health/outputs/current/metrics.json`
- `repository-health/outputs/current/summary.md`
- `repository-health/outputs/current/dashboard.html`

## 2. Check locale bloccante

```powershell
./repository-health/analyzer.ps1 `
  -Mode local `
  -FailOnThresholdBreach
```

Comportamento:

- `OK` o `WARN`: il comando termina normalmente
- `FAIL`: il comando esce con errore

## 3. Audit completo locale

```powershell
./repository-health/analyzer.ps1 `
  -Mode schedule `
  -EnableGitSizer
```

Usalo per:

- scansione più profonda
- verifica del path schedulato
- aggiornamento della dashboard locale con metriche complete

## 4. Come leggere il risultato

### Stato `OK`

- nessuna anomalia significativa
- nessun file vietato
- nessuna soglia critica superata

### Stato `WARN`

- repo utilizzabile
- esiste almeno un punto di attenzione

Esempi:

- file corrente più grande oltre la soglia warning
- crescita anomala rispetto allo snapshot precedente
- `size-pack` sopra threshold di attenzione

### Stato `FAIL`

- presenza di file vietati
- blob storico oltre soglia critica
- violazione bloccante della policy

In caso di `FAIL`, il change non è pronto per merge senza fix o decisione esplicita.

## 5. Triage rapido

### Caso A: warning sul file corrente più grande

Controlla:

- `repository-health/outputs/current/summary.md`
- `repository-health/outputs/current/dashboard.html`
- `repository-health/outputs/history/top-files-history.csv`

Domande da fare:

- il file è atteso?
- è un file testuale del semantic model/report o un artefatto evitabile?
- sta crescendo davvero nel tempo o è solo strutturalmente grande?

### Caso B: file vietati

Controlla se sono entrati file come:

- `.pbix`
- `.pbit`
- `.xlsx`
- `.csv`

Azione:

- rimuoverli dal versioning
- spostarli in un path locale escluso
- oppure aggiornare la policy solo se la scelta è intenzionale e approvata

### Caso C: blob storico grande

Il problema è nella history Git, non solo nello stato corrente.

Azione:

- identificare il blob
- valutare se è tollerabile
- se non lo è, pianificare una bonifica history separata dal normale sviluppo

## 6. Storico e dashboard

Storico runtime locale:

- `repository-health/outputs/history/`

Storico persistente autorevole:

- branch `repo-health-data`
- path target `repository-health/history/...`

Dashboard:

- `repository-health/outputs/current/dashboard.html`

Importante:

- la dashboard locale non si aggiorna da sola dopo un `commit`
- si aggiorna quando lanci `analyzer.ps1`
- lo storico ufficiale viene aggiornato automaticamente dai workflow dopo `push` su `main` o run schedulati

## 7. Uso in CI

### Pull request

Workflow:

- `.github/workflows/repo-health-pr.yml`

Comportamento:

- valida la PR
- commenta il summary
- non scrive sul branch storico

### Push su main

Workflow:

- `.github/workflows/repo-health-push.yml`

Comportamento:

- esegue l’analisi
- aggiorna il branch `repo-health-data`

### Audit schedulato

Workflow:

- `.github/workflows/repo-health-schedule.yml`

Comportamento:

- esegue analisi approfondita
- prova anche `git-sizer`
- aggiorna lo storico persistente

## 8. Comandi da ricordare

Check veloce:

```powershell
./repository-health/analyzer.ps1 -Mode local
```

Check bloccante:

```powershell
./repository-health/analyzer.ps1 -Mode local -FailOnThresholdBreach
```

Audit completo:

```powershell
./repository-health/analyzer.ps1 -Mode schedule -EnableGitSizer
```

## 9. Regola pratica

Per il lavoro quotidiano:

1. lancia `-Mode local` quando vuoi aggiornare la vista locale
2. leggi `summary.md` se lo stato è `WARN`
3. non procedere al merge se lo stato è `FAIL`
4. lascia ai workflow GitHub la persistenza storica ufficiale
