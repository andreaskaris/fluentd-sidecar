FROM quay.io/centos/centos:stream9
RUN yum install sudo -y
RUN curl -fsSL https://toolbelt.treasuredata.com/sh/install-redhat-fluent-package5-lts.sh | sh
RUN fluent-gem install fluent-plugin-grafana-loki
