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

## Batch Gateway profile

`apps/batch-gateway` contains the RHOAI 3.6 Batch Gateway installation and the
small supporting stack used by Shepard: cert-manager, RHCL/Kuadrant, PostgreSQL,
Redis, MinIO, and the CPU-friendly llm-d simulator. It enables the RHOAI
`aigateway.batchGateway` and KServe components through the DataScienceCluster.
The secret bootstrap Job generates Redis, PostgreSQL, and MinIO credentials in
the cluster; credential values are not stored in Git.

The profile is intended for a clean, connected HyperShift guest. The simulator
image is digest-pinned on GHCR, while RHOAI images use the mirrors configured
on the LWE. A fully disconnected guest also needs GHCR simulator mirroring.
The chart's `gateway.externalHostname` and `gateway.certificateSecret` values
must match the guest cluster's apps domain and ingress certificate before sync.

Create the profile's AppProject and ApplicationSet on the LWE management
cluster, then create the HyperShift LWE from the tracked manifest:

```bash
kubectl apply --kubeconfig ~/workspace/ai-grid-test/lwe-kubeconfig \
  -f argocd/batch-gateway-project.yaml
kubectl apply --kubeconfig ~/workspace/ai-grid-test/lwe-kubeconfig \
  -f argocd/batch-gateway-applicationset.yaml
kubectl apply --kubeconfig ~/workspace/ai-grid-test/lwe-kubeconfig \
  -f environments/batch-gateway/llmworkloadenvironment.yaml
```

The LWE's `llm.redhat.com/application-profile=batch-gateway` label registers
the ready guest with Argo CD and selects the ApplicationSet. The LWE expires
after 24 hours. The ApplicationSet's source revision is the deployment branch;
change it to `main` after the branch is merged.
