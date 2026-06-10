# Atlassian License Reclamation Report

**Organization:** Test Org (`test-org`)
**Generated:** 2026-06-10T13:38:05Z

## Executive Summary

| Category | Reclaimable signal | Estimated seats |
|----------|-------------------|-----------------|
| Inactive billable users (>90d) | 0 issue(s) | 0 |
| Redundant product access | 1 issue(s) | 10 |
| Stale pending invites (>=30d) | 1 issue(s) | 8 |

## Prioritized Recommendations

1. **Suspend before remove** — suspend inactive users first to stop billing while preserving group memberships for easy restore.
2. **Revoke stale invites** — pending invitations consume tier capacity until revoked in Atlassian Administration.
3. **Consolidate product access** — remove redundant product licenses for users active on a subset of products.
4. **Teamwork Collection note** — duplicate product rows may not imply duplicate billing; confirm licensing model before bulk removal.

## Administration Paths

- Managed accounts: https://admin.atlassian.com/o/test-org/users
- Suspend (directory API, operator action): POST /v2/orgs/{orgId}/directories/{directoryId}/users/{accountId}/suspend
- Remove from directory (operator action): DELETE /v2/orgs/{orgId}/directories/{directoryId}/users/{accountId}

## Findings Detail

### Inactive Billable Users
    Inactive Billable Users Analysis — Test Org
    ============================================================
    Billable users scanned: 5
    Inactive billable users (>90d): 0
    
    By product:
    
    Sample inactive users (up to 10):

### Product Overlap
    Product Overlap Analysis — Test Org
    =================================================
    Users with 2+ licensed products but inactive on some: 5
    
    Note: Under Teamwork Collection licensing, duplicate product rows may not imply duplicate billing.
          Consolidate access when users are active on only a subset of assigned products.
    
    - Overlap User 1 <overlap1@gamma.example>: licensed=jira-software,confluence,loom active_on=jira-software redundant=confluence,loom
    - Overlap User 2 <overlap2@gamma.example>: licensed=jira-software,confluence,loom active_on=jira-software redundant=confluence,loom
    - Overlap User 3 <overlap3@gamma.example>: licensed=jira-software,confluence,loom active_on=jira-software redundant=confluence,loom
    - Overlap User 4 <overlap4@gamma.example>: licensed=jira-software,confluence,loom active_on=jira-software redundant=confluence,loom
    - Overlap User 5 <overlap5@gamma.example>: licensed=jira-software,confluence,loom active_on=jira-software redundant=confluence,loom

### Pending Invites
    Pending Invites Analysis — Test Org
    ===============================================
    Pending / unaccepted users: 8
    Stale invites (>=30 days): 8
    
    - pending1@gamma.example status=pending days_pending=191 stale=true
    - pending2@gamma.example status=pending days_pending=207 stale=true
    - pending3@gamma.example status=pending days_pending=252 stale=true
    - pending4@gamma.example status=pending days_pending=282 stale=true
    - pending5@gamma.example status=pending days_pending=313 stale=true
    - pending6@gamma.example status=pending days_pending=344 stale=true
    - pending7@gamma.example status=pending days_pending=374 stale=true
    - pending8@gamma.example status=pending days_pending=405 stale=true
