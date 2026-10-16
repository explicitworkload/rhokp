# Red Hat Offline Knowledge Portal — deployment

Automation for running the [Red Hat Offline Knowledge Portal][catalog] (RHOKP) in
two places:

- **RHEL + podman** — an Ansible role that installs the portal as a systemd
  [Quadlet][quadlet] service, rootless by default.
- **Kubernetes / OpenShift** — plain manifests in [k8s/](k8s/).

No credentials are stored in this repository. The access key and the
`registry.redhat.io` pull secret are supplied by you at setup time and are either
encrypted with Ansible Vault or created directly against the cluster.

[catalog]: https://catalog.redhat.com/software/containers/offline-knowledge-portal/rhokp-rhel9
[quadlet]: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html

---

## What you need

| | |
| --- | --- |
| **RHOKP access key** | Issued with your portal entitlement. Injected as `ACCESS_KEY`. |
| **Red Hat pull secret** | [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret) — must contain an `auths` entry for `registry.redhat.io`. |
| **Target host** | RHEL 9.2+ (or 10) with `podman` ≥ 4.4, reachable over SSH, and a user with `sudo`. |
| **Control node** | `ansible-core` ≥ 2.15, `python3`, `bash`. |

Verified end to end on RHEL 9.7 with podman 5.8.2, rootless: clean install, a
no-op second run, access-key rotation, uninstall and reinstall.

---

## Repository layout

The repository root **is** an Ansible collection (`explicitworkload.rhokp`), which
is what the RHDP runner requires.

```
galaxy.yml                 collection metadata
meta/runtime.yml
requirements.yml           containers.podman, ansible.posix
ansible.cfg                local runs only; the RHDP runner ignores it
inventory.yml              standalone target hosts — edit this first
playbooks/
  deploy.yml               RHDP entrypoint (nodes + bastion proxy)
  standalone.yml           direct-over-SSH deploy
  uninstall.yml            tear down
  secrets/                 AES256 vault files (safe to commit)
roles/
  rhokp/                   the portal itself
  rhokp_bastion_proxy/     nginx location block on the RHDP bastion
site.yml                   Antora playbook for the Showroom lab guide
ui-config.yml              Showroom UI layout
content/                   lab guide pages (AsciiDoc)
package.json               local-only Antora preview tooling
k8s/
  rhokp-deployment.yaml    Namespace + Deployment + Service, no credentials
scripts/
  init-secrets.sh          encrypt your credentials into playbooks/secrets/
  k8s-create-secrets.sh    create the two cluster secrets from your input
```

---

## Quick start — RHEL with podman

**1. Encrypt your credentials.** The script prompts for anything it cannot find,
picks up `./pull-secret.json` and `./rhokp-access-key` automatically if they are
present, and writes an Ansible Vault password to `playbooks/secrets/vault-password`.

```bash
scripts/init-secrets.sh
```

**2. Point the inventory at your host.** Edit [inventory.yml](inventory.yml):

```yaml
rhel-lab:
  ansible_host: ssh.example.rhdp.net
  ansible_port: 30129
  ansible_user: lab-user
```

**3. Deploy.**

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/standalone.yml \
  --vault-password-file playbooks/secrets/vault-password
