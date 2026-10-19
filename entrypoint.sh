#!/bin/bash
set -e

GITOPS_REPO_NAME="$1"
GITOPS_REPO_URL="$2"
GH_ACCESS_TOKEN="$3"
IMAGE_NAME="$4"
APP_ID="$5"
GITHUB_ACTOR="$6"

# Extract owner and repo from URL (format: github.com/owner/repo)
REPO_OWNER=$(echo "$GITOPS_REPO_URL" | cut -d'/' -f2)
REPO_NAME=$(echo "$GITOPS_REPO_URL" | cut -d'/' -f3 | sed 's/\.git$//')

export GITHUB_TOKEN="${GH_ACCESS_TOKEN}"
export GH_TOKEN="${GH_ACCESS_TOKEN}"

# --- Logging helpers ---
log_header() { printf "\033[0;36m=> %s\033[0m\n" "$1"; }
log_step()   { printf "\033[0;32m=> %s\033[0m\n" "$1"; }
log_error()  { printf "\033[0;31m=> %s\033[0m\n" "$1"; }
log_warn()   { printf "\033[0;33m=> %s\033[0m\n" "$1"; }

# --- Reusable functions ---
clone_repo() {
  local branch="$1"
  log_step "Cloning ${GITOPS_REPO_NAME} - Branch: ${branch}"
  git clone "https://x-access-token:${GH_ACCESS_TOKEN}@${GITOPS_REPO_URL}" -b "$branch"
  cd "${GITOPS_REPO_NAME}"
  git config --local user.email "action@finaya.tech"
  git config --local user.name "GitHub Action"
  echo "Repo ${GITOPS_REPO_NAME} cloned!!!"
  REPO_ROOT="$(pwd)"
}

apply_kustomize() {
  local overlay="$1"
  local overlay_dir="k8s/${APP_ID}/overlays/${overlay}"
  if [ ! -d "$overlay_dir" ]; then
    log_error "Error: Directory ${overlay_dir} does not exist"
    exit 1
  fi
  cd "$overlay_dir"

  if grep -rql "kind: FinayaApplication" . >/dev/null 2>&1; then
    log_step "FinayaApplication detected - updating image directly"
    local app_file
    app_file=$(grep -rl "kind: FinayaApplication" .)
    yq -i '.spec.image.repository = "'"${IMAGE_NAME}"'" | .spec.image.tag = "'"${RELEASE_VERSION}"'"' "$app_file"
  else
    kustomize edit set image "IMAGE=${IMAGE_NAME}:${RELEASE_VERSION}"
    yq -i 'del(.labels[] | select(.pairs."app.kubernetes.io/version")) | .labels += [{"pairs": {"app.kubernetes.io/version": "'"${RELEASE_VERSION}"'"}, "includeSelectors": false, "includeTemplates": true}]' kustomization.yaml
    kustomize edit set label "app.kubernetes.io/name:${APP_ID}"
    kustomize edit set label "app.kubernetes.io/managed-by:kustomize"
    kustomize edit set label "app.kubernetes.io/created-by-repo:${GITOPS_REPO_NAME}"
    kustomize edit set annotation "finaya.tech/origin:${GITHUB_REPOSITORY}@${GITHUB_REF#refs/*/}"
  fi
  echo "Done!!"
  cd "$REPO_ROOT"
}

create_pr() {
  local head="$1" base="$2" env_name="$3" env_display="$4"
  if gh pr create --head "$head" --base "$base" \
    -t "[${env_display}] Deploy ${APP_ID}" \
    --body "**Microservice:** ${APP_ID}
**Environment:** ${env_name}
**Deployed by:** ${GITHUB_ACTOR}
**Branch:** ${head}
**Release version:** ${RELEASE_VERSION}

This PR updates only the ${APP_ID} microservice in the ${env_name,,} environment."; then
    log_step "PR created successfully"
  else
    log_warn "PR already exists or an error occurred, skipping..."
  fi
}

