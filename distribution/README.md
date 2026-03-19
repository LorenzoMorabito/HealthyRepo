# Repository Health Distribution Kit

Questa cartella contiene il materiale per distribuire `repository-health` come prodotto installabile in altri repository.

## Modello di distribuzione

La repo sorgente `HealthyRepo` resta la source-of-truth.

Da qui si possono seguire due percorsi:

- installazione diretta dalla source repo
- build di un package versionato `.zip` e installazione per `-Version`

## Contenuto

- `Build-RepoHealthPackage.ps1`
- `Install-RepoHealthFramework.ps1`
- `templates/config.template.json`
- `templates/github-workflows/*.template`
- `templates/gitignore.fragment.txt`
- `packages/.gitkeep`

## Build del package

Dalla root della repo sorgente:

```powershell
./distribution/Build-RepoHealthPackage.ps1
```

Output atteso:

- `distribution/packages/repository-health-v<version>.zip`

La versione viene letta da `manifest.json` e deve essere coerente con il tag di release.

## Installazione minima dalla source repo

```powershell
./distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo
```

## Installazione da package versionato locale

```powershell
./distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo `
  -Version 0.4.0 `
  -PackageFeedRoot ./distribution/packages
```

## Installazione da release GitHub

```powershell
./distribution/Install-RepoHealthFramework.ps1 `
  -TargetRepositoryRoot C:\path\to\target-repo `
  -Version 0.4.0
```

Se il package non e disponibile nel `PackageFeedRoot`, l'installer prova a scaricarlo dalla release GitHub configurata nel `manifest.json`.

## Parametri utili

- `-FrameworkRootRelativePath`
- `-DataBranchName`
- `-Version`
- `-PackageZipPath`
- `-PackageDirectory`
- `-PackageFeedRoot`
- `-ReleaseRepository`
- `-GitHubToken`
- `-Force`
- `-SkipWorkflows`
- `-SkipGitIgnoreUpdate`

## Modello operativo

L'installer:

- installa il runtime del framework nel repo target
- genera `config.json` dal template
- crea i workflow GitHub Actions
- aggiorna `.gitignore`
- prepara `outputs/current/.gitkeep` e `outputs/history/.gitkeep`

Il branch dati `repo-health-data` viene bootstrap-ato automaticamente dal primo workflow dopo il push su `main`.

## Validazione del distribution kit

La repo sorgente include self-tests che verificano anche il kit di distribuzione:

```powershell
./tests/Invoke-RepoHealthSelfTests.ps1
```

Questi test coprono:

- installazione dalla source repo
- build del package versionato
- installazione di una versione precisa dal package feed
- bootstrap del branch dati
- esecuzione reale dell'analyzer installato
