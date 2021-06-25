defmodule Bonfire.Social.Feeds.Notifications.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "show" do

    test "with account" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(account: account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, ".feed")
    end

    test "with user" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, ".feed")
    end

    test "follows in my feed" do
      account = fake_account!()
      user = fake_user!(account)
      # TODO
    end

    test "replies I'm allowed to see in my notifications" do
      account = fake_account!()
      user = fake_user!(account)

      account2 = fake_account!()
      user2 = fake_user!(account2)
      Follows.follow(user2, user)

      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}
      # TODO

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"

      conn = conn(user: user2, account: account2)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ "test post name"
    end

  end

  describe "DO NOT show" do

      test "not logged in" do
      conn = conn()
      conn = get(conn, "/notifications")
      assert redirected_to(conn) =~ "/login"
    end

    test "replies from people I am not following in my notifications" do
      user = fake_user!()
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"
      # TODO

      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      refute Floki.text(feed) =~ "test post name"

    end

    test "replies I'm NOT allowed to see in my notifications" do
      account = fake_account!()
      user = fake_user!(account)

      account2 = fake_account!()
      user2 = fake_user!(account2)
      Follows.follow(user2, user)

      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}
      # TODO

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"

      conn = conn(user: user2, account: account2)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      refute Floki.text(feed) =~ "test post name"
    end
  end
end
