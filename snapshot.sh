#!/usr/bin/env bash

# Script to create and restore snapshots of the OS disk of Azure VMs

# Copyright 2018 SURFnet B.V.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function error_exit {
    echo "${1}"
    exit 1
}

# Process options

if [ $# -eq 0 ]; then
    progname=${0##*/}
    echo "Usage: $progname <create | restore> [--group <resource group>] [--name <vm name>] [snapshot name]"
    echo
    echo "This script allows you to:"
    echo "- Create a snapshot of the OS disk of a (running) Azure VM"
    echo "- Restore the OS disk of a Azure VM from a snapshot"
    echo
    echo "THis script requires the 'az' command. This can be installed by running E.g. 'pip install azure-cli'"
    echo "(after install run 'az login')"
    echo
    echo "Options:"
    echo "--group|-g: <resource group> : resource group of the VM"
    echo "--name|-n <vm name> : Virtual machine name"
    echo
    echo "If resource group, vm name or snapshot name are not specified, you will be asked to select them from a list"
    echo
    exit 1
fi

command=$1  # Command to execute
shift
if [[ ! "$command" =~ ^(create|restore)$ ]]; then
    echo "Invalid command '$command'. Allowed commands: 'create' and 'restore'"
    exit 1
fi

group=
vm_name=
snapshot_name=

while [[ $# > 0 ]]
do
option="$1"
shift

case $option in
    -g|--group)
    group="$1"
    if [ -z "$1" ]; then
        error_exit "'$option' option requires an argument"
    fi
    shift
    ;;
    -n|--name)
    vm_name="$1"
    if [ -z "$1" ]; then
        error_exit "'$option' option requires an argument"
    fi
    shift
    ;;
    -*)
    error_exit "Unknown option: '$option'"
    ;;
    *)
    snapshot_name="$option"
    shift
esac
done

AZ=`which az`
if [ "$?" -ne "0" ]; then
   echo "Could not find the 'az' command in the current path. Make sure azure-cli is installed and in the current path."
   echo "Use e.g. 'pip install azure-cli' to install"
   exit 1
fi
echo "Using '$AZ'"


if [ -z "$group" ]; then
    echo "Fetching available resource groups in your subscription"
    az_groups=`$AZ group list --query [].name -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not fetch resource groups"
    fi

    echo "Choose resource group:"
    select group in $az_groups; do
        for item in $az_groups; do
            if [ "$item" == "$group"  ]; then
               break 2
            fi
        done
    done
fi

if [ -z "$vm_name" ]; then
    echo "Fetching vm names in resource group '$group'"
    az_names=`$AZ vm list -g "$group" --query [].name -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not fetch vm names in resource group '$group'"
    fi

    echo "Choose vm name for which to $command a snapshot:"
    select vm_name in $az_names; do
        for item in $az_names; do
            if [ "$item" == "$vm_name"  ]; then
               break 2
            fi
        done
    done
fi

echo "Selected VM '$vm_name' in resource group '$group'"

echo "Getting VM ID"
vm_id=`$AZ vm show -g $group -n $vm_name --query id -o tsv`
if [ "$?" -ne "0" ]; then
    error_exit "Could not find VM '$vm_name' in resource group '$group'"
fi
echo "VM ID: $vm_id"

out=`$AZ vm show --ids $vm_id --query "[storageProfile.osDisk.managedDisk.id, location] | join(',', @)" -o tsv`
if [ "$?" -ne "0" ]; then
    error_exit "Could get ID of the OS disk"
fi
IFS=',' read current_disk_id vm_location <<< $out

