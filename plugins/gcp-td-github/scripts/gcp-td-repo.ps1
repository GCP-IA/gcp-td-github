param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("ValidateTools", "Login", "ForceLogin", "Logout", "AuthStatus", "PublishCurrent", "Start", "Inicio", "Init")]
  [string]$Action,

  [string]$Name,
  [string]$Org = "GCP-TD",
  [string]$Visibility = "private",
  [string]$Remote = "origin",
  [string]$CommitMessage = "Publish secure GCP-TD project",
  [string]$OwnerEmail
)

$ErrorActionPreference = "Stop"

function Add-KnownToolPaths {
  $candidateDirs = @(
    "C:\Program Files\GitHub CLI",
    "C:\Program Files\Git\cmd",
    "C:\Program Files\Git\bin"
  )
  foreach ($dir in $candidateDirs) {
    if ((Test-Path -LiteralPath $dir) -and ($env:PATH -notlike "*$dir*")) {
      $env:PATH = "$dir;$env:PATH"
    }
  }
}

function Require-Command {
  param([string]$CommandName, [string]$Message)
  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw $Message
  }
}

function Invoke-Gh {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
  & gh @GhArgs
  if ($LASTEXITCODE -ne 0) {
    throw "gh $($GhArgs -join ' ') failed with exit code $LASTEXITCODE."
  }
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE."
  }
}

function Get-RepoNameFromFolder {
  return (Split-Path -Leaf (Get-Location)).Trim() -replace '[^A-Za-z0-9._-]+', '-'
}

function Get-DomainUserPrefix {
  param([string]$GitHubLogin)

  $gitEmailUser = $null
  try {
    $gitEmail = (& git config user.email 2>$null).Trim()
    if ($gitEmail -match '^([^@]+)@') {
      $gitEmailUser = $matches[1]
    }
  } catch {
    $gitEmailUser = $null
  }

  $isWindowsHost = $true
  if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $isWindowsHost = $IsWindows
  }

  if ($isWindowsHost) {
    $candidates = @(
      $env:GCP_TD_REPO_USER_PREFIX,
      $env:USERNAME,
      [Environment]::UserName,
      $GitHubLogin,
      $gitEmailUser,
      $env:USER
    )
  } else {
    $candidates = @(
      $env:GCP_TD_REPO_USER_PREFIX,
      $GitHubLogin,
      $gitEmailUser,
      $env:USER,
      $env:USERNAME,
      [Environment]::UserName
    )
  }

  foreach ($candidate in $candidates) {
    if ($candidate) {
      $normalized = $candidate.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
      if ($normalized) {
        return $normalized
      }
    }
  }
  throw "Could not determine the user prefix for repository naming. Set GCP_TD_REPO_USER_PREFIX or authenticate with GitHub first."
}

function Add-DomainUserRepoPrefix {
  param([string]$RepoName, [string]$GitHubLogin)
  $prefix = Get-DomainUserPrefix -GitHubLogin $GitHubLogin
  if ($RepoName -like "$prefix`_*") {
    return $RepoName
  }
  return "${prefix}_$RepoName"
}

function Resolve-GcpTdRepoName {
  param([string]$InputName, [string]$OrgName, [string]$GitHubLogin)
  if (-not $InputName) {
    $InputName = Get-RepoNameFromFolder
  }
  $InputName = $InputName.Trim()
  if ($InputName -match "/") {
    $parts = $InputName.Split("/", 2)
    if ($parts[0] -ne $OrgName) {
      throw "Repository owner must be '$OrgName'. Refusing to create or update '$InputName'."
    }
    return Add-DomainUserRepoPrefix -RepoName $parts[1] -GitHubLogin $GitHubLogin
  }
  if (-not $InputName) {
    throw "Repository name is empty."
  }
  return Add-DomainUserRepoPrefix -RepoName $InputName -GitHubLogin $GitHubLogin
}

