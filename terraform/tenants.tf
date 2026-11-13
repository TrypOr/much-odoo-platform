locals {
  tenants = {
    # Restore: add  db_cluster = "restore", restore_target_time = "2026-11-13T10:00:00Z"
    acme   = { size = "s" }
    globex = { size = "s" }
  }
}

module "tenant" {
  source              = "./modules/tenant"
  for_each            = local.tenants
  name                = each.key
  domain              = "${each.key}.localtest.me"
  size                = each.value.size
  db_cluster          = try(each.value.db_cluster, "primary")
  restore_target_time = try(each.value.restore_target_time, null)
  chart_path          = "${path.module}/../charts/tenant"
  s3_access_key       = random_password.s3_access_key.result
  s3_secret_key       = random_password.s3_secret_key.result
  depends_on          = [helm_release.cnpg, helm_release.barman_plugin, helm_release.platform, helm_release.objectstore, helm_release.kube_prometheus_stack, helm_release.blackbox]
}
