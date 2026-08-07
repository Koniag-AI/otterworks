#!/usr/bin/env python3
"""Render and (optionally) apply the Harness services and template-based
pipelines for every OtterWorks application described in harness/apps.yaml.

Each pipeline is a thin instance of the shared pipeline template
"Otterworks Build Deploy Template" - it only supplies template inputs
(codebase, per-language build/test commands, ECR image path, Harness service,
environment and infrastructure), so the build/scan/supply-chain/deploy logic
lives in exactly one place.

Usage:
  python3 harness/sync_harness.py                 # render YAML into harness/generated
  python3 harness/sync_harness.py --apply         # render, then create/update in Harness
  python3 harness/sync_harness.py --apply --only auth-service

Requires HARNESS_API_KEY (a Harness PAT/SAT) when --apply is used;
HARNESS_BASE_URL defaults to the koniag-gs vanity URL and the account id is
taken from the second dot-separated segment of the key.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_DIR = REPO_ROOT / "harness"
GENERATED_DIR = HARNESS_DIR / "generated"

IMAGE_TAG_EXPR = (
    "<+pipeline.stages.Build_Otterworks.spec.execution.steps"
    ".Build_and_Push_API_Gateway_Image_to_ECR"
    ".artifact_Build_and_Push_API_Gateway_Image_to_ECR"
    ".stepArtifacts.publishedImageArtifacts[0].tag>"
)


def identifier(name: str) -> str:
    return name.replace("-", "_")


def title(name: str) -> str:
    return " ".join(part.capitalize() for part in name.split("-"))


def service_identifier(name: str) -> str:
    return "otterworks_" + name.replace("-", "")


def service_yaml(app: dict, d: dict) -> str:
    art = identifier(app["name"])
    svc = {
        "service": {
            "name": "otterworks_" + app["name"],
            "identifier": service_identifier(app["name"]),
            "orgIdentifier": d["org"],
            "projectIdentifier": d["project"],
            "serviceDefinition": {
                "type": "NativeHelm",
                "spec": {
                    "manifests": [
                        {
                            "manifest": {
                                "identifier": art,
                                "type": "HelmChart",
                                "spec": {
                                    "store": {
                                        "type": "Github",
                                        "spec": {
                                            "connectorRef": d["codebase_connector"],
                                            "gitFetchType": "Branch",
                                            "folderPath": "infrastructure/helm/%s" % app["name"],
                                            "repoName": d["codebase_repo"],
                                            "branch": d["helm_branch"],
                                        },
                                    },
                                    "subChartPath": "",
                                    "valuesPaths": [
                                        "infrastructure/helm/%s/values.yaml" % app["name"]
                                    ],
                                    "optionalValuesYaml": False,
                                    "skipResourceVersioning": False,
                                    "enableDeclarativeRollback": False,
                                    "helmVersion": "V3",
                                    "fetchHelmChartMetadata": False,
                                },
                            }
                        }
                    ],
                    "artifacts": {
                        "primary": {
                            "primaryArtifactRef": "<+input>",
                            "sources": [
                                {
                                    "identifier": art,
                                    "type": "Ecr",
                                    "spec": {
                                        "connectorRef": d["aws_connector"],
                                        "imagePath": "otterworks/%s" % app["name"],
                                        "tag": IMAGE_TAG_EXPR,
                                        "digest": "",
                                        "region": d["aws_region"],
                                    },
                                }
                            ],
                        }
                    },
                },
            },
        }
    }
    return yaml.safe_dump(svc, sort_keys=False, width=10000)


def pipeline_yaml(app: dict, d: dict) -> str:
    path = app["path"]
    keep = lambda name, default: {  # noqa: E731 - template inputs keep their defaults
        "name": name,
        "type": "String",
        "value": '<+input>.default("%s")' % default,
    }
    fixed = lambda name, value: {"name": name, "type": "String", "value": value}  # noqa: E731
    pipeline = {
        "pipeline": {
            "name": "Build and Deploy %s" % title(app["name"]),
            "identifier": "Build_and_Deploy_%s" % identifier(app["name"]),
            "projectIdentifier": d["project"],
            "orgIdentifier": d["org"],
            "tags": {"application": app["name"]},
            "template": {
                "templateRef": d["template_ref"],
                "versionLabel": d["template_version"],
                "templateInputs": {
                    "properties": {
                        "ci": {
                            "codebase": {
                                "connectorRef": d["codebase_connector"],
                                "repoName": d["codebase_repo"],
                                "build": "<+input>",
                            }
                        }
                    },
                    "variables": [
                        keep("servicenow_incident_number", ""),
                        keep("aws_connector", d["aws_connector"]),
                        keep("aws_account_id", d["aws_account_id"]),
                        keep("aws_region", d["aws_region"]),
                        fixed("ecr_image_path", "otterworks/%s" % app["name"]),
                        fixed("service_workspace", "./%s" % path),
                        fixed("build_context", "./%s" % path),
                        fixed("dockerfile_path", "./%s/Dockerfile" % path),
                        fixed("build_image", app["build_image"]),
                        keep("sonar_project_key", d["sonar_project_key"]),
                        keep("delegate_selector", d["delegate_selector"]),
                        keep("servicenow_connector", d["servicenow_connector"]),
                        fixed("build_command", app["build_command"]),
                        fixed("test_command", app["test_command"]),
                        fixed("static_analysis_command", app["static_analysis_command"]),
                        fixed("test_intelligence", app.get("test_intelligence", "false")),
                    ],
                    "stages": [
                        {
                            "stage": {
                                "identifier": "Provision_Infra",
                                "type": "IACM",
                                "spec": {"workspace": d["iacm_workspace"]},
                            }
                        },
                        {
                            "stage": {
                                "identifier": "Deploy_to_Dev",
                                "type": "Deployment",
                                "spec": {
                                    "service": {
                                        "serviceRef": service_identifier(app["name"]),
                                        "serviceInputs": {
                                            "serviceDefinition": {
                                                "type": "NativeHelm",
                                                "spec": {
                                                    "artifacts": {
                                                        "primary": {
                                                            "primaryArtifactRef": identifier(
                                                                app["name"]
                                                            )
                                                        }
                                                    }
                                                },
                                            }
                                        },
                                    },
                                    "environment": {
                                        "environmentRef": d["environment"],
                                        "gitBranch": d["environment_git_branch"],
                                        "infrastructureDefinitions": [
                                            {"identifier": d["infrastructure"]}
                                        ],
                                    },
                                },
                            }
                        },
                    ],
                },
            },
        }
    }
    return yaml.safe_dump(pipeline, sort_keys=False, width=10000)


class Harness:
    def __init__(self) -> None:
        self.key = os.environ["HARNESS_API_KEY"]
        self.base = os.environ.get("HARNESS_BASE_URL", "https://koniag-gs.harness.io").rstrip("/")
        self.account = self.key.split(".")[1]

    def _call(self, method: str, path: str, params: dict, body: str | None, ctype: str):
        params = dict(params, accountIdentifier=self.account)
        query = "&".join("%s=%s" % (k, v) for k, v in params.items())
        req = urllib.request.Request(
            "%s%s?%s" % (self.base, path, query),
            data=body.encode() if body else None,
            method=method,
            headers={"x-api-key": self.key, "Content-Type": ctype},
        )
        try:
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            with urllib.request.urlopen(req) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def upsert_service(self, ident: str, name: str, org: str, project: str, svc_yaml: str) -> str:
        body = json.dumps(
            {
                "identifier": ident,
                "name": name,
                "orgIdentifier": org,
                "projectIdentifier": project,
                "yaml": svc_yaml,
            }
        )
        status, text = self._call("POST", "/ng/api/servicesV2", {}, body, "application/json")
        if status == 200:
            return "created"
        if "already exists" in text or "DUPLICATE_FIELD" in text:
            status, text = self._call("PUT", "/ng/api/servicesV2", {}, body, "application/json")
            if status == 200:
                return "updated"
        raise RuntimeError("service %s failed (%s): %s" % (ident, status, text[:400]))

    def upsert_pipeline(self, ident: str, org: str, project: str, pipe_yaml: str) -> str:
        params = {"orgIdentifier": org, "projectIdentifier": project}
        status, text = self._call(
            "POST", "/pipeline/api/pipelines/v2", params, pipe_yaml, "application/yaml"
        )
        if status == 200:
            return "created"
        if "already exists" in text or "DUPLICATE_FIELD" in text:
            status, text = self._call(
                "PUT",
                "/pipeline/api/pipelines/v2/%s" % ident,
                params,
                pipe_yaml,
                "application/yaml",
            )
            if status == 200:
                return "updated"
        raise RuntimeError("pipeline %s failed (%s): %s" % (ident, status, text[:400]))

    def upsert_template(self, org: str, project: str, tpl_yaml: str) -> str:
        params = {"orgIdentifier": org, "projectIdentifier": project}
        status, text = self._call(
            "POST", "/template/api/templates", params, tpl_yaml, "application/yaml"
        )
        if status == 200:
            return "created"
        if "already exists" in text or "DUPLICATE_FIELD" in text:
            return "exists"
        raise RuntimeError("template failed (%s): %s" % (status, text[:400]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="create/update the entities in Harness")
    ap.add_argument("--only", action="append", default=[], help="limit to these app names")
    ap.add_argument(
        "--apply-template",
        action="store_true",
        help="also create the pipeline template version from harness/template/",
    )
    ap.add_argument(
        "--include-api-gateway",
        action="store_true",
        help="also render/apply api-gateway (it already has a hand-built pipeline)",
    )
    args = ap.parse_args()

    config = yaml.safe_load((HARNESS_DIR / "apps.yaml").read_text())
    d = config["defaults"]
    apps = config["apps"]
    if not args.include_api_gateway:
        apps = [a for a in apps if a["name"] != "api-gateway"]
    if args.only:
        apps = [a for a in apps if a["name"] in args.only]
    if not apps:
        print("no applications selected", file=sys.stderr)
        return 1

    (GENERATED_DIR / "services").mkdir(parents=True, exist_ok=True)
    (GENERATED_DIR / "pipelines").mkdir(parents=True, exist_ok=True)

    harness = Harness() if args.apply else None
    if harness is not None and args.apply_template:
        tpl = (
            HARNESS_DIR / "template" / "otterworks_build_deploy_template_v2.yaml"
        ).read_text()
        print("template %s" % harness.upsert_template(d["org"], d["project"], tpl))
    for app in apps:
        svc = service_yaml(app, d)
        pipe = pipeline_yaml(app, d)
        (GENERATED_DIR / "services" / ("%s.yaml" % app["name"])).write_text(svc)
        (GENERATED_DIR / "pipelines" / ("%s.yaml" % app["name"])).write_text(pipe)
        if harness is None:
            print("rendered %s" % app["name"])
            continue
        svc_action = harness.upsert_service(
            service_identifier(app["name"]),
            "otterworks_" + app["name"],
            d["org"],
            d["project"],
            svc,
        )
        pipe_action = harness.upsert_pipeline(
            "Build_and_Deploy_%s" % identifier(app["name"]), d["org"], d["project"], pipe
        )
        print("%-22s service=%s pipeline=%s" % (app["name"], svc_action, pipe_action))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
