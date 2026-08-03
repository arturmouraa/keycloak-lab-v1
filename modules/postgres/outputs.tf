output "host" {
  value = kubernetes_service.postgres.metadata[0].name
}

output "port" {
  value = 5432
}

output "db_name" {
  value = var.db_name
}

output "secret_name" {
  value = kubernetes_secret.postgres.metadata[0].name
}
