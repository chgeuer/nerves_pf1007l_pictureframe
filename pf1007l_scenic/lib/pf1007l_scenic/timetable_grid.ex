defmodule Pf1007lScenic.TimetableGrid do
  @moduledoc """
  Lays out a week's WebUntis timetable following the Untis Mobile 6.7.1
  proportional time-grid and parallel column-packing specification.
  """

  alias Untis.{MasterData, Period, Timetable}

  @fallback_subject_colors [
    {52, 152, 219},
    {155, 89, 182},
    {46, 204, 113},
    {230, 126, 34},
    {26, 188, 156},
    {241, 196, 15},
    {231, 76, 60},
    {52, 73, 94}
  ]

  def build(%Timetable{} = timetable) do
    days =
      timetable
      |> Timetable.days()
      |> Enum.filter(&(Date.day_of_week(&1.date) <= 5 or &1.periods != []))

    all_units = collect_units(timetable, days)
    active_units = trim_units(all_units, days)

    {day_start_min, day_end_min} = time_bounds(active_units, days)

    days_with_layout =
      Enum.map(days, fn day ->
        layout = pack_day_periods(day.periods, timetable.master_data)
        Map.put(day, :layout_periods, layout)
      end)

    rows =
      for slot <- slots(timetable, days) do
        Map.put(slot, :cells, Enum.map(days, &in_slot(&1.periods, slot)))
      end

    %{
      days: days_with_layout,
      units: active_units,
      day_start_min: day_start_min,
      day_end_min: day_end_min,
      rows: trim(rows)
    }
  end

  def status(%Period{} = period) do
    cond do
      Period.cancelled?(period) -> :cancelled
      Period.exam?(period) -> :exam
      Period.changed?(period) -> :changed
      true -> :regular
    end
  end

  def subject_color(%Period{subjects: [subj | _]}, %MasterData{subjects: subjects}) do
    case Map.get(subjects, subj.id) do
      %{back_color: hex} when is_binary(hex) ->
        parse_hex_color(hex) || fallback_color(subj.id || subj.name)

      _ ->
        fallback_color(subj.id || subj.name)
    end
  end

  def subject_color(_period, _master_data), do: {103, 116, 126}

  def parse_hex_color("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    with {rv, ""} <- Integer.parse(r, 16),
         {gv, ""} <- Integer.parse(g, 16),
         {bv, ""} <- Integer.parse(b, 16) do
      {rv, gv, bv}
    else
      _ -> nil
    end
  end

  def parse_hex_color(
        "#" <> <<_a::binary-size(2), r::binary-size(2), g::binary-size(2), b::binary-size(2)>>
      ) do
    parse_hex_color("#" <> r <> g <> b)
  end

  def parse_hex_color(_), do: nil

  defp fallback_color(nil), do: {103, 116, 126}

  defp fallback_color(key) do
    idx = :erlang.phash2(key, length(@fallback_subject_colors))
    Enum.at(@fallback_subject_colors, idx)
  end

  def format_time(%Time{hour: h, minute: m}) do
    :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()
  end

  def format_time(%NaiveDateTime{} = ndt), do: format_time(NaiveDateTime.to_time(ndt))
  def format_time(_), do: ""

  def time_to_minutes(%Time{hour: h, minute: m}), do: h * 60 + m
  def time_to_minutes(%NaiveDateTime{hour: h, minute: m}), do: h * 60 + m
  def time_to_minutes(_), do: 0

  def iso_week_number(%Date{} = date) do
    {_year, week} = :calendar.iso_week_number(Date.to_erl(date))
    week
  end

  def weekday_short_de(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> "Mo"
      2 -> "Di"
      3 -> "Mi"
      4 -> "Do"
      5 -> "Fr"
      6 -> "Sa"
      7 -> "So"
    end
  end

  def month_short_de(%Date{month: month}) do
    case month do
      1 -> "Jan."
      2 -> "Feb."
      3 -> "März"
      4 -> "Apr."
      5 -> "Mai"
      6 -> "Juni"
      7 -> "Juli"
      8 -> "Aug."
      9 -> "Sep."
      10 -> "Okt."
      11 -> "Nov."
      12 -> "Dez."
    end
  end

  def day_short(%Date{} = date) do
    "#{weekday_short_de(date)} #{date.day}.#{date.month}."
  end

  defp collect_units(timetable, days) do
    raw =
      Enum.uniq_by(
        for day <- days,
            unit <- Map.get(timetable.master_data.time_grid, Date.day_of_week(day.date), []) do
          %{
            label: unit.label,
            start: unit.start,
            end: unit.end,
            start_min: time_to_minutes(unit.start),
            end_min: time_to_minutes(unit.end)
          }
        end,
        &{&1.start_min, &1.end_min}
      )
      |> Enum.sort_by(&{&1.start_min, &1.end_min})

     annotate_show_end(raw)
  end

  defp annotate_show_end([]), do: []

  defp annotate_show_end(units) do
    units
    |> Enum.with_index()
    |> Enum.map(fn {u, idx} ->
      next_u = Enum.at(units, idx + 1)
      show_end? = is_nil(next_u) or next_u.start_min != u.end_min
      Map.put(u, :show_end?, show_end?)
    end)
  end

  defp trim_units([], _days), do: []

  defp trim_units(units, days) do
    periods = Enum.flat_map(days, & &1.periods)

    if periods == [] do
      units |> Enum.take(6) |> annotate_show_end()
    else
      min_p = periods |> Enum.map(&time_to_minutes(&1.start)) |> Enum.min()
      max_p = periods |> Enum.map(&time_to_minutes(&1.end)) |> Enum.max()

      filtered =
        Enum.filter(units, fn u ->
          u.end_min > min_p - 15 and u.start_min < max_p + 15
        end)

      case filtered do
        [] -> units |> Enum.take(6) |> annotate_show_end()
        list -> annotate_show_end(list)
      end
    end
  end

  defp time_bounds(units, days) do
    periods = Enum.flat_map(days, & &1.periods)

    starts =
      Enum.map(units, & &1.start_min) ++ Enum.map(periods, &time_to_minutes(&1.start))

    ends =
      Enum.map(units, & &1.end_min) ++ Enum.map(periods, &time_to_minutes(&1.end))

    case {starts, ends} do
      {[], []} ->
        {8 * 60, 15 * 60}

      _ ->
        s = Enum.min(starts)
        e = max(Enum.max(ends), s + 60)
        {s, e}
    end
  end

  defp pack_day_periods(periods, master_data) do
    items =
      periods
      |> Enum.map(fn p ->
        s = time_to_minutes(p.start)
        e = max(time_to_minutes(p.end), s + 5)

        %{
          period: p,
          start_min: s,
          end_min: e,
          status: status(p),
          subject_color: subject_color(p, master_data)
        }
      end)
      |> Enum.sort_by(&{&1.start_min, &1.end_min, &1.period.id})
      |> merge_identical_contiguous()

    items
    |> cluster_overlaps()
    |> Enum.flat_map(&assign_cluster_columns/1)
  end

  # Merge contiguous or identical duplicate period entries that represent a double lesson
  # only when they have the exact same lesson_id, subjects, teachers, rooms, and status,
  # and no break between them (or keep them distinct if separated by a break).
  defp merge_identical_contiguous(items), do: items

  defp cluster_overlaps([]), do: []

  defp cluster_overlaps([first | rest]) do
    {clusters, current_cluster, _max_end} =
      Enum.reduce(rest, {[], [first], first.end_min}, fn item, {acc, cluster, cluster_end} ->
        if item.start_min < cluster_end do
          {acc, [item | cluster], max(cluster_end, item.end_min)}
        else
          {[Enum.reverse(cluster) | acc], [item], item.end_min}
        end
      end)

    Enum.reverse([Enum.reverse(current_cluster) | clusters])
  end

  defp assign_cluster_columns(cluster) do
    {placed, col_ends} =
      Enum.reduce(cluster, {[], []}, fn item, {placed_acc, cols} ->
        case Enum.find_index(cols, fn end_min -> end_min <= item.start_min end) do
          nil ->
            col_idx = length(cols)
            {[Map.put(item, :col_idx, col_idx) | placed_acc], cols ++ [item.end_min]}

          col_idx ->
            new_cols = List.replace_at(cols, col_idx, item.end_min)
            {[Map.put(item, :col_idx, col_idx) | placed_acc], new_cols}
        end
      end)

    col_count = max(length(col_ends), 1)

    placed
    |> Enum.reverse()
    |> Enum.map(&Map.put(&1, :col_count, col_count))
  end

  defp slots(timetable, days) do
    units =
      Enum.uniq_by(
        for day <- days,
            unit <- Map.get(timetable.master_data.time_grid, Date.day_of_week(day.date), []) do
          %{label: unit.label, start: unit.start, end: unit.end}
        end,
        &{&1.start, &1.end}
      )

    outside =
      for day <- days,
          period <- day.periods,
          span = span(period),
          not Enum.any?(units, &overlap?(span, &1)),
          do: Map.put(span, :label, nil)

    (units ++ Enum.uniq_by(outside, &{&1.start, &1.end}))
    |> Enum.sort_by(&{Time.to_erl(&1.start), Time.to_erl(&1.end)})
  end

  defp in_slot(periods, slot), do: Enum.filter(periods, &overlap?(span(&1), slot))

  defp span(%Period{start: start, end: finish}) do
    start = NaiveDateTime.to_time(start)
    finish = NaiveDateTime.to_time(finish)

    if Time.compare(finish, start) == :gt,
      do: %{start: start, end: finish},
      else: %{start: start, end: Time.add(start, 1)}
  end

  defp overlap?(a, b) do
    Time.compare(a.start, b.end) == :lt and Time.compare(b.start, a.end) == :lt
  end

  defp trim(rows) do
    rows
    |> Enum.drop_while(&empty?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&empty?/1)
    |> Enum.reverse()
  end

  defp empty?(row), do: Enum.all?(row.cells, &(&1 == []))
end
