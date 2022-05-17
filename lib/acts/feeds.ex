defmodule Bonfire.Social.Acts.Feeds do
  @moduledoc """
  Finds a list of appropriate feeds into which to post.

  Epic Options:
    * `:current_user` - current user. required.
    * `:boundary` - preset string or custom boundaries. default: nil

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
  """
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.Epic
  alias Bonfire.Common.Repo
  alias Bonfire.Social.Feeds
  alias Ecto.Changeset
  alias Pointers.Changesets
  import Bonfire.Social.Integration, only: [repo: 0]
  import Epics
  import Where, only: [error: 2, warn: 1]

  def run(epic, act) do
    cond do
      epic.errors != [] ->
        Epics.smart(epic, act, epic.errors, "Skipping due to epic errors")
        epic
      true ->
        on = Keyword.fetch!(act.options, :on)
        changeset = epic.assigns[on]
        current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
        boundary = epic.assigns[:options][:boundary]
        case changeset do
          %Changeset{valid?: true}=changeset ->
            smart(epic, act, changeset, "valid changeset")
            feed_ids = Feeds.feed_ids_to_publish(current_user, boundary, epic.assigns)
            pubs = Enum.map(feed_ids, &(%{feed_id: &1}))
            Changesets.put_assoc(changeset, :feed_publishes, pubs)
            |> Epic.assign(epic, on, ...)
          %Changeset{valid?: false}=changeset ->
            debug(epic, act, changeset, "invalid changeset")
            epic
          other ->
            error(other, "not a changeset")
            Epic.add_error(epic, act, {:expected_changeset, other})
        end
    end
  end

  def thread_id(epic) do
    case e(epic.assigns[:reply_to], :replied, :thread, :id, nil) do
      nil -> []
      other -> [other]
    end
  end

end
