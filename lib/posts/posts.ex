defmodule Bonfire.Social.Posts do
  alias Bonfire.Data.Social.Post
  alias Bonfire.Data.Identity.User
  alias Bonfire.Social.Contents
  # alias Pointers.Changesets
  alias Ecto.Changeset
  import Ecto.Query
  import Bonfire.Me.Integration

  @doc """
  Publish a post
  Usage: `Bonfire.Social.Posts.create(user, %{"post_content"=>%{"html_body"=>"hello"}})`
  """
  def create(%User{} = user, attrs) do
    create_changeset(user, attrs)
    |> repo().insert
  end

  def create_changeset(%User{} = creator, attrs) do
    attrs
    |> Map.merge(%{"created"=>%{"creator"=>creator, "creator_id"=>creator.id}})
    |> IO.inspect
    |> common_changeset()
    |> IO.inspect
  end

  def common_changeset(post \\ %Post{}, attrs) do
    Post.changeset(post, attrs)
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast_assoc(:post_content, [:required, with: &Contents.common_changeset/2])
  end
end
