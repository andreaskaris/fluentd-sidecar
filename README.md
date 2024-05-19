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

And the ClusterLogging stack was configured with the following configuration and will visualize logs in the OCP
console:
```
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance
  namespace: openshift-logging
spec:
  collection:
    type: vector
  curation:
    curator:
      schedule: 30 * * * *
    type: curator
  logStore:
    type: lokistack
    lokistack:
      name: logging-loki
  managementState: Managed
  visualization:
    type: ocp-console
```

> **Note:** This configuration is incomplete, see the OpenShift documentation for full configuration examples.

> **Note:** The OCP Console logging plugin must be enabled. See the OpenShift documentation.

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
to ClusterRole `fluentd-custom-logs-writer`.
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

## Verification

You should see a pod with 2 containers:
```
# oc get pods
NAME                            READY   STATUS    RESTARTS   AGE
fluentd-test-6d889f8d64-bbhhq   2/2     Running   0          92s
```

With a correct fluentd configuration. In this case, the pod was deployed in namespace `test-forward`, therefore you
should see record `_kubernetes_namespace_name test-forward`.

```
# oc rsh -c fluentd-sidecar fluentd-test-6d889f8d64-bbhhq
sh-5.1$ cat /etc/fluent/fluent.conf 
####
## Source section
####

# Tail logs from /fluent-logs/log.txt. Parse each line as JSON. Tag the logs as custom_logs.* so that we can target
# them in the following sections.
<source>
  @type tail
  @id custom_logs
  <parse>
    @type json
  </parse>
  path /fluent-logs/log.txt
  tag custom_logs.*
</source>

####
## Filter section
####
# Add custom records to the ingested data. The OpenShift Loki stack expects that we set certain labels. In order to
# filter, we must set valid values. For this demo, the easiest is to set the namespace name to the actual namespace
# name and then filter for that. See the Makefile for how we replace test-forward with the actual value of the namespace.
<filter custom_logs.**>
  @type record_modifier
  <record>
    _log_type application
    _kubernetes_container_name custom_log_container
    _kubernetes_host custom_log_host
    _kubernetes_namespace_name test-forward
    _kubernetes_pod_name custom_log_pod
  </record>
</filter>

####
## Output section
####

## For debugging, dump to console:
# <match custom_logs.**>
#   @type stdout
#   @id output_stdout
# </match>

## Match custom logs and send them to Loki. In order to do so, we use the ServiceAccount token and CA cert.
# Loki expects certain labels to be set, we do that in the labels section.
# See https://grafana.com/docs/loki/latest/send-data/fluentd/#adding-labels for info about the Loki plugin labels section.
# The <buffer> settings are copied from the OpenShift collector pods and slightly modified. See
# https://grafana.com/docs/loki/latest/send-data/fluentd/#usage for options.
# The fluentd configuration is documented in https://loki-operator.dev/docs/forwarding_logs_to_gateway.md/#fluentd
<match custom_logs.**>                                                  
  @type loki                                
  @id default_loki_apps
  line_format json
  url https://logging-loki-gateway-http.openshift-logging.svc:8080/api/logs/v1/application                                                                 
  min_version TLS1_2
  # fluents complains about this in my tests.
  # ciphers TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-
S256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384  
  ca_cert /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
  bearer_token_file /var/run/secrets/kubernetes.io/serviceaccount/token
  # extract_kubernetes_labels true  # makes no difference in my tests
  <label>                                
    kubernetes_container_name _kubernetes_container_name
    kubernetes_host _kubernetes_host
    kubernetes_namespace_name _kubernetes_namespace_name
    kubernetes_pod_name _kubernetes_pod_name                       
    log_type _log_type                                                      
  </label>                                                                 
  <buffer>                                
    @type file                                                             
    path '/tmp/default_loki_apps'                  
    flush_mode interval                
    flush_interval 1s
    flush_thread_count 2
    retry_type exponential_backoff
    retry_wait 1s
    retry_max_interval 60s
    retry_timeout 60m
    queued_chunks_limit_size "#{ENV['BUFFER_QUEUE_LIMIT'] || '32'}"
    total_limit_size "#{ENV['TOTAL_LIMIT_SIZE_PER_BUFFER'] || '8589934592'}"
    chunk_limit_size "#{ENV['BUFFER_SIZE_LIMIT'] || '8m'}" 
    overflow_action block
    disable_chunk_backup true
  </buffer>
</match>
```

The logs of `fluentd-sidecar` should show no errors:
```
# oc logs -c fluentd-sidecar fluentd-test-6d889f8d64-bbhhq --tail=10
    queued_chunks_limit_size 32
    total_limit_size 8589934592
    chunk_limit_size 8m
    overflow_action block
    disable_chunk_backup true
  </buffer>
</match> is not used.
2024-05-19 17:40:31 +0000 [info]: #0 starting fluentd worker pid=11 ppid=1 worker=0
2024-05-19 17:40:31 +0000 [info]: #0 [custom_logs] following tail of /fluent-logs/log.txt
2024-05-19 17:40:31 +0000 [info]: #0 fluentd worker is now running worker=0
```

In the OpenShift console, you should be able to filter by namespace (`test-forward`) in this case. And you should
see the supported stdout/stderr logs as well as the custom, unsupported fluentd log:

![image](https://github.com/andreaskaris/fluentd-sidecar/assets/3291433/343f171d-075f-4d2e-9a77-e3fba0c44968)
