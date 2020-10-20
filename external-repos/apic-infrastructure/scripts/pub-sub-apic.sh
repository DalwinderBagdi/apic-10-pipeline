#!/bin/bash
##*******************************************************************************
# PARAMETERS:
#   -c : <client cred secret>
#   -s : <cloud cred secret> (string)
#   -r : <release> (string)
#   -d : <debug> (string)
#   -e : <env> (string)
#   -a : <app name> (string)
#   -b : <catalog> (string)
#   -o : <consumer org> (string)
#   -p : <provider org> (string)
#   -f : <api yaml> (string)
#   -f : <product yaml> (string)
##*******************************************************************************
CURRENT_DIR=$(dirname $0)

TICK="\xE2\x9C\x85"
CROSS="\xE2\x9D\x8C"

OUTPUT=""

##*******************************************************************************
## Check parameters
##*******************************************************************************

while getopts "c:s:r:d:e:a:b:o:p:f:F:" opt; do
  case ${opt} in
    c ) APIC_PIPELINE_CLIENT_CRED="$OPTARG"
      ;;
    s ) APIC_SECRET="$OPTARG"
      ;;
    r ) RELEASE="$OPTARG"
      ;;
    d ) DEBUG="$OPTARG"
      ;;
    e ) ENVIRONMENT="$OPTARG"
      ;;
    a ) APP="$OPTARG"
      ;;
    b ) CATALOG="$OPTARG"
      ;;
    o ) CONSUMER_ORG="$OPTARG"
      ;;
    p ) PROVIDER_ORG="$OPTARG"
      ;;
    f ) API_YAML="$OPTARG"
      ;;
    F ) PRODUCT_YAML="$OPTARG"
      ;;
    \? ) usage; exit
      ;;
  esac
done

if [[ -z "$APIC_PIPELINE_CLIENT_CRED" ||
   -z "$APIC_SECRET" ||
   -z "$RELEASE" ||
   -z "$DEBUG" ||
   -z "$ENVIRONMENT" ||
   -z "$APP" ||
   -z "$CATALOG" ||
   -z "$CONSUMER_ORG" ||
   -z "$PROVIDER_ORG" ||
   -z "$API_YAML" ||
   -z "$PRODUCT_YAML" ]]; then
  echo -e "[ERROR] Please supply all parameters"
  exit 1
fi


function handle_res {
  local body=$1
  local status=$(echo ${body} | $JQ -r ".status")
  $DEBUG && echo "[DEBUG] res body: ${body}"
  $DEBUG && echo "[DEBUG] res status: ${status}"
  if [[ $status == "null" ]]; then
    OUTPUT="${body}"
  elif [[ $status == "400" ]]; then
    if [[ $body == *"already exists"* || $body == *"already subscribed"* ]]; then
      OUTPUT="${body}"
      echo "[INFO]  Resource already exists, continuing..."
    else
      echo -e "[ERROR] ${CROSS} Got 400 bad request"
      exit 1
    fi
  elif [[ $status == "409" ]]; then
    OUTPUT="${body}"
    echo "[INFO]  Resource already exists, continuing..."
  else
    echo -e "[ERROR] ${CROSS} Request failed: ${body}..."
    exit 1
  fi
}


##*******************************************************************************
## JQ Configuration
##*******************************************************************************

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
  echo "[DEBUG] jq not found, installing jq..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    $DEBUG && printf "on linux..."
    wget --quiet -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
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

echo "[INFO]  jq version: $($JQ --version)"

##*******************************************************************************
## Cluster Info and Bearer Token
##*******************************************************************************

# Gather info from cluster resources
echo "[INFO]  Gathering cluster info..."

PLATFORM_API_EP=$(oc get route ${RELEASE}-mgmt-platform-api -o jsonpath="{.spec.host}")
[[ -z $PLATFORM_API_EP ]] && echo -e "[ERROR] ${CROSS} APIC platform api route doesn't exit" && exit 1
$DEBUG && echo "[DEBUG] PLATFORM_API_EP=${PLATFORM_API_EP}"

echo -e "[INFO]  ${TICK} Cluster info gathered"

