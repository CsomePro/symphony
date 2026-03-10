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

## Observed CE behavior

- `X-API-Key` auth succeeds for every ticket-scoped endpoint.
- CE accepts both `limit`/`offset` and `per_page`/`cursor` on the work-items list.
- Cursor pagination metadata is returned as `next_cursor` / `prev_cursor`; a `per_page=2` follow-up with `cursor=2:1:0` returns `200` and an empty `results` array for a single-item dataset.
- `expand=state,labels` hydrates `state` as an object and `labels` as an array.
- Work-item detail returns `sequence_id` rather than `identifier`; the probe falls back accordingly in its summary output.
- Work-item lookup by identifier still succeeds via `GET /workspaces/{slug}/work-items/{identifier}/`.
- No blocking CE-vs-doc differences were observed for this ticket scope.

## Validation record for this session

- 2026-03-10: repository baseline confirmed there was no existing Plane probe script or documented results.
- 2026-03-10: dry-run coverage and report generation passed via `bash -n`, `--help`, and `--dry-run --output`.
- 2026-03-10: live read-only probe passed for auth, projects, states, work-items list, work-item detail, identifier lookup, pagination, and `expand=state,labels`.
- 2026-03-10: live mutation probe passed for work-item state update plus comment create/update.
- 2026-03-10: official docs focus on `limit`/`offset`, while the target CE instance also accepts `per_page`/`cursor` and returns cursor metadata as `next_cursor` / `prev_cursor`.
