#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FINGERPRINT_FILE="$ACTION_DIR/emudhra-blocked.certs"
IMAGE=${IMAGE:?IMAGE is required}
BLOCK_COMPROMISED_CERTIFICATES=${BLOCK_COMPROMISED_CERTIFICATES:-true}
ENABLE_REVOCATION=${ENABLE_REVOCATION:-false}
FINGERPRINT_COUNT=$(grep -Ec '^[A-F0-9]{64}$' "$FINGERPRINT_FILE")

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
  log "Certificate blocking and revocation checks are both disabled; leaving $IMAGE unchanged"
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
  for container in "${containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  docker image rm "$source_tag" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

create_container() {
  local image=$1
  created_container=$(docker create "$image")
  containers+=("$created_container")
}

list_blocklists() {
  local container=$1
  docker export "$container" |
    tar -tf - |
    sed 's#^\./##' |
    grep -E '(^|/)(blocked|blacklisted)\.certs$' |
    sort -u || true
}

append_fingerprints() {
  local blocklist=$1
  local fingerprint

  if [[ -s "$blocklist" ]] && [[ $(tail -c 1 "$blocklist" | wc -l) -eq 0 ]]; then
    printf '\n' >> "$blocklist"
  fi

  while IFS= read -r fingerprint; do
    [[ "$fingerprint" =~ ^[A-F0-9]{64}$ ]] || continue
    if ! grep -Fqx "$fingerprint" "$blocklist"; then
      printf '%s\n' "$fingerprint" >> "$blocklist"
    fi
  done < "$FINGERPRINT_FILE"
}

verify_fingerprints() {
  local blocklist=$1
  local fingerprint
  local count

  while IFS= read -r fingerprint; do
    [[ "$fingerprint" =~ ^[A-F0-9]{64}$ ]] || continue
    count=$(grep -Fxc "$fingerprint" "$blocklist" || true)
    if [[ "$count" -ne 1 ]]; then
      echo "::error::Expected fingerprint $fingerprint exactly once in $blocklist, found $count"
      return 1
    fi
  done < "$FINGERPRINT_FILE"
}

docker image inspect "$IMAGE" >/dev/null
log "Starting hardening for $IMAGE"
log "Configuration: block compromised certificates=$BLOCK_COMPROMISED_CERTIFICATES, enable revocation=$ENABLE_REVOCATION"
log "Using $FINGERPRINT_COUNT compromised certificate fingerprints from the bundled blocklist"

echo "::group::Discover JVM certificate blocklists"
create_container "$IMAGE"
source_container=$created_container
blocklists=()
while IFS= read -r blocklist; do
  blocklists+=("$blocklist")
done < <(list_blocklists "$source_container")
if [[ "${#blocklists[@]}" -eq 0 ]]; then
  log "No JVM blocked.certs or blacklisted.certs files were discovered"
else
  log "Found ${#blocklists[@]} JVM certificate blocklist(s):"
  printf '  - /%s\n' "${blocklists[@]}"
fi
echo "::endgroup::"

mkdir -p "$work_dir/rootfs"
printf 'FROM %s\n' "$source_tag" > "$work_dir/Dockerfile"

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "true" ]]; then
  if [[ "${#blocklists[@]}" -eq 0 ]]; then
    echo "::error::No JVM blocked.certs or blacklisted.certs file was found in $IMAGE"
    exit 1
  fi

  for blocklist in "${blocklists[@]}"; do
    if [[ "$blocklist" == /* || "$blocklist" == *..* || "$blocklist" =~ [[:space:]] ]]; then
      echo "::error::Unsupported JVM blocklist path in $IMAGE: $blocklist"
      exit 1
    fi
    destination="$work_dir/rootfs/$blocklist"
    mkdir -p "$(dirname "$destination")"
    docker cp -L "$source_container:/$blocklist" "$destination"
    entries_before=$(awk '/^[A-F0-9]{64}$/ { entries[$0] = 1 } END { print length(entries) }' "$destination")
    append_fingerprints "$destination"
    verify_fingerprints "$destination"
    entries_after=$(awk '/^[A-F0-9]{64}$/ { entries[$0] = 1 } END { print length(entries) }' "$destination")
    log "Patched /$blocklist: added $((entries_after - entries_before)) missing fingerprint(s); all $FINGERPRINT_COUNT affected fingerprints verified"
    printf 'COPY rootfs/%s /%s\n' "$blocklist" "$blocklist" >> "$work_dir/Dockerfile"
  done
else
  log "Compromised certificate blocking is disabled; existing JVM blocklists will not be changed"
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
  for blocklist in "${blocklists[@]}"; do
    verified_file="$work_dir/verified/$blocklist"
    mkdir -p "$(dirname "$verified_file")"
    docker cp -L "$verification_container:/$blocklist" "$verified_file"
    verify_fingerprints "$verified_file"
    log "Verified all $FINGERPRINT_COUNT affected fingerprints in /$blocklist"
  done
  echo "::endgroup::"
fi

log "Successfully hardened $IMAGE"
