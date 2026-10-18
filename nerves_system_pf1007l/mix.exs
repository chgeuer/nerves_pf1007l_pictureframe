defmodule NervesSystemPf1007l.MixProject do
  use Mix.Project

  @app :nerves_system_pf1007l
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: "Nerves System - Allwinner A33 PF1007L Digital Photo Frame",
      deps: deps(),
      aliases: [loadconfig: [&bootstrap/1]]
    ]
  end

  def application do
    []
  end

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  defp nerves_package do
    [
      type: :system,
      build_runner_opts: build_runner_opts(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      env: [
        {"TARGET_ARCH", "arm"},
        {"TARGET_CPU", "cortex_a7"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnueabihf"},
        {"TARGET_GCC_FLAGS",
         "-mabi=aapcs-linux -mfpu=vfpv4-d16 -marm -fstack-protector-strong -mfloat-abi=hard -mcpu=cortex-a7 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: package_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.11 or ~> 2.0 or ~> 2.0.0-dev", runtime: false},
      {:nerves_system_br, "1.35.2", runtime: false},
      {:nerves_toolchain_armv7_nerves_linux_gnueabihf, "~> 15.3.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package_files do
    [
      "c_src",
      "Config.in",
      "fwup_include",
      "linux",
      "rootfs_overlay",
      "uboot",
      "fwup-ops.conf",
      "fwup.conf",
      "mix.exs",
      "nerves_defconfig",
      "post-build.sh",
      "post-createfs.sh",
      "README.md",
      "VERSION"
    ]
  end

  defp build_runner_opts do
    [make_args: primary_site() ++ ["source", "all"]]
  end

  defp primary_site do
    case System.get_env("BR2_PRIMARY_SITE") do
      nil -> []
      primary_site -> ["BR2_PRIMARY_SITE=#{primary_site}"]
    end
  end

  defp set_target do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end
