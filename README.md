# Terraform Keycloak + Elastic on Kubernetes

Deploys, using only official installation methods:

- **Keycloak** (via the Keycloak Operator) backed by **PostgreSQL**, fronted by
  **NGINX Gateway Fabric** (Kubernetes Gateway API) with HTTPS terminated at the
  gateway, plus optional realm provisioning.
- **Elastic Cloud on Kubernetes (ECK)** — Elasticsearch, Kibana, Fleet Server,
  and a Fleet-managed Elastic Agent. Kibana is optionally exposed through the same
  NGINX gateway.

Both stacks are independent and can be toggled on/off.

## Two environments, one set of modules

This repo is two separate root Terraform configs, each with its own state,
sharing the same `modules/`:

| Environment | For | TLS |
|-------------|-----|-----|
| [`environments/docker-desktop/`](environments/docker-desktop) | Plain Docker Desktop with Kubernetes enabled | Built-in self-signed CA (default), or Let's Encrypt via Cloudflare DNS-01 — this environment installs cert-manager itself, so it's self-contained |
| [`environments/existing-cluster/`](environments/existing-cluster) | An existing/bare-metal cluster (MetalLB for LoadBalancer IPs; the example tfvars targets a Proxmox cluster) | Built-in self-signed CA (default), or Let's Encrypt — assumes cert-manager and a ClusterIssuer are already provisioned elsewhere on that cluster (e.g. by a sibling `../proxmox-k8s` project) |

Pick the directory matching your target and run every command from inside it —
`terraform init`/`apply`/`destroy` all operate on that environment's own state,
independently of the other one. Everything below (steps, variables, outputs)
applies to both unless a section says otherwise.

## Architecture

```
Browser
  │  HTTPS 443 (SNI: keycloak.local | kibana.local)
  ▼
LoadBalancer Service (Docker Desktop → 127.0.0.1, or MetalLB on existing-cluster)
  │
NGINX Gateway Fabric  ←  GatewayClass "nginx"
  │  Gateway: keycloak-gateway
  │   ├─ listener https/http        (keycloak.local)  → keycloak-service:8080
  │   └─ listener https-kibana/http-kibana (kibana.local) → kibana-kb-http:5601
  │      (both terminate TLS with the cert from modules/cert; HTTP to the backends)
  │
  ├─ HTTPRoute (keycloak ns)      → keycloak-service (ClusterIP :8080)
  └─ HTTPRoute (elastic-stack ns) → kibana-kb-http   (ClusterIP :5601, HTTP)

Keycloak Operator → Keycloak CR → Deployment + Service
  │                → KeycloakRealmImport CR → one-off import Job
  ▼
Keycloak Pod  ──►  PostgreSQL (ClusterIP :5432, PVC-backed)

ECK Operator (elastic-system)
  │  reconciles the following in the elastic-stack namespace:
  ├─ Elasticsearch (self-signed TLS, PVC-backed)
  ├─ Kibana (Fleet pre-configured; HTTP-layer TLS disabled when gateway-exposed)
  ├─ Agent "fleet-server"  (mode: fleet, fleetServerEnabled)
  └─ Agent "elastic-agent" (mode: fleet, DaemonSet, enrolled via Fleet Server)

(docker-desktop only, when enable_lets_encrypt = true)
cert-manager (installed by modules/cloudflare-dns01)
  └─ ClusterIssuer letsencrypt-staging / letsencrypt-prod (ACME, Cloudflare DNS-01)
       └─ modules/cert's Certificate CR references one of these instead of the
          built-in self-signed CA
```

Keycloak, Postgres and the gateway objects live in the `keycloak` namespace; the
NGINX controller in `gateway`; the Elastic stack in `elastic-stack`; the ECK
operator in `elastic-system`; cert-manager (docker-desktop's Let's Encrypt path
only) in `cert-manager`. A single LoadBalancer (one Gateway) fronts both
`keycloak.local` and `kibana.local` via SNI.

## Why kubectl instead of `kubernetes_manifest`

