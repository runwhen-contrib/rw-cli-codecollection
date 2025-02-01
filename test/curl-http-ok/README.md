# cURL HTTP OK Codebundle
This codebundle validates the response code of an endpoint using cURL and provides the total time of the request. It supports Linux, macOS, Windows, and HTTP.

## SLI
It periodically uses curl to validate the endpoint and pushes a metric to the RunWhen Platform of 1 or 0. A **1** indicates that the desired http response code was received within the desired target latency. A **0** indicates that either the desired http response code or the target latency was not produced. 
This codebundle configuration requires the following user variables:

- ${URL} (string): Specifies the URL to perform requests against. It accepts a string value and has a default value of https://www.runwhen.com. Example usage: https://www.runwhen.com.

- ${TARGET_LATENCY} (string): Represents the maximum latency in seconds, allowed for requests. It should be a float value. The default value is 1.2, and an example value is 1.2.

- ${DESIRED_RESPONSE_CODE} (string): Indicates the response code that indicates success. It should be a string value. The default value is 200, and an example value is 200.

## TaskSet
Similar to the SLI, this codebundle configuration requires the following user variables:

- ${URL} (string): Specifies the URL to perform requests against. It accepts a string value and has a default value of https://www.runwhen.com. Example usage: https://www.runwhen.com.

- ${TARGET_LATENCY} (string): Represents the maximum latency in seconds, allowed for requests. It should be a float value. The default value is 1.2, and an example value is 1.2.

- ${DESIRED_RESPONSE_CODE} (string): Indicates the response code that indicates success. It should be a string value. The default value is 200, and an example value is 200.

If either the http response code or the target latency are not produced, an issue is raised with the RunWhen Platform so that further troubleshooting can take place. 

