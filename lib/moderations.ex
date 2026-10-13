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

  With `pending: true`, an action one of our moderators took on a group hosted elsewhere, which takes effect here only once the group has applied it: a request on the record, kept on this instance, whose dates say what became of it (`confirm/1`, `refuse/1`).

  ## Examples

      iex> Bonfire.Social.Moderations.record(moderator, :lock, post, reason: "off topic")
      {:ok, %Bonfire.Data.Social.Moderation{}}
  """
  def record(subject, verb, object, opts \\ []) do
    with {:ok, record} <- insert_record(subject, verb, object, opts) do
      if opts[:pending], do: request_on(record, subject, verb)
      {:ok, record}
    end
  end

  defp request_on(record, subject, verb) do
    Bonfire.Social.Requests.request(subject, Bonfire.Boundaries.Verbs.get_id!(verb), record,
      current_user: subject,
      skip_federation: true,
      # the record is already in the group's log, read by its moderators
      to_feeds: [],
      to_circles: []
    )
  end

  defp insert_record(subject, verb, object, opts) do
    # where it applies, which decides who reads it and which log it is in: a group (given when the object doesn't lead to it, as a ban on a group's behalf, whose object is the person), the instance (`:instance_wide`), or else the group the object is in, if any
    scope = opts[:scope] || group_of(object)

    # TODO: for an undo (`unlock`, `unhide`, …), `opts[:reverses]` sets `reply_to_id` to the record it reverses when there is one, with no `thread_id` so records never join a thread
    # TODO: `opts` to widen who reads it (including the person acted on) and to notify the person acted on, as the confirmation's tick boxes ask
    Moderation.changeset(%{})
    |> Activities.put_assoc(verb, subject, object)
    |> maybe_put_reason(opts[:reason])
    # not public: addressed only to who moderates where it happened, so `mentions` (no preset) plus their circle
    |> Bonfire.Boundaries.Acls.cast(subject,
      boundary: "mentions",
      to_circles: readers(scope)
    )
    # the group's log is its notifications feed; an explicit list, so nothing else (eg. the moderator's own outbox) is added
    |> FeedActivities.cast(subject, feed_ids: log_feeds(scope))
    |> repo().insert()
  end

  @doc "Whether `user`, one of ours, is acting on `object` hosted on another instance, whose authority on it is there: then what they do is sent there, and recorded here as `pending: true`. Both with their locality loaded."
  def moderating_elsewhere?(nil, _user), do: false
  def moderating_elsewhere?(_group, nil), do: false

  # as one who may moderate our mirror of the group, which its moderators circle grants, filled from the moderators the group declares at its origin
  def moderating_elsewhere?(group, user) do
    Bonfire.Social.is_local?(user) and not Bonfire.Social.is_local?(group) and
      Bonfire.Boundaries.can?(user, :mediate, group)
  end

  @doc "Whether to apply such an action here at once as well, rather than once the group elsewhere has: `opts[:apply_now]`, else config (`[Bonfire.Social.Moderations, :apply_remote_moderation_now]`, waiting by default)."
  def apply_now?(opts) do
    case e(opts, :apply_now, nil) do
      nil -> Config.get([__MODULE__, :apply_remote_moderation_now], false)
      apply_now -> apply_now == true
    end
  end

  @doc "The record one of our own moderation activities points at (its stored AP object's `pointer_id`)."
  def record_of(%{pointer_id: record_id}) when is_binary(record_id),
    do: Bonfire.Common.Needles.get(record_id, skip_boundary_check: true)

  def record_of(other), do: error(other, "Not one of our moderation activities")

  @doc "The request on a `pending: true` record, if it is still waiting for the group."
  def pending(record) do
    case request(record) do
      {:ok, %{accepted_at: nil, ignored_at: nil} = request} -> {:ok, request}
      _ -> nil
    end
  end

  @doc """
  One of our moderators' activities on a group hosted elsewhere, relayed back by that group, so applied there: if its record is still waiting (`pending: true`), `apply` puts its effect in place here (given the record) and the request is confirmed. Returns the record, which the incoming activity is linked to.
  """
  def confirm_applied(our_activity, apply) when is_function(apply, 1) do
    case record_of(our_activity) do
      {:ok, record} ->
        if pending(record) do
          apply.(record)
          confirm(record)
        end

        {:ok, record}

      _ ->
        # ours, but with no record to confirm (sent before records, or by a path that keeps none): the group relaying it back says it accepted it, so it applies
        apply.(nil)
    end
  end

  @doc """
  One of our moderators' activities on a group hosted elsewhere, which that group REFUSED (its `Reject` of it): the request on its record is refused, and `undo` takes its effect out here, in case it was applied at once (`apply_now:`), checking for itself whether there is anything to undo. Returns the record.
  """
  def refuse_applied(our_activity, undo) when is_function(undo, 1) do
    with {:ok, record} <- record_of(our_activity) do
      refuse(record)
      undo.(record)
      {:ok, record}
    end
  end

  @doc "The group applied it: the request on the record gets its `accepted_at`."
  def confirm(record) do
    with {:ok, request} <- pending(record) || {:error, :not_pending} do
      Bonfire.Social.Requests.accept(request, skip_boundary_check: true)
    end
  end

  @doc "The group refused it: the request on the record gets its `ignored_at`."
  def refuse(record) do
    with {:ok, request} <- pending(record) || {:error, :not_pending} do
      Bonfire.Social.Requests.ignore(request, skip_boundary_check: true)
    end
  end

  # found by who acted and what they did, which the record's activity holds
  defp request(record) do
    case repo().maybe_preload(record, :activity) |> e(:activity, nil) do
      %{subject_id: subject_id, verb_id: verb_id} ->
        Bonfire.Social.Requests.get(subject_id, verb_id, record, skip_boundary_check: true)

      _ ->
        nil
    end
  end

  @doc """
  The reason a moderation action federates with, as its `summary`: the one given, else the action's default (config `[Bonfire.Social.Moderations, :default_reasons, verb]`, falling back to the wording below).

  Every moderator activity sends one, whether a lock, a removal, a hide or a block, because the threadiverse reads its presence as what makes it a moderation action: Lemmy treats a `Delete` without a `summary` as the author deleting their own post, and logs its own default reason for a mod action given none.

  ## Examples

      iex> Bonfire.Social.Moderations.summary("off topic", :lock)
      "off topic"

      iex> is_binary(Bonfire.Social.Moderations.summary(nil, :hide))
      true
  """
  def summary(reason, _verb) when is_binary(reason) and reason != "", do: reason

  def summary(_, verb),
    do: Config.get([__MODULE__, :default_reasons, verb], nil) || default_reason(verb)

  defp default_reason(:lock), do: l("Locked by a moderator")
  defp default_reason(:unlock), do: l("Reopened by a moderator")

  # `hide` is everything reversible, taking a post out of a group included (the "Remove from group" action)
  defp default_reason(:hide), do: l("Hidden by a moderator")
  defp default_reason(:block), do: l("Banned by a moderator")
  defp default_reason(_), do: l("No reason given")

  # the group the object is in, if any. Through `maybe_apply` since groups live in bonfire_classify, which social doesn't depend on
  defp group_of(object) do
    case maybe_apply(Bonfire.Classify.Categories, :group_of_object, [object],
           fallback_return: nil
         ) do
      {:ok, _object, %{} = group} -> group
      _ -> nil
    end
  end

  # an instance-wide action is read by who moderates the instance
  # TODO: a record with no group of an action that isn't instance-wide (an author's own lock outside a group) is read by instance moderators too
  defp readers(nil), do: []

  # an instance-wide action is read by who moderates the instance
  defp readers(scope) when scope in [:instance_wide, :instance],
    do: Enum.map([:admin, :mod], &Bonfire.Boundaries.Circles.get_id!/1)

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
  # the instance log is a preset over records, not a feed
  defp log_feeds(scope) when scope in [:instance_wide, :instance], do: []

  defp log_feeds(group),
    do: List.wrap(e(repo().maybe_preload(group, :character), :character, :notifications_id, nil))

  defp maybe_put_reason(changeset, reason) when reason in [nil, ""], do: changeset

  defp maybe_put_reason(changeset, reason) do
    changeset
    |> Ecto.Changeset.cast(%{named: %{name: reason}}, [])
    |> Needle.Changesets.cast_assoc(:named, with: &Named.changeset/2)
  end
end
