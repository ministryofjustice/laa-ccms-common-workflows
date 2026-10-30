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
  set +u
  for container in "${containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  set -u
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

root_aliases=(
  'vendor-emsign-g1'
  'vendor-emsign-g2'
  'vendor-emsign-ecc-g3'
  'vendor-aaa-ca'
)
root_common_names=(
  'emSign Root CA - G1'
  'emSign Root CA - G2'
  'emSign ECC Root CA - G3'
  'AAA Certificate Services'
)
safe_alias='unaffected-test-root'
safe_common_name='Unaffected Test Root'
source_truststore_password='changeit'
application_truststore_password='application-password'

mkdir -p "$work_dir/base"
for index in "${!root_aliases[@]}"; do
  keytool -genkeypair \
    -alias "${root_aliases[$index]}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 1 \
    -dname "CN=${root_common_names[$index]}" \
    -keystore "$work_dir/base/cacerts" \
    -storetype JKS \
    -storepass "$source_truststore_password" \
    -keypass "$source_truststore_password" \
    -noprompt >/dev/null 2>&1
done
keytool -genkeypair \
  -alias "$safe_alias" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 1 \
  -dname "CN=$safe_common_name" \
  -keystore "$work_dir/base/cacerts" \
  -storetype JKS \
  -storepass "$source_truststore_password" \
  -keypass "$source_truststore_password" \
  -noprompt >/dev/null 2>&1

mkdir -p "$work_dir/base/bundles"
for index in "${!root_aliases[@]}"; do
  keytool -exportcert \
    -rfc \
    -alias "${root_aliases[$index]}" \
    -keystore "$work_dir/base/cacerts" \
    -storetype JKS \
    -storepass "$source_truststore_password" \
    -file "$work_dir/base/bundles/affected-$index.pem" >/dev/null 2>&1
done
keytool -exportcert \
  -rfc \
  -alias "$safe_alias" \
  -keystore "$work_dir/base/cacerts" \
  -storetype JKS \
  -storepass "$source_truststore_password" \
  -file "$work_dir/base/bundles/safe.pem" >/dev/null 2>&1
cat \
  "$work_dir/base/bundles/safe.pem" \
  "$work_dir/base/bundles/affected-0.pem" \
  "$work_dir/base/bundles/affected-2.pem" \
  > "$work_dir/base/default-ca-certificates.crt"
cat \
  "$work_dir/base/bundles/safe.pem" \
  "$work_dir/base/bundles/affected-1.pem" \
  "$work_dir/base/bundles/affected-3.pem" \
  > "$work_dir/base/custom-ca-certificates.crt"

cat > "$work_dir/base/Dockerfile" <<'EOF'
FROM scratch
COPY --chown=1001:1001 --chmod=0644 cacerts /opt/java/lib/security/cacerts
COPY --chown=1001:1001 --chmod=0644 cacerts /opt/java/jre/lib/security/cacerts
COPY --chown=1002:1003 --chmod=0640 default-ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chown=1004:1005 --chmod=0600 custom-ca-certificates.crt /opt/custom/ca-certificates.crt
ENV JAVA_TOOL_OPTIONS="-Xmx256m"
ENV SSL_CERT_FILE="/opt/custom/ca-certificates.crt"
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
  TRUSTSTORE_PASSWORD="$application_truststore_password" \
  "$ACTION_DIR/harden-java-image.sh"

container=$(docker create "$HARDENED_IMAGE")
containers+=("$container")
mkdir -p "$work_dir/result"
docker cp "$container:/opt/java/lib/security/cacerts" "$work_dir/result/modern-cacerts"
docker cp "$container:/opt/java/jre/lib/security/cacerts" "$work_dir/result/java-8-cacerts"
docker cp "$container:/etc/ssl/certs/ca-certificates.crt" "$work_dir/result/default-ca-certificates.crt"
docker cp "$container:/opt/custom/ca-certificates.crt" "$work_dir/result/custom-ca-certificates.crt"
docker cp "$container:/opt/laa-java-security/revocation.security" "$work_dir/result/revocation.security"

file_paths=(
  'opt/java/lib/security/cacerts'
  'opt/java/jre/lib/security/cacerts'
  'etc/ssl/certs/ca-certificates.crt'
  'opt/custom/ca-certificates.crt'
)
expected_metadata=(
  '1001:1001:-rw-r--r--'
  '1001:1001:-rw-r--r--'
  '1002:1003:-rw-r-----'
  '1004:1005:-rw-------'
)
for index in "${!file_paths[@]}"; do
  file_path=${file_paths[$index]}
  metadata=$(
    docker export "$container" |
      tar --numeric-owner -tvf - "$file_path" |
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
  )
  [[ "$metadata" == "${expected_metadata[$index]}" ]] ||
    fail "Certificate store metadata changed for /$file_path: $metadata"
