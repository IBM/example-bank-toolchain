#!/usr/bin/env bash

if [[ $PIPELINE_DEBUG == 1 ]]; then
  pwd
  env
  trap env EXIT
  set -x
fi

source "${ONE_PIPELINE_PATH}/tools/retry"

mkdir -p "${WORKSPACE}/__cr_va__"
export VA_SCAN_DIR="${WORKSPACE}/__cr_va__"

artifact_list="${WORKSPACE}/images_for_va_scan"
touch "$artifact_list"

#
# if pipelinectl's list_artifacts and load_artifact are available,
# try to use those to get artifacts with image type
#
if which list_artifacts >/dev/null; then
  list_artifacts | while IFS= read -r artifact; do
    image="$(load_artifact "$artifact" "name")"
    type="$(load_artifact "$artifact" "type")"
    digest="$(load_artifact "$artifact" "digest")"

    if [ "$type" == "image" ]; then
      echo "$artifact $image $digest" >>"$artifact_list"
    fi
  done
fi

#
# if pipelinectl is not available or
# list_artifacts produced an empty list
# try to get the artifact in the legacy way
#
if [ -z "$(cat "$artifact_list")" ]; then
  ALL_IMAGES=( "$(cat /config/cp-user-service-image)" "$(cat /config/cp-transaction-service-image)" "$(cat /config/cp-simulator-service-image)" )
  ALL_DIGESTS=( "$(cat /config/cp-user-service-digest)" "$(cat /config/cp-transaction-service-digest)" "$(cat /config/cp-simulator-service-digest)" )
  for i in {0...2}; do
    image="${ALL_IMAGES[$i]}"
    image_digest="${ALL_DIGESTS[$i]}"
    echo "app-artifact $image $image_digest" >>"$artifact_list"
  done
fi

#
# prepare for VA scan check
#

_toolchain_read() {
  jq -r "$1" "$TOOLCHAIN_CONFIG_JSON" | tr -d '\n'
}

export TOOLCHAIN_CONFIG_JSON="/toolchain/toolchain.json"
export REGISTRY_REGION
export TOOLCHAIN_REGION
TOOLCHAIN_REGION=$(_toolchain_read '.region_id' | awk -F: '{print $3}')

BREAK_GLASS=$(get_env break_glass "")
if [[ -n $BREAK_GLASS ]]; then
  echo "Break-Glass mode is on, skipping the rest of the task..."
  exit 3
fi

ibmcloud_login() {
  local -r ibmcloud_api=$(get_env ibmcloud-api "https://cloud.ibm.com")

  ibmcloud config --check-version false
  # Use `cr-va-ibmcloud-api-key` if present, if not, fall back to `ibmcloud-api-key`
  local SECRET_PATH="/config/ibmcloud-api-key"
  if [[ -s "/config/cr-va-ibmcloud-api-key" ]]; then
    SECRET_PATH="/config/cr-va-ibmcloud-api-key"
  fi
  ibmcloud login -a "$ibmcloud_api" -r "$TOOLCHAIN_REGION" --apikey @"$SECRET_PATH"
  ibmcloud target -g "$(get_env dev-resource-group)"
}

retry 5 10 ibmcloud_login

exit_code=$?

if [ $exit_code -ne 0 ]; then
  echo "Error during the ibmcloud login. There might be an ibmcloud outage."
  printf "For further information check: https://cloud.ibm.com/status\n" >&2
fi

ibmcloud_region_set() {
  ibmcloud cr region-set "$1"
  ibmcloud cr info
}

ibmcloud_image_inspect() {
  echo -e "Details for image: $1"
  ibmcloud cr image-inspect "$1"
}

find_registry_region() {
  # Find the ibmcloud container registry region
  # https://cloud.ibm.com/docs/services/Registry?topic=registry-registry_overview#registry_regions_local
  if [[ $1 =~ ^registry\.[a-z]*.bluemix.net$ ]]; then
    # deprecated domain name
    REGISTRY_REGION=$(echo "$1" | awk -F. '{print $2}')
    if [ "$REGISTRY_REGION" == "ng" ]; then
      export REGISTRY_REGION="us-south"
    fi
  else
    REGISTRY_REGION=$(echo "$1" | awk -F. '{print $1}')
    if [ "$REGISTRY_REGION" == "jp" ]; then
      export REGISTRY_REGION="ap-north"
    elif [ "$REGISTRY_REGION" == "au" ]; then
      export REGISTRY_REGION="ap-south"
    elif [ "$REGISTRY_REGION" == "de" ]; then
      export REGISTRY_REGION="eu-central"
    elif [ "$REGISTRY_REGION" == "uk" ]; then
      export REGISTRY_REGION="uk-south"
    elif [ "$REGISTRY_REGION" == "us" ]; then
      export REGISTRY_REGION="us-south"
    elif [ "$REGISTRY_REGION" == "stg" ]; then
      export REGISTRY_REGION="us-south"
    elif [ "$REGISTRY_REGION" == "jp2" ]; then
      export REGISTRY_REGION="jp-osa"
    elif [ "$REGISTRY_REGION" == "fr2" ]; then
      export REGISTRY_REGION="eu-fr2"
    elif [ "$REGISTRY_REGION" == "ca" ]; then
      export REGISTRY_REGION="ca-tor"
    else
      echo "No IBM Cloud Container Registry region found for the registry url $1"
      exit 1
    fi
  fi
}

