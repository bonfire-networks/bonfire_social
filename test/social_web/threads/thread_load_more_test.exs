defmodule Bonfire.Social.Threads.LoadMoreTest do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.{Boosts, Likes, Follows, Posts}


  describe "Load More in Threads" do

    test "As a user I dont want to see the load more button if there are less than 11 replies" do
      total_posts = 10
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{to_circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, op} = Posts.publish(alice, attrs)
      attrs = Map.merge(attrs, %{reply_to: op.id})

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/discussion/#{op.id}"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "#load_more") == []
      assert Enum.count(Floki.find(doc, "#replies  > .reply")) == total_posts
    end

    test "As a user I want to see the load more button if there are more than 11 replies" do
      total_posts = 11
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{to_circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, op} = Posts.publish(alice, attrs)
      attrs = Map.merge(attrs, %{reply_to: op.id})

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/discussion/#{op.id}"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "#load_more") != []
    end

    test "As a user when I click on load more I want to see next replies below the others (using LiveView websocket)" do
      total_posts = 15
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{to_circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      assert {:ok, op} = Posts.publish(alice, attrs)
      attrs = Map.merge(attrs, %{reply_to: op.id})

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/discussion/#{op.id}"
      {view, doc} = floki_live(conn, next)

      more_doc = view
      |> element("#load_more")
      |> render_click()
      # |> IO.inspect()

      # FIXME: the extra activities are being sent via pubsub, need to figure out how to test that

      assert Enum.count(Floki.find(more_doc, "#replies  > .reply")) == total_posts

    end

    test "As a user when I click on load more I want to see next replies even without JavaScript (using HTTP)" do
      total_posts = 15
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)

      attrs = %{to_circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}
      assert {:ok, op} = Posts.publish(alice, attrs)
      attrs = Map.merge(attrs, %{reply_to: op.id})

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, post_attrs(n, attrs))
      end

      conn = conn(user: bob, account: account2)
      next = "/discussion/#{op.id}"
      {view, doc} = floki_live(conn, next)
      assert [load_more_query_string] = Floki.attribute(doc, "#load_more a", "href")

      url = "/discussion/#{op.id}"<>load_more_query_string
      IO.inspect(url)
      conn = get(conn, url)
      more_doc = floki_response(conn) #|> IO.inspect
      assert Enum.count(Floki.find(more_doc, "#replies  > .reply")) == total_posts

    end


  end


end
