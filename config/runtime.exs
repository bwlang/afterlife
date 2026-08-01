import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/afterlife start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :afterlife, AfterlifeWeb.Endpoint, server: true
end

config :afterlife, AfterlifeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :afterlife, AfterlifeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/afterlife_web/router\.ex$"E,
        ~r"lib/afterlife_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/afterlife/afterlife.db
      """

  config :afterlife, Afterlife.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Encryption key for message bodies/attachments at rest (Cloak). Generate
  # with: mix afterlife.gen_cloak_key
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: mix afterlife.gen_cloak_key
      """

  config :afterlife, Afterlife.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}
    ]

  if from_address = System.get_env("EMAIL_FROM") do
    config :afterlife, email_from: {"Afterlife", from_address}
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :afterlife, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :afterlife, AfterlifeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :afterlife, AfterlifeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :afterlife, AfterlifeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mail
  #
  # Every feature of this app is an email — reminders, magic-link logins,
  # and the final messages themselves — so a missing relay is a total
  # outage, and one nobody would notice until the day it mattered. Hence
  # raising at boot rather than discovering it at the first send.
  #
  # Delivered straight to the SMTP relay: Oban already retries failed
  # sends (DeliveryWorker, 5 attempts with backoff), so a local queueing
  # MTA in front of this would just be a second queue to keep alive.
  smtp_relay =
    System.get_env("SMTP_RELAY") ||
      raise """
      environment variable SMTP_RELAY is missing.
      For example: smtp.maileroo.com
      """

  config :afterlife, Afterlife.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_relay,
    port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
    username: System.get_env("SMTP_USER"),
    password: System.get_env("SMTP_PASS"),
    # :never lets an unauthenticated internal relay work; with
    # credentials set, refuse to fall back to sending them in the clear.
    auth: if(System.get_env("SMTP_USER"), do: :always, else: :never),
    tls: :always,
    # Without these, gen_smtp connects but doesn't validate the relay's
    # certificate — STARTTLS with no peer verification is trivially
    # MITM-able, and these credentials are on the wire.
    tls_options: [
      versions: [:"tlsv1.2", :"tlsv1.3"],
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_relay),
      depth: 99,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
end
