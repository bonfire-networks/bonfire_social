defmodule Bonfire.Social.PostsTest do
  use Bonfire.DataCase
  use Bonfire.Common.Utils

  alias Bonfire.Social.{FeedActivities, Posts}
  alias Bonfire.Me.Fake
  use Bonfire.Common.Utils

  test "creation works" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} =
      Posts.publish(current_user: user, post_attrs: attrs, boundary: "public", debug: true, crash: true)
    assert String.contains?(post.post_content.html_body, "epic html message")
    assert post.post_content.name =~ "name"
    assert post.post_content.summary =~ "summary"
    assert post.created.creator_id == user.id
  end

  test "read a public post, ignoring boundaries" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} =
      Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")
    # debug(post, "post")
    assert {:ok, read} = Posts.read(post.id, skip_boundary_check: true)
    assert post.id == read.id
  end

  test "read a public post as a guest" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} =
      Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")
    # debug(post, "post")
    assert {:ok, read} = Posts.read(post.id)
    assert post.id == read.id
  end

  test "read my own public post" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} =
      Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")
    # post = Bonfire.Repo.preload(post, [:caretaker, controlled: [acl: [:named, :caretaker]]])
    # user = Bonfire.Repo.preload(user, encircles: [circle: [:named]])
    # debug(post, "post")
    # debug(user, "user")
    assert {:ok, read} = Posts.read(post.id, current_user: user)
    # assert post.id == read.id
  end

  test "listing by creator, ignoring boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    attrs_2 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 2</p>"}}
    attrs_3 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 3</p>"}}
    user = Fake.fake_user!()
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_1, boundary: "public")
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_2, boundary: "public")
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_3, boundary: "public")
    assert %{edges: posts} = Posts.list_by(user, skip_boundary_check: true)
    # debug(posts, "posts")
    assert length(posts) == 3
  end

  test "listing by creator, querying with boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    attrs_2 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 2</p>"}}
    attrs_3 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 3</p>"}}
    user = Fake.fake_user!()
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_1, boundary: "public")
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_2, boundary: "public")
    assert {:ok, _} = Posts.publish(current_user: user, post_attrs: attrs_3, boundary: "public")
    assert %{edges: posts} = Posts.list_by(user, current_user: user)
    assert length(posts) == 3
  end

  test "when i post, it appears in my outbox feed" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert %{edges: edges} = FeedActivities.feed(:outbox, current_user: alice)
    assert [post2] = edges
    assert post2.id == post.id
  end

  test "when i post, it does not appear in my notifications feed" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert %{edges: []} = FeedActivities.feed(:notifications, alice)
  end

  test "when i post, it does not appear in my inbox feed" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert %{edges: []} = FeedActivities.feed(:inbox, current_user: alice)
  end

end
