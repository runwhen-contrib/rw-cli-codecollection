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

    recommendations = "No recommendations available."

    # Check for specific labels or annotations in the object JSON
    labels = obj_json.get("metadata", {}).get("labels", {})
    annotations = obj_json.get("metadata", {}).get("annotations", {})

    # Checking for an ArgoCD label
    if 'argocd.argoproj.io/instance' in labels:
        app_name = labels['argocd.argoproj.io/instance'].split('_')[0]
        recommendations = f"Troubleshoot ArgoCD Application `{app_name.capitalize()}`."

    # # Example: Checking for a specific annotation (dummy example)
    # if 'example.annotation/key' in annotations:
    #     recommendations += " Check the example.annotation/key for more insights."

    # Extend this function to check for other specific labels or annotations as needed

    return recommendations


