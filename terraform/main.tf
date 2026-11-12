provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "k3d-much"
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "k3d-much"
  }
}

resource "terraform_data" "cluster" {
  input            = "much"
  triggers_replace = filesha256("${path.module}/../k3d/cluster.yaml")

  provisioner "local-exec" {
    command = "k3d cluster list ${self.input} >/dev/null 2>&1 || k3d cluster create --config ${path.module}/../k3d/cluster.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.input}"
  }
}