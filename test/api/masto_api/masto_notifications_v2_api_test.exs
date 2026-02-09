# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoNotificationsV2ApiTest do
    @moduledoc "Run with: just test extensions/bonfire_social/test/api/masto_api/masto_notifications_v2_api_test.exs"

    use Bonfire.API.MastoApiCase, async: false

    @moduletag :masto_api

    setup %{conn: conn} do
      account = Bonfire.Me.Fake.fake_account!()
      user = Bonfire.Me.Fake.fake_user!(account)

      conn = masto_api_conn(conn, user: user, account: account)

      {:ok, conn: conn, user: user, account: account}
    end

    defp unauthenticated_conn do
      Phoenix.ConnTest.build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
    end

    describe "GET /api/v2/notifications" do
      test "returns 200 with list", %{conn: conn} do
        response =
          conn
          |> get("/api/v2/notifications")
          |> json_response(200)

        assert is_list(response)
      end

      test "requires authentication" do
        response =
          unauthenticated_conn()
          |> get("/api/v2/notifications")
          |> json_response(401)

        assert response["error"]
      end
    end
  end
end
