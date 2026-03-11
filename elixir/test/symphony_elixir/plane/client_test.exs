defmodule SymphonyElixir.Plane.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.Client

  @tracker %{
    base_url: "https://plane.example.test",
    workspace_slug: "workspace-slug",
    project_id: "project-uuid",
    api_key: "plane-token"
  }

  test "request/4 builds the project URL, headers, and json body" do
    request_fun = fn request ->
      send(self(), {:request, request})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end

    assert {:ok, %{"ok" => true}} =
             Client.request(@tracker, :patch, "work-items/work-item-1/",
               json: %{state: "done"},
               request_fun: request_fun
             )

    assert_receive {:request, request}
    assert request[:method] == :patch

    assert request[:url] ==
             "https://plane.example.test/api/v1/workspaces/workspace-slug/projects/project-uuid/work-items/work-item-1/"

    assert {"X-API-Key", "plane-token"} in request[:headers]
    assert {"Content-Type", "application/json"} in request[:headers]
    assert request[:json] == %{state: "done"}
  end

  test "request/4 marks 401 and 403 responses as auth failures" do
    for status <- [401, 403] do
      assert {:error, :auth_failure} =
               Client.request(@tracker, :get, "states/", request_fun: fn _request -> {:ok, %{status: status, body: %{"detail" => "nope"}}} end)
    end
  end

  test "request/4 backs off and retries 429 responses" do
    test_pid = self()
    attempt_key = {__MODULE__, :rate_limit_attempt}

    request_fun = fn request ->
      attempt = Process.get(attempt_key, 0) + 1
      Process.put(attempt_key, attempt)
      send(test_pid, {:attempt, attempt, request[:params]})

      case attempt do
        1 ->
          {:ok, %{status: 429, body: %{}, headers: [{"retry-after", "2"}]}}

        2 ->
          {:ok, %{status: 200, body: [%{"id" => "state-1"}]}}
      end
    end

    sleep_fun = fn ms -> send(test_pid, {:slept, ms}) end

    assert {:ok, [%{"id" => "state-1"}]} =
             Client.request(@tracker, :get, "states/",
               request_fun: request_fun,
               sleep_fun: sleep_fun,
               retry_delay_ms: 100,
               max_attempts: 3
             )

    assert_receive {:attempt, 1, %{}}
    assert_receive {:slept, 2_000}
    assert_receive {:attempt, 2, %{}}
  end

  test "request/4 maps 5xx responses to skip_cycle" do
    assert {:error, :skip_cycle} =
             Client.request(@tracker, :delete, "work-items/work-item-1/", request_fun: fn _request -> {:ok, %{status: 503, body: %{"detail" => "unavailable"}}} end)
  end

  test "request/4 maps timeout transport errors to skip_cycle" do
    assert {:error, :skip_cycle} =
             Client.request(@tracker, :get, "states/", request_fun: fn _request -> {:error, %{reason: :timeout}} end)
  end

  test "list_work_items/2 follows cursor pagination and serializes filters" do
    test_pid = self()
    attempt_key = {__MODULE__, :cursor_attempt}

    request_fun = fn request ->
      attempt = Process.get(attempt_key, 0) + 1
      Process.put(attempt_key, attempt)
      send(test_pid, {:work_items_request, attempt, request})

      case attempt do
        1 ->
          {:ok, %{status: 200, body: %{"results" => [%{"id" => "wi-1"}], "next_cursor" => "cursor-2"}}}

        2 ->
          {:ok, %{status: 200, body: %{"results" => [%{"id" => "wi-2"}], "next_cursor" => nil}}}
      end
    end

    assert {:ok, [%{"id" => "wi-1"}, %{"id" => "wi-2"}]} =
             Client.list_work_items(@tracker,
               state: "state-uuid",
               expand: ["state", "assignees"],
               fields: ["id", "name"],
               request_fun: request_fun
             )

    assert_receive {:work_items_request, 1, first_request}
    assert first_request[:url] =~ "/projects/project-uuid/work-items/"
    assert first_request[:params]["state"] == "state-uuid"
    assert first_request[:params]["expand"] == "state,assignees"
    assert first_request[:params]["fields"] == "id,name"

    assert_receive {:work_items_request, 2, second_request}
    assert second_request[:params]["cursor"] == "cursor-2"
    assert second_request[:params]["state"] == "state-uuid"
  end

  test "list_comments/2 follows next URLs for pagination" do
    attempt_key = {__MODULE__, :comment_attempt}

    request_fun = fn request ->
      attempt = Process.get(attempt_key, 0) + 1
      Process.put(attempt_key, attempt)

      case attempt do
        1 ->
          assert request[:params] == %{}

          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [%{"id" => "comment-1"}],
               "next" => "https://plane.example.test/api/v1/workspaces/workspace-slug/projects/project-uuid/work-items/work-item-1/comments/?offset=50&limit=50"
             }
           }}

        2 ->
          assert request[:params]["offset"] == "50"
          assert request[:params]["limit"] == "50"

          {:ok, %{status: 200, body: %{"results" => [%{"id" => "comment-2"}], "next" => nil}}}
      end
    end

    assert {:ok, [%{"id" => "comment-1"}, %{"id" => "comment-2"}]} =
             Client.list_comments(@tracker, "work-item-1", request_fun: request_fun)
  end

  test "get_work_item_by_identifier/2 uses the workspace-scoped endpoint" do
    request_fun = fn request ->
      send(self(), {:request, request})
      {:ok, %{status: 200, body: %{"id" => "wi-1"}}}
    end

    assert {:ok, %{"id" => "wi-1"}} =
             Client.get_work_item_by_identifier(@tracker, "PROJ-123", request_fun: request_fun)

    assert_receive {:request, request}

    assert request[:url] ==
             "https://plane.example.test/api/v1/workspaces/workspace-slug/work-items/PROJ-123/"
  end

  test "create_comment/3 and update_comment/4 send comment_html payloads" do
    request_fun = fn request ->
      send(self(), {:request, request})
      {:ok, %{status: 200, body: %{"id" => "comment-1"}}}
    end

    assert {:ok, %{"id" => "comment-1"}} =
             Client.create_comment(@tracker, "work-item-1", "<p>Hello</p>", request_fun: request_fun)

    assert_receive {:request, create_request}
    assert create_request[:method] == :post
    assert create_request[:json] == %{comment_html: "<p>Hello</p>"}

    assert {:ok, %{"id" => "comment-1"}} =
             Client.update_comment(@tracker, "work-item-1", "comment-1", "<p>Updated</p>", request_fun: request_fun)

    assert_receive {:request, update_request}
    assert update_request[:method] == :patch
    assert update_request[:json] == %{comment_html: "<p>Updated</p>"}
  end
end
