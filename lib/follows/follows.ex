defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Follow
  import Bonfire.Me.Integration

  def follow(%User{} = follower, %{} = followed) do
    create_changeset(follower, followed)
    |> repo().insert()
  end

  def create_changeset(%{id: follower}, %{id: followed}) do
    Follow.changeset(%Follow{}, %{follower_id: follower, followed_id: followed})
  end
end
