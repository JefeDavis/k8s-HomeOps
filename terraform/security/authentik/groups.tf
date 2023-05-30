data "authentik_group" "authentik-admins" {
  name = "authentik Admins"
}

resource "authentik_group" "davishaus-admins" {
  name         = "DavusHaus Admins"
  parent       = data.authentik_group.authentik-admins.id
  is_superuser = true
  # users        = ""
}

resource "authentik_group" "grafana-admins" {
  name         = "Grafana Admins"
  parent       = authentik_group.davishaus-admins.id
  is_superuser = false
}

resource "authentik_group" "sonarr-admins" {
  name         = "Sonarr Admins"
  parent       = authentik_group.davishaus-admins.id
  is_superuser = false
}
