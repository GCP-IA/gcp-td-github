---
name: gcp-td-vercel-security-workflow
description: Synchronize the centralized GCP-IA Vercel security workflow from GCP-IA/.github before creating or updating repositories.
---

# GCP-IA Vercel Security Workflow

Use this skill whenever a GCP-IA repository is created or updated.

## Required Workflow Source

The source of truth is:

`GCP-IA/.github/workflow-templates/seguridad-vercel.yml`

The workflow helper scripts are also centralized in:

`GCP-IA/.github/workflow-templates/scripts/`

The plugin must download the workflow and every `.sh` helper script from GitHub. Do not keep or use a bundled copy of the workflow or helper scripts.

Preferred target path in each application repository:

`.github/workflows/seguridad-vercel.yml`

## Template Handling

Do not write a guessed workflow from memory. First download the workflow from the centralized `.github` repository with GitHub CLI:

`gh api -H "Accept: application/vnd.github.raw" repos/GCP-IA/.github/contents/workflow-templates/seguridad-vercel.yml`

If the remote read fails, stop. Do not publish repository files without the centralized workflow.

## Publish Steps

For new and existing repositories, the publish flow must:

1. Synchronize `.github/workflows/seguridad-vercel.yml` and `.github/devsecops/scripts/` from `GCP-IA/.github`.
2. Run local workflow self-check.
3. Create or update `GCP-IA/<repo>` with the requested visibility.
4. Commit and push only `.github/workflows/seguridad-vercel.yml` plus `.github/devsecops/scripts/`.
5. Verify the workflow and scripts exist remotely.
6. Only then analyze, correct, commit, and push the remaining safe project files.

If the workflow cannot be found remotely after stage 1, stop and do not publish application files.

## Perimeter Security

The centralized workflow may include Vercel perimeter controls such as Edge Middleware injection before deployment. Keep that logic in `workflow-templates/scripts/` and let the workflow call the script by name. Do not inline long bash blocks into the YAML.

## Deployment Gate

If GitHub Actions later reports a security failure, fix the code or workflow issue in the central workflow or in the application project, then publish again through the same two-stage sequence.
