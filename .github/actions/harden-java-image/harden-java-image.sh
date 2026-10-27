#!/usr/bin/env bash
set -euo pipefail

IMAGE=${IMAGE:?IMAGE is required}
BLOCK_COMPROMISED_CERTIFICATES=${BLOCK_COMPROMISED_CERTIFICATES:-true}
ENABLE_REVOCATION=${ENABLE_REVOCATION:-false}
DEFAULT_TRUSTSTORE_PASSWORD=changeit
TARGET_TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD:-$DEFAULT_TRUSTSTORE_PASSWORD}
ROOT_CERTIFICATE_COUNT=4
CERTIFICATE_REMOVER_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/RemoveCertificates.java"

log() {
  printf '[java-image-hardening] %s\n' "$*"
}

case "$BLOCK_COMPROMISED_CERTIFICATES" in
  true|false) ;;
  *) echo "::error::block_compromised_certificates must be true or false"; exit 1 ;;
esac

case "$ENABLE_REVOCATION" in
  true|false) ;;
  *) echo "::error::enable_revocation must be true or false"; exit 1 ;;
esac

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "false" && "$ENABLE_REVOCATION" == "false" ]]; then
  log "Root certificate removal and revocation checks are both disabled; leaving $IMAGE unchanged"
  exit 0
fi

if [[ "$IMAGE" != *:* || "$IMAGE" == *@* ]]; then
  echo "::error::The image must use a mutable name:tag reference: $IMAGE"
  exit 1
fi

work_dir=$(mktemp -d)
source_tag="laa-ccms-java-hardening-source:$$"
containers=()

