defmodule Bonfire.Social.Moderations do
  @moduledoc """
  Records of moderation actions, for the moderation log.

  Each record is a `Bonfire.Data.Social.Moderation` whose `Activity` says who acted, the action and on what, with the reason, if given, in its `named` mixin.
  """
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  alias Bonfire.Data.Social.Moderation
  alias Bonfire.Data.Identity.Named
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities

  @doc """
  Records that `subject` did `verb` to `object`, with `opts[:reason]` as the reason.

  ## Examples

      iex> Bonfire.Social.Moderations.record(moderator, :lock, post, reason: "off topic")
      {:ok, %Bonfire.Data.Social.Moderation{}}
  """
  def record(subject, verb, object, opts \\ []) do
    group = group_of(object)

    # TODO: for an undo (`unlock`, `unhide`, …), `opts[:reverses]` sets `reply_to_id` to the record it reverses when there is one, with no `thread_id` so records never join a thread
    # TODO: `opts` to widen who reads it (including the person acted on) and to notify the person acted on, as the confirmation's tick boxes ask
    Moderation.changeset(%{})
    |> Activities.put_assoc(verb, subject, object)
    |> maybe_put_reason(opts[:reason])
    # not public: addressed only to who moderates where it happened, so `mentions` (no preset) plus their circle
    |> Bonfire.Boundaries.Acls.cast(subject, boundary: "mentions", to_circles: readers(group))
    # the group's log is its notifications feed; an explicit list, so nothing else (eg. the moderator's own outbox) is added
    |> FeedActivities.cast(subject, feed_ids: log_feeds(group))
    |> repo().insert()
  end

  # the group the object is in, if any. Through `maybe_apply` since groups live in bonfire_classify, which social doesn't depend on
  defp group_of(object) do
    case maybe_apply(Bonfire.Classify.Categories, :group_of_object, [object],
           fallback_return: nil
         ) do
      {:ok, _object, %{} = group} -> group
      _ -> nil
    end
  end

  # TODO: a record with no group (an instance action, or an author's own lock outside a group) is read by instance moderators and its subject
  defp readers(nil), do: []

  # TODO: instance moderators read a group's records too
  defp readers(group) do
    case maybe_apply(Bonfire.Classify.Categories, :moderators_circle, [group],
           fallback_return: nil
         ) do
      {:ok, circle} -> [id(circle)]
      _ -> []
    end
  end

  # TODO: the person acted on's notifications feed, when the moderator chooses to notify them
  defp log_feeds(nil), do: []

  defp log_feeds(group),
    do: List.wrap(e(repo().maybe_preload(group, :character), :character, :notifications_id, nil))

  defp maybe_put_reason(changeset, reason) when reason in [nil, ""], do: changeset

  defp maybe_put_reason(changeset, reason) do
    changeset
    |> Ecto.Changeset.cast(%{named: %{name: reason}}, [])
    |> Needle.Changesets.cast_assoc(:named, with: &Named.changeset/2)
  end
end