The `kubernetes` Terraform provider validates `kubernetes_manifest` resources
against the live cluster API **at plan time**. For CRDs installed within the same
apply (Gateway API, Keycloak Operator, ECK, cert-manager), the resource types
don't exist yet when Terraform plans, so planning fails. To work around this,
all custom-resource objects (GatewayClass, Gateway, HTTPRoute, Keycloak,
KeycloakRealmImport, Elasticsearch, Kibana, Agent, ClusterIssuer) are applied
through `kubectl` inside `terraform_data` + `local-exec` provisioners. Plain
core resources (Secrets, Deployment, Service, PVC, Namespace) still use the
native provider. Every rendered manifest is base64-round-tripped before being
piped into `kubectl apply -f -`, so nothing in an operator-supplied variable
(a hostname, a redirect URI) can break out of the shell string.

## Prerequisites

- `kubectl`, `terraform >= 1.6`, `helm >= 3.14`
- Can pull from `quay.io` (Keycloak), `ghcr.io` (NGINX), `docker.elastic.co`
  (Elastic), and `quay.io/jetstack` (cert-manager, docker-desktop's Let's
  Encrypt path only) — no extra auth needed
- Helm OCI registry support is built in; no `helm repo add` required
- **Resources:** the Elastic stack is memory-hungry. Give the cluster at least
  **8 GB RAM** (6 GB is the practical floor with `elastic_es_memory = "2Gi"` and
  `elastic_kibana_memory = "1Gi"`). Lower the memory vars or set
  `enable_elastic = false` if constrained.
