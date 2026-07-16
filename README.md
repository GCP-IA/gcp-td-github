# GCP-TD GitHub Codex Plugin Marketplace

Private Codex plugin marketplace for Casa Pellas.

## Structure

```text
.agents/plugins/marketplace.json
plugins/gcp-td-github/
```

The marketplace exposes the `gcp-td-github` plugin for Codex.

## Casa Pellas workspace releases

GitHub is the source of truth for the Casa Pellas workspace plugin.

1. Make plugin changes under `plugins/gcp-td-github/`.
2. Increment `version` and the visible version copy in
   `plugins/gcp-td-github/.codex-plugin/plugin.json`.
3. Merge the validated changes into `main`.
4. In ChatGPT Admin, open **Plugins**, choose **Add plugin**, then
   **Import from GitHub**.
5. Use repository `https://github.com/GCP-IA/gcp-td-github`, ref `main`, and
   sparse path `plugins/gcp-td-github` only.

Importing a newer version of the same plugin updates the workspace package
without changing its existing access policy. The workspace does not
automatically publish every commit, so each release requires an administrator
to run the import after the version is incremented.
