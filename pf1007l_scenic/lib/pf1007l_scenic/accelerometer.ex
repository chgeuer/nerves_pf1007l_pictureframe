defmodule Pf1007lScenic.Accelerometer do
  @moduledoc """
  Polls the Silan SC7A20 3-axis accelerometer on `/dev/i2c-1` (`0x19`) via
  `/usr/bin/pf1007l-accel` and broadcasts screen orientation changes.

  Supports automatic orientation from the gravity vector as well as a
  user-adjustable 90-degree rotation offset and auto/lock toggle persisted in
  `/root/ui_prefs.term`.
  """

  use GenServer

  @prefs_path "/root/ui_prefs.term"
  @orientations [:portrait, :landscape, :portrait_inverted, :landscape_inverted]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe(pid \\ self()) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def state do
    GenServer.call(__MODULE__, :state)
  catch
    :exit, _ ->
      %{
        orientation: :landscape,
        sensor_orientation: :landscape,
        raw: {0, 0, 0},
        auto_rotate?: true,
        offset: 0
      }
  end

  def rotate_cw do
    GenServer.call(__MODULE__, :rotate_cw)
  catch
    :exit, _ -> :ok
  end

  def toggle_auto do
    GenServer.call(__MODULE__, :toggle_auto)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    prefs = load_prefs()

    state = %{
      port: open_accel_port(),
      raw: {576, 0, 868},
      sensor_orientation: :landscape,
      auto_rotate?: Map.get(prefs, :auto_rotate?, true),
      offset: Map.get(prefs, :offset, 0),
      locked_orientation: Map.get(prefs, :locked_orientation, :landscape),
      subscribers: MapSet.new()
    }

    {:ok, Map.put(state, :orientation, effective_orientation(state))}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    state = %{state | subscribers: MapSet.put(state.subscribers, pid)}
    {:reply, {:ok, public_state(state)}, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, public_state(state), state}
  end

  def handle_call(:rotate_cw, _from, state) do
    state =
      if state.auto_rotate? do
        %{state | offset: rem(state.offset + 1, 4)}
      else
        %{state | locked_orientation: rotate_orientation(state.locked_orientation, 1)}
      end

    state = update_effective(state, true)
    save_prefs(state)
    {:reply, {:ok, public_state(state)}, state}
  end

  def handle_call(:toggle_auto, _from, state) do
    new_auto = not state.auto_rotate?

    state = %{
      state
      | auto_rotate?: new_auto,
        locked_orientation: state.orientation
    }

    state = update_effective(state, true)
    save_prefs(state)
    {:reply, {:ok, public_state(state)}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case parse_xyz(line) do
      {:ok, {x, y, _z} = raw} ->
        sensor_ori = classify_gravity(x, y, state.sensor_orientation)
        state = %{state | raw: raw, sensor_orientation: sensor_ori}
        {:noreply, update_effective(state, false)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    Process.send_after(self(), :reopen_port, 2_000)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:reopen_port, state) do
    {:noreply, %{state | port: open_accel_port()}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp open_accel_port do
    bin = "/usr/bin/pf1007l-accel"

    if File.exists?(bin) do
      Port.open({:spawn_executable, bin}, [:binary, {:line, 128}, :exit_status])
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_xyz(line) when is_binary(line) do
    case String.split(String.trim(line), ~r/\s+/) do
      [xs, ys, zs] ->
        {:ok, {String.to_integer(xs), String.to_integer(ys), String.to_integer(zs)}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # Hysteresis threshold so the UI doesn't flutter when held near 45 degrees
  # or lying flat on a table.
  defp classify_gravity(x, y, current) do
    ax = abs(x)
    ay = abs(y)

    cond do
      ax < 220 and ay < 220 ->
        current

      ax > ay + 120 ->
        if x >= 0, do: :landscape, else: :landscape_inverted

      ay > ax + 120 ->
        if y >= 0, do: :portrait_inverted, else: :portrait

      true ->
        current
    end
  end

  defp effective_orientation(%{auto_rotate?: false, locked_orientation: locked}), do: locked

  defp effective_orientation(%{sensor_orientation: base, offset: offset}) do
    rotate_orientation(base, offset)
  end

  defp rotate_orientation(ori, steps) do
    idx = Enum.find_index(@orientations, &(&1 == ori)) || 0
    Enum.at(@orientations, rem(idx + steps, 4))
  end

  defp update_effective(state, force_notify?) do
    new_ori = effective_orientation(state)
    changed? = new_ori != state.orientation
    state = %{state | orientation: new_ori}

    if changed? or force_notify? do
      msg = {:orientation_changed, public_state(state)}
      Enum.each(state.subscribers, &send(&1, msg))
    end

    state
  end

  defp public_state(state) do
    %{
      orientation: state.orientation,
      sensor_orientation: state.sensor_orientation,
      raw: state.raw,
      auto_rotate?: state.auto_rotate?,
      offset: state.offset
    }
  end

  defp load_prefs do
    case File.read(@prefs_path) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save_prefs(state) do
    prefs = %{
      auto_rotate?: state.auto_rotate?,
      offset: state.offset,
      locked_orientation: state.locked_orientation
    }

    _ = File.write(@prefs_path, :erlang.term_to_binary(prefs))
    :ok
  end
end
