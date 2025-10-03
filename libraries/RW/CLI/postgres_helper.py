# Helper functions for simplifying calls to postgres workloads in kubernetes

import re, logging, json, jmespath, os, yaml
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn

from RW import platform
from RW.Core import Core

from .CLI import run_cli

logger = logging.getLogger(__name__)

PASSWORD_KEYS: list[str] = [
    "PGPASSWORD",
    "PGPASSWORD_SUPERUSER",
]
USER_KEYS: list[str] = [
    "PGUSER",
    "PGUSER_SUPERUSER",
]

# TODO: iterate on this first draft and create well-refined db model for applications in the k8s application model
# TODO: support non-postgres database lookup for app-level troubleshooting

# simple global to cache first pass and reduce kubectl calls
implicit_auth_enabled: bool = False


def get_password(
    context: str,
    namespace: str,
    kubeconfig: platform.Secret,
    env: dict = {},
    labels: str = "",
    workload_name: str = "",
    container_name: str = "",
) -> platform.Secret:
    if labels:
        labels = f"-l {labels}"
    rsp: platform.ShellServiceResponse = run_cli(
        cmd=f"kubectl --context {context} -n {namespace} get all {labels} -oyaml",
        secret_file__kubeconfig=kubeconfig,
        env=env,
    )
    if rsp.returncode == 0 and rsp.stdout:
        manifest = yaml.safe_load(rsp.stdout)
        pod_spec = {}
        if "items" in manifest:
            manifest = manifest["items"][
                0
            ]  # user more specific labels if the first result is incorrect
        if manifest["kind"] == "StatefulSet" or manifest["kind"] == "Deployment":
            pod_spec = manifest["spec"]["template"]["spec"]
        if manifest["kind"] == "Pod":
            pod_spec = manifest["spec"]
        secret_name: str = ""
        secret_key: str = ""
        secret_value: str = ""
        for container in pod_spec["containers"]:
            if secret_name or secret_value:
                break
            if "env" in container:
                for container_env in container["env"]:
                    if container_env["name"] in PASSWORD_KEYS:
                        if "valueFrom" in container_env:
                            secret_name = container_env["valueFrom"]["secretKeyRef"][
                                "name"
                            ]
                            secret_key = container_env["valueFrom"]["secretKeyRef"][
                                "key"
                            ]
                        elif "value" in container_env:
                            secret_value = container_env["value"]
                            secret_key = container_env["name"]
                        break
        if secret_value:
            return platform.Secret(secret_key, secret_value)
        elif secret_key and secret_name:
            rsp: platform.ShellServiceResponse = run_cli(
                cmd=f'kubectl --context {context} -n {namespace} get secret/{secret_name} -ojsonpath="{{.data.{secret_key}}}" | base64 -d',
                secret_file__kubeconfig=kubeconfig,
                env=env,
                debug=False,
            )
            if rsp.returncode == 0 and rsp.stdout:
                return platform.Secret(secret_key, rsp.stdout)
    return None


def _test_implicit_auth(
    base_cmd: str,
    username: platform.Secret,
    kubeconfig: platform.Secret,
    env: dict = {},
) -> bool:
    # if we've already tested it, imediately return true to save on future calls
    global implicit_auth_enabled
    if implicit_auth_enabled:
        return implicit_auth_enabled
    test_qry: str = "SELECT 1;"
    rsp: platform.ShellServiceResponse = run_cli(
        cmd=f'{base_cmd} psql -U ${username.key} -c "{test_qry}"',
        secret__username=username,
        secret_file__kubeconfig=kubeconfig,
        env=env,
    )
    if rsp.returncode == 0:
        logger.info(f"Implicit auth test stdout: {rsp.stdout}")
        implicit_auth_enabled = True
        return implicit_auth_enabled
    return False


