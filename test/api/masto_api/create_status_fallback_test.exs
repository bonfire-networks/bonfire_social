defmodule Bonfire.Social.MastoApi.CreateStatusFallbackTest do
  @moduledoc """
  POST /api/v1/statuses when the GraphQL read-back of the new post fails: the post exists,
  so create still answers 200, mapped through GraphQL from the published activity, rather
  than an error that makes the client post it again.

  Its own module because `Mock` replaces the adapter for every process (async: false).

  Run with: just test extensions/bonfire_social/test/api/masto_api/create_status_fallback_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: false

  import Mock

  alias Bonfire.Me.Fake
  alias Bonfire.Social.API.GraphQLMasto.Adapter

  @moduletag :masto_api

  setup %{conn: conn} do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    {:ok, user: user, api_conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "answers 200 from the published activity when the read-back fails", %{
    user: user,
    api_conn: api_conn
  } do
    with_mock Adapter, [:passthrough], read_status: fn _id, _user -> {:error, :not_found} end do
      response =
        api_conn
        |> post("/api/v1/statuses", %{"status" => "Hello despite the read-back"})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["content"] =~ "Hello despite the read-back"
      assert response["account"]["id"] == user.id
      assert response["visibility"] == "public"
      assert_called(Adapter.read_status(response["id"], :_))
    end
  end

  test "answers 200 when the read-back raises", %{user: user, api_conn: api_conn} do
    with_mock Adapter, [:passthrough],
      read_status: fn _id, _user -> raise DBConnection.ConnectionError, "read-back timed out" end do
      response =
        api_conn
        |> post("/api/v1/statuses", %{"status" => "Hello despite a raise"})
        |> json_response(200)

      assert response["content"] =~ "Hello despite a raise"
      assert response["account"]["id"] == user.id
    end
  end

  test "a poll answers 200 with its poll when the read-back fails", %{
    user: user,
    api_conn: api_conn
  } do
    with_mock Adapter, [:passthrough], read_status: fn _id, _user -> {:error, :not_found} end do
      response =
        api_conn
        |> post("/api/v1/statuses", %{
          "status" => "Tea or coffee?",
          "visibility" => "public",
          "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}
        })
        |> json_response(200)

      assert response["account"]["id"] == user.id
      assert response["poll"]["id"] == response["id"]
    end
  end
end
