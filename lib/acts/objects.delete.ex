 defmodule Bonfire.Social.Acts.Objects.Delete do
  @moduledoc """
  Delete something with a changeset

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
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.Posts
  alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  import Where

  @doc false # see module documentation
  def run(epic, act) do
    current_account = epic.assigns[:options][:current_account]
    current_user = epic.assigns[:options][:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      not (is_struct(current_user) or is_binary(current_user) or is_struct(current_account) or is_binary(current_account)) ->
        maybe_debug(epic, act, [current_account: current_account, current_user: current_user], "Skipping due to missing current account or user")
        epic
      true ->
        as = Keyword.get(act.options, :as, :object)
        maybe_debug(epic, act, as, "Assigning changeset using object from")
        object = Keyword.get(epic.assigns[:options], as, %{})
        maybe_debug(epic, act, object, "Delete object")
        object
        |> Epic.assign(epic, as, ...)
        # |> Work.add(:object)
    end
  end


end
