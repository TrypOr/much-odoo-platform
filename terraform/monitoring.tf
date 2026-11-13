resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kps"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "93.2.2"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900
  values           = [file("${path.module}/values/kube-prometheus-stack.yaml")]
  set_sensitive    = [{ name = "grafana.adminPassword", value = random_password.grafana_admin.result }]
  depends_on       = [helm_release.platform]
}

resource "helm_release" "blackbox" {
  name       = "blackbox"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = "11.21.3"
  namespace  = "monitoring"
  values     = [file("${path.module}/values/blackbox.yaml")]
  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "monitoring" {
  name       = "monitoring"
  chart      = "${path.module}/../charts/monitoring"
  namespace  = "monitoring"
  depends_on = [helm_release.kube_prometheus_stack]
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}
