defmodule SymphonyElixir.Plane.StateCache do
  @moduledoc """
  Caches Plane state name/UUID mappings with periodic refreshes.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Plane.Client

  @default_ttl_ms :timer.minutes(5)

  @type resolve_error :: :state_not_found | {:states_not_found, [String.t()]} | :tracker_not_plane | term()

  @type state :: %{
          client_module: module(),
          enabled?: boolean(),
          id_to_name: %{optional(String.t()) => String.t()},
          name_to_id: %{optional(String.t()) => String.t()},
          refresh_timer_ref: reference() | nil,
          ttl_ms: pos_integer()
        }

  @doc """
  Starts the Plane state cache server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resolves a Plane state UUID to its configured state name.
  """
  @spec resolve_name(String.t()) :: {:ok, String.t()} | {:error, resolve_error()}
  def resolve_name(state_id) when is_binary(state_id) do
    GenServer.call(__MODULE__, {:resolve_name, normalize_key(state_id)})
  end

  def resolve_name(_state_id), do: {:error, :state_not_found}

  @doc """
  Resolves a Plane state name to its UUID.
  """
  @spec resolve_id(String.t()) :: {:ok, String.t()} | {:error, resolve_error()}
  def resolve_id(state_name) when is_binary(state_name) do
    GenServer.call(__MODULE__, {:resolve_id, normalize_key(state_name)})
  end

  def resolve_id(_state_name), do: {:error, :state_not_found}

  @doc """
  Resolves a list of Plane state names to UUIDs while preserving order.
  """
  @spec resolve_ids([String.t()]) :: {:ok, [String.t()]} | {:error, resolve_error()}
  def resolve_ids(state_names) when is_list(state_names) do
    normalized_names = Enum.map(state_names, &normalize_key/1)
    GenServer.call(__MODULE__, {:resolve_ids, normalized_names})
  end

  def resolve_ids(_state_names), do: {:error, {:states_not_found, []}}

  @impl true
  def init(opts) do
    state = %{
      client_module: Keyword.get(opts, :client_module, plane_client_module()),
      enabled?: false,
      id_to_name: %{},
      name_to_id: %{},
      refresh_timer_ref: nil,
      ttl_ms: Keyword.get(opts, :ttl_ms, plane_state_cache_ttl_ms())
    }

    {:ok, refresh_on_start(state)}
  end

  @impl true
  def handle_call({:resolve_name, state_id}, _from, state) do
    {reply, updated_state} = resolve_lookup(state, :id_to_name, state_id, :resolve_name)
    {:reply, reply, updated_state}
  end

  @impl true
  def handle_call({:resolve_id, state_name}, _from, state) do
    {reply, updated_state} = resolve_lookup(state, :name_to_id, state_name, :resolve_id)
    {:reply, reply, updated_state}
  end

  @impl true
  def handle_call({:resolve_ids, state_names}, _from, state) do
    case lookup_ids(state, state_names) do
      {:ok, state_ids} ->
        {:reply, {:ok, state_ids}, state}

      {:error, _missing_names} ->
        case refresh_cache(state, :resolve_ids) do
          {:ok, refreshed_state} ->
            reply_after_resolve_ids_refresh(refreshed_state, state_names)

          {:disabled, refreshed_state} ->
            {:reply, {:error, :tracker_not_plane}, refreshed_state}

          {:error, reason, refreshed_state} ->
            {:reply, {:error, reason}, refreshed_state}
        end
    end
  end

  @impl true
  def handle_info(:refresh_cache, state) do
    updated_state =
      case refresh_cache(state, :ttl) do
        {:ok, refreshed_state} -> refreshed_state
        {:disabled, refreshed_state} -> refreshed_state
        {:error, _reason, refreshed_state} -> refreshed_state
      end

    {:noreply, updated_state}
  end

  defp reply_after_resolve_ids_refresh(state, state_names) do
    case lookup_ids(state, state_names) do
      {:ok, state_ids} ->
        {:reply, {:ok, state_ids}, state}

      {:error, missing_names} ->
        Logger.error("Plane state lookup failed action=resolve_ids missing_state_names=#{inspect(missing_names)}")

        {:reply, {:error, {:states_not_found, missing_names}}, state}
    end
  end

  defp resolve_lookup(state, mapping_key, lookup_key, action) do
    case Map.fetch(Map.fetch!(state, mapping_key), lookup_key) do
      {:ok, value} ->
        {{:ok, value}, state}

      :error ->
        case refresh_cache(state, action) do
          {:ok, refreshed_state} ->
            reply_after_lookup_refresh(refreshed_state, mapping_key, lookup_key, action)

          {:disabled, refreshed_state} ->
            {{:error, :tracker_not_plane}, refreshed_state}

          {:error, reason, refreshed_state} ->
            {{:error, reason}, refreshed_state}
        end
    end
  end

  defp reply_after_lookup_refresh(state, mapping_key, lookup_key, action) do
    case Map.fetch(Map.fetch!(state, mapping_key), lookup_key) do
      {:ok, value} ->
        {{:ok, value}, state}

      :error ->
        log_missing_lookup(action, lookup_key)
        {{:error, :state_not_found}, state}
    end
  end

  defp lookup_ids(state, state_names) do
    Enum.reduce_while(state_names, {:ok, []}, fn state_name, {:ok, state_ids} ->
      case Map.fetch(state.name_to_id, state_name) do
        {:ok, state_id} -> {:cont, {:ok, [state_id | state_ids]}}
        :error -> {:halt, {:error, missing_names(state, state_names)}}
      end
    end)
    |> case do
      {:ok, state_ids} -> {:ok, Enum.reverse(state_ids)}
      {:error, missing} -> {:error, missing}
    end
  end

  defp missing_names(state, state_names) do
    state_names
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(state.name_to_id, &1))
  end

  defp refresh_on_start(state) do
    case refresh_cache(state, :startup) do
      {:ok, refreshed_state} -> refreshed_state
      {:disabled, refreshed_state} -> refreshed_state
      {:error, _reason, refreshed_state} -> refreshed_state
    end
  end

  defp refresh_cache(state, trigger) do
    case plane_tracker_config() do
      nil ->
        {:disabled, clear_cache(state)}

      tracker ->
        case state.client_module.list_states(tracker) do
          {:ok, states} ->
            {name_to_id, id_to_name} = build_mappings(states)

            updated_state =
              state
              |> Map.put(:enabled?, true)
              |> Map.put(:name_to_id, name_to_id)
              |> Map.put(:id_to_name, id_to_name)
              |> schedule_refresh()

            {:ok, updated_state}

          {:error, reason} ->
            Logger.error("Plane state cache refresh failed trigger=#{trigger} reason=#{inspect(reason)}")

            updated_state =
              state
              |> Map.put(:enabled?, true)
              |> schedule_refresh()

            {:error, reason, updated_state}
        end
    end
  end

  defp build_mappings(states) when is_list(states) do
    Enum.reduce(states, {%{}, %{}}, fn state, {name_to_id, id_to_name} ->
      case state_entry(state) do
        {state_name, state_id} ->
          {
            Map.put(name_to_id, state_name, state_id),
            Map.put(id_to_name, state_id, state_name)
          }

        nil ->
          {name_to_id, id_to_name}
      end
    end)
  end

  defp build_mappings(_states), do: {%{}, %{}}

  defp state_entry(%{"id" => state_id, "name" => state_name}), do: state_entry(%{id: state_id, name: state_name})

  defp state_entry(%{id: state_id, name: state_name}) when is_binary(state_id) and is_binary(state_name) do
    normalized_id = normalize_key(state_id)
    normalized_name = normalize_key(state_name)

    if normalized_id == "" or normalized_name == "" do
      nil
    else
      {normalized_name, normalized_id}
    end
  end

  defp state_entry(_state), do: nil

  defp clear_cache(state) do
    state
    |> cancel_refresh_timer()
    |> Map.put(:enabled?, false)
    |> Map.put(:id_to_name, %{})
    |> Map.put(:name_to_id, %{})
  end

  defp schedule_refresh(state) do
    state
    |> cancel_refresh_timer()
    |> Map.put(:refresh_timer_ref, Process.send_after(self(), :refresh_cache, state.ttl_ms))
  end

  defp cancel_refresh_timer(%{refresh_timer_ref: nil} = state), do: state

  defp cancel_refresh_timer(%{refresh_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    Map.put(state, :refresh_timer_ref, nil)
  end

  defp log_missing_lookup(:resolve_id, state_name) do
    Logger.error("Plane state lookup failed action=resolve_id state_name=#{inspect(state_name)}")
  end

  defp log_missing_lookup(:resolve_name, state_id) do
    Logger.error("Plane state lookup failed action=resolve_name state_id=#{inspect(state_id)}")
  end

  defp plane_tracker_config do
    case Config.settings!().tracker do
      %{kind: "plane"} = tracker -> tracker
      _other -> nil
    end
  end

  defp plane_client_module do
    Application.get_env(:symphony_elixir, :plane_client_module, Client)
  end

  defp plane_state_cache_ttl_ms do
    Application.get_env(:symphony_elixir, :plane_state_cache_ttl_ms, @default_ttl_ms)
  end

  defp normalize_key(value) when is_binary(value), do: String.trim(value)
  defp normalize_key(value), do: value |> to_string() |> normalize_key()
end
