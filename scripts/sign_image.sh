#!/usr/bin/env bash

export SIGNATURE_FILE
export IMAGE_SIGN_DIR
export USE_PIPELINECTL="true"

IBM_CLOUD_API_KEY="$(cat /config/ibmcloud-api-key)"
VAULT_SECRET="$(cat /config/signing-key)"
SIGNATURE_FILE="${WORKSPACE}/artifact-signature"
IMAGE_SIGN_DIR="${WORKSPACE}/__image_sign__"

mkdir -p "${IMAGE_SIGN_DIR}"
artifact_list="${IMAGE_SIGN_DIR}/images_for_image_sign"
touch "$artifact_list"

function import_gpg_key() {

  set -e

  yum install pinentry -y
  base64 -d <<< "${VAULT_SECRET}" >private_key.txt
  if [[ -s private_key.txt ]]; then
    echo "Base64 Conversion is successful...."
  else
    echo "Base64 Conversion is unsuccessful. Please check the key."
    exit 1
  fi

  gpg2 --import private_key.txt

}

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
      echo "$artifact $image $digest" >> "$artifact_list"
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
    echo "app-artifact-$i $image $image_digest" >> "$artifact_list"
    USE_PIPELINECTL="false"
  done
fi

set +e
BREAK_GLASS="$(cat /config/break_glass || echo "")"
if [[ -n "$BREAK_GLASS" ]]; then
  echo "Break-Glass mode is on, skipping the rest of the task...."
  exit 3
fi
export SECRET_PATH="/config/ibmcloud-api-key"
. "${ONE_PIPELINE_PATH}"/iam/get_token
source "${ONE_PIPELINE_PATH}/tools/retry"

echo "Proceeding with self signing...."


if import_gpg_key; then
    echo "GPG key import is successfull."
else
    echo "GPG key import failed. Please provide GPG key without passpharse."
    exit 1
fi

gpg2 --list-signatures
KEYS=$(gpg2 -k --with-colons)
TRIMMEDKEYS=$(echo "$KEYS" | tr -d '\n')
IFS=':' read -r -a TEMPARRAY <<< "$TRIMMEDKEYS"
FINGERPRINT="${TEMPARRAY[36]}"

sign_image() {
  name=$1
  image=$2
  digest=$3

  registry_url=$(echo "$image" | cut -f1 -d/)
  signing_dir="signing_${name}"
  mkdir "${signing_dir}"
  signing_key=${FINGERPRINT}

  if [[ "$signing_key" ]]; then
    echo "Signing image.... ${image} "
    skopeo copy docker://"${image}" docker://"${image}" --dest-creds iamapikey:"${IBM_CLOUD_API_KEY}" --src-creds iamapikey:"${IBM_CLOUD_API_KEY}" --sign-by "${signing_key}"
    exit_code=$?
  else
    echo "No key found. Unable to sign"
    return 1
  fi

  if [[ "$exit_code" == 0 ]]; then
    echo "No issues were found"
    image_name=$(echo "$image" | cut -d: -f1 | cut -d/ -f2,3)
    token=$(curl -s \
      -F "service=registry" \
      -F "grant_type=password" \
      -F "client_id=curlsig" \
      -F "username=iambearer" \
      -F "password=${IAM_ACCESS_TOKEN}" \
      -F "scope=repository:${image_name}:pull" \
      https://"${registry_url}"/oauth/token | jq -r .token)
    signatures=$(curl -s -H "Authorization: Bearer ${token}" "https://${registry_url}/extensions/v2/${image_name}/signatures/${digest}" | jq '.signatures')
    count=$(echo "${signatures}" | jq '. | length')
    index="$((count - 1))"
    echo "SIGNATURE INDEX ${index}"
    signature_data=$(echo "$signatures" | jq --arg jq_index "$index" '.[$jq_index|tonumber]')

    # create data for evidence
    signature_content=$(echo "${signature_data}" | jq -r '.content')
    echo -n "${signature_content}" > "${IMAGE_SIGN_DIR}/${name}_signature"
    return 0
  else
    echo "Signing failed."
    return 1
  fi
}

#
# Iterate over artifacts and sign them
#
while IFS= read -r artifact; do
  name="$(echo "$artifact" | awk '{print $1}')"
  image="$(echo "$artifact" | awk '{print $2}')"
  digest="$(echo "$artifact" | awk '{print $3}')"
  sign_image "$name" "$image" "$digest"
  exit_code=$?

  # capture signing success state
  status="success"
  if [ $exit_code != 0 ]; then
    status="failure"
  fi
  echo $status >> "${IMAGE_SIGN_DIR}/sign_statuses"

  # store signatures, or just an empty file
  signature="$(cat "${IMAGE_SIGN_DIR}/${name}_signature" 2> /dev/null || echo "")"
  save_result sign-artifact "${IMAGE_SIGN_DIR}/${name}_signature"

  if [ "$USE_PIPELINECTL" == "true" ]; then
    save_artifact "$name" "signature=${signature}"
    echo -e "$signature\n\n" >> "${WORKSPACE}/artifact-signature"
  else
    echo -e "$signature" >> "${WORKSPACE}/artifact-signature"
  fi

done <<< "$(cat "$artifact_list")"

#
# check if any of the signing processes failed
# and exit the script with the relevant exit code
#
if grep failure "${IMAGE_SIGN_DIR}/sign_statuses" >/dev/null; then
  exit 1
else
  exit 0
fi
