defmodule Bonfire.Social.LikesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Likes, Posts, FeedActivities}
  alias Bonfire.Me.Fake

  test "like works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

    assert {:ok, %{edge: edge}} = Likes.like(me, post)
    # IO.inspect(activity)
    assert edge.subject_id == me.id
    assert edge.object_id == post.id
  end

  test "can check if I like something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(me, post)

    assert true == Likes.liked?(me, post)
  end

  test "can check if I did not like something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")

    assert false == Likes.liked?(me, post)
  end

  test "can unlike something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(me, post)

    Likes.unlike(me, post)
    assert false == Likes.liked?(me, post)
  end

  test "can list my likes" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(me, post)

    assert %{edges: [fetched_liked]} = Likes.list_my(me)
    # debug(fetched_liked)

    assert fetched_liked.edge.object_id == post.id
  end

  test "can list something's likers" do
    me = Fake.fake_user!("me!")
    someone = Fake.fake_user!("someone")
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(me, post)
    assert {:ok, like2} = Likes.like(someone, post)

    assert %{edges: fetched_liked} = Likes.list_of(post, me)

    assert Enum.count(fetched_liked, &(&1.edge.object_id == post.id)) == 2
  end

  test "can list someone else's likes" do
    me = Fake.fake_user!("me!")
    someone = Fake.fake_user!("someone")
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(someone, post)
    # debug( Likes.list_by(someone, me))
    assert %{edges: [fetched_liked]} = Likes.list_by(someone, me)

    assert fetched_liked.edge.object_id == post.id
  end

  test "see a like of something I posted in my notifications" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}

    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "public")
    assert {:ok, like} = Likes.like(someone, post)

    assert %{edges: [fetched_liked]} = FeedActivities.feed(:notifications, me)

    assert fetched_liked.activity.object_id == post.id
  end

end
