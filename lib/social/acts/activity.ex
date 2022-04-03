defmodule Bonfire.Social.Acts.Activity do

  alias Bonfire.{Epics.Epic, Epics}
  alias Bonfire.Social.{Activities, Feeds}
  alias Ecto.Changeset
  import Epics
  import Where, only: [warn: 2]
  use Arrows

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = epic.assigns[:options][:current_user]
    verb = Keyword.get(epic.assigns[:options], :verb, :create)
    cond do
      epic.errors != [] ->
        debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        debug(epic, act, on, "Skipping due to `on` option")
        epic
      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to missing current_user")
        epic
      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic
      changeset.action not in [:insert, :delete] ->
        debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action == :insert ->
        boundary = epic.assigns[:options][:boundary]
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        feeds_key = Keyword.get(act.options, :feeds, :feed_ids)

        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        feed_ids = Feeds.target_feeds(changeset, current_user, boundary)

        debug(epic, act, "activity", "Casting")
        changeset
        |> Activities.cast(verb, current_user, feed_ids: feed_ids, boundary: boundary)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(..., feeds_key, feed_ids)

      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

end
