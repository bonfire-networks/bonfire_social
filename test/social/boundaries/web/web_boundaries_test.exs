defmodule Bonfire.Social.WebBoundariesTest do
  use Bonfire.Social.DataCase, async: true
  import Bonfire.Boundaries.Debug
  import Phoenix.LiveViewTest
  alias Bonfire.Me.Fake
  alias Bonfire.Social.{Posts, Follows, Likes, Boosts}
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Boundaries
  # import Plug.Conn
  # import Phoenix.ConnTest
  # @endpoint MyEndpoint

  test "creating a post with a 'public' boundary and verify that all users can see and interact with it", %{conn: conn} do
    account = fake_account!()
    # Given a user
    alice = fake_user!(account)
    # And another user that I follow
    bob = fake_user!(account)
    Follows.follow(alice, bob)
    # When I login as Alice
    conn = conn(user: alice, account: account)
    # And bob creates a post with a 'public' boundary
    attrs = %{
      post_content: %{
        html_body: "<p>epic html message</p>",
        boundary: "public"
      }
    }
    {:ok, view, html} = live(conn, "/feed")

    assert {:ok, post} = Posts.publish(current_user: bob, post_attrs: attrs)


  end

  test "creating a post with a 'local' boundary and verify that only users from that instance can see and interact with it." do

  end

  test "creating a post with a 'mention' boundary and verify that only mentioned users can see and interact with it." do

  end

  test "Test creating a post with a 'custom' boundary and verify that only specified users or circles can see and interact with it according to their assigned roles." do

  end

  test "Test adding a user with a 'see' role and verify that the user can see the post but not interact with it." do

  end

  test "adding a user with a 'read' role and verify that the user can read the post's content but not interact with it." do

  end

  test "adding a user with an 'interact' role and verify that the user can like and boost the post." do

  end

  test "adding a user with a 'participate' role and verify that the user can engage in the post's activities and discussions." do

  end

  test "adding a user with a 'caretaker' role and verify that the user can delete the post" do

  end

  test "adding a user with a 'none' role and verify that the user cannot see or interact with the post in any way." do

  end

  test "creating a post with a circle, and verify that only users within the circle can access the post according to their assigned roles." do

  end

  test "creating a post with a custom boundary, and verify that only users within the boundary can access the post according to their assigned roles." do

  end

end
