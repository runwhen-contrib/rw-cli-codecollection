output "namespace" {
  value = kubernetes_namespace.seaweedfs.metadata[0].name
}

output "release_name" {
  value = helm_release.seaweedfs.name
}

output "context" {
  value = var.kube_context
}
