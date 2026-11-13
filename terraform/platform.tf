resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.21.3"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  set              = [{ name = "crds.enabled", value = "true" }]
  depends_on       = [terraform_data.cluster]
}

resource "helm_release" "cnpg" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = "0.29.1"
  namespace        = "cnpg-system"
  create_namespace = true
  wait             = true
  depends_on       = [terraform_data.cluster]
}

resource "helm_release" "barman_plugin" {
  name       = "barman-cloud"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "plugin-barman-cloud"
  version    = "0.9.0"
  namespace  = "cnpg-system"
  wait       = true
  depends_on = [helm_release.cnpg, helm_release.cert_manager]
}

resource "helm_release" "platform" {
  name       = "platform"
  chart      = "${path.module}/../charts/platform"
  namespace  = "cert-manager"
  depends_on = [helm_release.cert_manager]
}