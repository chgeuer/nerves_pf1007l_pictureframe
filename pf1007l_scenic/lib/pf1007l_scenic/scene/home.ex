defmodule Pf1007lScenic.Scene.Home do
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives
  import Scenic.Components

  @width 800
  @height 1280
  @max_trail 8

  @themes [
    %{name: "Midnight Slate", bg: {15, 23, 42}, card: {30, 41, 59}, accent: {56, 189, 248}},
    %{name: "Emerald Studio", bg: {6, 36, 29}, card: {17, 62, 50}, accent: {52, 211, 153}},
    %{name: "Warm Ember", bg: {39, 18, 14}, card: {68, 32, 24}, accent: {251, 146, 60}}
  ]

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    :ok = request_input(scene, [:cursor_button, :cursor_pos, :key])

    state = %{
      touch_x: 400,
      touch_y: 640,
      touching: false,
      tap_count: 0,
      theme_idx: 0,
      brightness: read_brightness(),
      trail: []
    }

    graph =
      build_base_graph(state)
      |> update_dynamic_primitives(state)

    scene =
      scene
      |> assign(state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_input({:cursor_button, {:btn_left, 1, _mods, {x, y}}}, _id, scene) do
    rx = round(x)
    ry = round(y)
    trail = Enum.take([{rx, ry} | scene.assigns.trail], @max_trail)

    scene =
      scene
      |> assign(
        touch_x: rx,
        touch_y: ry,
        touching: true,
        tap_count: scene.assigns.tap_count + 1,
        trail: trail
      )
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_input({:cursor_button, {:btn_left, 0, _mods, {x, y}}}, _id, scene) do
    scene =
      scene
      |> assign(touch_x: round(x), touch_y: round(y), touching: false)
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_input({:cursor_pos, {x, y}}, _id, scene) do
    {x, y} = drain_cursor_pos({x, y})
    rx = round(x)
    ry = round(y)

    trail =
      if scene.assigns.touching do
        Enum.take([{rx, ry} | scene.assigns.trail], @max_trail)
      else
        scene.assigns.trail
      end

    scene =
      scene
      |> assign(touch_x: rx, touch_y: ry, trail: trail)
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_input(_event, _id, scene), do: {:noreply, scene}

  @impl Scenic.Scene
  def handle_event({:click, :btn_theme}, _from, scene) do
    next_idx = rem(scene.assigns.theme_idx + 1, length(@themes))
    scene = assign(scene, theme_idx: next_idx)

    graph =
      build_base_graph(scene.assigns)
      |> update_dynamic_primitives(scene.assigns)

    {:noreply, scene |> assign(graph: graph) |> push_graph(graph)}
  end

  def handle_event({:click, :btn_clear_trail}, _from, scene) do
    scene =
      scene
      |> assign(trail: [], tap_count: 0)
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_event({:click, :btn_bright_up}, _from, scene) do
    new_b = min(10, scene.assigns.brightness + 2)
    write_brightness(new_b)

    scene =
      scene
      |> assign(brightness: new_b)
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_event({:click, :btn_bright_down}, _from, scene) do
    new_b = max(1, scene.assigns.brightness - 2)
    write_brightness(new_b)

    scene =
      scene
      |> assign(brightness: new_b)
      |> push_dynamic()

    {:noreply, scene}
  end

  def handle_event(_event, _from, scene), do: {:noreply, scene}

  defp drain_cursor_pos(latest) do
    receive do
      {:_input, {:cursor_pos, pos}, _context, _id} ->
        drain_cursor_pos(pos)
    after
      0 -> latest
    end
  end

  defp push_dynamic(scene) do
    graph = update_dynamic_primitives(scene.assigns.graph, scene.assigns)

    scene
    |> assign(graph: graph)
    |> push_graph(graph)
  end

  defp build_base_graph(state) do
    theme = Enum.at(@themes, state.theme_idx)

    graph =
      Graph.build(font: :roboto, font_size: 28)
      |> rect({@width, @height}, fill: theme.bg)
      # Header card
      |> rrect({720, 170, 16}, fill: theme.card, translate: {40, 40})
      |> text("Nerves + Scenic on PF1007L",
        font_size: 42,
        fill: :white,
        translate: {80, 105}
      )
      |> text("Allwinner A33 • 800x1280 MIPI-DSI • Silead GSL1680 Touch",
        font_size: 22,
        fill: theme.accent,
        translate: {80, 155}
      )
      # Touch telemetry card
      |> rrect({720, 220, 16}, fill: theme.card, translate: {40, 240})
      |> text("Touch Status: IDLE",
        id: :status_text,
        font_size: 32,
        fill: theme.accent,
        translate: {80, 305}
      )
      |> text("Coordinates: X = 400 px, Y = 640 px",
        id: :coords_text,
        font_size: 28,
        fill: :white,
        translate: {80, 360}
      )
      |> text("",
        id: :info_text,
        font_size: 24,
        fill: {203, 213, 225},
        translate: {80, 415}
      )
      # Interactive touch canvas area
      |> rrect({720, 520, 16},
        fill: {10, 15, 28},
        stroke: {2, theme.accent},
        translate: {40, 490}
      )
      |> text("Touch or drag anywhere on the screen",
        font_size: 24,
        fill: {148, 163, 184},
        translate: {200, 540}
      )
      # Interactive Scenic buttons
      |> button("Switch Theme",
        id: :btn_theme,
        width: 220,
        height: 70,
        theme: :primary,
        translate: {40, 1050}
      )
      |> button("Clear Trail",
        id: :btn_clear_trail,
        width: 220,
        height: 70,
        theme: :secondary,
        translate: {290, 1050}
      )
      |> button("Bright -",
        id: :btn_bright_down,
        width: 105,
        height: 70,
        theme: :warning,
        translate: {540, 1050}
      )
      |> button("Bright +",
        id: :btn_bright_up,
        width: 105,
        height: 70,
        theme: :success,
        translate: {655, 1050}
      )

    # Pre-allocate trail dots
    graph =
      Enum.reduce(0..(@max_trail - 1), graph, fn idx, g ->
        trail_id = :"trail_#{idx}"
        radius = max(4, 18 - idx * 2)

        circle(g, radius,
          id: trail_id,
          fill: theme.accent,
          translate: {400, 640},
          hidden: true
        )
      end)

    # Active touch reticle
    graph
    |> circle(34,
      id: :reticle_circle,
      stroke: {3, theme.accent},
      translate: {400, 640}
    )
    |> line({{-45, 0}, {45, 0}},
      id: :reticle_h,
      stroke: {2, theme.accent},
      translate: {400, 640}
    )
    |> line({{0, -45}, {0, 45}},
      id: :reticle_v,
      stroke: {2, theme.accent},
      translate: {400, 640}
    )
  end

  defp update_dynamic_primitives(graph, state) do
    %{
      touch_x: tx,
      touch_y: ty,
      touching: touching,
      tap_count: taps,
      theme_idx: theme_idx,
      brightness: brightness,
      trail: trail
    } = state

    theme = Enum.at(@themes, theme_idx)
    status_label = if touching, do: "TOUCHING", else: "IDLE"
    reticle_color = if touching, do: {244, 63, 94}, else: theme.accent
    info_str = "Total Taps: #{taps}   |   Theme: #{theme.name}   |   Backlight: #{brightness}/10"

    graph =
      graph
      |> Graph.modify(:status_text, &text(&1, "Touch Status: #{status_label}", fill: reticle_color))
      |> Graph.modify(:coords_text, &text(&1, "Coordinates: X = #{tx} px, Y = #{ty} px"))
      |> Graph.modify(:info_text, &text(&1, info_str))
      |> Graph.modify(:reticle_circle, &circle(&1, 34, stroke: {3, reticle_color}, translate: {tx, ty}))
      |> Graph.modify(:reticle_h, &line(&1, {{-45, 0}, {45, 0}}, stroke: {2, reticle_color}, translate: {tx, ty}))
      |> Graph.modify(:reticle_v, &line(&1, {{0, -45}, {0, 45}}, stroke: {2, reticle_color}, translate: {tx, ty}))

    Enum.reduce(0..(@max_trail - 1), graph, fn idx, g ->
      trail_id = :"trail_#{idx}"
      radius = max(4, 18 - idx * 2)

      case Enum.at(trail, idx) do
        {px, py} ->
          Graph.modify(g, trail_id, &circle(&1, radius, translate: {px, py}, hidden: false))

        nil ->
          Graph.modify(g, trail_id, &circle(&1, radius, hidden: true))
      end
    end)
  end

  defp read_brightness do
    case File.read("/sys/class/backlight/backlight/brightness") do
      {:ok, val} ->
        val |> String.trim() |> String.to_integer()

      _ ->
        8
    end
  end

  defp write_brightness(level) do
    _ = File.write("/sys/class/backlight/backlight/brightness", "#{level}\n")
    :ok
  end
end
