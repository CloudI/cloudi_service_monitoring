defmodule CloudIServiceMonitoring do
  use Mix.Project

  def project do
    [app: :cloudi_service_monitoring,
     version: "1.5.3",
     language: :erlang,
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    [{:exometer,
      [git: "https://github.com/Feuerlabs/exometer.git",
       tag: "1.2.1"]},
     {:folsom, "~> 0.8.3", override: true},
     {:cloudi_core, "~> 1.5.3"},
     {:key2value, "~> 1.5.3"}]
  end

  defp description do
    "CloudI Monitoring Service"
  end

  defp package do
    [files: ~w(src doc rebar.config README.markdown),
     maintainers: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_monitoring"}]
   end
end
