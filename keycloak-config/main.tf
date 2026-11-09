resource "keycloak_realm" "plant" {
  realm        = "plant"
  enabled      = true
  display_name = "Plant Realm"

  ssl_required = "external"

  registration_allowed = false

  password_policy = "length(12) and notUsername"

  security_defenses {
    brute_force_detection {
      permanent_lockout                = false
      max_login_failures               = 5
      wait_increment_seconds           = 60
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      max_failure_wait_seconds         = 900
    }
  }
}

resource "keycloak_group" "vault_admins" {
  realm_id = keycloak_realm.plant.id
  name     = "vault-admins"
}

resource "keycloak_group" "plant_readers" {
  realm_id = keycloak_realm.plant.id
  name     = "plant-readers"
}


resource "keycloak_openid_client" "vault_client" {
	realm_id = keycloak_realm.plant.id
	client_id = "vault"
	name    = "vault"
	enabled = true

	access_type           = "CONFIDENTIAL"
	standard_flow_enabled = true
	valid_redirect_uris = [
		"https://vault.cloud-telemetry.click/ui/vault/auth/oidc/oidc/callback"
	]
}

resource "keycloak_openid_group_membership_protocol_mapper" "group_membership_mapper" {
  realm_id = keycloak_realm.plant.id
  client_id = keycloak_openid_client.vault_client.id
  name      = "group-membership-mapper"

  claim_name = "groups"
  full_path = false
}