defmodule AfterlifeWeb.PageController do
  use AfterlifeWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/switches")
    else
      render(conn, :home)
    end
  end
end
