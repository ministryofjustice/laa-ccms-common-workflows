#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FINGERPRINT_FILE="$ACTION_DIR/emudhra-blocked.certs"
IMAGE=${IMAGE:?IMAGE is required}
BLOCK_COMPROMISED_CERTIFICATES=${BLOCK_COMPROMISED_CERTIFICATES:-true}
ENABLE_REVOCATION=${ENABLE_REVOCATION:-false}

case "$BLOCK_COMPROMISED_CERTIFICATES" in
  true|false) ;;
  *) echo "::error::block_compromised_certificates must be true or false"; exit 1 ;;
esac

case "$ENABLE_REVOCATION" in
  true|false) ;;
  *) echo "::error::enable_revocation must be true or false"; exit 1 ;;
esac

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "false" && "$ENABLE_REVOCATION" == "false" ]]; then
  echo "Java image hardening is disabled"
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
create_container "$IMAGE"
source_container=$created_container
blocklists=()
while IFS= read -r blocklist; do
  blocklists+=("$blocklist")
done < <(list_blocklists "$source_container")

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
    append_fingerprints "$destination"
    verify_fingerprints "$destination"
    printf 'COPY rootfs/%s /%s\n' "$blocklist" "$blocklist" >> "$work_dir/Dockerfile"
  done
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
fi

docker tag "$IMAGE" "$source_tag"
docker buildx build --load --tag "$IMAGE" "$work_dir"

if [[ "$BLOCK_COMPROMISED_CERTIFICATES" == "true" ]]; then
  create_container "$IMAGE"
  verification_container=$created_container
  for blocklist in "${blocklists[@]}"; do
    verified_file="$work_dir/verified/$blocklist"
    mkdir -p "$(dirname "$verified_file")"
    docker cp -L "$verification_container:/$blocklist" "$verified_file"
    verify_fingerprints "$verified_file"
  done
fi

echo "Hardened $IMAGE"
