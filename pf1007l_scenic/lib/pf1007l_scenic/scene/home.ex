defmodule Pf1007lScenic.Scene.Home do
  @moduledoc """
  Orientation-aware Scenic UI for the PF1007L picture frame:
  - Auto-rotates between Landscape (`1280×800`) and Portrait (`800×1280`) via
    the Silan SC7A20 accelerometer (`Pf1007lScenic.Accelerometer`), with manual
    90° rotation and Auto/Lock controls.
  - Built-in Wi-Fi network scanner and touch QWERTY keyboard (`Pf1007lScenic.WiFi`).
  - Built-in WebUntis school search, login, and weekly student timetable grid
    (`Pf1007lScenic.Schedule` and `Pf1007lScenic.TimetableGrid`).
  """

  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  alias Pf1007lScenic.{Accelerometer, Schedule, TimetableGrid, WiFi}

  @bg {11, 17, 32}
  @panel {22, 32, 56}
  @panel_alt {30, 43, 72}
  @border {51, 69, 107}
  @text_main {241, 245, 249}
  @text_muted {148, 163, 184}
  @accent {56, 189, 248}
  @green {16, 185, 129}
  @amber {245, 158, 11}
  @red {239, 68, 68}
  @purple {139, 92, 246}

  @kb_rows_lower [
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "_"],
    ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "@", "."],
    ["a", "s", "d", "f", "g", "h", "j", "k", "l", ":", "/", "!"],
    ["SHIFT", "z", "x", "c", "v", "b", "n", "m", "?", "#", "BKSP"],
    ["SYM", "SPACE", "CLEAR", "DONE"]
  ]

  @kb_rows_upper [
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "_"],
    ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "@", "."],
    ["A", "S", "D", "F", "G", "H", "J", "K", "L", ":", "/", "!"],
    ["SHIFT", "Z", "X", "C", "V", "B", "N", "M", "?", "#", "BKSP"],
    ["SYM", "SPACE", "CLEAR", "DONE"]
  ]

  @kb_rows_sym [
    ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+"],
    ["~", "`", "|", "\\", "{", "}", "[", "]", ":", ";", "\"", "'"],
    ["<", ">", ",", ".", "?", "/", "=", "-", "+", "*", "&", "%"],
    ["SHIFT", "0", "1", "2", "3", "4", "5", "6", "7", "8", "BKSP"],
    ["ABC", "SPACE", "CLEAR", "DONE"]
  ]

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    :ok = request_input(scene, [:cursor_button, :cursor_pos])

    accel =
      case Accelerometer.subscribe(self()) do
        {:ok, st} -> st
        _ -> Accelerometer.state()
      end

    WiFi.subscribe()
    WiFi.scan()
    wifi = WiFi.status()

    today = Schedule.today()
    :timer.send_interval(5_000, :periodic_tick)

    state = %{
      view: :timetable,
      orientation: accel.orientation,
      auto_rotate?: accel.auto_rotate?,
      accel_raw: accel.raw,
      brightness: read_brightness(),
      touch_pos: {640, 400},
      hitboxes: [],
      # Wi-Fi UI state
      wifi: wifi,
      wifi_ssid: wifi.ssid || "",
      wifi_password: "",
      wifi_show_pw?: false,
      wifi_message: nil,
      # Untis UI + timetable state
      date: today,
      targets: [],
      selected_target_idx: 0,
      timetable: nil,
      grid: nil,
      selected_period: nil,
      untis_status: "Checking saved WebUntis credentials...",
      school_query: "",
      schools: [],
      untis_server: "",
      untis_school: "",
      untis_user: "",
      untis_password: "",
      untis_2fa: "",
      untis_show_pw?: false,
      # On-screen keyboard state
      active_field: nil,
      kb_mode: :lower
    }

    state =
      case Schedule.saved_info() do
        %{server: sv, school: sc, user: us} ->
          %{state | untis_server: sv, untis_school: sc, untis_user: us}

        _ ->
          state
      end

    send(self(), :sync_untis)
    scene = render_scene(scene, state)
    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_input({:cursor_button, {:btn_left, 1, _mods, {sx, sy}}}, _id, scene) do
    state = scene.assigns.state
    {lx, ly} = screen_to_logical({sx, sy}, state.orientation)
    state = %{state | touch_pos: {round(lx), round(ly)}}

    state =
      case find_hitbox(state.hitboxes, lx, ly) do
        nil -> state
        action -> handle_action(action, state)
      end

    {:noreply, render_scene(scene, state)}
  end

  def handle_input({:cursor_pos, {sx, sy}}, _id, scene) do
    {sx, sy} = drain_cursor_pos({sx, sy})
    state = scene.assigns.state
    {lx, ly} = screen_to_logical({sx, sy}, state.orientation)
    {:noreply, assign(scene, state: %{state | touch_pos: {round(lx), round(ly)}})}
  end

  def handle_input(_event, _id, scene), do: {:noreply, scene}

  @impl true
  def handle_info({:orientation_changed, accel}, scene) do
    state = %{
      scene.assigns.state
      | orientation: accel.orientation,
        auto_rotate?: accel.auto_rotate?,
        accel_raw: accel.raw
    }

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({VintageNet, ["interface", "wlan0" | _], _old, _new, _meta}, scene) do
    wifi = WiFi.status()
     prev_conn = scene.assigns.state.wifi.connection
    state = %{scene.assigns.state | wifi: wifi}

    if prev_conn not in [:internet, :lan] and wifi.connection in [:internet, :lan] do
      send(self(), :sync_untis)
    end

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({Untis.Session, _session, {:timetable, _element, _monday, _tt}}, scene) do
    send(self(), :load_timetable)
    {:noreply, scene}
  end

  def handle_info({Untis.Session, _session, {:error, err}}, scene) do
    state = %{scene.assigns.state | untis_status: "Untis sync error: #{Exception.message(err)}"}
    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:untis_session, _session, _event}, scene) do
    send(self(), :load_timetable)
    {:noreply, scene}
  end

  def handle_info(:periodic_tick, scene) do
    wifi = WiFi.status()
    accel = Accelerometer.state()
    today = Schedule.today()

    date =
      if abs(Date.diff(scene.assigns.state.date, today)) > 30 do
        today
      else
        scene.assigns.state.date
      end

    state = %{
      scene.assigns.state
      | wifi: wifi,
        date: date,
        orientation: accel.orientation,
        auto_rotate?: accel.auto_rotate?,
        accel_raw: accel.raw
    }

    if not Schedule.logged_in?() and Schedule.saved_login?() and wifi.connection in [:internet, :lan] do
      Task.start(fn -> _ = Schedule.resume() end)
      send(self(), :sync_untis)
    end

    {:noreply, render_scene(scene, state)}
  end

  def handle_info(:sync_untis, scene) do
    state = scene.assigns.state
    me = self()

    if Schedule.logged_in?() do
      _ = Schedule.subscribe(me)
      send(me, :load_timetable)
      {:noreply, scene}
    else
      if Schedule.saved_login?() do
        Task.start(fn ->
          _ = Schedule.resume()
          _ = Schedule.subscribe(me)
          send(me, :load_timetable)
        end)

        {:noreply, scene}
      else
        state = %{state | untis_status: "Not signed in to WebUntis. Tap 'Untis' to sign in."}
        {:noreply, render_scene(scene, state)}
      end
    end
  end

  def handle_info(:load_timetable, scene) do
    me = self()
    state = scene.assigns.state
    date = state.date
    target_idx = state.selected_target_idx

    Task.start(fn ->
      case Schedule.targets() do
        {:ok, targets} when targets != [] ->
          {_name, element} = Enum.at(targets, min(target_idx, length(targets) - 1))

          case Schedule.timetable(element, date) do
            {:ok, tt} ->
              send(me, {:timetable_loaded, targets, tt})

            {:error, reason} ->
              send(me, {:timetable_error, "Timetable fetch error: #{inspect(reason)}"})
          end

        {:ok, []} ->
          send(me, {:timetable_error, "WebUntis account has no timetable targets."})

        {:error, reason} ->
          send(me, {:timetable_error, "WebUntis status: #{inspect(reason)}"})
      end
    end)

    {:noreply, scene}
  end

  def handle_info({:timetable_loaded, targets, tt}, scene) do
    grid = TimetableGrid.build(tt)

    state = %{
      scene.assigns.state
      | targets: targets,
        timetable: tt,
        grid: grid,
        untis_status: "Updated #{Calendar.strftime(NaiveDateTime.utc_now(), "%H:%M:%S")} UTC"
    }

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:timetable_error, msg}, scene) do
    state = %{scene.assigns.state | untis_status: msg}
    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:schools_result, {:ok, schools}}, scene) do
    state = %{
      scene.assigns.state
      | schools: Enum.take(schools, 5),
        untis_status: "Found #{length(schools)} school(s). Tap one below to select it."
    }

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:schools_result, {:error, err}}, scene) do
    state = %{scene.assigns.state | untis_status: "School search failed: #{inspect(err)}"}
    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:login_result, {:ok, _user_data}}, scene) do
    _ = Schedule.subscribe(self())
    send(self(), :load_timetable)

    state = %{
      scene.assigns.state
      | view: :timetable,
        active_field: nil,
        untis_password: "",
        untis_2fa: "",
        untis_status: "Signed in to WebUntis! Loading timetable..."
    }

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:login_result, {:error, %Untis.Error{reason: :two_factor_required}}}, scene) do
    state = %{
      scene.assigns.state
      | active_field: :untis_2fa,
        untis_status: "2FA required: enter authenticator code and tap Sign In."
    }

    {:noreply, render_scene(scene, state)}
  end

  def handle_info({:login_result, {:error, err}}, scene) do
    state = %{scene.assigns.state | untis_status: "Sign-in failed: #{inspect(err)}"}
    {:noreply, render_scene(scene, state)}
  end

  def handle_info(_msg, scene), do: {:noreply, scene}

  # --- Actions ---

  defp handle_action({:nav, view}, state) do
    if view == :wifi, do: WiFi.scan()
    %{state | view: view, active_field: nil}
  end

  defp handle_action(:rotate_cw, state) do
    {:ok, accel} = Accelerometer.rotate_cw()
    %{state | orientation: accel.orientation, auto_rotate?: accel.auto_rotate?, accel_raw: accel.raw}
  end

  defp handle_action(:toggle_auto, state) do
    {:ok, accel} = Accelerometer.toggle_auto()
    %{state | orientation: accel.orientation, auto_rotate?: accel.auto_rotate?, accel_raw: accel.raw}
  end

  defp handle_action(:bright_down, state) do
    b = max(1, state.brightness - 2)
    write_brightness(b)
    %{state | brightness: b}
  end

  defp handle_action(:bright_up, state) do
    b = min(10, state.brightness + 2)
    write_brightness(b)
    %{state | brightness: b}
  end

  defp handle_action(:week_prev, state) do
    state = %{state | date: Date.add(state.date, -7), selected_period: nil}
    send(self(), :load_timetable)
    state
  end

  defp handle_action(:week_today, state) do
    state = %{state | date: Schedule.today(), selected_period: nil}
    send(self(), :load_timetable)
    state
  end

  defp handle_action(:week_next, state) do
    state = %{state | date: Date.add(state.date, 7), selected_period: nil}
    send(self(), :load_timetable)
    state
  end

  defp handle_action(:untis_refresh, state) do
    _ = Schedule.refresh()
    send(self(), :load_timetable)
    %{state | untis_status: "Refreshing timetable from WebUntis..."}
  end

  defp handle_action({:select_target, idx}, state) do
    state = %{state | selected_target_idx: idx, selected_period: nil}
    send(self(), :load_timetable)
    state
  end

  defp handle_action({:select_period, period}, state) do
    %{state | selected_period: period}
  end

  defp handle_action(:wifi_scan, state) do
    WiFi.scan()
    %{state | wifi: WiFi.status(), wifi_message: "Scanning 2.4 GHz Wi-Fi networks..."}
  end

  defp handle_action({:select_ap, ssid}, state) do
    %{
      state
      | wifi_ssid: ssid,
        active_field: :wifi_password,
        wifi_message: "Selected '#{ssid}'. Enter password below and tap Connect."
    }
  end

  defp handle_action(:wifi_toggle_pw, state) do
    %{state | wifi_show_pw?: not state.wifi_show_pw?}
  end

  defp handle_action(:wifi_connect, state) do
    case WiFi.connect(state.wifi_ssid, state.wifi_password) do
      :ok ->
        %{
          state
          | active_field: nil,
            wifi_message: "Connecting to '#{state.wifi_ssid}' (credentials saved to /root)..."
        }

      {:error, err} ->
        %{state | wifi_message: "Failed to configure Wi-Fi: #{inspect(err)}"}
    end
  end

  defp handle_action({:focus_field, field}, state) do
    %{state | active_field: field}
  end

  defp handle_action(:untis_toggle_pw, state) do
    %{state | untis_show_pw?: not state.untis_show_pw?}
  end

  defp handle_action(:untis_search_schools, state) do
    q = String.trim(state.school_query)

    if q == "" do
      %{state | untis_status: "Type a school name or city first, then tap Search."}
    else
      me = self()
      Task.start(fn -> send(me, {:schools_result, Schedule.search_schools(q)}) end)
      %{state | active_field: nil, untis_status: "Searching WebUntis for '#{q}'..."}
    end
  end

  defp handle_action({:select_school, school}, state) do
    %{
      state
      | untis_server: school.server,
        untis_school: school.login_name,
        active_field: :untis_user,
        untis_status: "Selected #{school.display_name} (#{school.login_name}). Enter username & password."
    }
  end

  defp handle_action(:untis_sign_in, state) do
    me = self()
    sv = state.untis_server
    sc = state.untis_school
    us = state.untis_user
    pw = state.untis_password
    tfa = String.trim(state.untis_2fa)
    opts = if tfa == "", do: [], else: [two_factor_code: tfa]

    Task.start(fn ->
      send(me, {:login_result, Schedule.login_with_password(sv, sc, us, pw, opts)})
    end)

    %{state | active_field: nil, untis_status: "Signing in to #{sc} (#{sv}) as #{us}..."}
  end

  defp handle_action(:untis_logout, state) do
    _ = Schedule.logout()

    %{
      state
      | timetable: nil,
        grid: nil,
        targets: [],
        untis_status: "Signed out and deleted saved key."
    }
  end

  defp handle_action({:kb_key, key}, state) do
    case key do
      "SHIFT" ->
        next = if state.kb_mode == :upper, do: :lower, else: :upper
        %{state | kb_mode: next}

      "SYM" ->
        %{state | kb_mode: :sym}

      "ABC" ->
        %{state | kb_mode: :lower}

      "DONE" ->
        %{state | active_field: nil}

      "CLEAR" ->
        put_active_field(state, "")

      "BKSP" ->
        cur = get_active_field(state)
        len = String.length(cur)
        put_active_field(state, if(len > 0, do: String.slice(cur, 0, len - 1), else: ""))

      "SPACE" ->
        put_active_field(state, get_active_field(state) <> " ")

      ch ->
        put_active_field(state, get_active_field(state) <> ch)
    end
  end

  defp handle_action(_other, state), do: state

  defp get_active_field(state) do
    case state.active_field do
      :wifi_ssid -> state.wifi_ssid
      :wifi_password -> state.wifi_password
      :school_query -> state.school_query
      :untis_server -> state.untis_server
      :untis_school -> state.untis_school
      :untis_user -> state.untis_user
      :untis_password -> state.untis_password
      :untis_2fa -> state.untis_2fa
      _ -> ""
    end
  end

  defp put_active_field(state, val) do
    case state.active_field do
      :wifi_ssid -> %{state | wifi_ssid: val}
      :wifi_password -> %{state | wifi_password: val}
      :school_query -> %{state | school_query: val}
      :untis_server -> %{state | untis_server: val}
      :untis_school -> %{state | untis_school: val}
      :untis_user -> %{state | untis_user: val}
      :untis_password -> %{state | untis_password: val}
      :untis_2fa -> %{state | untis_2fa: val}
      _ -> state
    end
  end

  # --- Coordinate & Orientation Transform ---

  defp logical_size(:landscape), do: {1280, 800}
  defp logical_size(:landscape_inverted), do: {1280, 800}
  defp logical_size(_portrait), do: {800, 1280}

  defp rot_group_opts(:portrait), do: [pin: {0, 0}, rotate: 0.0, translate: {0, 0}]
  defp rot_group_opts(:portrait_inverted), do: [pin: {0, 0}, rotate: :math.pi(), translate: {800, 1280}]
  defp rot_group_opts(:landscape), do: [pin: {0, 0}, rotate: :math.pi() / 2, translate: {800, 0}]
  defp rot_group_opts(:landscape_inverted), do: [pin: {0, 0}, rotate: -:math.pi() / 2, translate: {0, 1280}]

  defp screen_to_logical({sx, sy}, :portrait), do: {sx, sy}
  defp screen_to_logical({sx, sy}, :portrait_inverted), do: {800.0 - sx, 1280.0 - sy}
  defp screen_to_logical({sx, sy}, :landscape), do: {sy, 800.0 - sx}
  defp screen_to_logical({sx, sy}, :landscape_inverted), do: {1280.0 - sy, sx}

  defp find_hitbox(hitboxes, lx, ly) do
    Enum.find_value(hitboxes, fn {action, x, y, w, h} ->
      if lx >= x and lx <= x + w and ly >= y and ly <= y + h, do: action, else: nil
    end)
  end

  # --- Rendering ---

  defp render_scene(scene, state) do
    {w, h} = logical_size(state.orientation)

    {inner_fn, hitboxes} =
      build_ui({w, h}, state)

    graph =
      Graph.build(font: :roboto, font_size: 20)
      |> group(
        fn g ->
          g
          |> rect({w, h}, fill: @bg)
          |> inner_fn.()
        end,
        rot_group_opts(state.orientation)
      )

    state = %{state | hitboxes: hitboxes}

    scene
    |> assign(state: state)
    |> push_graph(graph)
  end

  defp build_ui({w, h}, state) do
    {top_fn, top_hb} = build_top_bar(w, state)

    {body_fn, body_hb} =
      case state.view do
        :timetable -> build_timetable_view({w, h}, state)
        :wifi -> build_wifi_view({w, h}, state)
        :untis -> build_untis_view({w, h}, state)
      end

    {kb_fn, kb_hb} =
      if state.active_field != nil do
        build_keyboard({w, h}, state)
      else
        {fn g -> g end, []}
      end

    # Put keyboard hitboxes first so when open, keyboard keys take priority
    hitboxes = kb_hb ++ top_hb ++ body_hb

    ui_fn = fn g ->
      g
      |> top_fn.()
      |> body_fn.()
      |> kb_fn.()
    end

    {ui_fn, hitboxes}
  end

  defp build_top_bar(w, state) do
    wifi_ok? = state.wifi.connection in [:internet, :lan]
    wifi_color = if wifi_ok?, do: @green, else: @amber

    wifi_label =
      cond do
        wifi_ok? and is_binary(state.wifi.ssid) -> "Wi-Fi: #{truncate(state.wifi.ssid, 11)}"
        wifi_ok? -> "Wi-Fi: Online"
        true -> "Wi-Fi: Setup"
      end

    untis_color = if Schedule.logged_in?(), do: @accent, else: @amber
    untis_label = if Schedule.logged_in?(), do: "Untis ✓", else: "Untis Login"
    auto_label = if state.auto_rotate?, do: "AUTO", else: "LOCK"
    auto_color = if state.auto_rotate?, do: @green, else: @panel_alt

    buttons =
      if w >= 1000 do
        [
          {{:nav, :timetable}, 16, 12, 165, 52, "Timetable", if(state.view == :timetable, do: @accent, else: @panel_alt)},
          {:week_prev, 192, 12, 64, 52, "◀", @panel_alt},
          {:week_today, 262, 12, 92, 52, "Today", @panel_alt},
          {:week_next, 360, 12, 64, 52, "▶", @panel_alt},
          {:untis_refresh, 430, 12, 68, 52, "↻", @panel_alt},
          {{:nav, :wifi}, w - 540, 12, 175, 52, wifi_label, if(state.view == :wifi, do: @accent, else: wifi_color)},
          {{:nav, :untis}, w - 355, 12, 130, 52, untis_label, if(state.view == :untis, do: @accent, else: untis_color)},
          {:rotate_cw, w - 215, 12, 62, 52, "⟳", @panel_alt},
          {:toggle_auto, w - 147, 12, 68, 52, auto_label, auto_color},
          {:bright_down, w - 73, 12, 30, 52, "-", @panel_alt},
          {:bright_up, w - 38, 12, 30, 52, "+", @panel_alt}
        ]
      else
        [
          {{:nav, :timetable}, 12, 12, 126, 50, "Schedule", if(state.view == :timetable, do: @accent, else: @panel_alt)},
          {:week_prev, 144, 12, 48, 50, "◀", @panel_alt},
          {:week_today, 196, 12, 74, 50, "Today", @panel_alt},
          {:week_next, 274, 12, 48, 50, "▶", @panel_alt},
          {{:nav, :wifi}, 328, 12, 152, 50, wifi_label, if(state.view == :wifi, do: @accent, else: wifi_color)},
          {{:nav, :untis}, 486, 12, 114, 50, untis_label, if(state.view == :untis, do: @accent, else: untis_color)},
          {:rotate_cw, 606, 12, 54, 50, "⟳", @panel_alt},
          {:toggle_auto, 664, 12, 62, 50, auto_label, auto_color},
          {:bright_down, 730, 12, 28, 50, "-", @panel_alt},
          {:bright_up, 762, 12, 28, 50, "+", @panel_alt}
        ]
      end

    hitboxes = Enum.map(buttons, fn {act, x, y, bw, bh, _lbl, _col} -> {act, x, y, bw, bh} end)

    draw_fn = fn g ->
      g =
        g
        |> rect({w, 76}, fill: @panel)
        |> line({{0, 76}, {w, 76}}, stroke: {2, @border})

      Enum.reduce(buttons, g, fn {_act, x, y, bw, bh, lbl, col}, acc ->
        draw_button(acc, x, y, bw, bh, lbl, col)
      end)
    end

    {draw_fn, hitboxes}
  end

  # --- View 1: Student Timetable Grid ---

  defp build_timetable_view({w, h}, state) do
    # Target selector chips if multiple targets exist
    {target_btns, target_y_offset} =
      if length(state.targets) > 1 do
        btns =
          state.targets
          |> Enum.with_index()
          |> Enum.map(fn {{name, _el}, idx} ->
            x = 16 + idx * 190
            col = if idx == state.selected_target_idx, do: @accent, else: @panel_alt
            {{:select_target, idx}, x, 84, 180, 38, truncate(name, 16), col}
          end)

        {btns, 46}
      else
        {[], 0}
      end

    top_y = 86 + target_y_offset
    footer_h = 88
    grid_h = h - top_y - footer_h - 10

    case state.grid do
      %{days: days, rows: rows} when days != [] and rows != [] ->
        num_days = length(days)
        num_rows = length(rows)
        time_col_w = if w >= 1000, do: 92, else: 74
        day_col_w = div(w - time_col_w - 24, max(num_days, 1))
        header_h = 44
        row_h = max(48, div(grid_h - header_h, max(num_rows, 1)))
        today = Schedule.today()

        period_cards =
          for {row, r_idx} <- Enum.with_index(rows),
              {cell_periods, d_idx} <- Enum.with_index(row.cells),
              cell_periods != [] do
            cx = 12 + time_col_w + d_idx * day_col_w + 3
            cy = top_y + header_h + r_idx * row_h + 3
            cw = day_col_w - 6
            ch = row_h - 6
            p = hd(cell_periods)
            {{:select_period, p}, cx, cy, cw, ch, p, length(cell_periods)}
          end

        hitboxes =
          Enum.map(target_btns, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end) ++
            Enum.map(period_cards, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)

        draw_fn = fn g ->
          g =
            Enum.reduce(target_btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
              draw_button(acc, x, y, bw, bh, lbl, col, 18)
            end)

          # Day column headers
          g =
            days
            |> Enum.with_index()
            |> Enum.reduce(g, fn {day, d_idx}, acc ->
              dx = 12 + time_col_w + d_idx * day_col_w
              is_today? = Date.compare(day.date, today) == :eq
              hdr_col = if is_today?, do: {24, 68, 108}, else: @panel

              acc
              |> rrect({day_col_w - 4, header_h - 4, 8}, fill: hdr_col, translate: {dx + 2, top_y})
              |> text(TimetableGrid.day_short(day.date),
                font_size: if(w >= 1000, do: 20, else: 17),
                fill: if(is_today?, do: @accent, else: @text_main),
                translate: {dx + 14, top_y + 28}
              )
            end)

          # Lesson slot rows & background cells
          g =
            rows
            |> Enum.with_index()
            |> Enum.reduce(g, fn {row, r_idx}, acc ->
              ry = top_y + header_h + r_idx * row_h
              t_start = TimetableGrid.format_time(row.start)
              t_end = TimetableGrid.format_time(row.end)

              acc =
                acc
                |> rrect({time_col_w - 4, row_h - 4, 6}, fill: @panel, translate: {12, ry + 2})
                |> text(t_start,
                  font_size: 16,
                  fill: @text_main,
                  translate: {18, ry + 22}
                )
                |> text(t_end,
                  font_size: 14,
                  fill: @text_muted,
                  translate: {18, ry + 42}
                )

              Enum.reduce(0..(num_days - 1), acc, fn d_idx, acc2 ->
                dx = 12 + time_col_w + d_idx * day_col_w
                rrect(acc2, {day_col_w - 6, row_h - 6, 6}, fill: {17, 25, 44}, translate: {dx + 3, ry + 3})
              end)
            end)

          # Holiday overlays
          g =
            days
            |> Enum.with_index()
            |> Enum.reduce(g, fn {day, d_idx}, acc ->
              if day.holiday do
                dx = 12 + time_col_w + d_idx * day_col_w
                hy = top_y + header_h + 4
                hh = num_rows * row_h - 8

                acc
                |> rrect({day_col_w - 8, hh, 8}, fill: {28, 42, 68}, translate: {dx + 4, hy})
                |> text(truncate(day.holiday.long_name || day.holiday.name || "Holiday", 16),
                  font_size: 18,
                  fill: @accent,
                  translate: {dx + 12, hy + 40}
                )
              else
                acc
              end
            end)

          # Period cards
          g =
            Enum.reduce(period_cards, g, fn {_act, cx, cy, cw, ch, p, count}, acc ->
              draw_period_card(acc, cx, cy, cw, ch, p, count)
            end)

          draw_footer_inspector(g, {w, h}, footer_h, state)
        end

        {draw_fn, hitboxes}

      _ ->
        # Empty / Onboarding state when not logged in or loading
        btns = [
          {{:nav, :wifi}, div(w, 2) - 270, div(h, 2) + 10, 250, 64, "1. Configure Wi-Fi", @green},
          {{:nav, :untis}, div(w, 2) + 20, div(h, 2) + 10, 250, 64, "2. WebUntis Sign In", @accent}
        ]

        hitboxes = Enum.map(btns, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)
        {ax, ay, az} = state.accel_raw

        draw_fn = fn g ->
          g =
            g
            |> rrect({w - 80, 320, 16}, fill: @panel, stroke: {2, @border}, translate: {40, div(h, 2) - 180})
            |> text("Student Timetable Dashboard (PF1007L)",
              font_size: 32,
              fill: @text_main,
              translate: {80, div(h, 2) - 115}
            )
            |> text(state.untis_status,
              font_size: 22,
              fill: @accent,
              translate: {80, div(h, 2) - 65}
            )
            |> text(
              "Wi-Fi: #{state.wifi.connection} (#{state.wifi.ssid || "none"}, IP: #{state.wifi.ip || "none"})   |   Orientation: #{state.orientation} (SC7A20 X=#{ax} Y=#{ay} Z=#{az})",
              font_size: 18,
              fill: @text_muted,
              translate: {80, div(h, 2) - 22}
            )

          Enum.reduce(btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
            draw_button(acc, x, y, bw, bh, lbl, col, 22)
          end)
        end

        {draw_fn, hitboxes}
    end
  end

  defp draw_period_card(g, x, y, w, h, period, count) do
    status = TimetableGrid.status(period)

    {bg, border_col, badge} =
      case status do
        :cancelled -> {{68, 24, 34}, @red, "CANCELLED"}
        :exam -> {{54, 32, 88}, @purple, "EXAM"}
        :changed -> {{72, 48, 18}, @amber, "CHANGED"}
        :regular -> {{26, 49, 78}, @accent, nil}
      end

    subj =
      case period.subjects do
        [s | _] -> s.name || s.long_name || "?"
        _ -> period.lesson_text || "Lesson"
      end

    room =
      case period.rooms do
        [r | _] -> r.name || ""
        _ -> ""
      end

    teacher =
      case period.teachers do
        [t | _] -> t.name || ""
        _ -> ""
      end

    extra = if count > 1, do: " (+#{count - 1})", else: ""
    line1 = truncate("#{subj}#{extra}", div(w, 10))
    line2 = truncate(String.trim("#{room}  #{teacher}"), div(w, 9))

    g =
      g
      |> rrect({w, h, 8}, fill: bg, stroke: {2, border_col}, translate: {x, y})
      |> text(line1,
        font_size: if(h >= 58, do: 20, else: 17),
        fill: @text_main,
        translate: {x + 10, y + 23}
      )

    g =
      if h >= 46 and line2 != "" do
        text(g, line2,
          font_size: 15,
          fill: @text_muted,
          translate: {x + 10, y + 43}
        )
      else
        g
      end

    if badge && h >= 64 do
      text(g, badge,
        font_size: 13,
        fill: border_col,
        translate: {x + 10, y + h - 8}
      )
    else
      g
    end
  end

  defp draw_footer_inspector(g, {w, h}, footer_h, state) do
    fy = h - footer_h
    {ax, ay, az} = state.accel_raw

    {line1, line2} =
      case state.selected_period do
        nil ->
          target_name =
            case Enum.at(state.targets, state.selected_target_idx) do
              {n, _} -> n
              _ -> "Student"
            end

          {
            "#{target_name} • Week of #{Date.to_iso8601(state.date)} • Tap any lesson card for details",
            "#{state.untis_status}   |   Wi-Fi: #{state.wifi.ssid || state.wifi.connection} (#{state.wifi.ip || "-"})   |   #{state.orientation} (X=#{ax} Y=#{ay} Z=#{az})"
          }

        p ->
          subjs = Enum.map_join(p.subjects, ", ", &(&1.long_name || &1.name))
          teachers = Enum.map_join(p.teachers, ", ", &(&1.long_name || &1.name))
          rooms = Enum.map_join(p.rooms, ", ", &(&1.long_name || &1.name))
          t_str = "#{TimetableGrid.format_time(p.start)}–#{TimetableGrid.format_time(p.end)}"

          notes =
            [p.substitution_text, p.lesson_text, p.info]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join(" • ")

          hw =
            case p.homework do
              [first | _] -> " | HW: #{first.text}"
              _ -> ""
            end

          {
            "#{t_str}  #{subjs}  —  Room: #{rooms}  —  Teacher: #{teachers}",
            truncate("#{if notes == "", do: "Regular lesson", else: notes}#{hw}", div(w, 8))
          }
      end

    g
    |> rect({w, footer_h}, fill: @panel, translate: {0, fy})
    |> line({{0, fy}, {w, fy}}, stroke: {2, @border})
    |> text(truncate(line1, div(w, 9)),
      font_size: 20,
      fill: @text_main,
      translate: {20, fy + 32}
    )
    |> text(truncate(line2, div(w, 8)),
      font_size: 16,
      fill: @text_muted,
      translate: {20, fy + 62}
    )
  end

  # --- View 2: On-Screen Wi-Fi Setup ---

  defp build_wifi_view({w, _h}, state) do
    pw_masked =
      if state.wifi_show_pw? do
        state.wifi_password
      else
        String.duplicate("•", String.length(state.wifi_password))
      end

    aps = Enum.take(state.wifi.access_points, 6)

    ap_btns =
      aps
      |> Enum.with_index()
      |> Enum.map(fn {ap, idx} ->
        y = 195 + idx * 54
        sec = if ap.secure?, do: "WPA2", else: "Open"
        lbl = "#{ap.ssid}   (#{ap.signal_percent}% • #{sec})"
        col = if ap.ssid == state.wifi_ssid, do: {28, 78, 118}, else: @panel_alt
        {{:select_ap, ap.ssid}, 24, y, div(w, 2) - 36, 48, lbl, col}
      end)

    rx = div(w, 2) + 12
    rw = div(w, 2) - 36

    form_btns = [
      {:wifi_scan, 24, 132, 200, 48, "↻ Scan Networks", @accent},
      {{:focus_field, :wifi_ssid}, rx, 155, rw, 52, "SSID: #{state.wifi_ssid}",
       if(state.active_field == :wifi_ssid, do: {28, 78, 118}, else: @panel_alt)},
      {{:focus_field, :wifi_password}, rx, 222, rw - 100, 52, "Password: #{pw_masked}",
       if(state.active_field == :wifi_password, do: {28, 78, 118}, else: @panel_alt)},
      {:wifi_toggle_pw, rx + rw - 92, 222, 92, 52, if(state.wifi_show_pw?, do: "Hide", else: "Show"), @panel_alt},
      {:wifi_connect, rx, 290, rw, 58, "Connect & Save to /root", @green}
    ]

    all_btns = ap_btns ++ form_btns
    hitboxes = Enum.map(all_btns, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)

    draw_fn = fn g ->
      status_str =
        "wlan0: #{state.wifi.connection}   |   SSID: #{state.wifi.ssid || "none"}   |   IPv4: #{state.wifi.ip || "none"}"

      g =
        g
        |> text("Wi-Fi Network Configuration (AIC8800DC)",
          font_size: 26,
          fill: @text_main,
          translate: {24, 114}
        )
        |> text(status_str,
          font_size: 18,
          fill: @accent,
          translate: {245, 164}
        )
        |> text(state.wifi_message || "Tap a network on the left or enter an SSID on the right.",
          font_size: 18,
          fill: @text_muted,
          translate: {rx, 378}
        )

      Enum.reduce(all_btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
        draw_button(acc, x, y, bw, bh, lbl, col, 19)
      end)
    end

    {draw_fn, hitboxes}
  end

  # --- View 3: On-Screen WebUntis Setup ---

  defp build_untis_view({w, _h}, state) do
    pw_masked =
      if state.untis_show_pw? do
        state.untis_password
      else
        String.duplicate("•", String.length(state.untis_password))
      end

    lw = div(w, 2) - 36
    rx = div(w, 2) + 12
    rw = div(w, 2) - 36

    school_btns =
      state.schools
      |> Enum.with_index()
      |> Enum.map(fn {s, idx} ->
        y = 250 + idx * 52
        lbl = truncate("#{s.display_name} (#{s.login_name})", 34)
        col = if s.login_name == state.untis_school, do: {28, 78, 118}, else: @panel_alt
        {{:select_school, s}, 24, y, lw, 46, lbl, col}
      end)

    form_btns = [
      {{:focus_field, :school_query}, 24, 132, lw - 120, 50, "Search: #{state.school_query}",
       if(state.active_field == :school_query, do: {28, 78, 118}, else: @panel_alt)},
      {:untis_search_schools, 24 + lw - 112, 132, 112, 50, "Search", @accent},
      {{:focus_field, :untis_server}, rx, 132, rw, 46, "Server: #{state.untis_server}",
       if(state.active_field == :untis_server, do: {28, 78, 118}, else: @panel_alt)},
      {{:focus_field, :untis_school}, rx, 186, rw, 46, "School: #{state.untis_school}",
       if(state.active_field == :untis_school, do: {28, 78, 118}, else: @panel_alt)},
      {{:focus_field, :untis_user}, rx, 240, rw, 46, "User: #{state.untis_user}",
       if(state.active_field == :untis_user, do: {28, 78, 118}, else: @panel_alt)},
      {{:focus_field, :untis_password}, rx, 294, rw - 92, 46, "Password: #{pw_masked}",
       if(state.active_field == :untis_password, do: {28, 78, 118}, else: @panel_alt)},
      {:untis_toggle_pw, rx + rw - 84, 294, 84, 46, if(state.untis_show_pw?, do: "Hide", else: "Show"), @panel_alt},
      {{:focus_field, :untis_2fa}, rx, 348, div(rw, 2) - 6, 46, "2FA: #{state.untis_2fa}",
       if(state.active_field == :untis_2fa, do: {28, 78, 118}, else: @panel_alt)},
      {:untis_logout, rx + div(rw, 2) + 6, 348, div(rw, 2) - 6, 46, "Sign Out", @red},
      {:untis_sign_in, rx, 404, rw, 54, "Sign In & Save Key", @green}
    ]

    all_btns = school_btns ++ form_btns
    hitboxes = Enum.map(all_btns, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)

    draw_fn = fn g ->
      g =
        g
        |> text("WebUntis Account & School Setup",
          font_size: 24,
          fill: @text_main,
          translate: {24, 112}
        )
        |> text(truncate(state.untis_status, div(w, 9)),
          font_size: 18,
          fill: @accent,
          translate: {24, 224}
        )

      Enum.reduce(all_btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
        draw_button(acc, x, y, bw, bh, lbl, col, 18)
      end)
    end

    {draw_fn, hitboxes}
  end

  # --- On-Screen Touch QWERTY Keyboard ---

  defp build_keyboard({w, h}, state) do
    rows =
      case state.kb_mode do
        :upper -> @kb_rows_upper
        :sym -> @kb_rows_sym
        _ -> @kb_rows_lower
      end

    kb_h = 310
    kb_y = h - kb_h
    row_h = 50
    pad = 6

    key_specs =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row_keys, r_idx} ->
        ry = kb_y + 48 + r_idx * (row_h + pad)
        n = length(row_keys)
        base_w = div(w - 24 - (n - 1) * pad, n)

        row_keys
        |> Enum.with_index()
        |> Enum.map(fn {k, k_idx} ->
          kx = 12 + k_idx * (base_w + pad)

          col =
            cond do
              k == "DONE" -> @green
              k in ["BKSP", "CLEAR"] -> @red
              k in ["SHIFT", "SYM", "ABC"] -> @accent
              true -> @panel_alt
            end

          {{:kb_key, k}, kx, ry, base_w, row_h, k, col}
        end)
      end)

    hitboxes = Enum.map(key_specs, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)
    cur_val = get_active_field(state)

    draw_fn = fn g ->
      g =
        g
        |> rect({w, kb_h}, fill: {8, 12, 24}, translate: {0, kb_y})
        |> line({{0, kb_y}, {w, kb_y}}, stroke: {2, @accent})
        |> text("Editing #{state.active_field}:  #{cur_val}_",
          font_size: 22,
          fill: @accent,
          translate: {20, kb_y + 32}
        )

      Enum.reduce(key_specs, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
        draw_button(acc, x, y, bw, bh, lbl, col, 20)
      end)
    end

    {draw_fn, hitboxes}
  end

  defp draw_button(g, x, y, w, h, label, bg_color, font_sz \\ 20) do
    g
    |> rrect({w, h, 8}, fill: bg_color, stroke: {1, @border}, translate: {x, y})
    |> text(label,
      font_size: font_sz,
      fill: @text_main,
      translate: {x + 12, y + div(h, 2) + div(font_sz, 3)}
    )
  end

  defp truncate(str, max_chars) when is_binary(str) and max_chars > 3 do
    if String.length(str) > max_chars do
      String.slice(str, 0, max_chars - 1) <> "…"
    else
      str
    end
  end

  defp truncate(str, _), do: to_string(str || "")

  defp drain_cursor_pos(latest) do
    receive do
      {:_input, {:cursor_pos, pos}, _context, _id} ->
        drain_cursor_pos(pos)
    after
      0 -> latest
    end
  end

  defp read_brightness do
    case File.read("/sys/class/backlight/backlight/brightness") do
      {:ok, val} -> val |> String.trim() |> String.to_integer()
      _ -> 8
    end
  end

  defp write_brightness(level) do
    _ = File.write("/sys/class/backlight/backlight/brightness", "#{level}\n")
    :ok
  end
end
