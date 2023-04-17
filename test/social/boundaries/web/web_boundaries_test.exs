defmodule Bonfire.Social.WebBoundariesTest do
  use Bonfire.Social.DataCase, async: true
  import Bonfire.Boundaries.Debug
  import Phoenix.LiveViewTest
  alias Bonfire.Me.Fake
  alias Bonfire.Social.{Posts, Follows, Likes, Boosts}
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Boundaries
  import Plug.Conn
  import Phoenix.ConnTest
  # import Plug.Conn
  # import Phoenix.ConnTest
  # @endpoint MyEndpoint
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  test "creating a post with boundaries public and verify that all users can see and interact with it" do
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

    {:ok, post} = Posts.publish(current_user: bob, post_attrs: attrs)

    {:ok, view, _html} = live(conn, "/feed")
    IO.inspect(view)
    # get the id of the <article> element
    id = element(view, "#post-#{post.id}") |> Floki.attribute("id") |> debug("id is this one:")

    # assign the created activity to element
    # activity = element(view, "#activity-#{post.id}")

    # Then I should see the post in my feed
    assert view.assigns.feed_posts |> Enum.any?(&(&1.id == post.id))
    # Then I should like the post
    # Then I should boost the post
    # Then I should comment on the post
  end

  # test "creating a post with a 'local' boundary and verify that only users from that instance can see and interact with it." do

  # end

  # test "creating a post with a 'mention' boundary and verify that only mentioned users can see and interact with it." do

  # end

  # test "Test creating a post with a 'custom' boundary and verify that only specified users or circles can see and interact with it according to their assigned roles." do

  # end

  # test "Test adding a user with a 'see' role and verify that the user can see the post but not interact with it." do

  # end

  # test "adding a user with a 'read' role and verify that the user can read the post's content but not interact with it." do

  # end

  # test "adding a user with an 'interact' role and verify that the user can like and boost the post." do

  # end

  # test "adding a user with a 'participate' role and verify that the user can engage in the post's activities and discussions." do

  # end

  # test "adding a user with a 'administer' role and verify that the user can delete the post" do

  # end

  # test "adding a user with a 'none' role and verify that the user cannot see or interact with the post in any way." do

  # end

  # test "creating a post with a circle, and verify that only users within the circle can access the post according to their assigned roles." do

  # end

  # test "creating a post with a custom boundary, and verify that only users within the boundary can access the post according to their assigned roles." do

  # end
end
