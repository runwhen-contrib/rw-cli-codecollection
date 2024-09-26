# Azure App Service Triage
Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `APPSERVICE`: The name of the App Service in the resource group to target with checks
- `STACKTRACE_PARSER`: What parser to use on log lines. If left as Dynamic then the first one to return a result will be used for the rest of the logs to parse.
- `INPUT_MODE`: Determines how logs are fed into the parser. Typically the default should work.
- `EXCLUDE_PATTERN`: a extended grep pattern used to filter out log results, such as exceptions/errors that you don't care about.

## Notes

This codebundle assumes the service principal authentication flow.

## TODO
- [ ] config best practices check
- [ ] Add documentation