## Error Pattern Matching
Pattern matching is leveraged against the shared error_patterns.json file, with each error tied to a specific category. In this way, each task targets one or more categories to for pattern matching. Currently we try to separate by category to reduce duplication across tasks, while also allowing to run additional tasks based on the error category. 

`GenericError`
- For simple “error”/”fail” messages that aren’t specific to exceptions, timeouts, or networking.
- Used by: Scan ... ERROR Logs task.

`Connection`
- Includes all connection failures, unreachable services, DNS issues, “service unavailable,” etc.
- Used by: Scan ... for Connection Failures task.

`Timeout`
- Used by: Scan ... for Timeout Errors task.

`Auth`
- Used by: Scan ... for Authentication and Authorization Failures task.

`Exceptions`
- Consolidates all language-specific exceptions and stack traces “Java,” “Python,” “Golang,” “C/C++,” “C#, .NET,” “Application,” “JavaScript,” etc.
- E.g., “NullPointerException,” “ReferenceError,” “TypeError,” “UnhandledPromiseRejectionWarning,” “panic,” “segfault,” etc.
- Used by:
    - Scan ... for Stack Traces
    - Scan ... for Null Pointer and Unhandled Exceptions

`AppFailure`
- For lines mentioning “fatal error,” “process exited,” “shutting down,” “core dumped,” etc.
- Used by: Scan ... for Application Restarts and Failures (along with AppRestart).

`AppRestart`
- For lines mentioning “restart.”
- Also used by: Scan ... for Application Restarts and Failures.

`Resource`
- E.g., “Out of memory,” “OOMKilled,” “memory limit exceeded,” “high CPU usage,” “CPU throttling detected.”
- Used by: Scan ... for Memory and CPU Resource Warnings.
