# Red Hat Offline Knowledge Portal — deployment

Automation for running the [Red Hat Offline Knowledge Portal][catalog] (RHOKP) —
a secure, offline copy of Red Hat's proprietary knowledge content, served from
a single container with no internet connection.

| Inside the image | Needs an access key? |
| --- | --- |
| Over **160,000** Knowledgebase articles and solutions, searchable through Apache Solr | **Yes** |
| More than **10,000** product documents, plus product lifecycle pages and the Security Data API | No |

Anyone with Red Hat registry credentials — Customer Portal, Red Hat Developer,
or a registry service account — can pull and deploy the image. The access key
is a **separate** credential that unlocks the encrypted Knowledgebase content
and the search index. Without one the portal still runs, showing a banner that
your access is limited.

Just looking? You do not need this repository at all:

```bash
podman login registry.redhat.io
podman run --rm -p 8080:8080 -p 8443:8443 \
  --env "ACCESS_KEY=<your_access_key>" \
  -d registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:latest
```

That is a throwaway container on your laptop. Everything below is about
running it as a **managed service** — a systemd unit with a restart policy,
the access key in a Podman secret rather than an environment variable on the
command line, and a repeatable deploy.

Three ways to do that, one role behind all of them:

| Path | Entrypoint | Use when |
| --- | --- | --- |
| **Your own RHEL host** | `playbooks/standalone.yml` | You have a RHEL box, over SSH or locally |
| **RHDP Field Asset** | `playbooks/deploy.yml` | Ordering from the Red Hat Demo Platform |
| **Kubernetes / OpenShift** | `k8s/rhokp-deployment.yaml` | You have a cluster |