function Resolve-OwnerMetadata {
  param([string]$ResolvedRepoName, [string]$GitHubLogin, [string]$OwnerEmailInput, [string]$GitHubEmail)

  $email = $OwnerEmailInput
  if (-not $email) { $email = $env:GCP_TD_OWNER_EMAIL }
  if (-not $email) { $email = $GitHubEmail }

  $user = $null
  if ($email -and $email -match '^([^@]+)@') {
    $user = $matches[1].ToLowerInvariant()
  }

  if (-not $user -and $ResolvedRepoName -match '^([^_]+)_') {
    $user = $matches[1].ToLowerInvariant()
  }

  if (-not $user -and $env:GCP_TD_REPO_USER_PREFIX) {
    $user = $env:GCP_TD_REPO_USER_PREFIX.ToLowerInvariant()
  }

  if (-not $user -and $GitHubLogin) {
    $user = $GitHubLogin.ToLowerInvariant()
  }

  if (-not $email -or $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "Could not determine a valid owner email from GitHub. Run 'gh auth refresh -h github.com -s user:email' and try again, or pass -OwnerEmail with a verified GitHub email."
  }

  [pscustomobject]@{ user = $user; email = $email.ToLowerInvariant() }
}

function Resolve-GitHubVerifiedEmail {
  $emails = @()
  try {
    $emails = @(& gh api user/emails | ConvertFrom-Json)
  } catch {
    $emails = @()
  }

  if ($emails.Count -gt 0) {
    $corporate = @($emails | Where-Object { $_.verified -eq $true -and $_.email -match '@casapellas\.com$' } | Select-Object -First 1)
    if ($corporate.Count -gt 0) { return $corporate[0].email.ToLowerInvariant() }

    $primary = @($emails | Where-Object { $_.primary -eq $true -and $_.verified -eq $true } | Select-Object -First 1)
    if ($primary.Count -gt 0) { return $primary[0].email.ToLowerInvariant() }

    $verified = @($emails | Where-Object { $_.verified -eq $true } | Select-Object -First 1)
    if ($verified.Count -gt 0) { return $verified[0].email.ToLowerInvariant() }
  }

  $publicEmail = ""
  try {
    $publicEmail = (& gh api user --jq ".email" 2>$null).Trim()
  } catch {
    $publicEmail = ""
  }
  if ($publicEmail -and $publicEmail -ne "null" -and $publicEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    return $publicEmail.ToLowerInvariant()
  }

  throw "Could not read a verified GitHub email for this user. Run 'gh auth refresh -h github.com -s user:email' so the plugin can use the GitHub account email instead of inventing one."
}

function Write-DevSecOpsOwnerMetadata {
  param([object]$OwnerMetadata)

  $targetDir = ".github"
  if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  }
  $json = $OwnerMetadata | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText((Join-Path $targetDir "devsecops-owner.json"), $json, [System.Text.UTF8Encoding]::new($false))
}
function Test-GhRepoExists {
  param([string]$FullName)
  $process = Start-Process -FilePath "gh" -ArgumentList @("repo", "view", $FullName, "--json", "nameWithOwner", "--jq", ".nameWithOwner") -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) -RedirectStandardError ([System.IO.Path]::GetTempFileName())
  return $process.ExitCode -eq 0
}

function Ensure-GcpTdAccess {
  param([string]$OrgName)
  & gh auth status -h github.com *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run the Login action first."
  }
  $login = (& gh api user --jq .login).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $login) {
    throw "Could not determine the authenticated GitHub user."
  }
  & gh api "orgs/$OrgName" --jq .login *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub user '$login' does not have API access to organization '$OrgName'."
  }
  return $login
}

function Ensure-GitRepository {
  $stdout = [System.IO.Path]::GetTempFileName()
  $stderr = [System.IO.Path]::GetTempFileName()
  try {
    $process = Start-Process -FilePath "git" -ArgumentList @("rev-parse", "--is-inside-work-tree") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $exitCode = $process.ExitCode
  } finally {
    Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
  }

  if ($exitCode -ne 0) {
    Invoke-Git init
  }
}

function Ensure-Gitignore {
  $required = @(
    ".env",
    ".env.*",
    "!.env.example",
    "node_modules/",
    "npm-debug.log*",
    "yarn-debug.log*",
    "yarn-error.log*"
  )
  $path = ".gitignore"
  $existing = @()
  if (Test-Path -LiteralPath $path) {
    $existing = @(Get-Content -LiteralPath $path)
  }
  $next = New-Object System.Collections.Generic.List[string]
  foreach ($line in $existing) {
    $next.Add($line)
  }
  foreach ($line in $required) {
    if ($existing -notcontains $line) {
      $next.Add($line)
    }
  }
  [System.IO.File]::WriteAllLines((Resolve-Path .).Path + "\.gitignore", $next, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-GhRawDownload {
  param([string]$ApiPath, [string]$Destination)

  $content = & gh api -H "Accept: application/vnd.github.raw" $ApiPath
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($content)) {
    throw "Downloaded content is empty or unavailable: $ApiPath"
  }

  $normalized = ($content -join "`n") -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath (Split-Path -Parent $Destination)).Path + "\" + (Split-Path -Leaf $Destination), $normalized, [System.Text.UTF8Encoding]::new($false))
}

