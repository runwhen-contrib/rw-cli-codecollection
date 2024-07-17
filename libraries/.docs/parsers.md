<a id="libraries.RW.K8sApplications.parsers"></a>

# libraries.RW.K8sApplications.parsers

<a id="libraries.RW.K8sApplications.parsers.StackTraceData"></a>

## StackTraceData Objects

```python
@dataclass
class StackTraceData()
```

<a id="libraries.RW.K8sApplications.parsers.StackTraceData.line_nums"></a>

#### line\_nums

line numbers associated with exceptions per file

<a id="libraries.RW.K8sApplications.parsers.BaseStackTraceParse"></a>

## BaseStackTraceParse Objects

```python
class BaseStackTraceParse()
```

Base class for stacktrace parsing functions.
Should be stateless so it can be used as a utility class.

Note that the default behavior assumes python stack traces, and inheritors can override for other languages.

