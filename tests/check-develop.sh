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
  [ "$path" = "k8s/$app/overlays/dev/app.yaml" ] && ok "arquivo alterado" || bad "arquivo: $path"
  grep -q "repository: registry.example/$app" <<<"$content" && ok "repository" || bad "repository"
  grep -q "tag: $RELEASE_VERSION" <<<"$content" && ok "tag" || bad "tag"
fi

grep -q "api repos/fake/gitops/merges" "$work/gh-calls.log" && ok "merge develop -> release" || bad "merge não chamado"
exit "$fail"
