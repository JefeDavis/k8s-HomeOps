data "authentik_flow" "default-authorization-flow" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default-source-authentication" {
  slug = "default-source-authentication"
}

data "authentik_flow" "default-authentication-flow" {
  slug = "default-authentication-flow"
}

data "authentik_flow" "default-enrollment-flow" {
  slug = "default-source-enrollment"
}
