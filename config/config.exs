# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :afterlife, :scopes,
  user: [
    default: true,
    module: Afterlife.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Afterlife.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :afterlife,
  ecto_repos: [Afterlife.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Sender for every outgoing email (Afterlife.Mailer.deliver_text/4).
  # Override in prod via EMAIL_FROM (config/runtime.exs) — a real
  # deliverable address on your sending domain.
  email_from: {"Afterlife", "contact@example.com"}

# Oban is the dead-man's-switch engine: a cron-scheduled sweep sends
# reminders, advances active/grace/triggered state, and enqueues
# delivery jobs. The Lite engine runs it against our SQLite DB directly
# — no Postgres, no Redis (see docs/DESIGN.md).
config :afterlife, Oban,
  engine: Oban.Engines.Lite,
  # The default notifier assumes Postgres LISTEN/NOTIFY; PG uses Erlang's
  # :pg process groups instead, which works with any Ecto adapter.
  notifier: Oban.Notifiers.PG,
  repo: Afterlife.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Afterlife.Switches.SweepWorker}
     ]},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}
  ],
  queues: [default: 10, mailers: 5]

# Configure the endpoint
config :afterlife, AfterlifeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AfterlifeWeb.ErrorHTML, json: AfterlifeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Afterlife.PubSub,
  live_view: [signing_salt: "U3yLMeS8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :afterlife, Afterlife.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  afterlife: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  afterlife: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
