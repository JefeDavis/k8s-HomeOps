resource "authentik_provider_proxy" "proxies" {
  for_each            = var.applications
  name                = each.key
  mode                = "forward_single"
  external_host       = each.value.url
  skip_path_regex     = each.value.skip_path_regex
  authorization_flow  = data.authentik_flow.default-authorization-flow.id
  authentication_flow = data.authentik_flow.default-authentication-flow.id
}

resource "authentik_application" "apps" {
  for_each          = authentik_provider_proxy.proxies
  name              = each.value.name
  slug              = replace(replace(lower(each.value.name), " ", "-"), "[^a-z0-9-]", "")
  group             = var.applications[each.key].group
  meta_launch_url   = each.value.external_host
  protocol_provider = each.value.id
}

resource "authentik_service_connection_kubernetes" "kubernetes_local" {
  name  = "Local Kubernetes Cluster"
  local = true
}

resource "authentik_outpost" "outpost" {
  name               = "Davishaus Outpost"
  service_connection = authentik_service_connection_kubernetes.kubernetes_local.id
  protocol_providers = [for proxy in authentik_provider_proxy.proxies : proxy.id]
}
