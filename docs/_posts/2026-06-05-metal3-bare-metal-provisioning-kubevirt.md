---
layout: post
title: "Simulating Bare Metal Provisioning on OpenShift with Metal3 and KubeVirt"
date: 2026-06-05
---

Metal3 and Ironic are the bare metal provisioning engine inside OpenShift. They handle everything from powering on a physical server to writing an operating system to its disk — all driven by a Kubernetes custom resource called BareMetalHost. The problem is that most engineers never get to interact with this stack because they do not have a rack of physical servers with Redfish-capable management controllers sitting under their desk. The kubevirt/redfish-controller changes that. It exposes a standards-compliant Redfish API for KubeVirt virtual machines, which means a VM running in your cluster can look exactly like a physical server to Ironic. This is a quick why and how-to for running the full Metal3 provisioning lifecycle — registration, hardware inspection, and OS installation — on any OpenShift cluster that has OpenShift Virtualization installed.

## Why This Matters

Bare metal provisioning through Kubernetes is one of those capabilities that sounds straightforward until you try to learn it. The BareMetalHost resource is well documented. The state machine is clearly defined: a host registers, gets inspected, becomes available, and then gets provisioned with an operating system. But reading about state transitions is not the same as watching them happen and understanding what is going on at each stage.

The barrier has always been hardware. Metal3 talks to servers through their Baseboard Management Controller — the out-of-band management interface that lets you power on a machine, attach a virtual CD, and boot from it without touching the server physically. On a Dell server that is iDRAC. On an HPE server it is iLO. The protocol they all speak is Redfish, a REST API that replaced the older IPMI standard. Without a BMC to talk to, Metal3 has nothing to manage.

The redfish-controller from the KubeVirt project solves this by translating Redfish API calls into KubeVirt VM operations. When Ironic sends a Redfish command to power on a system, the controller starts the VM. When Ironic attaches a virtual media ISO for inspection, the controller mounts it to the VM. The VM does not know it is simulating bare metal — it just sees a disk, a network interface, and whatever boot media Ironic provides. And because the Redfish API is the same standard that real hardware implements, the BareMetalHost YAML you write for this simulation would work against a physical server with a real BMC. The only field that changes is the BMC address.

This makes it possible to build confidence with the entire Metal3 workflow — validate image URLs, test cloud-init configurations, observe state transitions in real time — before touching production hardware or spending budget on a bare metal lab.

---

## The Steps

1. Create a namespace and a KubeVirt VirtualMachine to act as the simulated bare metal host
2. Deploy the redfish-controller via Helm to expose a Redfish BMC API for the VM
3. Enable the Provisioning CR to activate Ironic on a non-baremetal cluster
4. Register the VM as a BareMetalHost and watch it pass through inspection
5. Provision Fedora Cloud Base to the host and verify it boots

---

## How To Do It

This walkthrough assumes OpenShift Virtualization (KubeVirt) is already installed and operational on your cluster. The cluster does not need to be running on bare metal — this works on any platform (AWS, vSphere, bare metal, or single-node) as long as OpenShift Virtualization is available. You will need the `oc` and `helm` CLIs.

### Step 1: Create the Namespace and Virtual Machine

Start by creating a dedicated namespace and a KubeVirt VirtualMachine that will act as the simulated bare metal host. The VM does not need a pre-installed operating system — Ironic will provision one through the Redfish virtual media interface later. What it needs is a blank disk to write to, a stable MAC address, and UEFI firmware.

📄 [1-namespace-vm.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/1-namespace-vm.yaml)

```bash
oc apply -f 1-namespace-vm.yaml
```

The file contains two resources. The **Namespace** creates `simulated-bmh` where the VM and the redfish-controller will run. The **VirtualMachine** defines the simulated host with several fields worth understanding:

```yaml
spec:
  runStrategy: Halted
```

The `Halted` run strategy means the VM starts in a stopped state. This is intentional — Ironic will power it on through the Redfish API during registration and inspection. If the VM were already running, Ironic would not be able to control its power lifecycle.

