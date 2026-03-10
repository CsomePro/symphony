# Plane API Probe Report

- Generated at: 2026-03-10T18:55:12Z
- Mode: live
- Overall: PASS
- Mutations: enabled
- Workspace slug: hunter
- Project id: a10cc158-43eb-40a6-b14f-36f23aad612f
- Work item id: fa9a927c-1271-4fde-ab84-de104416dc95
- Work item identifier: VULNERABLE-1

## Results
- PASS `projects`: GET /workspaces/hunter/projects/ returned 200; count=1
- PASS `auth`: Authenticated request accepted using X-API-Key header; status=200
- PASS `states`: GET /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/states/ returned 200; count=8
- PASS `work_items`: GET /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/work-items/ returned 200; count=1
- PASS `work_item_detail`: GET /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/work-items/fa9a927c-1271-4fde-ab84-de104416dc95/ returned 200; identifier=1
- PASS `work_item_identifier`: GET /workspaces/hunter/work-items/VULNERABLE-1/ returned 200; id=fa9a927c-1271-4fde-ab84-de104416dc95
- PASS `pagination`: limit/offset request returned 200; count=1
- PASS `pagination`: per_page/cursor request returned 200; cursor=2:1:0
- PASS `expand`: expand=state,labels returned 200; state=object; labels=array
- PASS `update_state`: PATCH /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/work-items/fa9a927c-1271-4fde-ab84-de104416dc95/ returned 200; state=922a6600-a05a-4e54-a27d-1049567e1dae
- PASS `create_comment`: POST /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/work-items/fa9a927c-1271-4fde-ab84-de104416dc95/comments/ returned 201; comment_id=17b8989c-5a9c-44a0-ac9c-f2df44be95be
- PASS `update_comment`: PATCH /workspaces/hunter/projects/a10cc158-43eb-40a6-b14f-36f23aad612f/work-items/fa9a927c-1271-4fde-ab84-de104416dc95/comments/17b8989c-5a9c-44a0-ac9c-f2df44be95be/ returned 200

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

- Live mode executes real HTTP requests against Plane using X-API-Key authentication.