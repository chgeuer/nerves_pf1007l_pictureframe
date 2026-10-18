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
      spawn(fn -> write_boot_diagnostics() end)
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

  defp write_boot_diagnostics do
    File.mkdir_p("/tmp/boot_mnt")
    :os.cmd(~c"mount -t vfat /dev/mmcblk0p1 /tmp/boot_mnt")

    dump = fn label ->
      dmesg = :os.cmd(~c"dmesg") |> to_string()
      drm = :os.cmd(~c"head -n 20 /sys/class/drm/*/status /sys/class/drm/*/enabled /sys/class/drm/*/modes /sys/class/backlight/*/* 2>&1") |> to_string()
      input = :os.cmd(~c"cat /proc/bus/input/devices 2>&1") |> to_string()
      udc = :os.cmd(~c"head -n 20 /sys/class/udc/*/* /sys/kernel/config/usb_gadget/*/* 2>&1") |> to_string()

      content = """
      === PF1007L NERVES FLIGHT RECORDER (#{label}) ===
      === DRM & BACKLIGHT ===
      #{drm}
      === INPUT DEVICES ===
      #{input}
      === USB GADGET / UDC ===
      #{udc}
      === DMESG ===
      #{dmesg}
      """

      File.write("/tmp/boot_mnt/boot-diag.txt", content)
      :os.cmd(~c"sync")
    end

    dump.("initial")
    Process.sleep(5_000)
    dump.("after_5s")
    :os.cmd(~c"umount /tmp/boot_mnt")
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
        {Scenic, [main_viewport_config]}
      ]
    end
  end
end
