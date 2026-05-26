#!/usr/bin/env bash
#
# set-vm-static-ip.sh
#
# Reads a CSV with columns: vm_name,resource_group,desired_ip
# For each row, locates the VM's primary NIC and updates its primary
# ipConfiguration to use the desired IP as a static private IP, keeping
# the existing subnet, public IP, NSG, etc.
#
# Usage:
#   ./set-vm-static-ip.sh vms.csv [--dry-run]
#
# Requirements:
#   - az CLI logged in (az login) with the right subscription selected
#   - Permissions: Network Contributor (or equivalent) on the NICs
#
# Notes:
#   - The desired IP must belong to the subnet currently assigned to the
#     primary ipConfiguration of the primary NIC.
#   - The VM does not need to be restarted; Azure reprograms the NIC.
#     The guest OS will pick up the new IP via DHCP (Azure NICs always
#     use DHCP inside the guest, even when the allocation is "Static").

set -euo pipefail

CSV_FILE="${1:-}"
DRY_RUN="false"
if [[ "${2:-}" == "--dry-run" ]]; then
    DRY_RUN="true"
fi

if [[ -z "$CSV_FILE" || ! -f "$CSV_FILE" ]]; then
    echo "Usage: $0 <csv-file> [--dry-run]" >&2
    exit 1
fi

if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: az CLI not found in PATH." >&2
    exit 1
fi

# Strip an optional UTF-8 BOM and CR characters from the CSV before reading.
# Skip the header line.
tail -n +2 "$CSV_FILE" | sed $'s/\r$//; s/^\xEF\xBB\xBF//' | \
while IFS=',' read -r vm_name resource_group desired_ip _rest; do

    # Trim surrounding whitespace.
    vm_name="$(echo "$vm_name"        | xargs)"
    resource_group="$(echo "$resource_group" | xargs)"
    desired_ip="$(echo "$desired_ip"  | xargs)"

    # Skip blank lines.
    if [[ -z "$vm_name" && -z "$resource_group" && -z "$desired_ip" ]]; then
        continue
    fi

    echo "----------------------------------------------------------------"
    echo "VM:           $vm_name"
    echo "Resource grp: $resource_group"
    echo "Desired IP:   $desired_ip"

    if [[ -z "$vm_name" || -z "$resource_group" || -z "$desired_ip" ]]; then
        echo "  [SKIP] Missing field in CSV row." >&2
        continue
    fi

    # 1. Find the primary NIC of the VM. If only one NIC is attached, the
    #    "primary" flag may be absent, so we fall back to the first NIC.
    nic_id="$(az vm show \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --query "networkProfile.networkInterfaces[?primary].id | [0]" \
        -o tsv 2>/dev/null || true)"

    if [[ -z "$nic_id" || "$nic_id" == "None" ]]; then
        nic_id="$(az vm show \
            --resource-group "$resource_group" \
            --name "$vm_name" \
            --query "networkProfile.networkInterfaces[0].id" \
            -o tsv 2>/dev/null || true)"
    fi

    if [[ -z "$nic_id" || "$nic_id" == "None" ]]; then
        echo "  [ERROR] VM not found or has no NIC." >&2
        continue
    fi

    # 2. Parse NIC name + resource group from the resource ID. The NIC may
    #    live in a different RG than the VM.
    nic_name="$(basename "$nic_id")"
    nic_rg="$(echo "$nic_id" | awk -F'/' '{for(i=1;i<=NF;i++) if(tolower($i)=="resourcegroups") print $(i+1)}')"

    # 3. Get the primary ipConfiguration of that NIC, plus its current subnet.
    ipcfg_json="$(az network nic show \
        --ids "$nic_id" \
        --query "ipConfigurations[?primary] | [0].{name:name, subnetId:subnet.id, currentIp:privateIPAddress, alloc:privateIPAllocationMethod}" \
        -o json)"

    ipcfg_name="$(echo  "$ipcfg_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("name",""))' 2>/dev/null || true)"
    subnet_id="$(echo   "$ipcfg_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("subnetId",""))' 2>/dev/null || true)"
    current_ip="$(echo  "$ipcfg_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("currentIp",""))' 2>/dev/null || true)"
    current_alloc="$(echo "$ipcfg_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("alloc",""))' 2>/dev/null || true)"

    if [[ -z "$ipcfg_name" ]]; then
        echo "  [ERROR] Could not determine primary ipConfiguration of NIC $nic_name." >&2
        continue
    fi

    echo "  NIC:          $nic_name (rg: $nic_rg)"
    echo "  ipConfig:     $ipcfg_name"
    echo "  Current IP:   ${current_ip:-<none>} ($current_alloc)"
    echo "  Subnet:       $subnet_id"

    if [[ "$current_ip" == "$desired_ip" && "$current_alloc" == "Static" ]]; then
        echo "  [OK] Already set to $desired_ip (Static). Skipping."
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would set $desired_ip (Static) on $nic_name/$ipcfg_name."
        continue
    fi

    # 4. Update the primary ipConfiguration. The subnet stays the same;
    #    we only change the private IP and switch allocation to Static.
    if az network nic ip-config update \
            --resource-group "$nic_rg" \
            --nic-name "$nic_name" \
            --name "$ipcfg_name" \
            --private-ip-address "$desired_ip" \
            --output none; then
        echo "  [DONE] $nic_name/$ipcfg_name -> $desired_ip (Static)."
    else
        echo "  [ERROR] Failed to update NIC $nic_name. See az output above." >&2
        continue
    fi

done

echo "----------------------------------------------------------------"
echo "Finished."
