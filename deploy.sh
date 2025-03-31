#!/usr/bin/env bash
[[ -z $DEBUGX ]] || set -x

## Always call finish when scripts exits (error or success)
function finish {
  if [ -d "$temp_dir" ]; then
    rm -rf "$temp_dir"
  fi
}
trap finish EXIT

#################################################
### DEFINE VARIABLES (WITH OPTIONAL DEFAULTS) ###
#################################################
MODE=

########################
### DEFINE FUNCTIONS ###
########################

## Print script usage information
function usage() {
  echo "Usage:"
  echo "Environment variables to be set:"
  echo "PIVNET_API_TOKEN - API Token to access Tanzu network downloads"
  echo "PLATFORM_AUTOMATION_VERSION - The version of platform automation to use, if not set then latest will be selected"
  echo ""
  echo "Command line arguments:"
  echo "-h - Script help/usage"

  exit 0
}

## Validate script variables have all been correctly set
function validate() {
  
  [ -z "$PIVNET_API_TOKEN" ] && return 1

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

  temp_dir="$(mktemp -d -p `pwd`)"

  prepare_docker
  
}

# validate and run the script
if validate; then
  main
else
  usage
fi