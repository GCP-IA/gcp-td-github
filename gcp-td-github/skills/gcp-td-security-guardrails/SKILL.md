---
name: gcp-td-security-guardrails
description: Security pre-check and fix guidance for GCP-TD GitHub repository creation or updates before publishing with Git and GitHub CLI.
---

# GCP-TD Security Guardrails

Use this skill before code is sent to GitHub for the `GCP-TD` organization.

## Purpose

This plugin is a security guardrail only. It does not authenticate to GitHub, execute local publishing commands, create repositories, push commits, or open pull requests.

## Required Review

Inspect the files the user wants to send to GitHub for:

- `.env`, `.env.*` except safe `.env.example` files;
- private keys, certificates, service-account files, tokens, credentials, and connection strings;
- hardcoded secret-like values, including example passwords that scanners may flag;
- SQL injection, command injection, dynamic eval, disabled TLS verification, unsafe path handling, and unsafe server-side URL fetching;
- missing `.gitignore` entries for secret-bearing files.

## Fix Policy

Fix obvious blockers locally when possible. Prefer:

- moving values to environment variables;
- removing real secret files from tracked content;
- adding safe `.env.example` files with blank or clearly non-secret placeholders;
- parameterizing SQL queries;
- replacing dynamic eval or shell execution with safer APIs;
- adding input validation around paths, URLs, IDs, and commands.

After fixes, re-check the changed files. Do not publish while known blockers remain. The expected behavior is to fix blockers, rerun the gate, and then continue the deployment.
