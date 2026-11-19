#!/usr/bin/env bash
# Testa o create_pr_azure do entrypoint.sh com um curl falso: 201 cria, 409 (PR já existe) segue,
# e erro de credencial, servidor ou rede falha.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# curl falso: escreve a resposta no -o e imprime o status de FAKE_HTTP_CODE; 000 simula falha de rede.
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
if [ "$FAKE_HTTP_CODE" = "000" ]; then printf '000'; exit 7; fi
printf '{"pullRequestId": 42, "message": "fake %s"}' "$FAKE_HTTP_CODE" > "$out"
printf '%s' "$FAKE_HTTP_CODE"
FAKE
chmod +x "$tmp/bin/curl"

functions="$tmp/functions.sh"
{
  grep -E '^log_(step|warn|error)\(\)' "$root/entrypoint.sh"
  sed -n '/^create_pr_azure() {/,/^}/p' "$root/entrypoint.sh"
} > "$functions"

run() {
  PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp" FAKE_HTTP_CODE="$1" \
    AZURE_ORG=o AZURE_PROJECT=p AZURE_REPO=r GH_ACCESS_TOKEN=t \
    bash -e -c ". '$functions'; create_pr_azure feature/x release title body"
}

fail=0
expect() {
  local code="$1" want="$2" got=0
  run "$code" > "$tmp/out.log" 2>&1 || got=$?
  if { [ "$want" = ok ] && [ "$got" -eq 0 ]; } || { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
    echo "ok   HTTP $code -> $want"
  else
    echo "FAIL HTTP $code: esperado $want, exit $got"; cat "$tmp/out.log"; fail=1
  fi
}

expect 201 ok
expect 409 ok
expect 401 fail
expect 403 fail
expect 400 fail
expect 500 fail
expect 000 fail
exit "$fail"
