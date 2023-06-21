#-*-Mode:elixir;coding:utf-8;tab-width:2;c-basic-offset:2;indent-tabs-mode:()-*-
# ex: set ft=elixir fenc=utf-8 sts=2 ts=2 sw=2 et nomod:

defmodule CloudIServiceMonitoring do
  use Mix.Project

  def project do
    [app: :cloudi_service_monitoring,
     version: "2.0.6",
     language: :erlang,
     erlc_options: [
       :deterministic,
       :debug_info,
       :warn_export_vars,
       :warn_unused_import,
       #:warn_missing_spec,
       :warnings_as_errors],
     description: description(),
     package: package(),
     deps: deps()]
  end

  defp deps do
    [{:exometer_core, ">= 1.5.7"},
     {:folsom, ">= 1.0.0"},
     {:cloudi_core, ">= 2.0.6"},
     {:key2value, ">= 2.0.6"}]
  end

  defp description do
    "CloudI Monitoring Service"
  end

  defp package do
    [files: ~w(src doc rebar.config README.markdown LICENSE),
     maintainers: ["Michael Truog"],
     licenses: ["MIT"],
     links: %{"Website" => "https://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_monitoring"}]
   end
end
