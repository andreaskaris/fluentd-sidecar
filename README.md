# Forwarding custom application logs via fluentd sidecar into the OpenShift LokiStack

This repository contains instructions and an example for how one can forward custom application logs via a fluentd
sidecar into OpenShift's LokiStack. Such a setup is feasible, but it is not supported in OpenShift. This example shall
serve for demonstration purposes only. It is by no means meant to be complete, secure or reproducible.

## How this works

The only supported way in OpenShift to store application logs inside the OpenShift Logging Operator's stack is by
printing logs to stdout / stderr. The container logs will be picked up by vector or fluentd and are then forwarded to
LokiStack. However, it is technically feasible (albeit not supported) to run a fluentd sidecar for a given pod and
have the fluentd sidecar forward logs into LokiStack, as well.

For this test setup, the following LokiStack was deployed:
```
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki 
  namespace: openshift-logging
spec:
  size: 1x.small 
  storage:
    schemas:
      - effectiveDate: '2023-10-15'
        version: v13
    secret:
      name: logging-loki-odf
      type: s3
    tls:
      caName: openshift-service-ca.crt
  storageClassName: ocs-external-storagecluster-ceph-rbd
  tenants:
    mode: openshift-logging
  limits:
    global: 
      retention: 
        days: 7 
```

We will deploy a test application container with a main container `fluentd-main` and a sidecar container `fluentd-sidecar.`
Container `fluentd-main` writes logs to stdout and to stderr. These logs will be picked up by the supported OpenShift
application logging. They will be forwarded to Loki stack and can be inspected from the OpenShift console.
The container writes a 3rd log to `/fluent-logs/log.txt`. Location `/fluent-logs` is an `emptydir` mount that's shared
between the main and the sidecar containers.
Each log line is in valid JSON so that the fluentd JSON parser of fluentd running inside `fluentd-sidecar` can ingest
it properly.

Container `fluentd-sidecar` runs a custom (unsupported) fluentd daemon. The fluentd daemon reads its configuration from
`/etc/fluent/fluent.conf`. That configuration is provided by ConfigMap `fluentd-config` and the configuration instructs
fluentd to read JSON formatted lines from `/fluent-logs/log.txt`, transform them, and then forward them to Loki stack.

The fluentd inside the `fluentd-sidecar` will use the Loki plugin to forward into Loki.
See https://grafana.com/docs/loki/latest/send-data/fluentd/#usage for further details and options.

The supported and documented setup for LokiStack uses `.spec.tenants.mode: openshift-logging`. Therefore,
fluentd inside `fluentd-sidecar` will have to authenticate with OpenShift and to be authorized by the OpenShift LokiStack.
In order to do so, we run the fluentd test pod with ServiceAccount `fluentd-serviceaccount`. This ServiceAccount is bound
to ClusterRole `fluentd-custom-logs-writer``.
ClusterRole `fluentd-custom-logs-writer` has `get`,`create` verbs for loki `logs` resources `application`, `infrastructure`,
`audit`. See https://loki-operator.dev/docs/forwarding_logs_to_gateway.md/#openshift-logging for further details.
The configuration that instructs fluentd to use the `ca_cert` and `bearer_token_file`  is documented in
https://loki-operator.dev/docs/forwarding_logs_to_gateway.md/#fluentd

The OpenShift Loki stack expects that we set certain labels for each forwarded log. Therefore, we add custom records
to the ingested data.  In order to filter inside OpenShift console, we must set valid values. For this demo, the easiest
is to set the namespace name to the actual namespace name that the pod is deployed in and then filter for that to
retrieve the custom logs.

## Deployment

For simplicity, all operations have to be executed inside the target OpenShift project.
So either run: `oc new-project <project name>` or go to the project with `oc project <project name>`.

Build and push the container image (the container image defaults to quay.io/akaris/centos:fluentd):

```
make build-container-image IMAGE=<registry/image:label>
make push-container-image IMAGE=<registry/image:label>
```

Create a new project:

```
oc new-project test-forward
```

Deploy everything:

```
make deploy IMAGE=<registry/image:label>
```
