#!/bin/bash
# Confere o que a action fez no fluxo develop: o commit que iria pela API do GitHub (payload do
# graphql) tem o overlay com a imagem e os labels novos, e o merge develop -> release foi pedido.
set -euo pipefail
work="$1"; app="$2"; kind="$3"
payload="$work/graphql-payload.json"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "::error::$*"; fail=1; }

jq -e '.variables.input.branch.branchName == "develop"' "$payload" >/dev/null && ok "commit no develop" || bad "branch do commit"
jq -e --arg h "$(git -C "$work/gitops.git" rev-parse develop)" '.variables.input.expectedHeadOid == $h' "$payload" >/dev/null \
  && ok "expectedHeadOid = topo do develop" || bad "expectedHeadOid"

content=$(jq -r '.variables.input.fileChanges.additions[0].contents' "$payload" | base64 -d)
path=$(jq -r '.variables.input.fileChanges.additions[0].path' "$payload")
echo "--- $path"; echo "$content"; echo "---"

if [ "$kind" = kustomize ]; then
  [ "$path" = "k8s/$app/overlays/dev/kustomization.yaml" ] && ok "arquivo alterado" || bad "arquivo: $path"
  grep -q "newName: registry.example/$app" <<<"$content" && ok "newName" || bad "newName"
  grep -q "newTag: $RELEASE_VERSION" <<<"$content" && ok "newTag" || bad "newTag"
  grep -q "app.kubernetes.io/version: $RELEASE_VERSION" <<<"$content" && ok "label version" || bad "label version"
  grep -q "app.kubernetes.io/name: $app" <<<"$content" && ok "label name" || bad "label name"
  grep -q "finaya.tech/origin:" <<<"$content" && ok "annotation origin" || bad "annotation origin"
else
  # O commit pode trazer mais de um arquivo (app.yaml e kustomization.yaml): conferir cada um pelo path.
  file_of() { jq -r --arg p "$1" '.variables.input.fileChanges.additions[] | select(.path == $p) | .contents' "$payload" | base64 -d; }
  app_content=$(file_of "k8s/$app/overlays/dev/app.yaml")
  [ -n "$app_content" ] && ok "app.yaml alterado" || bad "app.yaml não está no commit"
  grep -q "repository: registry.example/$app" <<<"$app_content" && ok "repository" || bad "repository"
  grep -q "tag: $RELEASE_VERSION" <<<"$app_content" && ok "tag" || bad "tag"
  kus_content=$(file_of "k8s/$app/overlays/dev/kustomization.yaml")
  grep -q "app.kubernetes.io/version: $RELEASE_VERSION" <<<"$kus_content" && ok "label version" || bad "label version"
  grep -q "app.kubernetes.io/name: $app" <<<"$kus_content" && ok "label name preservado" || bad "label name"
fi

grep -q "api repos/fake/gitops/merges" "$work/gh-calls.log" && ok "merge develop -> release" || bad "merge não chamado"
exit "$fail"
