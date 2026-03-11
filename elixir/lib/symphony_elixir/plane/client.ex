defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Thin Plane REST API v1 client for project-scoped state, work item, and comment operations.

  The public functions accept a tracker config map/struct that includes the Plane
  connection settings already normalized by `SymphonyElixir.Config`.
  """

  @type tracker_config :: %{
          required(:base_url) => String.t(),
          required(:workspace_slug) => String.t(),
          required(:project_id) => String.t(),
          required(:api_key) => String.t()
        }

  @type request_method :: :get | :post | :patch | :delete

  @type request_option ::
          {:json, map() | nil}
          | {:params, map() | keyword()}
          | {:headers, [{String.t(), String.t()}]}
          | {:project_path?, boolean()}
          | {:request_fun, (keyword() -> {:ok, term()} | {:error, term()})}
          | {:sleep_fun, (non_neg_integer() -> term())}
          | {:retry_delay_ms, pos_integer()}
          | {:max_attempts, pos_integer()}
          | {:timeout_ms, pos_integer()}

  @type error_reason ::
          :auth_failure
          | :rate_limited
          | :skip_cycle
          | :not_found
          | :unexpected_payload
          | {:unexpected_status, non_neg_integer(), term()}
          | {:request_failed, term()}

  @type result(value) :: {:ok, value} | {:error, error_reason()}

  @default_timeout_ms 30_000
  @default_retry_delay_ms 1_000
  @default_max_attempts 3
  @request_option_keys [:headers, :max_attempts, :project_path?, :request_fun, :retry_delay_ms, :sleep_fun, :timeout_ms]

  @spec request(tracker_config(), request_method(), String.t(), [request_option()]) :: result(term())
  def request(tracker, method, path, opts \\ [])
      when is_map(tracker) and is_binary(path) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &send_request/1)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    retry_delay_ms = Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms)

    request =
      opts
      |> build_request(tracker, normalize_method(method), path)
      |> Keyword.put(:request_fun, request_fun)
      |> Keyword.put(:sleep_fun, sleep_fun)
      |> Keyword.put(:max_attempts, max_attempts)
      |> Keyword.put(:retry_delay_ms, retry_delay_ms)

    perform_request(request, 1)
  end

  @spec list_states(tracker_config()) :: result([map()])
  @spec list_states(tracker_config(), [request_option()]) :: result([map()])
  def list_states(tracker, opts \\ []) when is_map(tracker) and is_list(opts) do
    with {:ok, body} <- request(tracker, :get, "states/", opts),
         {:ok, states, _next_params} <- decode_list_response(body) do
      {:ok, states}
    end
  end

  @spec list_work_items(tracker_config(), keyword() | map()) :: result([map()])
  def list_work_items(tracker, opts \\ []) when is_map(tracker) and (is_list(opts) or is_map(opts)) do
    request_opts = extract_request_opts(opts)

    params =
      opts
      |> normalize_options_map()
      |> Map.take(["cursor", "expand", "fields", "limit", "offset", "per_page", "state"])

    paginate(tracker, "work-items/", params, request_opts, [])
  end

  @spec get_work_item(tracker_config(), String.t()) :: result(map())
  @spec get_work_item(tracker_config(), String.t(), [request_option()]) :: result(map())
  def get_work_item(tracker, work_item_id, opts \\ [])
      when is_map(tracker) and is_binary(work_item_id) and is_list(opts) do
    request(tracker, :get, "work-items/#{work_item_id}/", opts)
  end

  @spec get_work_item_by_identifier(tracker_config(), String.t()) :: result(map())
  @spec get_work_item_by_identifier(tracker_config(), String.t(), [request_option()]) :: result(map())
  def get_work_item_by_identifier(tracker, identifier, opts \\ [])
      when is_map(tracker) and is_binary(identifier) and is_list(opts) do
    request(tracker, :get, "work-items/#{identifier}/", Keyword.put(opts, :project_path?, false))
  end

  @spec update_work_item(tracker_config(), String.t(), map()) :: result(map())
  @spec update_work_item(tracker_config(), String.t(), map(), [request_option()]) :: result(map())
  def update_work_item(tracker, work_item_id, attrs, opts \\ [])
      when is_map(tracker) and is_binary(work_item_id) and is_map(attrs) and is_list(opts) do
    request(tracker, :patch, "work-items/#{work_item_id}/", Keyword.put(opts, :json, attrs))
  end

  @spec list_comments(tracker_config(), String.t()) :: result([map()])
  @spec list_comments(tracker_config(), String.t(), [request_option()]) :: result([map()])
  def list_comments(tracker, work_item_id, opts \\ [])
      when is_map(tracker) and is_binary(work_item_id) and is_list(opts) do
    paginate(tracker, "work-items/#{work_item_id}/comments/", %{}, opts, [])
  end

  @spec create_comment(tracker_config(), String.t(), String.t()) :: result(map())
  @spec create_comment(tracker_config(), String.t(), String.t(), [request_option()]) :: result(map())
  def create_comment(tracker, work_item_id, comment_html, opts \\ [])
      when is_map(tracker) and is_binary(work_item_id) and is_binary(comment_html) and is_list(opts) do
    request(tracker, :post, "work-items/#{work_item_id}/comments/", Keyword.put(opts, :json, %{comment_html: comment_html}))
  end

  @spec update_comment(tracker_config(), String.t(), String.t(), String.t()) :: result(map())
  @spec update_comment(tracker_config(), String.t(), String.t(), String.t(), [request_option()]) :: result(map())
  def update_comment(tracker, work_item_id, comment_id, comment_html, opts \\ [])
      when is_map(tracker) and is_binary(work_item_id) and is_binary(comment_id) and
             is_binary(comment_html) and is_list(opts) do
    request(tracker, :patch, "work-items/#{work_item_id}/comments/#{comment_id}/", Keyword.put(opts, :json, %{comment_html: comment_html}))
  end

  defp paginate(tracker, path, params, opts, acc) do
    case request(tracker, :get, path, Keyword.put(opts, :params, params)) do
      {:ok, body} ->
        with {:ok, items, next_params} <- decode_list_response(body) do
          updated_acc = Enum.reverse(items, acc)

          case next_params do
            nil -> {:ok, Enum.reverse(updated_acc)}
            next_params -> paginate(tracker, path, Map.merge(params, next_params), opts, updated_acc)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_list_response(body) when is_list(body), do: {:ok, body, nil}

  defp decode_list_response(%{"results" => results} = body) when is_list(results) do
    {:ok, results, next_page_params(body)}
  end

  defp decode_list_response(%{"data" => results} = body) when is_list(results) do
    {:ok, results, next_page_params(body)}
  end

  defp decode_list_response(%{"items" => items} = body) when is_list(items) do
    {:ok, items, next_page_params(body)}
  end

  defp decode_list_response(_body), do: {:error, :unexpected_payload}

  defp next_page_params(%{"next_cursor" => cursor}) when is_binary(cursor) and cursor != "" do
    %{"cursor" => cursor}
  end

  defp next_page_params(%{"cursor" => cursor}) when is_binary(cursor) and cursor != "" do
    %{"cursor" => cursor}
  end

  defp next_page_params(%{"next" => next_url}) when is_binary(next_url) and next_url != "" do
    case URI.parse(next_url) do
      %URI{query: nil} -> nil
      %URI{query: query} -> URI.decode_query(query)
    end
  end

  defp next_page_params(%{"next" => nil}), do: nil
  defp next_page_params(_body), do: nil

  defp build_request(opts, tracker, method, path) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    [
      method: method,
      url: build_url(tracker, path, Keyword.get(opts, :project_path?, true)),
      headers: build_headers(tracker, Keyword.get(opts, :headers, [])),
      params: normalize_query_params(Keyword.get(opts, :params, %{})),
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms]
    ]
    |> maybe_put_json(Keyword.get(opts, :json))
  end

  defp maybe_put_json(request, nil), do: request
  defp maybe_put_json(request, json) when is_map(json), do: Keyword.put(request, :json, json)

  defp build_url(tracker, path, true) do
    base = String.trim_trailing(to_string(Map.fetch!(tracker, :base_url)), "/")
    workspace_slug = URI.encode_www_form(to_string(Map.fetch!(tracker, :workspace_slug)))
    project_id = URI.encode_www_form(to_string(Map.fetch!(tracker, :project_id)))
    normalized_path = normalize_path(path)

    "#{base}/api/v1/workspaces/#{workspace_slug}/projects/#{project_id}/#{normalized_path}"
  end

  defp build_url(tracker, path, false) do
    base = String.trim_trailing(to_string(Map.fetch!(tracker, :base_url)), "/")
    workspace_slug = URI.encode_www_form(to_string(Map.fetch!(tracker, :workspace_slug)))
    normalized_path = normalize_path(path)

    "#{base}/api/v1/workspaces/#{workspace_slug}/#{normalized_path}"
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
  end

  defp build_headers(tracker, extra_headers) when is_list(extra_headers) do
    [
      {"X-API-Key", to_string(Map.fetch!(tracker, :api_key))},
      {"Content-Type", "application/json"}
      | extra_headers
    ]
  end

  defp normalize_method(method) when method in [:get, :post, :patch, :delete], do: method
  defp normalize_method("GET"), do: :get
  defp normalize_method("POST"), do: :post
  defp normalize_method("PATCH"), do: :patch
  defp normalize_method("DELETE"), do: :delete
  defp normalize_method("get"), do: :get
  defp normalize_method("post"), do: :post
  defp normalize_method("patch"), do: :patch
  defp normalize_method("delete"), do: :delete

  defp perform_request(request, attempt) do
    request_fun = Keyword.fetch!(request, :request_fun)
    sleep_fun = Keyword.fetch!(request, :sleep_fun)
    max_attempts = Keyword.fetch!(request, :max_attempts)
    retry_delay_ms = Keyword.fetch!(request, :retry_delay_ms)

    request
    |> strip_internal_options()
    |> request_fun.()
    |> handle_response(request, attempt, max_attempts, retry_delay_ms, sleep_fun)
  end

  defp handle_response({:ok, response}, request, attempt, max_attempts, retry_delay_ms, sleep_fun) do
    status = Map.get(response, :status) || Map.get(response, "status")
    body = Map.get(response, :body) || Map.get(response, "body")

    cond do
      is_integer(status) and status in 200..299 ->
        {:ok, body}

      status in [401, 403] ->
        {:error, :auth_failure}

      status == 404 ->
        {:error, :not_found}

      status == 429 and attempt < max_attempts ->
        retry_after_ms = retry_after_ms(response, retry_delay_ms)
        sleep_fun.(retry_after_ms)
        perform_request(request, attempt + 1)

      status == 429 ->
        {:error, :rate_limited}

      is_integer(status) and status >= 500 and status < 600 ->
        {:error, :skip_cycle}

      is_integer(status) ->
        {:error, {:unexpected_status, status, body}}

      true ->
        {:error, {:request_failed, {:invalid_response, response}}}
    end
  end

  defp handle_response({:error, reason}, _request, _attempt, _max_attempts, _retry_delay_ms, _sleep_fun) do
    if timeout_reason?(reason) do
      {:error, :skip_cycle}
    else
      {:error, {:request_failed, reason}}
    end
  end

  defp send_request(request) do
    Req.request(request)
  end

  defp strip_internal_options(request) do
    Keyword.drop(request, [:request_fun, :sleep_fun, :max_attempts, :retry_delay_ms])
  end

  defp retry_after_ms(response, default_ms) do
    case response_header(response, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1_000
          _ -> default_ms
        end

      _ ->
        default_ms
    end
  end

  defp response_header(response, header_name) do
    normalized_header = String.downcase(header_name)

    headers = Map.get(response, :headers) || Map.get(response, "headers") || []

    cond do
      is_map(headers) ->
        Enum.find_value(headers, fn {key, value} ->
          if String.downcase(to_string(key)) == normalized_header, do: value
        end)

      is_list(headers) ->
        Enum.find_value(headers, fn
          {key, value} when is_binary(key) ->
            if String.downcase(key) == normalized_header, do: value

          {key, value} when is_atom(key) ->
            if String.downcase(Atom.to_string(key)) == normalized_header, do: value

          _ ->
            nil
        end)

      true ->
        nil
    end
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:connect_timeout), do: true
  defp timeout_reason?(:receive_timeout), do: true
  defp timeout_reason?(%{reason: reason}), do: timeout_reason?(reason)

  defp timeout_reason?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&timeout_reason?/1)
  end

  defp timeout_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), "timeout")
  end

  defp timeout_reason?(_reason), do: false

  defp normalize_query_params(params) do
    params
    |> normalize_options_map()
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc ->
        Map.put(acc, to_string(key), normalize_query_value(value))
    end)
  end

  defp normalize_query_value(value) when is_list(value), do: Enum.join(value, ",")
  defp normalize_query_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_query_value(value), do: value

  defp extract_request_opts(options) when is_list(options), do: Keyword.take(options, @request_option_keys)

  defp extract_request_opts(options) when is_map(options) do
    options
    |> Map.take(@request_option_keys)
    |> Map.to_list()
  end

  defp normalize_options_map(options) when is_list(options), do: Map.new(options, fn {key, value} -> {to_string(key), value} end)
  defp normalize_options_map(options) when is_map(options), do: Map.new(options, fn {key, value} -> {to_string(key), value} end)
end
