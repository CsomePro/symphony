defmodule SymphonyElixir.Plane.StateCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Plane.StateCache

  defmodule FakePlaneClient do
    @results_key {__MODULE__, :results}
    @test_pid_key {__MODULE__, :test_pid}

    def list_states(tracker) do
      case :persistent_term.get(@test_pid_key, nil) do
        pid when is_pid(pid) -> send(pid, {:list_states_called, tracker})
        _other -> :ok
      end

      case :persistent_term.get(@results_key, []) do
        [result | rest] ->
          :persistent_term.put(@results_key, rest)
          result

        [] ->
          {:ok, []}
      end
    end

    def set_results(results) when is_list(results), do: :persistent_term.put(@results_key, results)
    def set_test_pid(pid) when is_pid(pid), do: :persistent_term.put(@test_pid_key, pid)

    def clear do
      :persistent_term.erase(@results_key)
      :persistent_term.erase(@test_pid_key)
    end
  end

  setup do
    previous_client_module = Application.get_env(:symphony_elixir, :plane_client_module)
    previous_ttl_ms = Application.get_env(:symphony_elixir, :plane_state_cache_ttl_ms)

    on_exit(fn ->
      restore_app_env(:plane_client_module, previous_client_module)
      restore_app_env(:plane_state_cache_ttl_ms, previous_ttl_ms)
      write_workflow_file!(Workflow.workflow_file_path())
      FakePlaneClient.clear()
      restart_state_cache!()
    end)

    FakePlaneClient.set_test_pid(self())

    :ok
  end

  test "preloads mappings on startup and resolves ids in both directions" do
    configure_plane_cache!(
      ttl_ms: 5_000,
      results: [
        {:ok,
         [
           %{"id" => "state-1", "name" => "Todo"},
           %{id: "state-2", name: "Done"},
           %{"id" => "", "name" => "Ignored"}
         ]}
      ]
    )

    assert_receive {:list_states_called, tracker}
    assert tracker.kind == "plane"
    assert tracker.base_url == "https://plane.example.test"

    assert {:ok, "state-1"} = StateCache.resolve_id(" Todo ")
    assert {:ok, "Todo"} = StateCache.resolve_name(" state-1 ")
    assert {:ok, ["state-1", "state-2", "state-1"]} = StateCache.resolve_ids(["Todo", "Done", "Todo"])
  end

  test "reloads mappings automatically after ttl expiry" do
    configure_plane_cache!(
      ttl_ms: 10,
      results: [
        {:ok, [%{"id" => "state-1", "name" => "Todo"}]},
        {:ok, [%{"id" => "state-2", "name" => "Todo"}]}
      ]
    )

    assert_receive {:list_states_called, _tracker}
    assert {:ok, "state-1"} = StateCache.resolve_id("Todo")

    assert_receive {:list_states_called, _tracker}, 200
    assert {:ok, "state-2"} = StateCache.resolve_id("Todo")
  end

  test "forces a refresh and logs clearly when a state name is missing" do
    configure_plane_cache!(
      ttl_ms: 5_000,
      results: [
        {:ok, [%{"id" => "state-1", "name" => "Todo"}]},
        {:ok, [%{"id" => "state-1", "name" => "Todo"}]}
      ]
    )

    assert_receive {:list_states_called, _tracker}

    log =
      capture_log(fn ->
        assert {:error, {:states_not_found, ["Done"]}} = StateCache.resolve_ids(["Done"])
      end)

    assert_receive {:list_states_called, _tracker}
    assert log =~ "Plane state lookup failed action=resolve_ids"
    assert log =~ ~s(missing_state_names=["Done"])
  end

  defp configure_plane_cache!(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_base_url: "https://plane.example.test",
      tracker_workspace_slug: "demo-workspace",
      tracker_project_id: "project-123",
      tracker_api_token: "plane-token"
    )

    Application.put_env(:symphony_elixir, :plane_client_module, FakePlaneClient)
    Application.put_env(:symphony_elixir, :plane_state_cache_ttl_ms, Keyword.fetch!(opts, :ttl_ms))
    FakePlaneClient.set_results(Keyword.fetch!(opts, :results))

    restart_state_cache!()
  end

  defp restart_state_cache! do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, StateCache) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_started} -> :ok
    end

    case Supervisor.restart_child(SymphonyElixir.Supervisor, StateCache) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
