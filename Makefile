# For simplicity, all operations have to be executed inside the target OpenShift project.
# So either run: `oc new-project <project name>` or go to the project with `oc project <project name>`.
PROJECT=$(shell oc project -q)
IMAGE ?= quay.io/akaris/centos:fluentd

.PHONY: build-container-image
build-container-image: ## Build container image.
	podman build -t $(IMAGE) .

.PHONY: push-container-image ## Push container image.
	podman push $(IMAGE)


.PHONY: configmap
configmap: ## Create the configmap.
	oc delete configmap fluentd-config 2>/dev/null || true
	tmp_file=$$(mktemp)
	cp fluent.conf $$tmp_file
	sed -i 's/_PROJECT_/$(PROJECT)/g' $$tmp_file
	oc create configmap fluentd-config --from-file=fluent.conf=$$tmp_file

.PHONY: serviceaccount
serviceaccount: ## Create the service account.
	oc delete serviceaccount fluentd-serviceaccount >/dev/null || true
	oc create serviceaccount fluentd-serviceaccount

# According to https://loki-operator.dev/docs/forwarding_logs_to_gateway.md/#forwarding-clients
# Also see: https://github.com/search?q=repo%3Agrafana%2Floki%20modetype&type=code
.PHONY: clusterrole
clusterrole: ## Create the cluster role.
	oc delete -f fluentd-custom-logs-writer.yaml 2>/dev/null || true
	oc apply -f fluentd-custom-logs-writer.yaml

.PHONY: clusterrolebinding
clusterrolebinding: ## Create the cluster role binding.
	oc delete clusterrolebinding fluentd-custom-logs-writer 2>/dev/null || true
	oc create clusterrolebinding fluentd-custom-logs-writer --clusterrole=fluentd-custom-logs-writer --serviceaccount=$(PROJECT):fluentd-serviceaccount

.PHONY: deployment
deployment: ## Create the deployment.
	oc delete -f fluentd-test.yaml || true
	tmp_file=$$(mktemp)
	cp fluentd-test.yaml $$tmp_file
	sed -i 's/_IMAGE_/$(IMAGE)/g' $$tmp_file
	oc apply -f $$tmp_file

.PHONY: deploy
deploy: configmap serviceaccount clusterrole clusterrolebinding deployment ## (Re-)Deploy all resources. Requires image $(IMAGE) (default:quay.io/akaris/centos:fluentd).

## From https://dwmkerr.com/makefile-help-command/.
.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done
