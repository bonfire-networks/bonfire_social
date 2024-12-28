defmodule Bonfire.Social.Acts.Threaded do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that sets the thread and/or reply_to for a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `current_user` - self explanatory
  """

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Common.Utils
  alias Bonfire.Social.Threads
  alias Ecto.Changeset
  alias Needle.Changesets
  import Epics
  import Untangle
  use Bonfire.Common.E
  use Arrows
  alias Bonfire.Common
  alias Common.Types

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

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
        warn(changeset, "Skipping :#{on} due to missing changeset")
        epic

      changeset.action not in [:insert, :delete] ->
        maybe_debug(
          epic,
          act,
          changeset.action,
          "Skipping, no matching action on changeset"
        )

        epic

      changeset.action == :insert ->
        handle_insert(epic, act, on, changeset, current_user)

      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp handle_insert(epic, act, on, changeset, current_user) do
    # TODO: dedup with cast function in Threads
    # boundary = epic.assigns[:options][:boundary]
    attrs_key = Keyword.get(act.options, :attrs, :post_attrs)

    attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
    # |> debug("attrs")

    custom_thread = Threads.find_thread(attrs, current_user)

    thread_title = e(attrs, :name, nil)

    case Threads.find_reply_to(attrs, current_user) |> debug("find_reply_to") do
      {:ok, %{replied: %{thread_id: thread_id, thread: %{}}} = reply_to} ->
        # we are permitted to both reply to the thing and the thread root.
        # for thread forking
        thread_id = Types.uid(custom_thread) || thread_id
        maybe_debug(epic, act, thread_id, "threading under parent thread root or custom thread")

        changeset
        |> put_replied(thread_id, reply_to, thread_title)
        |> maybe_put_name(thread_title)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)

      {:ok, %{replied: %{thread_id: thread_id}} = reply_to}
      when is_binary(thread_id) ->
        # we're permitted to reply to the thing, but not the thread root
        thread_id = Types.uid(custom_thread) || reply_to.id
        smart(epic, act, reply_to, "threading under parent or custom thread")

        changeset
        |> put_replied(thread_id, reply_to, thread_title)
        |> maybe_put_name(thread_title)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)

      {:ok, %{} = reply_to} ->
        # we're permitted to reply to the parent, but it appears to have no threading information.
        thread_id = Types.uid(custom_thread) || reply_to.id
        maybe_debug(epic, act, "parent missing threading, creating as root or custom")

        reply_to = init_replied(reply_to)

        changeset
        |> put_replied(thread_id, reply_to, thread_title)
        |> maybe_put_name(thread_title)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)

      _ ->
        maybe_debug(
          epic,
          act,
          "does not reply to anything or not permitted to reply to, so starting new thread (or using custom if specified)"
        )

        thread_id = Types.uid(custom_thread) || Needle.Changesets.get_field(changeset, :id)

        changeset
        |> put_replied(thread_id, nil, thread_title)
        |> maybe_put_name(thread_title)
        |> Epic.assign(epic, on, ...)
    end
  end

  defp put_replied(changeset, thread_id, nil, thread_title) do
    changeset
    |> Changesets.put_assoc(:replied, %{
      thread_id: thread_id,
      reply_to_id: nil
    })
  end

  defp put_replied(changeset, thread_id, %{} = reply_to, thread_title) do
    changeset
    # |> maybe_debug()
    |> Changesets.put_assoc(:replied, %{
      thread_id: thread_id,
      reply_to_id: reply_to.id
    })
    |> Changeset.update_change(
      :replied,
      &Replied.make_child_of(&1, reply_to.replied)
    )
  end

  defp maybe_put_name(changeset, nil) do
    changeset
  end

  defp maybe_put_name(changeset, thread_title) do
    changeset
    # |> maybe_debug()
    |> Changesets.put_assoc(:named, %{name: thread_title})
  end

  defp init_replied(reply_to) do
    %Replied{id: reply_to.id, thread_id: reply_to.id}
    |> Threads.init_parent_replied()
    ~> Map.put(reply_to, :replied, ...)
  end

  # defp init_replied(changeset, reply_to) do
  #   replied_attrs = %{id: reply_to.id, thread_id: reply_to.id}
  #   # pretend the replied already exists, because it will in a moment
  #   replied = Changesets.set_state(struct(Replied, replied_attrs), :loaded)
  #   reply_to = Map.put(reply_to, :replied, replied)
  #   |> maybe_debug("reply_to")

  #   # HACK: inserts the parent replied in a nasty way to get around there being no way to do an insert across an association with `on_conflict: :ignore`
  #   # FIXME: causes a `no case clause matching: :raise` error
  #   Changeset.prepare_changes(changeset, &Threads.create_parent_replied(&1, replied, replied_attrs))
  # end
end
