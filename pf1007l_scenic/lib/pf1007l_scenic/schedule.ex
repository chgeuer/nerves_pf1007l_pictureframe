defmodule Pf1007lScenic.Schedule do
  @moduledoc """
  Manages the persistent WebUntis student session on the PF1007L picture frame.

  Credentials (the Untis Mobile shared secret) are stored in
  `/root/untis_credentials.json` on the persistent F2FS `/root` partition.
  """

  require Logger
  alias Untis.{Client, Credentials, Session}

  @session __MODULE__.Session
  @supervisor __MODULE__.Supervisor
  @target_creds_path "/root/untis_credentials.json"

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {DynamicSupervisor, name: @supervisor},
             {Task, fn -> _ = resume() end}
           ],
           [strategy: :one_for_one]
         ]}
    }
  end

  def session, do: GenServer.whereis(@session)
  def logged_in?, do: session() != nil
  def saved_login?, do: File.exists?(credentials_path())

  def saved_info do
    case Credentials.load(path: credentials_path()) do
      {:ok, client} -> %{server: client.server, school: client.school, user: client.user}
      _ -> nil
    end
  end

  def today do
    # Shift UTC by +2h (CEST/CET approximation if TZ db isn't configured)
    DateTime.utc_now() |> DateTime.add(2 * 3600, :second) |> DateTime.to_date()
  end

  def search_schools(query) when is_binary(query) do
    Untis.search_schools(String.trim(query))
  end

  def login_with_password(server, school, user, password, opts \\ []) do
    with {:ok, client} <- new_client(server: server, school: school, user: user),
         {:ok, client} <- Untis.login(client, password, opts) do
      login(client)
    end
  end

  def login_with_qr(link) when is_binary(link) do
    with {:ok, client} <- Client.from_qr(link) do
      if blank?(client.secret), do: {:error, :missing_key}, else: login(client)
    end
  end

  def login(%Client{} = client) do
    with {:ok, user_data} <- Untis.user_data(client),
         :ok <- Credentials.save(client, path: credentials_path()),
         {:ok, _pid} <- start_session(client, user_data) do
      Logger.info("Signed in to WebUntis as #{client.user} at #{client.school}")
      {:ok, user_data}
    end
  end

  def resume do
    case Credentials.load(path: credentials_path()) do
      {:ok, client} ->
        Logger.info("Resuming WebUntis session for #{client.user} at #{client.school}")
        start_session(client, nil)

      error ->
        error
    end
  end

  def logout do
    res = Credentials.delete(path: credentials_path())
    stop_session()
    res
  end

  def subscribe(subscriber \\ self()) when is_pid(subscriber) do
    Task.start(fn ->
      with_session(fn pid ->
        :ok = Session.subscribe(pid, subscriber)
        {:ok, pid}
      end)
    end)
  end

  def targets, do: with_session(&Session.targets/1)

  def timetable(element, date, opts \\ []) do
    with_session(&Session.timetable(&1, element, date, opts))
  end

  def refresh, do: with_session(&Session.refresh/1)
  def status, do: with_session(&{:ok, Session.status(&1)})

  def credentials_path do
    if File.dir?("/root"), do: @target_creds_path, else: Credentials.default_path()
  end

  defp with_session(fun) do
    case session() do
      nil -> {:error, :not_logged_in}
      pid -> fun.(pid)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_logged_in}
  end

  defp start_session(client, user_data, attempts \\ 2) do
    stop_session()

    opts = [
      client: client,
      name: @session,
      refresh_interval: :timer.minutes(10),
      today: &__MODULE__.today/0,
      user_data: user_data
    ]

    case DynamicSupervisor.start_child(@supervisor, {Session, opts}) do
      {:error, {:already_started, _}} when attempts > 1 ->
        start_session(client, user_data, attempts - 1)

      result ->
        result
    end
  end

  defp stop_session do
    with pid when is_pid(pid) <- session() do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  defp new_client(fields) do
    if Enum.any?(fields, fn {_k, v} -> blank?(v) end) do
      {:error, :missing_fields}
    else
      fields = for {k, v} <- fields, do: {k, String.trim(v)}
      {:ok, Client.new(fields)}
    end
  end

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
end
