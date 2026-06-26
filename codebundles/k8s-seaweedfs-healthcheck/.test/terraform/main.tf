resource "kubernetes_namespace" "seaweedfs" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name" = "seaweedfs-test"
    }
  }
}

resource "helm_release" "seaweedfs" {
  name       = var.release_name
  namespace  = kubernetes_namespace.seaweedfs.metadata[0].name
  repository = "https://seaweedfs.github.io/seaweedfs/helm"
  chart      = "seaweedfs"
  version    = var.chart_version
  wait       = true
  timeout    = 600

  values = [
    yamlencode({
      master = {
        replicas = 1
        data = {
          type = "emptyDir"
        }
        logs = {
          type = "emptyDir"
        }
      }
      volume = {
        replicas = 1
        data = {
          type = "emptyDir"
        }
      }
      filer = {
        replicas = 1
        s3 = {
          enabled = true
        }
        data = {
          type = "emptyDir"
        }
      }
      global = {
        seaweedfs = {
          enableSecurity = false
        }
      }
    })
  ]
}
