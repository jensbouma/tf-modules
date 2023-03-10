resource "random_id" "argo_secret" {
  byte_length = 35
}

resource "cloudflare_argo_tunnel" "tunnel" {
  account_id = var.cloudflare_account_id
  name       = var.cluster
  secret     = random_id.argo_secret.b64_std
}

resource "cloudflare_record" "tunnel" {
  zone_id = var.cloudflare_zone.id
  name    = var.cluster
  value   = "${cloudflare_argo_tunnel.tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

resource "kubernetes_namespace" "cloudflared" {
  depends_on = [time_sleep.k3s_installed]
  metadata {
    name        = "cloudflared"
    annotations = {}
    labels      = {}
  }
}

resource "kubernetes_secret" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }

  data = {
    "credentials.json" = jsonencode({
      "AccountTag"   = var.cloudflare_account_id,
      "TunnelID"     = cloudflare_argo_tunnel.tunnel.id,
      "TunnelName"   = cloudflare_argo_tunnel.tunnel.name,
      "TunnelSecret" = random_id.argo_secret.b64_std
    })
  }

  type = "kubernetes.io/secret"
}

resource "kubernetes_deployment" "cloudflared" {
  depends_on = [
    kubernetes_secret.cloudflared
  ]
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "cloudflared"
      }
    }

    template {
      metadata {
        labels = {
          app = "cloudflared"
        }
      }

      spec {
        volume {
          name = "creds"
          secret {
            secret_name = "cloudflared"
          }
        }

        volume {
          name = "config"
          config_map {
            name = "cloudflared"
          }
        }

        container {
          image = "cloudflare/cloudflared:latest"
          name  = "cloudflared"
          args  = ["tunnel", "--config", "/etc/cloudflared/config/config.yaml", "run"]

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "125m"
              memory = "50Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }

            initial_delay_seconds = 1
            period_seconds        = 10
            failure_threshold     = 1
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/cloudflared/config"
            read_only  = true
          }

          volume_mount {
            name       = "creds"
            mount_path = "/etc/cloudflared/creds"
            read_only  = true
          }
        }
      }
    }
  }
}


resource "kubernetes_config_map" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }

  data = {
    "config.yaml" = <<EOT
# Name of the tunnel you want to run
tunnel: ${cloudflare_argo_tunnel.tunnel.id}
credentials-file: /etc/cloudflared/creds/credentials.json
# Serves the metrics server under /metrics and the readiness server under /ready
metrics: 0.0.0.0:2000
# Autoupdates applied in a k8s pod will be lost when the pod is removed or restarted, so
# autoupdate doesn't make sense in Kubernetes. However, outside of Kubernetes, we strongly
# recommend using autoupdate.
no-autoupdate: true
# The `ingress` block tells cloudflared which local service to route incoming
# requests to. For more about ingress rules, see
# https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/configuration/ingress
#

ingress:
# This rule sends all requests to nginx ingress controller, which proxies them further to correct services
- service: http://${helm_release.nginx_ingress.name}.${kubernetes_namespace.nginx_ingress.metadata[0].name}.svc.cluster.local.:80
EOT
  }
}