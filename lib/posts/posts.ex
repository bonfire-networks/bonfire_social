defmodule Bonfire.Social.Posts do
  alias Bonfire.Data.Social.Post
  alias Bonfire.Data.Identity.User
  alias Pointers.Changesets
  alias Ecto.Changeset
  import Ecto.Query

  defp repo, do: Application.get_env(:bonfire_social, :repo_module)

  def create(%User{} = user, attrs) do
    create_changeset(%Post{}, user, attrs)
    |> repo().insert
  end

  def create_changeset(post \\ %Post{}, %User{} = creator, attrs) do
    Post.changeset(post, attrs)
    |> Changeset.change(%{creator_id: creator.id})
    |> Changesets.cast_assoc(:content, attrs)
  end
end
