defmodule Bonfire.Social.Activities.LikePost.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Follows


  describe "like a post" do

    test "works" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs, "local")

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element("[data-id='like_action']")
      # |> IO.inspect
      |> render_click()
      |> Floki.text() =~ "Liked (1)"

      assert true == Likes.liked?(someone, post)

    end

    test "shows the right number of likes" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs, "local")

      assert {:ok, like} = Likes.like(fake_user!(), post)
      assert {:ok, like} = Likes.like(fake_user!(), post)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert view
      |> element("[data-id='like_action']")
      |> render()
      # |> IO.inspect
      |> Floki.text() =~ "Liked (2)"

      assert view
      |> element("[data-id='like_action']")
      |> render_click()
      |> Floki.text() =~ "Liked (3)"

      assert true == Likes.liked?(someone, post)

    end

  end

  describe "unlike a post" do

    test "works" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs, "local")

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      assert {:ok, like} = Likes.like(someone, post)
      assert true == Likes.liked?(someone, post)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element(".feed button.like")
      |> render_click()
      |> Floki.text() =~ "Like"

      assert false == Likes.liked?(someone, post)

    end

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
    attrs = %{post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post/p>"}}

    assert {:ok, post} = Posts.publish(alice, attrs, "public")
    assert {:ok, boost} = Likes.like(bob, post)

    conn = conn(user: bob, account: account2)
    next = "/home"
    {view, doc} = floki_live(conn, next)
    assert doc
      |> Floki.find("[data-id=feed]  > article")
      |> List.last
      |> Floki.text =~ "Like (1)"
  end

end
