# Harness pipelines for the OtterWorks applications

Every OtterWorks application is built and deployed by the shared Harness pipeline
template **Otterworks Build Deploy Template** (`Otterworks_Build_Deploy_Template`,
org `default`, project `default_project`). A per-application pipeline contains no
stage logic of its own - only template inputs.

The template stages are: CI build (Gitleaks -> build/test -> SCA -> SAST ->
BuildAndPushECR -> SBOM/SLSA/signing -> Trivy), a ServiceNow work-note update, an
IACM provisioning stage, and a NativeHelm deploy to `alert_dev`.

## Layout

| Path | Purpose |
| --- | --- |
| `apps.yaml` | Per-application inputs (path, build image, build/test/static-analysis commands) plus the shared defaults. |
| `sync_harness.py` | Renders the Harness service + pipeline YAML for each application and optionally creates/updates them through the Harness API. |
| `generated/services/*.yaml` | Rendered Harness service (NativeHelm, Helm chart from `infrastructure/helm/<app>`, ECR artifact `otterworks/<app>`). |
| `generated/pipelines/*.yaml` | Rendered pipeline: `templateRef` + `templateInputs` only. |

`generated/` is committed so the Harness state is reviewable in git; it is
regenerated from `apps.yaml`, never edited by hand.

## Usage

```bash
python3 harness/sync_harness.py                                    # render only
HARNESS_API_KEY=<pat> python3 harness/sync_harness.py --apply      # render + push to Harness
HARNESS_API_KEY=<pat> python3 harness/sync_harness.py --apply --only file-service
```

The account id is derived from the API key; `HARNESS_BASE_URL` defaults to
`https://koniag-gs.harness.io`. Entities are created if absent and updated
otherwise, so the script is safe to re-run.

`api-gateway` is described in `apps.yaml` for completeness but is skipped unless
`--include-api-gateway` is passed: it is already served by the hand-built
`Build and Deploy Otterworks Application` pipeline, which is the pipeline the
template was extracted from.

## Template version v2

v1 hardcoded the Go build/test/`go vet` commands of api-gateway, so it could only
be reused by Go services. v2 (now the stable version) adds four inputs and leaves
everything else untouched:

* `build_command`, `test_command`, `static_analysis_command` - executed inside
  `service_workspace` using `build_image`.
* `test_intelligence` - `"true"` keeps the Harness Test Intelligence step (Go,
  Java, Kotlin, Scala, C#, Python, Ruby); anything else runs the equivalent plain
  `Unit Tests` Run step instead, which is what the Rust and Node/TypeScript
  applications use.

## Known gaps

* `admin-service` (Rails) expects Postgres and Redis, which the GitHub workflow
  provides as service containers. The template has no service-dependency inputs,
  so its `test_command` skips DB-backed specs.
* All applications share the single IACM workspace
  `koniagcognitionharnessworkspace`; concurrent runs of different application
  pipelines will serialize on it.
