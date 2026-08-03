defmodule AfterlifeWeb.PageControllerTest do
  use AfterlifeWeb.ConnCase

  import Afterlife.AccountsFixtures

  test "GET / shows the marketing page to a logged-out visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Afterlife"
    assert html_response(conn, 200) =~ "Get started"
  end

  test "GET / redirects a logged-in user straight to their switches", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/vigils"
  end
end
