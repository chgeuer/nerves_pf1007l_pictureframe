defmodule Pf1007lScenic.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @target Mix.target()

  @impl true
  def start(_type, _args) do
    if @target != :host do
      init_hardware()
      spawn(fn -> init_wifi_driver() end)
    end

    children =
      [
        # Children for all targets
        # Starts a worker by calling: Pf1007lScenic.Worker.start_link(arg)
        # {Pf1007lScenic.Worker, arg},
      ] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pf1007lScenic.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp init_hardware do
    # Unbind Linux fbcon (vtcon1) so Scenic exclusively owns /dev/fb0
    _ = File.write("/sys/class/vtconsole/vtcon1/bind", "0\n")

    # Initialize Allwinner A33 MIPI-DSI + D-PHY + TCON0 + JD9365DA panel & PH0 PWM backlight
    if File.exists?("/usr/bin/pf1007l-dsi-init") do
      _ = System.cmd("/usr/bin/pf1007l-dsi-init", [])
    end

    # Ensure Silead GSL1680 touchscreen is bound before Scenic.Driver.Local enumerates /dev/input/event*
    unless File.exists?("/sys/bus/i2c/devices/0-0040/driver") do
      _ = File.write("/sys/bus/i2c/drivers/silead_ts/bind", "0-0040")
      Process.sleep(100)
    end
  rescue
    _ -> :ok
  end

  defp init_wifi_driver do
    if File.exists?("/lib/modules/6.12.34/extra/aic8800_bsp.ko") do
      # Let usb0, sshd, and Scenic finish starting first
      Process.sleep(4_000)

      unless File.exists?("/sys/class/net/wlan0") do
        # Hardware power-cycle AIC8800DC via sunxi-mmc1 pwrseq (PL5 chip_en + PL6 wl_reg_on)
        # while no aic8800 module is loaded, so warm OTA reboots always reset the chip
        # cleanly back to its SDIO ROM bootloader (0xC8A1:0xC08D) without touching rtnl_lock.
        if File.exists?("/sys/bus/platform/drivers/sunxi-mmc/1c10000.mmc") do
          _ = File.write("/sys/bus/platform/drivers/sunxi-mmc/unbind", "1c10000.mmc")
          Process.sleep(300)
          _ = File.write("/sys/bus/platform/drivers/sunxi-mmc/bind", "1c10000.mmc")
          Process.sleep(800)
        end

        _ = System.cmd("/sbin/modprobe", ["aic8800_bsp"])
        Process.sleep(300)
        _ = System.cmd("/sbin/modprobe", ["aic8800_fdrv"])
      end
    end
  rescue
    _ -> :ok
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      main_viewport_config = Application.get_env(:pf1007l_scenic, :viewport)

      [
        Pf1007lScenic.Accelerometer,
        Pf1007lScenic.Schedule,
        {Scenic, [main_viewport_config]}
      ]
    end
  end
end
