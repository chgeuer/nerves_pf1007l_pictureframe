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
  @panel_alt {30, 43, 72}
  @border {51, 69, 107}
  @text_main {241, 245, 249}
  @text_muted {148, 163, 184}
  @accent {56, 189, 248}
  @green {16, 185, 129}
  @red {239, 68, 68}

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
      theme: :light,
      orientation: accel.orientation,
      auto_rotate?: accel.auto_rotate?,
      accel_raw: accel.raw,
      brightness: read_brightness(),
      touch_pos: {400, 640},
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
    date_jumped? = abs(Date.diff(scene.assigns.state.date, today)) > 30

    date =
      if date_jumped? do
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

    cond do
      not Schedule.logged_in?() and Schedule.saved_login?() and wifi.connection in [:internet, :lan] ->
        Task.start(fn -> _ = Schedule.resume() end)
        send(self(), :sync_untis)

      (date_jumped? or state.timetable == nil) and Schedule.logged_in?() and wifi.connection in [:internet, :lan] ->
        send(self(), :sync_untis)

      true ->
        :ok
    end

    {:noreply, render_scene(scene, state)}
  end

  def handle_info(:sync_untis, scene) do
    state = scene.assigns.state
    me = self()

    if Schedule.logged_in?() do
      Task.start(fn ->
        _ = Schedule.refresh()
        _ = Schedule.subscribe(me)
        send(me, :load_timetable)
      end)

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

  defp handle_action(:toggle_theme, state) do
    next = if state.theme == :light, do: :dark, else: :light
    %{state | theme: next}
  end

  defp handle_action(:cycle_target, state) do
    if length(state.targets) > 1 do
      next_idx = rem(state.selected_target_idx + 1, length(state.targets))
      state = %{state | view: :timetable, selected_target_idx: next_idx, selected_period: nil}
      send(self(), :load_timetable)
      state
    else
      %{state | view: :timetable, active_field: nil}
    end
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

      {:error, err} when is_binary(err) ->
        %{state | wifi_message: "Wi-Fi error: #{err}"}

      {:error, err} ->
        %{state | wifi_message: "Wi-Fi error: #{inspect(err)}"}
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
  defp screen_to_logical({sx, sy}, :landscape), do: {sy, max(0.0, 800.0 - sx - 18.0)}
  defp screen_to_logical({sx, sy}, :landscape_inverted), do: {1280.0 - sy, max(0.0, sx - 18.0)}

  defp find_hitbox(hitboxes, lx, ly) do
    Enum.find_value(hitboxes, fn {action, x, y, w, h} ->
      if lx >= x and lx <= x + w and ly >= y and ly <= y + h, do: action, else: nil
    end)
  end

  # --- Rendering (Untis Mobile 6.7.1 Specification) ---

  defp palette(:light) do
    %{
      top_bar_bg: {255, 255, 255},
      top_bar_title: {103, 116, 126},
      top_bar_sub: {94, 115, 130},
      header_bg: {220, 223, 229},
      canvas_bg: {243, 245, 247},
      divider: {191, 200, 207},
      text_primary: {16, 23, 29},
      text_secondary: {94, 115, 130},
      untis_orange: {255, 96, 51},
      btn_bg: {243, 245, 247},
      btn_border: {191, 200, 207},
      btn_text: {16, 23, 29},
      regular_bg: {255, 255, 255},
      regular_past_bg: {243, 245, 247},
      regular_border: {220, 223, 229},
      changed_bg: {228, 255, 243},
      changed_border: {0, 146, 109},
      changed_pill: {0, 125, 100},
      cancelled_bg: {255, 243, 243},
      cancelled_border: {223, 0, 71},
      cancelled_pill: {223, 0, 71},
      exam_bg: {255, 247, 217},
      exam_border: {159, 83, 45},
      exam_pill: {197, 125, 0}
    }
  end

  defp palette(:dark) do
    %{
      top_bar_bg: {0, 0, 0},
      top_bar_title: {138, 150, 161},
      top_bar_sub: {191, 200, 207},
      header_bg: {22, 22, 22},
      canvas_bg: {24, 32, 38},
      divider: {94, 115, 130},
      text_primary: {243, 245, 247},
      text_secondary: {191, 200, 207},
      untis_orange: {255, 96, 51},
      btn_bg: {37, 46, 56},
      btn_border: {94, 115, 130},
      btn_text: {243, 245, 247},
      regular_bg: {37, 46, 56},
      regular_past_bg: {24, 32, 38},
      regular_border: {50, 61, 69},
      changed_bg: {21, 46, 40},
      changed_border: {0, 146, 109},
      changed_pill: {0, 146, 109},
      cancelled_bg: {45, 23, 36},
      cancelled_border: {223, 0, 71},
      cancelled_pill: {250, 24, 90},
      exam_bg: {43, 37, 24},
      exam_border: {197, 125, 0},
      exam_pill: {229, 151, 0}
    }
  end

  defp render_scene(scene, state) do
    {w, h} = logical_size(state.orientation)
    pal = palette(state.theme)

    {inner_fn, hitboxes} =
      build_ui({w, h}, state, pal)

    graph =
      Graph.build(font: :berkeley_mono, font_size: 20)
      |> group(
        fn g ->
          g
          |> rect({w, h}, fill: pal.canvas_bg)
          |> inner_fn.()
        end,
        rot_group_opts(state.orientation)
      )

    state = %{state | hitboxes: hitboxes}

    scene
    |> assign(state: state)
    |> push_graph(graph)
  end

  defp build_ui({w, h}, state, pal) do
    {top_fn, top_hb} = build_top_bar(w, state, pal)

    {body_fn, body_hb} =
      case state.view do
        :timetable -> build_timetable_view({w, h}, state, pal)
        :wifi -> build_wifi_view({w, h}, state)
        :untis -> build_untis_view({w, h}, state)
      end

    {kb_fn, kb_hb} =
      if state.active_field != nil do
        build_keyboard({w, h}, state)
      else
        {fn g -> g end, []}
      end

    hitboxes = kb_hb ++ top_hb ++ body_hb

    ui_fn = fn g ->
      g
      |> top_fn.()
      |> body_fn.()
      |> kb_fn.()
    end

    {ui_fn, hitboxes}
  end

  defp build_top_bar(w, state, pal) do
    wifi_ok? = state.wifi.connection in [:internet, :lan]
    wifi_label = if wifi_ok?, do: "Wi-Fi", else: "Wi-Fi!"
    untis_label = if Schedule.logged_in?(), do: "Untis", else: "Login"
    auto_label = if state.auto_rotate?, do: "AUTO", else: "LOCK"
    theme_label = if state.theme == :light, do: "Dark", else: "Hell"

    target_title =
      case Enum.at(state.targets, state.selected_target_idx) do
        {name, _} -> name
        _ -> if state.untis_school != "", do: state.untis_school, else: "Stundenplan"
      end

    buttons =
      if w >= 1000 do
        [
          {:week_prev, w - 602, 9, 44, 38, "◀", :neutral},
          {:week_today, w - 554, 9, 68, 38, "Heute", :orange},
          {:week_next, w - 482, 9, 44, 38, "▶", :neutral},
          {:untis_refresh, w - 434, 9, 54, 38, "Sync", :neutral},
          {{:nav, :wifi}, w - 374, 9, 76, 38, wifi_label, if(wifi_ok?, do: :green, else: :amber)},
          {{:nav, :untis}, w - 292, 9, 76, 38, untis_label, if(Schedule.logged_in?(), do: :neutral, else: :orange)},
          {:toggle_theme, w - 210, 9, 54, 38, theme_label, :neutral},
          {:rotate_cw, w - 150, 9, 46, 38, "90°", :neutral},
          {:toggle_auto, w - 98, 9, 56, 38, auto_label, if(state.auto_rotate?, do: :green, else: :neutral)},
          {:bright_down, w - 38, 9, 16, 38, "-", :neutral},
          {:bright_up, w - 19, 9, 16, 38, "+", :neutral}
        ]
      else
        [
          {:week_prev, w - 548, 9, 36, 38, "◀", :neutral},
          {:week_today, w - 508, 9, 58, 38, "Heute", :orange},
          {:week_next, w - 446, 9, 36, 38, "▶", :neutral},
          {:untis_refresh, w - 406, 9, 50, 38, "Sync", :neutral},
          {{:nav, :wifi}, w - 352, 9, 68, 38, wifi_label, if(wifi_ok?, do: :green, else: :amber)},
          {{:nav, :untis}, w - 280, 9, 68, 38, untis_label, if(Schedule.logged_in?(), do: :neutral, else: :orange)},
          {:toggle_theme, w - 208, 9, 50, 38, theme_label, :neutral},
          {:rotate_cw, w - 154, 9, 44, 38, "90°", :neutral},
          {:toggle_auto, w - 106, 9, 54, 38, auto_label, if(state.auto_rotate?, do: :green, else: :neutral)},
          {:bright_down, w - 48, 9, 20, 38, "-", :neutral},
          {:bright_up, w - 24, 9, 20, 38, "+", :neutral}
        ]
      end

    title_hb = [{:cycle_target, 8, 4, 240, 48}]
    hitboxes = title_hb ++ Enum.map(buttons, fn {act, x, y, bw, bh, _lbl, _st} -> {act, x, y, bw, bh} end)

    draw_fn = fn g ->
      g =
        g
        |> rect({w, 56}, fill: pal.top_bar_bg)
        |> line({{0, 56}, {w, 56}}, stroke: {1, pal.divider})
        |> text(truncate(target_title, if(w >= 1000, do: 28, else: 14)),
          font: :berkeley_mono_bold,
          font_size: 19,
          fill: pal.top_bar_title,
          translate: {16, 26}
        )
        |> text(
          if(length(state.targets) > 1,
            do: "Tippen zum Wechseln (#{state.selected_target_idx + 1}/#{length(state.targets)})",
            else: truncate(state.untis_school, 24)
          ),
          font_size: 12,
          fill: pal.top_bar_sub,
          translate: {16, 44}
        )

      Enum.reduce(buttons, g, fn {_act, x, y, bw, bh, lbl, style}, acc ->
        draw_bar_chip(acc, x, y, bw, bh, lbl, style, pal)
      end)
    end

    {draw_fn, hitboxes}
  end

  defp draw_bar_chip(g, x, y, w, h, label, style, pal) do
    {bg, border, fg} =
      case style do
        :orange -> {pal.untis_orange, pal.untis_orange, {255, 255, 255}}
        :green -> {{0, 146, 109}, {0, 146, 109}, {255, 255, 255}}
        :amber -> {{197, 125, 0}, {197, 125, 0}, {255, 255, 255}}
        _ -> {pal.btn_bg, pal.btn_border, pal.btn_text}
      end

    font_sz = if w <= 22, do: 14, else: 15
    pad_x = max(4, div(w - String.length(label) * div(font_sz, 2), 2) - 2)

    g
    |> rrect({w, h, 6}, fill: bg, stroke: {1, border}, translate: {x, y})
    |> text(label,
      font_size: font_sz,
      fill: fg,
      translate: {x + pad_x, y + div(h, 2) + 5}
    )
  end

  # --- View 1: Untis Mobile 6.7.1 Proportional Week Timetable ---

  defp build_timetable_view({w, h}, state, pal) do
    top_y = 56
    header_h = 52
    footer_h = if state.selected_period != nil, do: 68, else: 32
    body_top = top_y + header_h
    body_h = h - body_top - footer_h
    time_col_w = if w >= 1000, do: 64, else: 56

    case state.grid do
      %{days: days, units: units, day_start_min: day_start_min, day_end_min: day_end_min}
      when days != [] and units != [] ->
        num_days = length(days)
        day_col_w = div(w - time_col_w, max(num_days, 1))
        usable_h = max(body_h - 20, 100)
        span_min = max(day_end_min - day_start_min, 60)

        y_at = fn min_val ->
          clamped = min_val |> max(day_start_min) |> min(day_end_min)
          body_top + 10 + div((clamped - day_start_min) * usable_h, span_min)
        end

        now_local = Schedule.now_local()
        today = NaiveDateTime.to_date(now_local)
        now_min = now_local.hour * 60 + now_local.minute

        period_cards =
          for {day, d_idx} <- Enum.with_index(days),
              item <- Map.get(day, :layout_periods, []) do
            col_w = div(day_col_w, max(item.col_count, 1))
            cx = time_col_w + d_idx * day_col_w + item.col_idx * col_w + 1
            cw = max(col_w - 2, 16)
            y1 = y_at.(item.start_min)
            y2 = y_at.(item.end_min)
            cy = y1 + 1
            ch = max(y2 - y1 - 2, 18)
            past? = NaiveDateTime.compare(item.period.end, now_local) == :lt
            {{:select_period, item.period}, cx, cy, cw, ch, item, past?}
          end

        hitboxes =
          Enum.map(period_cards, fn {act, x, y, bw, bh, _item, _past?} -> {act, x, y, bw, bh} end)

        first_date = hd(days).date
        kw_str = "KW #{TimetableGrid.iso_week_number(first_date)}"
        month_str = TimetableGrid.month_short_de(first_date)

        draw_fn = fn g ->
          # 1. Sticky Weekday Header Row & Left Time Column backgrounds
          g =
            g
            |> rect({w, header_h}, fill: pal.header_bg, translate: {0, top_y})
            |> rect({time_col_w, body_h}, fill: pal.header_bg, translate: {0, body_top})
            |> rect({w - time_col_w, body_h}, fill: pal.canvas_bg, translate: {time_col_w, body_top})
            # Top-left corner cell: "KW <week>" (13sp) + "Apr." (17sp Bold)
            |> text(kw_str,
              font_size: 13,
              fill: pal.text_secondary,
              translate: {8, top_y + 19}
            )
            |> text(month_str,
              font: :berkeley_mono_bold,
              font_size: 17,
              fill: pal.text_secondary,
              translate: {8, top_y + 41}
            )

          # 2. Weekday Headers + Vertical Column Grid Dividers
          g =
            days
            |> Enum.with_index()
            |> Enum.reduce(g, fn {day, d_idx}, acc ->
              dx = time_col_w + d_idx * day_col_w
              is_today? = Date.compare(day.date, today) == :eq
              wd_str = TimetableGrid.weekday_short_de(day.date)
              day_num_str = Integer.to_string(day.date.day)

              wd_col = if is_today?, do: pal.untis_orange, else: pal.text_secondary
              num_col = if is_today?, do: pal.untis_orange, else: pal.text_primary
              center_x = dx + div(day_col_w, 2)

              acc
              |> line({{dx, top_y}, {dx, body_top + body_h}}, stroke: {1, pal.divider})
              |> text(wd_str,
                font_size: 13,
                fill: wd_col,
                translate: {center_x - 10, top_y + 19}
              )
              |> text(day_num_str,
                font: :berkeley_mono_bold,
                font_size: 18,
                fill: num_col,
                translate: {center_x - if(day.date.day >= 10, do: 10, else: 5), top_y + 41}
              )
            end)

          # Sticky weekday header bottom divider (1dp)
          g = line(g, {{0, body_top}, {w, body_top}}, stroke: {1, pal.divider})

          # 3. Time-Grid Units (Horizontal Lines, Break Bands & Left Time Labels)
          g =
            Enum.reduce(units, g, fn u, acc ->
              y1 = y_at.(u.start_min)
              y2 = y_at.(u.end_min)
              y_mid = div(y1 + y2, 2)
              t_start = TimetableGrid.format_time(u.start)
              t_end = TimetableGrid.format_time(u.end)

              acc =
                acc
                |> line({{0, y1}, {w, y1}}, stroke: {1, pal.divider})
                |> text(t_start,
                  font_size: 12,
                  fill: pal.text_secondary,
                  translate: {10, y1 + 13}
                )
                |> text(to_string(u.label || ""),
                  font_size: 15,
                  fill: pal.text_secondary,
                  translate: {22, y_mid + 5}
                )

              if u.show_end? do
                acc
                |> line({{0, y2}, {w, y2}}, stroke: {1, pal.divider})
                |> text(t_end,
                  font_size: 12,
                  fill: pal.text_secondary,
                  translate: {10, y2 - 4}
                )
              else
                acc
              end
            end)

          # 4. Holiday Overlays
          g =
            days
            |> Enum.with_index()
            |> Enum.reduce(g, fn {day, d_idx}, acc ->
              if day.holiday do
                dx = time_col_w + d_idx * day_col_w + 2
                hy = body_top + 10
                hh = usable_h

                acc
                |> rrect({day_col_w - 4, hh, 4},
                  fill: blend_past(pal.header_bg, pal.canvas_bg, false),
                  stroke: {1, pal.divider},
                  translate: {dx, hy}
                )
                |> text(truncate(day.holiday.long_name || day.holiday.name || "Ferien", 16),
                  font_size: 15,
                  fill: pal.text_secondary,
                  translate: {dx + 8, hy + 28}
                )
              else
                acc
              end
            end)

          # 5. Period Cards (PeriodCell)
          g =
            Enum.reduce(period_cards, g, fn {_act, cx, cy, cw, ch, item, past?}, acc ->
              selected? =
                state.selected_period != nil and state.selected_period.id == item.period.id

              draw_untis_period_cell(acc, cx, cy, cw, ch, item, past?, selected?, pal)
            end)

          # 6. Current-Time Indicator (TimeLine in #FF6033)
          g =
            if now_min >= day_start_min and now_min <= day_end_min do
              y_now = y_at.(now_min)
              today_idx = Enum.find_index(days, &(Date.compare(&1.date, today) == :eq))

              acc =
                line(g, {{time_col_w, y_now}, {w, y_now}}, stroke: {1, pal.untis_orange})

              if today_idx != nil do
                tdx = time_col_w + today_idx * day_col_w

                acc
                |> rect({day_col_w, 3}, fill: pal.untis_orange, translate: {tdx, y_now - 1})
                |> circle(4, fill: pal.untis_orange, translate: {tdx + 4, y_now})
              else
                acc
              end
            else
              g
            end

          # 7. Bottom Inspector / Status Bar
          draw_footer_inspector(g, {w, h}, footer_h, state, pal)
        end

        {draw_fn, hitboxes}

      _ ->
        btns = [
          {{:nav, :wifi}, div(w, 2) - 260, div(h, 2) + 10, 240, 56, "1. Wi-Fi einrichten", @green},
          {{:nav, :untis}, div(w, 2) + 20, div(h, 2) + 10, 240, 56, "2. WebUntis Login", pal.untis_orange}
        ]

        hitboxes = Enum.map(btns, fn {a, x, y, bw, bh, _, _} -> {a, x, y, bw, bh} end)
        {ax, ay, az} = state.accel_raw

        draw_fn = fn g ->
          g =
            g
            |> rrect({w - 80, 280, 8},
              fill: pal.regular_bg,
              stroke: {1, pal.divider},
              translate: {40, div(h, 2) - 160}
            )
            |> text("Untis Mobile Stundenplan (PF1007L)",
              font_size: 26,
              fill: pal.text_primary,
              translate: {72, div(h, 2) - 105}
            )
            |> text(state.untis_status,
              font_size: 19,
              fill: pal.untis_orange,
              translate: {72, div(h, 2) - 62}
            )
            |> text(
              "Wi-Fi: #{state.wifi.connection} (#{state.wifi.ssid || "none"}, IP: #{state.wifi.ip || "-"})  |  #{state.orientation} (X=#{ax} Y=#{ay} Z=#{az})",
              font_size: 15,
              fill: pal.text_secondary,
              translate: {72, div(h, 2) - 24}
            )

          Enum.reduce(btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
            draw_button(acc, x, y, bw, bh, lbl, col, 20)
          end)
        end

        {draw_fn, hitboxes}
    end
  end

  defp draw_untis_period_cell(g, x, y, w, h, item, past?, selected?, pal) do
    period = item.period
    status = item.status
    cancelled? = status == :cancelled

    {raw_bg, raw_border, border_w, pill_col} =
      case status do
        :cancelled ->
          {pal.cancelled_bg, pal.cancelled_border, 2, pal.cancelled_pill}

        :exam ->
          {pal.exam_bg, pal.exam_border, 2, pal.exam_pill}

        :changed ->
          {pal.changed_bg, pal.changed_border, 2, pal.changed_pill}

        :regular ->
          bg = if past?, do: pal.regular_past_bg, else: pal.regular_bg
          {bg, pal.regular_border, 1, pal.changed_pill}
      end

    bg = if status == :regular, do: raw_bg, else: blend_past(raw_bg, pal.canvas_bg, past?)
    border_col = if selected?, do: pal.untis_orange, else: blend_past(raw_border, pal.divider, past?)
    stroke_w = if selected?, do: 2, else: border_w
    bar_col = blend_past(item.subject_color, pal.canvas_bg, past?)
    fg_col = blend_past(pal.text_primary, pal.canvas_bg, past?)
    sub_fg_col = blend_past(pal.text_secondary, pal.canvas_bg, past?)

    # 1. Outer rounded card (radius = 4dp) + Left Subject Color Bar (width = 4dp, radius = 2dp)
    g =
      g
      |> rrect({w, h, 4}, fill: bg, stroke: {stroke_w, border_col}, translate: {x, y})
      |> rrect({4, max(h - 4, 4), 2}, fill: bar_col, translate: {x + 2, y + 2})

    # 2. Resource Rows (Subject Bold, Teacher, Room, Info) starting at x + 10
    text_x = x + 10
    avail_w = max(w - 14, 10)
    font_sz = cond do
      h >= 68 and w >= 90 -> 14
      h >= 46 -> 13
      true -> 11
    end
    line_step = font_sz + 4

    # Row 1: Subject (Bold)
    g =
      draw_resource_row(
        g,
        period.subjects,
        period.lesson_text,
        text_x,
        y + font_sz + 2,
        avail_w,
        font_sz,
        fg_col,
        pill_col,
        cancelled?,
        :berkeley_mono_bold
      )

    # Row 2: Teacher (if height fits at least 2 rows)
    g =
      if h >= font_sz + line_step + 4 and period.teachers != [] do
        draw_resource_row(
          g,
          period.teachers,
          nil,
          text_x,
          y + font_sz + 2 + line_step,
          avail_w,
          max(font_sz - 1, 11),
          sub_fg_col,
          pill_col,
          cancelled?
        )
      else
        g
      end

    # Row 3: Room (if height fits at least 3 rows)
    g =
      if h >= font_sz + line_step * 2 + 4 and period.rooms != [] do
        draw_resource_row(
          g,
          period.rooms,
          nil,
          text_x,
          y + font_sz + 2 + line_step * 2,
          avail_w,
          max(font_sz - 1, 11),
          sub_fg_col,
          pill_col,
          cancelled?
        )
      else
        g
      end

    # Row 4: Info / Substitution / Exam text (if height fits 4 rows)
    info_str =
      cond do
        period.exam != nil and is_binary(period.exam.name) -> period.exam.name
        is_binary(period.substitution_text) -> period.substitution_text
        is_binary(period.info) -> period.info
        is_binary(period.lesson_text) -> period.lesson_text
        true -> nil
      end

    g =
      if h >= font_sz + line_step * 3 + 6 and is_binary(info_str) and info_str != "" do
        max_chars = max(div(avail_w - 16, 7), 4)

        text(g, truncate(info_str, max_chars),
          font_size: max(font_sz - 2, 10),
          fill: sub_fg_col,
          translate: {text_x, y + font_sz + 2 + line_step * 3}
        )
      else
        g
      end

    # 3. Bottom-Right Notification Icon Badges (14x14dp, radius = 3dp)
    if h >= 32 and w >= 42 do
      draw_period_badges(g, x + w - 3, y + h - 3, period, pill_col, sub_fg_col)
    else
      g
    end
  end

  defp draw_resource_row(g, elements, fallback_str, x, baseline_y, avail_w, font_sz, fg_col, pill_col, period_cancelled?, font \\ :berkeley_mono) do
    max_chars = max(div(avail_w, max(div(font_sz * 3, 5), 6)), 3)

    case elements do
      [el | _] ->
        cur_name = el.name || el.long_name || ""
        orig_name = if el.original, do: el.original.name || el.original.long_name, else: nil

        cond do
          period_cancelled? or el.status == :removed ->
            label = truncate(if(cur_name != "", do: cur_name, else: orig_name || "-"), max_chars)
            strike_w = min(avail_w - 4, max(String.length(label) * div(font_sz * 3, 5), 14))
            strike_y = baseline_y - div(font_sz, 3)

            g
            |> text(label, font: font, font_size: font_sz, fill: fg_col, translate: {x, baseline_y})
            |> line({{x, strike_y}, {x + strike_w, strike_y}}, stroke: {1, pill_col})

          el.status == :changed ->
            label = truncate(cur_name, max(max_chars - 4, 3))
            pill_w = min(avail_w - 2, max(String.length(label) * div(font_sz * 3, 5) + 8, 20))
            pill_h = font_sz + 3
            pill_y = baseline_y - font_sz

            g =
              g
              |> rrect({pill_w, pill_h, 3}, fill: pill_col, translate: {x, pill_y})
              |> text(label,
                font: font,
                font_size: font_sz,
                fill: {255, 255, 255},
                translate: {x + 4, baseline_y - 1}
              )

            if is_binary(orig_name) and orig_name != "" and avail_w - pill_w >= 26 do
              ox = x + pill_w + 4
              olabel = truncate(orig_name, max(div(avail_w - pill_w - 6, 7), 2))
              ow = min(avail_w - pill_w - 6, max(String.length(olabel) * div(font_sz * 3, 5), 12))
              strike_y = baseline_y - div(font_sz, 3)

              g
              |> text(olabel, font: font, font_size: max(font_sz - 1, 10), fill: fg_col, translate: {ox, baseline_y - 1})
              |> line({{ox, strike_y}, {ox + ow, strike_y}}, stroke: {1, fg_col})
            else
              g
            end

          true ->
            label =
              elements
              |> Enum.map(&(&1.name || &1.long_name || ""))
              |> Enum.reject(&(&1 == ""))
              |> Enum.join(", ")
              |> truncate(max_chars)

            text(g, label, font: font, font_size: font_sz, fill: fg_col, translate: {x, baseline_y})
        end

      [] when is_binary(fallback_str) and fallback_str != "" ->
        text(g, truncate(fallback_str, max_chars), font: font, font_size: font_sz, fill: fg_col, translate: {x, baseline_y})

      _ ->
        g
    end
  end

  defp draw_period_badges(g, right_x, bottom_y, period, pill_col, muted_col) do
    badges =
      []
      |> then(fn acc ->
        if period.online?, do: [{"V", muted_col} | acc], else: acc
      end)
      |> then(fn acc ->
        if period.substitution_text != nil or period.info != nil or period.lesson_text != nil,
          do: [{"i", pill_col} | acc],
          else: acc
      end)
      |> then(fn acc ->
        if period.homework != [], do: [{"H", {0, 125, 100}} | acc], else: acc
      end)
      |> then(fn acc ->
        if Untis.Period.exam?(period), do: [{"E", {197, 125, 0}} | acc], else: acc
      end)

    badges
    |> Enum.with_index()
    |> Enum.reduce(g, fn {{sym, col}, idx}, acc ->
      bx = right_x - (idx + 1) * 16 + 2
      by = bottom_y - 14

      acc
      |> rrect({14, 14, 3}, fill: col, translate: {bx, by})
      |> text(sym, font_size: 10, fill: {255, 255, 255}, translate: {bx + 4, by + 11})
    end)
  end

  defp blend_past({r, g, b}, {br, bg, bb}, true) do
    {div(r + br, 2), div(g + bg, 2), div(b + bb, 2)}
  end

  defp blend_past(color, _bg, false), do: color

  defp draw_footer_inspector(g, {w, h}, footer_h, state, pal) do
    fy = h - footer_h
    {ax, ay, az} = state.accel_raw

    case state.selected_period do
      nil ->
        info =
          "#{state.untis_status}  •  Wi-Fi: #{state.wifi.ssid || state.wifi.connection} (#{state.wifi.ip || "-"})  •  #{state.orientation} (#{ax},#{ay},#{az})"

        g
        |> rect({w, footer_h}, fill: pal.top_bar_bg, translate: {0, fy})
        |> line({{0, fy}, {w, fy}}, stroke: {1, pal.divider})
        |> text(truncate(info, div(w, 7)),
          font_size: 13,
          fill: pal.text_secondary,
          translate: {12, fy + 21}
        )

      p ->
        subjs = Enum.map_join(p.subjects, ", ", &(&1.long_name || &1.name || ""))
        teachers =
          Enum.map_join(p.teachers, ", ", fn t ->
            base = t.long_name || t.name || ""
            if t.original, do: "#{base} (#{t.original.name || t.original.long_name})", else: base
          end)

        rooms =
          Enum.map_join(p.rooms, ", ", fn r ->
            base = r.long_name || r.name || ""
            if r.original, do: "#{base} (#{r.original.name || r.original.long_name})", else: base
          end)

        t_str = "#{TimetableGrid.format_time(p.start)}–#{TimetableGrid.format_time(p.end)}"

        notes =
          [
            if(p.exam, do: "Prüfung: #{p.exam.name} #{p.exam.text}", else: nil),
            p.substitution_text,
            p.info,
            p.lesson_text
          ]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" • ")

        hw =
          case p.homework do
            [first | _] -> " | HA: #{first.text}"
            _ -> ""
          end

        line1 = "#{t_str}  #{subjs}  •  Raum: #{rooms}  •  Lehrkraft: #{teachers}"
        line2 = "#{if notes == "", do: "Regulärer Unterricht", else: notes}#{hw}"

        g
        |> rect({w, footer_h}, fill: pal.top_bar_bg, translate: {0, fy})
        |> line({{0, fy}, {w, fy}}, stroke: {2, pal.untis_orange})
        |> text(truncate(line1, div(w, 8)),
          font_size: 16,
          fill: pal.text_primary,
          translate: {14, fy + 26}
        )
        |> text(truncate(line2, div(w, 7)),
          font_size: 14,
          fill: pal.text_secondary,
          translate: {14, fy + 50}
        )
    end
  end

  # --- View 2: On-Screen Wi-Fi Setup ---

  defp build_wifi_view({w, h}, state) do
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
      {{:nav, :timetable}, 24, 68, 170, 42, "← Stundenplan", @panel_alt},
      {:wifi_scan, 24, 132, 200, 48, "Scan Networks", @accent},
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

      msg = state.wifi_message || "Tap a network on the left or enter an SSID on the right."
      msg_lines = wrap_lines(msg, max(28, div(rw, 11)))

      g =
        g
        |> rect({w, h - 56}, fill: @bg, translate: {0, 56})
        |> text("Wi-Fi Network Configuration (AIC8800DC)",
          font_size: 24,
          fill: @text_main,
          translate: {210, 98}
        )
        |> text(status_str,
          font_size: 18,
          fill: @accent,
          translate: {245, 164}
        )

      g =
        msg_lines
        |> Enum.take(3)
        |> Enum.with_index()
        |> Enum.reduce(g, fn {line, idx}, acc ->
          text(acc, line,
            font_size: 17,
            fill: @text_muted,
            translate: {rx, 376 + idx * 24}
          )
        end)

      g =
        Enum.reduce(all_btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
          draw_button(acc, x, y, bw, bh, lbl, col, 19)
        end)

      draw_touch_dot(g, state.touch_pos)
    end

    {draw_fn, hitboxes}
  end

  # --- View 3: On-Screen WebUntis Setup ---

  defp build_untis_view({w, h}, state) do
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
      {{:nav, :timetable}, 24, 68, 170, 42, "← Stundenplan", @panel_alt},
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
      status_lines = wrap_lines(state.untis_status || "", max(28, div(lw, 11)))

      g =
        g
        |> rect({w, h - 56}, fill: @bg, translate: {0, 56})
        |> text("WebUntis Account & School Setup",
          font_size: 24,
          fill: @text_main,
          translate: {210, 98}
        )

      g =
        status_lines
        |> Enum.take(2)
        |> Enum.with_index()
        |> Enum.reduce(g, fn {line, idx}, acc ->
          text(acc, line,
            font_size: 16,
            fill: @accent,
            translate: {24, 210 + idx * 22}
          )
        end)

      g =
        Enum.reduce(all_btns, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
          draw_button(acc, x, y, bw, bh, lbl, col, 18)
        end)

      draw_touch_dot(g, state.touch_pos)
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

    kb_h = 320
    kb_y = h - kb_h
    row_h = 48
    pad = 5

    key_specs =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row_keys, r_idx} ->
        ry = kb_y + 44 + r_idx * (row_h + pad)
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

    hitboxes =
      Enum.map(key_specs, fn {a, x, y, bw, bh, _, _} ->
        {a, x - 2, y - 2, bw + 4, bh + 4}
      end)

    cur_val = get_active_field(state)

    draw_fn = fn g ->
      g =
        g
        |> rect({w, kb_h}, fill: {8, 12, 24}, translate: {0, kb_y})
        |> line({{0, kb_y}, {w, kb_y}}, stroke: {2, @accent})
        |> text("Editing #{state.active_field}:  #{cur_val}_",
          font_size: 22,
          fill: @accent,
          translate: {20, kb_y + 30}
        )

      g =
        Enum.reduce(key_specs, g, fn {_a, x, y, bw, bh, lbl, col}, acc ->
          draw_key_button(acc, x, y, bw, bh, lbl, col, 20)
        end)

      draw_touch_dot(g, state.touch_pos)
    end

    {draw_fn, hitboxes}
  end

  defp draw_button(g, x, y, w, h, label, bg_color, font_sz) do
    g
    |> rrect({w, h, 8}, fill: bg_color, stroke: {1, @border}, translate: {x, y})
    |> text(label,
      font_size: font_sz,
      fill: @text_main,
      translate: {x + 12, y + div(h, 2) + div(font_sz, 3)}
    )
  end

  defp draw_key_button(g, x, y, w, h, label, bg_color, font_sz) do
    g
    |> rrect({w, h, 8}, fill: bg_color, stroke: {1, @border}, translate: {x, y})
    |> text(label,
      font: :berkeley_mono_bold,
      font_size: font_sz,
      fill: @text_main,
      text_align: :center,
      translate: {x + div(w, 2), y + div(h, 2) + div(font_sz, 3)}
    )
  end

  defp draw_touch_dot(g, {tx, ty}) do
    circle(g, 5, fill: @accent, stroke: {1, @text_main}, translate: {tx, ty})
  end

  defp wrap_lines(str, max_chars) when is_binary(str) and max_chars > 5 do
    str
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
      cond do
        cur == "" ->
          {lines, word}

        String.length(cur) + 1 + String.length(word) <= max_chars ->
          {lines, cur <> " " <> word}

        true ->
          {[cur | lines], word}
      end
    end)
    |> then(fn
      {lines, ""} -> Enum.reverse(lines)
      {lines, last} -> Enum.reverse([last | lines])
    end)
  end

  defp wrap_lines(str, _), do: [to_string(str || "")]

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
