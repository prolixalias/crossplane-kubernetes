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

# Creates a kind cluster, installs Crossplane, providers, and packages, waits until they are healthy, and runs tests.
cluster-create: package-generate _cluster-create-kind
  just package-apply
  sleep 60
  kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl wait --for=condition=healthy function.pkg.crossplane.io --all --timeout={{timeout}}
  kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Executes `cluster-create` and sets it up to use Google Cloud.
cluster-create-google: cluster-create
  rm .env
  gcloud auth login
  export USE_GKE_GCLOUD_AUTH_PLUGIN=True
  echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> .env
  export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
  echo "export PROJECT_ID=$PROJECT_ID" >> .env
  gcloud projects create $PROJECT_ID
  echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID in a browser and *ENABLE* the API." | gum format
  gum input --placeholder "Press the enter key to continue."
  SA_NAME=devops-toolkit
  SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  gcloud iam service-accounts create $SA_NAME --project $PROJECT_ID
  gcloud projects add-iam-policy-binding --role roles/admin $PROJECT_ID --member serviceAccount:$SA
  gcloud iam service-accounts keys create gcp-creds.json --project $PROJECT_ID --iam-account $SA
  kubectl --namespace crossplane-system create secret generic gcp-creds --from-file creds=./gcp-creds.json
  yq --inplace ".spec.projectID = \"$PROJECT_ID\"" providers/provider-config-google.yaml
  kubectl apply --filename providers/provider-config-google.yaml
  echo "## Execute `source .env` to set up the environment variables."

# Destroys the cluster
cluster-destroy:
  KIND_EXPERIMENTAL_PROVIDER=nerdctl kind delete cluster

# Removes Google Cloud project and executes `cluster-destroy`.
cluster-destroy-google:
  gcloud projects delete --quiet
  just cluster-destroy

# Creates a kind cluster
_cluster-create-kind:
  -KIND_EXPERIMENTAL_PROVIDER=nerdctl kind create cluster --config kind.yaml
  helm upgrade --install crossplane crossplane --repo https://charts.crossplane.io/stable --version 1.17.1 --namespace crossplane-system --create-namespace --wait
  -eval $(op signin) && op document get {{credentials_aws}} --vault automation | kubectl --namespace crossplane-system create secret generic aws-secret --from-file=creds=/dev/stdin
  for provider in `ls -1 providers | grep -v config`; do kubectl apply --filename providers/$provider; done
  kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout=1800s
  for providerconfig in `ls -1 providers | grep provider-config`; do kubectl apply --filename providers/$providerconfig; done
  for tenant in `ls -1 deploy/tenants`; do kubectl create namespace ${tenant} || true; done
  kubectl apply --filename providers/provider-config-aws.yaml
  helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --namespace argocd --create-namespace --values deploy/argocd/values.yaml --wait --timeout 10m
  kubectl apply -f deploy/argocd/applications.yaml
