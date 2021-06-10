defmodule Bonfire.Social.PostsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Me.Fake

  test "creation works" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)
    # activity = fp.activity
    # post = activity.object
    # IO.inspect(activity)
    assert String.contains?(post.post_content.html_body, "epic html message")
    assert post.post_content.name == "name"
    assert post.post_content.summary == "summary"
    assert post.created.creator_id == user.id
  end

  test "listing by creator" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    attrs_2 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 2</p>"}}
    attrs_3 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 3</p>"}}
    user = Fake.fake_user!()
    assert {:ok, _} = Posts.publish(user, attrs_1)
    assert {:ok, _} = Posts.publish(user, attrs_2)
    assert {:ok, _} = Posts.publish(user, attrs_3)
    assert %{entries: posts} = Posts.list_by(user.id, user)
    assert length(posts) == 3
  end

  test "get / read a post" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs_1)
    assert {:ok, read} = Posts.read(post.id, user)
    assert post.id == read.id
  end
end
