defmodule Bonfire.Social.Feeds.Instance.Test do

  use Bonfire.Social.ConnCase, async: true
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  describe "show" do

    test "not logged in" do
      conn = conn()
      conn = get(conn, "/local")
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

      doc = floki_response(conn)
      main = Floki.find(doc, "main") # |> IO.inspect
      # assert redirected_to(conn) =~ "/login"
      assert [_] = Floki.find(doc, "[id='#{feed_id}']")
    end

    test "with account" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(account: account)
      next = "/local"
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, "[id='#{feed_id}']")
    end

    test "with user" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/local"
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, "[id='#{feed_id}']")
    end


    test "my own posts in instance feed (with local preset selected)" do
      account = fake_account!()
      user = fake_user!(account)
      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "local")
      assert post.post_content.name =~ "test post name"

      conn = conn(user: user, account: account)
      next = "/local"
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "[id='#{feed_id}']")
      assert Floki.text(feed) =~ "test post name"
    end

    test "local posts from people I am not following in instance feed (if local preset selected)" do
      user = fake_user!()
      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "local")
      assert post.post_content.name =~ "test post name"

      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/local"
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "[id='#{feed_id}']")
      assert Floki.text(feed) =~ "test post name"

    end

  end

  describe "DO NOT show" do

    test "posts I'm NOT allowed to see in instance feed" do
      account = fake_account!()
      user = fake_user!(account)

      account2 = fake_account!()
      user2 = fake_user!(account2)
      Follows.follow(user2, user)

      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs)
      assert post.post_content.name =~ "test post name"

      conn = conn(user: user2, account: account2)
      next = "/local"
      feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "[id='#{feed_id}']")
      refute Floki.text(feed) =~ "test post name"
    end
  end

end
