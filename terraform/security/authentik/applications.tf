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

resource "authentik_service_connection_kubernetes" "local" {
name = "Local Kubernetes Cluster"
local = true
}

resource "authentik_outpost" "outpost" {
  name               = "Davishaus Outpost"
  service_connection = authentik_service_connection_kubernetes.local.id
  protocol_providers = [for proxy in authentik_provider_proxy.proxies : proxy.id]
  config = jsonencode({
    log_level: debug
    authentik_host: format(var.authentik_url)
    authentik_host_insecure: false
    authentik_host_browser: var.authentik_host
    object_naming_template: "ak-outpost-%(name)s"
    kubernetes_replicas: 1
    kubernetes_namespace: security
    kubernetes_ingress_annotations: {
      cert-manager.io/cluster-issuer: letsencrypt-prod
    }
    kubernetes_ingress_secret_name: authentik-outpost-tls
    kubernetes_service_type: ClusterIP
    kubernetes_disabled_components: [
      - "traefik middleware"
    ]
    kubernetes_ingress_class_name: nginx
  })
}