function Ensure-SecurityWorkflow {
  param([string]$OrgName)

  $targetDir = ".github\workflows"
  $target = Join-Path $targetDir "seguridad-vercel.yml"
  $scriptTargetDir = ".github\devsecops\scripts"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  New-Item -ItemType Directory -Force -Path $scriptTargetDir | Out-Null

  $templatePath = "repos/$OrgName/.github/contents/workflow-templates/seguridad-vercel.yml"
  try {
    Write-Host "Downloading corporate workflow from $OrgName/.github..."
    Invoke-GhRawDownload -ApiPath $templatePath -Destination $target
    Write-Host "Corporate workflow downloaded from $OrgName/.github."
  } catch {
    throw "Could not download corporate workflow from $OrgName/.github. Refusing to publish without the centralized action. Details: $($_.Exception.Message)"
  }

  $scriptListPath = "repos/$OrgName/.github/contents/workflow-templates/scripts"
  Write-Host "Downloading corporate DevSecOps scripts from $OrgName/.github..."
  Get-ChildItem -LiteralPath $scriptTargetDir -Filter "*.sh" -File -ErrorAction SilentlyContinue | Remove-Item -Force
  $scripts = @()
  try {
    $scripts = @((& gh api $scriptListPath | ConvertFrom-Json) | Where-Object { $_.type -eq "file" -and $_.name -like "*.sh" })
  } catch {
    throw "Could not list corporate DevSecOps scripts from $OrgName/.github. Refusing to publish without centralized scripts. Details: $($_.Exception.Message)"
  }

  if ($scripts.Count -eq 0) {
    throw "No corporate DevSecOps scripts found in $OrgName/.github workflow-templates/scripts."
  }

  foreach ($script in $scripts) {
    $targetScript = Join-Path $scriptTargetDir $script.name
    try {
      Invoke-GhRawDownload -ApiPath "repos/$OrgName/.github/contents/workflow-templates/scripts/$($script.name)" -Destination $targetScript
    } catch {
      throw "Could not download corporate DevSecOps script '$($script.name)' from $OrgName/.github. Details: $($_.Exception.Message)"
    }
  }

  Write-Host "Corporate DevSecOps scripts downloaded from $OrgName/.github."
}

function Repair-SafeExamples {
  $examples = @(".env.example")
  foreach ($example in $examples) {
    if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
      continue
    }
    $lines = Get-Content -LiteralPath $example
    $fixed = foreach ($line in $lines) {
      if ($line -match "^\s*([A-Za-z0-9_]*(PASSWORD|PASSWD|PWD|SECRET|TOKEN|KEY)[A-Za-z0-9_]*)\s*=") {
        $name = $Matches[1]
        "$name="
      } else {
        $line
      }
    }
    [System.IO.File]::WriteAllLines((Resolve-Path -LiteralPath $example).Path, [string[]]$fixed, [System.Text.UTF8Encoding]::new($false))
  }
}

function Remove-BlockedFilesFromIndex {
  $blocked = @(".env")
  foreach ($file in $blocked) {
    $trackedMatches = @(& git ls-files -- $file)
    if ($trackedMatches -contains $file) {
      & git rm --cached -- $file
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove '$file' from the Git index."
      }
    }
  }
}

function Test-BinaryFile {
  param([string]$Path)
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $limit = [Math]::Min($bytes.Length, 8000)
    for ($i = 0; $i -lt $limit; $i++) {
      if ($bytes[$i] -eq 0) { return $true }
    }
  } catch {
    return $true
  }
  return $false
}

function Get-GitCandidateFiles {
  $tracked = @(& git ls-files)
  $untracked = @(& git ls-files --others --exclude-standard)
  return @($tracked + $untracked | Sort-Object -Unique)
}

