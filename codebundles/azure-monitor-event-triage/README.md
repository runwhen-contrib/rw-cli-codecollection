# Azure Monitor Event Triage

This codebundle queries for general activity log issues and raises them in a tabular report.

## Tasks
`Run Azure Monitor Activity Log Triage`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Azure service account username secret used to authenticate.
- `AZ_CLIENT_SECRET`: Azure service account client secret used to authenticate.
- `AZ_TENANT`: Azure tenant ID used to authenticate to.
- `AZ_HISTORY_RANGE`: The history range to inspect for incidents in the activity log, in hours. Defaults to 24 hours.

## Requirements
- The azure service principal should have access to the azure monitor API.

## TODO
- [ ] Additional tasks
- [ ] Refine next steps
- [ ] Array support for issues
- [ ] Add additional documentation.
