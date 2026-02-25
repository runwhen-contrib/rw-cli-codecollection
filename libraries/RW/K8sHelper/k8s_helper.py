import json
import logging

from robot.libraries.BuiltIn import BuiltIn

logger = logging.getLogger(__name__)


def _normalize_k8s_binary(binary: str | None) -> str:
    """Default to kubectl when binary is unset or a placeholder (e.g. missing_workspaceInfo_custom_variable)."""
    if binary is None:
        return "kubectl"
    s = (binary or "").strip()
    if not s or "missing_" in s.lower() or "workspaceinfo_custom_variable" in s.lower():
        return "kubectl"
    return s


def verify_cluster_connectivity(
    binary: str = "kubectl",
    context: str = "",
    env: dict = None,
    timeout_seconds: int = 30,
    **kwargs,
):
    """
    Verifies connectivity to a Kubernetes cluster by running 'cluster-info'.
    If the cluster is unreachable, raises a severity 3 issue and aborts the suite
    with a Fatal Error.

    Should be called from Suite Initialization after setting up kubeconfig and env.

    Args:
        binary: The Kubernetes CLI binary (kubectl or oc). Defaults to kubectl.
        context: The Kubernetes context to connect with.
        env: Environment dictionary containing KUBECONFIG path.
        timeout_seconds: Timeout for the connectivity check. Defaults to 30.
        **kwargs: Additional keyword arguments, typically secret_file__kubeconfig.
    """
    binary = _normalize_k8s_binary(binary)
    cli = BuiltIn().get_library_instance('RW.CLI')
    result = cli.run_cli(
        cmd=f"{binary} cluster-info --context {context}",
        env=env,
        include_in_history=False,
        timeout_seconds=timeout_seconds,
        **kwargs,
    )
    if result.returncode != 0:
        bi = BuiltIn()
        details = (
            f"Failed to connect to the Kubernetes cluster. This may indicate "
            f"an expired kubeconfig, network connectivity issues, or the cluster "
            f"being unreachable.\n\nSTDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}"
        )
        next_steps = (
            "Verify kubeconfig is valid and not expired\n"
            "Check network connectivity to the cluster API server\n"
            f"Verify the context '{context}' is correctly configured\n"
            "Check if the cluster is running and accessible"
        )
        try:
            core = bi.get_library_instance('RW.Core')
            core.add_issue(
                severity=3,
                expected=f"Kubernetes cluster should be reachable via configured kubeconfig and context `{context}`",
                actual=f"Unable to connect to Kubernetes cluster with context `{context}`",
                title=f"Kubernetes Cluster Connectivity Check Failed for Context `{context}`",
                reproduce_hint=f"{binary} cluster-info --context {context}",
                details=details,
                next_steps=next_steps,
            )
        except Exception as e:
            logger.warning(f"Could not add issue via RW.Core: {e}")
        bi.fatal_error(
            f"Kubernetes cluster connectivity check failed for context '{context}'. Aborting suite."
        )


def get_related_resource_recommendations(k8s_object):
    """
    Parse a Kubernetes object JSON for specific annotations or labels and return recommendations.

    Args:
    obj_json (dict): The Kubernetes object JSON.

    Returns:
    str: Recommendations based on the object's annotations or labels.
    """
    # Convert the string representation of the JSON to a Python dictionary
    try:
        obj_json = json.loads(k8s_object)
    except json.JSONDecodeError as e:
        return f"Error decoding JSON: {e}"

    recommendations = ""

    # Check for specific labels or annotations in the object JSON
    labels = obj_json.get("metadata", {}).get("labels", {})
    annotations = obj_json.get("metadata", {}).get("annotations", {})

    # Checking for an ArgoCD label
    if "argocd.argoproj.io/instance" in labels:
        app_name = labels["argocd.argoproj.io/instance"].split("_")[0]
        recommendations = f"Troubleshoot ArgoCD Application `{app_name.capitalize()}`"

    # Check for Flux Helm Resources
    elif "helm.toolkit.fluxcd.io/name" in labels:
        fluxcd_helm_name = labels["helm.toolkit.fluxcd.io/name"]
        fluxcd_helm_namespace = labels["helm.toolkit.fluxcd.io/namespace"]
        recommendations = f"Troubleshoot `{fluxcd_helm_name}` Helm Release Health in Namespace `{fluxcd_helm_namespace}`"

    # Check for Flux Kustomize Resources
    elif "kustomize.toolkit.fluxcd.io/name" in labels:
        fluxcd_helm_name = labels["kustomize.toolkit.fluxcd.io/name"]
        fluxcd_helm_namespace = labels["kustomize.toolkit.fluxcd.io/namespace"]
        recommendations = f"Get details for unready Kustomizations in Namespace `{fluxcd_helm_namespace}`"

    # Check helm after flux or argo helm managed resources
    elif "helm.sh/chart" in labels:
        helm_chart = labels["helm.sh/chart"]
        helm_namespace = annotations["meta.helm.sh/release-namespace"]
        helm_release_name = annotations["meta.helm.sh/release-name"]
        recommendations = f"Get Health Status of Helm Release `{helm_release_name}` Namespace `{helm_namespace}`"
    # Extend this function to check for other specific labels or annotations as needed

    return recommendations

def sanitize_messages(input_string):
    """Sanitize the message string by replacing ncharacters that can't be processed into json issue details.

    Args:
    - input_string: The string to be sanitized.

    Returns:
    - The sanitized string.
    """
    # Replace newline characters with an empty string
    sanitized_string = input_string.replace('\n', '')

    # Remove double quotes
    sanitized_string = sanitized_string.replace('"', '')

    return sanitized_string