def get_user(
    context: str,
    namespace: str,
    kubeconfig: platform.Secret,
    env: dict = {},
    labels: str = "",
    workload_name: str = "",
    container_name: str = "",
) -> platform.Secret:
    if labels:
        labels = f"-l {labels}"
    rsp: platform.ShellServiceResponse = run_cli(
        cmd=f"kubectl --context {context} -n {namespace} get all {labels} -oyaml",
        secret_file__kubeconfig=kubeconfig,
        env=env,
    )
    if rsp.returncode == 0 and rsp.stdout:
        manifest = yaml.safe_load(rsp.stdout)
        if "items" in manifest:
            manifest = manifest["items"][
                0
            ]  # user more specific labels if the first result is incorrect
        pod_spec = {}
        if manifest["kind"] == "StatefulSet" or manifest["kind"] == "Deployment":
            pod_spec = manifest["spec"]["template"]["spec"]
        if manifest["kind"] == "Pod":
            pod_spec = manifest["spec"]
        secret_name: str = ""
        secret_key: str = ""
        secret_value: str = ""
        for container in pod_spec["containers"]:
            if secret_name or secret_value:
                break
            if "env" in container:
                for container_env in container["env"]:
                    if container_env["name"] in USER_KEYS:
                        if "valueFrom" in container_env:
                            secret_name = container_env["valueFrom"]["secretKeyRef"][
                                "name"
                            ]
                            secret_key = container_env["valueFrom"]["secretKeyRef"][
                                "key"
                            ]
                        elif "value" in container_env:
                            secret_value = container_env["value"]
                            secret_key = container_env["name"]
                        break
        if secret_value:
            logger.info(f"user env: {secret_key}={secret_value}")
            return platform.Secret(secret_key, secret_value)
        elif secret_key and secret_name:
            rsp: platform.ShellServiceResponse = run_cli(
                cmd=f'kubectl --context {context} -n {namespace} get secret/{secret_name} -ojsonpath="{{.data.{secret_key}}}" | base64 -d',
                secret_file__kubeconfig=kubeconfig,
                env=env,
                debug=False,
            )
            if rsp.returncode == 0 and rsp.stdout:
                return platform.Secret(secret_key, rsp.stdout)
    return None


# TODO: implement to support application-level checks
def get_database(
    context: str,
    namespace: str,
    kubeconfig: platform.Secret,
    env: dict = {},
    labels: str = "",
    workload_name: str = "",
    container_name: str = "",
) -> str:
    return ""


def _get_workload_fqn(
    context: str,
    namespace: str,
    kubeconfig: platform.Secret,
    env: dict = {},
    labels: str = "",
) -> str:
    if labels:
        labels = f"-l {labels}"
    fqn: str = ""
    if labels:
        rsp: platform.ShellServiceResponse = run_cli(
            cmd=f"kubectl --context {context} -n {namespace} get all {labels} -oname",
            secret_file__kubeconfig=kubeconfig,
            env=env,
        )
        if rsp.returncode == 0 and rsp.stdout:
            fqn = rsp.stdout.strip()
    return fqn


# TODO: support dynamic db name for app data
def k8s_postgres_query(
    query: str,
    context: str,
    namespace: str,
    kubeconfig: platform.Secret,
    binary_name: str = "kubectl",
    env: dict = {},
    labels: str = "",
    workload_name: str = "",
    container_name: str = "",
    database_name: str = "postgres",
    opt_flags: str = "",
) -> platform.ShellServiceResponse:
    cnf: str = ""
    if container_name:
        cnf = f"-c {container_name}"
    if not workload_name:
        workload_name = _get_workload_fqn(
            context=context,
            namespace=namespace,
            kubeconfig=kubeconfig,
            env=env,
            labels=labels,
        )
    if not workload_name:
        raise Exception(f"Could not find workload name, got {workload_name} instead")
    cli_base: str = f"{binary_name} --context {context} -n {namespace} exec {workload_name} {cnf} --"
    logger.info(f"Created cli base: {cli_base}")
    username: platform.Secret = get_user(
        context=context,
        namespace=namespace,
        kubeconfig=kubeconfig,
        env=env,
        labels=labels,
        workload_name=workload_name,
        container_name=container_name,
    )
    rsp: platform.ShellServiceResponse = None
    if _test_implicit_auth(
        base_cmd=cli_base,
        username=username,
        kubeconfig=kubeconfig,
        env=env,
    ):
        logger.info(f"Implicit auth test succeeded")
        psql_config: str = (
            f"psql {opt_flags} -qAt -U ${username.key} -d {database_name}"
        )
        rsp: platform.ShellServiceResponse = run_cli(
            cmd=f'{cli_base} {psql_config} -c "{query}"',
            secret__username=username,
            secret_file__kubeconfig=kubeconfig,
            env=env,
        )
    else:
        password: platform.Secret = get_password(
            context=context,
            namespace=namespace,
            kubeconfig=kubeconfig,
            env=env,
            labels=labels,
            workload_name=workload_name,
            container_name=container_name,
        )
        psql_config: str = f'PGPASSWORD="${password.key}" psql {opt_flags} -qAt -U ${username.key} -d {database_name}'
        rsp: platform.ShellServiceResponse = run_cli(
            cmd=f"{cli_base} bash -c '{psql_config} -c \"{query}\"'",
            secret__username=username,
            secret__password=password,
            secret_file__kubeconfig=kubeconfig,
            env=env,
        )
    return rsp