function Invoke-SecurityGate {
  $findings = New-Object System.Collections.Generic.List[object]
  $blockedFilePatterns = @(
    "(^|/)\.env($|\.)",
    "\.pem$",
    "\.p12$",
    "\.pfx$",
    "\.key$",
    "id_rsa$",
    "id_ed25519$",
    "credentials\.json$",
    "service-account.*\.json$"
  )
  $secretPatterns = @(
    @{ Name = "GitHub token"; Regex = "gh[pousr]_[A-Za-z0-9_]{36,255}" },
    @{ Name = "Generic credential assignment"; Regex = "(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd|pwd)\b\s*[:=]\s*['""][^'""]{4,}['""]" },
    @{ Name = "AWS access key"; Regex = "AKIA[0-9A-Z]{16}" },
    @{ Name = "Google API key"; Regex = "AIza[0-9A-Za-z\-_]{35}" },
    @{ Name = "JWT"; Regex = "eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}" },
    @{ Name = "Private key"; Regex = "-----BEGIN (RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----" }
  )
  $riskPatterns = @(
    @{ Name = "Possible SQL injection"; Regex = "(?i)(select|insert|update|delete|exec|execute)\s+.*(\+|\$\{|%s|format\(|f['""])" },
    @{ Name = "Dynamic SQL execution"; Regex = "(?i)\b(execute|exec|query|raw|rawQuery)\s*\([^)]*(\+|\$\{|format\(|%s)" },
    @{ Name = "Dynamic eval"; Regex = "(?i)\b(eval|execScript|new Function)\s*\(" },
    @{ Name = "Shell command injection risk"; Regex = "(?i)\b(exec|spawn|system|popen|Start-Process|Invoke-Expression)\s*\([^)]*(req\.|request\.|params|query|body|\$\{)" },
    @{ Name = "Insecure TLS verification disabled"; Regex = "(?i)(rejectUnauthorized\s*:\s*false|verify\s*=\s*False|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['""]?0)" }
  )

  foreach ($file in Get-GitCandidateFiles) {
    $normalized = $file -replace "\\", "/"
    foreach ($pattern in $blockedFilePatterns) {
      if ($normalized -match $pattern -and $normalized -notmatch "(^|/)\.env\.example$") {
        $findings.Add([pscustomobject]@{ path = $file; line = 0; type = "blocked-file"; message = "Sensitive file must not be published." })
      }
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    $item = Get-Item -LiteralPath $file
    if ($item.Length -gt 1048576 -or (Test-BinaryFile $file)) { continue }
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $file))) {
      $lineNumber++
      foreach ($pattern in $secretPatterns) {
        if ($line -match $pattern.Regex) {
          $findings.Add([pscustomobject]@{ path = $file; line = $lineNumber; type = "secret"; message = $pattern.Name })
        }
      }
      foreach ($pattern in $riskPatterns) {
        if ($line -match $pattern.Regex) {
          $findings.Add([pscustomobject]@{ path = $file; line = $lineNumber; type = "vulnerability-pattern"; message = $pattern.Name })
        }
      }
    }
  }

  if ($findings.Count -gt 0) {
    Write-Host "GCP-TD security gate found $($findings.Count) blocker(s):"
    $findings | Sort-Object path, line | Format-Table type,path,line,message -AutoSize
    throw "Fix the listed security blockers, then rerun PublishCurrent. Deployment must continue only after these issues are corrected."
  }
  Write-Host "GCP-TD security gate passed."
}