done

grep -Fqx 'ocsp.enable=true' "$work_dir/result/revocation.security" ||
  fail "OCSP was not enabled"

for truststore in "$work_dir/result/modern-cacerts" "$work_dir/result/java-8-cacerts"; do
  for alias in "${root_aliases[@]}"; do
    if keytool -list \
      -keystore "$truststore" \
      -storetype JKS \
      -storepass "$source_truststore_password" \
      -alias "$alias" >/dev/null 2>&1; then
      fail "Affected root '$alias' remains in $truststore"
    fi
  done
  keytool -list \
    -keystore "$truststore" \
    -storetype JKS \
    -storepass "$source_truststore_password" \
    -alias "$safe_alias" >/dev/null 2>&1 ||
    fail "Unaffected certificate was removed from $truststore"
  keytool -list \
    -keystore "$truststore" \
    -storetype JKS \
    -storepass "$source_truststore_password" >/dev/null 2>&1 ||
    fail "$truststore no longer accepts the password required by the Paketo certificate loader"
done

mkdir -p "$work_dir/certificate-remover"
javac -source 8 -target 8 -Xlint:-options \
  -d "$work_dir/certificate-remover" \
  "$ACTION_DIR/RemoveCertificates.java"
for bundle in \
  "$work_dir/result/default-ca-certificates.crt" \
  "$work_dir/result/custom-ca-certificates.crt"; do
  java -cp "$work_dir/certificate-remover" RemoveCertificates verify-pem "$bundle"
  [[ $(grep -c '^-----BEGIN CERTIFICATE-----$' "$bundle") -eq 1 ]] ||
    fail "Expected only the unaffected certificate to remain in $bundle"
done

cp "$work_dir/result/modern-cacerts" "$work_dir/result/paketo-reimport-cacerts"
mkdir -p "$work_dir/reimport"
certificate_number=0
for bundle in \
  "$work_dir/result/default-ca-certificates.crt" \
  "$work_dir/result/custom-ca-certificates.crt"; do
  bundle_name=$(basename "$bundle")
  awk -v output_directory="$work_dir/reimport" -v prefix="$bundle_name" '
    /^-----BEGIN CERTIFICATE-----$/ {
      certificate += 1
      output = output_directory "/" prefix "-" certificate ".pem"
    }
    output != "" {
      print > output
    }
    /^-----END CERTIFICATE-----$/ {
      close(output)
      output = ""
    }
  ' "$bundle"
  for certificate in "$work_dir/reimport/$bundle_name"-*.pem; do
    certificate_number=$((certificate_number + 1))
    keytool -importcert \
      -noprompt \
      -alias "paketo-import-$certificate_number" \
      -file "$certificate" \
      -keystore "$work_dir/result/paketo-reimport-cacerts" \
      -storetype JKS \
      -storepass "$source_truststore_password" >/dev/null 2>&1
  done
done
java -cp "$work_dir/certificate-remover" \
  RemoveCertificates verify "$work_dir/result/paketo-reimport-cacerts" ||
  fail "Paketo-style container CA import reintroduced an affected root"

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
  TRUSTSTORE_PASSWORD="$application_truststore_password" \
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
CMD ["/not-used"]
EOF
docker buildx build --load --tag "$NO_JAVA_IMAGE" "$work_dir/no-java"

if IMAGE="$NO_JAVA_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=true \
  ENABLE_REVOCATION=false \
  "$ACTION_DIR/harden-java-image.sh"; then
  fail "Root removal should fail when no JVM truststore is present"
fi

image_id_before=$(docker image inspect --format '{{.Id}}' "$NO_JAVA_IMAGE")
IMAGE="$NO_JAVA_IMAGE" \
  BLOCK_COMPROMISED_CERTIFICATES=false \
  ENABLE_REVOCATION=false \
  "$ACTION_DIR/harden-java-image.sh"
image_id_after=$(docker image inspect --format '{{.Id}}' "$NO_JAVA_IMAGE")
[[ "$image_id_before" == "$image_id_after" ]] || fail "Disabled hardening modified the image"

echo "All harden-java-image tests passed"
