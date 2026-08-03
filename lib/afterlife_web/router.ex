defmodule AfterlifeWeb.Router do
  use AfterlifeWeb, :router

  import AfterlifeWeb.UserAuth

  @content_security_policy "default-src 'self'; " <>
                             "script-src 'self' 'unsafe-inline'; " <>
                             "style-src 'self' 'unsafe-inline'; " <>
                             "img-src 'self' data:; " <>
                             "font-src 'self'; " <>
                             "connect-src 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AfterlifeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # No session, no CSRF, no current-user lookup — the health check is
  # polled every minute by an external monitor and should depend on as
  # little as possible. The secure headers are pure plug (no session, no
  # DB), so there's no reason for this response to go out without them.
  pipeline :health do
    plug :accepts, ["html", "json"]
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
  end

  scope "/", AfterlifeWeb do
    pipe_through :health

    get "/health", HealthController, :show
  end

  scope "/", AfterlifeWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/check-in/:token", CheckInController, :show
  end

  scope "/api", AfterlifeWeb.Api do
    pipe_through :api

    # sobelow_skip ["Config.CSRFRoute"]
    #
    # Intentionally reachable via both GET and POST on the same action —
    # normally a CSRF-via-action-reuse red flag, but doesn't apply here:
    # this endpoint is authenticated by a capability-style bearer token in
    # the URL itself (Switches.regenerate_api_token/1), not by session
    # cookie, so there's no ambient browser auth for a forged cross-site
    # request to ride on. GET is kept deliberately, to stay curl/cron-
    # friendly (matching healthchecks.io-style ping URLs).
    get "/check_in/:token", CheckInController, :check_in
    post "/check_in/:token", CheckInController, :check_in
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:afterlife, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AfterlifeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", AfterlifeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AfterlifeWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/recipients", RecipientLive.Index, :index

      live "/vigils", SwitchLive.Index, :index
      live "/vigils/new", SwitchLive.Index, :new
      live "/vigils/:id", SwitchLive.Show, :show
      live "/vigils/:switch_id/messages/new", MessageLive.Form, :new
      live "/vigils/:switch_id/messages/:id/edit", MessageLive.Form, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", AfterlifeWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AfterlifeWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
