data "authentik_flow" "default-authorization-flow" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default-authentication-flow" {
  slug = "default-authentication-flow"
}

resource "authentik_provider_proxy" "wizarr" {
  name                = "Wizarr"
  mode                = "forward_single"
  external_host       = "http://join.davishaus.dev"
  authorization_flow  = data.authentik_flow.default-authorization-flow.id
  authentication_flow = data.authentik_flow.default-authentication-flow.id
}

resource "authentik_application" "name" {
  name              = "Wizarr"
  slug              = "wizarr"
  group             = "Media"
  meta_launch_url   = "https://join.davishaus.dev"
  protocol_provider = authentik_provider_proxy.wizarr.id
}
