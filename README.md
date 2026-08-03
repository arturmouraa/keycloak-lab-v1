# Terraform Keycloak + Elastic on Docker Desktop Kubernetes

Deploys, on Docker Desktop's Kubernetes, using only official installation methods:

- **Keycloak** (via the Keycloak Operator) backed by **PostgreSQL**, fronted by
  **NGINX Gateway Fabric** (Kubernetes Gateway API) with HTTPS terminated at the
  gateway using a self-signed certificate, plus optional realm provisioning.
- **Elastic Cloud on Kubernetes (ECK)** — Elasticsearch, Kibana, Fleet Server,
  and a Fleet-managed Elastic Agent. Kibana is optionally exposed through the same
  NGINX gateway.

Both stacks are independent and can be toggled on/off.

## Architecture

```
Browser
  │  HTTPS 443 (SNI: keycloak.local | kibana.local)
  ▼
LoadBalancer Service (Docker Desktop → 127.0.0.1)
  │
NGINX Gateway Fabric  ←  GatewayClass "nginx"
  │  Gateway: keycloak-gateway
  │   ├─ listener https/http        (keycloak.local)  → keycloak-service:8080
  │   └─ listener https-kibana/http-kibana (kibana.local) → kibana-kb-http:5601
  │      (both terminate TLS with the self-signed cert; HTTP to the backends)
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
```

Keycloak, Postgres and the gateway objects live in the `keycloak` namespace; the
NGINX controller in `gateway`; the Elastic stack in `elastic-stack`; the ECK
operator in `elastic-system`. A single LoadBalancer (one Gateway) fronts both
`keycloak.local` and `kibana.local` via SNI.

## Why kubectl instead of `kubernetes_manifest`

The `kubernetes` Terraform provider validates `kubernetes_manifest` resources
against the live cluster API **at plan time**. For CRDs installed within the same
apply (Gateway API, Keycloak Operator, ECK), the resource types don't exist yet
when Terraform plans, so planning fails. To work around this, all custom-resource
objects (GatewayClass, Gateway, HTTPRoute, Keycloak, KeycloakRealmImport,
Elasticsearch, Kibana, Agent) are applied through `kubectl` inside `terraform_data`
+ `local-exec` provisioners. Plain core resources (Secrets, Deployment, Service,
PVC, Namespace) still use the native provider.

## Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl`, `terraform >= 1.6`, `helm >= 3.14`
- Docker Desktop can pull from `quay.io` (Keycloak), `ghcr.io` (NGINX) and
  `docker.elastic.co` (Elastic) — no extra auth needed
- Helm OCI registry support is built in; no `helm repo add` required
- **Resources:** the Elastic stack is memory-hungry. Give Docker Desktop at least
  **8 GB RAM** (6 GB is the practical floor with `elastic_es_memory = "2Gi"` and
  `elastic_kibana_memory = "1Gi"`). Lower the memory vars or set
  `enable_elastic = false` if constrained.

## 1. Add hostnames to /etc/hosts

```bash
echo "127.0.0.1  keycloak.local" | sudo tee -a /etc/hosts
# only if exposing Kibana via the gateway (expose_kibana_via_gateway = true):
echo "127.0.0.1  kibana.local"   | sudo tee -a /etc/hosts
```

