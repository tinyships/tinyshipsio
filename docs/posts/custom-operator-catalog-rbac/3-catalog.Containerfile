# Tag must match your cluster's OCP minor version (see: oc get clusterversion)
FROM registry.redhat.io/openshift4/ose-operator-registry-rhel9:v4.22

COPY custom-catalog /configs

RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

EXPOSE 50051

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]