check_va_scan_result() {
  name=$1
  image=$2
  digest=$3

  local input_image_url
  input_image_url=$(echo "$image" | awk -F: '{print $1}')

  # Parse the image input to find information (region, namespace, image name, tag & digest/sha)
  local input_registry_url
  input_registry_url=$(echo "$input_image_url" | awk -F/ '{print $1}')

  find_registry_region "$input_registry_url"

  # Log container registry to the appropriate region
  retry 5 10 ibmcloud_region_set "$REGISTRY_REGION"

  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Error during the region set. There might be an ibmcloud outage."
    printf "For further information check: https://cloud.ibm.com/status\n" >&2
  fi

  local pipeline_image_url="$input_image_url@$digest"

  # inspect the image to ensure it exists
  retry 5 10 ibmcloud_image_inspect "${pipeline_image_url}"

  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Error during image inspect. There might be an ibmcloud outage."
    printf "For further information check: https://cloud.ibm.com/status\n" >&2
  fi

  va_report_json="${VA_SCAN_DIR}/${name}_va-report.json"

  # Loop until the scan has been performed
  echo -e "Checking vulnerabilities in image: ${pipeline_image_url}"

  retry_count=$(get_env "va-scan-retry-count" 30)
  retry_sleep=$(get_env "va-scan-retry-sleep" 10)

  for ((iter = 1; iter < retry_count; iter++)); do
    set +e
    status=""
    ibmcloud cr va -o json "${pipeline_image_url}" >"${va_report_json}" 2>/dev/null
    # ibmcloud cr va returns a non valid json output if image not yet scanned
    if jq -r -e '.[0].status' "${va_report_json}" >/dev/null 2>&1; then
      status=$(jq -r '.[0].status' "${va_report_json}")
    fi
    if [ -z "$status" ]; then
      status="UNSCANNED"
    fi
    set -e

    echo "VA scan status is ${status}"

    # Possible status from Vulnerability Advisor: OK, WARN, FAIL, UNSUPPORTED, INCOMPLETE, UNSCANNED
    # cf https://cloud.ibm.com/apidocs/container-registry/va#get-the-vulnerability-assessment-for-the-list-of-r
    if [[ ${status} != "INCOMPLETE" && ${status} != "UNSCANNED" ]]; then
      # status is one of the terminated scan action - break the loop
      break
    fi

    echo -e "${iter} STATUS ${status} : A vulnerability report was not found for the specified image."
    echo "Either the image doesn't exist or the scan hasn't completed yet. "
    echo "Waiting 10s for scan to complete..."

    sleep "$retry_sleep"
  done

  set +e

  echo "Showing extended vulnerability assessment report for ${pipeline_image_url}"
  ibmcloud cr va -e "${pipeline_image_url}" || true

  if [ -z "$status" ]; then
    status="UNSCANNED"
  fi
  set -e

  export VA_REPORT_JSON=$va_report_json
  export STATUS=$status
}

#
# prepare results and statuses to report
#
ARTIFACT_SCAN_RESULTS_JSON_PATH="${WORKSPACE}/artifact-scan-report.json"
echo "[]" | jq '' >"${ARTIFACT_SCAN_RESULTS_JSON_PATH}"

VA_SCAN_STATUSES_PATH="${VA_SCAN_DIR}/va_scan_statuses"

#
# Iterate over artifacts and check their VA scan status
#
while IFS= read -r artifact; do
  name="$(echo "$artifact" | awk '{print $1}')"
  image="$(echo "$artifact" | awk '{print $2}')"
  digest="$(echo "$artifact" | awk '{print $3}')"

  export VA_REPORT_JSON
  export STATUS

  check_va_scan_result "$name" "$image" "$digest"

  #
  # collect statuses
  #
  result="0"

  if [[ ${STATUS} == "OK" ]] || [[ ${STATUS} == "UNSUPPORTED" ]] || [[ ${STATUS} == "WARN" ]]; then
    echo "The vulnerability scan status is ${STATUS}"
    echo "success" >>"$VA_SCAN_STATUSES_PATH"
  else
    echo "ERROR: The vulnerability scan was not successful (status being ${STATUS})."
    echo "failure" >>"$VA_SCAN_STATUSES_PATH"
    result="1"
  fi

  #
  # collect scan artifacts into a single artifact JSON file
  #
  save_result scan-artifact "${VA_REPORT_JSON}"

  #
  # store result and attachment for asset-based evidence locker
  #
  stage_name="image_vulnerability_scan"
  save_artifact "${name}" "${stage_name}-result=${result}"
  save_result "${name}-${stage_name}-attachments" "${VA_REPORT_JSON}"

done <<<"$(cat "$artifact_list")"

cat "${ARTIFACT_SCAN_RESULTS_JSON_PATH}"

#
# check if any of the scans failed
#
if grep failure "${VA_SCAN_STATUSES_PATH}" >/dev/null; then
  exit 1
else
  exit 0
fi
