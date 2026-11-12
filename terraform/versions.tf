terraform {
required_version = ">= 1.6"
required_providers {
    helm       = { source = "hashicorp/helm", version = "3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.5.0" }
    random     = { source = "hashicorp/random", version = "3.9.1" }
}
}