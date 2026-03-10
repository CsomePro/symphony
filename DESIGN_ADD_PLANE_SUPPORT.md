# Symphony × Plane 集成设计文档

Status: Draft v1
Date: 2026-03-10

## 1. 概述

本文档描述为 Symphony 增加 `tracker.kind: plane` 支持的技术设计，使 Symphony 能以 [Plane](https://github.com/makeplane/plane)（特别是 Community Edition 自托管版）作为 issue tracker 来源，替代或并行使用当前仅支持的 Linear。

### 1.1 设计目标

- 在 Symphony 已有的 `SymphonyElixir.Tracker` behaviour 之上新增 Plane 适配器
- 复用 Symphony 现有的 orchestrator、workspace manager、agent runner，不改动核心调度逻辑
- 通过 Plane REST API v1 + API Key 认证进行所有数据交互
- 保持与 Linear 适配器相同的接口契约（5 个 callback）
- 最小可行闭环：拉取 work item → 调度 agent → 同步状态 → 维护 workpad comment

### 1.2 适用范围

| 维度 | 范围 |
|------|------|
| Plane 版本 | Community Edition (self-hosted) |
| 认证方式 | API Key (`X-API-Key` header) |
| API 版本 | REST API v1 (`/api/v1/`) |
| Project 范围 | 单 workspace + 单 project（第一版） |
| Agent 工具层 | 第一版不做 Plane MCP/Agent Tooling |

---

## 2. 架构设计

### 2.1 系统层次

```
┌─────────────────────────────────────────────┐
│              Symphony Orchestrator          │
│          (poll → dispatch → reconcile)      │
└───────────────────┬─────────────────────────┘
                    │  SymphonyElixir.Tracker behaviour
                    │
        ┌───────────┼───────────┐
        │           │           │
   ┌────▼────┐ ┌────▼────┐ ┌───▼──────┐
   │ Linear  │ │  Plane  │ │ Memory   │
   │ Adapter │ │ Adapter │ │ (test)   │
   └────┬────┘ └────┬────┘ └──────────┘
        │           │
   GraphQL API   REST API v1
   (Linear)      (Plane CE)
```

### 2.2 新增模块结构

```
lib/symphony_elixir/
├── tracker.ex                          # 已有 behaviour + adapter dispatch
├── linear/
│   ├── adapter.ex                      # 已有 Linear 适配器
│   ├── client.ex                       # 已有 Linear GraphQL 客户端
│   └── issue.ex                        # 已有 Linear issue struct
└── plane/                              # ★ 新增
    ├── adapter.ex                      # Plane 适配器 (实现 Tracker behaviour)
    ├── client.ex                       # Plane REST API 客户端
    ├── issue.ex                        # Plane work item → 统一 issue struct
    └── state_cache.ex                  # 状态名称 ↔ UUID 映射缓存
```

### 2.3 Tracker Dispatch 修改

在 `SymphonyElixir.Tracker.adapter/0` 中增加 `"plane"` 分支：

```elixir
def adapter do
  case Config.settings!().tracker.kind do
    "memory" -> SymphonyElixir.Tracker.Memory
    "plane"  -> SymphonyElixir.Plane.Adapter       # ★ 新增
    _        -> SymphonyElixir.Linear.Adapter
  end
end
```

---

## 3. Plane REST API 接口映射

### 3.1 认证

```
Header: X-API-Key: <api_key>
Content-Type: application/json
```

### 3.2 Base URL

```
{base_url}/api/v1
```

例：`http://192.168.8.107:8080/api/v1`

### 3.3 核心 API 端点

| 操作 | 方法 | 路径 | 用途 |
|------|------|------|------|
| 列出 States | GET | `/workspaces/{slug}/projects/{pid}/states/` | 启动时构建状态映射表 |
| 列出 Work Items | GET | `/workspaces/{slug}/projects/{pid}/work-items/` | 拉取候选任务 |
| 获取单个 Work Item | GET | `/workspaces/{slug}/projects/{pid}/work-items/{wid}/` | 读取详情 |
| 按标识获取 Work Item | GET | `/workspaces/{slug}/work-items/{identifier}/` | 按 ENG-123 格式查询 |
| 更新 Work Item | PATCH | `/workspaces/{slug}/projects/{pid}/work-items/{wid}/` | 更新状态等 |
| 列出评论 | GET | `/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/` | 查找 workpad comment |
| 创建评论 | POST | `/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/` | 创建 workpad comment |
| 更新评论 | PATCH | `/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/{cid}/` | 更新 workpad comment |

### 3.4 分页

Plane 使用 cursor-based 分页，格式为 `value:offset:is_prev`：

```
GET /work-items/?per_page=100&cursor=100:1:0
```

响应包含 `next_cursor`、`next_page_results`、`results` 等字段。

### 3.5 速率限制

- 60 请求/分钟/API Key
- 响应 Header：`X-RateLimit-Remaining`、`X-RateLimit-Reset`
- 建议 poll_interval 设为 15–30 秒，避免触发 429

### 3.6 查询优化

Plane 支持 `expand` 和 `fields` 参数：

```
GET /work-items/?expand=state,labels&fields=id,name,state,priority,sequence_id
```

在列出 work items 时使用 `expand=state` 可避免额外请求获取状态名称。

---

## 4. 数据模型映射

### 4.1 Plane Work Item → Symphony Issue

Plane 的 work item 需要归一化为与 `SymphonyElixir.Linear.Issue` 兼容的结构。

新增 `SymphonyElixir.Plane.Issue` struct：

```elixir
defstruct [
  :id,                # Plane work item UUID
  :identifier,        # "PROJ-123" (由 project.identifier + sequence_id 拼接)
  :title,             # work item name
  :description,       # description_html 或 description_stripped
  :priority,          # 映射: urgent→1, high→2, medium→3, low→4, none→nil
  :state,             # 状态名称 (通过 expand=state 或 state_cache 反查)
  :branch_name,       # nil (Plane 无此字段)
  :url,               # 拼接: {base_url}/{workspace_slug}/projects/{pid}/issues/{wid}
  :assignee_id,       # assignees 列表的第一个
  blocked_by: [],     # 第一版暂不实现
  labels: [],         # labels UUID 列表 (expand=labels 时可获取名称)
  assigned_to_worker: true,
  created_at: nil,
  updated_at: nil
]
```

### 4.2 字段映射表

| Symphony Issue Field | Plane Work Item Field | 转换规则 |
|---------------------|-----------------------|---------|
| `id` | `id` | 直接使用 UUID |
| `identifier` | `sequence_id` + project `identifier` | 拼接为 `"PROJ-123"` |
| `title` | `name` | 直接映射 |
| `description` | `description_html` / `description_stripped` | 优先 HTML，降级 stripped |
| `priority` | `priority` | `urgent→1, high→2, medium→3, low→4, none→nil` |
| `state` | `state` (UUID) → 查询映射 | 通过 state_cache 转为名称 |
| `branch_name` | — | 固定 `nil` |
| `url` | 动态拼接 | `{base_url}/{workspace_slug}/projects/{pid}/issues/{id}` |
| `assignee_id` | `assignees[0]` | 取第一个 assignee |
| `labels` | `labels` (expand 后) | 提取 `name`，lowercase |
| `created_at` | `created_at` | ISO8601 解析 |
| `updated_at` | `updated_at` | ISO8601 解析 |

### 4.3 Priority 映射

Plane 使用字符串优先级，Linear 使用整数。映射规则：

```elixir
defp map_priority("urgent"), do: 1
defp map_priority("high"),   do: 2
defp map_priority("medium"), do: 3
defp map_priority("low"),    do: 4
defp map_priority(_),        do: nil
```

### 4.4 State 映射策略

Plane 的 `state` 字段存储 UUID、而非名称。需维护一个 state_name ↔ state_id 映射：

1. **启动时**：调用 `GET /states/` 拉取当前 project 全部 states
2. **构建映射**：`%{"Todo" => "uuid-1", "In Progress" => "uuid-2", ...}`
3. **缓存**：缓存 5 分钟，过期后自动刷新
4. **状态比较**：配置的 `active_states` / `terminal_states` 用名称，内部查表转 UUID

Plane state 还有 `group` 字段 (backlog / unstarted / started / completed / cancelled)，
可作为 fallback 判断 active/terminal：
- active groups: `unstarted`, `started`
- terminal groups: `completed`, `cancelled`

---

## 5. Tracker Behaviour 实现

### 5.1 callback 到 Plane API 的映射

#### `fetch_candidate_issues/0`

```
1. 从 state_cache 获取当前 active_states 对应的 state_id 列表
2. GET /work-items/?expand=state,labels  (分页遍历)
3. 过滤 state 在 active_state_ids 中的 work items
4. normalize 为 Plane.Issue struct 列表
```

注意事项：
- Plane list API 支持 `state` query param 按 state UUID 过滤，但多值过滤需验证
- 如不支持多值过滤，则拉取全量后在客户端过滤
- 分页使用 cursor，每页最多 100 条

#### `fetch_issues_by_states/1`

```
1. 解析传入的 state 名称列表为 state_id 列表
2. GET /work-items/?expand=state  (分页遍历)
3. 过滤 state 在目标 state_ids 中的 work items
4. normalize 为 Plane.Issue struct 列表
```

此函数用于 `list_terminal_issues` 等场景。

#### `fetch_issue_states_by_ids/1`

```
1. 对每个 issue_id，GET /work-items/{id}/?fields=id,state
2. 通过 state_cache 反查 state_name
3. 返回 [{id, state_name}, ...]
```

优化：可批量请求 `/work-items/?fields=id,state`，然后在客户端过滤。

#### `create_comment/2`

```
1. POST /work-items/{work_item_id}/comments/
   Body: {"comment_html": body}
2. 返回 :ok 或 {:error, reason}
```

Plane comment 使用 `comment_html` 字段。workpad comment 的识别通过内容标记实现。

#### `update_issue_state/2`

```
1. 通过 state_cache 将 state_name 解析为 state_id
2. PATCH /work-items/{work_item_id}/
   Body: {"state": state_id}
3. 返回 :ok 或 {:error, reason}
```

### 5.2 额外功能：Workpad Comment

虽然 Tracker behaviour 只定义了 `create_comment/2`，Symphony 的 WORKFLOW.md 通常要求 agent 维护一条单例评论作为 workpad。对 Plane 适配器，建议：

- **创建时**：在 `comment_html` 中嵌入 HTML 注释标记 `<!-- symphony-workpad -->`
- **查找时**：遍历 comments，匹配 `comment_stripped` 或 `comment_html` 中包含标记的评论
- **更新时**：`PATCH /comments/{comment_id}/`，更新 `comment_html`

此逻辑可附加到 `Plane.Client` 模块中，由 WORKFLOW.md 中的 agent 指令调用。

---

## 6. 配置扩展

### 6.1 WORKFLOW.md 前置配置扩展

新增 `tracker.kind: plane` 时需要的额外字段：

```yaml
tracker:
  kind: plane
  base_url: "http://192.168.8.107:8080"
  workspace_slug: "my-team"
  project_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  api_key: "$PLANE_API_KEY"
  active_states:
    - "Todo"
    - "In Progress"
    - "Merging"
    - "Rework"
  terminal_states:
    - "Done"
    - "Closed"
    - "Canceled"
    - "Cancelled"
    - "Duplicate"
```

### 6.2 Config Schema 修改

在 `SymphonyElixir.Config.Schema.Tracker` 中新增字段：

```elixir
embedded_schema do
  field(:kind, :string)
  field(:endpoint, :string, default: "https://api.linear.app/graphql")
  field(:api_key, :string)
  field(:project_slug, :string)
  field(:assignee, :string)
  # ★ 新增 Plane 专用字段
  field(:base_url, :string)
  field(:workspace_slug, :string)
  field(:project_id, :string)
  # 共用字段
  field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
  field(:terminal_states, {:array, :string}, default: [...])
end
```

### 6.3 Dispatch Preflight 验证扩展

在 `Config` 验证逻辑中，当 `tracker.kind == "plane"` 时：

- 必填：`base_url`、`workspace_slug`、`project_id`、`api_key`
- `project_slug` 不再必填（仅 Linear 需要）
- `endpoint` 不再必填（仅 Linear 需要）

```elixir
defp validate_tracker_config(%{kind: "plane"} = tracker) do
  required_fields = [:base_url, :workspace_slug, :project_id, :api_key]
  # 验证所有必填字段非空
end

defp validate_tracker_config(%{kind: "linear"} = tracker) do
  # 已有逻辑
end
```

### 6.4 环境变量

| 变量名 | 用途 | 示例 |
|--------|------|------|
| `PLANE_API_KEY` | Plane API Key | `plane_api_xxxx` |
| `PLANE_BASE_URL` | Plane 服务地址（可选） | `http://192.168.8.107:8080` |

---

## 7. Plane.Client 设计

### 7.1 职责

封装所有 Plane REST API 的 HTTP 交互，对上层暴露语义化函数。

### 7.2 核心函数

```elixir
defmodule SymphonyElixir.Plane.Client do
  # 状态相关
  def list_states(config)                           # GET /states/
  
  # Work Item 相关
  def list_work_items(config, opts \\ [])            # GET /work-items/ (分页)
  def get_work_item(config, work_item_id)            # GET /work-items/{id}/
  def get_work_item_by_identifier(config, identifier) # GET /work-items/{identifier}/
  def update_work_item(config, work_item_id, attrs)  # PATCH /work-items/{id}/
  
  # 评论相关
  def list_comments(config, work_item_id)            # GET /work-items/{id}/comments/
  def create_comment(config, work_item_id, body)     # POST /work-items/{id}/comments/
  def update_comment(config, work_item_id, cid, body) # PATCH /work-items/{id}/comments/{cid}/
end
```

### 7.3 HTTP 客户端

使用与 Linear client 相同的 HTTP 库（`Req` / `Finch`）。每个请求：

1. 构建完整 URL：`{base_url}/api/v1/workspaces/{slug}/projects/{pid}/{path}`
2. 设置 Header：`X-API-Key`、`Content-Type`
3. 处理响应：200/201 成功，401/403 认证失败，429 限流，5xx 服务不可用
4. 解析 JSON 响应体

### 7.4 错误处理

```elixir
defp handle_response({:ok, %{status: status, body: body}}) when status in [200, 201] do
  {:ok, body}
end

defp handle_response({:ok, %{status: 401}}) do
  {:error, :unauthorized}
end

defp handle_response({:ok, %{status: 403}}) do
  {:error, :forbidden}
end

defp handle_response({:ok, %{status: 429}}) do
  {:error, :rate_limited}
end

defp handle_response({:ok, %{status: status, body: body}}) do
  {:error, {:http_error, status, body}}
end

defp handle_response({:error, reason}) do
  {:error, {:connection_error, reason}}
end
```

---

## 8. State Cache 设计

### 8.1 目的

Plane work item 的 `state` 字段是 UUID，而 Symphony 配置和显示都用状态名称。
需要维护一个按 project 级别的 name ↔ id 双向映射。

### 8.2 实现方式

使用 GenServer 或 Agent 在进程中缓存：

```elixir
defmodule SymphonyElixir.Plane.StateCache do
  use Agent

  # 缓存结构
  # %{
  #   name_to_id: %{"Todo" => "uuid-1", "In Progress" => "uuid-2"},
  #   id_to_name: %{"uuid-1" => "Todo", "uuid-2" => "In Progress"},
  #   fetched_at: ~U[2026-03-10 12:00:00Z]
  # }

  def resolve_name(state_id)       # id → name
  def resolve_id(state_name)       # name → id
  def resolve_ids(state_names)     # [name] → [id]
  def refresh()                    # 重新拉取并更新缓存
end
```

### 8.3 刷新策略

- 启动时立即加载
- TTL：5 分钟自动过期刷新
- 查找失败时强制刷新一次

---

## 9. Workpad Comment 策略

### 9.1 识别方式

使用 HTML 注释标记作为唯一标识：

```html
<!-- symphony-workpad -->
<h2>Codex Workpad</h2>
<h3>Summary</h3>
<p>...</p>
<h3>Progress</h3>
<p>...</p>
```

### 9.2 操作流程

```
find_or_create_workpad(config, work_item_id):
  1. GET /comments/ 列出所有评论
  2. 遍历查找 comment_html 包含 "<!-- symphony-workpad -->" 的评论
  3. 如果找到 → 返回该评论 ID
  4. 如果未找到 → POST /comments/ 创建，返回新评论 ID

update_workpad(config, work_item_id, comment_id, content):
  1. 将 content 包装为：`<!-- symphony-workpad -->\n{content}`
  2. PATCH /comments/{comment_id}/ 更新 comment_html
```

### 9.3 注意事项

- Plane 评论内容存储为 `comment_html`，创建和更新时都用此字段
- `comment_stripped` 是系统自动生成的纯文本版本，只能用于读取
- HTML 注释标记不会出现在 `comment_stripped` 中，查找应基于 `comment_html`

---

## 10. WORKFLOW.md 适配

### 10.1 术语替换

当 `tracker.kind: plane` 时，WORKFLOW.md 中的 prompt 模板应使用 Plane 术语：

| Linear 术语 | Plane 术语 |
|------------|-----------|
| Linear ticket | Plane work item |
| Linear issue | Plane work item |
| Linear comment | Plane comment |
| Linear API | Plane REST API |

### 10.2 Prompt 模板变量

prompt 模板中的 `{{issue}}` 对象结构保持不变。Plane adapter 输出的 Issue struct 与 Linear 相同字段名，上层模板无需感知底层 tracker 差异。

### 10.3 WORKFLOW.md 示例

```yaml
---
tracker:
  kind: plane
  base_url: "http://192.168.8.107:8080"
  workspace_slug: "my-team"
  project_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  api_key: "$PLANE_API_KEY"
  active_states:
    - "Todo"
    - "In Progress"
    - "Merging"
    - "Rework"
  terminal_states:
    - "Done"
    - "Closed"
    - "Canceled"
    - "Cancelled"
    - "Duplicate"

polling:
  interval_ms: 30000

agent:
  max_concurrent_agents: 3
---

You are working on a work item from Plane.

## Work Item
- ID: {{issue.identifier}}
- Title: {{issue.title}}
- Description: {{issue.description}}
- State: {{issue.state}}
- URL: {{issue.url}}

## Instructions
...
```

---

## 11. Plane 侧准备

### 11.1 Workspace

在 URL 中获取 `workspace_slug`，如 `http://plane.local/my-team/projects/...` 中的 `my-team`。

### 11.2 Project

创建或选择一个 project，记录 `project_id`（UUID 格式）和 `identifier`（用于拼接 work item 编号）。

### 11.3 States

建议配置以下状态以匹配 Symphony 工作流：

| 状态名 | Group | 用途 |
|--------|-------|------|
| Todo | unstarted | 新创建的任务 |
| In Progress | started | Agent 正在执行 |
| Human Review | started | 等待人工审核 |
| Merging | started | PR 合并中 |
| Rework | started | 需要返工 |
| Done | completed | 完成 |
| Canceled | cancelled | 取消 |

### 11.4 API Key

在 Profile Settings → Personal Access Tokens 中创建。

---

## 12. 差异分析：Linear vs Plane

| 维度 | Linear | Plane |
|------|--------|-------|
| API 类型 | GraphQL | REST |
| 认证 | `Authorization: Bearer` | `X-API-Key` |
| Issue 标识 | `identifier` 直接返回 | 需用 `project.identifier` + `sequence_id` 拼接 |
| 状态字段 | 返回状态名称 | 返回状态 UUID，需额外映射 |
| Priority | 整数 1–4 | 字符串 none/urgent/high/medium/low |
| Branch Name | 内置字段 | 不支持 |
| Blocker | `inverseRelations` | 第一版不实现 |
| 分页 | cursor-based (GraphQL) | cursor-based (REST) |
| 速率限制 | 较宽裕 | 60 req/min |
| Comment | Markdown body | HTML body (`comment_html`) |

---

## 13. 风险与缓解

| 风险 | 影响 | 缓解策略 |
|------|------|---------|
| Plane API 速率限制 (60/min) | 高频轮询导致 429 | poll_interval ≥ 15s，state 缓存减少请求 |
| State UUID 不稳定 | 环境重建后映射失效 | 按名称配置，启动时动态构建映射 |
| 无 branch_name 字段 | workspace hook 需要分支名 | 从 WORKFLOW.md hook 中用其他方式创建分支 |
| Comment 为 HTML 格式 | Markdown 直接存入可能渲染异常 | 将 workpad 内容转为合法 HTML |
| 无 blocker 关系 | 有依赖的任务可能被提前调度 | 第一版暂不处理，后续迭代增加 |
| Plane CE 版 API 差异 | 部分端点可能与官方文档不一致 | 先用脚本验证实际 API 返回 |

---

## 14. 不在第一版范围

以下功能明确排除在第一版实现之外：

- 多 workspace / 多 project 同时轮询
- Webhook 驱动调度（替代轮询）
- OAuth App / Bot Token 认证
- Plane MCP agent 工具层
- 自动创建新 work item
- Blocker / Relation 依赖分析
- Cycles / Modules / Pages 集成
- 富文本评论完美保真同步
- Assignee routing（按 assignee 分发）

---

## 15. Agent 动态工具：从 `linear_graphql` 到 `plane_api`

### 15.1 现状：Linear 的 agent 工具

Symphony 当前为 Codex agent 注入了一个名为 `linear_graphql` 的 **dynamic tool**
（见 `lib/symphony_elixir/codex/dynamic_tool.ex`），让 agent 在执行过程中可以直接对
Linear 执行任意 GraphQL 查询/变更：

```elixir
# 当前实现：agent 拥有一个 linear_graphql 工具
%{
  "name" => "linear_graphql",
  "description" => "Execute a raw GraphQL query or mutation against Linear ...",
  "inputSchema" => %{
    "properties" => %{
      "query"     => %{"type" => "string"},
      "variables" => %{"type" => ["object", "null"]}
    }
  }
}
```

这不是 MCP Server，而是通过 Codex app-server 的 `dynamicTools` 参数在线程启动时注册，
agent 发起 tool call 后由 Symphony 进程内直接调用 `Linear.Client.graphql/3` 执行。

### 15.2 Plane 没有 GraphQL API

**Plane 只提供 REST API**（无 GraphQL 端点），因此无法沿用 `linear_graphql` 的模式。
需要设计一个等价的 `plane_api` 动态工具。

### 15.3 方案 A：`plane_api` 动态工具（推荐，第一版）

仿照 `linear_graphql` 的实现方式，新增一个 `plane_api` 动态工具，让 agent 可以调用
Plane REST API：

```elixir
@plane_api_tool "plane_api"
@plane_api_description """
Execute a REST API call against Plane using Symphony's configured auth.
"""
@plane_api_input_schema %{
  "type" => "object",
  "additionalProperties" => false,
  "required" => ["method", "path"],
  "properties" => %{
    "method" => %{
      "type" => "string",
      "enum" => ["GET", "POST", "PATCH", "DELETE"],
      "description" => "HTTP method."
    },
    "path" => %{
      "type" => "string",
      "description" => "API path relative to workspace/project base, e.g. 'work-items/' or 'work-items/{id}/comments/'"
    },
    "body" => %{
      "type" => ["object", "null"],
      "description" => "Optional JSON request body for POST/PATCH."
    },
    "query_params" => %{
      "type" => ["object", "null"],
      "description" => "Optional query parameters, e.g. {\"expand\": \"state,labels\"}"
    }
  }
}
```

#### 执行流程

```
Agent 发起 tool call: plane_api(method: "PATCH", path: "work-items/{id}/", body: {"state": "uuid"})
                  │
                  ▼
DynamicTool.execute("plane_api", arguments)
                  │
                  ▼
Plane.Client.request(method, full_path, body, config)
                  │
                  ▼
HTTP 请求 → Plane REST API → 返回 JSON 响应给 agent
```

#### 安全约束

- `path` 自动拼接 `{base_url}/api/v1/workspaces/{slug}/projects/{pid}/` 前缀，agent 无法访问任意 URL
- 仅允许 GET / POST / PATCH / DELETE 四种方法
- 认证 header 由 Symphony 注入，agent 无需也看不到 API Key

#### DynamicTool 分发修改

```elixir
def execute(tool, arguments, opts \\ []) do
  case tool do
    "linear_graphql" -> execute_linear_graphql(arguments, opts)
    "plane_api"      -> execute_plane_api(arguments, opts)      # ★ 新增
    other            -> failure_response(...)
  end
end

def tool_specs do
  case SymphonyElixir.Config.settings!().tracker.kind do
    "plane"  -> [plane_api_spec()]
    "linear" -> [linear_graphql_spec()]
    _        -> [linear_graphql_spec()]
  end
end
```

### 15.4 方案 B：Plane MCP Server（后续增强）

Plane 官方提供了 [MCP Server](https://developers.plane.so/dev-tools/mcp-server)（Beta），
支持 stdio 本地传输模式，适合自托管场景：

```json
{
  "mcpServers": {
    "plane": {
      "command": "uvx",
      "args": ["plane-mcp-server", "stdio"],
      "env": {
        "PLANE_API_KEY": "<YOUR_API_KEY>",
        "PLANE_WORKSPACE_SLUG": "<YOUR_WORKSPACE_SLUG>",
        "PLANE_BASE_URL": "https://your-plane-instance.com/api"
      }
    }
  }
}
```

此方案的优势：
- 官方维护，工具定义更丰富（work items、comments、projects、states 等）
- agent 使用开箱即用的语义化工具，而非手动构造 REST 请求
- 支持 OAuth 和 PAT Token 两种认证

劣势：
- 需要额外启动 MCP Server 进程
- 依赖 Python 3.10+ 和 `uvx`
- 需要修改 Codex app-server 的线程配置以注册 MCP 工具源
- 目前处于 Beta 阶段

**建议**：第一版使用方案 A（`plane_api` 动态工具），与现有 `linear_graphql` 架构对称。
待 Plane MCP Server 稳定后，可作为方案 B 替换或补充。

### 15.5 方案 C：Plane Agent App（远期）

Plane 还提供了 [Agent 框架](https://developers.plane.so/dev-tools/agents/overview)（Beta），
允许创建 OAuth 应用作为 "agent"，用户可在 work item 评论中 @mention agent 触发交互。
这与 Symphony 的调度模式不同（Plane Agent 是被动触发，Symphony 是主动轮询），
但未来可以考虑让 Symphony 注册为 Plane Agent，获得 Webhook 驱动的事件推送能力。

---

## 16. 后续演进方向

1. **Plane MCP Server 替代 `plane_api`**：待稳定后用 MCP 工具替代自定义动态工具
2. **Webhook 集成**：Plane 推送事件触发调度，替代轮询延迟
3. **多 Project**：单 Symphony 实例管理多个 Plane project
4. **Plane Agent App 集成**：注册为 Plane Agent，获得 @mention 驱动的交互能力
5. **Blocker 支持**：通过 Plane relations API 实现任务依赖分析
6. **Assignee Routing**：按 work item assignee 分发到特定 worker
7. **丰富字段映射**：labels、estimates、cycles、links
8. **自动创建 Follow-up**：agent 完成后自动在 Plane 创建后续任务

---

## 附录 A：Plane API 快速参考

### Work Items

```
GET    /api/v1/workspaces/{slug}/projects/{pid}/work-items/
GET    /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/
GET    /api/v1/workspaces/{slug}/work-items/{identifier}/
POST   /api/v1/workspaces/{slug}/projects/{pid}/work-items/
PATCH  /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/
DELETE /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/
```

### States

```
GET    /api/v1/workspaces/{slug}/projects/{pid}/states/
```

### Comments

```
GET    /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/
POST   /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/
PATCH  /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/{cid}/
DELETE /api/v1/workspaces/{slug}/projects/{pid}/work-items/{wid}/comments/{cid}/
```

### Projects

```
GET    /api/v1/workspaces/{slug}/projects/
GET    /api/v1/workspaces/{slug}/projects/{pid}/
```

### 分页参数

```
?per_page=100&cursor={next_cursor}
```

### Expandable Fields

```
?expand=state,labels,assignees,project
```
