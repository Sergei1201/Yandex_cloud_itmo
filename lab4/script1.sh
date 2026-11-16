#!/usr/bin/env bash
set -euo pipefail

CLOUD_ID="b1gfaod9gpbrp91pr7a7"
FOLDER_NAME="nic-policy"
NET_NAME="nic-net"
SUBNET_NAME="nic-subnet-a"
VM_NAME="nic-vm"
ZONE="ru-central1-a"
CIDR="10.10.0.0/24"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"

# ---------- 1. Folder ----------
FOLDER_ID=$(yc resource-manager folder create \
  --name "$FOLDER_NAME" \
  --cloud-id "$CLOUD_ID" \
  --format json | jq -r .id)
echo "folder: $FOLDER_ID"

# ---------- 2. Network + subnet ----------
NET_ID=$(yc vpc network create \
  --name "$NET_NAME" \
  --folder-id "$FOLDER_ID" \
  --format json | jq -r .id)
echo "network: $NET_ID"

SUBNET_ID=$(yc vpc subnet create \
  --name "$SUBNET_NAME" \
  --folder-id "$FOLDER_ID" \
  --network-id "$NET_ID" \
  --zone "$ZONE" \
  --range "$CIDR" \
  --format json | jq -r .id)
echo "subnet: $SUBNET_ID"

# ---------- 3. Authorization policy: forbid multi-NIC VMs ----------
# compute.denyMultipleNic is a parameterless template. It blocks both
# creating a VM with >1 interface and attaching an extra interface to an
# existing VM. Scope it to the folder so it does not affect the rest of the cloud.
yc iam access-policy create \
  --name "deny-multiple-nic" \
  --template "compute.denyMultipleNic" \
  --resource-id "$FOLDER_ID" \
  --resource-type "resource-manager.folder"
# verify: yc iam access-policy list --resource-id "$FOLDER_ID" --resource-type resource-manager.folder

# ---------- 4. VM with exactly one interface ----------
yc compute instance create \
  --name "$VM_NAME" \
  --folder-id "$FOLDER_ID" \
  --zone "$ZONE" \
  --network-interface "subnet-id=$SUBNET_ID,nat-ip-version=ipv4" \
  --create-boot-disk "image-family=ubuntu-2204-lts,size=20,type=network-hdd" \
  --cores 2 --memory 2 --core-fraction 20 \
  --ssh-key "$SSH_KEY"

# ---------- 5. Verify ----------
yc compute instance get --name "$VM_NAME" --folder-id "$FOLDER_ID" \
  --format json | jq '{name, status, nics: [.network_interfaces[].index]}'
# expect: status RUNNING, nics [0]

# ---------- 6. Negative test A: attach a second interface ----------
# Adding/removing interfaces on a running VM is Preview, so stop it first.
yc compute instance stop --name "$VM_NAME" --folder-id "$FOLDER_ID"
if yc compute instance attach-network-interface "$VM_NAME" \
     --folder-id "$FOLDER_ID" \
     --network-interface "subnet-id=$SUBNET_ID"; then
  echo "UNEXPECTED: second interface was attached"
else
  echo "OK: attach rejected by policy"
fi
yc compute instance start --name "$VM_NAME" --folder-id "$FOLDER_ID"

# ---------- 7. Negative test B: create a VM with two interfaces ----------
if yc compute instance create \
     --name "${VM_NAME}-2nic" \
     --folder-id "$FOLDER_ID" \
     --zone "$ZONE" \
     --network-interface "subnet-id=$SUBNET_ID" \
     --network-interface "subnet-id=$SUBNET_ID" \
     --create-boot-disk "image-family=ubuntu-2204-lts,size=20"; then
  echo "UNEXPECTED: 2-NIC VM was created"
else
  echo "OK: 2-NIC VM rejected by policy"
fi

# ---------- 8. Cleanup ----------
yc compute instance delete --name "$VM_NAME" --folder-id "$FOLDER_ID"
yc vpc subnet delete   --name "$SUBNET_NAME" --folder-id "$FOLDER_ID"
yc vpc network delete  --name "$NET_NAME"    --folder-id "$FOLDER_ID"
yc iam access-policy delete --name "deny-multiple-nic" \
  --resource-id "$FOLDER_ID" --resource-type "resource-manager.folder"
yc resource-manager folder delete --id "$FOLDER_ID"