# Grab bearer token
echo "[INFO]  Getting bearer token..."
"${CURRENT_DIR}"/get-bearer-token.sh -c "$APIC_PIPELINE_CLIENT_CRED" -a "$APIC_SECRET" -r "$RELEASE"

TOKEN=$(cat token.json)
rm token.json
$DEBUG && echo "[DEBUG] Bearer token: ${TOKEN}"

##*******************************************************************************
## Drafting and publishing API and Product
##*******************************************************************************

# Get product and api versions
API_VER=$(grep 'version:' "${API_YAML}" | head -1 | awk '{print $2}')
PRODUCT_VER=$(grep 'version:' "${PRODUCT_YAML}" | head -1 | awk '{print $2}')
PRODUCT=$(grep 'name:' ${CURRENT_DIR}/product.yaml | head -1 | awk '{print $2}')

printf "\n[INFO] API VERSION %s" "$API_VER"
printf "\n[INFO] PRODUCT VERSION %s" "$PRODUCT_VER"
printf "\n[INFO] ENVIRONMENT %s" "$ENVIRONMENT"
printf "\n[INFO] ORG %s\n" "$PROVIDER_ORG"
printf "\n[INFO] CATALOG %s\n" "$CATALOG"

# Draft product first for dev, straight to publish for test
if [[ $ENVIRONMENT == "dev" ]]; then

  # Does product already exist
  RES=$(curl -kLsS https://"$PLATFORM_API_EP"/api/orgs/$PROVIDER_ORG/drafts/draft-products \
    -H "accept: application/json" \
    -H "authorization: Bearer $TOKEN")

  handle_res "${RES}"

  $DEBUG && echo "[DEBUG] output: ${OUTPUT}"
  MATCHING_PRODUCT=$(echo ${OUTPUT} | $JQ -r '.results[] | select(.name == "'$PRODUCT'" and .version == "'$PRODUCT_VER'")')
  $DEBUG && echo "[DEBUG] matching product: ${MATCHING_PRODUCT}"

  echo "[INFO] Checking for existing product..."
  if [[ ! $MATCHING_PRODUCT || $MATCHING_PRODUCT == "null" ]]; then
    # Create draft product
    echo "[INFO]  Creating draft product in org '$PROVIDER_ORG'..."

    echo "https://$PLATFORM_API_EP/api/orgs/$PROVIDER_ORG/drafts/draft-products"
    RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/orgs/$PROVIDER_ORG/drafts/draft-products \
      -H "accept: application/json" \
      -H "authorization: Bearer ${TOKEN}" \
      -H "content-type: multipart/form-data" \
      -F "openapi=@${API_YAML};type=application/yaml" \
      -F "product=@${PRODUCT_YAML};type=application/yaml")
    echo $RES
    handle_res "${RES}"
    echo -e "[INFO]  ${TICK} Draft product created in org '$PROVIDER_ORG'"
  else
    # Replace draft product
    echo "[INFO]  Matching product found, replacing draft product in org '$PROVIDER_ORG'..."
    RES=$(curl -kLsS -X PATCH https://$PLATFORM_API_EP/api/orgs/$PROVIDER_ORG/drafts/draft-products/$PRODUCT/$PRODUCT_VER \
      -H "accept: application/json" \
      -H "authorization: Bearer ${TOKEN}" \
      -H "content-type: multipart/form-data" \
      -F "openapi=@${API_YAML};type=application/yaml" \
      -F "product=@${PRODUCT_YAML};type=application/yaml")

    echo $RES
    handle_res "${RES}"
    echo -e "[INFO]  ${TICK} Draft product replaced in org '$PROVIDER_ORG'"
  fi

  # Get product url
  $DEBUG && echo "[DEBUG] Getting product url..."
  RES=$(curl -kLsS https://$PLATFORM_API_EP/api/orgs/$PROVIDER_ORG/drafts/draft-products \
    -H "accept: application/json" \
    -H "authorization: Bearer ${TOKEN}")
  handle_res "${RES}"
  DRAFT_PRODUCT_URL=$(echo ${OUTPUT} | $JQ -r '.results[] | select(.name == "'$PRODUCT'" and .version == "'$PRODUCT_VER'").url')
  if [[ $DRAFT_PRODUCT_URL == "null" ]]; then
    echo -e "[ERROR] ${CROSS} Couldn't get product url"
    exit 1
  fi
  $DEBUG && echo "[DEBUG] Product url: ${DRAFT_PRODUCT_URL}"
  echo -e "[INFO]  ${TICK} Got product url"

  # Get gateway service url
  echo "[INFO]  Getting gateway service url..."
  RES=$(curl -kLsS https://$PLATFORM_API_EP/api/orgs/$PROVIDER_ORG/gateway-services \
    -H "accept: application/json" \
    -H "authorization: Bearer ${TOKEN}")
  handle_res "${RES}"
  GW_URL=$(echo "${OUTPUT}" | $JQ -r ".results[0].integration_url")
  $DEBUG && echo "[DEBUG] Gateway service url: ${GW_URL}"
  echo -e "[INFO]  ${TICK} Got gateway service url"

  # Stage draft product
  echo "[INFO]  Staging draft product..."
  RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/catalogs/$PROVIDER_ORG/$CATALOG/stage-draft-product \
    -H "accept: application/json" \
    -H "authorization: Bearer ${TOKEN}" \
    -H "content-type: application/json" \
    -d "{
    \"gateway_service_urls\": [\"${GW_URL}\"],
    \"draft_product_url\": \"${DRAFT_PRODUCT_URL}\"
  }")
  handle_res "${RES}"
  echo -e "[INFO]  ${TICK} Draft product staged"

  # Publish draft product
  echo "[INFO]  Publishing draft product..."
  RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/catalogs/$PROVIDER_ORG/$CATALOG/publish-draft-product \
    -H "accept: application/json" \
    -H "authorization: Bearer ${TOKEN}" \
    -H "content-type: application/json" \
    -d "{
    \"gateway_service_urls\": [\"${GW_URL}\"],
    \"draft_product_url\": \"${DRAFT_PRODUCT_URL}\"
  }")
  handle_res "${RES}"
  echo -e "[INFO]  ${TICK} Draft product published"
