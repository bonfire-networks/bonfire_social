defmodule Bonfire.Social.API.BellNotificationsTest do
  @moduledoc """
  What a Mastodon client is told about a post that reached someone through a bell: a `status`, Mastodon's own type for "someone you turned on notifications for has posted", and not a `mention`, since the post doesn't name them.
  """
  use Bonfire.Social.MastoApiCase, async: false

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    reader_account = Bonfire.Me.Fake.fake_account!()
    reader = Bonfire.Me.Fake.fake_user!(reader_account)
    author = Bonfire.Me.Fake.fake_user!()

    {:ok,
     reader: reader,
     author: author,
     reader_conn: masto_api_conn(conn, user: reader, account: reader_account)}
  end

  test "a post from someone with a bell on is a status, not a mention", context do
    {:ok, _} = Bonfire.Notify.Bells.enable(context.reader, context.author)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: context.author,
        post_attrs: %{post_content: %{html_body: "news for whoever asked"}},
        boundary: "public"
      )

    # the positive first: the bell put it in the reader's notifications, so what the API does with it is the API's doing
    assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
             current_user: context.reader
           )

    notifications =
      context.reader_conn |> get("/api/v1/notifications") |> json_response(200)

    notification = Enum.find(notifications, &(get_in(&1, ["status", "id"]) == post.id))

    assert notification, "the bell brought the post"
    assert notification["type"] == "status"
    assert notification["account"]["id"] == context.author.id
  end

  # a reply to someone else's post sits in Other with bell posts, not under Replies, so a client is told about it the same way
  test "a reply in a thread with a bell on is a status, not a mention", context do
    {:ok, root} =
      Bonfire.Posts.publish(
        current_user: context.author,
        post_attrs: %{post_content: %{html_body: "a discussion"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Notify.Bells.enable(context.reader, root)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: Bonfire.Me.Fake.fake_user!(),
        post_attrs: %{post_content: %{html_body: "joining in"}, reply_to_id: root.id},
        boundary: "public"
      )

    assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, reply,
             current_user: context.reader
           )

    notification = notification_about(context.reader_conn, reply)

    assert notification, "the bell brought the reply"
    assert notification["type"] == "status"
  end

  # a reply is a mention only when it names the reader, as on Mastodon, which wouldn't notify one that doesn't
  test "a reply to the reader's own post that doesn't name them is a status", context do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: context.reader,
        post_attrs: %{post_content: %{html_body: "my own post"}},
        boundary: "public"
      )

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: context.author,
        post_attrs: %{post_content: %{html_body: "answering you"}, reply_to_id: post.id},
        boundary: "public"
      )

    notification = notification_about(context.reader_conn, reply)

    assert notification, "the reply reached its author's notifications"
    assert notification["type"] == "status"
  end

  defp notification_about(conn, post) do
    conn
    |> get("/api/v1/notifications")
    |> json_response(200)
    |> Enum.find(&(get_in(&1, ["status", "id"]) == post.id))
  end
end
