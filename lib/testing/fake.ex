defmodule Bonfire.Social.Fake do
  import Bonfire.Common.Simulation
  import Bonfire.Me.Fake
  alias Bonfire.Common.Utils
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  def fake_post!(user, boundary \\ nil, attrs \\ nil) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs:
          attrs ||
            %{
              post_content: %{
                name: title(),
                # summary: summary(),
                html_body: markdown()
              }
            },
        boundary: boundary || "public",
        debug: true,
        crash: true
      )

    post
  end

  def fake_comment!(user, reply_to, boundary \\ nil, attrs \\ nil) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs:
          attrs ||
            %{
              reply_to_id: Utils.ulid(reply_to),
              post_content: %{
                summary: "summary",
                name: "name",
                html_body: "<p>epic html message</p>"
              }
            },
        boundary: boundary || "public",
        debug: true,
        crash: true
      )

    post
  end

  def fake_remote_user!() do
    {:ok, user} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()
    user
  end

  @username "test"

  def fake_follow!() do
    me = fake_user!(@username)
    followed = fake_user!()
    {:ok, follow} = Follows.follow(me, followed)

    follow
  end

  def fake_incoming_follow!() do
    me = fake_remote_user!()
    followed = fake_user!(@username)
    {:ok, follow} = Follows.follow(me, followed)

    follow
  end

  def fake_outgoing_follow!() do
    me = fake_user!(@username)
    followed = fake_remote_user!()
    {:ok, follow} = Follows.follow(me, followed)

    follow
  end
end
