defmodule Bonfire.Social.PostPostsTest do

  use Bonfire.DataCase, async: true
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Users.Boundaries
  alias Bonfire.Repo


  test "creating & then reading my own post works" do
    user = fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}

    assert {:ok, activity} = Posts.publish(user, attrs)
    assert String.contains?(activity.post.post_content.html_body, "epic html message")
    assert activity.post.post_content.name == "name"

    assert {:ok, post} = Posts.read(activity.post.id, user)
    assert "name" == post.activity.object_post_content.name

  end


  test "cannot read posts which I am not permitted to see" do

    user = fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, activity} = Posts.publish(user, attrs)
    assert activity.post.post_content.name == "name"

    me = fake_user!()
    assert {:error, :not_found} = Posts.read(activity.post.id, me)

  end

  test "creating & then seeing my own post in feeds works" do
    user = fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}

    assert {:ok, activity} = Posts.publish(user, attrs)
    assert activity.post.post_content.name == "name"

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %Paginator.Page{entries: activities} = FeedActivities.feed(feed_id, user)
    assert feed_entry = List.first(activities)
    assert "name" == feed_entry.activity.object_post_content.name

  end

  test "cannot see post I'm not allowed to see in feed" do
    user = fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}

    assert {:ok, activity} = Posts.publish(user, attrs)
    assert activity.post.post_content.name == "name"

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    me = fake_user!()
    assert %Paginator.Page{entries: activities} = FeedActivities.feed(feed_id, me)
    assert activities == []

  end
end
