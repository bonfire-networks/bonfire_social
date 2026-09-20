defmodule Bonfire.Social.Acts.Activity do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that translates creates an activity for a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `verb` - indicates what kind of activity we're creating, default: `:create`
    * `current_user` - self explanatory
  """

  alias Bonfire.Epics.Epic
  alias Bonfire.Epics

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Feeds

  alias Ecto.Changeset
  import Epics
  use Bonfire.Common.E
  import Untangle
  use Arrows
  alias Bonfire.Common.Utils

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = Bonfire.Common.Utils.current_user_or_id(epic.assigns[:options])
    verb = epic.assigns[:verb] || Keyword.get(epic.assigns[:options], :verb, :create)

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to missing current_user")
        epic

      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic

      changeset.action not in [:insert, :delete] ->
        maybe_debug(
          epic,
          act,
          changeset.action,
          "Skipping, no matching action on changeset"
        )

        epic

      changeset.action in [:insert] ->
        boundary = epic.assigns[:options][:boundary]
        boundary_name = Bonfire.Boundaries.Presets.preset_name(boundary, true)

        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        feeds_key = Keyword.get(act.options, :feeds, :feed_ids)

        notify_feeds_key = Keyword.get(act.options, :notify_feeds, :notify_feeds)

        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})

        notify =
          Feeds.reply_and_or_mentions_to_notify(
            current_user,
            boundary_name,
            e(changeset.changes, :post_content, :changes, :mentions, []),
            e(epic.assigns, :reply_to, :created, :creator, nil) ||
              e(attrs, :reply_to, :created, :creator, nil),
            e(attrs, :to_circles, [])
          )

        feed_ids =
          Feeds.feed_ids_to_publish(
            current_user,
            boundary_name,
            epic.assigns,
            notify[:notify_feeds]
          )

        maybe_debug(epic, act, "activity", "Casting")

        # `enqueue_notify: false` in this Act's options means a later Act notifies after the transaction commits, where a failure can be reported to whoever caused it. An Act inside a parallel group cannot see what runs later (the runner empties `next` for the group), so this is declared in the epic rather than detected, and the assign is how the later Act knows the work is its
        enqueue_notify? = Keyword.get(act.options, :enqueue_notify, true)

        changeset
        |> Activities.cast(verb, current_user,
          feed_ids: feed_ids,
          # who is notified and which feeds that is, both already worked out just above, so the funnel doesn't have to ask again
          notifications_class: e(notify, :notify_feeds, []),
          notify_users: e(notify, :notify_users, []),
          enqueue_notify: enqueue_notify?,
          boundary: boundary
        )
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(..., feeds_key, feed_ids)
        |> Epic.assign(..., notify_feeds_key, notify)
        |> Epic.assign(..., :notify_inline, !enqueue_notify?)

      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end
end
