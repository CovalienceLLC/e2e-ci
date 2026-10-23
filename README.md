# Covalience E2E tests — CI setup

Run the Covalience end-to-end test suite in your CI with one step. The runner
pulls a pre-built, pinned test image and executes it against your application; it
works on any Linux runner with `bash`, `curl`, `jq` and `docker`.

## What Covalience gives you

- A **license key** — one secret, issued once. Store it as a CI secret.
- The **broker URL**.

## Secrets to configure in your CI

| Name | What it is |
|---|---|
| `COV_LICENSE_KEY` | The license key Covalience issued you |
| `COV_BROKER_URL` | The broker URL Covalience gave you |
| `TEST_BASE_URL` | Your application under test |
| `COV_ROLE_CREDENTIALS` | Contents of `role_credentials.json` (the test accounts) |

`COV_ROLE_CREDENTIALS` holds your own test-account credentials and MFA seeds —
keep it in your secret store, never in the repo.

## Add the runner

You can either fetch the script from Covalience at run time (recommended — you
always get the current pinned version) or commit it to your repo.

### Recommended: fetch and verify at run time

Covalience publishes the script and its checksum per version. Your step fetches
it, verifies the checksum (so a tampered file never executes), and runs it:

```bash
set -euo pipefail
SCRIPT_URL="https://raw.githubusercontent.com/CovalienceLLC/e2e-ci/<commit-sha>/run-e2e.sh"
EXPECTED_SHA="<sha256-from-covalience>"
curl -fsSL "$SCRIPT_URL" -o /tmp/run-e2e.sh
echo "${EXPECTED_SHA}  /tmp/run-e2e.sh" | sha256sum -c -
bash /tmp/run-e2e.sh
```

The URL is pinned to an immutable commit, and the checksum guards against
tampering. In the platform snippets below, replace `ci/run-e2e.sh` with these
lines (keeping the same `env:` block).

### Alternative: commit the script

Commit [`run-e2e.sh`](./run-e2e.sh) to your repo (e.g. `ci/run-e2e.sh`) and call
it directly, as shown in the snippets below.

### GitHub Actions

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ci/run-e2e.sh
        env:
          COV_BROKER_URL:      ${{ secrets.COV_BROKER_URL }}
          COV_LICENSE_KEY:     ${{ secrets.COV_LICENSE_KEY }}
          TEST_BASE_URL:       ${{ secrets.TEST_BASE_URL }}
          COV_ROLE_CREDENTIALS: ${{ secrets.COV_ROLE_CREDENTIALS }}
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: e2e-results
          path: e2e-results/
```

### GitLab CI

```yaml
e2e:
  image: docker:27
  services: [docker:27-dind]
  before_script: [apk add --no-cache bash curl jq]
  script: [bash ci/run-e2e.sh]
  artifacts:
    when: always
    paths: [e2e-results/]
    reports:
      junit: e2e-results/junit.xml
  # COV_* and TEST_BASE_URL set as masked CI/CD variables
```

### Bitbucket Pipelines

```yaml
pipelines:
  default:
    - step:
        services: [docker]
        script:
          - apt-get update && apt-get install -y jq
          - bash ci/run-e2e.sh
        artifacts: [e2e-results/**]
  # COV_* and TEST_BASE_URL set as repository variables (secured)
```

### Azure Pipelines

```yaml
pool: { vmImage: ubuntu-latest }
steps:
  - bash: ci/run-e2e.sh
    env:
      COV_BROKER_URL:       $(COV_BROKER_URL)
      COV_LICENSE_KEY:      $(COV_LICENSE_KEY)
      TEST_BASE_URL:        $(TEST_BASE_URL)
      COV_ROLE_CREDENTIALS: $(COV_ROLE_CREDENTIALS)
  - task: PublishTestResults@2
    condition: always()
    inputs:
      testResultsFormat: JUnit
      testResultsFiles: e2e-results/junit.xml
```

## Options

Set these as environment variables to change behaviour:

| Variable | Default | Values |
|---|---|---|
| `COV_TEST_MODE` | `regression` | `story`, `smoke`, `regression` |
| `COV_IMAGE_TAG` | `stable` | any published tag |
| `COV_RESULTS_DIR` | `./e2e-results` | any path |
| `TEST_BROWSERS` | `chromium` | `chromium`, `firefox`, `webkit` (comma-separated) |
| `COV_ROLE_CREDENTIALS_FILE` | — | path to a file, instead of inline `COV_ROLE_CREDENTIALS` |

## Results

The suite writes `e2e-results/junit.xml`. Point your CI's test-reporting step at
it (shown above) to get pass/fail per test in the native UI.

## Notes

- **Docker must be available** on the runner. GitHub/Azure `ubuntu-latest` have
  it; GitLab needs the `docker:dind` service; Bitbucket needs the `docker`
  service (shown above).
- The pull credential the runner receives is **short-lived (\~1 hour)** and
  scoped to your repository only.
- Pin `COV_IMAGE_TAG` to a specific version instead of `stable` if you want to
  control exactly when you pick up a new release.
