#!/bin/bash
#
# Prova as duas funcoes de guarda do entrypoint.sh sem subir o action: extrai o bloco das
# funcoes, injeta um `gh` de mentira e roda os casos sobre um manifesto de verdade.
#
# Uso:  bash tests/tag-guard-test.sh entrypoint.sh
#
# O caso que le a tag do kustomization.yaml precisa do `yq` no PATH (o mesmo binario que o
# Dockerfile instala); sem ele, esse caso e pulado e os demais rodam.
set -u
ACTION=${1:-entrypoint.sh}
# caminho absoluto antes do cd: o teste roda num diretorio temporario
ACTION=$(cd "$(dirname "$ACTION")" && pwd)/$(basename "$ACTION")
work=$(mktemp -d); cd "$work" || exit 1

# extrai só as duas funcoes + os helpers de log
sed -n '/^log_header()/,/^log_warn()/p' "$ACTION" > funcs.sh
sed -n '/^current_overlay_tag()/,/^}/p' "$ACTION" >> funcs.sh
sed -n '/^manifest_is_newer_than_release()/,/^  \[ "\$status" = "ahead" \]$/p' "$ACTION" >> funcs.sh
echo '}' >> funcs.sh

# gh de mentira: responde o status do compare a partir de COMPARE_STATUS
cat > gh <<'GH'
#!/bin/bash
if [ "${COMPARE_FAILS:-false}" = "true" ]; then exit 22; fi
echo "${COMPARE_STATUS:-behind}"
GH
chmod +x gh; export PATH="$work:$PATH"

# manifesto de mentira, no formato real
mkdir -p k8s/app/overlays/dev
cat > k8s/app/overlays/dev/kustomization.yaml <<'K'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
- name: IMAGE
  newName: registry/app
  newTag: 436ea24
K

# usadas pelas funcoes extraidas do entrypoint
# shellcheck disable=SC2034
APP_ID=app
# shellcheck disable=SC2034
GITHUB_REPOSITORY=org/app
# shellcheck disable=SC1091
. ./funcs.sh

falhas=0
check() { # nome, esperado(0=pula,1=escreve), comando
  local nome=$1 esperado=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" != "$esperado" ]; then echo "FALHOU  $nome (esperado $esperado, veio $got)"; falhas=$((falhas+1));
  else echo "ok      $nome"; fi
}

if command -v yq >/dev/null 2>&1; then
  tag=$(current_overlay_tag dev)
  [ "$tag" = "436ea24" ] && echo "ok      le a tag do kustomization.yaml" \
    || { echo "FALHOU  le a tag: '$tag'"; falhas=$((falhas+1)); }
else
  echo "pulado  le a tag do kustomization.yaml (sem yq no PATH)"
fi

# shellcheck disable=SC2034
RELEASE_VERSION=aaaaaaa
COMPARE_STATUS=ahead   check "manifesto ja contem o nosso commit -> pula"       0 manifest_is_newer_than_release 436ea24
COMPARE_STATUS=behind  check "manifesto e mais velho -> escreve"                1 manifest_is_newer_than_release 436ea24
COMPARE_STATUS=diverged check "historias divergentes -> escreve"                1 manifest_is_newer_than_release 436ea24
COMPARE_STATUS=identical check "mesma arvore, sha diferente -> escreve"         1 manifest_is_newer_than_release 436ea24
COMPARE_FAILS=true     check "compare indisponivel -> escreve (falha aberta)"   1 manifest_is_newer_than_release 436ea24
COMPARE_STATUS=ahead   check "overlay sem tag -> escreve"                       1 manifest_is_newer_than_release ""
COMPARE_STATUS=ahead   check "yq devolveu null -> escreve"                      1 manifest_is_newer_than_release null
# shellcheck disable=SC2034
RELEASE_VERSION=436ea24
COMPARE_STATUS=ahead   check "mesma tag -> escreve (idempotente)"               1 manifest_is_newer_than_release 436ea24

echo; [ "$falhas" = 0 ] && echo "TODOS OS CASOS PASSARAM" || echo "$falhas caso(s) falharam"
cd /; rm -rf "$work"; exit "$falhas"
