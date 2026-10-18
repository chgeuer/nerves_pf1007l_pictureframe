defmodule Pf1007lScenic.WiFi do
  @moduledoc """
  Helper for scanning, connecting, and inspecting `wlan0` via `VintageNet`
  and `VintageNetWiFi`. Credentials configured via `VintageNet.configure/3`
  are automatically persisted to `/root` across reboots.
  """

  @ifname "wlan0"

  def subscribe do
    if Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :subscribe, [["interface", @ifname]])
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def scan do
    if Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :scan, [@ifname])
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def connect(ssid, password) when is_binary(ssid) do
    ssid = String.trim(ssid)
    password = String.trim(password || "")

    cond do
      ssid == "" ->
        {:error, :empty_ssid}

      not Code.ensure_loaded?(VintageNetWiFi) ->
        {:error, :vintage_net_unavailable}

      password == "" ->
        config = %{
          type: VintageNetWiFi,
          vintage_net_wifi: %{
            networks: [%{ssid: ssid, key_mgmt: :none}]
          },
          ipv4: %{method: :dhcp}
        }

        apply(VintageNet, :configure, [@ifname, config])

      true ->
        apply(VintageNetWiFi, :quick_configure, [ssid, password])
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def status do
    if Code.ensure_loaded?(VintageNet) do
      connection = apply(VintageNet, :get, [["interface", @ifname, "connection"]]) || :disconnected
      aps = apply(VintageNet, :get, [["interface", @ifname, "wifi", "access_points"]]) || []
      current_ap = apply(VintageNet, :get, [["interface", @ifname, "wifi", "current_ap"]])
      addrs = apply(VintageNet, :get, [["interface", @ifname, "addresses"]]) || []
      cfg = apply(VintageNet, :get, [["interface", @ifname, "config"]]) || %{}

      configured_ssid =
        case get_in(cfg, [:vintage_net_wifi, :networks]) do
          [%{ssid: s} | _] when is_binary(s) -> s
          _ -> nil
        end

      ssid =
        cond do
          is_map(current_ap) and is_binary(Map.get(current_ap, :ssid)) and current_ap.ssid != "" ->
            current_ap.ssid

          is_binary(configured_ssid) and configured_ssid != "" ->
            configured_ssid

          true ->
            nil
        end

      ipv4 =
        Enum.find_value(addrs, fn
          %{family: :inet, address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
          _ -> nil
        end)

      dedup_aps =
        aps
        |> Enum.filter(&(is_binary(&1.ssid) and String.trim(&1.ssid) != ""))
        |> Enum.sort_by(&(&1.signal_percent || 0), :desc)
        |> Enum.uniq_by(& &1.ssid)
        |> Enum.take(8)
        |> Enum.map(fn ap ->
          %{
            ssid: ap.ssid,
            signal_percent: ap.signal_percent || 0,
            flags: ap.flags || [],
            secure?: Enum.any?(ap.flags || [], &(&1 in [:wpa2, :psk, :wpa, :sae]))
          }
        end)

      %{
        connection: connection,
        ssid: ssid,
        ip: ipv4,
        access_points: dedup_aps
      }
    else
      %{connection: :disconnected, ssid: nil, ip: nil, access_points: []}
    end
  rescue
    _ -> %{connection: :disconnected, ssid: nil, ip: nil, access_points: []}
  end
end
