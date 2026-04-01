# 1. Create a namespace
oc create namespace my-custom-metrics
oc project my-custom-metrics

# 2. Create the ServiceAccount
oc create sa custom-grafana-sa

# 3. Grant the SA permission to view cluster metrics
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z custom-grafana-sa
