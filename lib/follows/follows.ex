defmodule Bonfire.Social.Follows do
  alias CommonsPub.Users.User
  alias CommonsPub.Follows.Follow

  defp repo, do: Application.get_env(:bonfire_social, :repo_module)

  def create(%User{} = follower, followed) do
    create_changeset(follower, followed)
    |> repo().insert()
  end

  def create_changeset(follower, followed) do
    Follow.changeset(%Follow{}, %{follower_id: follower.id, followed_id: followed.id})
  end
end
