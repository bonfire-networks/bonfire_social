defmodule Bonfire.Social.Acts.Threaded do

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.Threads
  alias Ecto.Changeset
  alias Pointers.Changesets
  import Epics
  import Where
  use Arrows

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = epic.assigns[:options][:current_user]
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
        handle_insert(epic, act, on, changeset, current_user)
      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

  defp handle_insert(epic, act, on, changeset, current_user) do
    boundary = epic.assigns[:options][:boundary]
    attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
    attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
    case Threads.find_reply_to(attrs, current_user) do
      {:ok, %{replied: %{thread_id: thread_id, thread: %{}}}=reply_to} ->
        # we are permitted to both reply to the thing and the thread root.
        debug(epic, act, thread_id, "threading under parent thread root")
        changeset
        |> put_replied(thread_id, reply_to)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)

      {:ok, %{replied: %{thread_id: thread_id}}=reply_to} when is_binary(thread_id) ->
        # we're permitted to reply to the thing, but not the thread root
        smart(epic, act, reply_to, "threading under parent")
        changeset
        |> put_replied(reply_to.id, reply_to)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)

      {:ok, %{}=reply_to} ->
        # we're permitted to reply to the parent, but it appears to have no threading information.
        debug(epic, act, "parent missing threading, creating as root")

        reply_to = init_replied(reply_to)

        changeset
        |> put_replied(reply_to.id, reply_to)
        |> Epic.assign(epic, on, ...)
        |> Epic.assign(:reply_to, reply_to)
      _ ->
        debug(epic, act, "does not reply to anything or not permitted to reply to, so starting new thread")
        id = Changeset.get_field(changeset, :id)
        changeset
        |> put_replied(id, nil)
        |> Epic.assign(epic, on, ...)
    end
  end

  defp put_replied(changeset, thread_id, nil),
    do: Changesets.put_assoc(changeset, :replied, %{thread_id: thread_id, reply_to_id: nil}) #|> debug()
  defp put_replied(changeset, thread_id, %{}=reply_to) do
    changeset
    |> Changesets.put_assoc(:replied, %{thread_id: thread_id, reply_to_id: reply_to.id}) #|> debug()
    |> Changeset.update_change(:replied, &Replied.make_child_of(&1, reply_to.replied))
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
  #   |> debug("reply_to")

  #   # HACK: inserts the parent replied in a nasty way to get around there being no way to do an insert across an association with `on_conflict: :ignore`
  #   # FIXME: causes a `no case clause matching: :raise` error
  #   Changeset.prepare_changes(changeset, &Threads.create_parent_replied(&1, replied, replied_attrs))
  # end

end
