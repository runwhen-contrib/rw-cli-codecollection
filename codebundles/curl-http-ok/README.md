# cURL HTTP OK Codebundle
This codebundle validates the response code of an endpoint using cURL and provides the total time of the request. It supports Linux, macOS, Windows, and HTTP.

## SLI
It periodically uses curl to validate the endpoint and pushes a metric to the RunWhen Platform of 1 or 0. A **1** indicates that an acceptable HTTP response code was received within the desired target latency. A **0** indicates that either an acceptable HTTP response code or the target latency was not achieved. 

This codebundle configuration requires the following user variables:

- ${URLS} (string): Comma-separated list of URLs to perform requests against. It accepts a string value and has a default value of https://www.runwhen.com. Example usage: https://www.runwhen.com,https://api.runwhen.com.

- ${TARGET_LATENCY} (string): Represents the maximum latency in seconds, allowed for requests. It should be a float value. The default value is 1.2, and an example value is 1.2.

- ${ACCEPTABLE_RESPONSE_CODES} (string): Comma-separated list of HTTP response codes that indicate success and connectivity. This allows endpoints to be considered healthy when returning various success responses (2xx), redirects (3xx), authentication challenges (401), or access denied (403). The default value is 200,201,202,204,301,302,307,401,403, and an example value is 200,201,202,204,301,302,307,401,403.

- ${VERIFY_SSL} (string): Whether to verify SSL certificates. Set to 'false' to ignore SSL certificate errors for self-signed or untrusted certificates. It should be a string value. The default value is false, and an example value is true.

## TaskSet
Similar to the SLI, this codebundle configuration requires the following user variables:

- ${URLS} (string): Comma-separated list of URLs to perform requests against. It accepts a string value and has a default value of https://www.runwhen.com. Example usage: https://www.runwhen.com,https://api.runwhen.com.

- ${TARGET_LATENCY} (string): Represents the maximum latency in seconds, allowed for requests. It should be a float value. The default value is 1.2, and an example value is 1.2.

- ${ACCEPTABLE_RESPONSE_CODES} (string): Comma-separated list of HTTP response codes that indicate success and connectivity. This allows endpoints to be considered healthy when returning various success responses (2xx), redirects (3xx), authentication challenges (401), or access denied (403). The default value is 200,201,202,204,301,302,307,401,403, and an example value is 200,201,202,204,301,302,307,401,403.

- ${VERIFY_SSL} (string): Whether to verify SSL certificates. Set to 'false' to ignore SSL certificate errors for self-signed or untrusted certificates. It should be a string value. The default value is false, and an example value is true.

If either an acceptable HTTP response code or the target latency are not achieved, an issue is raised with the RunWhen Platform so that further troubleshooting can take place.

## Key Benefits

- **Comprehensive Connectivity Detection**: Accepts a wide range of HTTP status codes (2xx, 3xx, 401, 403) that indicate the endpoint is reachable and functioning, even if not returning a perfect 200 OK.
- **Solves Authentication Challenge Problem**: 401 (authentication required) and 403 (forbidden) responses are considered healthy since they indicate the server is working and responding.
- **Handles All Redirect Types**: Supports 301 (permanent), 302 (temporary), and 307 (temporary with method preservation) redirects as healthy responses.
- **Covers Success Variations**: Includes 201 (created), 202 (accepted), and 204 (no content) for APIs that return different success codes.
- **Flexible Configuration**: Easily customize which HTTP status codes should be considered healthy for your specific use case. 

