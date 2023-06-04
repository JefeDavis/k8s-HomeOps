resource "authentik_blueprint" "blueprints" {
  for_each = var.blueprints
  name     = each.key
  path     = each.value.path
}