- **docker-desktop**: Docker Desktop with Kubernetes enabled.
- **existing-cluster**: a working kubeconfig context for that cluster, and
  (for the Let's Encrypt path) cert-manager + a ClusterIssuer already installed
  there.

## 1. Add hostnames to /etc/hosts

```bash
echo "127.0.0.1  keycloak.local" | sudo tee -a /etc/hosts
# only if exposing Kibana via the gateway (expose_kibana_via_gateway = true):
echo "127.0.0.1  kibana.local"   | sudo tee -a /etc/hosts
```

On `existing-cluster`, point these at the gateway's MetalLB IP instead of
127.0.0.1 — see that environment's `terraform.tfvars.example`.

## 2. Configure variables

```bash
cd environments/docker-desktop      # or environments/existing-cluster
cp terraform.tfvars.example terraform.tfvars
# then edit terraform.tfvars
```

`keycloak_admin_password` and `postgres_db_password` must be changed from their
placeholder defaults — `validation` blocks on both variables reject common
placeholder values (`admin`, `changeme`, `keycloak`, etc.) outright, so
`terraform plan` fails with a clear error until you set real ones.

### Optional: Let's Encrypt via Cloudflare DNS-01 (docker-desktop only)

By default `docker-desktop` uses the built-in self-signed CA (see [step
4](#4-trust-the-self-signed-ca)). To get publicly-trusted certs instead, this
environment can install cert-manager itself and provision Let's Encrypt
certificates through a Cloudflare DNS-01 challenge — no public inbound
connectivity is required, since DNS-01 only needs Cloudflare API access, not a
reachable HTTP endpoint. Your hostnames can still resolve to `127.0.0.1` via
`/etc/hosts` exactly like the self-signed path.

You need:
1. A domain managed in Cloudflare DNS.
2. A Cloudflare API token scoped to `Zone:DNS:Edit` on that zone
   ([create one here](https://dash.cloudflare.com/profile/api-tokens)) — not
   the legacy Global API Key.
3. An email address for Let's Encrypt's ACME account.

Set in `terraform.tfvars`:

```hcl
enable_lets_encrypt  = true
domain               = "example.com"
cloudflare_api_token = "<your scoped API token>"
acme_email           = "you@example.com"
cluster_issuer       = "letsencrypt-staging"   # switch to letsencrypt-prod once certs issue cleanly
```

`domain` is a convenience: `keycloak_hostname`, `elastic_kibana_hostname`,
`elastic_es_hostname`, and `elastic_fleet_hostname` all default to
`<service>.<domain>` when left unset, or you can still set any of them
individually to override just that one. `config_guard` in `main.tf` fails
`terraform plan` early if `enable_lets_encrypt = true` without
`cloudflare_api_token`, `acme_email`, or a usable hostname source.

`existing-cluster` doesn't have `domain`/`cloudflare_api_token`/`acme_email` —
its `enable_lets_encrypt` assumes cert-manager and the ClusterIssuer already
exist on that cluster (see that environment's `terraform.tfvars.example` for
the full walkthrough, including the `../proxmox-k8s` reference).

## 3. Deploy

```bash
terraform init
terraform apply
```

The apply is fully sequenced within each stack — CRDs install first, controllers
become ready, then the custom resources are applied. The Elastic stack can take
several minutes on first run while images pull and Elasticsearch initializes.
On docker-desktop with `enable_lets_encrypt = true`, cert-manager installs and
the ACME DNS-01 challenge completes before the Keycloak/Kibana certificate is
issued — this can take a few minutes on top of everything else.

## 4. Trust the self-signed CA

Skip this step if you're using Let's Encrypt (`enable_lets_encrypt = true`) —
those certs are already publicly trusted.

After apply, the CA cert is written to `certs/ca.crt` **inside the environment
directory you applied from**. The same CA signs the cert used for both
`keycloak.local` and `kibana.local`, so trusting it once covers both.

**macOS**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain certs/ca.crt
```

**Windows (PowerShell as Admin)**
```powershell
Import-Certificate -FilePath "certs\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

**Linux**
```bash
sudo cp certs/ca.crt /usr/local/share/ca-certificates/keycloak-dev-ca.crt
sudo update-ca-certificates
```

## 5. Access Keycloak

| URL | Description |
|-----|-------------|
| https://keycloak.local | Keycloak root |
| https://keycloak.local/admin | Admin console |
| https://keycloak.local/realms/demo | Imported realm (if enabled) |
| https://keycloak.local/realms/demo/.well-known/openid-configuration | OIDC discovery for the realm |

(Substitute your actual `keycloak_hostname` — e.g. `keycloak.example.com` under
Let's Encrypt.)

Retrieve the admin credentials (they match your tfvars):

```bash
kubectl get secret keycloak-bootstrap-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get secret keycloak-bootstrap-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d
```

## 6. Access Kibana / Elastic

When `expose_kibana_via_gateway = true`, Kibana is reachable through the gateway at:

- **https://kibana.local** (or `https://kibana.<domain>` under Let's Encrypt)

The login user is `elastic`; get the generated password:

```bash
kubectl get secret elasticsearch-es-elastic-user -n elastic-stack \
  -o jsonpath='{.data.elastic}' | base64 -d
```

Watch the stack come up:

```bash
kubectl get elasticsearch,kibana,agent -n elastic-stack
```

If you set `expose_kibana_via_gateway = false`, reach Kibana with a port-forward
instead (Kibana keeps its own self-signed TLS in that case — open https://localhost:5601):

```bash
kubectl port-forward -n elastic-stack service/kibana-kb-http 5601
```

In Kibana, Fleet is pre-configured: the "Fleet Server on ECK policy" and
"Elastic Agent on ECK policy" policies are created automatically, the Fleet Server
enrolls itself, and the Elastic Agent DaemonSet enrolls into it (collecting system
and Kubernetes integration data).

## How Kibana is exposed through the gateway

Rather than re-encrypting to Kibana's self-signed certificate, the setup mirrors
Keycloak: TLS is terminated at the gateway and the gateway speaks plain HTTP to
Kibana in-cluster. Concretely, when `expose_kibana_via_gateway = true`:

- The server certificate gains `kibana.local` (or `kibana.<domain>`) as an
  additional SAN, so the single `keycloak-tls` secret backs both the
  `keycloak.local` and `kibana.local` HTTPS listeners (distinguished by SNI on
  the same LoadBalancer).
- The Gateway gets `https-kibana` / `http-kibana` listeners with
  `allowedRoutes.namespaces.from: All`, so the Kibana HTTPRoute (which lives in
  the `elastic-stack` namespace) can attach cross-namespace.
- Kibana's `spec.http.tls.selfSignedCertificate.disabled = true` makes it serve
  HTTP on 5601, and `server.publicBaseUrl` makes it generate correct external
  links.

This avoids `BackendTLSPolicy` for Kibana specifically. The optional
Elasticsearch-API route (`expose_es_via_gateway`) takes the opposite approach —
it keeps ES's self-signed TLS on and uses `BackendTLSPolicy` so the gateway
re-encrypts to it — since re-encrypting to a datastore's own TLS is worth the
extra piece, whereas terminating once for an HTTP-only UI like Kibana isn't.

## Configuration reference

All variables have sensible defaults; override them in `terraform.tfvars`.
Unless a table says otherwise, these exist in both environments — the two
`variables.tf` files are near-identical except where called out below.

### Keycloak / gateway / Postgres

| Variable | Default | Description |
|----------|---------|-------------|
| `kubeconfig_path` | `~/.kube/config` | Path to kubeconfig |
| `kube_context` | `docker-desktop` on that environment; **required, no default** on `existing-cluster` | Kube context to target |
| `keycloak_namespace` | `keycloak` | Namespace for Keycloak, Postgres, gateway resources |
| `gateway_namespace` | `gateway` | Namespace for the NGINX Gateway Fabric controller |
| `keycloak_hostname` | `keycloak.local` (`existing-cluster`); `""` → derives from `domain` or falls back to `keycloak.local` (`docker-desktop`) | Hostname for TLS SAN + routing (match /etc/hosts) |
| `keycloak_admin_user` | `admin` | Initial admin username (first start only) |
| `keycloak_admin_password` | `admin`, but **rejected by validation** — must override | Initial admin password (first start only) |
| `postgres_db_name` | `keycloak` | PostgreSQL database name |
| `postgres_db_user` | `keycloak` | PostgreSQL user |
| `postgres_db_password` | `keycloak`, but **rejected by validation** — must override | PostgreSQL password |
| `enable_realm_import` | `true` | Provision a realm via KeycloakRealmImport |
| `realm_name` | `demo` | Name of the realm to import |
| `realm_client_id` | `demo-client` | Client ID created inside the realm |
| `realm_client_redirect_uris` | `["*"]` | Allowed redirect URIs for the sample client |

### Elastic (ECK)

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_elastic` | `true` | Deploy the Elastic stack |
| `elastic_namespace` | `elastic-stack` | Namespace for Elasticsearch/Kibana/Agents |
| `eck_version` | `3.4.0` | ECK operator version |
| `elastic_stack_version` | `9.4.3` | Elastic Stack version |
| `elastic_es_node_count` | `1` | Elasticsearch node count (keep 1 on Docker Desktop; `2` requires `elastic_enable_voting_only_node = true`, enforced at plan time) |
| `elastic_enable_voting_only_node` | `false` | Add a 3rd, master-eligible-only node so a 2-node cluster can still reach quorum |
| `elastic_es_voting_only_memory` | `1Gi` | Memory request/limit for the voting-only node |
| `elastic_es_voting_only_storage_size` | `2Gi` | PVC size for the voting-only node (cluster state only, no shard data) |
| `elastic_es_memory` | `2Gi` | Memory request/limit per Elasticsearch node |
| `elastic_es_storage_size` | `5Gi` | PVC size per Elasticsearch node |
| `elastic_kibana_memory` | `1Gi` | Memory request/limit for Kibana |
| `elastic_password` | `""` | Set the `elastic` superuser password to this value instead of ECK's auto-generated one — applied via the Security API after Elasticsearch is up (ECK has no declarative field for this). See [Setting a custom elastic password](#setting-a-custom-elastic-password) |
| `expose_kibana_via_gateway` | `true` | Expose Kibana through the NGINX gateway |
| `elastic_kibana_hostname` | `kibana.local` (`existing-cluster`); `""` → derives from `domain` (`docker-desktop`) | External hostname for Kibana (becomes a TLS SAN) |
| `elastic_enable_external_fleet` | `false` | Expose Fleet Server outside the cluster via a MetalLB LoadBalancer, for agents on bare-metal hosts/VMs/other clusters |
| `elastic_external_fleet_host` | `""` | Hostname/IP external agents use to reach Fleet Server (required when `elastic_enable_external_fleet = true`) |
| `elastic_external_fleet_load_balancer_ip` | `""` | Optional static MetalLB IP to pin Fleet Server's external LoadBalancer to |

### Exposing Elasticsearch / Fleet Server through the gateway

Off by default — Kibana is the only Elastic component fronted by the gateway
out of the box. See [How Kibana is exposed through the gateway](#how-kibana-is-exposed-through-the-gateway)
for the pattern these mirror.

| Variable | Default | Description |
|----------|---------|-------------|
| `expose_es_via_gateway` | `false` | Expose the Elasticsearch HTTP API through the gateway. **Security note:** this publishes a datastore endpoint — protect it with strong Elasticsearch credentials and, ideally, network restrictions |
| `elastic_es_hostname` | `elasticsearch.local` (`existing-cluster`); `""` → derives from `domain` (`docker-desktop`) | Hostname for the Elasticsearch API via the gateway (becomes a TLS SAN) |
| `expose_fleet_via_gateway` | `false` | Expose Fleet Server through the gateway. Fleet's long-polling check-in over HTTP/2 can need L7 tuning behind a gateway — `elastic_enable_external_fleet` (a dedicated L4 LoadBalancer) is the more robust option |
| `elastic_fleet_hostname` | `fleet.local` (`existing-cluster`); `""` → derives from `domain` (`docker-desktop`) | Hostname for Fleet Server via the gateway (becomes a TLS SAN) |
| `enable_fleet_direct_tls` | `false` | Serve a cert-manager cert directly on Fleet's `:8220` LoadBalancer instead of the gateway. Needs an issuer that populates `ca.crt` (not Let's Encrypt/ACME) |
| `enable_fleet_le_proxy` | `false` | Front Fleet Server with a small nginx TLS-terminating proxy that presents a Let's Encrypt cert and re-encrypts to Fleet's stock self-signed `:8220`. Requires `enable_lets_encrypt`/cert-manager |
| `fleet_le_proxy_load_balancer_ip` | `""` | MetalLB IP for the Fleet LE proxy's LoadBalancer Service |

`expose_fleet_via_gateway`, `enable_fleet_direct_tls`, and `enable_fleet_le_proxy`
are mutually exclusive Fleet exposure methods — enabling more than one fails at
plan time.

### TLS / Let's Encrypt

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_lets_encrypt` | `false` | Issue gateway TLS certs via cert-manager + Let's Encrypt instead of the built-in self-signed CA. **docker-desktop**: self-contained — installs cert-manager itself via `modules/cloudflare-dns01`, using Cloudflare DNS-01. **existing-cluster**: assumes cert-manager and the ClusterIssuer already exist on that cluster |
| `cluster_issuer` | `letsencrypt-staging` | cert-manager `ClusterIssuer` to use when `enable_lets_encrypt = true` (or for the Fleet direct-TLS/LE-proxy paths) |

**docker-desktop only:**

| Variable | Default | Description |
|----------|---------|-------------|
| `domain` | `""` | Base domain managed in Cloudflare DNS. When set, `keycloak_hostname`/`elastic_kibana_hostname`/`elastic_es_hostname`/`elastic_fleet_hostname` default to `<service>.<domain>` unless individually overridden |
| `cloudflare_api_token` | `""` | Cloudflare API token scoped to `Zone:DNS:Edit`. Required when `enable_lets_encrypt = true` |
| `acme_email` | `""` | Email registered with Let's Encrypt for expiry notices / ACME account recovery. Required when `enable_lets_encrypt = true` |

### Bare-metal / MetalLB

| Variable | Default | Description |
|----------|---------|-------------|
| `gateway_load_balancer_ip` | `""` | Pin the NGINX gateway's LoadBalancer IP via MetalLB. Leave empty on Docker Desktop; on an existing bare-metal cluster, set to the MetalLB pool IP your `/etc/hosts` entries point at |

### kube-state-metrics

Feeds the Elastic Agent Kubernetes integration's `state_*` metrics. Independent
of both stacks above.

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_kube_state_metrics` | `true` | Whether to install kube-state-metrics |
| `kube_state_metrics_namespace` | `kube-system` | Namespace for kube-state-metrics |
| `kube_state_metrics_chart_version` | `5.27.1` | kube-state-metrics Helm chart version (prometheus-community) |

## Outputs

Run `terraform output` from inside the environment directory you applied from.
`admin_password` and `elastic_password` are marked `sensitive` — Terraform
hides them from plain `terraform output`; use `terraform output -raw
admin_password` (or `-json` for scripts) to print the actual value.

| Output | Description |
|--------|-------------|
| `keycloak_url` | Base URL |
| `admin_console` | Admin console URL |
| `admin_username` | Configured admin username |
| `admin_password` | Keycloak admin password (sensitive). From `terraform.tfvars`, not read back from the cluster — see the output's own description for the first-boot-only caveat |
| `realm_url` | Imported realm URL (or a disabled notice) |
| `realm_openid_config` | OIDC discovery URL for the realm |
| `cert_secret_name` | Name of the TLS secret used by the gateway |
| `get_admin_credentials` | Commands to read the Keycloak admin credentials from the cluster directly, as an alternative to `admin_password` |
| `elastic_kibana_url` | Kibana URL (gateway) or a port-forward note |
| `elastic_kibana_port_forward` | Command to port-forward Kibana |
| `elastic_password` | The `elastic` superuser password (sensitive), read directly from the ECK-generated secret |
| `elastic_get_password` | Command to read the `elastic` user password yourself, as an alternative to `elastic_password` |
| `elastic_check_status` | Command to check Elastic resource status |
| `kube_state_metrics_service` | kube-state-metrics Service (or a disabled notice) |
| `kube_state_metrics_elastic_host` | Host to set for the KSM data streams in the Elastic Kubernetes integration |

## PostgreSQL persistence

The database is backed by a `PersistentVolumeClaim` (`postgres-pvc`), dynamically
provisioned by the cluster's default StorageClass (Docker Desktop's `hostpath`
provisioner, or whatever `existing-cluster` has configured). Because that
StorageClass binds on first consumer, the PVC only binds once the Postgres pod is
scheduled. Data survives pod restarts. The Deployment uses the `Recreate` strategy
because a single-volume database must never run two pods against the same data
directory at once. Adjust the volume size with `storage_size` in the postgres
module (default `1Gi`).

## Realm import

When `enable_realm_import = true`, a `KeycloakRealmImport` CR provisions a realm
and a sample public client after the Keycloak instance reports `Ready`.

Important: the operator only **creates** realms — it never updates or deletes an
existing one. Changing realm variables and re-applying will not modify a realm
that already exists. To change an existing realm, edit it in the admin console, or
delete the realm (or the whole DB) and re-import. Set `enable_realm_import = false`
to skip it entirely.

## Elastic stack notes

- **Fleet is wired via CRs.** Fleet Server is an `Agent` with `mode: fleet` and
  `fleetServerEnabled: true`; the Elastic Agent is an `Agent` with `mode: fleet`
  and a `fleetServerRef`. Kibana's `xpack.fleet.*` config points at the in-cluster
  Elasticsearch and Fleet Server service DNS names, and defines the agent policies.
- **TLS/CA wiring is automatic.** Because components reference each other via
  `elasticsearchRef` / `kibanaRef` / `fleetServerRef`, ECK injects the right CAs —
  no manual certificate configuration is needed. Elasticsearch keeps its
  self-signed TLS; only Kibana's external HTTP layer is switched to plain HTTP when
  fronted by the gateway.
- **CRDs are cluster-scoped and shared.** Deleting the ECK CRDs deletes *all*
  Elastic custom resources in the cluster, so `terraform destroy` deliberately
  leaves them installed (same treatment as the Gateway API and Keycloak
  Operator CRDs) rather than cascade-deleting cluster-wide — remove them
  manually if you want them gone. The `crds.yaml` is applied with
  `kubectl apply --server-side` to avoid the client-side annotation size limit the
  large ECK CRDs otherwise hit.
- **Single-node dev cluster.** `node.store.allow_mmap: false` is set so
  Elasticsearch runs without tuning `vm.max_map_count`.

## Setting a custom elastic password

By default ECK auto-generates the `elastic` superuser's password and stores it
in the `elasticsearch-es-elastic-user` Secret — that's what `elastic_get_password`
and the `elastic_password` output read. ECK has no declarative field to set
this password yourself (file-realm/custom-user secrets add *additional* users,
they can't override the built-in `elastic` user), so setting `elastic_password`
in `terraform.tfvars` takes the officially documented route instead: after
Elasticsearch is up, Terraform calls the Elasticsearch Security API
(`POST _security/user/elastic/_password`) via `kubectl exec` + curl inside the
Elasticsearch pod itself, authenticated with the current password, then syncs
the `elasticsearch-es-elastic-user` Secret to match so later reads see the new
value instead of the stale auto-generated one.

Notes:
- Leave `elastic_password` empty (the default) to keep ECK's auto-generated
  password — nothing changes.
- Unsetting `elastic_password` after it's been applied does **not** roll the
  password back to a fresh auto-generated one; it just stops being managed
  here. Use ECK's own rotation mechanism (delete the Secret, and ECK
  regenerates it) if you want that.
- If you rotate the password outside Terraform (e.g. via Kibana) without
  touching `terraform.tfvars`, Terraform won't detect or fix that drift on the
  next apply — same behavior as the other credential variables in this repo.

## cert-manager + Let's Encrypt via Cloudflare (docker-desktop only)

`modules/cloudflare-dns01` is what makes `docker-desktop`'s
`enable_lets_encrypt = true` self-contained instead of assuming an externally
provisioned cert-manager:

1. Installs cert-manager via Helm (`oci://quay.io/jetstack/charts/cert-manager`,
   CRDs included).
2. Waits for the webhook Deployment to be `Available` — cert-manager validates
   `ClusterIssuer`/`Certificate` objects through its own admission webhook, so
   applying one too early fails with a connection error rather than a clean
   validation error.
3. Publishes your `cloudflare_api_token` as a Secret in the `cert-manager`
   namespace (its default "cluster resource namespace" for ClusterIssuer
   secrets).
4. Applies **both** `letsencrypt-staging` and `letsencrypt-prod` `ClusterIssuer`s
   with a Cloudflare `dns01` solver, so switching `cluster_issuer` between them
   doesn't require re-running this module.

`modules/cert`'s existing `use_cert_manager` path then points its `Certificate`
at whichever `cluster_issuer` you picked, same as it always did for the
externally-provisioned case on `existing-cluster`.

**Teardown:** cert-manager is treated as shared cluster infrastructure (like the
Gateway API CRDs elsewhere in this repo) rather than something owned
exclusively by this stack, so `terraform destroy` leaves cert-manager, its
ClusterIssuers, and the Cloudflare token Secret in place rather than
uninstalling them. The destroy provisioner in `modules/cloudflare-dns01` prints
the manual commands to remove them if you want a fully clean slate.

## Teardown

From inside the environment directory:

```bash
terraform destroy
# Remove the hosts entries manually
sudo sed -i '' '/keycloak.local/d;/kibana.local/d' /etc/hosts   # macOS
```

Destroy provisioners guard each custom-resource deletion with a CRD-existence
check, so teardown won't error even if CRDs were already removed. Note that
destroying the Elasticsearch resource releases its PVC; data is not retained.

## Migrating from the old single-root layout

Earlier versions of this repo had `main.tf`/`variables.tf`/`outputs.tf`/
`providers.tf` directly at the repo root instead of under `environments/`. If
you have state from that layout (a root-level `terraform.tfstate` or a
Terraform Cloud/remote workspace pointed at the repo root), it is now orphaned
— the resources it manages still exist in your cluster, but nothing in this
repo references that state anymore. Before pulling this change:

1. From the old root checkout, run `terraform destroy` to tear down what it
   manages, **or**
2. `terraform state pull`/`push` (or `terraform import`) that state into
   `environments/docker-desktop/` or `environments/existing-cluster/`,
   whichever matches what you had deployed.

Skipping this leaves live cluster resources with no Terraform config managing
them.

## Project layout

```
keycloak-lab-v1/
├── environments/
│   ├── docker-desktop/          # root config: plain Docker Desktop, own state
│   │   ├── main.tf                    # module wiring + config guardrails
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── terraform.tfvars.example
│   │   └── certs/                     # generated CA cert (git-ignored, self-signed path only)
│   └── existing-cluster/        # root config: existing/bare-metal cluster, own state
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars.example   # targets Proxmox by default; adjust for yours
│       └── certs/
└── modules/                     # shared by both environments
    ├── cert/                   # self-signed CA + server cert (multi-SAN), or cert-manager/Let's Encrypt, TLS secret, namespace
    ├── gateway/                # Gateway API CRDs, NGINX Gateway Fabric, Gateway + routes (Keycloak/Kibana/Elasticsearch/Fleet listeners)
    ├── postgres/               # PostgreSQL Deployment, Service, PVC, Secret
    ├── keycloak/               # Operator, Keycloak CR, realm import
    ├── elastic/                # ECK operator + Elasticsearch, Kibana, Fleet Server, Elastic Agent, gateway routes
    ├── kube-state-metrics/     # kube-state-metrics Helm release
    └── cloudflare-dns01/       # cert-manager + Let's Encrypt ClusterIssuers via Cloudflare DNS-01 (docker-desktop only)
```