function Invoke-DependencyUsageGate {
  $packageFiles = @(Get-ChildItem -Path . -Recurse -File -Filter package.json -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' })
  if ($packageFiles.Count -eq 0) {
    Write-Host "No package.json found; skipping local dependency usage gate."
    return
  }

  Require-Command npx "npx was not found. Install Node.js/npm before publishing projects with package.json."

  $ignored = @('vite', '@vitejs/*', 'astro', 'typescript', 'eslint', 'prettier', 'tailwindcss', 'postcss', 'autoprefixer')
  $ignoredArg = ($ignored -join ',')

  foreach ($pkg in $packageFiles) {
    $dir = $pkg.Directory.FullName
    Write-Host "Checking dependency usage in $dir"
    Push-Location $dir
    try {
      $reportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("depcheck-" + [guid]::NewGuid().ToString("N") + ".json")
      & npx --yes depcheck --json --ignores=$ignoredArg *> $reportPath
      $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
      Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue

      $unused = @()
      if ($report.dependencies) { $unused += @($report.dependencies) }
      if ($report.devDependencies) { $unused += @($report.devDependencies) }
      $unused = @($unused | Sort-Object -Unique)

      if ($unused.Count -eq 0) {
        Write-Host "Dependency usage gate passed in $dir."
        continue
      }

      Write-Host "Removing unused package(s) before publish: $($unused -join ', ')"
      if (Test-Path -LiteralPath 'pnpm-lock.yaml') {
        Require-Command pnpm "pnpm-lock.yaml was found, but pnpm is not available to remove unused dependencies."
        & pnpm remove @unused
      } else {
        & npm uninstall @unused
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove unused package(s): $($unused -join ', ')"
      }

      $verifyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("depcheck-verify-" + [guid]::NewGuid().ToString("N") + ".json")
      & npx --yes depcheck --json --ignores=$ignoredArg *> $verifyPath
      $verify = Get-Content -LiteralPath $verifyPath -Raw | ConvertFrom-Json
      Remove-Item -LiteralPath $verifyPath -Force -ErrorAction SilentlyContinue
      $remaining = @()
      if ($verify.dependencies) { $remaining += @($verify.dependencies) }
      if ($verify.devDependencies) { $remaining += @($verify.devDependencies) }
      $remaining = @($remaining | Sort-Object -Unique)
      if ($remaining.Count -gt 0) {
        throw "Unused package(s) remain after cleanup: $($remaining -join ', ')"
      }
    } finally {
      Pop-Location
    }
  }
}

function Invoke-PackageManagerPreflight {
  $packageFiles = @(Get-ChildItem -Path . -Recurse -File -Filter package.json -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' })
  if ($packageFiles.Count -eq 0) {
    Write-Host "No package.json found; skipping package manager preflight."
    return
  }

  Require-Command node "node was not found. Install Node.js before publishing JavaScript projects."
  Require-Command npm "npm was not found. Install Node.js/npm before publishing JavaScript projects."
  Require-Command npx "npx was not found. Install Node.js/npm before publishing JavaScript projects."

  foreach ($pkg in $packageFiles) {
    $dir = $pkg.Directory.FullName
    Write-Host "Checking package manager in $dir"
    Push-Location $dir
    try {
      if (Test-Path -LiteralPath 'pnpm-lock.yaml') {
        if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
          & corepack enable *> $null
          & corepack prepare pnpm@10 --activate *> $null
        }
        Require-Command pnpm "pnpm-lock.yaml was found, but pnpm is not available. Install pnpm or enable Corepack before publishing."
        & pnpm --version | Out-Host
        if ($LASTEXITCODE -ne 0) {
          throw "pnpm is installed but failed to run in $dir."
        }
      } elseif ((Test-Path -LiteralPath 'package-lock.json') -or (Test-Path -LiteralPath 'npm-shrinkwrap.json')) {
        & npm --version | Out-Host
        if ($LASTEXITCODE -ne 0) {
          throw "npm is installed but failed to run in $dir."
        }
      } else {
        Write-Host "No lockfile found in $dir; npm audit will generate a temporary package-lock in the workflow."
      }
    } finally {
      Pop-Location
    }
  }
}

function Invoke-WorkflowSelfCheck {
  $workflowRoot = ".github\workflows"
  if (-not (Test-Path -LiteralPath $workflowRoot -PathType Container)) {
    Write-Host "No GitHub workflow directory found; skipping workflow self-check."
    return
  }

  $findings = New-Object System.Collections.Generic.List[object]
  $workflowFiles = @(Get-ChildItem -LiteralPath $workflowRoot -Recurse -File -Include *.yml,*.yaml -ErrorAction SilentlyContinue)

  foreach ($workflowFile in $workflowFiles) {
    $lines = Get-Content -LiteralPath $workflowFile.FullName
    $inRunBlock = $false
    $runIndent = -1

    for ($index = 0; $index -lt $lines.Count; $index++) {
      $line = $lines[$index]

      if ($line -match '^(\s*)run:\s*[|>]') {
        $inRunBlock = $true
        $runIndent = $Matches[1].Length
        continue
      }

      if ($inRunBlock) {
        if ($line.Trim().Length -gt 0) {
          $currentIndent = ([regex]::Match($line, '^\s*')).Value.Length
          if ($currentIndent -le $runIndent) {
            $inRunBlock = $false
          }
        }
      }

      if ($inRunBlock -and $line -match '\$\{\{\s*github\.') {
        $relativePath = Resolve-Path -LiteralPath $workflowFile.FullName -Relative
        $findings.Add([pscustomobject]@{
          path = $relativePath
          line = $index + 1
          message = 'GitHub context interpolation inside run block. Move the value to env and reference the quoted environment variable.'
        })
      }
    }
  }

  foreach ($workflowFile in $workflowFiles) {
    $relativePath = Resolve-Path -LiteralPath $workflowFile.FullName -Relative
    $workflowText = Get-Content -LiteralPath $workflowFile.FullName -Raw
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $workflowFile.FullName) {
      $lineNumber++
      if ($line -match 'vercel-args:\s*[''"].*--yes') {
        $findings.Add([pscustomobject]@{
          path = $relativePath
          line = $lineNumber
          message = 'Unsupported Vercel CLI argument --yes in vercel-args. Remove it before publishing.'
        })
      }
    }

    if ($workflowText -match 'amondnet/vercel-action') {
      $findings.Add([pscustomobject]@{
        path = $relativePath
        line = 0
        message = 'Deprecated amondnet/vercel-action detected. Use npx vercel@latest with dynamic .vercel/project.json instead.'
      })
    }

    if ($workflowText -match 'secrets\.VERCEL_PROJECT_ID|vars\.VERCEL_PROJECT_ID|VERCEL_PROJECT_ID:\s*[''"][^$]') {
      $findings.Add([pscustomobject]@{
        path = $relativePath
        line = 0
        message = 'Static VERCEL_PROJECT_ID detected. The corporate workflow must resolve project_id dynamically through Vercel API.'
      })
    }
  }

  if ($findings.Count -gt 0) {
    Write-Host "Workflow self-check found blocking issue(s):"
    $findings | Format-Table path,line,message -AutoSize
    throw "Fix workflow issues before publishing the GitHub Action."
  }

  Write-Host "Workflow self-check passed."
}
function Stage-SafeFiles {
  Invoke-Git add -- .gitignore .github
  foreach ($file in Get-GitCandidateFiles) {
    if ($file -eq ".env" -or $file -like ".env.*" -and $file -ne ".env.example") {
      continue
    }
    Invoke-Git add -- $file
  }
}