# Creates a verified commit via GitHub API (commits via API are automatically verified by GitHub Apps).
# Must be called from REPO_ROOT after `git add` has staged the desired changes.
# Creates a commit using the GraphQL createCommitOnBranch mutation.
# This is the only way to produce commits with verified signatures via GitHub App tokens.
# The REST API /git/commits does NOT produce verified commits.
commit_via_api() {
  local branch="$1"
  local message="$2"

  local parent_sha
  parent_sha=$(git rev-parse HEAD)

  # Collect staged files
  local changed_files deleted_files
  changed_files=$(git diff --cached --name-only)
  deleted_files=$(git diff --cached --name-only --diff-filter=D)

  # Build additions array (modified/new files with base64 content)
  local additions="[]"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! echo "$deleted_files" | grep -qx "$file"; then
      additions=$(echo "$additions" | jq \
        --arg path "$file" \
        --arg contents "$(base64 -w 0 "$file")" \
        '. + [{"path": $path, "contents": $contents}]')
    fi
  done <<< "$changed_files"

  # Build deletions array
  local deletions="[]"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    deletions=$(echo "$deletions" | jq --arg path "$file" '. + [{"path": $path}]')
  done <<< "$deleted_files"

  # Ensure the remote branch exists before committing to it
  if ! git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/refs" \
      -f ref="refs/heads/${branch}" \
      -f sha="$parent_sha"
    log_step "Remote branch ${branch} created"
  fi

  local gql_query='mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }'

  # Re-read the tip on each attempt: a sibling deploy job can advance the branch
  # between the read and this optimistic-locked commit and reject the mutation.
  local attempt=1 expected_head new_commit_sha
  while : ; do
    expected_head=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/ref/heads/${branch}" --jq '.object.sha') || expected_head=""
    if [ -n "$expected_head" ] && new_commit_sha=$(jq -n \
        --arg query  "$gql_query" \
        --arg repo   "${REPO_OWNER}/${REPO_NAME}" \
        --arg branch "$branch" \
        --arg head   "$expected_head" \
        --arg msg    "$message" \
        --argjson additions "$additions" \
        --argjson deletions "$deletions" \
        '{
          "query": $query,
          "variables": {
            "input": {
              "branch":          {"repositoryNameWithOwner": $repo, "branchName": $branch},
              "message":         {"headline": $msg},
              "fileChanges":     {"additions": $additions, "deletions": $deletions},
              "expectedHeadOid": $head
            }
          }
        }' \
        | gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'); then
      log_step "Verified commit created: ${new_commit_sha}"
      log_step "Branch ${branch} updated on remote"
      return 0
    fi

    local max_attempts="${GITOPS_PUSH_MAX_ATTEMPTS:-8}"
    if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [ "$max_attempts" -lt 1 ]; then
      log_warn "GITOPS_PUSH_MAX_ATTEMPTS='${GITOPS_PUSH_MAX_ATTEMPTS}' is not a positive integer, defaulting to 8"
      max_attempts=8
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      log_error "Failed to push to ${branch} after ${attempt} attempts"
      return 1
    fi
    sleep "$(( attempt < 6 ? attempt : 6 ))"
    attempt=$(( attempt + 1 ))
  done
}

commit_and_push() {
  local branch="$1" message="$2"
  shift 2
  local add_paths=("$@")

  git add "${add_paths[@]:-.}"

  if git diff --cached --quiet; then
    log_warn "No changes to commit - already up to date"
    return 0
  fi

  commit_via_api "$branch" "$message"
}

# Reads the tag currently written in the overlay, in whichever of the two shapes the
# manifest uses.
current_overlay_tag() {
  local overlay_dir="k8s/${APP_ID}/overlays/$1"
  local app_file
  # head -1: o overlay pode ter mais de um arquivo com o kind, e yq com dois caminhos
  # devolveria dois valores para uma variavel que espera um
  if app_file=$(grep -rl "kind: FinayaApplication" "$overlay_dir" 2>/dev/null | head -n1) && [ -n "$app_file" ]; then
    yq -r '.spec.image.tag // ""' "$app_file"
  elif [ -f "${overlay_dir}/kustomization.yaml" ]; then
    yq -r '(.images[] | select(.name == "IMAGE") | .newTag) // ""' "${overlay_dir}/kustomization.yaml"
  fi
}

