# -----------------------------------------------------------------------------
# PostgreSQL — plain Kubernetes manifests for local dev
# Runs in the same namespace as Keycloak (no separate DB namespace needed)
# Data persisted via a PersistentVolumeClaim (Docker Desktop's default
# StorageClass "hostpath" provisions it dynamically).
# -----------------------------------------------------------------------------

# --- Credentials secret ---
resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "postgres-secret"
    namespace = var.namespace
  }

  data = {
    POSTGRES_DB       = var.db_name
    POSTGRES_USER     = var.db_user
    POSTGRES_PASSWORD = var.db_password
  }
}

# --- PersistentVolumeClaim ---
resource "kubernetes_persistent_volume_claim" "postgres" {
  metadata {
    name      = "postgres-pvc"
    namespace = var.namespace
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = var.storage_size
      }
    }

    # Leave storage_class_name unset to use the cluster default
    # (on Docker Desktop that's the "hostpath" provisioner).
  }

  # The PVC is bound lazily by the first consumer (WaitForFirstConsumer on
  # Docker Desktop), so don't block apply waiting for it to bind.
  wait_until_bound = false
}

# --- Deployment ---
resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "postgres" }
    }

    # Recreate is REQUIRED for a single-volume database: it guarantees the old
    # pod is fully terminated before the new one starts, so two postmaster
    # processes never mount the same data directory at once (which would cause
    # a lock error / data corruption). ReadWriteOnce PVCs also can't be mounted
    # by two pods simultaneously.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "postgres" }
      }

      spec {
        container {
          name              = "postgres"
          image             = "postgres:16.3"
          image_pull_policy = "IfNotPresent"

          env_from {
            secret_ref {
              name = kubernetes_secret.postgres.metadata[0].name
            }
          }

          port {
            container_port = 5432
            name           = "postgres"
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
            sub_path   = "pgdata" # Avoids "lost+found" / init issues on the volume root
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", var.db_user, "-d", var.db_name]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 6
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", var.db_user, "-d", var.db_name]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres.metadata[0].name
          }
        }
      }
    }
  }
}

# --- Service (ClusterIP) ---
resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }

  spec {
    selector = { app = "postgres" }
    type     = "ClusterIP"

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

# --- Wait for Postgres to be rolled out and accepting connections ---
# Ensures Keycloak doesn't start against a DB that isn't ready yet.
resource "terraform_data" "postgres_ready" {
  triggers_replace = {
    kube_context = var.kube_context
    namespace    = var.namespace
    deployment   = kubernetes_deployment.postgres.metadata[0].name
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --context=${self.triggers_replace.kube_context} rollout status \
        deployment/${self.triggers_replace.deployment} \
        -n ${self.triggers_replace.namespace} \
        --timeout=120s
    EOT
  }

  depends_on = [kubernetes_deployment.postgres]
}
