#!/usr/bin/env bash
set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
REPO_PATH="${REPO_PATH:-policy/med}"
TAG="${TAG:-v1}"
BUNDLE="${BUNDLE:-bundle.tar.gz}"
INSTALL_ORAS_VERSION="${INSTALL_ORAS_VERSION:-1.3.0}"

GH_USER="${GH_USER:-}"
GH_PAT="${GH_PAT:-}"
if [[ -z "${GH_USER}" ]]; then read -r -p "GitHub username: " GH_USER; fi
if [[ -z "${GH_PAT}" ]]; then read -r -s -p "GitHub PAT: " GH_PAT; echo; fi

mkdir -p "$HOME/bin"
case ":$PATH:" in *":$HOME/bin:"*) ;; *) export PATH="$HOME/bin:$PATH";; esac

if ! command -v oras >/dev/null 2>&1; then
  curl -sSL -o /tmp/oras.tgz "https://github.com/oras-project/oras/releases/download/v${INSTALL_ORAS_VERSION}/oras_${INSTALL_ORAS_VERSION}_linux_amd64.tar.gz"
  tar -zxf /tmp/oras.tgz -C "$HOME/bin" oras
fi
if ! command -v cosign >/dev/null 2>&1; then
  curl -sSL -o "$HOME/bin/cosign" https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
  chmod +x "$HOME/bin/cosign"
fi
if ! command -v opa >/dev/null 2>&1; then
  curl -sSL -o "$HOME/bin/opa" https://openpolicyagent.org/downloads/latest/opa_linux_amd64
  chmod +x "$HOME/bin/opa"
fi

echo "Tools installed:"
echo "- $(oras version || true)"
echo "- $(cosign version || true)"
echo "- OPA $(opa version | awk 'NR==1{print $2}')"

mkdir -p policy examples dist
cat > policy/policy.rego <<'EOF'
package med
default allow := false
allow if {
  input.pii == true
  input.purpose == "treatment"
  input.consent == true
}
allow if { not input.pii }
EOF

cat > examples/input_allow.json <<'EOF'
{ "pii": true, "purpose": "treatment", "consent": true }
EOF
cat > examples/input_deny.json <<'EOF'
{ "pii": true, "purpose": "research", "consent": false }
EOF

opa build -b policy -o "$BUNDLE"

oras login "$REGISTRY_HOST" -u "$GH_USER" -p "$GH_PAT"
REG="$REGISTRY_HOST/$GH_USER"
echo '{}' > config.json

PUSH_LOG=$(oras push "$REG/$REPO_PATH:$TAG" \
  --config config.json:application/vnd.oci.image.config.v1+json \
  "$BUNDLE":application/vnd.oci.image.layer.v1.tar+gzip 2>&1 | tee /dev/tty)

DIGEST=$(echo "$PUSH_LOG" | awk '/Digest:/ {print $2; exit}')
if [[ -z "${DIGEST}" ]]; then
  echo "Failed to parse digest from ORAS output"; exit 1
fi
REF="$REG/$REPO_PATH@$DIGEST"
echo "Pushed: $REF"

export COSIGN_PASSWORD="${COSIGN_PASSWORD:-1}"
[[ -f cosign.key && -f cosign.pub ]] || cosign generate-key-pair
cosign sign --key cosign.key "$REF"
cosign verify --key cosign.pub "$REF" >/dev/null
echo "Signature verified"

mkdir -p /tmp/bundle && cd /tmp/bundle
oras pull "$REF"
tar -xzf "$BUNDLE"

echo -n "allow (treatment) -> "
opa eval -i ~/examples/input_allow.json -d . 'data.med.allow' --format=pretty
echo -n "allow (research)  -> "
opa eval -i ~/examples/input_deny.json  -d . 'data.med.allow' --format=pretty