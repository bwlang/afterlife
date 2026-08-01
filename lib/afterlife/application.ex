defmodule Afterlife.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AfterlifeWeb.Telemetry,
      Afterlife.Repo,
      # Must precede Oban: on a fresh database (first boot against an
      # empty volume) Oban's producers query `oban_jobs` immediately, so
      # the tables have to exist before it starts.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:afterlife, :ecto_repos), skip: skip_migrations?()},
      Afterlife.Vault,
      {Oban, Application.fetch_env!(:afterlife, Oban)},
      {DNSCluster, query: Application.get_env(:afterlife, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Afterlife.PubSub},
      # Start a worker by calling: Afterlife.Worker.start_link(arg)
      # {Afterlife.Worker, arg},
      # Start to serve requests, typically the last entry
      AfterlifeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Afterlife.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AfterlifeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Migrations run at boot in a release, so a deploy that starts is a
  # deploy that migrated — there's no separate migrate step to forget.
  # To roll one back, run against a live release:
  #
  #     bin/afterlife eval \
  #       'Ecto.Migrator.with_repo(Afterlife.Repo, &Ecto.Migrator.run(&1, :down, to: VERSION))'
  defp skip_migrations? do
    System.get_env("RELEASE_NAME") == nil
  end
end
