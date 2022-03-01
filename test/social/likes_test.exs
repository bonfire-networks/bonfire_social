defmodule Bonfire.Social.LikesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Likes, Posts, FeedActivities}
  alias Bonfire.Me.Fake

  test "like works" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, %{edge: edge}} = Likes.like(alice, post)
    # debug(activity)
    assert edge.subject_id == alice.id
    assert edge.object_id == post.id
  end

  test "can check if I like something" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(alice, post)
    assert true == Likes.liked?(alice, post)
  end

  test "can check if I did not like something" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert false == Likes.liked?(alice, post)
  end

  test "can unlike something" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(alice, post)
    Likes.unlike(alice, post)
    assert false == Likes.liked?(alice, post)
  end

  test "can list my likes" do
    alice = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(alice, post)
    assert %{edges: [fetched_liked]} = Likes.list_my(alice)
    # debug(fetched_liked)
    assert fetched_liked.edge.object_id == post.id
  end

  test "can list the likers of something" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(alice, post)
    assert {:ok, like2} = Likes.like(bob, post)
    assert %{edges: fetched_liked} = Likes.list_of(post, alice)
    assert Enum.count(fetched_liked, &(&1.edge.object_id == post.id)) == 2
  end

  test "can list someone else's likes" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!("bob")
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(bob, post)
    # debug( Likes.list_by(bob, alice))
    assert %{edges: [fetched_liked]} = Likes.list_by(bob, alice)
    assert fetched_liked.edge.object_id == post.id
  end

  test "see a like of something I posted in my notifications" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}
    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(bob, post)
    assert %{edges: [fetched_liked]} = FeedActivities.feed(:notifications, alice)
    assert fetched_liked.activity.object_id == post.id
  end

end
