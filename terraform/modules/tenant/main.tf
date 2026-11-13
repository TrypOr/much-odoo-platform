locals {
  sizes = {
    s = { req_cpu = "1", req_mem = "3Gi", lim_mem = "5Gi", storage = "10Gi" }
    m = { req_cpu = "2", req_mem = "5Gi", lim_mem = "8Gi", storage = "30Gi" }
  }
  quota = local.sizes[var.size]
  ns    = kubernetes_namespace_v1.this.metadata[0].name
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.name
    labels = { "much.io/tenant" = var.name }
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  metadata {
    name      = "tenant-quota"
    namespace = local.ns
  }
  spec {
    hard = {
      "requests.cpu"     = local.quota.req_cpu
      "requests.memory"  = local.quota.req_mem
      "limits.memory"    = local.quota.lim_mem
      "requests.storage" = local.quota.storage
    }
  }
}

resource "kubernetes_limit_range_v1" "this" {
  metadata {
    name      = "tenant-defaults"
    namespace = local.ns
  }
  spec {
    limit {
      type            = "Container"
      default_request = { cpu = "50m", memory = "64Mi" }
      default         = { memory = "256Mi" }
    }
  }
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = "odoo-db"
    namespace = local.ns
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = "odoo"
    password = random_password.db.result
  }
}
resource "helm_release" "tenant" {
  name      = "tenant"
  chart     = var.chart_path
  namespace = local.ns
  timeout   = 900
  values = [yamlencode({
    db = {
      instances         = var.db_instances
      cluster           = var.db_cluster
      restoreTargetTime = var.restore_target_time
    }
    odoo = {
      hostname = var.domain
    }
    backup = {
      namespaceUID = kubernetes_namespace_v1.this.metadata[0].uid
    }
  })]
  depends_on = [
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.admin,
    kubernetes_secret_v1.backup,
    kubernetes_resource_quota_v1.this,
    kubernetes_limit_range_v1.this,
  ]
}
resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "admin" {
  metadata {
    name      = "odoo-admin"
    namespace = local.ns
  }
  data = {
    admin_passwd = random_password.admin.result
  }
}
resource "kubernetes_secret_v1" "backup" {
  metadata {
    name      = "backup-s3"
    namespace = local.ns
  }
  data = {
    ACCESS_KEY_ID     = var.s3_access_key
    ACCESS_SECRET_KEY = var.s3_secret_key
  }
}
