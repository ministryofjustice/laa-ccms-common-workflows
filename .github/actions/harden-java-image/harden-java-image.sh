#!/usr/bin/env bash
set -euo pipefail

IMAGE=${IMAGE:?IMAGE is required}
BLOCK_COMPROMISED_CERTIFICATES=${BLOCK_COMPROMISED_CERTIFICATES:-true}
ENABLE_REVOCATION=${ENABLE_REVOCATION:-false}
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
  local archive=$1
  tar -tf "$archive" |
    sed 's#^\./##' |
    grep -E '(^|/)(jre/)?lib/security/cacerts$' |
    sort -u || true
}

file_metadata() {
  local archive=$1
  local path=$2

  tar --numeric-owner -tvf "$archive" "$path" |
    awk '
      $2 ~ /^[0-9]+\/[0-9]+$/ {
        split($2, owner, "/")
        print owner[1] ":" owner[2] ":" $1
        found = 1
        exit
      }
      $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
        print $3 ":" $4 ":" $1
        found = 1
        exit
      }
      END {
        if (!found) {
          exit 1
        }
      }
    '
}

run_certificate_remover() {
  local mode=$1
  local file=$2
  java -cp "$work_dir/certificate-remover" \
    RemoveCertificates "$mode" "$file"
}

archive_contains() {
  local path=$1
  grep -Fqx -- "$path" "$work_dir/source-image-paths"
}

docker image inspect "$IMAGE" >/dev/null
log "Starting hardening for $IMAGE"
log "Configuration: remove affected root certificates=$BLOCK_COMPROMISED_CERTIFICATES, enable revocation=$ENABLE_REVOCATION"
log "Following OpenJDK guidance to remove $ROOT_CERTIFICATE_COUNT root certificates"
log "JVM truststores and container CA bundles used by Paketo will both be checked"
log "Existing file ownership and modes, plus JVM truststore formats and passwords, will be preserved"

echo "::group::Discover certificate stores"
create_container "$IMAGE"
source_container=$created_container
source_archive="$work_dir/source-image.tar"
docker export --output "$source_archive" "$source_container"
tar -tf "$source_archive" | sed 's#^\./##' > "$work_dir/source-image-paths"
truststores=()
while IFS= read -r truststore; do
  truststores+=("$truststore")
done < <(list_truststores "$source_archive")
if [[ "${#truststores[@]}" -eq 0 ]]; then
  log "No JVM cacerts truststores were discovered"
else
  log "Found ${#truststores[@]} JVM truststore(s):"
  printf '  - /%s\n' "${truststores[@]}"
fi

ssl_cert_file=$(
  docker image inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$IMAGE" |
    sed -n 's/^SSL_CERT_FILE=//p' |
    tail -n 1
)
os_ca_bundles=()
default_os_ca_bundle='etc/ssl/certs/ca-certificates.crt'
if archive_contains "$default_os_ca_bundle"; then
  os_ca_bundles+=("$default_os_ca_bundle")
  log "Found default container CA bundle /$default_os_ca_bundle"
else
  log "Default container CA bundle /$default_os_ca_bundle is not present"
