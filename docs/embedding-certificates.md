# Configuring Additional CA Certificates for a Java / Gradle / SpringBoot Application

This guide describes how to add one or more additional trusted CA certificates to a Java Spring Boot application image built with Gradle and Paketo Buildpacks.

The approach uses:

- Spring Boot's `bootBuildImage` Gradle task
- Paketo's `ca-certificates` buildpack
- a Cloud Native Buildpacks service binding

## Why this is needed

A Java application may need to connect over TLS to services whose certificate chain is not trusted by the JVM's default truststore, for example:

- databases
- internal APIs
- corporate proxies
- services using an organisation-specific/private CA

Rather than modifying the JVM truststore manually with `keytool`, Paketo Buildpacks can consume additional CA certificates through a `ca-certificates` binding.

When the image is built, the certificates are made available to the buildpacks and, when `BP_EMBED_CERTS=true` is configured, embedded in the resulting application image.

## Overview

The setup has three parts:

1. Configure `bootBuildImage` to mount a certificate binding.
2. Store the required PEM certificates as a CI/CD secret.
3. Configure your calling workflow

The resulting binding looks similar to:

```text
bindings/certificates/
├── type
├── certificate-001.pem
├── certificate-002.pem
└── certificate-003.pem
```

The `type` file contains:

```text
ca-certificates
```

Each `.pem` file must contain exactly one PEM-encoded certificate.

---

## 1. Configure `bootBuildImage`

Add the certificate binding to the application's `build.gradle`:

```groovy
bootBuildImage {
    // Mount the certificate binding into the Cloud Native Buildpacks
    // bindings directory during image creation.
    binding("$projectDir/bindings/certificates:/platform/bindings/certificates")

    // Include build-time CA certificates in the resulting application image.
    environment = [
        "BP_EMBED_CERTS": "true"
    ]
}
```

If the `bootBuildImage` task already has environment variables configured, merge `BP_EMBED_CERTS` into the existing map rather than replacing it.

For example:

```groovy
bootBuildImage {
    binding("$projectDir/bindings/certificates:/platform/bindings/certificates")

    environment = [
        "BP_JVM_VERSION": "25",
        "BP_EMBED_CERTS" : "true"
    ]
}
```

Spring Boot passes the binding through to the builder container. Paketo's `ca-certificates` buildpack discovers bindings whose `type` is `ca-certificates`.

---

## 2. Store certificates as a PEM bundle

Store the certificates required by the application as a GitHub actions secret.

A single secret can contain any number of concatenated PEM certificates:

```text
-----BEGIN CERTIFICATE-----
cert1
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
cert2
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
cert3
-----END CERTIFICATE-----
```

For example, a GitHub Actions secret might be named:

```text
CA_CERTIFICATE_BUNDLE
```

To add another CA:

1. Update the `CA_CERTIFICATE_BUNDLE` secret.
2. Append the new PEM certificate to the existing bundle.
3. Rebuild and deploy the application image.

---

## 3. Update your calling workflow

Ensure the `certificate_bundle` and `binding_directory` properties are set in the `ecr-publish-image` workflow.

```yaml
  ecr-publish-image:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/ecr-publish-image.yml@v2
    permissions:
      contents: read
      id-token: write
      security-events: write
    with:
      image_version: '1.0.0'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      ecr_repository: ${{ vars.ECR_REPOSITORY_MP }}
      ecr_region: ${{ vars.ECR_REGION_MP }}
      ecr_role_to_assume: ${{ secrets.ECR_ROLE_TO_ASSUME_MP }}
      ecr_registry: ${{ secrets.ECR_REGISTRY_MP }}
      certificate_bundle: ${{ secrets.CA_CERTIFICATE_BUNDLE }}
      binding_directory: "bindings/certificates"
```

---

## References

- Paketo CA Certificates buildpack: https://github.com/paketo-buildpacks/ca-certificates
- Paketo configuration and bindings: https://paketo.io/docs/howto/configuration/#bindings
- Spring Boot Gradle Plugin — Packaging OCI Images: https://docs.spring.io/spring-boot/gradle-plugin/packaging-oci-image.html
- Cloud Native Buildpacks bindings specification: https://github.com/buildpacks/spec/blob/main/extensions/project-descriptor.md
