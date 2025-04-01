#!/usr/bin/env bash
[[ -z $DEBUGX ]] || set -x

repo_root="$(cd "$(dirname "$0")" && pwd)"

## Always call finish when scripts exits (error or success)
function finish {
  if [ -d "$temp_dir" ] && [ "$CLEANUP" = true ]; then
    rm -rf "$temp_dir"
  fi
}
trap finish EXIT

if ls -d $repo_root/tmp.*/ &>/dev/null; then
  #use existing tmp dir
  temp_dir="$(ls -d $repo_root/tmp.*)"
else
  # create temporary work dir
  temp_dir="$(mktemp -d -p $repo_root)"
fi

#################################################
### DEFINE VARIABLES (WITH OPTIONAL DEFAULTS) ###
#################################################
CLEANUP=${CLEANUP:-true}

########################
### DEFINE FUNCTIONS ###
########################

## Print script usage information
function usage() {
  echo "Usage:"
  echo "Environment variables to be set:"
  echo "PIVNET_API_TOKEN - API Token to access Tanzu network downloads"
  echo "PLATFORM_AUTOMATION_VERSION - The version of platform automation to use, if not set then latest will be selected"
  echo "OPSMAN_VERSION - The version of ops manager to deploy, if not set then latest will be selected"
  echo "CLEANUP - Automatically cleans up downloaded artefacts, defaults to true"
  echo ""
  echo "Command line arguments:"
  echo "-h - Script help/usage"

  exit 0
}

## Validate script variables have all been correctly set
function validate() {
  
  [ -z "$PIVNET_API_TOKEN" ] && return 1

  if [[ ! $CLEANUP =~ ^(true|false)$ ]]; then 
    echo "Error: CLEANUP env var must be true or false"
    return 1
  fi

  return 0
}


function prepare_docker() {

  # get the latest platform automation version if explicit version not set
  [ -z "$PLATFORM_AUTOMATION_VERSION" ] && PLATFORM_AUTOMATION_VERSION=`curl -s https://network.tanzu.vmware.com/api/v2/products/platform-automation/releases | jq -r '.releases | first | .version'`
	
  if [ "$(docker images -q "platform-automation-image:${PLATFORM_AUTOMATION_VERSION}")" == "" ]; then
    
    echo "Downloading platform automation docker image version: $PLATFORM_AUTOMATION_VERSION"
    om download-product \
    --pivnet-api-token="$PIVNET_API_TOKEN" \
    --pivnet-product-slug=platform-automation \
    --product-version="$PLATFORM_AUTOMATION_VERSION" \
    --file-glob='platform-automation-image-*.tgz' \
    --output-directory="${temp_dir}/"

    echo "Importing platform automation docker image version: $PLATFORM_AUTOMATION_VERSION to local docker daemon"
    docker import ${temp_dir}/platform-automation-image-*.tgz "platform-automation-image:${PLATFORM_AUTOMATION_VERSION}"

  else
    echo "Skipping platform automation docker image download as version: $PLATFORM_AUTOMATION_VERSION is already present" 
  fi

}

docker_run() {
  docker run \
    --volume="${repo_root}:/workdir" \
    --volume="${temp_dir}:/tempdir" \
    --workdir="/workdir" \
    "platform-automation-image:${PLATFORM_AUTOMATION_VERSION}" \
    "$@"
}

function deploy_opsman() {

  # get the latest ops manager version if explicit version not set
  [ -z "$OPSMAN_VERSION" ] && OPSMAN_VERSION=`curl -s https://network.tanzu.vmware.com/api/v2/products/ops-manager/releases | jq -r '.releases | first | .version'`

  opsman_filename=ops-manager-vsphere-$OPSMAN_VERSION.ova

  if [ ! -f ${temp_dir}/${opsman_filename} ]; then
  
    echo "Downloading ops manager version: $OPSMAN_VERSION"
    docker_run om download-product \
    --pivnet-api-token="$PIVNET_API_TOKEN" \
    --pivnet-product-slug=ops-manager \
    --product-version="$OPSMAN_VERSION" \
    --file-glob='ops-manager-vsphere-*.ova' \
    --output-directory="/tempdir"

  else
    echo "Skipping ops manager download as version: $OPSMAN_VERSION is already present" 
  fi

  echo "Generating ops manager environment file"
  docker_run om interpolate \
  --config /workdir/templates/env/env.yml \
  --vars-file /workdir/control-plane-vars.yml \
  > "${temp_dir}/env.yml"

  echo "Deploying ops manager VM"
  docker_run om nom create-vm \
  --config /workdir/templates/config/opsman-vsphere.yml \
  --image-file "/tempdir/${opsman_filename}"  \
  --state-file /workdir/state/opsman_state.yml \
  --vars-file /workdir/control-plane-vars.yml

  # Configure Ops Manager auth
  om_target="$(awk '/target: / {print $2}' "${temp_dir}/env.yml")"

  # shellcheck disable=SC2091
  until $(curl --output /dev/null -k --silent --head --fail "${om_target}/setup"); do
      printf '.'
      sleep 5
  done

  echo "Setting up ops manager authentication"
  docker_run om \
  --env /tempdir/env.yml \
  configure-authentication \
  --config /workdir/templates/config/auth.yml \
  --vars-file /workdir/control-plane-vars.yml

  echo "Configuring bosh director"
  docker_run om \
  --env /tempdir/env.yml \
  configure-director \
  --config /workdir/templates/config/director-vsphere.yml \
  --vars-file /workdir/control-plane-vars.yml

  echo "Deploying bosh director"
  docker_run om \
  --env /tempdir/env.yml \
  apply-changes \
  --reattach \
  --skip-deploy-products
}

#############################################
### Read parameters from the command line ###
#############################################
while getopts 'h' arg; do
  case $arg in
  m) export MODE="$OPTARG" ;;
  \? | h) usage ;;
  esac
done

## Main script logic
function main() {



  prepare_docker
  deploy_opsman
  
}

# validate and run the script
if validate; then
  main
else
  usage
fi