fi
if [[ -n "$ssl_cert_file" ]]; then
  if [[ "$ssl_cert_file" != /* ||
        "$ssl_cert_file" == *..* ||
        "$ssl_cert_file" =~ [[:space:]] ]]; then
    echo "::error::Unsupported SSL_CERT_FILE path configured in $IMAGE: $ssl_cert_file"
    exit 1
  fi
  configured_os_ca_bundle=${ssl_cert_file#/}
  if ! archive_contains "$configured_os_ca_bundle"; then
    echo "::error::SSL_CERT_FILE is configured as $ssl_cert_file but that file is not present in $IMAGE"
    exit 1
  fi
  if [[ "$configured_os_ca_bundle" != "$default_os_ca_bundle" ]]; then
    os_ca_bundles+=("$configured_os_ca_bundle")
  fi
  log "Found image-configured SSL_CERT_FILE bundle $ssl_cert_file"
else
  log "The image does not configure SSL_CERT_FILE; Paketo will use its default CA bundle when present"
fi
echo "::endgroup::"

mkdir -p "$work_dir/rootfs"
printf 'FROM %s\n' "$source_tag" > "$work_dir/Dockerfile"

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "true" ]]; then
  if [[ "${#truststores[@]}" -eq 0 ]]; then
    echo "::error::No JVM cacerts truststore was found in $IMAGE"
    exit 1
  fi

  echo "::group::Remove affected root certificates"
  log "Compiling the certificate-store helper for Java 8 compatibility"
  mkdir -p "$work_dir/certificate-remover"
  javac -source 8 -target 8 -Xlint:-options \
    -d "$work_dir/certificate-remover" \
    "$CERTIFICATE_REMOVER_SOURCE"

  truststore_metadata_values=()
  for truststore in "${truststores[@]}"; do
    if [[ "$truststore" == /* || "$truststore" == *..* || "$truststore" =~ [[:space:]] ]]; then
      echo "::error::Unsupported JVM truststore path in $IMAGE: $truststore"
      exit 1
    fi
    metadata=$(file_metadata "$source_archive" "$truststore")
    truststore_metadata_values+=("$metadata")
    IFS=: read -r truststore_uid truststore_gid truststore_mode <<< "$metadata"
    log "Processing /$truststore (owner $truststore_uid:$truststore_gid, mode $truststore_mode)"
    destination="$work_dir/rootfs/$truststore"
    mkdir -p "$(dirname "$destination")"
    docker cp -L "$source_container:/$truststore" "$destination"

    if ! removal_output=$(run_certificate_remover remove "$destination"); then
      echo "::error::Unable to read or update JVM truststore /$truststore using a standard JDK truststore password"
      exit 1
    fi
    removed_count=0
    while IFS=$'\t' read -r record alias common_name; do
      if [[ "$record" == "REMOVED" ]]; then
        log "Removed '$common_name' (alias '$alias') from /$truststore"
      elif [[ "$record" == "REMOVED_COUNT" ]]; then
        removed_count=$alias
      fi
    done <<< "$removal_output"
    log "Patched /$truststore: removed $removed_count affected root certificate(s); all $ROOT_CERTIFICATE_COUNT subjects are absent"
    log "The overlay will preserve owner $truststore_uid:$truststore_gid and the existing file mode"
    printf 'COPY --chown=%s:%s rootfs/%s /%s\n' \
      "$truststore_uid" \
      "$truststore_gid" \
      "$truststore" \
      "$truststore" \
      >> "$work_dir/Dockerfile"
  done

  os_ca_bundle_metadata_values=()
  for os_ca_bundle in "${os_ca_bundles[@]}"; do
    if [[ "$os_ca_bundle" == /* || "$os_ca_bundle" == *..* || "$os_ca_bundle" =~ [[:space:]] ]]; then
      echo "::error::Unsupported container CA bundle path in $IMAGE: $os_ca_bundle"
      exit 1
    fi
    metadata=$(file_metadata "$source_archive" "$os_ca_bundle")
    os_ca_bundle_metadata_values+=("$metadata")
    IFS=: read -r bundle_uid bundle_gid bundle_mode <<< "$metadata"
    log "Processing /$os_ca_bundle (owner $bundle_uid:$bundle_gid, mode $bundle_mode)"
    destination="$work_dir/rootfs/$os_ca_bundle"
    mkdir -p "$(dirname "$destination")"
    docker cp -L "$source_container:/$os_ca_bundle" "$destination"

    if ! removal_output=$(run_certificate_remover remove-pem "$destination"); then
      echo "::error::Unable to read or update container CA bundle /$os_ca_bundle"
      exit 1
    fi
    removed_count=0
    while IFS=$'\t' read -r record value; do
      if [[ "$record" == "REMOVED_PEM" ]]; then
        log "Removed '$value' from /$os_ca_bundle"
      elif [[ "$record" == "REMOVED_COUNT" ]]; then
        removed_count=$value
      fi
    done <<< "$removal_output"
    log "Patched /$os_ca_bundle: removed $removed_count affected root certificate(s); all $ROOT_CERTIFICATE_COUNT subjects are absent"
    log "The overlay will preserve owner $bundle_uid:$bundle_gid and the existing file mode"
    printf 'COPY --chown=%s:%s rootfs/%s /%s\n' \
      "$bundle_uid" \
      "$bundle_gid" \
      "$os_ca_bundle" \
      "$os_ca_bundle" \
      >> "$work_dir/Dockerfile"
  done
  echo "::endgroup::"
else
  log "Affected root certificate removal is disabled; JVM truststores and container CA bundles will not be changed"
fi

if [[ "$ENABLE_REVOCATION" == "true" ]]; then
  echo "::group::Configure JVM certificate revocation"
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
  echo "::endgroup::"
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
  verification_archive="$work_dir/verified-image.tar"
  docker export --output "$verification_archive" "$verification_container"
  for index in "${!truststores[@]}"; do
    truststore=${truststores[$index]}
    verified_file="$work_dir/verified/$truststore"
    mkdir -p "$(dirname "$verified_file")"
    docker cp -L "$verification_container:/$truststore" "$verified_file"
    run_certificate_remover verify "$verified_file"
    log "Verified all $ROOT_CERTIFICATE_COUNT affected root subjects are absent from /$truststore"
    verified_metadata=$(file_metadata "$verification_archive" "$truststore")
    expected_metadata=${truststore_metadata_values[$index]}
    if [[ "$verified_metadata" != "$expected_metadata" ]]; then
      echo "::error::Truststore metadata changed for /$truststore: expected $expected_metadata, found $verified_metadata"
      exit 1
    fi
    log "Verified metadata for /$truststore is unchanged ($verified_metadata)"
  done
  for index in "${!os_ca_bundles[@]}"; do
    os_ca_bundle=${os_ca_bundles[$index]}
    verified_file="$work_dir/verified/$os_ca_bundle"
    mkdir -p "$(dirname "$verified_file")"
    docker cp -L "$verification_container:/$os_ca_bundle" "$verified_file"
    run_certificate_remover verify-pem "$verified_file"
    log "Verified all $ROOT_CERTIFICATE_COUNT affected root subjects are absent from /$os_ca_bundle"
    verified_metadata=$(file_metadata "$verification_archive" "$os_ca_bundle")
    expected_metadata=${os_ca_bundle_metadata_values[$index]}
    if [[ "$verified_metadata" != "$expected_metadata" ]]; then
      echo "::error::Container CA bundle metadata changed for /$os_ca_bundle: expected $expected_metadata, found $verified_metadata"
      exit 1
    fi
    log "Verified metadata for /$os_ca_bundle is unchanged ($verified_metadata)"
  done
  echo "::endgroup::"
fi

log "Successfully hardened $IMAGE: ${#truststores[@]} JVM truststore(s) and ${#os_ca_bundles[@]} container CA bundle(s) processed, revocation checks enabled=$ENABLE_REVOCATION"