# Handle "create" command
if [ "$command" == "create" ]; then
    while [ -z $snapshot_name ]; do
        echo -n "Enter name for the snapshot to create: "
        read snapshot_name
    done
    echo "About to create snapshot with name '$snapshot_name' of vm '$vm_name' in resource group '$group' in location '$vm_location'."
    read -p "Continue [Y/N]? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted"
        exit 1
    fi
    echo "Creating a snapshot of disk with ID '$current_disk_id' in location '$vm_location' and resource group '$group'"
    snapshot_id=`$AZ snapshot create -g $group -n $snapshot_name -l $vm_location --source $current_disk_id --query id -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Error creating snapshot"
    fi
    echo 'Created snapshot with ID: snapshot_id'

    echo "Done!"
    echo

    exit 0
# Handle "restore" command
elif [ "$command" == "restore" ]; then
    if [ -z $snapshot_name ]; then
        snapshots=`$AZ snapshot list -g $group --query [].name -o tsv`
        echo "Fetching available snapshots in group $group"
        if [ "$?" -ne "0" ]; then
            error_exit "Could not fetch snapshots in group '$group'"
        fi
        echo "Choose snapshot to restore to vm $vm_name:"
        select snapshot_name in $snapshots; do
            for item in $snapshots; do
                if [ "$item" == "$snapshot_name"  ]; then
                   break 2
                fi
            done
        done
    fi

    echo "About to restore snapshot $snapshot_name to vm '$vm_name' in resource group '$group' in location '$vm_location'"
    echo "The VM will be shutdown and the current OS disk of the VM will be destroyed. The snapshot remains available."
    read -p "Continue [Y/N]? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted"
        exit 1
    fi

    # Get the ID of the snapshot to restore
    echo "Fetching snapshot ID"
    snapshot_id=`$AZ snapshot show -n $snapshot_name -g $group --query id -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not fetch snapshot ID"
    fi
    echo "Snapshot ID: $snapshot_id"

    # Get current OS disk ID from the VM so we can delete it later
    echo "Fetching current OS disk ID"
    current_disk_id=`$AZ vm show --ids $vm_id --query storageProfile.osDisk.managedDisk.id -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not fetch current OS disk ID"
    fi
    echo "Current disk ID: $current_disk_id"

    # Create a name for the new disk
    new_disk_name="${vm_name}__${snapshot_name}__`date +%Y-%m-%d_%s`"

    # Create new disk from snapshot
    echo "Creating a new disk with name $new_disk_name from snapshot"
    new_disk_id=`$AZ disk create -n $new_disk_name -g $group --location $vm_location --sku Standard_LRS --source $snapshot_id --query id -o tsv`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not create a new disk from snapshot"
    fi
    echo "Created new disk with ID $new_disk_id"

    # Stop and deallocate the VM
    echo "Stopping the VM"
    $AZ vm stop --ids $vm_id
    if [ "$?" -ne "0" ]; then
        error_exit "Could not stop the VM"
    fi
    echo "VM Stopped"
    echo "Deallocating the VM"
    $AZ vm deallocate --ids $vm_id
    if [ "$?" -ne "0" ]; then
        error_exit "Could deallocate the VM"
    fi
    echo "VM deallocated"

    # Assign new disk to the VM
    echo "Updating the VM to use the new disk"
    upated_vm=`$AZ vm update --ids $vm_id --os-disk $new_disk_id`
    if [ "$?" -ne "0" ]; then
        error_exit "Could not update the VM"
    fi
    echo "VM updated"

    # Start the VM
    echo "Starting the VM"
    $AZ vm start --ids $vm_id
    if [ "$?" -ne "0" ]; then
        echo "Starting the VM failed. You need to manually:"
        echo "- Start the VM: '$AZ vm start --ids $vm_id'"
        echo "- Delete the old disk: '$AZ disk delete --ids $current_disk_id'"
        echo "(Because the VM was deallocated, starting sometimes fails when Azure does not have"
        echo " enough VMs of the required type avaiable)"
        error_exit "Could not start the VM."
    fi
    echo "VM started"

    echo "Deleting the old disk with id $current_disk_id"
    $AZ disk delete --ids $current_disk_id --verbose --yes
    echo "Deleted the old disk"

    echo "Done!"
    echo

    exit 0
else
    error_exit "Don't know how to handle command $command"
fi