```

The run performs preflight checks (podman version, subuid range, credentials
present), stores the access key as a podman secret, pulls the image, installs the
Quadlet unit, opens the firewall, and waits for the portal to answer HTTP. It
finishes by printing the URL.

The portal listens on **8080/tcp** (and 8443 if `rhokp_publish_https` is on).

If you prefer not to keep the vault password on disk, drop
`--vault-password-file` and pass `--ask-vault-pass` instead.

---

## How the credentials are protected

Three separate problems, three different mechanisms.

### In this git repository — nothing

This repository is public and contains **no credentials in any form**, not even
encrypted ones. `.gitignore` is deny-by-default inside `playbooks/secrets/`, so
neither a stray plaintext `pull-secret.json` nor a `.vault` file can be
committed by accident.

`scripts/init-secrets.sh` writes `access-key.vault`, `pull-secret.json.vault`
and `vault-password` there for **local use only**. The vault files are genuine
AES256, so they are safe to commit to a *private* fork — but published
ciphertext of a live Red Hat entitlement can be cached and indexed forever, and
there is no way to recall it, so it is simply never pushed from here.

Day-to-day:

```bash
ansible-vault view playbooks/secrets/access-key.vault --vault-password-file playbooks/secrets/vault-password
ansible-vault edit playbooks/secrets/access-key.vault --vault-password-file playbooks/secrets/vault-password
scripts/init-secrets.sh --rekey     # change the vault password
```

You can skip the vault entirely for a one-off run:

```bash
ansible-playbook playbooks/standalone.yml \
  -e rhokp_access_key='<key>' \
  -e rhokp_pull_secret_path=./pull-secret.json
```

### In transit and on the target host

The access key is decrypted on the control node, pushed over SSH, and written to
podman's secret store — never to a file the role leaves behind. The Quadlet unit
references it by name:

```ini
Secret=rhokp-access-key,type=env,target=ACCESS_KEY
```

The unit file carries only the secret's *name*. `podman inspect` lists an entry
called `rhokp-access-key` in `Config.Env` with its value masked as `*******`,
and no `ACCESS_KEY=` entry at all — the real value is only ever present in the
running container's environment. Every Ansible task that touches it is marked
`no_log: true`.

The registry pull secret is staged into a `mktemp -d` directory at mode `0600`,
used for exactly one `podman pull`, and deleted in an `always:` block — so it is
removed even if the pull fails. Set `rhokp_persist_authfile: true` if you would
rather keep it at `~/.config/containers/auth.json` so the unit can re-pull
unattended.

> **Be clear-eyed about the limit here.** Podman's default secret driver stores
> secret data *unencrypted* on disk, protected only by file permissions
> (`~/.local/share/containers/storage/secrets/` rootless,
> `/var/lib/containers/storage/secrets/` rootful). It keeps the key out of your
> git history, out of process arguments, out of the unit file and out of
> `inspect` output — it does not protect against someone who is already root on
> the box. For encryption at rest on the host, create the secret with an external
> driver backed by `pass` or `gopass`, or hold the key in a KMS and fetch it at
> start time.

### In Kubernetes / OpenShift

See [below](#kubernetes--openshift).

---

## Configuration

Override any of these with `-e`, in the play `vars:`, or
per-host in the inventory. Full list with comments:
[roles/rhokp/defaults/main.yml](roles/rhokp/defaults/main.yml).

| Variable | Default | Purpose |
| --- | --- | --- |
| `rhokp_image` | `registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:latest` | Image to run |
| `rhokp_image_force_pull` | `false` | Re-pull even if the image is already local |
| `rhokp_rootless` | `true` | `false` installs a root-owned system service |
| `rhokp_http_port` | `8080` | Host port for HTTP |
| `rhokp_https_port` | `8443` | Host port for HTTPS |
| `rhokp_publish_https` | `true` | Publish 8443 at all |
| `rhokp_edge_tls` | `false` | See [Behind an edge-terminating proxy](#behind-an-edge-terminating-proxy) |
| `rhokp_require_credentials` | `false` | `true` fails the run instead of degrading when no credentials resolve |
| `rhokp_bind_address` | `0.0.0.0` | Use `127.0.0.1` to keep the portal behind a reverse proxy |
| `rhokp_manage_firewall` | `true` | Open the ports in firewalld when it is running |
| `rhokp_apply_resource_limits` | rootful only | See [Resource limits](#resource-limits) |
| `rhokp_persist_authfile` | `false` | Keep the registry authfile on the host after pulling |
| `rhokp_wait_for_ready` | `true` | Probe HTTP before declaring success |
| `rhokp_ready_timeout` | `300` | Seconds to wait for that probe |
| `rhokp_stop_timeout` | `10` | See [Shutdown behaviour](#shutdown-behaviour) |
| `rhokp_healthcheck_enabled` | `false` | See [Health checks](#health-checks) |

### Rootless vs rootful

Rootless is the default: the portal runs as a systemd **user** service owned by
`ansible_user`, and the role enables [lingering][linger] so it survives logout
and starts at boot. This needs a `/etc/subuid` range for that user; the preflight
check fails with the exact `usermod` command if one is missing.

```bash
ansible-playbook site.yml -e rhokp_rootless=false   # root-owned system service
```

[linger]: https://www.freedesktop.org/software/systemd/man/loginctl.html

### Resource limits

The Kubernetes manifest caps the portal at 2 CPU / 4 GiB. The role applies the
same caps via `PodmanArgs` but **only in rootful mode by default**, because a
rootless container can only use the cgroup controllers systemd has delegated to
the user slice — and `cpu` delegation is not universal. If `cat
/sys/fs/cgroup/user.slice/user-$UID.slice/cgroup.controllers` on your host lists
both `cpu` and `memory`, turn them on. (On stock RHEL 9.7 it lists only `memory
pids`, which is why this defaults to off.)

```bash
ansible-playbook site.yml -e rhokp_apply_resource_limits=true
```

### Shutdown behaviour

PID 1 in this image is `mel`, which does not handle `SIGTERM`. Podman waits
`rhokp_stop_timeout` seconds and then `SIGKILL`s it, so **every** stop — however
routine — ends with exit code 137. Two consequences are baked into the unit:

- `StopTimeout` is deliberately short (10s). Raising it only makes restarts
  slower; the container is never going to exit gracefully.
- `SuccessExitStatus=137 143`, so a normal stop does not park the unit in
  `failed`. The trade-off is that an OOM kill also exits 137 and will no longer
  show as failed. `Restart=always` still restarts it either way, and the kill is
  visible in `journalctl -k`.

A cold start takes roughly **45 seconds** before the portal answers HTTP (Solr
indexing). That is well inside the default `rhokp_ready_timeout`.

### Health checks

The in-container health check is **off** by default: the upstream image is not
documented to ship `curl`, and a health command that cannot run marks the
container unhealthy. Readiness is verified from the Ansible side instead. If you
have confirmed a usable command inside the image:

```yaml
rhokp_healthcheck_enabled: true
rhokp_healthcheck_cmd: "curl -fsS http://localhost:8080/ || exit 1"
```

---

## Day-two operations

Rootless commands are shown with `--user`; drop it for a rootful install.

```bash
# status and logs
systemctl --user status rhokp.service
journalctl --user -u rhokp.service -f

