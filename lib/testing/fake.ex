defmodule Bonfire.Social.Fake do
  import Bonfire.Common.Simulation
  import Bonfire.Me.Fake
  # alias Bonfire.Common.Utils
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Common
  alias Common.Types

  def fake_remote_user!() do
    {:ok, user} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()
    user
  end
end
