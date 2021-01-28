defmodule Bonfire.Social.Contents do
  alias Bonfire.Data.Social.PostContent
  alias Pointers.Changesets
  alias Ecto.Changeset
  import Ecto.Query
  import Bonfire.Me.Integration

  def create(attrs) do
    common_changeset(attrs)
    |> repo().insert()
  end

  def common_changeset(content \\ %PostContent{}, attrs) do
    PostContent.changeset(content, attrs)
  end
end
