defmodule Tesla.Mock do
  @moduledoc """
  Mock adapter for better testing.

  ## Setup

  ```elixir
  # config/test.exs
  config :tesla, adapter: Tesla.Mock

  # in case MyClient defines specific adapter with `adapter SpecificAdapter`
  config :tesla, MyClient, adapter: Tesla.Mock
  ```

  ## Examples

  ```elixir
  defmodule MyAppTest do
    use ExUnit.Case

    setup do
      Tesla.Mock.mock(fn
        %{method: :get} ->
          %Tesla.Env{status: 200, body: "hello"}
      end)

      :ok
    end

    test "list things" do
      assert {:ok, env} = MyApp.get("...")
      assert env.status == 200
      assert env.body == "hello"
    end
  end
  ```

  ## Setting up mocks

  ```elixir
  # Match on method & url and return whole Tesla.Env
  Tesla.Mock.mock(fn
    %{method: :get, url: "http://example.com/list"} ->
      %Tesla.Env{status: 200, body: "hello"}
  end)

  # You can use any logic required
  Tesla.Mock.mock(fn env ->
    case env.url do
      "http://example.com/list" ->
        %Tesla.Env{status: 200, body: "ok!"}

      _ ->
        %Tesla.Env{status: 404, body: "NotFound"}
    end
  end)


  # mock will also accept short version of response
  # in the form of {status, headers, body}
  Tesla.Mock.mock(fn
    %{method: :post} -> {201, %{}, %{id: 42}}
  end)

  # mock will also accept error tuples in the form
  # of {:error, reason}
  Tesla.Mock.mock(fn
    %{method: :post} -> {:error, :timeout}
  end)
  ```

  ## Global mocks

  By default, mocks are bound to the current process,
  i.e. the process running a single test case.
  This design allows proper isolation between test cases
  and make testing in parallel (`async: true`) possible.

  While this style is recommended, there is one drawback:
  if Tesla client is called from different process
  it will not use the setup mock.

  To solve this issue it is possible to setup a global mock
  using `mock_global/1` function.

  ```elixir
  defmodule MyTest do
    use ExUnit.Case, async: false # must be false!

    setup_all do
      Tesla.Mock.mock_global fn
        env -> # ...
      end

      :ok
    end

    # ...
  end
  ```

  **WARNING**: Using global mocks may affect tests with local mock
  (because of fallback to global mock in case local one is not found)
  """

  defmodule Error do
    defexception env: nil, ex: nil, stacktrace: []

    def message(%__MODULE__{ex: nil}) do
      """
      There is no mock set for process #{inspect(self())}.
      Use Tesla.Mock.mock/1 to mock HTTP requests.

      See https://github.com/teamon/tesla#testing
      """
    end

    def message(%__MODULE__{env: env, ex: %FunctionClauseError{} = ex, stacktrace: stacktrace}) do
      """
      Request not mocked

      The following request was not mocked:

      #{inspect(env, pretty: true)}

      #{Exception.format(:error, ex, stacktrace)}
      """
    end
  end

  ## PUBLIC API

  @doc """
  Setup mocks for current test.

  This mock will only be available to the current process.
  """
  @spec mock((Tesla.Env.t() -> Tesla.Env.t() | {integer, map, any})) :: :ok
  def mock(fun) when is_function(fun) do
    pdict_set(fun)
    :ok
  end

  @doc """
  Setup global mocks.

  **WARNING**: This mock will be available to ALL processes.
  It might cause conflicts when running tests in parallel!
  """
  @spec mock_global((Tesla.Env.t() -> Tesla.Env.t() | {integer, map, any})) :: :ok
  def mock_global(fun) when is_function(fun) do
    agent_set(fun)
    :ok
  end

  ## HELPERS

  @type response_opt :: :headers | :status
  @type response_opts :: [{response_opt, any}]

  @doc """
  Return JSON response.

  Example

      import Tesla.Mock

      mock fn
        %{url: "/ok"} -> json(%{"some" => "data"})
        %{url: "/404"} -> json(%{"some" => "data"}, status: 404)
      end
  """
  @spec json(body :: term, opts :: response_opts) :: Tesla.Env.t()
  def json(body, opts \\ []), do: response(json_encode(body), "application/json", opts)

  defp json_encode(body) do
    engine = Keyword.get(Application.get_env(:tesla, Tesla.Mock, []), :json_engine, Jason)
    engine.encode!(body)
  end

  @doc """
  Return text response.

  Example

      import Tesla.Mock

      mock fn
        %{url: "/ok"} -> text("200 ok")
        %{url: "/404"} -> text("404 not found", status: 404)
      end
  """
  @spec text(body :: term, opts :: response_opts) :: Tesla.Env.t()
  def text(body, opts \\ []), do: response(body, "text/plain", opts)

  defp response(body, content_type, opts) do
    defaults = [status: 200, headers: [{"content-type", content_type}]]
    struct(Tesla.Env, Keyword.merge(defaults, [{:body, body} | opts]))
  end

  ## ADAPTER IMPLEMENTATION

  def call(env, _opts) do
    case pdict_get() || agent_get() do
      nil ->
        raise Tesla.Mock.Error, env: env

      fun ->
        case rescue_call(fun, env) do
          {status, headers, body} ->
            {:ok, %{env | status: status, headers: headers, body: body}}

          %Tesla.Env{} = env ->
            {:ok, env}

          {:ok, %Tesla.Env{} = env} ->
            {:ok, env}

          {:error, reason} ->
            {:error, reason}

          error ->
            {:error, error}
        end
    end
  end

  defp pdict_set(fun), do: Process.put(__MODULE__, fun)

  # Gets the mock fun for the current process or its ancestors
  defp pdict_get do
    callers = Process.get(:"$callers", [])
    # TODO: the standard way is to just look in $callers.
    # However, we were using $ancestors before and users were depending on that behaviour
    # https://github.com/elixir-tesla/tesla/issues/765
    # To make sure we don't break existing flows,
    # we will check mocks *both* in $callers and $ancestors
    # We might want to remove checking in $ancestors in a major release
    ancestors = Process.get(:"$ancestors", [])

    potential_mock_holder_pids =
      [self() | Enum.reverse(callers) ++ Enum.reverse(ancestors)]
      |> Enum.map(fn
        pid when is_pid(pid) -> pid
        atom when is_atom(atom) -> Process.whereis(atom)
      end)
      |> Enum.filter(&is_pid/1)

    Enum.find_value(potential_mock_holder_pids, nil, fn pid ->
      {:dictionary, process_dictionary} = Process.info(pid, :dictionary)
      Keyword.get(process_dictionary, __MODULE__)
    end)
  end

  defp agent_set(fun) do
    mock_start_result =
      ExUnit.Callbacks.start_supervised(
        %{
          id: __MODULE__,
          start: {Agent, :start_link, [fn -> fun end, [{:name, __MODULE__}]]}
        },
        []
      )

    case mock_start_result do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        Agent.update(pid, fn _ -> fun end)

      other ->
        raise other
    end
  end

  defp agent_get do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> Agent.get(pid, fn f -> f end)
    end
  end

  defp rescue_call(fun, env) do
    fun.(env)
  rescue
    ex in FunctionClauseError ->
      raise Tesla.Mock.Error, env: env, ex: ex, stacktrace: __STACKTRACE__
  end
end
