module "acme" {
  source     = "./modules/tenant"
  name       = "acme"
  domain     = "acme.localtest.me"
  chart_path = "${path.module}/../charts/tenant"
  depends_on = [helm_release.cnpg, helm_release.barman_plugin]
}

module "globex" {
  source     = "./modules/tenant"
  name       = "globex"
  domain     = "globex.localtest.me"
  chart_path = "${path.module}/../charts/tenant"
  depends_on = [helm_release.cnpg, helm_release.barman_plugin]
}