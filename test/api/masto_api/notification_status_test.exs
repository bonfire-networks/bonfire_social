defmodule Bonfire.Social.API.NotificationStatusTest do
  use Bonfire.Social.MastoApiCase, async: false

  @moduletag :masto_api
  @moduletag capture_log: true

  import Bonfire.Common.Testing, only: [count_queries: 1]

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    author = Bonfire.Me.Fake.fake_user!(account)
    reactor = Bonfire.Me.Fake.fake_user!()

    {:ok,
     author: author, reactor: reactor, conn: masto_api_conn(conn, user: author, account: account)}
  end

  for {action, type} <- [{:like, "favourite"}, {:boost, "reblog"}] do
    test "#{type} notification preserves the original author and status", context do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: context.author,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
          boundary: "public"
        )

      case unquote(action) do
        :like -> assert {:ok, _} = Bonfire.Social.Likes.like(context.reactor, post)
        :boost -> assert {:ok, _} = Bonfire.Social.Boosts.boost(context.reactor, post)
      end

      notifications = context.conn |> get("/api/v1/notifications") |> json_response(200)
      notification = Enum.find(notifications, &(&1["type"] == unquote(type)))
      assert notification
      assert notification["account"]["id"] == context.reactor.id
      assert notification["status"]["account"]["id"] == context.author.id
      status = context.conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
      assert notification["status"]["content"] == status["content"]
      assert notification["status"]["created_at"] == status["created_at"]

      assert Map.take(notification["status"], [
               "favourites_count",
               "reblogs_count",
               "replies_count",
               "visibility"
             ]) ==
               Map.take(status, [
                 "favourites_count",
                 "reblogs_count",
                 "replies_count",
                 "visibility"
               ])

      detail =
        context.conn |> get("/api/v1/notifications/#{notification["id"]}") |> json_response(200)

      assert detail["status"]["account"]["id"] == context.author.id
      timeline = context.conn |> get("/api/v1/timelines/home") |> json_response(200)

      entry =
        Enum.find(timeline, &(&1["id"] == post.id or get_in(&1, ["reblog", "id"]) == post.id))

      assert entry
      original = entry["reblog"] || entry
      assert original["account"]["id"] == context.author.id

      assert Map.take(original, ["content", "favourites_count", "reblogs_count", "replies_count"]) ==
               Map.take(status, ["content", "favourites_count", "reblogs_count", "replies_count"])
    end
  end

  test "poll reaction status contains its author and poll data", context do
    status =
      context.conn
      |> post("/api/v1/statuses", %{
        "status" => Faker.Lorem.sentence(),
        "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}
      })
      |> json_response(200)

    {:ok, question} = Bonfire.Poll.Questions.read(status["id"], current_user: context.reactor)
    [choice | _] = question.choices

    assert {:ok, _} =
             Bonfire.Poll.Votes.vote(context.reactor, question, [
               %{choice_id: choice.id, weight: 1}
             ])

    assert {:ok, _} = Bonfire.Social.Likes.like(context.reactor, question)

    notification =
      context.conn
      |> get("/api/v1/notifications")
      |> json_response(200)
      |> Enum.find(&(get_in(&1, ["status", "id"]) == status["id"]))

    assert notification
    assert notification["status"]["account"]["id"] == context.author.id
    assert notification["status"]["poll"]["id"] == status["id"]
    assert length(notification["status"]["poll"]["options"]) == 2
    timeline = context.conn |> get("/api/v1/timelines/home") |> json_response(200)
    poll_status = Enum.find(timeline, &(&1["id"] == status["id"]))
    assert poll_status
    assert poll_status["account"]["id"] == context.author.id
  end

  test "mention content uses the same rendering as the opened status", context do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: context.reactor,
        post_attrs: %{
          post_content: %{html_body: "@#{context.author.character.username} **Hello**"}
        },
        boundary: "public"
      )

    notification =
      context.conn
      |> get("/api/v1/notifications")
      |> json_response(200)
      |> Enum.find(&(get_in(&1, ["status", "id"]) == post.id))

    assert notification
    status = context.conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    assert notification["status"]["content"] == status["content"]
    assert notification["status"]["content"] =~ "<strong>Hello</strong>"
    refute notification["status"]["content"] =~ "[@"
  end

  test "a page's statuses come with the notifications, not one read each", context do
    Process.put([:bonfire, :default_pagination_limit], 20)
    liked_post = liked_and_mentioned(context)

    # the viewer's own interaction still shows on the status, now read for the whole page at once
    assert {:ok, _} = Bonfire.Social.Likes.like(context.author, liked_post)

    favourite =
      context.conn
      |> get("/api/v1/notifications")
      |> json_response(200)
      |> Enum.find(&(&1["type"] == "favourite" and &1["status"]["id"] == liked_post.id))

    assert favourite["status"]["favourited"] == true
    assert favourite["status"]["favourites_count"] == 2

    queries_for = fn path ->
      {response, queries} = count_queries(fn -> get(context.conn, path) end)
      assert json_response(response, 200) != []
      queries
    end

    v1_for_one = queries_for.("/api/v1/notifications")
    v2_for_one = queries_for.("/api/v2/notifications")

    liked_and_mentioned(context)
    liked_and_mentioned(context)

    assert queries_for.("/api/v1/notifications") == v1_for_one
    assert queries_for.("/api/v2/notifications") == v2_for_one
  end

  # one post of the author's liked by the reactor, and one of the reactor's mentioning the author: two notifications, each about a distinct status
  defp liked_and_mentioned(context) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: context.author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    assert {:ok, _} = Bonfire.Social.Likes.like(context.reactor, post)

    assert {:ok, _} =
             Bonfire.Posts.publish(
               current_user: context.reactor,
               post_attrs: %{
                 post_content: %{html_body: "@#{context.author.character.username} hi"}
               },
               boundary: "public"
             )

    post
  end

  test "outsider cannot read another account's notification detail", context do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: context.author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    {:ok, like} = Bonfire.Social.Likes.like(context.reactor, post)
    outsider_account = Bonfire.Me.Fake.fake_account!()
    outsider = Bonfire.Me.Fake.fake_user!(outsider_account)

    context.conn
    |> masto_api_conn(user: outsider, account: outsider_account)
    |> get("/api/v1/notifications/#{like.id}")
    |> response(404)
  end
end
