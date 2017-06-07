#-*-Mode:elixir;coding:utf-8;tab-width:2;c-basic-offset:2;indent-tabs-mode:()-*-
# ex: set ft=elixir fenc=utf-8 sts=2 ts=2 sw=2 et nomod:

defmodule CloudIServiceMonitoring do
  use Mix.Project

  def project do
    [app: :cloudi_service_monitoring,
     version: "1.7.1",
     language: :erlang,
     description: description(),
     package: package(),
     deps: deps()]
  end

  defp deps do
    [{:exometer,
      [git: "https://github.com/Feuerlabs/exometer.git",
       ref: "7a7bd8d2b52de4d90f65aa3f6044b0e988319b9e"]},
     {:folsom, "~> 0.8.3"},
     {:cloudi_core, "~> 1.7.1"},
     {:key2value, "~> 1.7.1"}]
  end

  defp description do
    "CloudI Monitoring Service"
  end

  defp package do
    [files: ~w(src doc rebar.config README.markdown),
     maintainers: ["Michael Truog"],
     licenses: ["MIT"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_monitoring"}]
   end
end
