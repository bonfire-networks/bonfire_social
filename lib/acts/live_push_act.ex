defmodule Bonfire.Social.Acts.LivePush do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that translates creates an activity for a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `feeds` - key
    * `notify_feeds` - key 
  """

  use Bonfire.Common.Utils
  alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  import Epics

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)

      case epic.assigns[on] do
        nil ->
          maybe_debug(epic, act, on, "Skipping: no activity at")
          epic

        activity ->
          ## {inspect activity}
          maybe_debug(epic, act, on, "Publishing activity at")

          feeds_key = Keyword.get(act.options, :feeds, :feed_ids)

          notify_feeds_key = Keyword.get(act.options, :notify_feeds, :notify_feeds)

          feeds = Map.get(epic.assigns, feeds_key, [])

          maybe_debug(
            epic,
            act,
            feeds,
            "Publishing to feeds at assign #{feeds_key}"
          )

          notify = Map.get(epic.assigns, notify_feeds_key)

          pushed = Bonfire.Social.LivePush.emit_live(activity, feeds, notify: notify)

          # durable delivery, run here rather than from the write path so that a failure reaches whoever caused it. Only when the write path stood down (`Bonfire.Social.Acts.Activity` with `enqueue_notify: false`), or an activity would be notified twice. This Act is skipped when the epic has errors, so a failed insert never gets this far
          notified = if epic.assigns[:notify_inline], do: notify_recipients(activity, notify)

          pushed
          # |> debug("pushed")
          |> Epic.assign(epic, on, ...)
          # kept rather than dropped: running this inline was the point, so the outcome is available to whoever asked for the publish. Not an epic error, because the activity is published either way and a missed notification must not fail a post
          |> Epic.assign(..., Keyword.get(act.options, :notified, :notified), notified)
      end
    else
      maybe_debug(act, length(epic.errors), "Skipping due to errors!")
      epic
    end
  end

  defp notify_recipients(activity, notify) do
    maybe_apply(
      Bonfire.Notify.FanOut,
      :notify,
      [
        activity,
        %{feeds: e(notify, :notify_feeds, []), recipients: e(notify, :notify_users, [])}
      ],
      fallback_return: :skip
    )
    |> case do
      {:ok, _} = notified ->
        notified

      :skip ->
        :skip

      other ->
        # the activity is published either way, so this is reported rather than raised: a missed notification must not fail a post
        error(other, "The activity is published, but notifying its recipients failed")
    end
  end
end
