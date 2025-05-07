# Azure App Service Triage
Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

export APPSERVICE
export AZ_RESOURCE_GROUP

## Notes

This codebundle assumes the service principal authentication flow.

## TODO
- [ ] look for notable activities in list
- [ ] config best practices check
- [ ] Add documentation