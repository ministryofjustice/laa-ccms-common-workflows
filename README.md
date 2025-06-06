# LAA CCMS Common Workflows

A library of commonly used GitHub actions and workflows used within LAA CCMS

## Reusable workflows - [`.github/workflows`](.github/workflows)
Complete workflows that may consist of several other reusable workflows and actions.

### Gradle build & publish

Workflow: [`gradle-build-and-publish.yml`](.github/workflows/gradle-build-and-publish.yml)

Runs a gradle build (or chosen build task), an optional integration test task and either creates a new tag or publishes an artifact.

It is assumed that `build` includes unit tests.

When using `create_tag`, it is advised to create a new workflow that is triggered by new tags to carry out post-tag tasks, such as image publishing and deployment.

#### Pre-requisites

- Java / Gradle repository
- [Java or SpringBoot Plugin](https://github.com/ministryofjustice/laa-ccms-spring-boot-common) enabled
- [Gradle Release Plugin](https://github.com/researchgate/gradle-release) (included in the above).

#### Example usage

```yaml
jobs:
  build-and-publish-release:
    uses: ministryofjustice/laa-ccms-common-workflows/.github/workflows/gradle-build-and-publish.yml@v1
    permissions:
      contents: read
      packages: write
    with:
      integration_test_task: "integrationTest --tests '*IntegrationTest'"
      create_tag: 'true'
      junit_results_path: 'example-service/build/test-results'
      junit_report_path: 'example-service/build/reports/tests'
      checkstyle_report_path: 'example-service/build/reports/checkstyle'
      jacoco_coverage_report_path: 'example-service/build/reports/jacoco'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
```

#### Inputs

| Input                         | Description                                                                                                                                                             | Required | Default                    |
|-------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|----------------------------|
| `java_version`                | The Java JDK version to run build commands with.                                                                                                                        | false    | `21`                       |
| `java_distribution`           | The Java JDK distribution.                                                                                                                                              | false    | `temurin`                  |
| `build_command`               | The gradle build command to run.                                                                                                                                        | false    | `build`                    |
| `build_args`                  | Additional build arguments to pass to the gradle `build` task.                                                                                                          | false    |                            |
| `integration_test_task`       | The name of the gradle task to run integration tests (if separate from unit tests)                                                                                      | false    |                            |
| `publish_package`             | Whether to publish build artifacts to the packages repository.                                                                                                          | false    | `false`                    |
| `is_snapshot`                 | Whether to publish using a snapshot version generated by the `updateSnapshotVersion` task.                                                                              | false    | `false`                    |
| `override_version`            | Specify a version to use to publish artifacts.                                                                                                                          | false    |                            |
| `create_tag`                  | Runs the `release` task if `true` to create a new release tag. This disables package publishing (a separate `on: tag` workflow should be created to handle publishing). | false    | `false`                    |
| `override_tagged_branch`      | Override the version from which the tag will be created (if different to `main`). Only applies when `create_tag=true`.                                                  | false    | `main`                     |
| `junit_results`               | Whether junit is enabled for this project, and a results artifact should be produced.                                                                                   | false    | `true`                     |
| `junit_results_path`          | The path of the junit test results to upload.                                                                                                                           | false    | `build/test-results`       |
| `junit_report`                | Whether junit is enabled for this project, and a report artifact should be produced.                                                                                    | false    | `true`                     |
| `junit_report_path`           | The path of the junit report to upload.                                                                                                                                 | false    | `build/reports/tests`      |
| `checkstyle_report`           | Whether checkstyle is enabled for this project, and a report artifact should be produced.                                                                               | false    | `true`                     |
| `checkstyle_report_path`      | The path of the checkstyle report to upload.                                                                                                                            | false    | `build/reports/checkstyle` |
| `jacoco_coverage_report`      | Whether jacoco coverage is enabled for this project, and a report artifact should be produced.                                                                          | false    | `true`                     |
| `jacoco_coverage_report_path` | The path of the jacoco report to upload.                                                                                                                                | false    | `build/reports/jacoco`     |
| `github_bot_username`         | The bot username to use for commits made by this workflow.                                                                                                              | false    | `github-actions-bot`       |

#### Secrets

| Input                     | Description                                                                                           | Required | Default |
|---------------------------|-------------------------------------------------------------------------------------------------------|----------|---------|
| `gh_token`                | The github token from the calling repository.                                                         | true     |         |
| `aws_region`              | The AWS Region to use for AWS CLI commands, if required for build tasks.                              | false    |         |
| `github_app_id`           | The ID of the GitHub App to use for release commits - e.g. updating semantic version, creating a tag. | false    |         |
| `github_app_private_key`  | The private key of the GitHub App to use for release commits.                                         | false    |         |
| `github_app_organisation` | The organisation in which the GitHub App has been installed.                                          | false    |         |

#### Outputs

| Output                       | Description                                                                     |
|------------------------------|---------------------------------------------------------------------------------|
| `published_artifact_version` | The version of the published artifact, or the current version if not published. |

### Publish image to ECR

Worflow: [`ecr-publish-image.yml`](.github/workflows/ecr-publish-image.yml)

Generates a boot image for a SpringBoot application (via `bootBuildImage`) and pushes the image to the given AWS ECR repository.

#### Pre-requisites

- Java / Gradle project
- [SpringBoot Plugin (for `buildBootImage`)](https://github.com/ministryofjustice/laa-ccms-spring-boot-common) enabled

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
```

#### Inputs

| Input                            | Description                                                  | Required | Default                              |
|----------------------------------|--------------------------------------------------------------|----------|--------------------------------------|
| `java_version`                   | The Java JDK version to run build commands with.             | false    | `21`                                 |
| `java_distribution`              | The Java JDK distribution.                                   | false    | `temurin`                            |
| `image_version`                  | The image version to be published.                           | true     |                                      |
| `jar_subproject`                 | The gradle subproject to run the `bootBuildImage` task in.   | false    |                                      |
| `image_scan`                     | Whether to scan the built image (via Trivy).                 | false    | `true`                               |
| `image_scan_severity`            | The severity levels to include in the image scan report.     | false    | `'UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL'` |
| `image_scan_skip_db_update `     | Whether to update the database for image scanning.           | false    | `true`                               |
| `image_scan_skip_java_db_update` | Whether to skip the java database update for image scanning. | false    | `true`                               |
| `publish`                        | Whether to publish the image. Disable for scanning only.     | false    | `true`                               |

#### Secrets

| Input                | Description                                   | Required | Default |
|----------------------|-----------------------------------------------|----------|---------|
| `gh_token`           | The github token from the calling repository. | true     |         |
| `ecr_region`         | The ECR region to publish to.                 | true     |         |
| `ecr_repository`     | The name of the ECR repository to publish to. | true     |         |
| `ecr_role_to_assume` | The AWS role to assume to connect to ECR.     | true     |         |

#### Outputs

| Output                    | Description                         |
|---------------------------|-------------------------------------|
| `published_image_version` | The version of the published image. |

### Snyk vulnerability scan

Worflow: [`snyk-vulnerability-scan.yml`](.github/workflows/snyk-vulnerability-scan.yml)

Identifies __new__ vulnerabilities that have been introduced against a target reference project that exists in Snyk.

Also runs a `snyk code test` to identify code security issues (Static Application Security Testing).

#### Pre-requisites

- Snyk compatible repository
- A published Snyk project to use as a target reference
- A secret named `SNYK_TOKEN` added to the calling repository secrets, containing a Snyk access token.

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

| Input                   | Description                                                                                                                                                                                             | Required   | Default            |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------|--------------------|
| `java_version`          | The Java JDK version to run build commands with.                                                                                                                                                        | false      | `21`               |
| `java_distribution`     | The Java JDK distribution.                                                                                                                                                                              | false      | `temurin`          |
| `snyk_organisation`     | Which Snyk organisation to use. See [`--org`](https://docs.snyk.io/snyk-cli/commands/test#org-less-than-org_id-greater-than).                                                                           | false      | `legal-aid-agency` |
| `snyk_test_exclude`     | Which files / directories to exclude from Snyk testing. See [`--exclude`](https://docs.snyk.io/snyk-cli/commands/test#exclude-less-than-name-greater-than-less-than-name-greater-than-...greater-than). | false      |                    |
| `snyk_target_reference` | The target reference to use for Snyk testing. See [`--target-reference`](https://docs.snyk.io/snyk-cli/commands/test#target-reference-less-than-target_reference-greater-than).                         | false      |                    |

#### Secrets

| Input        | Description                                                                     | Required | Default |
|--------------|---------------------------------------------------------------------------------|----------|---------|
| `gh_token`   | The github token from the calling repository.                                   | true     |         |
| `snyk_token` | The token to use for Snyk CLI commands. This should be a service account token. | true     |         |

### Snyk vulnerability report

Worflow: [`snyk-vulnerability-report.yml`](.github/workflows/snyk-vulnerability-report.yml)

Publishes a project vulnerability report to the given Snyk organisation dashboard, via `snyk monitor`.

Optionally produces a sarif report and publishes to Github Code Scanning.

#### Pre-requisites

- Snyk compatible repository
- A secret named `SNYK_TOKEN` added to the calling repository secrets, containing a Snyk access token.

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

| Input                         | Description                                                                                                                                                                                             | Required   | Default            |
|-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------|--------------------|
| `java_version`                | The Java JDK version to run build commands with.                                                                                                                                                        | false      | `21`               |
| `java_distribution`           | The Java JDK distribution.                                                                                                                                                                              | false      | `temurin`          |
| `snyk_organisation`           | Which Snyk organisation to use. See [`--org`](https://docs.snyk.io/snyk-cli/commands/test#org-less-than-org_id-greater-than).                                                                           | false      | `legal-aid-agency` |
| `snyk_test_exclude`           | Which files / directories to exclude from Snyk testing. See [`--exclude`](https://docs.snyk.io/snyk-cli/commands/test#exclude-less-than-name-greater-than-less-than-name-greater-than-...greater-than). | false      |                    |
| `snyk_target_reference`       | The target reference to use for Snyk testing. See [`--target-reference`](https://docs.snyk.io/snyk-cli/commands/test#target-reference-less-than-target_reference-greater-than).                         | false      |                    |
| `github_code_scanning_report` | Whether to generate and upload a sarif report to [Github Code Scanning](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github).        | false      | `false`            |

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
> A PAT token will likely be required over the generated GITHUB_TOKEN here if your helm chart repository is private.

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

## Reusable actions - [`.github/actions`](.github/actions)
Individual reusable actions for common tasks.

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
      - uses: actions/checkout@v4
      - uses: ministryofjustice/laa-ccms-common-workflows/.github/actions/remove-prefix@v1
        id: get-feature-name
        with:
          string: 'feature-dev/example-feature'
          prefix: 'feature-*/'
```

Output: `result: example-feature`

#### Inputs

| Input                   | Description                               | Required | Default |
|-------------------------|-------------------------------------------|----------|---------|
| `string`                | The string to process.                    | true     |         |
| `prefix`                | The prefix to be removed from the string. | true     |         |

#### Outputs

| Output   | Description                                         |
|----------|-----------------------------------------------------|
| `result` | The resulting string with the given prefix removed. |
