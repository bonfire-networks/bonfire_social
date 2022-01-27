defmodule Bonfire.Social.Threads.RepliesTest do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.{Boosts, Likes, Follows, Posts}

  test "As a user I want to see the activity total replies" do
    # Create alice user
    account = fake_account!()
    alice = fake_user!(account)
    # Create bob user
    account2 = fake_account!()
    bob = fake_user!(account2)

    # bob follows alice
    Follows.follow(bob, alice)

    attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post</p>"}}
    assert {:ok, op} = Posts.publish(alice, attrs, "public")

    # Reply to the original post
    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>reply to first post</p>"}, reply_to_id: op.id}
    assert {:ok, post_reply} = Posts.publish(bob, attrs_reply, "public")

    conn = conn(user: bob, account: account2)
    next = "/home"
    {view, doc} = floki_live(conn, next)
    assert doc
      |> Floki.find("[data-id=feed]  > article")
      |> List.last
      |> Floki.text =~ "Replies (1)"
  end
end
