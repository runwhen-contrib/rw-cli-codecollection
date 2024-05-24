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

<a id="libraries.RW.K8sHelper.k8s_helper.sanitize_messages"></a>

#### sanitize\_messages

```python
def sanitize_messages(input_string)
```

Sanitize the message string by replacing ncharacters that can't be processed into json issue details.

**Arguments**:

  - input_string: The string to be sanitized.
  

**Returns**:

  - The sanitized string.

