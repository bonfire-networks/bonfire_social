defmodule Bonfire.Social.Acts.Feeds do
  @moduledoc """
  (not currently used)
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
  alias Bonfire.Repo
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
            feed_ids = get_feed_ids(epic, act, on, current_user, boundary)
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

  # TODO: unravel the pleroma mentions parsing so we can deal with mentions properly
  defp get_feed_ids(epic, act, _on, _me, "admins") do
    Feeds.admins_notifications()
    |> debug(epic, act, ..., "posting to admin feeds")
  end
  defp get_feed_ids(epic, act, on, me, boundary) do
    feeds =
      thread_id(epic) ++
      my_outbox_feed_id(epic, act, me, boundary) ++
      global_feed_ids(boundary) ++
      mentions_feed_ids(epic, act, on, boundary)
    feeds
    |> MapSet.new()
    |> MapSet.to_list()
  end

  defp thread_id(epic) do
    case e(epic.assigns[:reply_to], :replied, :thread, :id, nil) do
      nil -> []
      other -> [other]
    end
  end

  defp my_outbox_feed_id(epic, act, me, boundary) do
    if boundary in ["public", "federated", "local"] do
      case Feeds.my_feed_id(:outbox, me) do
        nil ->
          warn("Cannot find my outbox to publish!")
          []
        id ->
          debug(epic, act, boundary, "Publishing to my outbox, boundary")
          [id]
      end
    else
      debug(epic, act, boundary, "Not publishing to my outbox, boundary")
      []
    end
  end

  @global_feeds %{
    "public"    => [:guest, :local],
    "federated" => [:guest, :activity_pub],
    "local"     => [:local],
  }
  defp global_feed_ids(boundary), do: Enum.map(Map.get(@global_feeds, boundary, []), &Feeds.named_feed_id/1)

  defp mentions_feed_ids(epic, act, on, boundary) do
    mentions = Map.get(epic.assigns, :mentions, [])
    reply_to = epic.assigns[:reply_to]
    reply_to_creator = e(reply_to, :created, :creator, nil)
    user_notifications_feeds(epic, act, [reply_to_creator | mentions], boundary)
    |> debug(epic, act, ..., "mentions notifications feeds")
  end

  defp user_notifications_feeds(epic, act, users, boundary) do
    # debug(epic, act, users, "users going in")
    cond do
      boundary in ["public", "mentions", "federated"] ->
        users
        |> Enum.reject(&is_nil/1)
        |> repo().maybe_preload([:character])
        |> Enum.map(&Feeds.feed_id(:notifications, &1))
        |> Enum.reject(&is_nil/1)
      boundary == "local" ->
        users
        |> Enum.reject(&is_nil/1)
        |> repo().maybe_preload([:character, :peered])
        |> Enum.filter(&is_nil(e(&1, :peered, nil))) # only local
        |> Enum.map(&Feeds.feed_id(:notifications, &1))
        |> Enum.reject(&is_nil/1)
      true ->
        []
    end
  end



end
