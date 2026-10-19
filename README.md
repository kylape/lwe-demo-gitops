# LWE GitOps demo

The `qwen-single-gpu` profile deploys Qwen/Qwen3-0.6B with the upstream
`vllm/vllm-openai:v0.11.0` image, pinned by digest. It requests exactly one
NVIDIA GPU and exposes the OpenAI-compatible API on a ClusterIP Service at
`qwen-single-gpu.demo-app.svc:8000`, with served model name `qwen`.

The Deployment is currently paused at zero replicas after live testing exposed
a vCluster syncer bug: guest Pod reconciliation removes host-added Kueue
scheduling gates, causing repeated Pod termination and replacement. Keep it
paused until the syncer preserves host-owned gates, then change `replicas` back
to `1` in Git and let Argo CD synchronize the update.

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
