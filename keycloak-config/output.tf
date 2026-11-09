output "client_secret" {
  value       = keycloak_openid_client.vault_client.client_secret
  sensitive = true
}