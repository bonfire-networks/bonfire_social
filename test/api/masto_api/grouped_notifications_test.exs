defmodule Bonfire.Social.API.GroupedNotificationsTest do
  use Bonfire.Social.MastoApiCase, async: false
  doctest Bonfire.API.MastoCompat.Mappers.NotificationGroups
  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    user = Bonfire.Me.Fake.fake_user!(account)
    {:ok, user: user, conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "groups two favourites, preserves canonical references, and keeps v1 flat", %{conn: conn, user: user} do
    {:ok, post} = Bonfire.Posts.publish(current_user: user, post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
    actors = for _ <- 1..2, do: Bonfire.Me.Fake.fake_user!()
    for actor <- actors, do: assert({:ok, _} = Bonfire.Social.Likes.like(actor, post))
    result = conn |> get("/api/v2/notifications?types[]=favourite") |> json_response(200)
    assert is_map(result)
    assert [group] = result["notification_groups"]
    assert group["notifications_count"] == 2
    assert group["type"] == "favourite"
    assert group["status_id"] == post.id
    assert MapSet.new(group["sample_account_ids"]) == MapSet.new(Enum.map(actors, & &1.id))
    assert MapSet.new(Enum.map(result["accounts"], & &1["id"])) == MapSet.new(group["sample_account_ids"])
    assert [status] = result["statuses"]
    assert status["account"]["id"] == user.id
    assert status["id"] == post.id
    detail = conn |> get("/api/v2/notifications/#{group["group_key"]}") |> json_response(501)
    assert detail["error"] == "Notification group detail lookup is not supported"
    assert length(conn |> get("/api/v1/notifications?types[]=favourite") |> json_response(200)) == 2
  end

  test "paginates activities before grouping without losing or repeating notifications", %{conn: conn, user: user} do
    actors = for _ <- 1..3, do: Bonfire.Me.Fake.fake_user!()
    posts = for _ <- 1..2 do
      {:ok, post} = Bonfire.Posts.publish(current_user: user, post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
      for actor <- actors, do: assert({:ok, _} = Bonfire.Social.Likes.like(actor, post))
      post
    end
    {groups, next} = Enum.reduce(1..6, {[], "/api/v2/notifications?limit=1&types[]=favourite"}, fn _, {groups, url} ->
      refute is_nil(url)
      page_conn = get(conn, url)
      assert [group] = json_response(page_conn, 200)["notification_groups"]
      assert group["notifications_count"] == 1
      next = case get_resp_header(page_conn, "link") do
        [links] -> case Regex.run(~r/<([^>]+)>; rel="next"/, links) do
          [_, url] -> uri = URI.parse(url); uri.path <> "?" <> uri.query
          _ -> nil
        end
        _ -> nil
      end
      {groups ++ [group], next}
    end)
    assert is_nil(next)
    assert length(Enum.uniq_by(groups, & &1["most_recent_notification_id"])) == 6
    assert MapSet.new(Enum.map(groups, & &1["status_id"])) == MapSet.new(Enum.map(posts, & &1.id))
    ungrouped = conn |> get("/api/v2/notifications?grouped_types[]=follow&types[]=favourite") |> json_response(200)
    assert length(ungrouped["notification_groups"]) == 6
    assert Enum.all?(ungrouped["notification_groups"], &(String.starts_with?(&1["group_key"], "ungrouped-") and &1["notifications_count"] == 1))
    filtered = conn |> get("/api/v2/notifications?account_id=#{hd(actors).id}") |> json_response(200)
    assert length(filtered["notification_groups"]) == 2
    assert Enum.all?(filtered["notification_groups"], &(&1["sample_account_ids"] == [hd(actors).id]))
  end
  test "follows stay separate and group details are explicitly unsupported", %{conn: conn, user: user} do
    actors = for _ <- 1..2, do: Bonfire.Me.Fake.fake_user!()
    for actor <- actors, do: assert({:ok, _} = Bonfire.Social.Graph.Follows.follow(actor, user))
    result = conn |> get("/api/v2/notifications?types[]=follow") |> json_response(200)
    assert [group, other] = result["notification_groups"]
    assert Enum.all?([group, other], &(&1["notifications_count"] == 1))
    refute Map.has_key?(group, "status_id")
    refute Map.has_key?(other, "status_id")
    assert result["statuses"] == []
    outsider = masto_api_conn(Phoenix.ConnTest.build_conn(), user: hd(actors))
    outsider |> get("/api/v2/notifications/#{group["group_key"]}") |> response(501)
  end

  test "native boost groups keep page-local actors and continue across page boundaries", %{conn: conn, user: user} do
    {:ok, post} = Bonfire.Posts.publish(current_user: user, post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
    actors = for _ <- 1..3, do: Bonfire.Me.Fake.fake_user!()
    for actor <- actors, do: assert({:ok, _} = Bonfire.Social.Boosts.boost(actor, post))
    first = get(conn, "/api/v2/notifications?types[]=reblog&limit=2")
    assert [group] = json_response(first, 200)["notification_groups"]
    assert group["notifications_count"] == 2
    assert group["type"] == "reblog"
    assert length(group["sample_account_ids"]) == 2
    [links] = get_resp_header(first, "link")
    [_, next] = Regex.run(~r/<([^>]+)>; rel="next"/, links)
    uri = URI.parse(next)
    second = get(conn, uri.path <> "?" <> uri.query)
    assert [remaining] = json_response(second, 200)["notification_groups"]
    assert remaining["notifications_count"] == 1
    assert remaining["status_id"] == group["status_id"]
    assert MapSet.new(group["sample_account_ids"] ++ remaining["sample_account_ids"]) == MapSet.new(Enum.map(actors, & &1.id))
    refute Enum.any?(get_resp_header(second, "link"), &String.contains?(&1, "rel=\"next\""))

    outsider = masto_api_conn(Phoenix.ConnTest.build_conn(), user: hd(actors))
    assert (outsider |> get("/api/v2/notifications?types[]=reblog") |> json_response(200))["notification_groups"] == []
  end

  test "since and min cursors return only newer groups", %{conn: conn, user: user} do
    actor = Bonfire.Me.Fake.fake_user!()
    groups = for _ <- 1..3 do
      {:ok, post} = Bonfire.Posts.publish(current_user: user, post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
      {:ok, like} = Bonfire.Social.Likes.like(actor, post)
      like.id
    end
    [oldest, middle, newest] = groups
    result = conn |> get("/api/v2/notifications?since_id=#{middle}&types[]=favourite") |> json_response(200)
    assert [group] = result["notification_groups"]
    assert group["most_recent_notification_id"] == newest
    result = conn |> get("/api/v2/notifications?min_id=#{oldest}&limit=1&types[]=favourite") |> json_response(200)
    assert [group] = result["notification_groups"]
    assert group["most_recent_notification_id"] == middle
  end

end
