defmodule Bonfire.Social.Feeds.Instance.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  describe "show" do

    test "not logged in" do
      conn = conn()
      conn = get(conn, "/browse/instance")
      doc = floki_response(conn) #|> IO.inspect
      # assert redirected_to(conn) =~ "/login"
      assert [_] = Floki.find(doc, "#tab-instance")
    end

    test "with account" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(account: account)
      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, "#tab-instance")
    end

    test "with user" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, "#tab-instance")
    end


    test "my own posts in instance feed (if local circles selected)" do
      account = fake_account!()
      user = fake_user!(account)
      attrs = %{to_circles: [:local], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"

      conn = conn(user: user, account: account)
      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "#tab-instance")
      assert Floki.text(feed) =~ "test post name"
    end

    test "local posts from people I am not following in instance feed" do
      user = fake_user!()
      attrs = %{to_circles: [:local], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"

      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "#tab-instance")
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

      assert {:ok, post} = Posts.publish(user, attrs)
      assert post.post_content.name == "test post name"

      conn = conn(user: user2, account: account2)
      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "#tab-instance")
      refute Floki.text(feed) =~ "test post name"
    end
  end

end
