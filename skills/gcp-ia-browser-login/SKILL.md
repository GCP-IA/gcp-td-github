---
name: gcp-ia-browser-login
description: Use when the user needs to connect GitHub for the GCP-IA plugin through GitHub CLI browser authentication without installing tools or requesting administrator rights.
---

# GCP-IA Browser Login

Use this skill when GitHub authentication is missing or expired. Do not force re-authentication for every new chat.

## Policy

- Do not install Git, GitHub CLI, or any prerequisite.
- Do not request administrator rights.
- Do not open a separate hidden PowerShell window.
- Use GitHub CLI only if IT already installed it.
- Open GitHub's browser authentication flow through `gh auth login --web`. If the browser does not open, relay the one-time code and URL printed by GitHub CLI back to the user so they can click the link manually.

## Commands

From the project folder, run the native script for the current operating system.

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-ia-github/scripts/gcp-ia-repo.ps1" -Action ValidateTools
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-ia-github/scripts/gcp-ia-repo.ps1" -Action Login
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-ia-github/scripts/gcp-ia-repo.ps1" -Action AuthStatus
```

macOS/Linux Bash:

```bash
bash "$HOME/plugins/gcp-ia-github/scripts/gcp-ia-repo.sh" --action ValidateTools
bash "$HOME/plugins/gcp-ia-github/scripts/gcp-ia-repo.sh" --action Login
bash "$HOME/plugins/gcp-ia-github/scripts/gcp-ia-repo.sh" --action AuthStatus
```

Only if the user explicitly asks to switch accounts or re-enter credentials, use:

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-ia-github/scripts/gcp-ia-repo.ps1" -Action ForceLogin
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE/plugins/gcp-ia-github/scripts/gcp-ia-repo.ps1" -Action AuthStatus
```

macOS/Linux Bash:

```bash
bash "$HOME/plugins/gcp-ia-github/scripts/gcp-ia-repo.sh" --action ForceLogin
bash "$HOME/plugins/gcp-ia-github/scripts/gcp-ia-repo.sh" --action AuthStatus
```
## Persistence

GitHub CLI stores the authenticated session in the user credential store. The user should not need to authenticate again in every Codex chat. Run `AuthStatus` at the start of publish workflows and call `Login` only when the session is missing, expired, or revoked. Use `ForceLogin` only when the user explicitly wants to change accounts.

## Organization Requirement

Publishing is allowed only when `AuthStatus` confirms access to `GCP-IA`. If the user is authenticated but does not have organization access, stop and ask a GitHub organization admin to add the user or grant the required role.
