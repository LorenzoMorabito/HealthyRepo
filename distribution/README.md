# Repository Health Distribution Kit

Questa cartella contiene il materiale per installare `repository-health` in un altro repository.

## Contenuto

- `Install-RepoHealthFramework.ps1`
- `templates/config.template.json`
- `templates/github-workflows/*.template`
- `templates/gitignore.fragment.txt`

## Installazione minima

Dalla repository sorgente del framework:

```powershell
./repository-health/distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo
```

## Parametri utili

- `-FrameworkRootRelativePath`
- `-DataBranchName`
- `-Force`
- `-SkipWorkflows`
- `-SkipGitIgnoreUpdate`

## Modello operativo

L’installer:

- copia il framework sorgente nel repo target
- genera `config.json` dal template
- crea i workflow GitHub Actions
- aggiorna `.gitignore`
- prepara `outputs/current/.gitkeep` e `outputs/history/.gitkeep`

## Nota

Il framework resta pienamente funzionante anche nella repository sorgente che lo distribuisce. Non serve reinstallarlo qui: questa repo continua a usarlo come source-of-truth e come install source per altri team.

## Validazione del distribution kit

Il framework sorgente include self-tests che verificano anche il kit di distribuzione:

```powershell
./repository-health/tests/Invoke-RepoHealthSelfTests.ps1
```

Questo smoke test installa il framework in un repo Git temporaneo e verifica che il tool installato sia realmente eseguibile.
