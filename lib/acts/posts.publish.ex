defmodule Bonfire.Social.Acts.Posts.Publish do
  @moduledoc """
  Creates a changeset for publishing a post

  Epic Options:
    * `:current_user` - user that will create the post, required.
    * `:post_attrs` (configurable) - attrs to create the post from, required.
    * `:post_id` (configurable) - id to use for the created post (handy for creating
      activitypub objects with an id representing their reported creation time)

  Act Options:
    * `:id` - epic options key to find an id to force override with at, default: `:post_id`
    * `:as` - key to assign changeset to, default: `:post`.
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
  """

  alias Bonfire.Ecto.Acts.Work
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Social.Posts
  alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  # import Untangle

  # see module documentation
  @doc false
  def run(epic, act) do
    current_user = epic.assigns[:options][:current_user]

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(
          epic,
          act,
          current_user,
          "Skipping due to missing current_user"
        )

        epic

      true ->
        as = Keyword.get(act.options, :as, :post)
        id_key = Keyword.get(act.options, :id, :post_id)
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        id = epic.assigns[:options][id_key]
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        boundary = epic.assigns[:options][:boundary]

        maybe_debug(
          epic,
          act,
          attrs_key,
          "Assigning changeset to :#{as} using attrs"
        )

        # maybe_debug(epic, act, attrs, "Post attrs")
        if attrs == %{}, do: maybe_debug(act, attrs, "empty attrs")

        Posts.changeset(:create, attrs, current_user, boundary)
        |> Map.put(:action, :insert)
        |> maybe_overwrite_id(id)
        |> Epic.assign(epic, as, ...)
        |> Work.add(:post)
    end
  end

  defp maybe_overwrite_id(changeset, nil), do: changeset

  defp maybe_overwrite_id(changeset, id),
    do: Changeset.put_change(changeset, :id, id)
end
