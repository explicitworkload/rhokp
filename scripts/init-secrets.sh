#!/usr/bin/env bash
#
# Turn your plaintext RHOKP credentials into local Ansible Vault files.
#
#
#   playbooks/secrets/access-key.vault        <- AES256
#   playbooks/secrets/pull-secret.json.vault  <- AES256
#   playbooks/secrets/vault-password          <- the password
#
# All three are gitignored. This repo is public, so no credential material is
# committed -- not even the encrypted files. Committing them is only ever
# appropriate on a PRIVATE fork. See "RHDP" in README.md.
#
# Usage:
#   scripts/init-secrets.sh                       # prompt for anything missing
#   scripts/init-secrets.sh -p ./pull-secret.json -k ./rhokp-access-key
#   scripts/init-secrets.sh --rekey                # re-encrypt with a new password
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/playbooks/secrets"
VAULT_PASS_FILE="${SECRETS_DIR}/vault-password"

PULL_SECRET_SRC=""
ACCESS_KEY_SRC=""
REKEY=0

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pull-secret) PULL_SECRET_SRC="${2:?}"; shift 2 ;;
    -k|--access-key)  ACCESS_KEY_SRC="${2:?}";  shift 2 ;;
    --rekey)          REKEY=1; shift ;;
    -h|--help)        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

command -v ansible-vault >/dev/null || die "ansible-vault not found. Install ansible-core first."
command -v python3       >/dev/null || die "python3 not found (needed to validate the pull secret)."

umask 077
mkdir -p "${SECRETS_DIR}"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# --- 1. vault password -----------------------------------------------------

if [[ -f "${VAULT_PASS_FILE}" && "${REKEY}" -eq 0 ]]; then
  info "Reusing the existing vault password at playbooks/secrets/vault-password"
else
  [[ "${REKEY}" -eq 1 && -f "${VAULT_PASS_FILE}" ]] && warn "Rekeying: existing vault files must be re-encrypted (this script does that)."
  echo
  echo "Choose a vault password. You will need it on every control node that runs"
  echo "the playbook, so store it in your password manager -- it is the only thing"
  echo "standing between a repo reader and your credentials."
  read -rsp "Vault password: " pw1; echo
  read -rsp "Confirm:        " pw2; echo
  [[ -n "${pw1}" ]]        || die "the vault password cannot be empty."
  [[ "${pw1}" == "${pw2}" ]] || die "passwords did not match."
  printf '%s' "${pw1}" > "${VAULT_PASS_FILE}"
  chmod 600 "${VAULT_PASS_FILE}"
  unset pw1 pw2
  info "Wrote playbooks/secrets/vault-password (gitignored)"
fi

VAULT=(ansible-vault encrypt --vault-password-file "${VAULT_PASS_FILE}")

# --- 2. registry pull secret ----------------------------------------------

if [[ -z "${PULL_SECRET_SRC}" ]]; then
  if [[ -f "${REPO_ROOT}/pull-secret.json" ]]; then
    PULL_SECRET_SRC="${REPO_ROOT}/pull-secret.json"
  else
    echo
    echo "Download your pull secret from:"
    echo "  https://console.redhat.com/openshift/install/pull-secret"
    read -rp "Path to pull-secret.json: " PULL_SECRET_SRC
  fi
fi
PULL_SECRET_SRC="${PULL_SECRET_SRC/#\~/$HOME}"
[[ -f "${PULL_SECRET_SRC}" ]] || die "no such file: ${PULL_SECRET_SRC}"

python3 -I - "${PULL_SECRET_SRC}" <<'PY' || die "that file is not a valid pull secret."
import json, sys
try:
    auths = json.load(open(sys.argv[1]))["auths"]
except Exception as exc:
    sys.exit(f"  cannot parse: {exc}")
if "registry.redhat.io" not in auths:
    sys.exit("  no 'registry.redhat.io' entry in auths; the image pull will fail.")
print(f"    auths for: {', '.join(sorted(auths))}")
PY

cp "${PULL_SECRET_SRC}" "${WORKDIR}/pull-secret.json"
rm -f "${SECRETS_DIR}/pull-secret.json.vault"
"${VAULT[@]}" --output "${SECRETS_DIR}/pull-secret.json.vault" "${WORKDIR}/pull-secret.json" >/dev/null
info "Encrypted playbooks/secrets/pull-secret.json.vault"

# --- 3. RHOKP access key ---------------------------------------------------

if [[ -n "${ACCESS_KEY_SRC}" ]]; then
  ACCESS_KEY_SRC="${ACCESS_KEY_SRC/#\~/$HOME}"
  [[ -f "${ACCESS_KEY_SRC}" ]] || die "no such file: ${ACCESS_KEY_SRC}"
  tr -d '\r\n' < "${ACCESS_KEY_SRC}" > "${WORKDIR}/access-key"
elif [[ -f "${REPO_ROOT}/rhokp-access-key" ]]; then
  info "Reading the access key from ./rhokp-access-key"
  tr -d '\r\n' < "${REPO_ROOT}/rhokp-access-key" > "${WORKDIR}/access-key"
else
  echo
  read -rsp "RHOKP access key: " key; echo
  [[ -n "${key}" ]] || die "the access key cannot be empty."
  printf '%s' "${key}" > "${WORKDIR}/access-key"
  unset key
fi

[[ -s "${WORKDIR}/access-key" ]] || die "the access key is empty."

rm -f "${SECRETS_DIR}/access-key.vault"
"${VAULT[@]}" --output "${SECRETS_DIR}/access-key.vault" "${WORKDIR}/access-key" >/dev/null
info "Encrypted playbooks/secrets/access-key.vault"

# --- 4. what to do next ----------------------------------------------------

cat <<EOF

Done. Both .vault files are AES256 encrypted, and all three are gitignored.

Deploy over SSH:
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook playbooks/standalone.yml \\
    --vault-password-file playbooks/secrets/vault-password

For an unattended RHDP deploy the runner cannot be given a vault password, so
all three must be committed. Only do this on a PRIVATE fork:
  git add -f playbooks/secrets/access-key.vault \\
             playbooks/secrets/pull-secret.json.vault \\
             playbooks/secrets/vault-password

The plaintext copies are still on disk and gitignored. Once you have confirmed a
successful deploy you can remove them:
  rm -f ${REPO_ROOT}/pull-secret.json ${REPO_ROOT}/rhokp-access-key ${REPO_ROOT}/.env
EOF