function Ensure-RepositoryRemote {
  param([string]$FullName, [string]$VisibilityValue, [string]$RemoteName)

  $exists = Test-GhRepoExists -FullName $FullName
  if (-not $exists) {
    Invoke-Gh repo create $FullName "--$VisibilityValue"
  }

  $url = "https://github.com/$FullName.git"
  $remoteNames = @(& git remote)
  if ($remoteNames -contains $RemoteName) {
    $currentRemote = (& git remote get-url $RemoteName)
    if ($currentRemote -notmatch [regex]::Escape($FullName)) {
      throw "Remote '$RemoteName' points to '$currentRemote', not '$FullName'. Refusing to publish outside the configured organization."
    }
    Invoke-Git remote set-url $RemoteName $url
  } else {
    Invoke-Git remote add $RemoteName $url
  }

  return $exists
}

function Ensure-CurrentBranch {
  $branch = (& git branch --show-current).Trim()
  if (-not $branch) {
    $branch = "main"
    Invoke-Git checkout -B $branch
  }
  return $branch
}

function Test-RemoteWorkflowExists {
  param([string]$FullName, [string]$Branch)

  $process = Start-Process -FilePath "gh" -ArgumentList @(
    "api",
    "--method",
    "GET",
    "repos/$FullName/contents/.github/workflows/seguridad-vercel.yml",
    "-f",
    "ref=$Branch"
  ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) -RedirectStandardError ([System.IO.Path]::GetTempFileName())

  return $process.ExitCode -eq 0
}

function Test-RemoteDevSecOpsScriptsExist {
  param([string]$FullName, [string]$Branch)

  $process = Start-Process -FilePath "gh" -ArgumentList @(
    "api",
    "--method",
    "GET",
    "repos/$FullName/contents/.github/devsecops/scripts",
    "-f",
    "ref=$Branch"
  ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) -RedirectStandardError ([System.IO.Path]::GetTempFileName())

  return $process.ExitCode -eq 0
}

