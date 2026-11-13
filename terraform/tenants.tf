locals {
  tenants = yamldecode(file("${path.module}/../tenants.yaml"))
}

module "tenant" {
  source              = "./modules/tenant"
  for_each            = local.tenants
  name                = each.key
  domain              = "${each.key}.localtest.me"
  size                = try(each.value.size, "s")
  db_instances        = try(each.value.instances, 1)
  db_cluster          = try(each.value.restore, null) == null ? "primary" : "restore"
  restore_target_time = try(each.value.restore, null)
  chart_path          = "${path.module}/../charts/tenant"
  s3_access_key       = random_password.s3_access_key.result
  s3_secret_key       = random_password.s3_secret_key.result
  depends_on          = [helm_release.cnpg, helm_release.barman_plugin, helm_release.platform, helm_release.objectstore, helm_release.kube_prometheus_stack, helm_release.blackbox]
}
