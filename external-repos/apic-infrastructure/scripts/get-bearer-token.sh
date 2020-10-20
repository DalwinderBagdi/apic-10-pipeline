#!/bin/bash
#******************************************************************************
# PREREQUISITES:
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# PARAMETERS:
#   -c : <client cred secret>
#   -a : <cloud cred secret> (string)
#   -r : <release> (string)
#   -d : <debug> (string)
#
#******************************************************************************


TICK="\xE2\x9C\x85"
CROSS="\xE2\x9D\x8C"
DEBUG=false

while getopts "c:a:r:d" opt; do
  case ${opt} in
    c ) APIC_PIPELINE_CLIENTCRED="$OPTARG"
      ;;
    a ) APIC_SECRET="$OPTARG"
      ;;
    r ) RELEASE="$OPTARG"
      ;;
    d ) DEBUG="$OPTARG"
      ;;
    \? ) usage; exit
      ;;
  esac
done


OUTPUT=""
function handle_res {
  local body=$1
  local status=$(echo ${body} | $JQ -r ".status")
  $DEBUG && echo "[DEBUG] res body: ${body}"
  $DEBUG && echo "[DEBUG] res status: ${status}"
  if [[ $status == "null" ]]; then
    OUTPUT="${body}"
  else
    $DEBUG && echo -e "[ERROR] ${CROSS} Request failed: ${body}..."
    exit 1
  fi
}

# Install jq
$DEBUG && echo "[DEBUG] Checking if jq is present..."
jqInstalled=false

if ! command -v jq &> /dev/null; then
  jqInstalled=false
else
  jqInstalled=true
fi

JQ=jq
if [[ "$jqInstalled" == "false" ]]; then
  $DEBUG && echo "[DEBUG] jq not found, installing jq..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    $DEBUG && printf "on linux..."
    wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
    chmod +x ./jq
    JQ=./jq
    $DEBUG && echo "[DEBUG] ${TICK} jq installed"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    $DEBUG && printf "on macOS..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
    brew install jq
    $DEBUG && echo "[DEBUG] ${TICK} jq installed"
  fi
fi

$DEBUG && echo "[DEBUG] jq version: $($JQ --version)"

# Gather info from cluster resources
$DEBUG && echo "[DEBUG] Gathering cluster info..."
PLATFORM_API_EP=$(oc get route ${RELEASE}-mgmt-platform-api -o jsonpath="{.spec.host}")
$DEBUG && echo "[DEBUG] PLATFORM_API_EP=${PLATFORM_API_EP}"

#Get the API Manager secret
API_MANAGER_USER=$(oc get secret $APIC_SECRET --template='{{.data.admin_username}}' | base64 --decode)
API_MANAGER_PASS=$(oc get secret $APIC_SECRET --template='{{.data.admin_password}}' | base64 --decode)

$DEBUG && echo "[DEBUG] API_MANAGER_USER=${API_MANAGER_USER}"
$DEBUG && echo "[DEBUG] API_MANAGER_PASS=${API_MANAGER_PASS}"

#Get the Client ID and Secret
APIC_PIPELINE_CLIENT_ID=$(oc get secret $APIC_PIPELINE_CLIENTCRED --template='{{.data.client_id}}' | base64 --decode)
APIC_PIPELINE_CLIENT_SECRET=$(oc get secret $APIC_PIPELINE_CLIENTCRED --template='{{.data.client_secret}}' | base64 --decode)

$DEBUG && echo "[DEBUG] APIC_PIPELINE_CLIENT_ID=${APIC_PIPELINE_CLIENT_ID}"
$DEBUG && echo "[DEBUG] APIC_PIPELINE_CLIENT_SECRET=${APIC_PIPELINE_CLIENT_SECRET}"

#Check who is our client in this instance?!
$DEBUG && echo "[DEBUG] Getting bearer token..."
RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/token \
  -H "accept: application/json" \
  -H "content-type: application/json" \
  -d "{
    \"username\": \"${API_MANAGER_USER}\",
    \"password\": \"${API_MANAGER_PASS}\",
    \"realm\": \"provider/default-idp-2\",
    \"client_id\": \"${APIC_PIPELINE_CLIENT_ID}\",
    \"client_secret\": \"${APIC_PIPELINE_CLIENT_SECRET}\",
    \"grant_type\": \"password\"
}")

handle_res "${RES}"
TOKEN=$(echo "${OUTPUT}" | $JQ -r ".access_token")

echo $TOKEN > token.json

if [[ $TOKEN == "null" ]]; then
  echo -e "[ERROR] ${CROSS} Couldn't extract token"
  exit 1
else
  echo -e "[DEBUG] ${TICK} Got bearer token"
  exit 0
fi

cat token.json