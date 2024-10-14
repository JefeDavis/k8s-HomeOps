data "authentik_certificate_key_pair" "default-certificate" {
  name = "authentik Self-signed Certificate"
}

resource "authentik_property_mapping_provider_scope" "oauth2-scopes" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-profile"
  ]
}