```yaml
firmware:
  bootloader:
    efi:
      secureBoot: false
```

UEFI firmware is required for Redfish virtual media provisioning. Ironic attaches an ISO image to the VM's virtual CD drive and instructs the firmware to boot from it. Legacy BIOS does not support this virtual media boot path. Secure Boot is disabled because the Ironic Python Agent ramdisk is not signed.

```yaml
interfaces:
  - name: default
    macAddress: "02:00:00:00:00:01"
    bridge: {}
```

```yaml
networks:
  - name: default
    multus:
      networkName: default/lab-vlan6-vm
```

The VM is attached to a real network through a Multus NetworkAttachmentDefinition rather than the cluster's pod network. This is critical — during provisioning, the Ironic Python Agent running inside the VM reports its IP address back to Ironic, and Ironic needs to connect to the agent on port 9999 to issue commands. The Metal3 pod runs with `hostNetwork: true`, so Ironic shares the node's network stack. If the VM were on the pod network (using `masquerade` or even `bridge` with `pod: {}`), the IPA agent's IP would not be routable from the node's perspective. Placing the VM on a network that the nodes can reach directly solves this.

The NetworkAttachmentDefinition should use `"ipam": {}` (no CNI-level IPAM) so the VM's own DHCP client handles IP assignment and DNS resolution natively from the physical network. If you use the CNI DHCP plugin (`"ipam": {"type": "dhcp"}`), KubeVirt's virt-launcher pod will override the VM's DNS with the cluster's CoreDNS address, which is unreachable from the bridged VLAN. Leaving IPAM empty avoids this entirely — the VM gets its IP and DNS directly from your network's DHCP server, just like a physical machine would.

Replace `default/lab-vlan6-vm` with a NetworkAttachmentDefinition in your cluster that bridges VMs to a network reachable from your OpenShift nodes. If you do not have one, you can create a linux bridge on the nodes using the NMState Operator and a `NodeNetworkConfigurationPolicy`, then reference it in a `NetworkAttachmentDefinition`.

The MAC address is pinned to a static value. KubeVirt assigns random MAC addresses to VM interfaces by default, and those addresses can change when the VirtualMachineInstance is recreated. The BareMetalHost resource you create later requires a `bootMACAddress` that exactly matches the VM's NIC — if they drift apart, Ironic will not be able to correlate the host it discovered with the BareMetalHost resource.

```yaml
dataVolumeTemplates:
  - metadata:
      name: simulated-bmh-rootdisk
    spec:
      storage:
        resources:
          requests:
            storage: 20Gi
      source:
        blank: {}
```

The DataVolume creates a 20Gi blank disk. This is the disk Ironic will write the Fedora image to during provisioning. The `blank` source means no operating system is pre-installed — just empty storage waiting for Ironic to populate it.

Verify the VM was created and is in a stopped state:

```bash
oc get vm -n simulated-bmh
```

```
NAME             AGE   STATUS    READY
simulated-bmh    10s   Stopped   False
```

---

### Step 2: Deploy the Redfish Controller

The redfish-controller translates standard Redfish API calls into KubeVirt operations. When Ironic sends a Redfish request to power on a system, the controller starts the corresponding VirtualMachine. When Ironic attaches a virtual media ISO, the controller mounts it to the VM. Deploy it with Helm.

Add the Helm repository and install the controller. The chart is published under the original maintainer's repository — the upstream KubeVirt chart hosting is not yet available:

```bash
helm repo add v1k0d3n https://v1k0d3n.github.io/charts
helm repo update
```

📄 [2-redfish-values.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/2-redfish-values.yaml)

```bash
helm install kubevirt-redfish v1k0d3n/kubevirt-redfish \
  --version 0.2.3 \
  -n simulated-bmh \
  -f 2-redfish-values.yaml
```

The values file configures five things:

```yaml
global:
  namespace: simulated-bmh
```

