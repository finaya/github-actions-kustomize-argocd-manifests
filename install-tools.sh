#!/bin/bash
# Instala kustomize, yq e gh em $RUNNER_TEMP/kustomize-argocd-manifests/bin, com versão e sha256
# vindos do action.yml. Idempotente: vários steps desta action no mesmo job baixam uma vez só.
set -euo pipefail

dir="${RUNNER_TEMP}/kustomize-argocd-manifests"
bin="$dir/bin"
mkdir -p "$bin"

for tool in git curl jq base64; do
  command -v "$tool" >/dev/null || { echo "::error::$tool não encontrado no runner"; exit 1; }
done

case "${RUNNER_ARCH}" in
  X64)   arch=amd64; arch_var=AMD64 ;;
  ARM64) arch=arm64; arch_var=ARM64 ;;
  *) echo "::error::Arquitetura não suportada: ${RUNNER_ARCH}"; exit 1 ;;
esac
sha_of() { local v="${1}_SHA256_${arch_var}"; echo "${!v}"; }

# Baixa $2 em $1 e confere o sha256 $3. HTTPS forçado também nos redirects do GitHub.
get() {
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 30 -o "$1" "$2"
  echo "$3  $1" | sha256sum -c -
}

if [ ! -x "$bin/kustomize" ]; then
  get "$dir/kustomize.tar.gz" \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${arch}.tar.gz" \
    "$(sha_of KUSTOMIZE)"
  tar -xzf "$dir/kustomize.tar.gz" -C "$bin" kustomize
fi

if [ ! -x "$bin/yq" ]; then
  get "$bin/yq" \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}" \
    "$(sha_of YQ)"
  chmod +x "$bin/yq"
fi

if [ ! -x "$bin/gh" ]; then
  get "$dir/gh.tar.gz" \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
    "$(sha_of GH)"
  tar -xzf "$dir/gh.tar.gz" -C "$bin" --strip-components=2 "gh_${GH_VERSION}_linux_${arch}/bin/gh"
fi

"$bin/kustomize" version
"$bin/yq" --version
"$bin/gh" --version | head -1
