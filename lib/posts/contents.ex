defmodule Bonfire.Social.Contents do
  alias Bonfire.Data.Content
  alias Pointers.Changesets
  alias Ecto.Changeset
  import Ecto.Query

  defp repo(), do: Application.get_env(:bonfire_social, :repo_module)

  def create(attrs) do
    create_changeset(%Content{}, attrs)
    |> repo().insert()
  end

  def create_changeset(content \\ %Content{}, attrs) do
    Content.changeset(content, attrs)
  end
end
