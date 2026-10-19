defmodule Pf1007lScenic.Assets do
  use Scenic.Assets.Static,
    otp_app: :pf1007l_scenic,
    sources: [
      "assets",
      {:scenic, "deps/scenic/assets"}
    ],
    alias: [
      roboto: "fonts/BerkeleyMono-Regular.ttf",
      roboto_mono: "fonts/BerkeleyMono-Regular.ttf",
      berkeley_mono: "fonts/BerkeleyMono-Regular.ttf",
      berkeley_mono_bold: "fonts/BerkeleyMono-Bold.ttf"
    ]
end