cleanup() {
  local container
  set +u
  for container in "${containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  set -u
  docker image rm "$source_tag" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

create_container() {
  local image=$1
  created_container=$(docker create "$image")
  containers+=("$created_container")
}

list_truststores() {
  local container=$1
  docker export "$container" |
    tar -tf - |
    sed 's#^\./##' |
    grep -E '(^|/)(jre/)?lib/security/cacerts$' |
    sort -u || true
}

run_certificate_remover() {
  local mode=$1
  local truststore=$2
  local source_password=$3
  SOURCE_TRUSTSTORE_PASSWORD=$source_password \
    TARGET_TRUSTSTORE_PASSWORD=$TARGET_TRUSTSTORE_PASSWORD \
    java -cp "$work_dir/certificate-remover" \
      RemoveCertificates "$mode" "$truststore"
}

find_source_password() {
  local truststore=$1
  local password

  for password in "$TARGET_TRUSTSTORE_PASSWORD" "$DEFAULT_TRUSTSTORE_PASSWORD"; do
    if keytool -list -keystore "$truststore" -storepass "$password" >/dev/null 2>&1; then
      source_password=$password
      return 0
    fi
  done
  return 1
}

docker image inspect "$IMAGE" >/dev/null
log "Starting hardening for $IMAGE"
log "Configuration: remove affected root certificates=$BLOCK_COMPROMISED_CERTIFICATES, enable revocation=$ENABLE_REVOCATION"
log "Following OpenJDK guidance to remove $ROOT_CERTIFICATE_COUNT root certificates"
if [[ -n "${TRUSTSTORE_PASSWORD:-}" ]]; then
  log "Hardened JVM truststores will use the configured application truststore password"
else
  log "No application truststore password was configured; using the standard cacerts password"
fi

echo "::group::Discover JVM truststores"
create_container "$IMAGE"
source_container=$created_container
truststores=()
while IFS= read -r truststore; do
  truststores+=("$truststore")
done < <(list_truststores "$source_container")
if [[ "${#truststores[@]}" -eq 0 ]]; then
  log "No JVM cacerts truststores were discovered"
else
  log "Found ${#truststores[@]} JVM truststore(s):"
  printf '  - /%s\n' "${truststores[@]}"
fi
echo "::endgroup::"

mkdir -p "$work_dir/rootfs"
printf 'FROM %s\n' "$source_tag" > "$work_dir/Dockerfile"

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "true" ]]; then
  if [[ "${#truststores[@]}" -eq 0 ]]; then
    echo "::error::No JVM cacerts truststore was found in $IMAGE"
    exit 1
  fi

  mkdir -p "$work_dir/certificate-remover"
  javac -source 8 -target 8 -Xlint:-options \
    -d "$work_dir/certificate-remover" \
    "$CERTIFICATE_REMOVER_SOURCE"

  for truststore in "${truststores[@]}"; do
    if [[ "$truststore" == /* || "$truststore" == *..* || "$truststore" =~ [[:space:]] ]]; then
      echo "::error::Unsupported JVM truststore path in $IMAGE: $truststore"
      exit 1
    fi
    destination="$work_dir/rootfs/$truststore"
    mkdir -p "$(dirname "$destination")"
    docker cp -L "$source_container:/$truststore" "$destination"

    if ! find_source_password "$destination"; then
      echo "::error::Unable to read JVM truststore /$truststore with the configured or standard cacerts password"
      exit 1
    fi

    removal_output=$(run_certificate_remover remove "$destination" "$source_password")
    removed_count=0
    while IFS=$'\t' read -r record alias common_name; do
      if [[ "$record" == "REMOVED" ]]; then
        log "Removed '$common_name' (alias '$alias') from /$truststore"
      elif [[ "$record" == "REMOVED_COUNT" ]]; then
        removed_count=$alias
      fi
    done <<< "$removal_output"
    log "Patched /$truststore: removed $removed_count affected root certificate(s); all $ROOT_CERTIFICATE_COUNT subjects are absent"
    printf 'COPY rootfs/%s /%s\n' "$truststore" "$truststore" >> "$work_dir/Dockerfile"
  done
else
  log "Affected root certificate removal is disabled; JVM truststores will not be changed"
fi

if [[ "$ENABLE_REVOCATION" == "true" ]]; then
  mkdir -p "$work_dir/rootfs/opt/laa-java-security"
  printf 'ocsp.enable=true\n' > "$work_dir/rootfs/opt/laa-java-security/revocation.security"
  printf '%s\n' \
    'COPY rootfs/opt/laa-java-security/revocation.security /opt/laa-java-security/revocation.security' \
    >> "$work_dir/Dockerfile"

  java_tool_options=$(
    docker image inspect \
      --format '{{range .Config.Env}}{{println .}}{{end}}' \
      "$IMAGE" |
      sed -n 's/^JAVA_TOOL_OPTIONS=//p' |
      tail -n 1
  )
  if [[ -n "$java_tool_options" ]]; then
    log "Preserving the image's existing JAVA_TOOL_OPTIONS while adding revocation settings"
  else
    log "The image has no existing JAVA_TOOL_OPTIONS; adding revocation settings"
  fi
  revocation_options=(
    '-Dcom.sun.net.ssl.checkRevocation=true'
    '-Dcom.sun.security.enableCRLDP=true'
    '-Djava.security.properties=/opt/laa-java-security/revocation.security'
  )
  for option in "${revocation_options[@]}"; do
    if [[ " $java_tool_options " != *" $option "* ]]; then
      java_tool_options="${java_tool_options:+$java_tool_options }$option"
    fi
  done

  if [[ "$java_tool_options" == *$'\n'* ]]; then
    echo "::error::JAVA_TOOL_OPTIONS must not contain newlines"
    exit 1
  fi
  escaped_options=${java_tool_options//\\/\\\\}
  escaped_options=${escaped_options//\"/\\\"}
  escaped_options=${escaped_options//\$/\\\$}
  printf 'ENV JAVA_TOOL_OPTIONS="%s"\n' "$escaped_options" >> "$work_dir/Dockerfile"
  log "Configured CRL distribution point and OCSP revocation checks"
else
  log "JVM certificate revocation checks remain disabled"
fi

echo "::group::Rebuild hardened image"
log "Creating a metadata-preserving overlay layer and replacing local tag $IMAGE"
docker tag "$IMAGE" "$source_tag"
docker buildx build --load --tag "$IMAGE" "$work_dir"
echo "::endgroup::"

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "true" ]]; then
  echo "::group::Verify hardened image"
  create_container "$IMAGE"
  verification_container=$created_container
  for truststore in "${truststores[@]}"; do
    verified_file="$work_dir/verified/$truststore"
    mkdir -p "$(dirname "$verified_file")"
    docker cp -L "$verification_container:/$truststore" "$verified_file"
    run_certificate_remover verify "$verified_file" "$TARGET_TRUSTSTORE_PASSWORD"
    log "Verified all $ROOT_CERTIFICATE_COUNT affected root subjects are absent from /$truststore"
  done
  echo "::endgroup::"
fi

log "Successfully hardened $IMAGE"
