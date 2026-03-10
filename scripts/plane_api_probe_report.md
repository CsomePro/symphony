# Plane API Probe Report

- Generated at: 2026-03-10T18:15:42Z
- Mode: dry-run
- Overall: DRY-RUN
- Mutations: disabled
- Workspace slug: <unset>
- Project id: <unset>
- Work item id: <unset>
- Work item identifier: <unset>

## Results
- DRY-RUN `auth`: would send GET /workspaces/<workspace-slug>/projects/ with X-API-Key header; verifies X-API-Key authentication via an authenticated list request
- DRY-RUN `projects`: would send GET /workspaces/<workspace-slug>/projects/ with X-API-Key header
- DRY-RUN `states`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/states/ with X-API-Key header
- DRY-RUN `work_items`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/work-items/ with X-API-Key header
- DRY-RUN `work_item_detail`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/work-items/<work-item-id>/ with X-API-Key header
- DRY-RUN `work_item_identifier`: would send GET /workspaces/<workspace-slug>/work-items/<identifier>/ with X-API-Key header
- DRY-RUN `pagination`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/work-items/?limit=2&offset=0 with X-API-Key header; official docs baseline
- DRY-RUN `pagination`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/work-items/?per_page=2 with X-API-Key header; CE divergence probe for per_page/cursor
- DRY-RUN `expand`: would send GET /workspaces/<workspace-slug>/projects/<project-id>/work-items/<work-item-id>/?expand=state,labels with X-API-Key header; checks expand=state,labels
- DRY-RUN `update_state`: would send PATCH /workspaces/<workspace-slug>/projects/<project-id>/work-items/<work-item-id>/ with X-API-Key header; no-op PATCH when target state is omitted; body={"state":"<uuid>"}
- DRY-RUN `create_comment`: would send POST /workspaces/<workspace-slug>/projects/<project-id>/work-items/<work-item-id>/comments/ with X-API-Key header; creates a probe comment; body={"comment_html":"..."}
- DRY-RUN `update_comment`: would send PATCH /workspaces/<workspace-slug>/projects/<project-id>/work-items/<work-item-id>/comments/<comment-id>/ with X-API-Key header; updates a probe comment or existing comment id; body={"comment_html":"..."}

## Documentation Baseline

- Checked official Plane API docs on 2026-03-10.
- Projects: https://developers.plane.so/api-reference/project/list-projects
- States: https://developers.plane.so/api-reference/state/list-states
- Work items list: https://developers.plane.so/api-reference/issue/list-issues
- Work item by id: https://developers.plane.so/api-reference/issue/get-issue-detail
- Work item by identifier: https://developers.plane.so/api-reference/issue/get-issue-sequence-id
- Update work item: https://developers.plane.so/api-reference/issue/update-issue-detail
- Create comment: https://developers.plane.so/api-reference/issue-comment/add-issue-comment
- Update comment: https://developers.plane.so/api-reference/issue-comment/update-issue-comment-detail
- Official docs describe list pagination with `limit` and `offset`; this probe also exercises `per_page` and `cursor` to surface Community Edition differences.

## Required Environment

- `PLANE_BASE_URL`, e.g. `https://plane.example.com`
- `PLANE_API_KEY`
- `PLANE_WORKSPACE_SLUG`
- `PLANE_PROJECT_ID` for project-scoped endpoints
- `PLANE_WORK_ITEM_ID` for work item detail and mutation probes
- `PLANE_WORK_ITEM_IDENTIFIER` for identifier lookup
- Optional: `PLANE_TARGET_STATE_ID`, `PLANE_COMMENT_ID`, `PLANE_COMMENT_HTML`, `PLANE_COMMENT_UPDATE_HTML`

## Notes

- Dry-run mode does not require Plane credentials; it validates request coverage and report formatting only.