The chart hardcodes its target namespace through `global.namespace` rather than respecting the Helm `-n` flag. Override it to `simulated-bmh` so that all resources — the Deployment, Service, Route, and ServiceAccount — are created in the same namespace as the VM.

```yaml
route:
  enabled: true
  host: ""
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

An OpenShift Route exposes the Redfish API outside the cluster's internal network. Setting `host` to an empty string overrides the chart's hardcoded default and lets OpenShift auto-generate the hostname based on the route name, namespace, and your cluster's apps wildcard DNS. This is necessary because the Metal3 pod runs with `hostNetwork: true` when the provisioning network is disabled. Host-networked pods use the node's DNS resolver, not the cluster's CoreDNS, which means internal service names like `kubevirt-redfish.simulated-bmh.svc.cluster.local` may not resolve. The Route's hostname goes through the cluster's external wildcard DNS (`*.apps.<cluster>.<domain>`), which the node's resolver can reach.

```yaml
chassis:
  - name: simulated-bmh
    namespace: simulated-bmh
    service_account: default
```

The chassis configuration maps a logical chassis name to the `simulated-bmh` namespace. The controller will expose all VirtualMachines in that namespace as Redfish Systems. The service account provides the controller with the permissions it needs to manage VMs in that namespace.

```yaml
authentication:
  users:
    - username: admin
      password: r3dfish!
      chassis:
        - simulated-bmh
```

Authentication credentials for the Redfish API. Each user is scoped to one or more chassis by name — the `chassis` list here must match the `name` field from the chassis configuration above. The BMC Secret you create later for the BareMetalHost must use these same credentials.

```yaml
datavolume:
  storage_size: 3Gi
  allow_insecure_tls: true
```

The datavolume section configures how the controller handles virtual media ISOs that Ironic attaches during inspection and provisioning. The `storage_size` sets the PVC size for temporary ISO storage, and `allow_insecure_tls` permits downloading ISOs over HTTPS without strict certificate validation — necessary when Ironic serves its images with a self-signed certificate.

Verify the controller pod is running:

```bash
oc get pods -n simulated-bmh -l app.kubernetes.io/name=kubevirt-redfish
```

```
NAME                                    READY   STATUS    RESTARTS   AGE
kubevirt-redfish-xxxxx-xxxxx            1/1     Running   0          30s
```

Get the Route hostname and verify the Redfish API is responding:

```bash
REDFISH_ROUTE=$(oc get route -n simulated-bmh -o jsonpath='{.items[0].spec.host}')
echo $REDFISH_ROUTE
```

```
kubevirt-redfish-simulated-bmh.apps.<cluster>.<domain>
```

```bash
curl -sk -u admin:r3dfish! https://${REDFISH_ROUTE}/redfish/v1/Systems/simulated-bmh
```

You should see a JSON response with the VM's details — `PowerState: "Off"`, processor count, memory, and available actions. The controller does not support listing all systems at the collection endpoint (`/Systems/`); you must address each system by its VirtualMachine name. If the response returns a `ResourceNotFound` error, check that the controller pod logs show it discovered the VirtualMachine in the `simulated-bmh` namespace.

---

### Step 3: Enable the Provisioning CR

On every OpenShift cluster, the Cluster Baremetal Operator (CBO) is installed by default. But CBO only deploys Ironic — the component that actually communicates with BMCs and manages host provisioning — when it sees a Provisioning custom resource. On clusters that were not installed on bare metal, this resource does not exist and Ironic is not running. You need to create it.

📄 [3-provisioning.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/3-provisioning.yaml)

```bash
oc apply -f 3-provisioning.yaml
```

The Provisioning resource has three key fields:

```yaml
spec:
  provisioningNetwork: Disabled
