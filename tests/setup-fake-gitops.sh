#!/bin/bash
# Prepara um GitOps falso para o teste da action: repo bare local (o clone https é redirecionado
# para ele por insteadOf, num gitconfig global só do teste) e um gh falso que registra as chamadas.
# Nada sai do runner. Uso: setup-fake-gitops.sh <dir> <bin-da-action>
set -euo pipefail
work="$1"; action_bin="$2"
mkdir -p "$work" "$action_bin"

src="$work/src"
git init -q -b develop "$src"
git -C "$src" config user.email test@example.com
git -C "$src" config user.name test

mkdir -p "$src/k8s/kustom-app/overlays/dev" "$src/k8s/finaya-app/overlays/dev"
cat > "$src/k8s/kustom-app/overlays/dev/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
images:
  - name: IMAGE
    newName: registry.example/old
    newTag: old
YAML
cat > "$src/k8s/kustom-app/overlays/dev/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kustom-app
YAML
cat > "$src/k8s/finaya-app/overlays/dev/app.yaml" <<'YAML'
apiVersion: finaya.tech/v1
kind: FinayaApplication
metadata:
  name: finaya-app
spec:
  image:
    repository: registry.example/old
    tag: old
YAML
# Overlay do operator com o label de versão (padrão dos repos migrados): a action deve atualizá-lo.
cat > "$src/k8s/finaya-app/overlays/dev/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app.yaml
labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/name: finaya-app
  - includeSelectors: false
    includeTemplates: true
    pairs:
      app.kubernetes.io/version: old
YAML
git -C "$src" add -A
git -C "$src" commit -qm fixture
git clone -q --bare "$src" "$work/gitops.git"

# O entrypoint clona https://x-access-token:<token>@<url>; o gitconfig do teste aponta isso para o bare.
cat > "$work/gitconfig" <<CFG
[url "file://$work/gitops.git"]
	insteadOf = https://x-access-token:test-token@github.com/fake/gitops.git
[safe]
	directory = *
CFG

# gh falso: registra cada chamada; devolve o SHA do develop no GET do ref e um oid no graphql
# (guardando o payload, que o teste confere).
cat > "$action_bin/gh" <<GH
#!/bin/bash
echo "gh \$*" >> "$work/gh-calls.log"
case "\$*" in
  *"api graphql"*) cat > "$work/graphql-payload.json"; echo 0000000000000000000000000000000000000001 ;;
  *"git/ref/heads/"*) git -C "$work/gitops.git" rev-parse develop ;;
  *) : ;;
esac
GH
chmod +x "$action_bin/gh"
