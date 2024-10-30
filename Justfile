timeout := "600s"
credentials_aws := "aws_credentials_cynerge"

# List tasks.
default:
  just --list

# Generates package files.
package-generate:
  kcl run kcl/crossplane.k > package/crossplane.yaml
  kcl run kcl/definition.k > package/definition.yaml
  kcl run kcl/compositions.k > package/compositions.yaml
  # kcl run kcl/backstage-template.k > backstage/crossplane-kubernetes.yaml

# Applies Compositions and Composite Resource Definition.
package-apply:
  kubectl apply --filename package/definition.yaml && sleep 1
  kubectl apply --filename package/compositions.yaml
  kubectl apply --filename package/sql.yaml

# Builds and pushes the package.
#package-publish: package-generate
#  up login --token $UP_TOKEN
#  up xpkg build --package-root package --name kubernetes.xpkg
#  up xpkg push --package package/kubernetes.xpkg xpkg.upbound.io/$UP_ACCOUNT/dot-kubernetes:$VERSION
#  rm package/kubernetes.xpkg
#  yq --inplace ".spec.package = \"xpkg.upbound.io/devops-toolkit/dot-kubernetes:$VERSION\"" config.yaml

# Combines `package-generate` and `package-apply`.
package-generate-apply: package-generate package-apply

# Create a cluster, runs tests, and destroys the cluster.
test: cluster-create package-generate-apply
  chainsaw test
  just cluster-destroy

# Runs tests once assuming that the cluster is already created and everything is installed.
test-once: package-generate-apply
  chainsaw test

# Runs tests in the watch mode assuming that the cluster is already created and everything is installed.
test-watch:
  watchexec -w kcl -w tests "just test-once"

# Shortcut to cluster-create-local
cluster-create: cluster-create-local

# Create kind cluster, install Crossplane/providers/packages, wait until healthy.
cluster-create-local: package-generate _cluster-create-kind
  -KIND_EXPERIMENTAL_PROVIDER=nerdctl kind create cluster --config kind.yaml
  just package-apply
  sleep 60
  kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl wait --for=condition=healthy function.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Uses existing kind cluster in worker, install Crossplane/providers/packages, wait until healthy.
cluster-create-action: package-generate _cluster-create-kind
  just package-apply
  sleep 60
  kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl wait --for=condition=healthy function.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Destroys local cluster
cluster-destroy:
  KIND_EXPERIMENTAL_PROVIDER=nerdctl kind delete cluster

# Create kind cluster
_cluster-create-kind:
  helm upgrade --install crossplane crossplane --repo https://charts.crossplane.io/stable --version 1.17.1 --namespace crossplane-system --create-namespace --wait
  -eval $(op signin) && op document get {{credentials_aws}} --vault automation | kubectl --namespace crossplane-system create secret generic aws-secret --from-file=creds=/dev/stdin
  for provider in `ls -1 providers | grep -v config`; do kubectl apply --filename providers/$provider; done
  kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout=1800s
  for providerconfig in `ls -1 providers | grep provider-config`; do kubectl apply --filename providers/$providerconfig; done
  for tenant in `ls -1 deploy/tenants`; do kubectl create namespace ${tenant} || true; done
  kubectl apply --filename providers/provider-config-aws.yaml
  helm upgrade --install opencost opencost --repo https://opencost.github.io/opencost-helm-chart --namespace opencost --create-namespace --values deploy/opencost/values.yaml --wait --timeout 5m
  kubectl get secret -n opencost cloud-costs || kubectl create secret --namespace opencost generic cloud-costs --from-file=deploy/opencost/cloud-integration.json
  helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --namespace argocd --create-namespace --values deploy/argocd/values.yaml --wait --timeout 10m
  kubectl apply -f deploy/argocd/applications.yaml
