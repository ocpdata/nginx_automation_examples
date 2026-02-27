resource "kubernetes_namespace_v1" "nginx-ingress" {
  metadata {
    name = "nginx-ingress"
  }
}
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}