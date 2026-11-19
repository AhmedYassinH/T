terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_context
}

variable "kube_config_path" {
  type = string
}

variable "kube_context" {
  type = string
}

variable "release" {
  type    = string
  default = "v1"
}

variable "mode" {
  type    = string
  default = "standard"
}

variable "storage_class" {
  type    = string
  default = ""
}

variable "claim_name" {
  type    = string
  default = "report-data"
}

locals {
  namespace = "kappa-practice-20"
  labels    = { app = "report-stack" }
}

data "kubernetes_namespace_v1" "target" {
  metadata {
    name = local.namespace
  }
}

resource "kubernetes_config_map_v1" "release" {
  metadata {
    name      = "report-release"
    namespace = data.kubernetes_namespace_v1.target.metadata[0].name
  }

  data = {
    release = var.release
    mode    = var.mode
  }
}

resource "kubernetes_persistent_volume_claim_v1" "report_data" {
  count = var.storage_class == "" ? 0 : 1

  metadata {
    name      = var.claim_name
    namespace = data.kubernetes_namespace_v1.target.metadata[0].name
  }

  # A WaitForFirstConsumer class needs the Deployment before it can bind.
  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = { storage = "128Mi" }
    }
  }
}

resource "kubernetes_deployment_v1" "report_stack" {
  metadata {
    name      = "report-stack"
    namespace = data.kubernetes_namespace_v1.target.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.labels
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        automount_service_account_token = false

        container {
          name    = "report"
          image   = "python:3.12.16-alpine3.24"
          command = ["python", "-m", "http.server", "8080", "--bind", "0.0.0.0", "--directory", "/site"]

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/release"
              port = "http"
            }
          }

          resources {
            requests = { cpu = "20m", memory = "24Mi" }
            limits   = { cpu = "200m", memory = "64Mi" }
          }

          volume_mount {
            name       = "config"
            mount_path = "/site"
            read_only  = true
          }

          dynamic "volume_mount" {
            for_each = kubernetes_persistent_volume_claim_v1.report_data
            content {
              name       = "data"
              mount_path = "/data"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.release.metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = kubernetes_persistent_volume_claim_v1.report_data
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = volume.value.metadata[0].name
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "4m"
    update = "4m"
  }
}

resource "kubernetes_service_v1" "report_stack" {
  metadata {
    name      = "report-stack"
    namespace = data.kubernetes_namespace_v1.target.metadata[0].name
  }

  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}
