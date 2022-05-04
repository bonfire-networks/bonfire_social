defmodule Bonfire.Social.Fake do

  import Bonfire.Me.Fake
  alias Bonfire.Social.{Follows}

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