**This repository is public and contains no credentials in any form — not even
encrypted ones.** You supply the access key and the `registry.redhat.io` pull
secret at setup time; see [How the credentials are protected](#how-the-credentials-are-protected).

### Why the repository is shaped like this

The layout follows the
[rhpds/field-sourced-content-rhel](https://github.com/rhpds/field-sourced-content-rhel)
template, so that it can be published on the Red Hat Demo Platform as a **RHEL
Field Asset** catalog item. That template dictates the structure:

| Requirement from the template | How this repo satisfies it |
| --- | --- |
| `galaxy.yml` at the repository root | The root **is** an Ansible collection, `explicitworkload.rhokp` |
| Roles and playbooks inside the collection | `roles/`, `playbooks/` |
| A playbook entrypoint the runner can find | `playbooks/deploy.yml` |
| `requirements.yml` at the root or under `playbooks/` | Not needed — the roles use `ansible.builtin` only |
| Target the platform's `bastions` and `nodes` inventory groups | `playbooks/deploy.yml` targets both |
| Showroom lab guide at the root (or a named subdirectory) | `site.yml`, `ui-config.yml`, `content/` at the root |

**None of that stops you using it on your own RHEL box.** The collection
structure is just a directory layout — `playbooks/standalone.yml` runs against
any RHEL host you can reach, with no RHDP involvement at all. Start at
[Quick start — your own RHEL host](#quick-start--your-own-rhel-host).

[catalog]: https://catalog.redhat.com/software/containers/offline-knowledge-portal/rhokp-rhel9
[quadlet]: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html

---

## Contents

- [What you need](#what-you-need)
- [Repository layout](#repository-layout)
- [Quick start — your own RHEL host](#quick-start--your-own-rhel-host)
- [RHDP Field Sourced Content](#rhdp-field-sourced-content)
- [Kubernetes / OpenShift](#kubernetes--openshift)
- [How the credentials are protected](#how-the-credentials-are-protected)
- [Configuration](#configuration)
- [Day-two operations](#day-two-operations)
- [Showroom UI and lab guide](#showroom-ui-and-lab-guide)
- [Troubleshooting](#troubleshooting)
- [Licence](#licence)

---

## What you need

| | |
| --- | --- |
| **RHOKP access key** | Optional. Unlocks the encrypted Knowledgebase content and the search index; without one you can still browse product documentation, product lifecycle pages and the Security Data API. Injected as `ACCESS_KEY`. Get one at <https://access.redhat.com/offline/access>. |
| **Red Hat pull secret** | [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret) — must contain an `auths` entry for `registry.redhat.io`. |
| **Target host** | RHEL 9.2+ (or 10) with `podman` ≥ 4.4 for Quadlet, reachable over SSH, and a user with `sudo`. |
| **Control node** | `ansible-core` ≥ 2.15, `python3`, `bash`. No Galaxy collections required. |

### What has actually been tested

Verified end to end on RHEL 9.7 with podman 5.8.2:

- **Standalone, rootless** — clean install, a no-op second run (`changed=0`, no
  container restart), access-key rotation, uninstall and reinstall.
- **RHDP-style, rootful** — against a simulated platform inventory
  (`bastions`/`nodes` groups with `ansible_become=true`), including decrypting
  credentials with no `--vault-password-file` on the command line.
- **Degraded mode** — with no credentials resolvable, the run installs
  everything it can and does not fail.
- **Public routes** — HTTP and HTTPS through an OpenShift edge Route.

Not yet exercised against a real order: the `rhokp_bastion_proxy` nginx config,
and a rendered Showroom deployment.

---

## Repository layout

```
galaxy.yml                 collection metadata
meta/runtime.yml
ansible.cfg                local runs only; the RHDP runner ignores it
inventory.yml              standalone target hosts — edit this first
playbooks/
  deploy.yml               RHDP entrypoint (nodes + bastion proxy)
  standalone.yml           direct-over-SSH deploy
  uninstall.yml            tear down
  secrets/                 your local vault files — all gitignored
roles/
  rhokp/                   the portal itself
  rhokp_bastion_proxy/     nginx location block on the RHDP bastion
k8s/
  rhokp-deployment.yaml    Namespace + Deployment + Service, no credentials
scripts/
  init-secrets.sh          encrypt your credentials into playbooks/secrets/
  k8s-create-secrets.sh    create the two cluster secrets from your input
site.yml                   Antora playbook for the Showroom lab guide
ui-config.yml              Showroom UI layout
content/                   lab guide pages (AsciiDoc)
package.json               local-only Antora preview tooling
```

> **Note:** `site.yml` at the root is the **Antora** playbook for the lab guide,
> not an Ansible one. The Ansible entrypoints all live under `playbooks/`.

---

## Quick start — your own RHEL host

No RHDP, no cluster: one RHEL machine and the portal running on it.

### 0. Prepare the RHEL host

Podman 4.4 or newer, for Quadlet support. RHEL 9.2+ ships it:

```bash
sudo dnf -y install podman
podman --version
```

For the default **rootless** install, the user you deploy as also needs a
subuid range. Most RHEL users get one automatically; check and add if missing:

```bash
grep "^$USER:" /etc/subuid || \
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
```

The role preflights both of these and fails with the exact fix if either is
missing, so you can also just run it and see.

### 1. Get the repo and the Ansible dependencies

On whichever machine will *run* Ansible — your laptop, or the RHEL host itself:

```bash
git clone https://github.com/explicitworkload/rhokp
cd rhokp
```

The roles use `ansible.builtin` modules only — no Galaxy collections to
install, and nothing to reach the internet for beyond the container image
itself.

### 2. Create your credential vault

Put your pull secret and access key in the repo root as `pull-secret.json` and
`rhokp-access-key` (both gitignored), or let the script prompt you:

```bash
scripts/init-secrets.sh
```

It encrypts both with Ansible Vault into `playbooks/secrets/`, alongside the
password that opens them. All three stay local.

### 3. Tell Ansible where the host is

Pick whichever matches your setup. Edit [inventory.yml](inventory.yml):

**Over SSH, from another machine:**

```yaml
all:
  children:
    rhokp:
      hosts:
        my-rhel:
          ansible_host: rhel.example.com
          ansible_port: 22
          ansible_user: cloud-user
          # ansible_ssh_private_key_file: ~/.ssh/id_rsa
```

**Running directly on the RHEL host itself:**

```yaml
all:
  children:
    rhokp:
      hosts:
        localhost:
          ansible_connection: local
```

The group must stay named `rhokp` — that is what `playbooks/standalone.yml`
targets.

### 4. Deploy

```bash
ansible-playbook playbooks/standalone.yml \
  --vault-password-file playbooks/secrets/vault-password
```

Add `--ask-become-pass` if your sudo needs a password, and `--ask-pass`
instead of `--vault-password-file` plus a key if you authenticate over SSH
with a password (needs `sshpass`).

The run preflights podman and subuid, decrypts the credentials, stores the
access key as a podman secret, pulls the image, installs the Quadlet unit,
opens firewalld if it is running, and waits for the portal to answer HTTP. It
finishes by printing the URL.

### 5. Use it

The portal listens on **8080/tcp**, and **8443/tcp** unless you set
`rhokp_publish_https: false`. A cold start takes about 45 seconds while Solr
builds its index.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<your-host>:8080/
```

What was installed, for a rootless deploy:

| | |
| --- | --- |
| Quadlet unit | `~/.config/containers/systemd/rhokp.container` |
| systemd service | `rhokp.service` (user scope) |
| Access key | podman secret `rhokp-access-key` |
| Key fingerprint | `~/.config/rhokp/access-key.sha256` |
| Helper | `/usr/sbin/rhokp-set-credentials` |

Rootful (`-e rhokp_rootless=false`) puts the first four under
`/etc/containers/systemd/`, system scope, and `/etc/rhokp/`.

Then see [Day-two operations](#day-two-operations) for logs, restarts, key
rotation and teardown.

### Common adjustments

```bash
# listen somewhere other than 8080/8443
ansible-playbook playbooks/standalone.yml -e rhokp_http_port=80 -e rhokp_https_port=443 ...

# root-owned system service instead of a user service
ansible-playbook playbooks/standalone.yml -e rhokp_rootless=false ...

# keep it host-local, behind your own reverse proxy
ansible-playbook playbooks/standalone.yml -e rhokp_bind_address=127.0.0.1 ...

# skip the vault entirely for a one-off
ansible-playbook playbooks/standalone.yml \
  -e rhokp_access_key='<key>' -e rhokp_pull_secret_path=./pull-secret.json
```

Rootless podman cannot bind ports below 1024 unless you lower
`net.ipv4.ip_unprivileged_port_start`, so pair `rhokp_http_port=80` with
`-e rhokp_rootless=false`.

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
| Private git repo? | unchecked for this public repo — see [Credentials on RHDP](#credentials-on-rhdp) |
| **Install proxy on bastion?** | **checked** — see [Why the proxy is required](#why-the-proxy-is-required) |
| Deploy Showroom? | checked, **Showroom path left empty** (the files are at the repo root) |
| Node count | `1` |

### What the platform gives the playbook

Inventory groups `bastions` and `nodes`, with `ansible_user=cloud-user` and
**`ansible_become=true` for every host**. Extra-vars are a fixed set: `guid`,
`subdomain`, and `field_asset.{node_count,node_size,rhel_version,enable_bastion_proxy,route_app,route_app_secure}`.

`playbooks/deploy.yml` runs two plays: the portal on `groups['nodes'][0]`, and
the nginx location block on the bastion when `enable_bastion_proxy` is true.

Because the inventory forces become on, **the RHDP path deploys rootful**
(`rhokp_rootless: false`). Facts gathered under become describe root, so a
rootless install would quietly land in `/root` with
`XDG_RUNTIME_DIR=/run/user/0`. The role asserts against that rather than
letting it happen.

### Why the proxy is required

Workload nodes have no public routes. The only way in is the bastion's two
reserved ports, which the catalog always publishes:

| Public URL | Bastion port |
| --- | --- |
| `http://app-<guid>.<subdomain>` | 8080 |
| `https://app-secure-<guid>.<subdomain>` | 8443, **edge TLS** |

The portal runs on a node, so something has to listen on those bastion ports
and forward. Checking the box makes the platform install nginx with an empty
`include /etc/nginx/proxy.d/*.conf`; `rhokp_bastion_proxy` drops one file in
there. Leave it unchecked and both URLs return **504** — nothing is listening.

### Credentials on RHDP

The runner clones the repo and runs `ansible-playbook` unattended. **There is
no order-form field for custom variables and no vault password**, so the only
route to a turnkey deploy is to ship the credentials in the repo. Without the
pull secret the image cannot even be pulled.

Nothing credential-shaped is committed here, so **an order against this public
repo always lands in degraded mode**: the role installs the Quadlet unit, the
firewall rules and the nginx route, leaves the portal stopped, and prints the
command to finish it. On the node:

```bash
sudo /usr/sbin/rhokp-set-credentials
```

That helper is installed on every node. It prompts for whatever is still
missing, stores the access key as a podman secret, and starts the portal — see
[Pre-pulling the image](#pre-pulling-the-image) for why "whatever is still
missing" is usually just the access key.

For a turnkey deploy instead, fork into a **private** repo and commit all three
files:

```bash
scripts/init-secrets.sh
git add -f playbooks/secrets/access-key.vault \
           playbooks/secrets/pull-secret.json.vault \
           playbooks/secrets/vault-password
```

`roles/rhokp/tasks/resolve_secrets.yml` then shells out to `ansible-vault`
itself, because the runner never passes `--vault-password-file`. Be clear about
what that buys you: the secrets are not sitting in plain sight, but the
password is in the same repo, so **the real protection is repo privacy plus the
read token**. If that fork is ever made public, rotate both credentials.

### Pre-pulling the image

`registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:latest` is **about
7.8 GB compressed**, nearly all of it in a single layer. That download, not the
install, is the slowest part of standing the portal up, and on a degraded
install it lands on whoever runs `rhokp-set-credentials` — several minutes of
staring at `Copying blob`.

The role pulls the image during the deploy whenever it has a pull secret, and
it does **not** need an access key to do so. The two credentials are resolved
independently:

| Resolved at deploy time | What happens |
| --- | --- |
| Pull secret **and** access key | Image pulled, secret stored, portal started. Nothing left to do. |
| Pull secret only | Image pulled; portal left stopped. The helper asks only for the access key and starts in seconds. |
| Access key only | Secret stored; nothing to pull from. The helper asks for a pull secret and downloads. |
| Neither | Nothing pulled. The helper asks for both and downloads. |

There is no way around needing *a* pull secret for this: the image is not
mirrored anywhere unauthenticated. `registry.access.redhat.com` answers

```
This repo requires terms acceptance and is only available on registry.redhat.io
```

To pre-pull on an RHDP order, give the catalog item a pull secret as base64:

```bash
base64 -w0 pull-secret.json        # macOS: base64 -i pull-secret.json
```

and set it as `field_asset.pull_secret_b64`. `playbooks/deploy.yml` maps that
onto `rhokp_pull_secret_b64`. On a bastion you are already logged into, the
same thing without re-ordering:

```bash
sudo vi /opt/field-content/extra-vars.yml     # add rhokp_pull_secret_b64: "<blob>"
sudo systemctl restart field-content
```

Weigh that up honestly. A pull secret on the catalog item is shared by everyone
who orders the item, and all it does is **pull the image** — anyone with Red
Hat registry credentials can do that. The Knowledgebase content and the search
index still need a per-person access key, so the "bring your own credentials"
shape of the lab survives. If you are not comfortable with a shared pull secret, leave it
unset and accept the download.

On the standalone path this is already automatic: `scripts/init-secrets.sh`
vaults both credentials, so the image is pulled during the run. For a one-off
without a vault:

```bash
ansible-playbook playbooks/standalone.yml \
  -e rhokp_pull_secret_b64="$(base64 -w0 pull-secret.json)" \
  -e rhokp_require_credentials=false
```

Once the image is on the node, `rhokp-set-credentials` detects it, skips the
download, and does not ask for a pull secret at all. Force a fresh copy with
`sudo /usr/sbin/rhokp-set-credentials --force-pull`.

### Watching and re-running

```bash
sudo systemctl status field-content
sudo journalctl -u field-content -f
sudo podman logs -f field-content

sudo systemctl restart field-content    # re-clones and reruns from scratch
```

The RHDP order succeeds as soon as the container is *running*, not when the
playbook finishes — **a failed playbook will not fail the order**.

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

## How the credentials are protected

Three separate problems, three different mechanisms.

### In this git repository — nothing

`.gitignore` is deny-by-default inside `playbooks/secrets/`, so neither a stray
plaintext `pull-secret.json` nor a `.vault` file can be committed by accident.

`scripts/init-secrets.sh` writes `access-key.vault`, `pull-secret.json.vault`
and `vault-password` there for **local use only**. The vault files are genuine
AES256, so they are safe to commit to a *private* fork — but published
ciphertext of a live Red Hat entitlement can be cached and indexed long after a
delete, so it is never pushed from here.

```bash
ansible-vault view playbooks/secrets/access-key.vault \
  --vault-password-file playbooks/secrets/vault-password

ansible-vault edit playbooks/secrets/access-key.vault \
  --vault-password-file playbooks/secrets/vault-password

scripts/init-secrets.sh --rekey     # change the vault password
```

Skip the vault entirely for a one-off run:

```bash
ansible-playbook playbooks/standalone.yml \
  -e rhokp_access_key='<key>' \
  -e rhokp_pull_secret_path=./pull-secret.json
```

### In transit and on the target host

The access key is decrypted on the control node, pushed over SSH, and written
to podman's secret store — never to a file the role leaves behind. The Quadlet
unit references it by name:

```ini
Secret=rhokp-access-key,type=env,target=ACCESS_KEY
```

The unit file carries only the secret's *name*. `podman inspect` lists an entry
called `rhokp-access-key` in `Config.Env` with its value masked as `*******`,
and no `ACCESS_KEY=` entry at all — the real value is only ever present in the
running container's environment. Every Ansible task that touches it is marked
`no_log: true`.

The registry pull secret is staged into a `mktemp -d` directory at mode `0600`,
used for exactly one `podman pull`, and deleted in an `always:` block — so it
is removed even if the pull fails. Set `rhokp_persist_authfile: true` to keep
it at `~/.config/containers/auth.json` so the unit can re-pull unattended.

> **Be clear-eyed about the limit here.** Podman's default secret driver stores
> secret data *unencrypted* on disk, protected only by file permissions
> (`~/.local/share/containers/storage/secrets/` rootless,
> `/var/lib/containers/storage/secrets/` rootful). It keeps the key out of your
> git history, out of process arguments, out of the unit file and out of
> `inspect` output — it does **not** protect against someone who is already
> root on the box. For encryption at rest on the host, create the secret with
> an external driver backed by `pass` or `gopass`, or hold the key in a KMS and
> fetch it at start time.

### In Kubernetes / OpenShift

See [Kubernetes / OpenShift](#kubernetes--openshift) above.

---

## Configuration

Override any of these with `-e`, in the play `vars:`, or per-host in the
inventory. Full list with comments:
[roles/rhokp/defaults/main.yml](roles/rhokp/defaults/main.yml).

| Variable | Default | Purpose |
| --- | --- | --- |
| `rhokp_image` | `registry.redhat.io/.../rhokp-rhel9:latest` | Image to run |
| `rhokp_image_force_pull` | `false` | Re-pull even if the image is already local |
| `rhokp_rootless` | `true` | `false` installs a root-owned system service |
| `rhokp_service_name` | `rhokp` | systemd unit name, minus `.service` |
| `rhokp_container_name` | `rhokp` | podman container name |
| `rhokp_http_port` | `8080` | Host port for HTTP |
| `rhokp_https_port` | `8443` | Host port for HTTPS |
| `rhokp_publish_https` | `true` | Publish 8443 at all |
| `rhokp_edge_tls` | `false` | See [Behind an edge-terminating proxy](#behind-an-edge-terminating-proxy) |
| `rhokp_bind_address` | `0.0.0.0` | Use `127.0.0.1` to keep the portal behind a reverse proxy |
| `rhokp_manage_firewall` | `true` | Open the ports in firewalld when it is running |
| `rhokp_apply_resource_limits` | rootful only | See [Resource limits](#resource-limits) |
| `rhokp_cpu_limit` / `rhokp_memory_limit` | `2` / `4g` | Applied only when the above is on |
| `rhokp_require_credentials` | `false` | `true` fails the run instead of degrading. `standalone.yml` sets it true |
| `rhokp_vault_password_file` | `playbooks/secrets/vault-password` | Used when Ansible has no vault secret of its own |
| `rhokp_persist_authfile` | `false` | Keep the registry authfile on the host after pulling |
| `rhokp_wait_for_ready` | `true` | Probe HTTP before declaring success |
| `rhokp_ready_timeout` | `300` | Seconds to wait for that probe |
| `rhokp_stop_timeout` | `10` | See [Shutdown behaviour](#shutdown-behaviour) |
| `rhokp_healthcheck_enabled` | `false` | See [Health checks](#health-checks) |

### Rootless vs rootful

Rootless is the default: the portal runs as a systemd **user** service owned by
`ansible_user`, and the role enables [lingering][linger] so it survives logout
and starts at boot. This needs a `/etc/subuid` range for that user; the
preflight check fails with the exact `usermod` command if one is missing.

```bash
ansible-playbook playbooks/standalone.yml -e rhokp_rootless=false
```

Rootless state lives in `~/.config/`, rootful in `/etc/`. Rootless mode
requires that facts are **not** gathered as root — see the note under
[RHDP](#what-the-platform-gives-the-playbook).

[linger]: https://www.freedesktop.org/software/systemd/man/loginctl.html

### Resource limits

The Kubernetes manifest caps the portal at 2 CPU / 4 GiB. The role applies the
same caps via `PodmanArgs` but **only in rootful mode by default**, because a
rootless container can only use the cgroup controllers systemd has delegated to
the user slice — and `cpu` delegation is not universal. If

```bash
cat /sys/fs/cgroup/user.slice/user-$UID.slice/cgroup.controllers
```

lists both `cpu` and `memory`, turn them on. On stock RHEL 9.7 it lists only
`memory pids`, which is why this defaults to off.

```bash
ansible-playbook playbooks/standalone.yml -e rhokp_apply_resource_limits=true
```

### Shutdown behaviour

PID 1 in this image is `mel`, which does not handle `SIGTERM`. Podman waits
`rhokp_stop_timeout` seconds and then `SIGKILL`s it, so **every** stop — however
routine — ends with exit code 137. Two consequences are baked into the unit:

- `StopTimeout` is deliberately short (10s). Raising it only makes restarts
  slower; the container is never going to exit gracefully.
- `SuccessExitStatus=137 143`, so a normal stop does not park the unit in
  `failed`. The trade-off is that an OOM kill also exits 137 and will no longer
  show as failed. `Restart=always` still restarts it either way, and the kill
  is visible in `journalctl -k`.

A cold start takes roughly **45 seconds** before the portal answers HTTP (Solr
indexing). That is well inside the default `rhokp_ready_timeout`.

### Health checks

The in-container health check is **off** by default: the upstream image is not
documented to ship `curl`, and a health command that cannot run marks the
container unhealthy. Readiness is verified from the Ansible side instead. If
you have confirmed a usable command inside the image:

```yaml
rhokp_healthcheck_enabled: true
rhokp_healthcheck_cmd: "curl -fsS http://localhost:8080/ || exit 1"
```

### Behind an edge-terminating proxy

If the portal is reachable directly on a host whose 8443 is fronted by
something that terminates TLS (an OpenShift edge Route, an ALB), that port
receives **plain HTTP**. The container's own TLS listener answers plaintext
with `400`. Set:

```yaml
rhokp_edge_tls: true
```

and host port 8443 is published to the container's HTTP port instead. This is
already set for `rhel-lab` in [inventory.yml](inventory.yml). On the RHDP path
it is unnecessary — nginx on the bastion is what listens on 8443 there.

---

## Day-two operations

Rootless commands are shown with `--user`; drop it for a rootful install.

```bash
# status and logs
systemctl --user status rhokp.service
journalctl --user -u rhokp.service -f

# restart
systemctl --user restart rhokp.service
```

From the control node, with
`VP=--vault-password-file=playbooks/secrets/vault-password`:

```bash
# rotate the access key — edit the vault, then re-run
ansible-vault edit playbooks/secrets/access-key.vault $VP
ansible-playbook playbooks/standalone.yml $VP

# tear down (add -e rhokp_remove_image=true to drop the image too)
ansible-playbook playbooks/uninstall.yml $VP
```

Or on the node itself, without Ansible:

```bash
sudo /usr/sbin/rhokp-set-credentials      # prompts, then restarts the portal
```

### Keeping the content current

Red Hat's online content changes constantly, so RHOKP is **usually updated
weekly**. Releases depend on external factors, so weekly is not guaranteed,
and they land Monday to Thursday. Whatever is in your image is as current as
the day you pulled it and no more, which makes a refresh schedule part of
running this properly at a disconnected site.

Restarting the service does **not** pick up a new image — the Quadlet unit
sets `Pull=missing`, so Podman reuses the copy it already has. Force it:

```bash
ansible-playbook playbooks/standalone.yml -e rhokp_image_force_pull=true $VP

# or on the node, without Ansible (prompts for the pull secret again,
# because 7.8 GB genuinely has to come back down)
sudo /usr/sbin/rhokp-set-credentials --force-pull
```

Re-running `playbooks/standalone.yml` is idempotent. The role fingerprints the
access key (`~/.config/rhokp/access-key.sha256` rootless,
`/etc/rhokp/access-key.sha256` rootful) so it only recreates the podman secret
— and only restarts the portal — when the key has actually changed.

Useful tags: `--tags preflight,secrets,image,deploy,firewall,verify`.

---

## Showroom UI and lab guide

Reference:
[nookbag ui-config.adoc](https://github.com/rhpds/showroom_template_nookbag/blob/main/content/modules/ROOT/pages/ui-config.adoc).

### Two substitution systems, easily confused

They look similar and are not interchangeable.

| Where | Syntax | Source | Available |
| --- | --- | --- | --- |
| `ui-config.yml` tab URLs | `${GUID}`, `${DOMAIN}` | Showroom, at runtime | **only those two** |
| `content/**.adoc` pages | `{attribute}` | `user_data`, overlaid onto `content/antora.yml` defaults | whatever the asset publishes |
| `playbooks/*.yml` | `{{ guid }}`, `{{ field_asset.x }}` | Ansible extra-vars from the runner | `guid`, `subdomain`, `field_asset.*` |

The third row is the one the platform README advertises, and it works: the
runner writes `/opt/field-content/extra-vars.yml` and the playbook gets real
values. Confirmed on a live order — `field_asset.route_app` rendered as
`app-ppbkv.apps.ocpv02.rhdp.net` in the generated nginx drop-in, and the
bastion play is gated on `field_asset.enable_bastion_proxy` and ran.

**That says nothing about the lab guide.** Showroom is a separate pipeline
that builds the Antora site from `user_data`, not from the playbook's
extra-vars. On a live order every attribute in the rendered guide was still
the `antora.yml` default, so this asset publishes no
`bastion_public_hostname`, `guid` or `subdomain` for the guide. The pages are
therefore written not to need them: they route the reader through the
**Portal** and **Terminal** tabs, both of which resolve correctly, and the
terminal already starts on the bastion.

### Why there is no "Portal" tab

`${DOMAIN}` does not mean what the upstream reference says it means on this
asset. It describes it as "the apps domain of the OpenShift cluster", but
measured on a live order (GUID `6wrqg`, cluster `ocpv07`):

```yaml
url: 'https://app-secure-${GUID}.${DOMAIN}'
# served as:
url: 'https://app-secure-6wrqg.bastion-6wrqg.apps.ocpv07.rhdp.net'
```

`${GUID}` is right; `${DOMAIN}` expands to **Showroom's own route host**,
`bastion-<guid>.<apps domain>`. The portal's hostname cannot be built from
that — there is no way to strip the leading `bastion-<guid>.`, no other
variable is offered, and hardcoding the apps domain would break on every
other cluster.

So `ui-config.yml` ships a Terminal tab only, and the guide sends readers to
the URL on their order page. If you deploy this somewhere the apps domain is
fixed and known, adding a Portal tab is a one-line change.

### Framing headers

Showroom renders tab URLs in an iframe, and the upstream reference warns that
`X-Frame-Options` or a restrictive CSP will produce a blank pane. The bastion
drop-in strips both:

```nginx
proxy_hide_header X-Frame-Options;
proxy_hide_header Content-Security-Policy;
```

In practice this is currently a **no-op**: checked at the origin, RHOKP's
Apache 2.4.62 sends neither header. It is kept as insurance against a future
image adding one. Set `rhokp_bastion_proxy_allow_iframe: false` to drop the
lines. Re-check with:

```bash
curl -sI http://127.0.0.1:8080/ | grep -iE 'x-frame|content-security'   # on the node
```

### Previewing the lab guide

The guide is a standard Antora site, so you can render just the content:

```bash
npm install     # one-off; installs Antora and the two theme extensions
npm run preview # builds ./www and serves it on 8081
```

Then open <http://localhost:8081>. That is enough to proofread prose, but it
is **not** what the reader sees — it is missing the split pane, the tab bar
and the sidebar, all of which come from Nookbag, the React app RHDP puts in
front of the content.

For the real thing:

```bash
scripts/showroom-preview.sh      # builds, assembles, serves on 8080
```

It pulls the Nookbag UI image, lifts the static app out of it, and drops
`ui-config.yml` and `./www` alongside in the layout Nookbag expects. Useful
because Showroom only builds at **provision time** — without this, a layout
change cannot be checked without placing a new order.

| | |
| --- | --- |
| `-p 9000` | serve on another port |
| `-n` | skip the Antora rebuild |
| `-t v0.5` | pin a different Nookbag release |
| `?w=NN` | override the split live in the URL |

Two things to know. The **Terminal tab is a placeholder** — there is no
bastion and no wetty locally, and an unreachable iframe renders as a dead grey
pane that looks like a bug. And the tag is **pinned to `v0.5` deliberately**:
`quay.io/rhpds/nookbag:latest` is an older build that reads a different config
schema (`nookbag.yml` with an `antora:` block) and ignores `default_width`,
`view_switcher` and `persist_url_state`, so it would show you a layout RHDP
does not serve.

Antora reads **committed** files, so anything you have only saved — not
committed — will not appear in the preview.

`node_modules/` and `www/` are gitignored, and `galaxy.yml` keeps all of the
Showroom files out of the built collection.

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `podman ... is too old` | Quadlet needs podman ≥ 4.4. `sudo dnf -y install podman` on RHEL 9.2+. |
| `has no /etc/subuid range` | Rootless podman needs one. Run the `usermod` command in the error, or deploy with `-e rhokp_rootless=false`. |
| `rhokp_rootless=true needs an unprivileged connection user` | Facts were gathered as root. Set `become: false` on the play, or use `-e rhokp_rootless=false`. |
| `unauthorized` / `401` on pull | The pull secret has no valid `registry.redhat.io` entry. Download a fresh one and re-run `scripts/init-secrets.sh`. |
| `Attempting to decrypt but no vault secrets found` | Pass `--vault-password-file playbooks/secrets/vault-password` or `--ask-vault-pass`. |
| Container exits immediately, `ERR_002: ACCESS_KEY could not be validated` | The key is wrong. Check it at <https://access.redhat.com/offline/access>, then `ansible-vault edit playbooks/secrets/access-key.vault` and re-run. |
| Portal installed but stopped, "no credentials were available" | Expected in degraded mode. Run `sudo /usr/sbin/rhokp-set-credentials` on the node. |
| Readiness probe times out | A cold start takes ~45s; the default allows 300s. If it still fails: `podman logs rhokp`. |
| HTTPS returns `400` but HTTP works | The edge terminates TLS and sends plain HTTP to 8443. Set `rhokp_edge_tls: true`. |
| Both RHDP routes return `504` | Nothing is listening on the bastion's 8080/8443. Re-order with **Install proxy on bastion?** checked. |
| `systemctl status` shows `failed` after a stop | Only happens on units predating `SuccessExitStatus` — see [Shutdown behaviour](#shutdown-behaviour). Clear a stale entry with `systemctl --user reset-failed rhokp.service`. |
| Service does not come back after reboot (rootless) | Check lingering: `loginctl show-user $USER --property=Linger`. |
| `cannot set cpu limit` (rootless) | Leave `rhokp_apply_resource_limits` at its default — see [Resource limits](#resource-limits). |
| `npx` fails with `EACCES` on `~/.npm/_cacache` | Unrelated to this repo; fix with `sudo chown -R $(whoami) ~/.npm`. |

---

## Licence

MIT. See [galaxy.yml](galaxy.yml) for collection metadata.
