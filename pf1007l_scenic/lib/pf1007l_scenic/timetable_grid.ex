defmodule Pf1007lScenic.TimetableGrid do
  @moduledoc """
  Lays out a week's WebUntis timetable as a grid of days (columns) and lesson
  slots (rows) for rendering in Scenic.
  """

  alias Untis.{Period, Timetable}

  def build(%Timetable{} = timetable) do
    days =
      timetable
      |> Timetable.days()
      |> Enum.filter(&(Date.day_of_week(&1.date) <= 5 or &1.periods != []))

    rows =
      for slot <- slots(timetable, days) do
        Map.put(slot, :cells, Enum.map(days, &in_slot(&1.periods, slot)))
      end

    %{days: days, rows: trim(rows)}
  end

  def status(%Period{} = period) do
    cond do
      Period.cancelled?(period) -> :cancelled
      Period.exam?(period) -> :exam
      Period.changed?(period) -> :changed
      true -> :regular
    end
  end

  def format_time(%Time{hour: h, minute: m}) do
    :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()
  end

  def format_time(%NaiveDateTime{} = ndt), do: format_time(NaiveDateTime.to_time(ndt))
  def format_time(_), do: ""

  def day_short(%Date{} = date) do
    weekday =
      case Date.day_of_week(date) do
        1 -> "Mon"
        2 -> "Tue"
        3 -> "Wed"
        4 -> "Thu"
        5 -> "Fri"
        6 -> "Sat"
        7 -> "Sun"
      end

    "#{weekday} #{date.day}.#{date.month}."
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
