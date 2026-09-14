defmodule Bonfire.Social.API.ReplyNotificationsTest do
  use Bonfire.Social.MastoApiCase, async: false

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    author_account = Bonfire.Me.Fake.fake_account!()
    author = Bonfire.Me.Fake.fake_user!(author_account)
    replier_account = Bonfire.Me.Fake.fake_account!()
    replier = Bonfire.Me.Fake.fake_user!(replier_account)

    {:ok,
     author: author,
     replier: replier,
     author_conn: masto_api_conn(conn, user: author, account: author_account),
     replier_conn: masto_api_conn(conn, user: replier, account: replier_account)}
  end

  for poll? <- [false, true] do
    test "reply to poll=#{poll?} notifies its author without an explicit mention", context do
      params = %{"status" => Faker.Lorem.sentence(), "visibility" => "public"}

      params =
        if unquote(poll?),
          do: Map.put(params, "poll", %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}),
          else: params

      parent = context.author_conn |> post("/api/v1/statuses", params) |> json_response(200)

      reply =
        context.replier_conn
        |> post("/api/v1/statuses", %{
          "status" => Faker.Lorem.sentence(),
          "in_reply_to_id" => parent["id"],
          "visibility" => "public"
        })
        |> json_response(200)

      notifications = context.author_conn |> get("/api/v1/notifications") |> json_response(200)
      notification = Enum.find(notifications, &(get_in(&1, ["status", "id"]) == reply["id"]))
      assert notification
      assert notification["type"] == "mention"
      assert notification["account"]["id"] == context.replier.id
      assert notification["status"]["in_reply_to_id"] == parent["id"]

      self_notifications =
        context.replier_conn |> get("/api/v1/notifications") |> json_response(200)

      refute Enum.any?(self_notifications, &(get_in(&1, ["status", "id"]) == reply["id"]))
    end
  end

  test "replying to oneself does not notify oneself", context do
    parent =
      context.author_conn
      |> post("/api/v1/statuses", %{"status" => Faker.Lorem.sentence()})
      |> json_response(200)

    reply =
      context.author_conn
      |> post("/api/v1/statuses", %{
        "status" => Faker.Lorem.sentence(),
        "in_reply_to_id" => parent["id"]
      })
      |> json_response(200)

    notifications = context.author_conn |> get("/api/v1/notifications") |> json_response(200)
    refute Enum.any?(notifications, &(get_in(&1, ["status", "id"]) == reply["id"]))
  end
end