# restart
systemctl --user restart rhokp.service

# rotate the access key — edit the vault, then re-run
ansible-vault edit playbooks/secrets/access-key.vault --vault-password-file playbooks/secrets/vault-password
ansible-playbook site.yml --vault-password-file .vault-password

# update to a newer :latest
ansible-playbook site.yml -e rhokp_image_force_pull=true --vault-password-file .vault-password

# tear down (add -e rhokp_remove_image=true to drop the image too)
ansible-playbook uninstall.yml --vault-password-file .vault-password
```

Re-running `site.yml` is idempotent. The role fingerprints the access key in
`~/.config/rhokp/access-key.sha256` so it only recreates the podman secret — and
only restarts the portal — when the key has actually changed.

Useful tags: `--tags preflight,secrets,image,deploy,firewall,verify`.

---

## RHDP Field Sourced Content

Order the **RHEL Field Asset** catalog item and point it at this repository.
See [rhpds/field-sourced-content-rhel](https://github.com/rhpds/field-sourced-content-rhel)
for the platform side.

### Order form

| Field | Value |
| --- | --- |
| Existing content repo? | checked |
| Collection git repo | `https://github.com/explicitworkload/rhokp` |
| Git revision | `main` |
| Playbook entrypoint | `playbooks/deploy.yml` |
| Private git repo? | unchecked for this public repo — see [Credentials](#credentials-on-rhdp) |
| **Install proxy on bastion?** | **checked** — see [Why the proxy is required](#why-the-proxy-is-required) |
| Deploy Showroom? | checked, **Showroom path left empty** (files are at the repo root) |
| Node count | `1` |

### What the platform gives the playbook

Inventory groups `bastions` and `nodes`, with `ansible_user=cloud-user` and
**`ansible_become=true` for every host**. Extra-vars are a fixed set: `guid`,
`subdomain`, and `field_asset.{node_count,node_size,rhel_version,enable_bastion_proxy,route_app,route_app_secure}`.

`playbooks/deploy.yml` runs two plays: the portal on `groups['nodes'][0]`, and
the nginx location block on the bastion when `enable_bastion_proxy` is true.

Because the inventory forces become on, **the RHDP path deploys rootful**
(`rhokp_rootless: false`). Facts under become describe root, so a rootless
install would land in `/root` with `XDG_RUNTIME_DIR=/run/user/0`. The role
asserts against that rather than letting it happen quietly.

### Why the proxy is required

Workload nodes have no public routes. The only way in is the bastion's two
reserved ports, which the catalog always publishes:

| Public URL | Bastion port |
| --- | --- |
| `http://app-<guid>.<subdomain>` | 8080 |
| `https://app-secure-<guid>.<subdomain>` | 8443, **edge TLS** |

The portal runs on a node, so something has to listen on those bastion ports and
forward. Checking the box makes the platform install nginx with an empty
`include /etc/nginx/proxy.d/*.conf`; `rhokp_bastion_proxy` drops one file in
there. Leave it unchecked and both URLs return 504 — nothing is listening.

### Credentials on RHDP

The runner clones the repo and runs `ansible-playbook` unattended. **There is no
order-form field for custom variables and no vault password**, so the only way
to a turnkey deploy is to ship the credentials in the repo. Without the pull
secret the image cannot even be pulled.

Nothing credential-shaped is committed here, so **an order against this public
repo always lands in degraded mode** — see below. To get a turnkey deploy, fork
into a private repo and commit all three files:

```bash
scripts/init-secrets.sh
git add -f playbooks/secrets/access-key.vault \
           playbooks/secrets/pull-secret.json.vault \
           playbooks/secrets/vault-password
```

`resolve_secrets.yml` then shells out to `ansible-vault` itself, because the
runner never passes `--vault-password-file`. Be clear about what this buys you:
the secrets are not sitting in plain sight, but the password is in the same
repo, so **the real protection is repo privacy plus the read token**. If the
repo is ever made public, rotate both credentials.

If the vault password is absent the run does not fail. The role installs
everything that needs no credentials, leaves the portal stopped, and prints:

```
sudo rhokp-set-credentials
```

That helper is installed on every node. It prompts for the pull secret and
access key, pulls the image, stores the podman secret, and starts the portal.

### Watching and re-running

```bash
sudo systemctl status field-content
sudo journalctl -u field-content -f
sudo podman logs -f field-content

sudo systemctl restart field-content    # re-clones and reruns from scratch
```

The RHDP order succeeds as soon as the container is *running*, not when the
playbook finishes — a failed playbook will not fail the order.

---

## Behind an edge-terminating proxy

If the portal is reachable directly on a host whose 8443 is fronted by something
that terminates TLS (an OpenShift edge Route, an ALB), that port receives
**plain HTTP**. The container's own TLS listener answers plaintext with `400`.
Set:

```yaml
rhokp_edge_tls: true
```

and host port 8443 is published to the container's HTTP port instead. This is
already set for `rhel-lab` in [inventory.yml](inventory.yml). On the RHDP path
it is unnecessary — nginx on the bastion is what listens on 8443 there.

---

## Previewing the lab guide

The Showroom guide is a standard Antora site. To render it locally:

```bash
npm install     # one-off; installs Antora and the two theme extensions
npm run preview # builds ./www and serves it on 8081
```

Then open <http://localhost:8081>.

Antora reads **committed** files, so anything you have only saved — not
committed — will not appear in the preview.

`node_modules/` and `www/` are gitignored, and `galaxy.yml` keeps all of this
out of the built collection.

---

## Kubernetes / OpenShift

[k8s/rhokp-deployment.yaml](k8s/rhokp-deployment.yaml) contains a Namespace, a
Deployment and a Service — and no credentials. It references two secrets you
create yourself:

| Secret | Type | Holds |
| --- | --- | --- |
| `redhat-registry-secret` | `kubernetes.io/dockerconfigjson` | Your pull secret |
| `rhokp-access-key` | `Opaque`, key `ACCESS_KEY` | Your access key |

```bash
scripts/k8s-create-secrets.sh          # prompts for both, then applies them
oc apply -f k8s/rhokp-deployment.yaml
```

Or by hand:

```bash
oc create namespace rhokp-portal

oc create secret docker-registry redhat-registry-secret \
  --namespace rhokp-portal \
  --from-file=.dockerconfigjson=/path/to/pull-secret.json

oc create secret generic rhokp-access-key \
  --namespace rhokp-portal \
  --from-file=ACCESS_KEY=/path/to/rhokp-access-key
```

The script stages the access key through a `0600` temp file rather than
`--from-literal`, so it never appears in the process list. Note that Kubernetes
Secrets are only base64-encoded in etcd unless your cluster has [encryption at
rest][k8s-enc] enabled.

Expose the Service when you are ready:

```bash
oc expose service rhokp-service --namespace rhokp-portal
```

[k8s-enc]: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `podman ... is too old` | Quadlet needs podman ≥ 4.4. `sudo dnf -y install podman` on RHEL 9.2+. |
| `has no /etc/subuid range` | Rootless podman needs one. Run the `usermod` command in the error, or deploy with `-e rhokp_rootless=false`. |
| `unauthorized` / `401` on pull | The pull secret has no valid `registry.redhat.io` entry. Download a fresh one and re-run `scripts/init-secrets.sh`. |
| `Attempting to decrypt but no vault secrets found` | Pass `--vault-password-file .vault-password` or `--ask-vault-pass`. |
| Container exits immediately with `ERR_002: ACCESS_KEY could not be validated` | The key is wrong. Check it against <https://access.redhat.com/offline/access>, then `ansible-vault edit playbooks/secrets/access-key.vault` and re-run. |
| Portal starts, then the readiness probe times out | A cold start takes ~45s; the default timeout allows 300s. If it still fails: `podman logs rhokp`. |
| HTTPS route returns `400` but HTTP works | The edge terminates TLS and sends plain HTTP to 8443. Set `rhokp_edge_tls: true`. |
| Both RHDP routes return `504` | Nothing is listening on the bastion's 8080/8443. Re-order with **Install proxy on bastion?** checked. |
| `systemctl status` shows `failed` after a stop | Expected before this was fixed — see [Shutdown behaviour](#shutdown-behaviour). Clear a stale entry with `systemctl --user reset-failed rhokp.service`. |
| Service does not come back after reboot (rootless) | Check lingering: `loginctl show-user $USER --property=Linger`. |
| `cannot set cpu limit` (rootless) | Leave `rhokp_apply_resource_limits` at its default — see [Resource limits](#resource-limits). |

---

## If you cloned this before the secrets were removed

Earlier revisions of `k8s/rhokp-deployment.yaml` embedded a base64 pull secret
directly in the manifest. If you have a copy of that file, treat those registry
credentials as compromised and [rotate your pull secret][rotate].

[rotate]: https://console.redhat.com/openshift/install/pull-secret