```

Setting the provisioning network to `Disabled` tells Ironic to operate in virtual-media-only mode. In a traditional bare metal deployment, Ironic uses a dedicated provisioning network with DHCP and PXE to boot hosts into the inspection ramdisk. With virtual media, Ironic skips PXE entirely and instead attaches an ISO image directly to the host's virtual CD drive through the Redfish API. This is simpler — no dedicated network, no DHCP server — and is the right mode for this simulation because the redfish-controller supports virtual media operations.

```yaml
spec:
  disableVirtualMediaTLS: true
```

By default, Ironic serves the IPA boot ISO over HTTPS with a self-signed certificate. The IPA ramdisk may not be able to verify that certificate, which prevents it from downloading the image or calling back to Ironic. Setting `disableVirtualMediaTLS` to `true` tells Ironic to serve virtual media over plain HTTP, avoiding certificate issues in a lab environment.

```yaml
spec:
  watchAllNamespaces: true
```

This tells the Bare Metal Operator to watch all namespaces for BareMetalHost resources, not just `openshift-machine-api`. This gives you the flexibility to create BareMetalHost resources in any namespace.

Verify that Ironic is starting up. CBO deploys the Metal3 components in `openshift-machine-api`:

```bash
oc get pods -n openshift-machine-api | grep metal3
```

```
metal3-xxxxx-xxxxx                                3/3     Running   0          2m
metal3-baremetal-operator-xxxxx-xxxxx             1/1     Running   0          2m
metal3-image-customization-xxxxx-xxxxx            1/1     Running   0          2m
```

The `metal3` pod contains Ironic and its supporting services. The `metal3-baremetal-operator` pod runs the Bare Metal Operator that reconciles BareMetalHost resources. The `metal3-image-customization` pod handles image preparation. It may take a minute or two for all pods to reach `Running` status. If any pod stays in `Pending` or `CrashLoopBackOff`, check the CBO operator logs for configuration issues:

```bash
oc logs deployment/cluster-baremetal-operator -n openshift-machine-api --tail=20
```

---

### Step 4: Register the BareMetalHost

Now connect the two systems: create a BareMetalHost that points Ironic at the redfish-controller's Redfish API for the simulated VM. This step requires two resources — a Secret with the BMC credentials and the BareMetalHost itself. Both go in `openshift-machine-api` because that is the namespace BMO watches.

📄 [4-bmc-secret.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/4-bmc-secret.yaml)

```bash
oc apply -f 4-bmc-secret.yaml
```

The Secret contains the same `admin` / `r3dfish!` credentials you configured in the redfish-controller's Helm values. Ironic will use these to authenticate against the Redfish API when it powers on the VM, attaches virtual media, and queries hardware inventory.

Before applying the BareMetalHost, replace the placeholder BMC address with your actual Route hostname. This one-liner reads the Route, substitutes it into the YAML, and applies it:

```bash
REDFISH_ROUTE=$(oc get route kubevirt-redfish -n simulated-bmh -o jsonpath='{.spec.host}')
sed "s/REPLACE_WITH_ROUTE_HOSTNAME/${REDFISH_ROUTE}/" 5-baremetalhost.yaml | oc apply -f -
```

📄 [5-baremetalhost.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/5-baremetalhost.yaml)

The resulting BMC address will look like:

```
redfish-virtualmedia+https://kubevirt-redfish-simulated-bmh.apps.<cluster>.<domain>/redfish/v1/Systems/simulated-bmh
```

The BareMetalHost has several fields that control how Ironic registers and manages this host:

```yaml
spec:
  bmc:
    address: redfish-virtualmedia+https://<route>/redfish/v1/Systems/simulated-bmh
    credentialsName: simulated-bmh-bmc
    disableCertificateVerification: true
```

The `address` uses the `redfish-virtualmedia+https://` scheme, which tells Ironic to use the Redfish Virtual Media protocol over HTTPS. The path `/redfish/v1/Systems/simulated-bmh` identifies the specific system within the redfish-controller — with the default `system_id_convention: "legacy"`, the system ID is simply the VirtualMachine name. The `credentialsName` references the Secret you just created. Certificate verification is disabled because the Route uses the cluster's wildcard TLS certificate, which Ironic does not trust by default. This is acceptable in a lab environment.