function Test-RemoteFileMatchesLocal {
  param([string]$FullName, [string]$Branch, [string]$LocalPath, [string]$RemotePath)

  if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
    return $false
  }

  $temp = [System.IO.Path]::GetTempFileName()
  try {
    & gh api -H "Accept: application/vnd.github.raw" "repos/$FullName/contents/$RemotePath`?ref=$Branch" > $temp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp) -or ((Get-Item -LiteralPath $temp).Length -eq 0)) {
      return $false
    }

    $localText = ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $LocalPath).Path) -replace "`r`n", "`n").TrimEnd()
    $remoteText = ([System.IO.File]::ReadAllText($temp) -replace "`r`n", "`n").TrimEnd()
    return $localText -eq $remoteText
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Test-RemoteDevSecOpsScriptsMatchLocal {
  param([string]$FullName, [string]$Branch)

  $localScripts = @(Get-ChildItem -LiteralPath ".github\devsecops\scripts" -Filter "*.sh" -File -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($localScripts.Count -eq 0) {
    return $false
  }

  foreach ($script in $localScripts) {
    $remotePath = ".github/devsecops/scripts/$($script.Name)"
    if (-not (Test-RemoteFileMatchesLocal -FullName $FullName -Branch $Branch -LocalPath $script.FullName -RemotePath $remotePath)) {
      Write-Host "Remote DevSecOps script is missing or stale: $($script.Name)"
      return $false
    }
  }

  return $true
}

function Publish-SecurityWorkflowFirst {
  param([string]$FullName, [string]$RemoteName, [string]$Branch)

  if (-not (Test-Path -LiteralPath ".github\workflows\seguridad-vercel.yml" -PathType Leaf)) {
    throw "Security workflow is missing locally; refusing to publish repository files."
  }
  if (-not (Test-Path -LiteralPath ".github\devsecops\scripts" -PathType Container)) {
    throw "Corporate DevSecOps scripts are missing locally; refusing to publish repository files."
  }

  Invoke-Git add -- .github/workflows/seguridad-vercel.yml
  Invoke-Git add -- .github/devsecops/scripts
  if (Test-Path -LiteralPath ".github\devsecops-owner.json" -PathType Leaf) {
    Invoke-Git add -- .github/devsecops-owner.json
  }
  & git diff --cached --quiet -- .github/workflows/seguridad-vercel.yml .github/devsecops/scripts .github/devsecops-owner.json
  if ($LASTEXITCODE -ne 0) {
    Invoke-Git commit -m "Sync corporate DevSecOps gate" -- .github/workflows/seguridad-vercel.yml .github/devsecops/scripts .github/devsecops-owner.json
  } else {
    Write-Host "Security workflow and DevSecOps scripts already committed locally."
  }

  Invoke-Git push -u $RemoteName $Branch

  if (-not (Test-RemoteWorkflowExists -FullName $FullName -Branch $Branch)) {
    throw "Security workflow was not found in '$FullName' on branch '$Branch' after push. Refusing to publish repository files."
  }
  if (-not (Test-RemoteDevSecOpsScriptsExist -FullName $FullName -Branch $Branch)) {
    throw "DevSecOps scripts were not found in '$FullName' on branch '$Branch' after push. Refusing to publish repository files."
  }
  if (-not (Test-RemoteFileMatchesLocal -FullName $FullName -Branch $Branch -LocalPath ".github\workflows\seguridad-vercel.yml" -RemotePath ".github/workflows/seguridad-vercel.yml")) {
    throw "Remote security workflow is stale after stage 1. Refusing to publish repository files."
  }
  if (-not (Test-RemoteDevSecOpsScriptsMatchLocal -FullName $FullName -Branch $Branch)) {
    throw "Remote DevSecOps scripts are stale after stage 1. Refusing to publish repository files."
  }

  Write-Host "Security workflow and DevSecOps scripts are current remotely. Continuing with repository files."
}

function Ensure-GitIdentity {
  param([string]$GitHubLogin, [string]$VerifiedEmail)

  $name = (& git config user.name).Trim()
  if (-not $name) {
    & git config user.name $GitHubLogin
  }
  if (-not $VerifiedEmail -or $VerifiedEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "Cannot configure Git author email because no verified GitHub email was resolved."
  }
  & git config user.email $VerifiedEmail
  Write-Host "Configured local Git author email from verified GitHub account: $VerifiedEmail"
}

function Publish-Current {
  param([string]$RepoName, [string]$OrgName, [string]$VisibilityValue, [string]$RemoteName, [string]$Message, [string]$OwnerEmailValue)

  $login = Ensure-GcpTdAccess -OrgName $OrgName
  $githubEmail = Resolve-GitHubVerifiedEmail
  $resolvedName = Resolve-GcpTdRepoName -InputName $RepoName -OrgName $OrgName -GitHubLogin $login
  $fullName = "$OrgName/$resolvedName"
  if ($fullName -notlike "$OrgName/*") {
    throw "Internal safety check failed: target repository must be under '$OrgName'."
  }
  $ownerMetadata = Resolve-OwnerMetadata -ResolvedRepoName $resolvedName -GitHubLogin $login -OwnerEmailInput $OwnerEmailValue -GitHubEmail $githubEmail

  Ensure-GitRepository
  Ensure-Gitignore
  Repair-SafeExamples
  Remove-BlockedFilesFromIndex
  Ensure-SecurityWorkflow -OrgName $Org
  Write-DevSecOpsOwnerMetadata -OwnerMetadata $ownerMetadata
  Invoke-WorkflowSelfCheck
  Invoke-SecurityGate
  Invoke-PackageManagerPreflight
  Ensure-GitIdentity -GitHubLogin $login -VerifiedEmail $githubEmail
  $exists = Ensure-RepositoryRemote -FullName $fullName -VisibilityValue $VisibilityValue -RemoteName $RemoteName
  $branch = Ensure-CurrentBranch
  Publish-SecurityWorkflowFirst -FullName $fullName -RemoteName $RemoteName -Branch $branch
  Invoke-DependencyUsageGate
  Stage-SafeFiles

  & git diff --cached --quiet
  if ($LASTEXITCODE -ne 0) {
    Invoke-Git commit -m $Message
  } else {
    Write-Host "No file changes to commit."
  }

  Invoke-Git push -u $RemoteName $branch

  [pscustomobject]@{
    repository = "https://github.com/$fullName"
    existed = $exists
    branch = $branch
    remote = $RemoteName
    githubUser = $login
  } | ConvertTo-Json
}

Add-KnownToolPaths

switch ($Action) {
  "ValidateTools" {
    Require-Command git "Git was not found. Ask IT to deploy Git for Windows before using this plugin."
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before using this plugin."
    [pscustomobject]@{ git = (& git --version); gh = (& gh --version | Select-Object -First 1) } | ConvertTo-Json
    break
  }
  "Login" {
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before login."
    Write-Host "GitHub CLI iniciara autenticacion web. Si el navegador no se abre, copia desde esta salida el codigo de un solo uso y abre el enlace que muestre GitHub CLI."
    & gh auth login -h github.com -p https --web --skip-ssh-key --scopes repo,read:org,workflow
    if ($LASTEXITCODE -ne 0) {
      throw "GitHub browser login failed."
    }
    break
  }
  "ForceLogin" {
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before login."
    & gh auth status -h github.com *> $null
    if ($LASTEXITCODE -eq 0) {
      & gh auth logout -h github.com
      if ($LASTEXITCODE -ne 0) {
        throw "GitHub logout failed."
      }
    }
    Write-Host "GitHub CLI iniciara autenticacion web. Si el navegador no se abre, copia desde esta salida el codigo de un solo uso y abre el enlace que muestre GitHub CLI."
    & gh auth login -h github.com -p https --web --skip-ssh-key --scopes repo,read:org,workflow
    if ($LASTEXITCODE -ne 0) {
      throw "GitHub browser login failed."
    }
    break
  }
  "Logout" {
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before logout."
    & gh auth logout -h github.com
    if ($LASTEXITCODE -ne 0) {
      throw "GitHub logout failed."
    }
    [pscustomobject]@{ loggedOut = $true; host = "github.com" } | ConvertTo-Json
    break
  }
  "AuthStatus" {
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before checking auth."
    $login = Ensure-GcpTdAccess -OrgName $Org
    $orgs = @(& gh api user/orgs --jq '.[].login')
    [pscustomobject]@{ login = $login; organizations = $orgs; hasGcpTd = ($orgs -contains $Org) } | ConvertTo-Json
    break
  }
  { $_ -in @("PublishCurrent", "Start", "Inicio", "Init") } {
    Require-Command git "Git was not found. Ask IT to deploy Git for Windows before publishing."
    Require-Command gh "GitHub CLI was not found. Ask IT to deploy GitHub CLI before publishing."
    Publish-Current -RepoName $Name -OrgName $Org -VisibilityValue $Visibility -RemoteName $Remote -Message $CommitMessage -OwnerEmailValue $OwnerEmail
    break
  }
}
