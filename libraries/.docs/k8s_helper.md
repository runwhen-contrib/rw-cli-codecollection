<a id="libraries.RW.K8sHelper.k8s_helper"></a>

# libraries.RW.K8sHelper.k8s\_helper

<a id="libraries.RW.K8sHelper.k8s_helper.get_related_resource_recommendations"></a>

#### get\_related\_resource\_recommendations

```python
def get_related_resource_recommendations(k8s_object)
```

Parse a Kubernetes object JSON for specific annotations or labels and return recommendations.

**Arguments**:

- `obj_json` _dict_ - The Kubernetes object JSON.
  

**Returns**:

- `str` - Recommendations based on the object's annotations or labels.

