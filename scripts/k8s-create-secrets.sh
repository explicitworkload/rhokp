#!/usr/bin/env bash
#
# Create the two secrets that k8s/rhokp-deployment.yaml expects, from input you
# supply at run time. Nothing sensitive is written to the repo.
#
#   redhat-registry-secret  kubernetes.io/dockerconfigjson  (pulls the image)
#   rhokp-access-key        Opaque, key ACCESS_KEY          (unlocks the portal)
#
# Usage:
#   scripts/k8s-create-secrets.sh                                  # prompt
#   scripts/k8s-create-secrets.sh -p ./pull-secret.json -n rhokp-portal
#
set -euo pipefail

NAMESPACE="rhokp-portal"
PULL_SECRET_SRC=""
ACCESS_KEY_SRC=""

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)   NAMESPACE="${2:?}";        shift 2 ;;
    -p|--pull-secret) PULL_SECRET_SRC="${2:?}";  shift 2 ;;
    -k|--access-key)  ACCESS_KEY_SRC="${2:?}";   shift 2 ;;
    -h|--help)        sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

KUBECTL="$(command -v oc || command -v kubectl)" || die "neither oc nor kubectl is on PATH."

# --- pull secret -----------------------------------------------------------

if [[ -z "${PULL_SECRET_SRC}" ]]; then
  echo "Download your pull secret from https://console.redhat.com/openshift/install/pull-secret"
  read -rp "Path to pull-secret.json: " PULL_SECRET_SRC
fi
PULL_SECRET_SRC="${PULL_SECRET_SRC/#\~/$HOME}"
[[ -f "${PULL_SECRET_SRC}" ]] || die "no such file: ${PULL_SECRET_SRC}"

python3 -I -c '
import json, sys
auths = json.load(open(sys.argv[1]))["auths"]
if "registry.redhat.io" not in auths:
    sys.exit("no registry.redhat.io entry in auths; the image pull will fail.")
' "${PULL_SECRET_SRC}" || die "that file is not a usable pull secret."

# --- access key ------------------------------------------------------------

if [[ -n "${ACCESS_KEY_SRC}" ]]; then
  ACCESS_KEY_SRC="${ACCESS_KEY_SRC/#\~/$HOME}"
  [[ -f "${ACCESS_KEY_SRC}" ]] || die "no such file: ${ACCESS_KEY_SRC}"
  ACCESS_KEY="$(tr -d '\r\n' < "${ACCESS_KEY_SRC}")"
else
  read -rsp "RHOKP access key: " ACCESS_KEY; echo
fi
[[ -n "${ACCESS_KEY}" ]] || die "the access key cannot be empty."

# --- apply -----------------------------------------------------------------

"${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1 \
  || "${KUBECTL}" create namespace "${NAMESPACE}"

info "Creating redhat-registry-secret in ${NAMESPACE}"
"${KUBECTL}" create secret docker-registry redhat-registry-secret \
  --namespace "${NAMESPACE}" \
  --from-file=".dockerconfigjson=${PULL_SECRET_SRC}" \
  --dry-run=client -o yaml | "${KUBECTL}" apply -f -

info "Creating rhokp-access-key in ${NAMESPACE}"
# Staged through a 0600 temp file rather than --from-literal so the key never
# shows up in the process list.
umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
printf '%s' "${ACCESS_KEY}" > "${WORKDIR}/ACCESS_KEY"
unset ACCESS_KEY

"${KUBECTL}" create secret generic rhokp-access-key \
  --namespace "${NAMESPACE}" \
  --from-file="ACCESS_KEY=${WORKDIR}/ACCESS_KEY" \
  --dry-run=client -o yaml | "${KUBECTL}" apply -f -

cat <<EOF

Both secrets are in place. Deploy the workload with:
  ${KUBECTL##*/} apply -f k8s/rhokp-deployment.yaml
EOF
