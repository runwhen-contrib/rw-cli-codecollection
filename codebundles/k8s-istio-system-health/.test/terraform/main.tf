data "aws_caller_identity" "current" {}


data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name   = var.cluster_name
  region = "us-west-2"

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  istio_chart_url     = "https://istio-release.storage.googleapis.com/charts"
  istio_chart_version = var.istio_version

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = local.name
  cluster_version                = "1.30"
  cluster_endpoint_public_access = true

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns        = {}
    kube-proxy     = {}
    vpc-cni        = {}
    metrics-server = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t2.medium"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  #  EKS K8s API cluster needs to be able to talk with the EKS worker nodes with port 15017/TCP and 15012/TCP which is used by Istio
  #  Istio in order to create sidecar needs to be able to communicate with webhook and for that network passage to EKS is needed.
  node_security_group_additional_rules = {
    ingress_15017 = {
      description                   = "Cluster API - Istio Webhook namespace.sidecar-injector.istio.io"
      protocol                      = "TCP"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15012 = {
      description                   = "Cluster API to nodes ports/protocols"
      protocol                      = "TCP"
      from_port                     = 15012
      to_port                       = 15012
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = local.tags
}

resource "kubernetes_cluster_role_binding" "eks_admins" {
  metadata { name = "eks-admins-binding" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind = "Group"
    name = "eks-admins"
  }

  depends_on = [module.eks]   # wait until cluster is ready
}


# module "eks-metrics-server" {
#   source  = "lablabs/eks-metrics-server/aws"
#   version = "1.0.1"

#   enabled           = true
#   argo_enabled      = false
#   argo_helm_enabled = false

#   helm_release_name = "metrics-server"
#   namespace         = "kube-system"

#   values = yamlencode({
#     "podLabels" : {
#       "app" : "metrics-server"
#     }
#   })

#   helm_timeout = 240
#   helm_wait    = true
# }

################################################################################
# EKS Blueprints Addons
################################################################################

resource "kubernetes_namespace_v1" "istio_system" {
  metadata {
    name = "istio-system"
  }
  depends_on = [
    module.eks
  ]
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # This is required to expose Istio Ingress Gateway
  enable_aws_load_balancer_controller = true

  helm_releases = {
    istio-base = {
      chart         = "base"
      chart_version = local.istio_chart_version
      repository    = local.istio_chart_url
      name          = "istio-base"
      namespace     = kubernetes_namespace_v1.istio_system.metadata[0].name
      wait     = true     
      timeout  = 600 
    }

    istiod = {
      chart         = "istiod"
      chart_version = local.istio_chart_version
      repository    = local.istio_chart_url
      name          = "istiod"
      namespace     = kubernetes_namespace_v1.istio_system.metadata[0].name

      set = [
        {
          name  = "meshConfig.accessLogFile"
          value = "/dev/stdout"
        }
      ]
    }

    istio-ingress = {
      chart            = "gateway"
      chart_version    = local.istio_chart_version
      repository       = local.istio_chart_url
      name             = "istio-ingress"
      namespace        = "istio-ingress" # per https://github.com/istio/istio/blob/master/manifests/charts/gateways/istio-ingress/values.yaml#L2
      create_namespace = true

      values = [
        yamlencode(
          {
            labels = {
              istio = "ingressgateway"
            }
            service = {
              annotations = {
                "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
                "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
                "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
                "service.beta.kubernetes.io/aws-load-balancer-attributes"      = "load_balancing.cross_zone.enabled=true"
              }
            }
          }
        )
      ]
    }
  }

  tags = local.tags
}

# service account and rbac creation 

resource "kubernetes_service_account" "kubeconfig_sa" {
  metadata {
    name      = "kubeconfig-sa"
    namespace = "kube-system"
  }
  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubernetes_cluster_role_binding" "view_binding" {
  metadata {
    name = "add-on-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.kubeconfig_sa.metadata[0].name
    namespace = kubernetes_service_account.kubeconfig_sa.metadata[0].namespace
  }
  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubernetes_secret" "kubeconfig_sa_token" {
  metadata {
    name      = "kubeconfig-sa-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = "kubeconfig-sa"
    }
  }

  type = "kubernetes.io/service-account-token"
  depends_on = [
    module.eks_blueprints_addons
  ]
}

# create faulty gateway
data "kubectl_path_documents" "faulty_gateway_manifest" {
  pattern = "faulty-gateway.yaml"
}

resource "kubectl_manifest" "faulty_gateway" {
  for_each  = toset(data.kubectl_path_documents.faulty_gateway_manifest.documents)
  yaml_body = each.value

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# resource "kubectl_manifest" "faulty_gateway" {
#   yaml_body = <<YAML
# apiVersion: networking.istio.io/v1beta1
# kind: Gateway
# metadata:
#   name: faulty-gateway
#   namespace: istio-system
# spec:
#   selector:
#     istio: ingressgateway
#   servers:
#   - port:
#       number: 80
#       name: http
#       protocol: HTTP
#     hosts:
#     - "invalid-host.local"
# YAML

#   depends_on = [
#     module.eks_blueprints_addons
#   ]
# }

# bookinfo application and fault injection
data "kubectl_path_documents" "bookinfo_manifest" {
  pattern = "./bookinfo/*.yaml"
}

resource "kubectl_manifest" "bookinfo_app" {
  for_each  = toset(data.kubectl_path_documents.bookinfo_manifest.documents)
  yaml_body = each.value

  depends_on = [module.eks_blueprints_addons]

}

# null resource to execute some requests to generate errors

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
