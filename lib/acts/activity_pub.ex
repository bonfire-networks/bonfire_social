defmodule Bonfire.Social.Acts.ActivityPub do
  @moduledoc """

  An Act that translates a post or changeset into some jobs for the
  AP publish worker. Handles creation, update and delete

  Act Options:
    * `on` - key in assigns to find the post, default: `:post`
    * `as` - key in assigns to assign indexable object, default: `:post_index`
  """

  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Data.Social.Post
  alias Bonfire.Social.Integration
  alias Ecto.Changeset
  import Epics
  import Untangle

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    object = epic.assigns[on]
    action = Keyword.get(epic.assigns[:options], :action, :insert)
    current_user = epic.assigns[:options][:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "ActivityPub: Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "ActivityPub: Skipping due to `on` option")
        epic
      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "ActivityPub: Skipping due to missing current_user")
        epic
      action in [:insert] ->
        maybe_debug(epic, act, action, "Queue for federated")
        Bonfire.Social.Integration.ap_push_activity(current_user.id, object)
      action in [:update] ->
        maybe_debug(epic, act, action, "Queue for federated")
        Bonfire.Social.Integration.ap_push_activity(current_user.id, object, :update)
      action == :delete -> # TODO: deletion
        maybe_debug(epic, act, action, "Queue for federated")
        Bonfire.Social.Integration.ap_push_activity(current_user.id, object, :delete)
      true ->
        maybe_debug(epic, act, action, "ActivityPub: Skipping due to unknown action")
        epic
    end
    epic
  end
end
