---
name: gcp-td-security-guardrails
description: Security pre-check and fix guidance for GCP-IA GitHub repository creation or updates before publishing with Git and GitHub CLI.
---

# GCP-IA Security Guardrails

Use this skill before code is sent to GitHub for the `GCP-IA` organization.

## Purpose

This plugin is a security guardrail only. It does not authenticate to GitHub, execute local publishing commands, create repositories, push commits, or open pull requests.

## Required Review

Inspect the files the user wants to send to GitHub for:

- `.env`, `.env.*` except safe `.env.example` files;
- private keys, certificates, service-account files, tokens, credentials, and connection strings;
- hardcoded secret-like values, including example passwords that scanners may flag;
- SQL injection, command injection, dynamic eval, disabled TLS verification, unsafe path handling, and unsafe server-side URL fetching;
- missing `.gitignore` entries for secret-bearing files.

## Preventive Semgrep SAST Review

Before publishing, review the code for patterns that commonly fail the `3. SAST Semgrep` job. Do not run Python, Semgrep, pipx, or any local scanner for this step unless the user explicitly asks for tool execution. This review is a manual/static code-quality pass based on Semgrep-style best practices.

Check and fix these blockers before sending files:

- npm/pnpm supply-chain policy: if a project has `package.json`, ensure `.npmrc` exists and includes `min-release-age=7`, `engine-strict=true`, `package-manager-strict=true`, and `package-manager-strict-version=true`.
- unsafe JavaScript execution: remove or replace `eval`, `new Function`, dynamic script injection, unsafe `setTimeout` string usage, and untrusted template execution.
- XSS sinks: avoid `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, and React `dangerouslySetInnerHTML` unless sanitized with a proven sanitizer and justified.
- secret exposure: never hardcode tokens, API keys, passwords, connection strings, private keys, bearer tokens, project/team tokens, or realistic example credentials. `.env.example` must use blank values or safe placeholders.
- command injection: do not pass user input directly to shell commands. Prefer native APIs; if shell usage is unavoidable, validate inputs with strict allowlists and avoid string-built commands.
- path traversal: validate filenames, project IDs, routes, and paths with allowlists; resolve paths and reject `..`, absolute paths from users, and unexpected extensions.
- SSRF and unsafe fetch: never fetch arbitrary user-provided URLs from server-side code unless the host is allowlisted and private/internal IP ranges are blocked.
- SQL/NoSQL injection: parameterize queries and avoid string concatenation in query filters.
- weak crypto/auth: do not use MD5/SHA1 for security, do not store session tokens in `localStorage` or `sessionStorage` for sensitive admin tools, and compare secrets with timing-safe comparison when practical.
- excessive error disclosure: return sanitized errors to the UI. Do not reveal tokens, team IDs, project IDs, headers, stack traces, or raw provider responses in user-facing errors.
- serverless/API boundaries: privileged API routes must validate method, parse JSON safely, enforce authentication/authorization first, and only then call external providers.

If a Semgrep-like risk is found, fix it locally before publishing. Do not silence, skip, or exclude application code to make the gate pass. The only acceptable exclusions are existing workflow/tooling exclusions already owned by the centralized DevSecOps workflow.

## Fix Policy

Fix obvious blockers locally when possible. Prefer:

- moving values to environment variables;
- removing real secret files from tracked content;
- adding safe `.env.example` files with blank or clearly non-secret placeholders;
- parameterizing SQL queries;
- replacing dynamic eval or shell execution with safer APIs;
- adding input validation around paths, URLs, IDs, and commands.

After fixes, re-check the changed files. Do not publish while known blockers remain. The expected behavior is to fix blockers, rerun the gate, and then continue the deployment.
