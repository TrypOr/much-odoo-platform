locals {
  tenants = {
    acme   = { size = "s" }
    globex = { size = "s" }
  }
}

module "tenant" {
  source     = "./modules/tenant"
  for_each   = local.tenants
  name       = each.key
  domain     = "${each.key}.localtest.me"
  size       = each.value.size
  chart_path = "${path.module}/../charts/tenant"
  depends_on = [helm_release.cnpg, helm_release.barman_plugin]
}