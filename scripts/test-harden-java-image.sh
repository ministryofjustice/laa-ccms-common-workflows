#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACTION_DIR="$ROOT_DIR/.github/actions/harden-java-image"
TEST_ID=$$
BASE_IMAGE="harden-java-image-test-base:$TEST_ID"
HARDENED_IMAGE="harden-java-image-test-hardened:$TEST_ID"
NO_JAVA_IMAGE="harden-java-image-test-no-java:$TEST_ID"
work_dir=$(mktemp -d)
containers=()

cleanup() {
  local container
  for container in "${containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  docker image rm "$BASE_IMAGE" "$HARDENED_IMAGE" "$NO_JAVA_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local value=$1
  local expected=$2
  [[ "$value" == *"$expected"* ]] || fail "Expected '$value' to contain '$expected'"
}

fingerprint_count=$(grep -Ec '^[A-F0-9]{64}$' "$ACTION_DIR/emudhra-blocked.certs")
unique_fingerprint_count=$(grep -E '^[A-F0-9]{64}$' "$ACTION_DIR/emudhra-blocked.certs" | sort -u | wc -l | tr -d ' ')
[[ "$fingerprint_count" -eq 16 ]] || fail "Expected 16 fingerprints, found $fingerprint_count"
[[ "$unique_fingerprint_count" -eq 16 ]] || fail "Expected 16 unique fingerprints, found $unique_fingerprint_count"

mkdir -p "$work_dir/base"
printf 'existing-modern-entry' > "$work_dir/base/blocked.certs"
printf 'existing-java-8-entry\n' > "$work_dir/base/blacklisted.certs"
cat > "$work_dir/base/Dockerfile" <<'EOF'
FROM scratch
COPY blocked.certs /opt/java/lib/security/blocked.certs
COPY blacklisted.certs /opt/java/jre/lib/security/blacklisted.certs
ENV JAVA_TOOL_OPTIONS="-Xmx256m"
LABEL test.metadata="preserved"
USER 1001
ENTRYPOINT ["/application"]
CMD ["serve"]
EOF
docker buildx build --load --tag "$BASE_IMAGE" "$work_dir/base"
docker tag "$BASE_IMAGE" "$HARDENED_IMAGE"

metadata_before=$(docker image inspect --format '{{json .Config}}' "$HARDENED_IMAGE")
IMAGE="$HARDENED_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=true \
  ENABLE_REVOCATION=true \
  "$ACTION_DIR/harden-java-image.sh"

container=$(docker create "$HARDENED_IMAGE")
containers+=("$container")
mkdir -p "$work_dir/result"
docker cp "$container:/opt/java/lib/security/blocked.certs" "$work_dir/result/blocked.certs"
docker cp "$container:/opt/java/jre/lib/security/blacklisted.certs" "$work_dir/result/blacklisted.certs"
docker cp "$container:/opt/laa-java-security/revocation.security" "$work_dir/result/revocation.security"

grep -Fqx 'existing-modern-entry' "$work_dir/result/blocked.certs" ||
  fail "Modern blocklist entry was not preserved"
grep -Fqx 'existing-java-8-entry' "$work_dir/result/blacklisted.certs" ||
  fail "Java 8 blocklist entry was not preserved"
grep -Fqx 'ocsp.enable=true' "$work_dir/result/revocation.security" ||
  fail "OCSP was not enabled"

while IFS= read -r fingerprint; do
  [[ "$fingerprint" =~ ^[A-F0-9]{64}$ ]] || continue
  [[ $(grep -Fxc "$fingerprint" "$work_dir/result/blocked.certs") -eq 1 ]] ||
    fail "Modern blocklist does not contain $fingerprint exactly once"
  [[ $(grep -Fxc "$fingerprint" "$work_dir/result/blacklisted.certs") -eq 1 ]] ||
    fail "Java 8 blocklist does not contain $fingerprint exactly once"
done < "$ACTION_DIR/emudhra-blocked.certs"

java_tool_options=$(
  docker image inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$HARDENED_IMAGE" |
    sed -n 's/^JAVA_TOOL_OPTIONS=//p'
)
assert_contains "$java_tool_options" '-Xmx256m'
assert_contains "$java_tool_options" '-Dcom.sun.net.ssl.checkRevocation=true'
assert_contains "$java_tool_options" '-Dcom.sun.security.enableCRLDP=true'
assert_contains "$java_tool_options" '-Djava.security.properties=/opt/laa-java-security/revocation.security'

metadata_after=$(docker image inspect --format '{{json .Config}}' "$HARDENED_IMAGE")
for format in \
  '{{.Config.User}}' \
  '{{json .Config.Entrypoint}}' \
  '{{json .Config.Cmd}}' \
  '{{index .Config.Labels "test.metadata"}}'; do
  before=$(docker image inspect --format "$format" "$BASE_IMAGE")
  after=$(docker image inspect --format "$format" "$HARDENED_IMAGE")
  [[ "$before" == "$after" ]] || fail "Image metadata changed for $format"
done
[[ "$metadata_before" != "$metadata_after" ]] || fail "Expected hardening to update image configuration"

IMAGE="$HARDENED_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=true \
  ENABLE_REVOCATION=true \
  "$ACTION_DIR/harden-java-image.sh"

java_tool_options=$(
  docker image inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$HARDENED_IMAGE" |
    sed -n 's/^JAVA_TOOL_OPTIONS=//p'
)
for option in \
  '-Dcom.sun.net.ssl.checkRevocation=true' \
  '-Dcom.sun.security.enableCRLDP=true' \
  '-Djava.security.properties=/opt/laa-java-security/revocation.security'; do
  [[ $(grep -Fo -- "$option" <<< "$java_tool_options" | wc -l | tr -d ' ') -eq 1 ]] ||
    fail "Revocation option was duplicated: $option"
done

mkdir -p "$work_dir/no-java"
cat > "$work_dir/no-java/Dockerfile" <<'EOF'
FROM scratch
LABEL test.image="no-java"
EOF
docker buildx build --load --tag "$NO_JAVA_IMAGE" "$work_dir/no-java"

if IMAGE="$NO_JAVA_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=true \
  ENABLE_REVOCATION=false \
  "$ACTION_DIR/harden-java-image.sh"; then
  fail "Certificate blocking should fail when no JVM blocklist is present"
fi

image_id_before=$(docker image inspect --format '{{.Id}}' "$NO_JAVA_IMAGE")
IMAGE="$NO_JAVA_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=false \
  ENABLE_REVOCATION=false \
  "$ACTION_DIR/harden-java-image.sh"
image_id_after=$(docker image inspect --format '{{.Id}}' "$NO_JAVA_IMAGE")
[[ "$image_id_before" == "$image_id_after" ]] || fail "Disabled hardening modified the image"

echo "All harden-java-image tests passed"
