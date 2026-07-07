---
name: gcp-td-publish-repository
description: Use when the user asks to create or update a GCP-TD repository from a local folder, including short plugin prompts such as start, inicio, init, publicar, crear repo, subir repo, or actualizar repo. Always run security analysis, correction, and safe publish sequencing before pushing repository files.
---

# GCP-TD Publish Repository

Use this skill for requests such as "start", "inicio", "init", "crea un repo", "sube esta carpeta", "actualiza el repositorio", or "deploy to GitHub GCP-TD". Treat short prompts as a request to run the complete secure publish flow, not as a request to only initialize Git.

## Hard Rules

- Repositories must always be under `GCP-TD`.
- Never create or update repositories under a personal GitHub account.
- Never publish `.env`, private keys, credentials, tokens, or vulnerable code.
- Do not install tools or request administrator rights.
- If vulnerabilities are found, fix them and rerun the publish flow. Do not abandon the deploy after fixes.
- Do not invent notification or commit emails by concatenating a username with a domain. Use an email exposed by the authenticated GitHub account, preferably a verified corporate email.


## Easy Start Prompts

When the user invokes the plugin with a short command such as `start`, `inicio`, or `init`, run the full secure publish sequence:

1. Resolve the target repo name from the explicit user request or current folder name.
2. Validate Git/GitHub CLI and authentication.
3. Analyze the local project for blocked files, secrets, obvious vulnerability patterns, vulnerable dependency policy, and unused dependency cleanup.
4. Apply safe automatic corrections such as `.gitignore`, `.env.example`, centralized workflow and DevSecOps script sync from `GCP-TD/.github`, owner metadata, and unused dependency removal.
5. Validate local JavaScript package managers before publish: npm projects must have `npm`; pnpm projects must have `pnpm` or Corepack must be able to activate `pnpm@10`.
6. Create the `GCP-TD/<resolved-name>` repository if missing, or update it if it exists.
7. Push `.github/workflows/seguridad-vercel.yml` and `.github/devsecops/scripts/` first and verify both exist remotely.
8. Push the remaining safe project files only after local validation passes.

Do not publish vulnerable code. If a blocker cannot be safely fixed, stop with the exact fix list.

## Required Flow

1. Validate tools and authentication. Use the native script for the current operating system.

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-td-github/scripts/gcp-td-repo.ps1" -Action ValidateTools
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-td-github/scripts/gcp-td-repo.ps1" -Action AuthStatus
```

macOS/Linux Bash:

```bash
bash "$HOME/plugins/gcp-td-github/scripts/gcp-td-repo.sh" --action ValidateTools
bash "$HOME/plugins/gcp-td-github/scripts/gcp-td-repo.sh" --action AuthStatus
```

2. If authentication is missing, use `gcp-td-browser-login`.
3. Inspect the local project and fix obvious security blockers:
   - remove tracked `.env` files from Git;
   - keep `.env` local and ignored;
   - make `.env.example` safe by clearing secret-like values;
   - parameterize SQL queries;
   - remove dynamic eval and command injection patterns;
   - keep the centralized Vercel security workflow synchronized from `GCP-TD/.github`;
   - Vercel deployments must use `VERCEL_TOKEN_SECRET` and `VERCEL_ORG_ID` or `VERCEL_TEAM_ID`; do not require a per-repository `VERCEL_PROJECT_ID` because the workflow auto-provisions or resolves the Vercel project by repository name.
4. Publish with an explicit repository name.

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-td-github/scripts/gcp-td-repo.ps1" -Action Start -Name "<repo-name>"
```

macOS/Linux Bash:

```bash
bash "$HOME/plugins/gcp-td-github/scripts/gcp-td-repo.sh" --action start --name "<repo-name>"
```

The script creates `GCP-TD/<repo-name>` when missing, updates it when it already exists, and publishes in two stages:

1. Commit and push only `.github/workflows/seguridad-vercel.yml` plus `.github/devsecops/scripts/`.
2. Verify the workflow and DevSecOps scripts exist remotely.
3. Run local workflow self-check so the synchronized GitHub Action does not fail Semgrep against itself.
4. Run local dependency usage validation when package.json exists, matching the GitHub Action depcheck gate.
5. Commit and push the rest of the safe files only after all local validations pass.

If the workflow cannot be found remotely after stage 1, if the workflow self-check fails, or if unused dependencies are detected locally, the script must stop and must not publish repository files.
## Repository Naming

Repository names are prefixed from trusted identity sources by operating system. On Windows, prefer the Windows/domain username first, then GitHub. On macOS/Linux, prefer the authenticated GitHub login first because local device users may be generic. If a specific corporate prefix is required, set `GCP_TD_REPO_USER_PREFIX` before publishing. For alert email ownership and Git commit author email, use a verified email exposed by the authenticated GitHub account. If GitHub CLI cannot read `user:email`, refresh auth with `gh auth refresh -h github.com -s user:email` or pass `GCP_TD_OWNER_EMAIL` / `--owner-email` with a verified GitHub email.
## If The Security Gate Fails

Treat the gate output as a fix list. Correct every finding in the codebase, then rerun `PublishCurrent`. Do not bypass the gate and do not publish partial vulnerable code.