# True when the tag already in the manifest DESCENDS from the one we are about to write:
# what is deployed already contains this commit, so writing would roll the environment back.
#
# Why this exists: the deploy order is the order the BUILDS finish, not the order the commits
# were made. Two PRs merged 16 seconds apart put the older commit in DEV, because its build
# was the slower one and wrote last. Measured in this gitops repo on 2026-09-08:
#
#   21:10:58  Deploy fin-vehicle-financing-service to DEV - version 1e789d2   <- newer commit
#   21:11:01  Deploy fin-vehicle-financing-service to DEV - version 71a1256   <- older, 3s later
#
# Nothing signals it: both builds are green, the commit message looks like any other, the pod
# stays 1/1 healthy, and ArgoCD syncs what it is told. Nothing is broken - it is just old.
#
# Fails open on purpose: a comparison that cannot be answered keeps today's behaviour instead
# of blocking a deploy on an API hiccup.
manifest_is_newer_than_release() {
  local current="$1"
  if [ -z "$current" ] || [ "$current" = "null" ] || [ "$current" = "$RELEASE_VERSION" ]; then
    return 1
  fi

  # As duas entram numa URL de API. Sao sha ou tag, entao a forma esperada e a de uma
  # referencia git; qualquer outra coisa nao e comparavel e o fluxo segue como antes.
  if ! printf '%s' "$current$RELEASE_VERSION" | grep -qE '^[A-Za-z0-9._/-]+$'; then
    log_warn "Tag fora do formato esperado (${current} / ${RELEASE_VERSION}) - writing the tag as usual"
    return 1
  fi

  local status
  if ! status=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${RELEASE_VERSION}...${current}" --jq '.status' 2>/dev/null); then
    log_warn "Could not compare ${RELEASE_VERSION} with ${current} in ${GITHUB_REPOSITORY} - writing the tag as usual"
    return 1
  fi

  [ "$status" = "ahead" ]
}

delete_remote_branch_if_exists() {
  local branch="$1"

  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log_warn "Remote branch ${branch} already exists. Deleting..."
    git push origin --delete "$branch"
    log_step "Remote branch ${branch} deleted"
  else
    log_step "Remote branch ${branch} does not exist. Continuing..."
  fi
}

# --- Main logic ---

if [[ "$GITOPS_BRANCH" == "develop" ]]; then
  log_header "Condition 1: Develop environment"
  clone_repo develop

  # DEV is the only environment written unattended - homolog and prod go through a PR, where a
  # regression is at least visible to a human. Set GITOPS_ALLOW_TAG_ROLLBACK=true to write an
  # older tag on purpose, which is what a rollback is.
  DEV_CURRENT_TAG=$(current_overlay_tag dev)
  if [ "${GITOPS_ALLOW_TAG_ROLLBACK:-false}" != "true" ] && manifest_is_newer_than_release "${DEV_CURRENT_TAG}"; then
    log_warn "DEV already runs ${DEV_CURRENT_TAG}, which already contains ${RELEASE_VERSION}"
    log_warn "Skipping the write: this build finished after a newer one and would roll DEV back"
  else
    log_step "Develop branch Kustomize step - DEV Overlay"
    apply_kustomize dev

    log_step "Git commit and push directly to develop"
    commit_and_push develop "Deploy ${APP_ID} to DEV - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"
  fi

  log_step "Merge develop into release branch via API"
  # gh api exits 0 for 201 (merged) and 204 (already up to date), non-zero for 409 (conflict)
  if ! gh api "repos/${REPO_OWNER}/${REPO_NAME}/merges" \
    --silent \
    -f base="release" \
    -f head="develop" \
    -f commit_message="Merge develop into release after deploying ${APP_ID} ${RELEASE_VERSION}"; then
    log_error "Merge conflict between develop and release - manual resolution required"
    exit 1
  fi
  log_step "develop merged into release"

elif [[ "$GITOPS_BRANCH" == "homolog" ]] || [[ "$GITOPS_BRANCH" == "release" ]]; then
  BRANCH_NAME="deploy/homolog/${APP_ID}"
  log_header "Condition 2: Homolog environment"
  clone_repo release

  delete_remote_branch_if_exists "${BRANCH_NAME}"

  log_step "Creating individual branch: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Homolog branch Kustomize step - HML Overlay"
  apply_kustomize homolog

  log_step "Git commit and push individual branch"
  commit_and_push "${BRANCH_NAME}" "Deploy ${APP_ID} to HOMOLOG - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"

  log_step "Open individual PR: ${BRANCH_NAME} -> release"
  create_pr "${BRANCH_NAME}" release "Homolog" "HOMOLOG"
fi

if [[ "$GITOPS_BRANCH" == "release" ]]; then
  BRANCH_NAME="deploy/${GITOPS_BRANCH}/${APP_ID}"
  log_header "Condition 3: New release (HML and PRD environment)"
  clone_repo master

  log_step "Returning to release branch for PRD PR"
  git checkout master

  delete_remote_branch_if_exists "${BRANCH_NAME}"

  log_step "Creating branch for PRODUCTION: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Release branch Kustomize step - PRD Overlay"
  apply_kustomize prod

  log_step "Git commit and push PRODUCTION branch"
  commit_and_push "${BRANCH_NAME}" "Deploy ${APP_ID} to PRD - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}" "k8s/${APP_ID}/overlays/prod"

  log_step "Open PR for PRODUCTION: ${BRANCH_NAME} -> master"
  create_pr "${BRANCH_NAME}" master "Production" "PRODUCTION"
fi
