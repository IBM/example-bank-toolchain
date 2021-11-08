#!/usr/bin/env bash

set -euo pipefail

if [[ "${PIPELINE_DEBUG:-0}" == 1 ]]; then
  set -x
  trap env EXIT
fi

get-icr-region() {
  case "$1" in
    ibm:yp:us-south)
      echo us
      ;;
    ibm:yp:eu-de)
      echo de
      ;;
    ibm:yp:eu-gb)
      echo uk
      ;;
    ibm:yp:jp-tok)
      echo jp
      ;;
    ibm:yp:jp-osa)
      echo jp2
      ;;
    ibm:yp:au-syd)
      echo au
      ;;
    *)
      echo "Unknown region: $1" >&2
      exit 1
      ;;
  esac
}

# curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
# add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
# apt-get update && apt-get install docker-ce-cli

set -e

IMAGE_NAME="$1"
IMAGE_TAG="$(date +%Y%m%d%H%M%S)-$(cat /config/git-branch)-$(cat /config/git-commit)"

BREAK_GLASS=$(cat /config/break_glass || echo "")

if [[ -n "$BREAK_GLASS" ]]; then
  ARTIFACTORY_URL="$(jq -r .parameters.repository_url /config/artifactory)"
  ARTIFACTORY_REGISTRY="$(sed -E 's~https://(.*)/?~\1~' <<<"$ARTIFACTORY_URL")"
  ARTIFACTORY_INTEGRATION_ID="$(jq -r .instance_id /config/artifactory)"
  IMAGE="$ARTIFACTORY_REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
  jq -j --arg instance_id "$ARTIFACTORY_INTEGRATION_ID" '.services[] | select(.instance_id == $instance_id) | .parameters.token' /toolchain/toolchain.json | docker login -u "$(jq -r '.parameters.user_id' /config/artifactory)" --password-stdin "$(jq -r '.parameters.repository_url' /config/artifactory)"
else
  ICR_REGISTRY_NAMESPACE="$(cat /config/registry-namespace)"
  ICR_REGISTRY_REGION="$(get-icr-region "$(cat /config/registry-region)")"
  IMAGE="$ICR_REGISTRY_REGION.icr.io/$ICR_REGISTRY_NAMESPACE/$IMAGE_NAME:$IMAGE_TAG"
  docker login -u iamapikey --password-stdin "$ICR_REGISTRY_REGION.icr.io" < /config/api-key

  # Create the namespace if needed to ensure the push will be can be successfull
  echo "Checking registry namespace: ${ICR_REGISTRY_NAMESPACE}"
  IBM_LOGIN_REGISTRY_REGION=$(cat /config/registry-region | awk -F: '{print $3}')
  ibmcloud login --apikey @/config/api-key -r "$IBM_LOGIN_REGISTRY_REGION"
  NS=$( ibmcloud cr namespaces | sed 's/ *$//' | grep -x "${ICR_REGISTRY_NAMESPACE}" ||: )

  if [ -z "${NS}" ]; then
      echo "Registry namespace ${ICR_REGISTRY_NAMESPACE} not found"
      ibmcloud cr namespace-add "${ICR_REGISTRY_NAMESPACE}"
      echo "Registry namespace ${ICR_REGISTRY_NAMESPACE} created."
  else
      echo "Registry namespace ${ICR_REGISTRY_NAMESPACE} found."
  fi
fi

DOCKER_BUILD_ARGS="-t $IMAGE"

#cDOCKER_BUILDKIT=1 docker build $DOCKER_BUILD_ARGS .
docker build -t "$IMAGE" -f "$2" .
docker push "${IMAGE}"

#optional tag
set +e
TAG="$(cat /config/custom-image-tag)"
set -e
if [[ "${TAG}" ]]; then
    #see build_setup script
    IFS=',' read -ra tags <<< "${TAG}"
    for i in "${!tags[@]}"
    do
        TEMP_TAG=${tags[i]}
        TEMP_TAG=$(echo "$TEMP_TAG" | sed -e 's/^[[:space:]]*//')
        echo "adding tag $i $TEMP_TAG"
        ADDITIONAL_IMAGE_TAG="$ICR_REGISTRY_REGION.icr.io"/"$ICR_REGISTRY_NAMESPACE"/"$IMAGE_NAME":"$TEMP_TAG"
        docker tag "$IMAGE" "$ADDITIONAL_IMAGE_TAG"
        docker push "$ADDITIONAL_IMAGE_TAG"
    done
fi

DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" | awk -F@ '{print $2}')"
echo -n "$DIGEST" > ../image-digest
echo -n "$IMAGE_TAG" > ../image-tags
echo -n "$IMAGE" > ../image

if which save_artifact >/dev/null; then
  save_artifact "$1"-image type=image "name=${IMAGE}" "digest=${DIGEST}"
fi

echo "$IMAGE" >${WORKSPACE}/"$1"-image
echo "$DIGEST" >${WORKSPACE}/"$1"-digest
echo "$IMAGE_TAG" >${WORKSPACE}/"$1"-tag
