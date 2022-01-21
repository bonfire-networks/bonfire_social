defmodule Bonfire.Social.PostsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Me.Fake
  use Bonfire.Common.Utils, only: [debug: 2]

  test "creation works" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs, "public")
    assert String.contains?(post.post_content.html_body, "epic html message")
    assert post.post_content.name =~ "name"
    assert post.post_content.summary =~ "summary"
    assert post.created.creator_id == user.id
  end

  test "get / read a post, ignoring boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs_1, "public")
    debug(post, "post")
    assert {:ok, read} = Posts.read(post.id, skip_boundary_check: true)
    assert post.id == read.id
  end

  test "get / read a post, querying with boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs_1, "public")
    assert {:ok, read} = Posts.read(post.id, current_user: user)
    assert post.id == read.id
  end

  test "listing by creator, ignoring boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    attrs_2 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 2</p>"}}
    attrs_3 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 3</p>"}}
    user = Fake.fake_user!()
    assert {:ok, _} = Posts.publish(user, attrs_1, "public")
    assert {:ok, _} = Posts.publish(user, attrs_2, "public")
    assert {:ok, _} = Posts.publish(user, attrs_3, "public")
    assert %{edges: posts} = Posts.list_by(user.id, skip_boundary_check: true)
    assert length(posts) == 3
  end

  test "listing by creator, querying with boundaries" do
    attrs_1 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 1</p>"}}
    attrs_2 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 2</p>"}}
    attrs_3 = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message 3</p>"}}
    user = Fake.fake_user!()
    assert {:ok, _} = Posts.publish(user, attrs_1, "public")
    assert {:ok, _} = Posts.publish(user, attrs_2, "public")
    assert {:ok, _} = Posts.publish(user, attrs_3, "public")
    assert %{edges: posts} = Posts.list_by(user.id, current_user: user)
    assert length(posts) == 3
  end


end