## 2. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
# then edit terraform.tfvars
```

`keycloak_admin_password` and `postgres_db_password` must be changed from their
placeholder defaults — `validation` blocks on both variables reject common
placeholder values (`admin`, `changeme`, `keycloak`, etc.) outright, so
`terraform plan` fails with a clear error until you set real ones.

### Deploying to Proxmox / bare-metal instead of Docker Desktop

`terraform.tfvars.proxmox.example` is a second starting point for a bare-metal
cluster fronted by MetalLB, with Let's Encrypt (cert-manager) as an alternative
to the built-in self-signed CA. Copy it instead of the Docker Desktop example:

```bash
cp terraform.tfvars.proxmox.example terraform.tfvars
# then edit terraform.tfvars — the file's comments walk through MetalLB
# IP pinning (gateway_load_balancer_ip) and enabling Let's Encrypt
# (enable_lets_encrypt, cluster_issuer)
```

See the [Configuration reference](#configuration-reference) below for every
variable this path touches (TLS/Let's Encrypt, bare-metal/MetalLB, and the
per-component gateway-exposure toggles).

## 3. Deploy

```bash
terraform init
terraform apply
```

The apply is fully sequenced within each stack — CRDs install first, controllers
become ready, then the custom resources are applied. The Elastic stack can take
several minutes on first run while images pull and Elasticsearch initializes.

## 4. Trust the self-signed CA

After apply, the CA cert is written to `certs/ca.crt`. The same CA signs the cert
used for both `keycloak.local` and `kibana.local`, so trusting it once covers both.

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

Retrieve the admin credentials (they match your tfvars):

```bash
kubectl get secret keycloak-bootstrap-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get secret keycloak-bootstrap-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d
```

## 6. Access Kibana / Elastic

When `expose_kibana_via_gateway = true`, Kibana is reachable through the gateway at:

- **https://kibana.local**

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

- The server certificate gains `kibana.local` as an additional SAN, so the single
  `keycloak-tls` secret backs both the `keycloak.local` and `kibana.local` HTTPS
  listeners (distinguished by SNI on the same LoadBalancer).
- The Gateway gets `https-kibana` / `http-kibana` listeners with
  `allowedRoutes.namespaces.from: All`, so the Kibana HTTPRoute (which lives in
  the `elastic-stack` namespace) can attach cross-namespace.
- Kibana's `spec.http.tls.selfSignedCertificate.disabled = true` makes it serve
  HTTP on 5601, and `server.publicBaseUrl = https://kibana.local` makes it
  generate correct external links.

This avoids `BackendTLSPolicy` for Kibana specifically. The optional
Elasticsearch-API route (`expose_es_via_gateway`) takes the opposite approach —
it keeps ES's self-signed TLS on and uses `BackendTLSPolicy` so the gateway
re-encrypts to it — since re-encrypting to a datastore's own TLS is worth the
extra piece, whereas terminating once for an HTTP-only UI like Kibana isn't.

## Configuration reference

All variables have sensible defaults for local dev; override them in `terraform.tfvars`.

### Keycloak / gateway / Postgres

| Variable | Default | Description |
|----------|---------|-------------|
| `kubeconfig_path` | `~/.kube/config` | Path to kubeconfig |
| `kube_context` | `docker-desktop` | Kube context to target |
| `keycloak_namespace` | `keycloak` | Namespace for Keycloak, Postgres, gateway resources |
| `gateway_namespace` | `gateway` | Namespace for the NGINX Gateway Fabric controller |
| `keycloak_hostname` | `keycloak.local` | Hostname for TLS SAN + routing (match /etc/hosts) |
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
| `expose_kibana_via_gateway` | `true` | Expose Kibana through the NGINX gateway |
| `elastic_kibana_hostname` | `kibana.local` | External hostname for Kibana (becomes a TLS SAN) |
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
| `elastic_es_hostname` | `elasticsearch.local` | Hostname for the Elasticsearch API via the gateway (becomes a TLS SAN) |
| `expose_fleet_via_gateway` | `false` | Expose Fleet Server through the gateway. Fleet's long-polling check-in over HTTP/2 can need L7 tuning behind a gateway — `elastic_enable_external_fleet` (a dedicated L4 LoadBalancer) is the more robust option |
| `elastic_fleet_hostname` | `fleet.local` | Hostname for Fleet Server via the gateway (becomes a TLS SAN) |
| `enable_fleet_direct_tls` | `false` | Serve a cert-manager cert directly on Fleet's `:8220` LoadBalancer instead of the gateway. Needs an issuer that populates `ca.crt` (not Let's Encrypt/ACME) |
| `enable_fleet_le_proxy` | `false` | Front Fleet Server with a small nginx TLS-terminating proxy that presents a Let's Encrypt cert and re-encrypts to Fleet's stock self-signed `:8220`. Requires `enable_lets_encrypt`/cert-manager |
| `fleet_le_proxy_load_balancer_ip` | `""` | MetalLB IP for the Fleet LE proxy's LoadBalancer Service |

`expose_fleet_via_gateway`, `enable_fleet_direct_tls`, and `enable_fleet_le_proxy`
are mutually exclusive Fleet exposure methods — enabling more than one fails at
plan time.

