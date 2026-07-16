#!/usr/bin/env bash
set -euo pipefail

ACTION=""
NAME=""
ORG="GCP-IA"
VISIBILITY="private"
REMOTE="origin"
COMMIT_MESSAGE="Publish secure GCP-IA project"
OWNER_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action|-Action) ACTION="${2:-}"; shift 2 ;;
    --name|-Name) NAME="${2:-}"; shift 2 ;;
    --org|-Org) ORG="${2:-}"; shift 2 ;;
    --visibility|-Visibility) VISIBILITY="${2:-}"; shift 2 ;;
    --remote|-Remote) REMOTE="${2:-}"; shift 2 ;;
    --message|-CommitMessage) COMMIT_MESSAGE="${2:-}"; shift 2 ;;
    --owner-email|-OwnerEmail) OWNER_EMAIL="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Missing --action. Valid actions: ValidateTools, Login, ForceLogin, Logout, AuthStatus, PublishCurrent, Start, Inicio, Init" >&2
  exit 2
fi

augment_path() {
  local candidates=(
    "$HOME/.local/bin"
    "$HOME/bin"
    "$HOME/go/bin"
    "$HOME/.cargo/bin"
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
    "/usr/local/bin"
    "/usr/local/sbin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  )
  local dir
  for dir in "${candidates[@]}"; do
    [[ -n "$dir" ]] || continue
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$PATH:$dir" ;;
    esac
  done
  export PATH
}

augment_path

require_command() {
  local command_name="$1"
  local message="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

normalize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

repo_name_from_folder() {
  basename "$PWD" | sed -E 's/[^A-Za-z0-9._-]+/-/g'
}

get_git_email_user() {
  local email
  email="$(git config user.email 2>/dev/null || true)"
  if [[ "$email" == *@* ]]; then
    printf '%s' "${email%@*}"
  fi
}

get_user_prefix() {
  local github_login="${1:-}"
  local candidates=(
    "${GCP_IA_REPO_USER_PREFIX:-}"
    "${GCP_TD_REPO_USER_PREFIX:-}"
    "$github_login"
    "$(get_git_email_user)"
    "${USER:-}"
    "${USERNAME:-}"
  )
  local candidate normalized
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" ]]; then
      normalized="$(normalize_name "$candidate")"
      if [[ -n "$normalized" ]]; then
        printf '%s' "$normalized"
        return 0
      fi
    fi
  done
  echo "Could not determine the user prefix. Set GCP_IA_REPO_USER_PREFIX or authenticate with GitHub first." >&2
  exit 1
}

add_user_prefix() {
  local repo_name="$1"
  local github_login="${2:-}"
  local prefix
  prefix="$(get_user_prefix "$github_login")"
  if [[ "$repo_name" == "${prefix}_"* ]]; then
    printf '%s' "$repo_name"
  else
    printf '%s_%s' "$prefix" "$repo_name"
  fi
}

resolve_repo_name() {
  local input_name="${1:-}"
  local org_name="$2"
  local github_login="${3:-}"
  if [[ -z "$input_name" ]]; then
    input_name="$(repo_name_from_folder)"
  fi
  input_name="${input_name// /-}"
  if [[ "$input_name" == */* ]]; then
    local owner="${input_name%%/*}"
    local repo="${input_name#*/}"
    if [[ "$owner" != "$org_name" ]]; then
      echo "Repository owner must be '$org_name'. Refusing '$input_name'." >&2
      exit 1
    fi
    add_user_prefix "$repo" "$github_login"
  else
    add_user_prefix "$input_name" "$github_login"
  fi
}

ensure_gcp_td_access() {
  local org_name="$1"
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    echo "GitHub CLI is not authenticated. Run Login first." >&2
    exit 1
  fi
  local login
  login="$(gh api user --jq .login)"
  if [[ -z "$login" ]]; then
    echo "Could not determine the authenticated GitHub user." >&2
    exit 1
  fi
  if ! gh api "orgs/$org_name" --jq .login >/dev/null 2>&1; then
    echo "GitHub user '$login' does not have API access to organization '$org_name'." >&2
    exit 1
  fi
  printf '%s' "$login"
}

resolve_owner_metadata() {
  local resolved_repo_name="$1"
  local github_login="${2:-}"
  local explicit_email="${3:-}"
  local github_email="${4:-}"
  local email="${explicit_email:-${GCP_IA_OWNER_EMAIL:-${GCP_TD_OWNER_EMAIL:-$github_email}}}"
  local user=""

  if [[ -n "$email" && "$email" == *@* ]]; then
    user="${email%@*}"
  fi

  if [[ -z "$user" && "$resolved_repo_name" == *_* ]]; then
    user="${resolved_repo_name%%_*}"
  fi

  if [[ -z "$user" && -n "${GCP_IA_REPO_USER_PREFIX:-}" ]]; then
    user="$GCP_IA_REPO_USER_PREFIX"
  fi

  if [[ -z "$user" && -n "${GCP_TD_REPO_USER_PREFIX:-}" ]]; then
    user="$GCP_TD_REPO_USER_PREFIX"
  fi

  if [[ -z "$user" && -n "$github_login" ]]; then
    user="$github_login"
  fi

  user="$(normalize_name "$user")"

  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    echo "Could not determine a valid owner email from GitHub. Run 'gh auth refresh -h github.com -s user:email' and try again, or pass --owner-email with a verified GitHub email." >&2
    exit 1
  fi

  printf '%s\t%s' "$user" "$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"
}

github_verified_email() {
  local emails_json selected public_email
  emails_json="$(gh api user/emails 2>/dev/null || true)"
  if [[ -n "$emails_json" ]]; then
    selected="$(node -e '
const data = JSON.parse(process.argv[1]);
const corporate = data.find(e => e.verified && /@casapellas\.com$/i.test(e.email));
const primary = data.find(e => e.primary && e.verified);
const verified = data.find(e => e.verified);
const chosen = corporate || primary || verified;
if (chosen) process.stdout.write(String(chosen.email).toLowerCase());
' "$emails_json")"
    if [[ -n "$selected" ]]; then
      printf '%s' "$selected"
      return 0
    fi
  fi

  public_email="$(gh api user --jq .email 2>/dev/null || true)"
  if [[ "$public_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    printf '%s' "$(printf '%s' "$public_email" | tr '[:upper:]' '[:lower:]')"
    return 0
  fi

  echo "Could not read a verified GitHub email for this user. Run 'gh auth refresh -h github.com -s user:email' so the plugin can use the GitHub account email instead of inventing one." >&2
  exit 1
}

write_owner_metadata() {
  local user="$1"
  local email="$2"
  mkdir -p .github
  node - "$user" "$email" > .github/devsecops-owner.json <<'NODE'
const [user, email] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ user, email }));
NODE
}
ensure_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git init
  fi
}

ensure_gitignore() {
  touch .gitignore
  local entries=(".env" ".env.*" "!.env.example" "node_modules/" ".vercel/" "*.pem" "*.p12" "*.pfx" "*.key" "id_rsa" "id_ed25519" "credentials.json" "service-account*.json")
  local entry
  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" .gitignore; then
      printf '\n%s' "$entry" >> .gitignore
    fi
  done
}

copy_security_workflow() {
  local org_name="$1"
  local target=".github/workflows/seguridad-vercel.yml"
  local script_target_dir=".github/devsecops/scripts"
  local temp_workflow
  temp_workflow="$(mktemp)"

  mkdir -p .github/workflows
  mkdir -p "$script_target_dir"

  echo "Downloading corporate workflow from $org_name/.github..."
  if gh api -H "Accept: application/vnd.github.raw" "repos/$org_name/.github/contents/workflow-templates/seguridad-vercel.yml" > "$temp_workflow" 2>/dev/null && [[ -s "$temp_workflow" ]]; then
    cp "$temp_workflow" "$target"
    rm -f "$temp_workflow"
    echo "Corporate workflow downloaded from $org_name/.github."
    return 0
  fi

  rm -f "$temp_workflow"
  echo "Could not download corporate workflow from $org_name/.github. Refusing to publish without the centralized action." >&2
  exit 1
}

copy_devsecops_scripts() {
  local org_name="$1"
  local script_target_dir=".github/devsecops/scripts"
  local names_json

  mkdir -p "$script_target_dir"
  echo "Downloading corporate DevSecOps scripts from $org_name/.github..."
  find "$script_target_dir" -maxdepth 1 -type f -name '*.sh' -delete
  names_json="$(gh api "repos/$org_name/.github/contents/workflow-templates/scripts" | node -e '
let data = "";
process.stdin.on("data", chunk => data += chunk);
process.stdin.on("end", () => {
  const files = JSON.parse(data).filter(item => item.type === "file" && item.name.endsWith(".sh")).map(item => item.name);
  process.stdout.write(JSON.stringify(files));
});
')"

  if [[ "$names_json" == "[]" || -z "$names_json" ]]; then
    echo "No corporate DevSecOps scripts found in $org_name/.github workflow-templates/scripts." >&2
    exit 1
  fi

  mapfile -t script_names < <(node -e 'for (const name of JSON.parse(process.argv[1])) console.log(name)' "$names_json")
  for script_name in "${script_names[@]}"; do
    if ! gh api -H "Accept: application/vnd.github.raw" "repos/$org_name/.github/contents/workflow-templates/scripts/$script_name" > "$script_target_dir/$script_name"; then
      echo "Could not download corporate DevSecOps script: $script_name" >&2
      exit 1
    fi
    if [[ ! -s "$script_target_dir/$script_name" ]]; then
      echo "Downloaded corporate DevSecOps script is empty: $script_name" >&2
      exit 1
    fi
  done
}

remove_blocked_from_index() {
  local tracked
  tracked="$(git ls-files | grep -E '(^|/)\.env($|\.|/)|(^|/).*\.(pem|p12|pfx|key)$|(^|/)id_rsa$|(^|/)id_ed25519$|(^|/)credentials\.json$|(^|/)service-account.*\.json$' | grep -vE '(^|/)\.env\.example$' || true)"
  if [[ -n "$tracked" ]]; then
    while IFS= read -r file; do
      git rm --cached --ignore-unmatch -- "$file" >/dev/null 2>&1 || true
    done <<< "$tracked"
  fi
}

security_gate() {
  local blocked
  blocked="$(git ls-files --others --cached --exclude-standard | grep -E '(^|/)\.env($|\.|/)|(^|/).*\.(pem|p12|pfx|key)$|(^|/)id_rsa$|(^|/)id_ed25519$|(^|/)credentials\.json$|(^|/)service-account.*\.json$' | grep -vE '(^|/)\.env\.example$' || true)"
  if [[ -n "$blocked" ]]; then
    echo "Sensitive files must not be published:" >&2
    printf '%s\n' "$blocked" >&2
    exit 1
  fi
}

dependency_usage_gate() {
  mapfile -d '' package_files < <(find . -name "package.json" -not -path "*/node_modules/*" -print0)
  if [[ ${#package_files[@]} -eq 0 ]]; then
    return 0
  fi

  require_command npx "npx was not found. Install Node.js/npm before publishing projects with package.json."
  local ignores="vite,@vitejs/*,astro,typescript,eslint,prettier,tailwindcss,postcss,autoprefixer"

  for pkg in "${package_files[@]}"; do
    local dir report unused_json remaining_json
    dir="$(dirname "$pkg")"
    echo "Checking dependency usage in $dir"
    pushd "$dir" >/dev/null

    report="$(mktemp)"
    npx --yes depcheck --json --ignores="$ignores" > "$report" || true
    unused_json="$(node - "$report" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const unused = [...(report.dependencies || []), ...(report.devDependencies || [])];
process.stdout.write(JSON.stringify([...new Set(unused)].sort()));
NODE
)"
    rm -f "$report"

    if [[ "$unused_json" != "[]" ]]; then
      mapfile -t unused < <(node -e 'for (const dep of JSON.parse(process.argv[1])) console.log(dep)' "$unused_json")
      echo "Removing unused package(s): ${unused[*]}"
      if [[ -f pnpm-lock.yaml ]]; then
        require_command pnpm "pnpm-lock.yaml was found, but pnpm is not available to remove unused dependencies."
        pnpm remove "${unused[@]}"
      else
        npm uninstall "${unused[@]}"
      fi

      report="$(mktemp)"
      npx --yes depcheck --json --ignores="$ignores" > "$report" || true
      remaining_json="$(node - "$report" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const unused = [...(report.dependencies || []), ...(report.devDependencies || [])];
process.stdout.write(JSON.stringify([...new Set(unused)].sort()));
NODE
)"
      rm -f "$report"
      if [[ "$remaining_json" != "[]" ]]; then
        echo "Unused package(s) remain after cleanup: $remaining_json" >&2
        exit 1
      fi
    fi

    popd >/dev/null
  done
}

package_manager_preflight() {
  mapfile -d '' package_files < <(find . -name "package.json" -not -path "*/node_modules/*" -print0)
  if [[ ${#package_files[@]} -eq 0 ]]; then
    echo "No package.json found; skipping package manager preflight."
    return 0
  fi

  require_command node "node was not found. Install Node.js before publishing JavaScript projects."
  require_command npm "npm was not found. Install Node.js/npm before publishing JavaScript projects."
  require_command npx "npx was not found. Install Node.js/npm before publishing JavaScript projects."

  for pkg in "${package_files[@]}"; do
    local dir
    dir="$(dirname "$pkg")"
    echo "Checking package manager in $dir"
    pushd "$dir" >/dev/null

    if [[ -f pnpm-lock.yaml ]]; then
      if ! command -v pnpm >/dev/null 2>&1; then
        corepack enable >/dev/null 2>&1 || true
        corepack prepare pnpm@10 --activate >/dev/null 2>&1 || true
      fi
      require_command pnpm "pnpm-lock.yaml was found, but pnpm is not available. Install pnpm or enable Corepack before publishing."
      pnpm --version
    elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
      npm --version
    else
      echo "No lockfile found in $dir; npm audit will generate a temporary package-lock in the workflow."
    fi

    popd >/dev/null
  done
}

ensure_remote() {
  local full_name="$1"
  local visibility="$2"
  local remote_name="$3"
  if ! gh repo view "$full_name" >/dev/null 2>&1; then
    gh repo create "$full_name" --"$visibility" --confirm
  fi
  local url="https://github.com/$full_name.git"
  if git remote get-url "$remote_name" >/dev/null 2>&1; then
    git remote set-url "$remote_name" "$url"
  else
    git remote add "$remote_name" "$url"
  fi
}

current_branch() {
  local branch
  branch="$(git branch --show-current || true)"
  if [[ -z "$branch" ]]; then
    branch="main"
    git checkout -B "$branch"
  fi
  printf '%s' "$branch"
}

remote_file_matches_local() {
  local full_name="$1"
  local branch="$2"
  local local_path="$3"
  local remote_path="$4"
  local temp_remote

  [[ -f "$local_path" ]] || return 1
  temp_remote="$(mktemp)"
  if ! gh api -H "Accept: application/vnd.github.raw" "repos/$full_name/contents/$remote_path?ref=$branch" > "$temp_remote" 2>/dev/null; then
    rm -f "$temp_remote"
    return 1
  fi
  if ! cmp -s "$local_path" "$temp_remote"; then
    rm -f "$temp_remote"
    return 1
  fi
  rm -f "$temp_remote"
  return 0
}

remote_devsecops_scripts_match_local() {
  local full_name="$1"
  local branch="$2"
  local script
  shopt -s nullglob
  local scripts=(.github/devsecops/scripts/*.sh)
  shopt -u nullglob

  if [[ ${#scripts[@]} -eq 0 ]]; then
    return 1
  fi

  for script in "${scripts[@]}"; do
    local name
    name="$(basename "$script")"
    if ! remote_file_matches_local "$full_name" "$branch" "$script" ".github/devsecops/scripts/$name"; then
      echo "Remote DevSecOps script is missing or stale: $name" >&2
      return 1
    fi
  done

  return 0
}

publish_workflow_first() {
  local full_name="$1"
  local remote_name="$2"
  local branch="$3"
  if [[ ! -f .github/workflows/seguridad-vercel.yml ]]; then
    echo "Security workflow is missing locally; refusing to publish repository files." >&2
    exit 1
  fi
  if [[ ! -d .github/devsecops/scripts ]]; then
    echo "Corporate DevSecOps scripts are missing locally; refusing to publish repository files." >&2
    exit 1
  fi
  git add .github/workflows/seguridad-vercel.yml
  git add .github/devsecops/scripts
  if [[ -f .github/devsecops-owner.json ]]; then
    git add .github/devsecops-owner.json
  fi
  if ! git diff --cached --quiet -- .github/workflows/seguridad-vercel.yml .github/devsecops/scripts .github/devsecops-owner.json; then
    git commit -m "Sync corporate DevSecOps gate"
  else
    echo "Security workflow and DevSecOps scripts already committed locally."
  fi
  git push -u "$remote_name" "$branch"
  if ! gh api "repos/$full_name/contents/.github/workflows/seguridad-vercel.yml?ref=$branch" >/dev/null 2>&1; then
    echo "Remote workflow was not found after stage 1. Aborting file publish." >&2
    exit 1
  fi
  if ! gh api "repos/$full_name/contents/.github/devsecops/scripts?ref=$branch" >/dev/null 2>&1; then
    echo "Remote DevSecOps scripts were not found after stage 1. Aborting file publish." >&2
    exit 1
  fi
  if ! remote_file_matches_local "$full_name" "$branch" ".github/workflows/seguridad-vercel.yml" ".github/workflows/seguridad-vercel.yml"; then
    echo "Remote security workflow is stale after stage 1. Aborting file publish." >&2
    exit 1
  fi
  if ! remote_devsecops_scripts_match_local "$full_name" "$branch"; then
    echo "Remote DevSecOps scripts are stale after stage 1. Aborting file publish." >&2
    exit 1
  fi
  echo "Security workflow and DevSecOps scripts are current remotely. Continuing with repository files."
}

stage_safe_files() {
  git add -A
  git reset -- .env .env.* '*.pem' '*.p12' '*.pfx' '*.key' id_rsa id_ed25519 credentials.json service-account*.json >/dev/null 2>&1 || true
  git add .env.example .gitignore .github/workflows/seguridad-vercel.yml 2>/dev/null || true
}

publish_current() {
  require_command git "Git was not found. Install Git before publishing."
  require_command gh "GitHub CLI was not found. Install GitHub CLI before publishing."
  local login github_email resolved_name full_name branch owner_user owner_email owner_metadata
  login="$(ensure_gcp_td_access "$ORG")"
  github_email="$(github_verified_email)"
  resolved_name="$(resolve_repo_name "$NAME" "$ORG" "$login")"
  full_name="$ORG/$resolved_name"
  owner_metadata="$(resolve_owner_metadata "$resolved_name" "$login" "$OWNER_EMAIL" "$github_email")"
  owner_user="${owner_metadata%%$'\t'*}"
  owner_email="${owner_metadata#*$'\t'}"
  ensure_git_repo
  ensure_gitignore
  copy_security_workflow "$ORG"
  copy_devsecops_scripts "$ORG"
  write_owner_metadata "$owner_user" "$owner_email"
  remove_blocked_from_index
  security_gate
  package_manager_preflight
  git config user.name "$login"
  git config user.email "$github_email"
  echo "Configured local Git author email from verified GitHub account: $github_email"
  ensure_remote "$full_name" "$VISIBILITY" "$REMOTE"
  branch="$(current_branch)"
  publish_workflow_first "$full_name" "$REMOTE" "$branch"
  dependency_usage_gate
  stage_safe_files
  if git diff --cached --quiet; then
    echo "No file changes to publish."
  else
    git commit -m "$COMMIT_MESSAGE"
    git push -u "$REMOTE" "$branch"
  fi
  echo "Published $full_name on branch $branch"
}

case "$ACTION" in
  ValidateTools)
    require_command git "Git was not found. Install Git before publishing."
    require_command gh "GitHub CLI was not found. Install GitHub CLI before publishing."
    echo '{"git":true,"gh":true}'
    ;;
  Login)
    require_command gh "GitHub CLI was not found. Install GitHub CLI before login."
    echo "GitHub CLI iniciara autenticacion web. Si el navegador no se abre, copia el codigo de un solo uso y abre el enlace que muestre GitHub CLI."
    gh auth login -h github.com -p https --web --skip-ssh-key --scopes repo,read:org,workflow
    ;;
  ForceLogin)
    require_command gh "GitHub CLI was not found. Install GitHub CLI before login."
    gh auth status -h github.com >/dev/null 2>&1 && gh auth logout -h github.com || true
    echo "GitHub CLI iniciara autenticacion web. Si el navegador no se abre, copia el codigo de un solo uso y abre el enlace que muestre GitHub CLI."
    gh auth login -h github.com -p https --web --skip-ssh-key --scopes repo,read:org,workflow
    ;;
  Logout)
    require_command gh "GitHub CLI was not found. Install GitHub CLI before logout."
    gh auth logout -h github.com
    ;;
  AuthStatus)
    require_command gh "GitHub CLI was not found. Install GitHub CLI before checking auth."
    login="$(ensure_gcp_td_access "$ORG")"
    gh api user/orgs --jq '{login: "'"$login"'", organizations: [.[] .login], hasGcpIa: any(.[]; .login == "'"$ORG"'"), organization: "'"$ORG"'"}'
    ;;
  PublishCurrent|publishcurrent|Start|start|Inicio|inicio|Init|init)
    publish_current
    ;;
  *)
    echo "Invalid action: $ACTION" >&2
    exit 2
    ;;
esac