else
  # Publish product
  echo "[INFO]  Publishing product..."
  RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/catalogs/$PROVIDER_ORG/$CATALOG/publish \
    -H "accept: application/json" \
    -H "authorization: Bearer ${TOKEN}" \
    -H "content-type: multipart/form-data" \
    -F "openapi=@${API_YAML};type=application/yaml" \
    -F "product=@${PRODUCT_YAML};type=application/yaml")
  handle_res "${RES}"
  echo -e "[INFO]  ${TICK} Product published"
fi

##*******************************************************************************
## Subscription
##*******************************************************************************

# Get product url
echo "[INFO] Getting url for product $PRODUCT..."
RES=$(curl -kLsS https://$PLATFORM_API_EP/api/catalogs/$PROVIDER_ORG/$CATALOG/products/$PRODUCT \
  -H "accept: application/json" \
  -H "authorization: Bearer ${TOKEN}")
handle_res "${RES}"
PRODUCT_URL=$(echo "${OUTPUT}" | $JQ -r ".results[0].url")
$DEBUG && echo "[DEBUG] Product url: ${PRODUCT_URL}"
echo -e "[INFO] ${TICK} Got product url"

# Create an subscription
echo "[INFO] Creating subscription..."
echo "REST API - https://$PLATFORM_API_EP/api/apps/$PROVIDER_ORG/$CATALOG/$CONSUMER_ORG/$APP/subscriptions"
RES=$(curl -kLsS -X POST https://$PLATFORM_API_EP/api/apps/$PROVIDER_ORG/$CATALOG/$CONSUMER_ORG/$APP/subscriptions \
  -H "accept: application/json" \
  -H "authorization: Bearer ${TOKEN}" \
  -H "content-type: application/json" \
  -d "{
    \"product_url\": \"${PRODUCT_URL}\",
    \"plan\": \"default-plan\"
}")
handle_res "${RES}"
echo -e "[INFO] ${TICK} Subscription created"