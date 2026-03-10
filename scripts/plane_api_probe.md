# Plane API Probe Notes

This repository now includes an independent Plane CE probe script at `scripts/plane_api_probe.sh`.

## Purpose

- Verify `X-API-Key` authentication without touching Symphony runtime code.
- Exercise the ticket-scoped endpoints for projects, states, work items, work item detail, identifier lookup, state updates, and comment create/update.
- Record how Plane Community Edition behaves for pagination and `expand=state,labels`.

## Usage

Dry run coverage review:

```bash
scripts/plane_api_probe.sh --dry-run
```

Live read-only probe:

```bash
PLANE_BASE_URL="https://plane.example.com" \
PLANE_API_KEY="..." \
PLANE_WORKSPACE_SLUG="my-workspace" \
PLANE_PROJECT_ID="project-uuid" \
PLANE_WORK_ITEM_ID="work-item-uuid" \
PLANE_WORK_ITEM_IDENTIFIER="PROJ-123" \
scripts/plane_api_probe.sh --live
```

Live mutation probe:

```bash
PLANE_BASE_URL="https://plane.example.com" \
PLANE_API_KEY="..." \
PLANE_WORKSPACE_SLUG="my-workspace" \
PLANE_PROJECT_ID="project-uuid" \
PLANE_WORK_ITEM_ID="work-item-uuid" \
PLANE_WORK_ITEM_IDENTIFIER="PROJ-123" \
scripts/plane_api_probe.sh --live --mutate
```

The script prints a markdown report to stdout and can also write one to disk with `--output <file>`.

## Official docs baseline checked on 2026-03-10

- Projects: `GET /api/v1/workspaces/{slug}/projects/`
- States: `GET /api/v1/workspaces/{slug}/projects/{pid}/states/`
- Work items: `GET /api/v1/workspaces/{slug}/projects/{pid}/work-items/`
- Work item by id: `GET /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/`
- Work item by identifier: `GET /api/v1/workspaces/{slug}/work-items/{identifier}/`
- Update work item: `PATCH /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/`
- Create comment: `POST /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/`
- Update comment: `PATCH /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/{cid}/`

Reference pages:

- `https://developers.plane.so/api-reference/project/list-projects`
- `https://developers.plane.so/api-reference/state/list-states`
- `https://developers.plane.so/api-reference/issue/list-issues`
- `https://developers.plane.so/api-reference/issue/get-issue-detail`
- `https://developers.plane.so/api-reference/issue/get-issue-sequence-id`
- `https://developers.plane.so/api-reference/issue/update-issue-detail`
- `https://developers.plane.so/api-reference/issue-comment/add-issue-comment`
- `https://developers.plane.so/api-reference/issue-comment/update-issue-comment-detail`

Observed documentation difference to verify in CE:

- Official docs describe list pagination with `limit` and `offset`.
- Ticket `CSO-65` requires explicit verification of `per_page` and `cursor` behavior.
- The probe script therefore tests both forms and reports whether CE supports, ignores, or rejects `per_page`/`cursor`.

## Validation record for this session

- 2026-03-10: repository baseline confirmed there was no existing Plane probe script or documented results.
- 2026-03-10: local environment had no `PLANE_*` variables set, so live Plane CE execution could not be completed in this session.
- 2026-03-10: dry-run coverage and report generation are the only completed validations so far.
