# LWE GitOps demo

The `qwen-single-gpu` profile deploys Qwen/Qwen3-0.6B with the upstream
`vllm/vllm-openai:v0.11.0` image, pinned by digest. It requests exactly one
NVIDIA GPU and exposes the OpenAI-compatible API on a ClusterIP Service at
`qwen-single-gpu.demo-app.svc:8000`, with served model name `qwen`.

The Deployment runs one replica. The 2026-10-19 rehearsal verified Kueue quota
reservation and admission, a stable Ready Pod, Argo CD Synced / Healthy, and
HTTP 200 inference. vCluster must include the scheduling-gate preservation fix
from source revision `37b50bb1c76e7b2bbf53faa2170eefaa03140589`; older syncers
can remove host admission gates and cause repeated Pod replacement. The demo
uses `quay.io/klape/vcluster:kueue-gates-37b50bb1c`, pinned to digest
`sha256:65be5418b44645e1abaebad77e90792d9e5b42ce552db6e514b8160488db67ef`.

The small, public model needs no Hugging Face token. Model files use an
ephemeral cache and are downloaded again when the Pod is replaced. The
Deployment uses `Recreate` to avoid requesting a second GPU during upgrades.
The Pod carries the `default` Kueue label; admission enforcement depends on
the host cluster's Kueue configuration and namespace selection.
CPU, memory, and GPU are the only explicitly requested resources because the
demo ClusterQueue does not cover ephemeral storage; cache volumes remain bounded.

## Manual activation

The demo Argo CD instance and scoped `lwe-demo` AppProject must already exist.
The project must allow this repository, the selected vCluster API endpoint,
the `demo-app` namespace, and Namespace, Deployment, and Service resources.

Apply the control-plane manifest to the **host** cluster:

```bash
kubectl apply --context coreweave-kermit -f argocd/qwen-single-gpu-applicationset.yaml
kubectl label llmworkloadenvironment scooby -n landing-scooby \
  --context coreweave-kermit \
  llm.redhat.com/application-profile=qwen-single-gpu
```

The LWE operator creates the Argo CD cluster Secret. Its profile label makes
the ApplicationSet generate an Application, which synchronizes only
`apps/qwen-single-gpu` into `demo-app` in the guest cluster. The `argocd/`
directory is applied manually to the host and is outside that source path.

## Verify inference

Use the guest kubeconfig for the following commands:

```bash
kubectl rollout status deployment/qwen-single-gpu -n demo-app --timeout=20m
kubectl port-forward service/qwen-single-gpu -n demo-app 18000:8000
```

In another terminal:

```bash
curl http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":64,"chat_template_kwargs":{"enable_thinking":false}}'
```

Removing the profile label removes registration and the generated Application,
but leaves the model running unmanaged, consuming its GPU. Automatic pruning
is disabled, and `preserveResourcesOnDeletion` is enabled. To stop the model,
delete its Deployment and Service explicitly in the guest cluster, or scale
the Deployment to zero after removing the label.

## RHOAI developer environment

`apps/rhoai-platform` is the shared RHOAI 3.6 nightly profile. It installs the
RHOAI operator and DataScienceCluster, cert-manager, the OpenShift
`GatewayClass`, RHCL/Kuadrant with Authorino TLS, PostgreSQL, and the
`selfsigned-issuer`. PostgreSQL provisions both `keycloak` and `batch`
databases. These common services support RHOAI inference, MaaS, and Batch
Gateway development.

`apps/batch-gateway` is an optional workload profile layered on that platform.
It adds Redis, MinIO, the simulator model, gateways, policies, and the
`LLMBatchGateway` instance. Secret values are generated in the cluster and are
not stored in Git.

### 1. Create a HyperShift LWE

`environments/inference-e2e/llmworkloadenvironment.yaml` is a 48-hour example
with the RHOAI and RHAII digest mirrors. Apply it to a host-cluster namespace
that has the `rhai-pull-secret` and `inference-workspace-test` ClusterQueue, and
change the LWE name if it is already in use:

```bash
export HOST_KUBECONFIG=/path/to/host-lwe-kubeconfig
export LWE_NAMESPACE=<your-namespace>

kubectl apply --kubeconfig "$HOST_KUBECONFIG" \
  -n "$LWE_NAMESPACE" \
  -f environments/inference-e2e/llmworkloadenvironment.yaml
```

Wait for the LWE to become Ready and save its guest kubeconfig to a private
file. The current mirror list covers RHOAI/RHAII images. For a disconnected
run, mirror the `llm-d-inference-sim` image and add its registry mapping too.

### 2. Apply the RHOAI platform

The guest uses its own OpenShift GitOps installation. Set `GUEST_KUBECONFIG`
to the kubeconfig produced for the LWE, install OpenShift GitOps, then grant its
application controller the permissions required by the platform resources:

```bash
export GUEST_KUBECONFIG=/path/to/guest-kubeconfig

kubectl apply --kubeconfig "$GUEST_KUBECONFIG" -f argocd/guest-operator.yaml
# Wait for the openshift-gitops namespace and default Argo CD instance.
kubectl apply --kubeconfig "$GUEST_KUBECONFIG" \
  -f argocd/guest-application-controller-rbac.yaml
kubectl apply --kubeconfig "$GUEST_KUBECONFIG" \
  -f argocd/guest-rhoai-platform-application.yaml
```

Wait for the `rhoai-platform` Application to become Synced and Healthy and for
`default-dsc` to report Ready. The inference gateway must accept the
`inference-gateway-access=true` namespace label used by inference-e2e.

### 3. Run inference-e2e

From a local clone of
[`inference-e2e`](https://github.com/opendatahub-io/llm-d-e2e), install the
project dependencies and run the mock smoke case. Mock mode uses
`llm-d-inference-sim`, so this path does not require a GPU:

```bash
uv sync
uv run llm-d-e2e --setup 3.6-ea2 \
  -t single-gpu-smoke --mock \
  --kubeconfig "$GUEST_KUBECONFIG" -v
```

Use the same 3.6 manifest ref when adding a testcase or manifest; use a fork
with `--manifest-repo` while developing changes. After the smoke case passes,
run the broader profile in `configs/profiles/3.6.yaml` with the GPU capacity and
model access its testcases need.

### Optional Batch Gateway profile

After the platform is ready, apply `argocd/guest-application.yaml` to sync
`apps/batch-gateway`. The batch chart's `gateway.externalHostname` and
`gateway.certificateSecret` values must match the guest cluster's apps domain
and ingress certificate before sync. The LWE expires 48 hours after creation.
