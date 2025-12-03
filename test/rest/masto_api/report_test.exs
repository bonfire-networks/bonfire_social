# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.ReportTest do
  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Flags

  @moduletag :masto_api

  describe "POST /api/v1/reports" do
    test "creates a report against an account", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/reports", %{
          "account_id" => target.id,
          "comment" => "This is spam"
        })
        |> json_response(200)

      # Validate Report structure
      assert is_binary(response["id"])
      assert response["category"] == "other"
      assert response["comment"] == "This is spam"
      assert response["action_taken"] == false
      assert response["forwarded"] == false
      assert is_binary(response["created_at"])

      # target_account should be present
      assert is_map(response["target_account"])
      assert response["target_account"]["id"] == target.id
    end

    test "creates a report with forward flag", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/reports", %{
          "account_id" => target.id,
          "comment" => "Harassment",
          "forward" => true
        })
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["comment"] == "Harassment"
      # Note: forwarded in response may still be false as we don't track it after creation
    end

    test "creates a report without comment", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/reports", %{"account_id" => target.id})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["comment"] == ""
    end

    test "truncates comment to 1000 characters", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      long_comment = String.duplicate("a", 1500)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/reports", %{
          "account_id" => target.id,
          "comment" => long_comment
        })
        |> json_response(200)

      assert String.length(response["comment"]) == 1000
    end

    test "returns error when account_id is missing", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/reports", %{})
        |> json_response(400)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      target = Fake.fake_user!()

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/reports", Jason.encode!(%{"account_id" => target.id}))
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "allows reporting the same account again (idempotent)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      api_conn = masto_api_conn(conn, user: user, account: account)

      # First report
      response1 =
        api_conn
        |> post("/api/v1/reports", %{"account_id" => target.id})
        |> json_response(200)

      # Second report - should succeed (Flags.flag handles duplicates)
      response2 =
        api_conn
        |> post("/api/v1/reports", %{"account_id" => target.id})
        |> json_response(200)

      assert response1["id"] == response2["id"]
    end
  end

  describe "GET /api/v1/reports" do
    test "lists reports created by the user", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target1 = Fake.fake_user!()
      target2 = Fake.fake_user!()

      # Create some flags
      {:ok, _flag1} = Flags.flag(user, target1, comment: "Spam")
      {:ok, _flag2} = Flags.flag(user, target2, comment: "Harassment")

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/reports")
        |> json_response(200)

      assert is_list(response)
      assert length(response) == 2

      # Each report should have required fields
      Enum.each(response, fn report ->
        assert is_binary(report["id"])
        assert is_binary(report["created_at"])
        assert is_map(report["target_account"])
      end)
    end

    test "returns empty list when user has no reports", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/reports")
        |> json_response(200)

      assert response == []
    end

    test "does not show other users' reports", %{conn: conn} do
      account1 = Fake.fake_account!()
      user1 = Fake.fake_user!(account1)
      account2 = Fake.fake_account!()
      user2 = Fake.fake_user!(account2)
      target = Fake.fake_user!()

      # user1 creates a report
      {:ok, _flag} = Flags.flag(user1, target, comment: "Spam")

      # user2 should not see it
      api_conn = masto_api_conn(conn, user: user2, account: account2)

      response =
        api_conn
        |> get("/api/v1/reports")
        |> json_response(200)

      assert response == []
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/reports")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "GET /api/v1/reports/:id" do
    test "returns a specific report", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      target = Fake.fake_user!()

      {:ok, flag} = Flags.flag(user, target, comment: "Test report")

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/reports/#{flag.id}")
        |> json_response(200)

      assert response["id"] == flag.id
      assert response["comment"] == "Test report"
      assert is_map(response["target_account"])
    end

    test "returns 404 for non-existent report", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/reports/01HZNONEXISTENT00000000000")
        |> json_response(404)

      assert response["error"]
    end

    test "returns 404 for report owned by another user", %{conn: conn} do
      account1 = Fake.fake_account!()
      user1 = Fake.fake_user!(account1)
      account2 = Fake.fake_account!()
      user2 = Fake.fake_user!(account2)
      target = Fake.fake_user!()

      # user1 creates the report
      {:ok, flag} = Flags.flag(user1, target, comment: "Secret")

      # user2 tries to access it
      api_conn = masto_api_conn(conn, user: user2, account: account2)

      response =
        api_conn
        |> get("/api/v1/reports/#{flag.id}")
        |> json_response(404)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      user = Fake.fake_user!()
      target = Fake.fake_user!()
      {:ok, flag} = Flags.flag(user, target)

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/reports/#{flag.id}")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end
end