### TLS / Let's Encrypt

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_lets_encrypt` | `false` | Issue gateway TLS certs via cert-manager + Let's Encrypt instead of the built-in self-signed CA. Requires cert-manager and PUBLIC, Cloudflare-managed hostnames (not `.local`) |
| `cluster_issuer` | `letsencrypt-staging` | cert-manager `ClusterIssuer` to use when `enable_lets_encrypt = true` (or for the Fleet direct-TLS/LE-proxy paths) |

### Bare-metal / MetalLB

| Variable | Default | Description |
|----------|---------|-------------|
| `gateway_load_balancer_ip` | `""` | Pin the NGINX gateway's LoadBalancer IP via MetalLB. Leave empty on Docker Desktop; on Proxmox, set to the MetalLB pool IP your `/etc/hosts` entries point at |

### kube-state-metrics

Feeds the Elastic Agent Kubernetes integration's `state_*` metrics. Independent
of both stacks above.

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_kube_state_metrics` | `true` | Whether to install kube-state-metrics |
| `kube_state_metrics_namespace` | `kube-system` | Namespace for kube-state-metrics |
| `kube_state_metrics_chart_version` | `5.27.1` | kube-state-metrics Helm chart version (prometheus-community) |

## Outputs

| Output | Description |
|--------|-------------|
| `keycloak_url` | Base URL |
| `admin_console` | Admin console URL |
| `admin_username` | Configured admin username |
| `realm_url` | Imported realm URL (or a disabled notice) |
| `realm_openid_config` | OIDC discovery URL for the realm |
| `cert_secret_name` | Name of the TLS secret used by the gateway |
| `get_admin_credentials` | Commands to read the Keycloak admin credentials |
| `elastic_kibana_url` | Kibana URL (gateway) or a port-forward note |
| `elastic_kibana_port_forward` | Command to port-forward Kibana |
| `elastic_get_password` | Command to read the `elastic` user password |
| `elastic_check_status` | Command to check Elastic resource status |
| `kube_state_metrics_service` | kube-state-metrics Service (or a disabled notice) |
| `kube_state_metrics_elastic_host` | Host to set for the KSM data streams in the Elastic Kubernetes integration |

## PostgreSQL persistence

The database is backed by a `PersistentVolumeClaim` (`postgres-pvc`), dynamically
provisioned by Docker Desktop's default `hostpath` StorageClass. Because that
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
  Elastic custom resources in the cluster. The `crds.yaml` is applied with
  `kubectl apply --server-side` to avoid the client-side annotation size limit the
  large ECK CRDs otherwise hit.
- **Single-node dev cluster.** `node.store.allow_mmap: false` is set so
  Elasticsearch runs on Docker Desktop without tuning `vm.max_map_count`.

## Teardown

```bash
terraform destroy
# Remove the hosts entries manually
sudo sed -i '' '/keycloak.local/d;/kibana.local/d' /etc/hosts   # macOS
```

Destroy provisioners guard each custom-resource deletion with a CRD-existence
check, so teardown won't error even if CRDs were already removed. Note that
destroying the Elasticsearch resource releases its PVC; data is not retained.

## Project layout

```
keycloak-lab-v1/
├── main.tf                           # module wiring + cross-variable config guardrails
├── variables.tf
├── outputs.tf
├── providers.tf
├── terraform.tfvars.example          # Docker Desktop starting point
├── terraform.tfvars.proxmox.example  # Proxmox/MetalLB + Let's Encrypt starting point
├── certs/                            # generated CA cert (git-ignored, self-signed path only)
└── modules/
    ├── cert/                   # self-signed CA + server cert (multi-SAN), or cert-manager/Let's Encrypt, TLS secret, namespace
    ├── gateway/                # Gateway API CRDs, NGINX Gateway Fabric, Gateway + routes (Keycloak/Kibana/Elasticsearch/Fleet listeners)
    ├── postgres/               # PostgreSQL Deployment, Service, PVC, Secret
    ├── keycloak/               # Operator, Keycloak CR, realm import
    ├── elastic/                # ECK operator + Elasticsearch, Kibana, Fleet Server, Elastic Agent, gateway routes
    └── kube-state-metrics/     # kube-state-metrics Helm release
```
