## Usage

1. Create the namespace and apply the ConfigMap/DaemonSet (does not create secret):

```bash
kubectl apply -f k8s/nginx-agent/namespace.yaml
kubectl apply -f k8s/nginx-agent/configmap.yaml
kubectl apply -f k8s/nginx-agent/daemonset.yaml
```

2. Create the dataplane secret (do NOT commit keys to git). Replace <TU_DATA_PLANE_KEY> with the real key:

```bash
kubectl create secret generic nginx-agent-dataplane-key \
  --from-literal=dataplane.key='<TU_DATA_PLANE_KEY>' \
  -n nginx-agent
```

3. If your cluster needs image pull credentials, create an ImagePullSecret named `regcred` or adjust the DaemonSet `imagePullSecrets`.

4. Verify pods:

```bash
kubectl get pods -n nginx-agent -o wide
kubectl logs -n nginx-agent -l app=nginx-agent --tail=200
```

## Terraform / GitHub Actions integration

- Prefer using `kubernetes_namespace`, `kubernetes_secret`, `kubernetes_config_map`, and `kubernetes_daemonset` resources in Terraform to manage these objects.
- Do NOT store secrets in git; use GitHub Actions secrets or Terraform variables tied to a secure store.

## Notes

- Adjust `hostPath` paths in `daemonset.yaml` to match how NIC/WAF expose configs/logs on nodes.
- The DaemonSet uses image `private-registry.nginx.com/nginx-plus/agent:nginx-plus-r31-alpine-3.19` (nginx-agent v2.39).
