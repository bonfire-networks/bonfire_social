defmodule Bonfire.Social.Feeds.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.{Boosts, Likes, Follows, Posts}


  describe "Feeds UX" do
    test "As a user when I navigate on a feed I want to see the first 10 activities" do

      total_posts = 7
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert Enum.count(Floki.find(doc, "#feed_past  > article")) == total_posts

    end

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
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "#load_more") == []
    end

    test "As a user I want to see the load more button if there are more than 11 activities" do
      total_posts = 11
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>epic html message</p>"}}

      for n <- 1..total_posts do
        assert {:ok, post} = Posts.publish(alice, attrs)
      end

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert Floki.find(doc, "#load_more") != []
    end

    test "As a user when I click on load more I want to see next 10 activities below the others" do

    end


    test "As a user when I publish a new post I want to see it appearing at the beginning of the feed without refreshing the page" do

    end

    test "As a user I want to see the activity boundary" do

    end

    test "As a user I want to see the activity total replies" do
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post/p>"}}

      assert {:ok, post} = Posts.publish(alice, attrs)

      # Reply to the original post
      attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>reply to first post</p>"}, reply_to_id: post.id}
      assert {:ok, post_reply} = Posts.publish(bob, attrs_reply)

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert doc
        |> Floki.find("#feed_past  > article")
        |> List.last
        |> Floki.text =~ "Reply (1)"
    end

    test "As a user I want to see the activity total boosts" do
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post/p>"}}

      assert {:ok, post} = Posts.publish(alice, attrs)
      assert {:ok, boost} = Boosts.boost(bob, post)

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert doc
        |> Floki.find("#feed_past  > article")
        |> List.last
        |> Floki.text =~ "Boosted (1)"
    end

    test "As a user I want to see the activity total likes" do
      # Create alice user
      account = fake_account!()
      alice = fake_user!(account)
      # Create bob user
      account2 = fake_account!()
      bob = fake_user!(account2)
      # bob follows alice
      Follows.follow(bob, alice)
      attrs = %{circles: [:guest], post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post/p>"}}

      assert {:ok, post} = Posts.publish(alice, attrs)
      assert {:ok, boost} = Likes.like(bob, post)

      conn = conn(user: bob, account: account2)
      next = "/browse"
      {view, doc} = floki_live(conn, next)
      assert doc
        |> Floki.find("#feed_past  > article")
        |> List.last
        |> Floki.text =~ "Liked (1)"
    end

    test "As a user I want to see if I already boosted an activity" do

    end

    test "As a user I want to see if I already liked an activity" do

    end

    test "As a user I want to see the context a message is replying to" do

    end

    test "When I click the reply button, I want to navigate to the thread page" do

    end

    test "When I click the boost button, I want the boosted activity to appear in the timeline without refreshing" do

    end

    test "When I click the like button, I want to see the liked activity without refreshing" do

    end

    test "As a user I want to click over the user avatar or name and navigate to their own profile page" do

    end

    test "As a user I want to click over a user mention within an activity and navigate to their own profile page" do

    end

    test "As a user I want to click over a link that is part of an activity body and navigate to that link" do

    end

  end


end
