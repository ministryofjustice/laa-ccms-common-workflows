[![Ministry of Justice Repository Compliance Badge](https://github-community.service.justice.gov.uk/repository-standards/api/laa-ccms-common-workflows/badge)](https://github-community.service.justice.gov.uk/repository-standards/laa-ccms-common-workflows)

# LAA CCMS Common Workflows

A library of commonly used GitHub actions and workflows used within LAA CCMS

## Table of Contents

- [Reusable workflows](#reusable-workflows---githubworkflows)
    - [Gradle build & publish](#gradle-build--publish)
    - [Publish image to ECR](#publish-image-to-ecr)
    - [Snyk vulnerability scan](#snyk-vulnerability-scan)
    - [Snyk vulnerability report](#snyk-vulnerability-report)
    - [Update helm chart](#update-helm-chart)
    - [Pact and Publish](#pact-and-publish)
    - [Pact Provider Webhook](#pact-provider-webhook)
- [Reusable actions](#reusable-actions---githubactions)
    - [Compute version](#compute-version)
    - [Define Snyk arguments](#define-snyk-arguments)
    - [Remove prefix](#remove-prefix)
    - [Pact Can I Merge](#pact-can-i-merge)
    - [Pact Can I Deploy](#pact-can-i-deploy)
    - [Pact Record Deployment](#pact-record-deployment)

## Reusable workflows - [`.github/workflows`](.github/workflows)

Complete workflows that may consist of several other reusable workflows and actions.

### Gradle build & publish

Workflow: [`gradle-build-and-publish.yml`](.github/workflows/gradle-build-and-publish.yml)

Runs a Gradle build (or chosen build task), optional integration tests, and handles versioning,
tagging, artifact publishing, and GitHub Release creation — all driven by a single `release_type` input.

Version computation is handled internally via the [`compute-version`](.github/actions/compute-version)
composite action: it resolves the previous Release Tag, detects the Bump Type from
[Conventional Commits](https://www.conventionalcommits.org/), and applies semver arithmetic.

It is assumed that `build` includes unit tests.

#### Pre-requisites

- Java / Gradle repository
- A GitHub App with write access to repository contents (for tag creation)

> **Note:** The [Gradle Release Plugin](https://github.com/researchgate/gradle-release) is no longer
> required. If your repository uses it, see the
> [migration guide](https://github.com/ministryofjustice/laa-ccms-common-workflows/wiki/Migrating-from-the-Gradle-Release-Plugin)
> for step-by-step instructions.

#### `release_type` input

The `release_type` input is the single control point for the release pipeline:

| `release_type`              | Behaviour                                                                         |
|-----------------------------|-----------------------------------------------------------------------------------|
| `patch` / `minor` / `major` | Creates Release Tag, publishes Maven artifact, creates GitHub Release             |
| `snapshot`                  | Computes `{next}-{hash}-SNAPSHOT` version and publishes artifact                  |
| `none`                      | Build and test only — no publish, no tag                                          |
| `''` (empty) on `main`      | Auto-detects Bump Type from Conventional Commits; defaults to `patch`             |
| `''` (empty) elsewhere      | Build and test only                                                               |

#### Conventional Commits and versioning

When `release_type` is empty on `main`, the pipeline scans commit messages since the last Release Tag
and determines the bump type automatically:

| Commit prefix                              | Bump type | Example version  |
|--------------------------------------------|-----------|------------------|
| `feat!:` / `fix!:` / `BREAKING CHANGE:`   | `major`   | `1.0.0 → 2.0.0`  |
| `feat:`                                    | `minor`   | `1.0.0 → 1.1.0`  |
| `fix:` / `chore:` / `refactor:`            | `patch`   | `1.0.0 → 1.0.1`  |
| anything else (or no commits matched)      | `patch`   | `1.0.0 → 1.0.1`  |

**PR title is the version signal.** Because most repositories squash-merge, the PR title becomes
the commit message on `main`. The `lint-pr-title.yml` workflow enforces Conventional Commits format
on PR titles so the signal is always present.

Conventional Commits format: `<type>[optional scope]: <description>`

```
feat: add new claim endpoint          → minor bump
feat(claims): add new claim endpoint  → minor bump (with scope)
fix: correct null check on submit     → patch bump
chore: update dependencies            → patch bump
feat!: remove v1 API endpoints        → major bump (breaking change)
```

Scope is optional. Use it to reference a Jira ticket (`fix(LJCP-42): ...`) or a component.
A PR covering multiple change types — pick the highest bump that applies.

#### Example: release pipeline (build-main.yml)

```yaml
on:
  push:
    branches: [ main ]
  workflow_dispatch:
    inputs:
      release_type:
        type: choice
        default: "auto"
        options: [ "auto", "none", "patch", "minor", "major" ]

jobs:
  release:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/gradle-build-and-publish.yml@main
    permissions:
      contents: write
      packages: write
    with:
      java_version: '25'
      java_distribution: 'corretto'
      release_type: ${{ inputs.release_type != 'auto' && inputs.release_type || '' }}
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      github_app_id: ${{ vars.YOUR_APP_ID }}
      github_app_private_key: ${{ secrets.YOUR_APP_KEY }}
      github_app_organisation: ministryofjustice
```

To chain Docker image publishing after a release, use `published_artifact_version` output:

```yaml
  publish-image:
    needs: release
    if: ${{ needs.release.outputs.published_artifact_version != '' }}
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/ecr-publish-image.yml@main
    permissions:
      contents: read
      id-token: write
    with:
      image_version: ${{ needs.release.outputs.published_artifact_version }}
      tag_with_latest: ${{ !contains(needs.release.outputs.published_artifact_version, 'SNAPSHOT') }}
    secrets: inherit
```

#### Example: snapshot pipeline (build-feature.yml)

```yaml
on:
  push:
    branches-ignore: [ main ]

jobs:
  snapshot:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/gradle-build-and-publish.yml@main
    permissions:
      contents: write
      packages: write
    with:
      release_type: 'snapshot'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
```

#### Inputs

| Input                         | Description                                                                                                                      | Required | Default                    |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------------|----------|----------------------------|
| `release_type`                     | Release type: `major` \| `minor` \| `patch` \| `snapshot` \| `none` \| `''` (auto-detect on main). See table above.             | false    | `''`                       |
| `java_version`                | The Java JDK version to run build commands with.                                                                                 | false    | `25`                       |
| `java_distribution`           | The Java JDK distribution.                                                                                                       | false    | `temurin`                  |
| `build_command`               | The Gradle build command to run.                                                                                                 | false    | `build`                    |
| `build_args`                  | Additional build arguments to pass to the Gradle `build` task.                                                                   | false    |                            |
| `integration_test_task`       | The name of the Gradle task to run integration tests (if separate from unit tests).                                              | false    |                            |
| `override_version`            | Specify an explicit version to publish artifacts with. Takes precedence over computed version.                                    | false    |                            |
| `junit_results`               | Whether a junit results artifact should be produced.                                                                             | false    | `true`                     |
| `junit_results_path`          | The path of the junit test results to upload.                                                                                    | false    | `build/test-results`       |
| `junit_report`                | Whether a junit report artifact should be produced.                                                                              | false    | `true`                     |
| `junit_report_path`           | The path of the junit report to upload.                                                                                          | false    | `build/reports/tests`      |
| `checkstyle_report`           | Whether a checkstyle report artifact should be produced.                                                                         | false    | `true`                     |
| `checkstyle_report_path`      | The path of the checkstyle report to upload.                                                                                     | false    | `build/reports/checkstyle` |
| `jacoco_coverage_report`      | Whether a jacoco coverage report artifact should be produced.                                                                    | false    | `true`                     |
| `jacoco_coverage_report_path` | The path of the jacoco report to upload.                                                                                         | false    | `build/reports/jacoco`     |
| `github_bot_username`         | The bot username for git commits made by this workflow.                                                                          | false    | `github-actions-bot`       |
| `semgrep_check`               | Whether to run a Semgrep security scan before the main build.                                                                    | false    | `false`                    |
| `publish_package` ⚠️          | **Deprecated.** Use `release_type` instead.                                                                                           | false    | `false`                    |
| `create_tag` ⚠️               | **Deprecated.** Use `release_type=patch/minor/major` instead.                                                                         | false    | `false`                    |
| `is_snapshot` ⚠️              | **Deprecated.** Use `release_type=snapshot` instead.                                                                                  | false    | `false`                    |
| `override_tagged_branch` ⚠️   | **Deprecated.** Used only by the legacy `create_tag` path.                                                                      | false    | `main`                     |

#### Secrets

| Secret                    | Description                                                                                            | Required |
|---------------------------|--------------------------------------------------------------------------------------------------------|----------|
| `gh_token`                | The GitHub token from the calling repository.                                                          | true     |
| `aws_region`              | The AWS Region, if required for build tasks.                                                           | false    |
| `github_app_id`           | The ID of the GitHub App used for tag creation. Required for release paths.                            | false    |
| `github_app_private_key`  | The private key of the GitHub App used for tag creation. Required for release paths.                   | false    |
| `github_app_organisation` | The organisation in which the GitHub App is installed.                                                 | false    |

#### Outputs

| Output                       | Description                                                        |
|------------------------------|--------------------------------------------------------------------|
| `published_artifact_version` | The published version (release or snapshot), or empty if skipped.  |

### Publish image to ECR

Worflow: [`ecr-publish-image.yml`](.github/workflows/ecr-publish-image.yml)

Generates a boot image for a SpringBoot application (via `bootBuildImage`) and pushes the image to
the given AWS ECR repository.

#### Pre-requisites

- Java / Gradle project
- [SpringBoot Plugin (for
  `buildBootImage`)](https://github.com/ministryofjustice/laa-ccms-spring-boot-common) enabled
- Snyk token for a CI account in the LAA organisation (image scanning)

```yaml
jobs:
  ecr-publish-image:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/ecr-publish-image.yml@v1
    permissions:
      contents: read
      id-token: write
    with:
      image_version: 'image-1'
      jar_subproject: 'example-service'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      ecr_repository: ${{ vars.ECR_REPOSITORY }}
      ecr_region: ${{ vars.ECR_REGION }}
      ecr_role_to_assume: ${{ secrets.ECR_ROLE_TO_ASSUME }}
      snyk_token: ${{ secrets.snyk_token }}
```

#### Inputs

| Input                     | Description                                                                                                                                                             | Required | Default      |
|---------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|--------------|
| `java_version`            | The Java JDK version to run build commands with.                                                                                                                        | false    | `25`         |
| `java_distribution`       | The Java JDK distribution.                                                                                                                                              | false    | `temurin`    |
| `image_version`           | The image version to be published.                                                                                                                                      | true     |              |
| `dockerfile_path`         | The Dockerfile to use to build the image. (Should only be provided if not using SpringBoot)                                                                             | false    |              |
| `docker_build_args`       | The arguments to supply to the docker build command, if a Dockerfile path has been supplied.                                                                            | false    |              |
| `jar_subproject`          | The gradle subproject to run the `bootBuildImage` task in.                                                                                                              | false    |              |
| `image_scan`              | Whether to scan the built image (via Snyk).                                                                                                                             | false    | `true`       |
| `image_scan_severity`     | The minumum severity level to flag in the image scan report. Any vulnerabilities identified at this level or above will fail the pipeline.                              | false    | `medium`     |
| `image_scan_fail_on`      | The types of vulnerabiltiies that will fail the pipeline. See [snyk container test](https://docs.snyk.io/developer-tools/snyk-cli/commands/container-test) CLI command. | false    | `upgradable` |
| `image_scan_policy_path`  | The path to your [`.snyk` policy file](https://docs.snyk.io/manage-risk/policies/the-.snyk-file).                                                                       | false    | `.snyk`      |
| `image_scan_upload_sarif` | Whether to upload the sarif file generated by image scanning.                                                                                                           | false    | `true`       |
| `publish`                 | Whether to publish the image. Disable for scanning only.                                                                                                                | false    | `true`       |
| `tag_with_latest`         | Whether to publish the image with the `latest` tag also.                                                                                                                | false    | `false`      |

#### Secrets

| Input                   | Description                                                                                                                       | Required | Default |
|-------------------------|-----------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `gh_token`              | The github token from the calling repository.                                                                                     | true     |         |
| `ecr_region`            | The ECR region to publish to.                                                                                                     | true     |         |
| `ecr_repository`        | The name of the ECR repository to publish to.                                                                                     | true     |         |
| `ecr_role_to_assume`    | The AWS role to assume to connect to ECR.                                                                                         | true     |         |
| `ecr_registry`          | The ECR registry to publish to, if in a different account to the role.                                                            | false    |         |
| `snyk_token`            | The API token for Snyk. This should be from an LAA service account. Required when `image_scan=true`.                              | false    |         |
| `snyk_client_id`        | The API client id for Snyk. Required when `image_scan=true` and `snyk_token` not set.                                             | false    |         |
| `snyk_client_secret`    | The API client secret for Snyk. Required when `image_scan=true` and `snyk_token` not set.                                         | false    |         |
| `root_certificate`      | The root certificate to embed into the image. This will be added to the JVM Truststore.                                           | false    |         |
| `binding_directory`     | The directory used for binding the root certificate. See [Paketo Bindings](https://paketo.io/docs/howto/configuration/#bindings). | false    |         |
| `tls_keystore_password` | Keystore password. This will be exposed as the TLS_KEYSTORE_PASSWORD environment variable.                                        | false    |         |

#### Outputs

| Output                    | Description                         |
|---------------------------|-------------------------------------|
| `published_image_version` | The version of the published image. |

### Snyk vulnerability scan

Worflow: [`snyk-vulnerability-scan.yml`](.github/workflows/snyk-vulnerability-scan.yml)

Identifies __new__ vulnerabilities that have been introduced against a target reference project that
exists in Snyk.

Also runs a `snyk code test` to identify code security issues (Static Application Security Testing).

#### Pre-requisites

- Snyk compatible repository
- A published Snyk project to use as a target reference
- A secret named `SNYK_TOKEN` added to the calling repository secrets, containing a Snyk access
  token.

#### Example usage

```yaml
jobs:
  vulnerability-scan:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/snyk-vulnerability-scan.yml@v1
    permissions:
      contents: read
    with:
      snyk_organisation: 'legal-aid-agency'
      snyk_test_exclude: 'build,generated'
      snyk_target_reference: 'main'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

#### Inputs

| Input                   | Description                                                                                                                                                                                             | Required | Default            |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|--------------------|
| `java_version`          | The Java JDK version to run build commands with.                                                                                                                                                        | false    | `25`               |
| `java_distribution`     | The Java JDK distribution.                                                                                                                                                                              | false    | `temurin`          |
| `snyk_organisation`     | Which Snyk organisation to use. See [`--org`](https://docs.snyk.io/snyk-cli/commands/test#org-less-than-org_id-greater-than).                                                                           | false    | `legal-aid-agency` |
| `snyk_test_exclude`     | Which files / directories to exclude from Snyk testing. See [`--exclude`](https://docs.snyk.io/snyk-cli/commands/test#exclude-less-than-name-greater-than-less-than-name-greater-than-...greater-than). | false    |                    |
| `snyk_target_reference` | The target reference to use for Snyk testing. See [`--target-reference`](https://docs.snyk.io/snyk-cli/commands/test#target-reference-less-than-target_reference-greater-than).                         | false    |                    |

#### Secrets

| Input        | Description                                                                     | Required | Default |
|--------------|---------------------------------------------------------------------------------|----------|---------|
| `gh_token`   | The github token from the calling repository.                                   | true     |         |
| `snyk_token` | The token to use for Snyk CLI commands. This should be a service account token. | true     |         |

### Snyk vulnerability report

Worflow: [`snyk-vulnerability-report.yml`](.github/workflows/snyk-vulnerability-report.yml)

Publishes a project vulnerability report to the given Snyk organisation dashboard, via
`snyk monitor`.

Optionally produces a sarif report and publishes to Github Code Scanning.

#### Pre-requisites

- Snyk compatible repository
- A secret named `SNYK_TOKEN` added to the calling repository secrets, containing a Snyk access
  token.

#### Example usage

```yaml
jobs:
  vulnerability-report:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/snyk-vulnerability-report.yml@v1
    permissions:
      contents: read
      security-events: write
    with:
      snyk_organisation: 'legal-aid-agency'
      snyk_test_exclude: 'build,generated'
      snyk_target_reference: 'main'
      github_code_scanning_report: 'true'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

#### Inputs

| Input                         | Description                                                                                                                                                                                             | Required | Default            |
|-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|--------------------|
| `java_version`                | The Java JDK version to run build commands with.                                                                                                                                                        | false    | `25`               |
| `java_distribution`           | The Java JDK distribution.                                                                                                                                                                              | false    | `temurin`          |
| `snyk_organisation`           | Which Snyk organisation to use. See [`--org`](https://docs.snyk.io/snyk-cli/commands/test#org-less-than-org_id-greater-than).                                                                           | false    | `legal-aid-agency` |
| `snyk_test_exclude`           | Which files / directories to exclude from Snyk testing. See [`--exclude`](https://docs.snyk.io/snyk-cli/commands/test#exclude-less-than-name-greater-than-less-than-name-greater-than-...greater-than). | false    |                    |
| `snyk_target_reference`       | The target reference to use for Snyk testing. See [`--target-reference`](https://docs.snyk.io/snyk-cli/commands/test#target-reference-less-than-target_reference-greater-than).                         | false    |                    |
| `github_code_scanning_report` | Whether to generate and upload a sarif report to [Github Code Scanning](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github).        | false    | `false`            |

#### Secrets

| Input        | Description                                                                     | Required | Default |
|--------------|---------------------------------------------------------------------------------|----------|---------|
| `gh_token`   | The github token from the calling repository.                                   | true     |         |
| `snyk_token` | The token to use for Snyk CLI commands. This should be a service account token. | true     |         |

### Update helm chart

Worflow: [`update-helm-chart.yml`](.github/workflows/update-helm-chart.yml)

Updates the version of a subchart within a helm chart repository in GitHub.

#### Pre-requisites

- Helm chart repository

```yaml
jobs:
  update-helm-chart:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/update-helm-chart.yml@v1
    with:
      helm_charts_repository: 'example-helm-charts'
      helm_charts_branch: 'example-branch'
      service_name: 'example-service'
      subchart_name: 'example-subchart'
      application_version: '0.0.1'
    secrets:
      gh_token: ${{ secrets.REPO_TOKEN }}
```

> [!Important]
> A PAT token will likely be required over the generated GITHUB_TOKEN here if your helm chart
> repository is private.

#### Inputs

| Input                    | Description                                                                                                                                 | Required | Default              |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|----------|----------------------|
| `helm_charts_repository` | The name of the helm chart repository.                                                                                                      | true     |                      |
| `helm_charts_branch`     | The branch to checkout.                                                                                                                     | true     |                      |
| `service_name`           | The parent service name.                                                                                                                    | true     |                      |
| `subchart_name`          | The name of the subchart to update.                                                                                                         | true     |                      |
| `application_version`    | The new application version.                                                                                                                | true     |                      |
| `feature_branch`         | The name of the feature branch to update. Creates the branch if it does not exist. If not set, the checked out branch will be used instead. | false    |                      |
| `github_bot_username`    | The bot username to use for commits made by this workflow.                                                                                  | false    | `github-actions-bot` |

#### Secrets

| Input                     | Description                                                                                           | Required | Default |
|---------------------------|-------------------------------------------------------------------------------------------------------|----------|---------|
| `gh_token`                | The github token from the calling repository.                                                         | true     |         |
| `github_app_id`           | The ID of the GitHub App to use for release commits - e.g. updating semantic version, creating a tag. | false    |         |
| `github_app_private_key`  | The private key of the GitHub App to use for release commits.                                         | false    |         |
| `github_app_organisation` | The organisation in which the GitHub App has been installed.                                          | false    |         |

### Pact and Publish

Workflow: [`pact-and-publish.yml`](.github/workflows/pact-and-publish.yml)

Runs the Pact tests within a given project, and publishes the results to the given Pact Broker. This
can be used by either a provider, or consumer

#### Pre-requisites

- Pact Broker server to publish results to
- A username & password for the Pact Broker server

#### Example usage

```yaml
jobs:
  pact-test:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/pact-and-publish.yml@v1
    permissions:
      contents: write
      packages: write
    with:
      pact_test_task: ":exampleService:pactTest"
      pacticipant_name: 'example-provider-service-name'
      is_provider: true
      enable_can_i_merge: true
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      pact_broker_url: ${{ secrets.PACT_BROKER_URL }}
      pact_broker_username: ${{ secrets.PACT_BROKER_USERNAME }}
      pact_broker_password: ${{ secrets.PACT_BROKER_PASSWORD }}

```

#### Inputs

| Input                  | Description                                                                                                     | Required | Default    |
|------------------------|-----------------------------------------------------------------------------------------------------------------|----------|------------|
| `java_version`         | The Java JDK version to run build commands with.                                                                | false    | `25`       |
| `java_distribution`    | The Java JDK distribution.                                                                                      | false    | `temurin`  |
| `pact_test_task`       | The gradle task to run the pact tests.                                                                          | true     |            |
| `pacticipant_name`     | The name of the pacticipant according to Pact Broker.                                                           | true     |            |
| `consumer_name`        | Filter by specific consumer (leave empty to test against all consumers) - for provider tests only.              | false    |            |
| `provider_name`        | The provider name to check if the PR can safely merge into `main` - for consumer tests only.                    | false    |            |
| `version`              | The version of the pacticipant. Should always be Commit SHA unless you are testing something.                   | false    | Commit SHA |
| `publish_pact_results` | If the PACT result should be published to Pact Broker - for consumer tests only.                                | false    | false      |
| `is_provider`          | Defines if the pacticipant using the workflow is a provider or not.                                             | false    | false      |
| `enable_can_i_merge`   | Enables the 'can-i-merge' step to see if a PR can safely be merged. Requires the `provider_name` to be set also | false    | false      |

#### Secrets

| Input                  | Description                                                        | Required | 
|------------------------|--------------------------------------------------------------------|----------|
| `gh_token`             | The github token from the calling repository.                      | true     |         
| `pact_broker_url`      | The Pact Broker URL you want to test against or publish to.        | false    |         
| `pact_broker_username` | The Pact Broker username. Required if you wish to publish results. | false    |         
| `pact_broker_password` | The Pact Broker password. Required if you wish to publish results. | false    |         

### PACT Provider Webhook

Workflow: [`pact-provider-webhook.yml`](.github/workflows/pact-provider-webhook.yml)

Workflow defined with the intent of being triggered by a webhook via workflow dispatch. Runs
provider
tests against a specific consumer and it's branch.

You can see how this is setup via the Pact Broker repository
[laa-data-pact-broker](https://github.com/ministryofjustice/laa-data-pact-broker/tree/main/seed).
Webhooks are defined in `.json` files within this repo, which should point to your repositories
workflow file which you wish to trigger following PACT publish (or similar) event.
The `.json` file is then uploaded to the Pact Broker in its own workflow when a PR is merged to
`main` which uses the `create-webhooks.sh` script recreated the webhooks on the newly deployed
Pact Broker instance. This script will need updating to include any
future webhook definitions.

#### Pre-requisites

- Pact Broker server to publish results to.
- A webhook setup within the Pact Broker server via its
  repository [laa-data-pact-broker](https://github.com/ministryofjustice/laa-data-pact-broker) which
  is triggered by the defined provider name.

#### Example usage

```yaml
on:
  workflow_dispatch:
    inputs:
      consumer: { required: true, description: "Consumer name (e.g., laa-microservice)" }
      consumerBranch: { required: true, description: "Consumer branch (e.g., main)" }

jobs:
  pact-test:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/pact-provider-webhook.yml@v1
    permissions:
      contents: write
      packages: write
    with:
      pact_test_task: ":claims-data:service:pactTest"
      provider_name: 'laa-data-claims-api'
      consumer_name: ${{ github.event.inputs.consumer }}
      consumer_branch: ${{ github.event.inputs.consumerBranch }}
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
      pact_broker_url: ${{ secrets.PACT_BROKER_URL }}
      pact_broker_username: ${{ secrets.PACT_BROKER_USERNAME }}
      pact_broker_password: ${{ secrets.PACT_BROKER_PASSWORD }}

```

#### Inputs

| Input               | Description                                                                                  | Required | Default   |
|---------------------|----------------------------------------------------------------------------------------------|----------|-----------|
| `java_version`      | The Java JDK version to run build commands with.                                             | false    | `25`      |
| `java_distribution` | The Java JDK distribution.                                                                   | false    | `temurin` |
| `pact_test_task`    | The gradle task to run the pact tests.                                                       | true     |           |
| `consumer_name`     | The consumer name which triggered the webhook (Pact broker passes this as an event input).   | true     |           |
| `consumer_branch`   | The consumer branch which triggered the webhook (Pact broker passes this as an event input). | true     |           |

#### Secrets

| Input                  | Description                                                        | Required | 
|------------------------|--------------------------------------------------------------------|----------|
| `gh_token`             | The github token from the calling repository.                      | true     |         
| `pact_broker_url`      | The Pact Broker URL you want to test against or publish to.        | false    |         
| `pact_broker_username` | The Pact Broker username. Required if you wish to publish results. | false    |         
| `pact_broker_password` | The Pact Broker password. Required if you wish to publish results. | false    |         

## Reusable actions - [`.github/actions`](.github/actions)

Individual reusable actions for common tasks.

### Compute version

Action: [`compute-version/action.yml`](.github/actions/compute-version/action.yml)

Resolves the previous Release Tag, detects the Bump Type from Conventional Commits, and computes
the next semver version. Used internally by `gradle-build-and-publish.yml` and available for use
in custom pipelines.

Tag resolution prefers `v{semver}` tags; falls back to `{repo-name}-{semver}` tags (old Gradle
Release Plugin format) during migration.

#### Inputs

| Input  | Description                                                                                          | Required | Default |
|--------|------------------------------------------------------------------------------------------------------|----------|---------|
| `bump` | Override the detected bump type: `major` \| `minor` \| `patch` \| `none`. Empty = auto-detect.      | false    | `''`    |

#### Outputs

| Output         | Description                                                                  |
|----------------|------------------------------------------------------------------------------|
| `prev_tag`     | Last Release Tag found (e.g. `v1.2.3`), or `v0.0.0` if none.               |
| `bump_type`    | Detected bump type: `major` \| `minor` \| `patch` \| `none`.                |
| `major`        | Major component of the next version.                                         |
| `minor`        | Minor component of the next version.                                         |
| `patch`        | Patch component of the next version.                                         |
| `next_version` | Next Release Tag (e.g. `v1.3.0`), or empty string when `bump_type=none`.    |

### Define Snyk arguments

Action: [`define-snyk-arguments/action.yml`](.github/actions/define-snyk-arguments/action.yml)

Produces a string of arguments that can be used for running Snyk CLI commands.

#### Example usage

```yaml
jobs:
  get-snyk-arguments:
    runs-on: ubuntu-latest
    steps:
      - uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/define-snyk-arguments@v1
        id: define-snyk-arguments
        with:
          snyk_organisation: 'snyk-org'
          snyk_test_exclude: 'file1,file2'
          snyk_target_reference: 'main'
```

Output: `snyk_args: --org=snyk-org --exclude=file1,file2 --target-reference=main`

Missing inputs will be removed from the output.

#### Inputs

| Input                   | Description                                                                                                                                                                                             | Required | Default |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|---------|
| `snyk_organisation`     | Which Snyk organisation to use. See [`--org`](https://docs.snyk.io/snyk-cli/commands/test#org-less-than-org_id-greater-than).                                                                           | false    |         |
| `snyk_test_exclude`     | Which files / directories to exclude from Snyk testing. See [`--exclude`](https://docs.snyk.io/snyk-cli/commands/test#exclude-less-than-name-greater-than-less-than-name-greater-than-...greater-than). | false    |         |
| `snyk_target_reference` | The target reference to use for Snyk testing. See [`--target-reference`](https://docs.snyk.io/snyk-cli/commands/test#target-reference-less-than-target_reference-greater-than).                         | false    |         |

#### Outputs

| Output      | Description                                                   |
|-------------|---------------------------------------------------------------|
| `snyk_args` | A string of arguments that can be added to Snyk CLI commands. |

### Remove prefix

Action: [`remove-prefix/action.yml`](.github/actions/remove-prefix/action.yml)

Removed the prefix from a string.

#### Example usage

```yaml
jobs:
  define-feature-version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/remove-prefix@v1
        id: get-feature-name
        with:
          string: 'feature-dev/example-feature'
          prefix: 'feature-*/'
```

Output: `result: example-feature`

#### Inputs

| Input    | Description                               | Required | Default |
|----------|-------------------------------------------|----------|---------|
| `string` | The string to process.                    | true     |         |
| `prefix` | The prefix to be removed from the string. | true     |         |

#### Outputs

| Output   | Description                                         |
|----------|-----------------------------------------------------|
| `result` | The resulting string with the given prefix removed. |

### Pact Can I Merge

Action: [`pact-can-i-merge/action.yml`](.github/actions/pact-can-i-merge/action.yml)

Checks if the open PR can merge into `main` by check if it's compatible with any pacticipants in the
Pact Broker it depends on which are also in the `main` branch.

#### Example usage

```yaml
jobs:
  run-pr-checks:
    runs-on: ubuntu-latest
    steps:
      - name: Can I merge?
        uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/pact-can-i-merge@v1
        with:
          pact_broker_url: ${{ secrets.PACT_BROKER_URL }}
          pact_broker_password: ${{ secrets.PACT_BROKER_PASSWORD }}
          pact_broker_username: ${{ secrets.PACT_BROKER_USERNAME }}
          pacticipant: ${{ inputs.pacticipant_name }}
          is_provider: ${{ inputs.is_provider }}
          provider_name: ${{ inputs.provider_name }}
```

#### Inputs

| Input                  | Description                                                                                   | Required | Default    |
|------------------------|-----------------------------------------------------------------------------------------------|----------|------------|
| `pacticipant`          | The name of the pacticipant running this action.                                              | true     |            |
| `version`              | The version of the pacticipant. Should always be Commit SHA unless you are testing something. | false    | Commit SHA |
| `pact_broker_url`      | The Pact Broker URL you want to test against or publish to.                                   | true     |            |
| `pact_broker_username` | The Pact Broker username.                                                                     | true     |            |
| `pact_broker_password` | The Pact Broker password.                                                                     | true     |            |
| `is_provider`          | If the workflow repo is a provider.                                                           | false    | false      |
| `provider_name`        | The provider name to check against. Required if `is_provider` is false.                       | false    | false      |
| `retry_attempts`       | The total times to retry.                                                                     | false    | 30         |
| `retry_interval`       | The interval in seconds between retries.                                                      | false    | 20         |

### Pact Can I Deploy

Action: [`pact-can-i-deploy/action.yml`](.github/actions/pact-can-i-deploy/action.yml)

Checks if the commit can safely be deployed into a named environment. Only runs on environments
called the following:

- main
- uat
- stg
- staging
- prod
- production

#### Example usage

```yaml
jobs:
  deploy-to-uat:
    runs-on: ubuntu-latest
    steps:
      - name: Can I deploy?
        uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/pact-can-i-deploy@v1
        with:
          pacticipant: 'service-name'
          environment: 'uat'
          pact_broker_url: ${{ secrets.PACT_BROKER_URL }}
          pact_broker_password: ${{ secrets.PACT_BROKER_PASSWORD }}
          pact_broker_username: ${{ secrets.PACT_BROKER_USERNAME }}
          provider_name: ${{ inputs.provider_name }}
```

#### Inputs

| Input                  | Description                                                                                   | Required | Default    |
|------------------------|-----------------------------------------------------------------------------------------------|----------|------------|
| `pacticipant`          | The name of the pacticipant running this action.                                              | true     |            |
| `environment`          | The environment the pacticipant is being deployed to.                                         | true     |            |
| `version`              | The version of the pacticipant. Should always be Commit SHA unless you are testing something. | false    | Commit SHA |
| `pact_broker_url`      | The Pact Broker URL you want to test against or publish to.                                   | true     |            |
| `pact_broker_username` | The Pact Broker username.                                                                     | true     |            |
| `pact_broker_password` | The Pact Broker password.                                                                     | true     |            |

### Pact Record Deployment

Action: [`pact-record-deployment/action.yml`](.github/actions/pact-record-deployment/action.yml)

Records the commit SHA (or manually specified version) as a deployment to the given environment.
Only records against environments called the following:

- main
- uat
- stg
- staging
- prod
- production

#### Example usage

```yaml
jobs:
  deploy-to-uat:
    runs-on: ubuntu-latest
    steps:
      - name: Record UAT deployment to pact broker
        id: record_uat_deployment
        uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/pact-record-deployment@v1
        with:
          pacticipant: 'laa-data-claims-api'
          environment: 'uat'
          pact_broker_url: ${{ secrets.pact_broker_url }}
          pact_broker_username: ${{ secrets.pact_broker_username }}
          pact_broker_password: ${{ secrets.pact_broker_password }}
```

#### Inputs

| Input                  | Description                                                                                   | Required | Default    |
|------------------------|-----------------------------------------------------------------------------------------------|----------|------------|
| `pacticipant`          | The name of the pacticipant running this action.                                              | true     |            |
| `environment`          | The environment the pacticipant version has been deployed to.                                 | true     |            |
| `version`              | The version of the pacticipant. Should always be Commit SHA unless you are testing something. | false    | Commit SHA |
| `pact_broker_url`      | The Pact Broker URL you want to test against or publish to.                                   | true     |            |
| `pact_broker_username` | The Pact Broker username.                                                                     | true     |            |
| `pact_broker_password` | The Pact Broker password.                                                                     | true     |            |

