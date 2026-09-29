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

        reply_to = e(epic.assigns, :reply_to, nil) || e(attrs, :reply_to, nil)

        # the posts above a reply, from the thread's first post to the one it answers: a bell on any of them covers it, and the author's own bell on one of them covers what they write below it
        ancestors =
          if reply_to,
            do:
              e(changeset.changes, :replied, :changes, :path, nil) ||
                List.wrap(e(reply_to, :replied, :path, nil)) ++
                  [Bonfire.Common.Types.uid(reply_to)],
            else: []

        # known before the insert, so the author's bell on it can go in with it
        changeset = with_id(changeset)

        notify =
          Feeds.to_notify_of_this(
            current_user,
            boundary_name,
            e(changeset.changes, :post_content, :changes, :mentions, []),
            e(epic.assigns, :reply_to, :created, :creator, nil) ||
              e(attrs, :reply_to, :created, :creator, nil),
            e(attrs, :to_circles, []),
            # for whoever enabled a bell on them: the thread a reply is in (the parent's thread, or the parent itself when it is the thread's first post), and the groups a new post is in (which the Tag act, running before this one, has already checked the author may post in)
            thread_id:
              if(reply_to,
                do:
                  e(reply_to, :replied, :thread_id, nil) ||
                    e(reply_to, :replied, :thread, :id, nil) ||
                    Bonfire.Common.Types.uid(reply_to)
              ),
            ancestors: ancestors,
            in:
              Enum.map(
                List.wrap(epic.assigns[:categories_auto_boost]),
                &Bonfire.Common.Types.uid/1
              )
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
          wrote_above: e(notify, :wrote_above, []),
          enqueue_notify: enqueue_notify?,
          boundary: boundary
        )
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(..., feeds_key, feed_ids)
        |> Epic.assign(..., notify_feeds_key, notify)
        |> Epic.assign(..., :notify_inline, !enqueue_notify?)
        |> maybe_enable_thread_notifications(
          current_user,
          Changeset.get_field(changeset, :id),
          ancestors
        )

      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp with_id(changeset) do
    if Changeset.get_field(changeset, :id),
      do: changeset,
      else: Changeset.put_change(changeset, :id, Needle.ULID.generate())
  end

  # what the author writes enables notifications of the replies below it for them (`Bonfire.Notify.Bells.enable_thread_notifications_changeset/3` says when not), inserted in the same transaction, after the post it points at
  defp maybe_enable_thread_notifications(epic, author, object_id, ancestors) do
    case Utils.maybe_apply(
           Bonfire.Notify.Bells,
           :enable_thread_notifications_changeset,
           [author, object_id, ancestors],
           fallback_return: nil
         ) do
      %Changeset{} = changeset ->
        epic
        |> Epic.assign(:thread_notifications, changeset)
        |> Bonfire.Ecto.Acts.Work.add_after(:thread_notifications)

      _ ->
        epic
    end
  end
end
