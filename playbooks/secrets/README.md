# playbooks/secrets

This directory is **empty in git**. It is where `scripts/init-secrets.sh` puts
your credentials locally:

| File | Contents | In git? |
| --- | --- | --- |
| `access-key.vault` | RHOKP `ACCESS_KEY`, AES256 via Ansible Vault | no |
| `pull-secret.json.vault` | `registry.redhat.io` pull secret, AES256 | no |
| `vault-password` | the password that opens both | no |

This is a public repository, so nothing credential-shaped is committed — not
even the encrypted files. Published ciphertext of a live entitlement cannot be
recalled, so it is simply never pushed. `.gitignore` is deny-by-default here.

## Getting set up

```bash
scripts/init-secrets.sh
```

It picks up `./pull-secret.json` and `./rhokp-access-key` if present, prompts
for anything missing, and writes all three files here.

## Using them

```bash
ansible-playbook playbooks/standalone.yml \
  --vault-password-file playbooks/secrets/vault-password

ansible-vault view playbooks/secrets/access-key.vault \
  --vault-password-file playbooks/secrets/vault-password

scripts/init-secrets.sh --rekey     # change the vault password
```

## If you fork this privately

The RHDP field-content runner is unattended and is never passed
`--vault-password-file`, so a turnkey deploy needs all three files committed.
Only do that on a private repo:

```bash
git add -f playbooks/secrets/access-key.vault \
           playbooks/secrets/pull-secret.json.vault \
           playbooks/secrets/vault-password
```

Without them the deploy still succeeds — it just leaves the portal stopped for
`sudo rhokp-set-credentials` to finish. See "RHDP" in the top-level README.