```yaml
spec:
  bootMACAddress: "02:00:00:00:00:01"
  bootMode: UEFI
  online: true
```

The `bootMACAddress` must exactly match the static MAC address you assigned to the VM's network interface in Step 1. Ironic uses this MAC to correlate the physical (or in this case, virtual) network interface it discovers during inspection with this BareMetalHost resource. The `bootMode` is set to UEFI to match the VM's firmware configuration. Setting `online: true` tells BMO to power on the host after registration — Ironic will start the VM through the Redfish API.

Watch the BareMetalHost move through its lifecycle states:

```bash
oc get bmh -n openshift-machine-api -w
```

```
NAME             STATE          CONSUMER   ONLINE   ERROR   AGE
simulated-bmh    registering               true             5s
simulated-bmh    inspecting                true             30s
simulated-bmh    available                 true             3m
```

During **registering**, Ironic contacts the Redfish endpoint to verify BMC access and reads the current power state. During **inspecting**, Ironic powers on the VM, attaches the Ironic Python Agent (IPA) ramdisk via virtual media, and boots it. The IPA ramdisk collects hardware inventory — CPU, memory, disk, and network information — and reports it back to Ironic. Once inspection completes, the host transitions to **available**, meaning it is ready to be provisioned with an operating system.

If the host stays in `registering` with an error, the most common cause is that Ironic cannot reach the Redfish endpoint. Check the metal3 pod's `ironic` container logs:

```bash
oc logs -n openshift-machine-api $(oc get pods -n openshift-machine-api -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state -o jsonpath='{.items[0].metadata.name}') -c metal3-ironic --tail=30
```

You can also inspect the hardware details that Ironic collected during inspection:

```bash
oc get bmh simulated-bmh -n openshift-machine-api -o jsonpath='{.status.hardware}' | jq
```

This shows the CPU count, memory size, disk capacity, and NIC details that Ironic discovered — all coming from the KubeVirt VM through the redfish-controller.

---

### Step 5: Provision Fedora Cloud Base

With the BareMetalHost in the `available` state, you can provision an operating system. This step adds cloud-init user data and an OS image to the BareMetalHost, which triggers Ironic to boot the IPA ramdisk again, download the Fedora Cloud image, write it to the VM's disk, inject the cloud-init configuration, and reboot into the installed OS.

First, create the cloud-init user data Secret:

📄 [6-userdata-secret.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/6-userdata-secret.yaml)

```bash
oc apply -f 6-userdata-secret.yaml
```

The Secret contains a cloud-config that runs on first boot:

```yaml
userData: |
  #cloud-config
  user: fedora
  password: changeme
  chpasswd:
    expire: false
  ssh_pwauth: true
  packages:
    - qemu-guest-agent
  runcmd:
    - systemctl enable --now qemu-guest-agent
```

This sets the `fedora` user's password to `changeme` (change this in any non-lab environment), enables SSH password authentication so you can log in without an SSH key, and installs the QEMU guest agent. The guest agent allows KubeVirt to report the VM's IP address and OS information through the VirtualMachineInstance status, which is useful for verifying that the provisioned OS is actually Fedora.

Apply the provisioning image the same way, substituting the Route hostname:

📄 [7-provision-image.yaml](https://github.com/tinyships/tinyshipsio/blob/main/docs/posts/metal3-bare-metal-provisioning-kubevirt/7-provision-image.yaml)

```bash
REDFISH_ROUTE=$(oc get route kubevirt-redfish -n simulated-bmh -o jsonpath='{.spec.host}')
sed "s/REPLACE_WITH_ROUTE_HOSTNAME/${REDFISH_ROUTE}/" 7-provision-image.yaml | oc apply -f -
```

This applies the full BareMetalHost resource with the `image` and `userData` blocks added:

```yaml
spec:
  image:
    url: https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2
    checksum: https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-42-1.1-x86_64-CHECKSUM
    checksumType: auto
    format: qcow2
```

The `url` points to the Fedora 42 Cloud Base image in qcow2 format. The `checksum` is a URL to Fedora's published checksum file — Ironic will download this file and use it to verify the image after download. Setting `checksumType` to `auto` tells Ironic to detect the hash algorithm from the checksum file. The `format: qcow2` tells Ironic to convert the image from qcow2 to raw before writing it to disk, since disks expect raw block data.

Note that the Ironic Python Agent ramdisk — not Ironic itself — downloads the OS image. The ramdisk runs inside the KubeVirt VM, which means the VM needs network egress to reach `download.fedoraproject.org`. If your cluster restricts outbound traffic, you will need to mirror the Fedora image to an internal registry or HTTP server accessible from the pod network.

```yaml
spec:
  userData:
    name: simulated-bmh-userdata
    namespace: openshift-machine-api
```

The `userData` field references the cloud-init Secret you created. Ironic packages this into a config drive (a small ISO or VFAT partition) and attaches it to the host. Cloud-init reads the config drive on first boot and applies the configuration.

Watch the provisioning progress:

```bash
oc get bmh -n openshift-machine-api -w
```

```
NAME             STATE           CONSUMER   ONLINE   ERROR   AGE
simulated-bmh    provisioning               true             5m
simulated-bmh    provisioned                true             12m
```

The **provisioning** state means Ironic has booted the IPA ramdisk, downloaded the Fedora image, and is writing it to the VM's disk. This can take several minutes depending on image download speed. Once it transitions to **provisioned**, the OS has been written and the host is rebooting into Fedora.

Verify the VM is running:

```bash
oc get vmi -n simulated-bmh
```

```
NAME             AGE   PHASE     IP            NODENAME   READY
simulated-bmh    12m   Running   10.x.x.x      worker-1   True
```

If the QEMU guest agent is running (it should be, from the cloud-init configuration), you can check the OS information reported by the guest:

```bash
oc get vmi simulated-bmh -n simulated-bmh -o jsonpath='{.status.guestOSInfo}' | jq
```

```json
{
    "id": "fedora",
    "name": "Fedora Linux",
    "prettyName": "Fedora Linux 42",
    "version": "42",
    "versionId": "42"
}
```

The guest OS reports as Fedora Linux 42 — the image you specified in the BareMetalHost was downloaded by Ironic, written to the VM's disk, and booted successfully with your cloud-init configuration applied.

---

## Cleanup

To remove everything created in this walkthrough:

```bash
oc delete bmh simulated-bmh -n openshift-machine-api --wait=false
oc patch bmh simulated-bmh -n openshift-machine-api --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
oc delete secret simulated-bmh-bmc simulated-bmh-userdata -n openshift-machine-api
helm uninstall kubevirt-redfish -n simulated-bmh
oc delete pvc --all -n simulated-bmh
oc delete provisioning provisioning-configuration
oc delete namespace simulated-bmh
oc delete pod -n openshift-machine-api -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state
```

Deleting the BareMetalHost triggers deprovisioning — Ironic will wipe the disk and power off the VM before releasing it. Wait for the BareMetalHost to be fully removed before deleting the namespace, or the finalizer may block namespace deletion.

---

## References

- [kubevirt/redfish-controller on GitHub](https://github.com/kubevirt/redfish-controller) (upstream) and [v1k0d3n/kubevirt-redfish](https://github.com/v1k0d3n/kubevirt-redfish) (Helm chart source)
- [Metal3 User Guide — BareMetalHost Provisioning](https://book.metal3.io/bmo/provisioning)
- [Metal3 User Guide — Instance Customization](https://book.metal3.io/bmo/instance_customization)
- [OpenShift BareMetalHost API Reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/provisioning_apis/baremetalhost-metal3-io-v1alpha1)
- [Cluster Baremetal Operator](https://github.com/openshift/cluster-baremetal-operator)
- [Fedora Cloud Downloads](https://fedoraproject.org/cloud/download/)
