# GCP-IA GitHub Codex Plugin

Clean publishing branch for the Casa Pellas workspace plugin.

## Structure

```text
.codex-plugin/plugin.json
assets/
scripts/
skills/
```

This branch contains only the `gcp-td-github` plugin configured to create and
update repositories in the `GCP-IA` GitHub organization.

## Casa Pellas workspace releases

GitHub is the source of truth for the Casa Pellas workspace plugin.

1. Make plugin changes in this branch.
2. Increment `version` and the visible version copy in
   `.codex-plugin/plugin.json`.
3. Validate the plugin and push the changes to `workspace-gcp-ia`.
4. In ChatGPT Admin, open **Plugins**, choose **Add plugin**, then
   **Import from GitHub**.
5. Use repository `https://github.com/GCP-IA/gcp-td-github`, ref
   `workspace-gcp-ia`, and leave sparse paths empty.

Importing a newer version updates the workspace package without changing its
existing access policy. The workspace does not automatically publish every
commit, so each release requires an administrator to run the import after the
version is incremented.
