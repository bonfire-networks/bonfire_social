defmodule Bonfire.Social.Feeds.LoadMoreTest do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.{Boosts, Likes, Follows, Posts}


  describe "Load More in Feeds" do

    test "As a user I dont want to see the load more button if there are less than 11 activities" do
      total_posts = 10
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs, "public")
      end

      conn = conn(user: bob, account: account2)
      next = "/home"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "[data-id=load_more]") == []
      assert Enum.count(Floki.find(doc, "[data-id=feed]  > article")) == total_posts
    end

    test "As a user I want to see the load more button if there are more than 11 activities" do
      total_posts = 15
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs, "public")
      end

      conn = conn(user: bob, account: account2)
      next = "/home"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "[data-id=load_more]") != []
    end

    test "As a user when I click on load more I want to see next activities below the others (using LiveView websocket)" do
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

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs, "public")
      end

      conn = conn(user: bob, account: account2)
      next = "/home"
      {view, doc} = floki_live(conn, next)

      more_doc = view
      |> element("[data-id=load_more]")
      |> render_click()
      # |> Floki.find(".feed")
      # |> IO.inspect()

      # FIXME: the extra activities are being sent via pubsub, need to figure out how to test that

      assert Enum.count(Floki.find(more_doc, "[data-id=feed]  > article")) == total_posts

    end

    test "As a user when I click on load more I want to see next activities even without JavaScript (using HTTP)" do
      total_posts = 15
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, post_attrs(n), "public")
      end

      conn = conn(user: bob, account: account2)
      next = "/home"
      {view, doc} = floki_live(conn, next)
      assert [load_more_query_string] = Floki.attribute(doc, "[data-id=load_more] a", "href")

      url = "/home"<>load_more_query_string
      # IO.inspect(url)
      conn = get(conn, url)
      more_doc = floki_response(conn) #|> IO.inspect
      assert Enum.count(Floki.find(more_doc, "[data-id=feed]  > article")) == 5

    end


  end


end
