defmodule Bonfire.Social.Acts.MeiliSearch.Prepare do
  @moduledoc """

  An Act that translates a post or changeset into some jobs for the
  meilisearch index worker. Handles creation, update and delete

  Act Options:
    * `on` - key in assigns to find the post, default: `:post`
    * `as` - key in assigns to assign indexable object, default: `:post_index`
  """

  import Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.Acts.MeiliSearch.Queue
  alias Bonfire.Social.{Integration, Posts}
  alias Bonfire.Data.Social.Activity
  alias Ecto.Changeset

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    # current_user = epic.assigns[:options][:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
        epic
      # not (is_struct(current_user) or is_binary(current_user)) ->
      #   Act.warn(current_user, "Skipping due to missing current_user")
      #   epic
      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic
      not changeset.valid? ->
        maybe_debug(epic, act, "changeset invalid", "Skipping")
        epic
      changeset.action not in [:insert, :update, :delete] ->
        maybe_debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action in [:insert, :update] ->
        maybe_debug(epic, act, changeset.action, "Queue for indexing")
        Queue.index(epic)
      changeset.action == :delete -> # TODO: deletion
        maybe_debug(epic, act, changeset.action, "Queue for deletion")
        Queue.unindex(epic)
    end
  end

end
