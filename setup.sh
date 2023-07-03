#!/bin/bash
# This script sets up a single node cluster (SNC) which was created by 
# the Cloud Installer (https://cloud.redhat.com/openshift/assisted-installer/clusters/~new)
#
# First, you have to install the SNC in your network. Then you are logging into it with kubeadmin
# THEN you can let this script run, which will create PVs in the VM and configures the 
# internal registry to use one of the PVs for storing everything.
# 
# Please see README.MD for more details.
#
set -e -u -o pipefail

declare HOST=192.168.2.23 # set it to your IP
declare USER=core
declare NUM_PVs=100
declare KUBECONFIG=""
declare OC=oc

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare COMMAND="help"


valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    storage|registry|operators|ci|users|all)
      COMMAND=$1
      shift
      ;;
    -h|--host-name)
      HOST=$2
      shift 2
      ;;
    -u|--user-name)
      USER=$2
      shift 2
      ;;
    -k|--kubeconfig)
      KUBECONFIG=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *) 
      break
  esac
done


command.help() {
  cat <<-EOF
  Provides some functions to make an OpenShift Single Node Cluster usable. 
  
  NOTE: First, you need to install an OpenShift Single Node Cluster (CRC or SNO). Then you
  have to log into it using the kubeadmin credentials provided. 

  oc login -u kubeadmin -p <your kubeadmin hash> https://api.crc.testing:6443

  And THEN you can issue this script.
  

  Usage:
      setup.sh [command] [options]
  
  Example:
      setup.sh all 
  
  COMMANDS:
      storage                        Setup CSI kubevirt hostpath provisioner
      registry                       Setup internal image registry to use a PVC and accept requests
      operators                      Install gitops and pipeline operators
      ci                             Install Nexus and Gogs in a ci namespace
      users                          Creates two users: admin/admin123 and devel/devel
      all                            call all modules
      help                           Help about this command

  OPTIONS:
      -k --kubeconfig                kubeconfig file to be used
      
EOF
}

# This command sets up the kubevirt hostpath provisioner
command.storage() {
    info "Installing kubevirt CSI hostpath provisioner"
    $OC apply -k config/storage
}

command.registry() {
    info "Binding internal image registry to a persistent volume and make it manageable"
    # Apply registry pvc to bound with pv0001
    $OC apply -k config/registry
}

command.operators() {
  info "Installing openshift-gitops and openshift-pipelines operators"
  $OC apply -k config/operators
}

command.ci() {
    info "Initialising a CI project in OpenShift with Nexus and GOGS installed"
    $OC get ns ci 2>/dev/null  || {
      info "Creating CI project" 
      $OC new-project ci > /dev/null

      $OC apply -f "$SCRIPT_DIR/support/nexus.yaml" --namespace ci
      $OC apply -f "$SCRIPT_DIR/support/gogs.yaml" --namespace ci
      GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}')
      info "Gogs Hostname: $GOGS_HOSTNAME"

      info "Initiatlizing git repository in Gogs and configuring webhooks"
      sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" support/gogs-configmap.yaml | $OC apply --namespace ci -f - 
      $OC rollout status deployment/gogs --namespace ci
      $OC create -f support/gogs-init-taskrun.yaml --namespace ci
    }
}

command.users() {
    info "Creating an admin and a developer user."
    $OC apply -k config/users
    # we want admin be cluster-admin
    $OC adm policy add-cluster-role-to-user cluster-admin admin

    info "Please wait a while until OpenShift has updated OAuth management"
}


command.all() {
    command.storage
    command.registry
    command.users
    command.operators
    command.ci
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  # setup OC command
  if [ -n "$KUBECONFIG" ]; then
    info "Using kubeconfig $KUBECONFIG"
    OC="oc --kubeconfig $KUBECONFIG"
  else
    info "Using default kubeconfig"
    OC="oc"
  fi 

  cd "$SCRIPT_DIR"
  $fn
  return $?
}

main
