#!/usr/bin/env bash
set -e


#############
# VARIABLES #
#############

rook_git_root=$(git rev-parse --show-toplevel)
rook_kube_templates_dir="$rook_git_root/cluster/examples/kubernetes/"


#############
# FUNCTIONS #
#############

function fail_if {
  if ! git rev-parse --show-toplevel &> /dev/null; then
    echo "It looks like you are NOT in a Git repository"
    echo "This script should be executed from WITHIN Rook's git repository"
    exit 1
  fi
}

function purge_rook_pods {
  cd "$rook_kube_templates_dir"
  kubectl delete -n rook pool replicapool || true
  kubectl delete storageclass rook-block || true
  kubectl -n kube-system delete secret rook-admin || true
  kubectl delete -f kube-registry.yaml || true
  kubectl delete -n rook cluster rook || true
  kubectl delete thirdpartyresources cluster.rook.io pool.rook.io objectstore.rook.io filesystem.rook.io volumeattachment.rook.io || true # ignore errors if on K8s 1.7+
  kubectl delete crd clusters.rook.io pools.rook.io objectstores.rook.io filesystems.rook.io volumeattachments.rook.io || true # ignore errors if on K8s 1.5 and 1.6
  kubectl delete -n rook-system daemonset rook-agent || true
  kubectl delete -f rook-operator.yaml || true
  kubectl delete clusterroles rook-agent || true
  kubectl delete clusterrolebindings rook-agent || true
  kubectl delete namespace rook || true
  cd "$rook_git_root"
}

function purge_ceph_vms {
  instances=$(vagrant global-status | awk '/k8s-/ { print $1 }')
  for i in $instances; do
    # assuming /var/lib/rook is not ideal but it should work most of the time
    vagrant ssh "$i" -c "cat << 'EOF' > /tmp/purge-ceph.sh
    sudo rm -rf /var/lib/rook
    for disk in \$(sudo blkid | awk '/ROOK/ {print \$1}' | sed 's/[0-9]://' | uniq); do
    sudo dd if=/dev/zero of=\$disk bs=1M count=20 oflag=direct
    done
EOF"
    vagrant ssh "$i" -c "bash /tmp/purge-ceph.sh"
  done
}

  # shellcheck disable=SC2120
function add_user_to_docker_group {
  sudo groupadd docker || true
  sudo gpasswd -a vagrant docker || true
  if [[ $(id -gn) != docker ]]; then
    exec sg docker "$0 $*"
  fi
}

function run_docker_registry {
  if ! docker ps | grep -sq registry; then
    docker run -d -p 5000:5000 --restart=always --name registry registry:2
  fi
}

function docker_import {
  img=$(docker images | grep -Eo '^build-[a-z0-9]{8}/rook-[a-z0-9]+\s')
  # shellcheck disable=SC2086
  docker tag $img 172.17.8.1:5000/rook/rook:latest
  docker --debug push 172.17.8.1:5000/rook/rook:latest
  # shellcheck disable=SC2086
  docker rmi $img
}

function make_rook {
  # go to the repository root dir
  cd "$rook_git_root"
  # build rook
  make
}

function run_rook {
  cd "$rook_kube_templates_dir"
  kubectl create -f rook-operator.yaml
  kubectl create -f rook-cluster.yaml
  cd -
}

function edit_rook_cluster_template {
  cd "$rook_kube_templates_dir"
  sed -i 's|image: .*$|image: 172.17.8.1:5000/rook/rook:latest|' rook-operator.yaml
  echo "rook-operator.yml has been edited with the new image '172.17.8.1:5000/rook/rook:latest'"
  echo "Now run purge-ceph.sh from your host."
  cd -
}

function config_kubectl {
  local k8s_01_vm
  k8s_01_vm=$(vagrant global-status | awk '/k8s-01/ { print $1 }')
  mkdir -p $HOME/.kube/
  if [ -f $HOME/.kube/config ]; then
    echo "Backing up existing Kubernetes configuration file."
    mv $HOME/.kube/config $HOME/.kube/config.before.rook."$(date +%s)"
  fi
  vagrant ssh $k8s_01_vm -c "sudo cat /root/.kube/config" > $HOME/.kube/config.rook
  ln -sf $HOME/.kube/config.rook $HOME/.kube/config
  kubectl get nodes
}


########
# MAIN #
########

fail_if
config_kubectl
add_user_to_docker_group
run_docker_registry
# we purge rook otherwise make fails for 'use-use' image
purge_rook_pods
purge_ceph_vms
make_rook
docker_import
edit_rook_cluster_template
run_rook
