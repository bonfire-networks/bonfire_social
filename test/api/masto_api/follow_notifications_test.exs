defmodule Bonfire.Social.API.FollowNotificationsTest do
  use Bonfire.Social.MastoApiCase, async: false
  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    follower = Bonfire.Me.Fake.fake_user!(account)
    author_account = Bonfire.Me.Fake.fake_account!()
    author = Bonfire.Me.Fake.fake_user!(author_account)
    {:ok, follower: follower, author: author,
      conn: masto_api_conn(conn, user: follower, account: account),
      author_conn: masto_api_conn(conn, user: author, account: author_account)}
  end

  test "rejects author-post notifications without creating or changing a follow", c do
    path = "/api/v1/accounts/#{c.author.id}/follow"
    for notify <- [true, "true", "1", 1] do
      error = c.conn |> post(path, %{"notify" => notify}) |> json_response(422)
      assert error["error"] == "Notifications for every post by an author are not supported"
      refute Bonfire.Social.Graph.Follows.following?(c.follower, c.author)
    end
    assert (c.conn |> post(path, %{}) |> json_response(200))["following"]
    c.conn |> post(path, %{"notify" => true}) |> response(422)
    assert Bonfire.Social.Graph.Follows.following?(c.follower, c.author)
  end

  test "ordinary follow and unfollow report notifying false", c do
    path = "/api/v1/accounts/#{c.author.id}/follow"
    for params <- [%{}, %{"notify" => false}, %{"notify" => "false"}] do
      result = c.conn |> post(path, params) |> json_response(200)
      assert result["following"]
      assert result["notifying"] == false
    end
    [relationship] = c.conn |> get("/api/v1/accounts/relationships?id[]=#{c.author.id}") |> json_response(200)
    assert relationship["following"]
    assert relationship["notifying"] == false
    result = c.conn |> post("/api/v1/accounts/#{c.author.id}/unfollow", %{}) |> json_response(200)
    assert result["following"] == false
    assert result["notifying"] == false
  end

  test "publishing ordinary posts and polls does not notify followers", c do
    c.conn |> post("/api/v1/accounts/#{c.author.id}/follow", %{}) |> json_response(200)
    ordinary = publish(c.author_conn, "public")
    direct = publish(c.author_conn, "direct")
    poll = c.author_conn |> post("/api/v1/statuses", %{
      "status" => Faker.Lorem.sentence(),
      "poll" => %{"options" => ["One", "Two"], "expires_in" => 3600}
    }) |> json_response(200)
    assert poll["poll"]["id"]
    refute Enum.any?(notifications(c.conn), &(&1["status"] && &1["status"]["id"] in [ordinary["id"], direct["id"], poll["id"]]))
  end

  test "replies still notify the parent author as mentions", c do
    parent = publish(c.conn, "public")
    reply = c.author_conn |> post("/api/v1/statuses", %{"status" => Faker.Lorem.sentence(), "in_reply_to_id" => parent["id"]}) |> json_response(200)
    mentions = c.conn |> get("/api/v1/notifications?types[]=mention") |> json_response(200)
    assert Enum.any?(mentions, &(&1["type"] == "mention" and &1["status"]["id"] == reply["id"]))
  end

  test "explicit mentions still notify through the native delivery path", c do
    username = Bonfire.Common.Repo.preload(c.follower, :character).character.username
    status = c.author_conn |> post("/api/v1/statuses", %{"status" => "@#{username} #{Faker.Lorem.sentence()}"}) |> json_response(200)
    assert Enum.any?(notifications(c.conn), &(&1["type"] == "mention" and &1["status"]["id"] == status["id"]))
    grouped = c.conn |> get("/api/v2/notifications?types[]=mention&limit=1") |> json_response(200)
    assert [group] = grouped["notification_groups"]
    assert group["type"] == "mention"
    assert group["status_id"] == status["id"]
  end

  defp publish(conn, visibility), do: conn |> post("/api/v1/statuses", %{"status" => Faker.Lorem.sentence(), "visibility" => visibility}) |> json_response(200)
  defp notifications(conn), do: conn |> get("/api/v1/notifications") |> json_response(200)
end
