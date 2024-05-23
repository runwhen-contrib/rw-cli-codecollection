import json


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