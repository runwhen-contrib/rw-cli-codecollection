# GitHub Actions Artifact Analysis
This codebundle is highly configurable and integrates with GitHub Actions and workflow artifacts. It downloads a specified artifact from the last workflow run, analyzes a artifact with a user provided command (typically using linux / bash tools like jq) 

## Authentication

This codebundle supports two authentication methods:

1. **GitHub Personal Access Token (PAT)**: Set the `GITHUB_TOKEN` secret.
2. **GitHub App Credentials**: Set `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and `GITHUB_APP_PRIVATE_KEY` secrets. (INSTALLATION_ID is optional, auto-discovered via API if unset)
| `GITHUB_APP_CLIENT_ID` | GitHub App Client ID (used to auto-discover installation) | no |

> **Note**: Provide either `GITHUB_TOKEN` **or** all three GitHub App credentials.

## SLI
This SLI downloads the artifact from the latest run of the GitHub Actions workflow, runs the analysis command (which must result in a metric), and pushes the metric to the RunWhen Platform. 

## TaskSet
This SLI downloads the artifact from the latest GitHub Actions workflow run, executes the analysis command and adds the details to the report. It can also generate Issues if: 
- a user specified string is found in the report output
- the latest run didn't complete successfully
- the latest run is older than the desired time period ($PERIOD_HOURS)
